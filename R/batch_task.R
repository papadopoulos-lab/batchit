# Declared-output commit engine (batch_task()) -- Phase 6' Units 1-4. Package
# targets, both commit styles: `return` (Unit 1, the target returns a named
# list) and `staged_writer` (Unit 2, the target streams each output to
# `batch_stage_path(<name>)` instead); see PHASE6_DESIGN.md sections 2-4, 9.1,
# 9.5.
# batch_task() reuses batch_run()'s transport (a fresh subprocess per item via
# processx, the SAME inst/batch_worker.R) but replaces the raw return-value
# result with a small, non-negotiable commit record: `outputs[[i]]` names the
# files the target must produce, and the CHILD -- never the parent -- writes
# them via the 7-step commit sequence in `.batch_commit_task()`. The final
# per-item MARKER file is the atomic witness of a complete commit -- but ONLY
# when it is a VALID, engine-produced marker (it decodes, and its
# protocol/attempt-token/committed-output-map verify): bare PATHNAME
# existence is NOT the witness. A target that errors before step 4 (removal
# of the old marker) leaves an unrelated PRE-EXISTING marker at that path
# completely untouched, so "a file sits at the marker path" does not by
# itself mean "this attempt committed" -- only a marker that decodes and
# verifies does.
#
# Unit 4 (design PHASE6_DESIGN.md sections 7, 9.2, 9.3): the OPT-IN
# consumer-skip mechanism -- `batch_record()`/`batch_prior()`/`batch_skip()`,
# backed by a scoped accessor (`.batch_record_env`) entered/exited tightly
# around `do.call()` in `.batch_execute()`, exactly like `.batch_stage_env`.
# batchit itself never decides to skip; it only reads the marker to hand a
# consumer its own prior `details` (step 0, `.batch_read_prior_marker()`,
# CHILD-side, before `do.call()`), and honours an explicit `batch_skip()`
# sentinel the target RETURNS (`.batch_commit_task_skip()`, CHILD-side, after
# `do.call()`). Neither is ever called from `batch_task()`'s own (parent) body.
#
# Doctrine (PHASE6_DESIGN.md section 0, normative): no batchit LAUNCH decision
# may depend on marker existence or contents. The parent-side functions in this
# file therefore validate only the marker's PATHNAME and its parent directory
# -- they never call file.exists()/file.info()/Sys.readlink() (or read it) on
# the marker path itself. Reading/removing/replacing the marker is exclusively
# the CHILD's job, inside `.batch_commit_task()`/`.batch_read_prior_marker()`/
# `.batch_commit_task_skip()`, as part of COMMITTING or handing a consumer its
# own prior `details` (never as part of deciding whether to dispatch) -- those
# three functions are therefore the ones below explicitly exempt from that
# rule.

# --- outputs spec: alignment, structural validation, path validation --------

#' Align a `batch_task()` `outputs` list to the item ids
#'
#' `outputs` is either POSITIONAL (an unnamed list, 1:1 with `items`/`ids`) or,
#' when the caller wants to name items instead of relying on position, NAMED BY
#' ITEM ID -- same name set as `ids`, any order (design PHASE6_DESIGN.md
#' section 9.1). Either way the return value is a plain (unnamed) list in `ids`
#' order, so every downstream consumer can index it positionally alongside
#' `items`/`ids`.
#' @noRd
.batch_align_outputs_to_ids <- function(outputs, ids, what) {
  onms <- names(outputs)
  if (is.null(onms)) {
    return(outputs)
  }
  if (any(!nzchar(onms)) || anyDuplicated(onms)) {
    stop(sprintf(
      "%s: `outputs` names must be non-blank and unique when named by item id",
      what), call. = FALSE)
  }
  if (!identical(sort(onms), sort(ids))) {
    stop(sprintf(paste0(
      "%s: named `outputs` must use EXACTLY the same set of ids as `items` -- ",
      "outputs names: {%s}; item ids: {%s}"),
      what, paste(sort(onms), collapse = ", "), paste(sort(ids), collapse = ", ")),
      call. = FALSE)
  }
  unname(outputs[ids])
}

#' Validate one item's output map STRUCTURE (design PHASE6_DESIGN.md section 3.1)
#'
#' Both-ends: the parent calls this at `batch_task()` dispatch time, the child
#' again inside `.batch_check_envelope()` (a mismatched/corrupted envelope must
#' not reach `do.call()`). Non-empty; every name non-blank and unique; every
#' path a non-empty string; every path unique within this item.
#' @param map A named character vector: `<output name> = <final path>`.
#' @noRd
.batch_validate_output_map <- function(map, where, id) {
  lead <- sprintf("batch_task() %s-validation [item '%s']", where, id)
  if (!is.character(map) || length(map) == 0L) {
    stop(sprintf("%s: outputs must be a non-empty named character vector", lead),
      call. = FALSE)
  }
  nms <- names(map)
  if (is.null(nms) || any(is.na(nms)) || any(!nzchar(nms))) {
    stop(sprintf("%s: every output must be named (no blank/missing names)", lead),
      call. = FALSE)
  }
  if (anyDuplicated(nms)) {
    stop(sprintf("%s: duplicate output name(s): %s", lead,
      paste(unique(nms[duplicated(nms)]), collapse = ", ")), call. = FALSE)
  }
  if (any(is.na(map)) || any(!nzchar(map))) {
    stop(sprintf("%s: every output path must be a non-empty string", lead),
      call. = FALSE)
  }
  if (anyDuplicated(unname(map))) {
    stop(sprintf("%s: duplicate output path(s) within this item's output map", lead),
      call. = FALSE)
  }
  invisible(TRUE)
}

#' Is `path` an absolute path (POSIX, or a Windows drive-letter path)?
#' @noRd
.batch_is_absolute_path <- function(path) {
  grepl("^(/|[A-Za-z]:[\\\\/])", path)
}

#' Is `path` a symlink (dangling or not)?
#'
#' `Sys.readlink()` returns `NA` (not `""`) for a path that does not exist at
#' all -- and `nzchar(NA_character_)` is `TRUE` by default, so a naive
#' `nzchar(Sys.readlink(path))` misreports every ABSENT path (the common case:
#' an output that doesn't exist yet) as "is a symlink". This helper is the one
#' place that distinction is made correctly: `NA` (absent) is NOT a symlink;
#' a non-`NA`, non-empty link target (even a DANGLING one, which also fails
#' `file.exists()`) IS.
#' @noRd
.batch_is_symlink <- function(path) {
  link <- suppressWarnings(Sys.readlink(path))
  !is.na(link) && nzchar(link)
}

#' Validate + normalize one item's output paths (design PHASE6_DESIGN.md 3.1)
#'
#' Conservative, PARENT-side, filesystem-touching validation of the OUTPUT
#' paths only (never the marker -- see the file banner). Every path must be
#' absolute; its parent directory must already exist; and the destination must
#' be either absent or an existing non-directory, non-symlink file (a directory,
#' symlink, or dangling symlink is rejected, never silently overwritten).
#' Returns the SAME named character vector with every path replaced by its
#' `normalizePath(mustWork = FALSE)` form, which is what the marker derivation
#' and the invocation-wide collision check both key off.
#'
#' Known gap: only directory vs. symlink vs. "everything else" is
#' distinguished (via `dir.exists()` / `Sys.readlink()`) -- a pre-existing
#' FIFO, socket, or device special file at the destination is NOT detected
#' and MAY be silently replaced by the commit rename (POSIX `rename()` can
#' replace such a destination); it is not guaranteed to be rejected.
#' Base R has no portable "is this a regular file" primitive (`file.info()`
#' exposes permission `mode`, not the S_IFREG/S_IFIFO/... type bits), so a
#' clean fix would require a compiled/system-call helper; not worth the
#' dependency for what is, in practice, an operator error at a data-pipeline
#' output path. The cross-invocation hardlink-alias gap is a SEPARATE,
#' explicitly accepted limit (design PHASE6_DESIGN.md section 3.1) -- not
#' this one.
#' @noRd
.batch_validate_output_paths <- function(map, id) {
  lead <- sprintf("batch_task() parent-validation [item '%s']", id)
  out <- map
  for (nm in names(map)) {
    path <- map[[nm]]
    if (!.batch_is_absolute_path(path)) {
      stop(sprintf("%s: output '%s' is not an absolute path: %s", lead, nm, path),
        call. = FALSE)
    }
    parent <- dirname(path)
    if (!dir.exists(parent)) {
      stop(sprintf(
        "%s: parent directory of output '%s' does not exist: %s", lead, nm, parent),
        call. = FALSE)
    }
    # Normalize ONLY the parent (resolving `..`/symlinked ancestors), then
    # re-attach the final component WITHOUT resolving it -- so a symlink AT the
    # leaf is caught below rather than silently followed. normalizePath() on the
    # whole path would resolve `alias.qs2 -> real.qs2` and commit to the target,
    # defeating the "reject existing symlink destinations" rule.
    norm <- file.path(normalizePath(parent, mustWork = FALSE), basename(path))
    # Symlink check FIRST and independent of file.exists(): a DANGLING symlink
    # fails file.exists() but must still be rejected, not silently accepted as
    # "absent, safe to create".
    if (.batch_is_symlink(norm)) {
      stop(sprintf("%s: output '%s' is a symlink, which is not permitted: %s",
        lead, nm, norm), call. = FALSE)
    }
    if (dir.exists(norm)) {
      stop(sprintf("%s: output '%s' is a directory, which is not permitted: %s",
        lead, nm, norm), call. = FALSE)
    }
    out[[nm]] <- norm
  }
  out
}

#' Derive an item's marker path deterministically (design PHASE6_DESIGN.md 9.1)
#'
#' `dirname(sort(output_paths)[1])/.batchit__<item_id>` -- the lexicographically
#' first output's directory plus the item's already-unique stable id, so two
#' items sharing a directory never collide. `normalized_map` must already be
#' `.batch_validate_output_paths()`-normalized (absolute, canonical) -- this
#' function does no filesystem I/O of its own and never touches the marker.
#' @noRd
.batch_task_marker_path <- function(normalized_map, id) {
  first_dir <- dirname(sort(unname(normalized_map))[1L])
  file.path(first_dir, paste0(".batchit__", id))
}

#' Invocation-wide output/marker collision check (design PHASE6_DESIGN.md 3.1, 9.1)
#'
#' Within ONE `batch_task()` call, no two paths -- across every item's outputs
#' AND every item's marker -- may alias each other. The doctrine (section 0/9.1)
#' forbids any LAUNCH decision depending on marker filesystem state. The markers
#' are ALREADY canonical (each derived from a normalized output dir + a plain
#' `.batchit__<id>` basename), so this check compares them EXACTLY as derived --
#' it must NOT `normalizePath()` a marker, because that would FOLLOW a leaf
#' symlink at the marker pathname and make this collision decision depend on
#' whether the marker path happens to be a symlink (a section-0 violation).
#' `outputs` must already be `.batch_validate_output_paths()`-normalized.
#' @noRd
.batch_check_task_collisions <- function(outputs, markers, ids) {
  all_paths <- c(unlist(outputs, use.names = FALSE), markers)
  if (anyDuplicated(all_paths)) {
    dup <- unique(all_paths[duplicated(all_paths)])
    stop(sprintf(paste0(
      "batch_task(): output/marker path collision within this invocation ",
      "(every output and marker must be unique across ALL items): %s"),
      paste(dup, collapse = ", ")), call. = FALSE)
  }
  invisible(TRUE)
}

#' A high-entropy per-dispatch attempt token
#'
#' Issued by the PARENT for every item, travels in the envelope, and is echoed
#' back in the marker and the commit record -- the identity the child re-reads
#' after committing (design PHASE6_DESIGN.md section 3.3 step 7) and the parent
#' checks the result against (section 3.5). Built from `tempfile()` (a process-
#' local counter, unique per call) exactly like the mirai compute-profile nonce
#' [.batch_stream_profile()], NOT from R's RNG stream -- so issuing tokens can
#' never disturb a caller's `set.seed()`/reproducibility. Distinct per item
#' within a dispatch, and distinct across runs (different session temp state).
#' @noRd
.batch_new_attempt_token <- function() {
  gsub("[^[:alnum:]]", "", basename(tempfile(pattern = "")))
}

#' Best-effort PARENT-side sweep of one item's own commit temps
#'
#' `.batch_commit_task()`'s own `on.exit` cleanup (design PHASE6_DESIGN.md
#' section 3.3) only runs if the CHILD process gets to run R-level unwind code
#' at all -- a `kill_tree()` (the timeout path) or an OS-level SIGKILL sends a
#' signal `on.exit` cannot intercept, so a worker killed while mid-commit can
#' orphan `<basename(final)>.tmp*` temps in the output directories (`return`
#' style) or `<basename(final)>.stage*` staging files (`staged_writer` style,
#' Unit 2 -- see [.batch_stage_paths_for()]). There is no way for the PARENT
#' to know the exact temp names the child generated (they carry a
#' `tempfile()`-random suffix), but it does not need to: every temp either
#' style creates is ATTEMPT-SCOPED -- `<basename>.<attempt>.tmp<random>` or
#' `<basename>.<attempt>.stage<random>`, where `<attempt>` is this dispatch's
#' unique, alphanumeric (regex-safe) token -- so a `list.files(all.files=TRUE)`
#' match keyed on the literal `.<attempt>.tmp`/`.<attempt>.stage` substring
#' finds ONLY this attempt's own temps (including the DOTFILE marker temp,
#' which `Sys.glob()` would skip). It is keyed on the unique TOKEN, never on
#' the output basename, so an unrelated pre-existing file such as
#' `out.qs2.tmp.backup` or `out.qs2.stage.backup` (no attempt token) can never
#' match -- safe to remove unconditionally.
#'
#' Deliberately conservative and narrow: it sweeps only the ONE item's own
#' attempt-scoped temps across the directories it writes into -- it never
#' inspects the MARKER's own existence/contents (only its temp-name pattern),
#' so it stays inside the doctrine (design section 0): this runs on FAILURE
#' cleanup, after the item has already been dispatched and has already
#' failed, never as part of a launch decision.
#' @param outputs_map This item's (already parent-validated, normalized)
#'   output name -> final path map.
#' @param marker_path This item's (already parent-validated) marker path.
#' @param attempt This item's dispatch attempt token (embedded in every temp).
#' @noRd
.batch_sweep_task_temps <- function(outputs_map, marker_path, attempt) {
  dirs <- unique(c(dirname(unname(outputs_map)), dirname(marker_path)))
  # list.files(all.files = TRUE), NOT Sys.glob(): a glob's leading `*` skips
  # DOTFILES, and the marker temp is a dotfile
  # (`.batchit__<id>.<attempt>.tmp<random>`). The attempt token is a unique,
  # alphanumeric (regex-safe) nonce; match the literal `.<attempt>.tmp` OR
  # `.<attempt>.stage` substring (the marker/return-style output temps use
  # `.tmp`; `staged_writer` output staging files use `.stage` -- Unit 2), so
  # an unrelated `out.qs2.tmp.backup`/`out.qs2.stage.backup` (no token) never
  # matches.
  pat <- paste0("\\.", attempt, "\\.(tmp|stage)")
  for (d in dirs) {
    leftover <- list.files(d, pattern = pat, all.files = TRUE, full.names = TRUE)
    if (length(leftover) > 0L) unlink(leftover, force = TRUE)
  }
  invisible(TRUE)
}

# --- child-side commit (design PHASE6_DESIGN.md section 3.3) ----------------

#' Atomically replace `final` with `tmp` (rename, same filesystem)
#'
#' The ONE place a temp becomes a committed final file. Supported semantics are
#' POSIX `rename()` and server-side-atomic CIFS rename-replace (the production
#' target: an uppsala CIFS mount) -- `file.rename()` overwrite behaviour is not
#' promised identically on every platform/filesystem, so this is a named,
#' single-purpose primitive rather than an inline call, mirroring the existing
#' `.batch_write_envelope()` rename.
#' @noRd
.batch_atomic_replace <- function(tmp, final) {
  if (!file.rename(tmp, final)) {
    stop(sprintf("batch commit: could not rename %s -> %s", tmp, final), call. = FALSE)
  }
  invisible(TRUE)
}

# --- staged_writer scoped accessor (design PHASE6_DESIGN.md section 3.4) ----

#' Pre-compute one item's per-output staging temp paths (staged_writer only)
#'
#' Attempt-scoped, same directory as each output's final destination (so the
#' later commit rename in `.batch_commit_task()` is same-filesystem):
#' `<basename(final)>.<attempt>.stage<random>`. Called ONCE, in
#' `.batch_execute()` BEFORE `do.call()` runs the target -- the returned map
#' is both what `batch_stage_path()` hands the target during the call AND,
#' unchanged, what `.batch_commit_task()` later verifies/renames; it is never
#' recomputed (a second `tempfile()` call would mint a DIFFERENT random path).
#' @noRd
.batch_stage_paths_for <- function(outputs, attempt) {
  declared <- names(outputs)
  stage <- character(length(declared))
  names(stage) <- declared
  for (nm in declared) {
    final <- outputs[[nm]]
    stage[[nm]] <- tempfile(pattern = paste0(basename(final), ".", attempt, ".stage"),
      tmpdir = dirname(final))
  }
  stage
}

# One package-level environment holding the CURRENT staged_writer run's
# per-output staging paths, if any. `batch_stage_path()` is called from
# INSIDE the target's own call stack (arbitrarily deep -- a helper the target
# itself calls), with no direct handle back into `.batch_execute()`'s frame,
# so this state has to live somewhere both sides can reach. A dedicated
# environment, not a base R `options()` entry: `options()` is a namespace a
# consumer's own code might independently poke at, so a private slot keeps
# this unambiguous. Only one item ever runs at a time inside one worker
# subprocess (batchit never runs two items concurrently within one child), so
# there is no concurrency hazard in reusing one shared slot across dispatches.
.batch_stage_env <- new.env(parent = emptyenv())
.batch_stage_env$active <- FALSE
.batch_stage_env$paths <- NULL

#' Enter staged_writer scope: `batch_stage_path()` becomes answerable.
#' Returns the PRIOR `{active, paths}` so the caller can restore it on exit
#' (save/restore, not an unconditional reset -- defensive against any nested or
#' in-process reuse, even though one item runs at a time per worker).
#' @noRd
.batch_stage_scope_enter <- function(paths) {
  prior <- list(active = .batch_stage_env$active, paths = .batch_stage_env$paths)
  .batch_stage_env$active <- TRUE
  .batch_stage_env$paths <- paths
  invisible(prior)
}

#' Exit staged_writer scope, restoring the PRIOR `{active, paths}` state.
#'
#' Called from a `finally` wrapped TIGHTLY around `do.call()` in
#' `.batch_execute()` -- so `batch_stage_path()` is answerable ONLY while the
#' target itself runs, NOT during the subsequent commit or result construction.
#' It runs on both the target returning normally and the target erroring. Only
#' an OS-level kill (no R-level unwind at all) can skip it, the same limit every
#' other child-side cleanup here already has.
#' @param prior The `{active, paths}` returned by `.batch_stage_scope_enter()`.
#' @noRd
.batch_stage_scope_exit <- function(prior = list(active = FALSE, paths = NULL)) {
  .batch_stage_env$active <- prior$active
  .batch_stage_env$paths <- prior$paths
  invisible(NULL)
}

#' The staging path batchit pre-computed for one declared output
#'
#' Inside a `style = "staged_writer"` [batch_task()] target, WRITE each
#' declared output to `batch_stage_path(<name>)` -- an attempt-scoped temp
#' path in the SAME directory as that output's final destination (so the
#' later commit rename is same-filesystem) -- instead of returning it. The
#' target's own return value is ignored by the commit engine; batchit finds
#' out what was written by checking, once the target returns, that this
#' exact path exists as a regular, non-symlink file (design
#' PHASE6_DESIGN.md section 3.4) -- a declared name the target never wrote
#' fails the whole item, with zero renames.
#'
#' Only callable from inside the `do.call()` of a `style = "staged_writer"`
#' `batch_task()` item -- i.e. only in a batchit worker subprocess, while
#' that one target call is running. Calling it any other time (outside a
#' staged_writer run entirely, or for a `name` this item never declared) is
#' an error.
#'
#' @param name The declared output name -- must be one of this item's
#'   `outputs` names.
#' @return A single absolute path string. WRITE to this path; do not read it
#'   back or move/rename it yourself -- batchit renames it to the final
#'   destination once every declared output has been staged.
#' @examples
#' \dontrun{
#' # inside a style = "staged_writer" target:
#' my_writer <- function(x) {
#'   saveRDS(x, batch_stage_path("primary"))
#'   invisible(NULL)
#' }
#' }
#' @export
batch_stage_path <- function(name) {
  if (!isTRUE(.batch_stage_env$active)) {
    stop(paste0(
      "batch_stage_path(): no staged_writer batch_task() run is active -- only ",
      "callable from inside the target of a style = \"staged_writer\" batch_task() item"),
      call. = FALSE)
  }
  if (!is.character(name) || length(name) != 1L || is.na(name) || !nzchar(name)) {
    stop("batch_stage_path(): `name` must be a single non-empty string", call. = FALSE)
  }
  paths <- .batch_stage_env$paths
  if (!(name %in% names(paths))) {
    stop(sprintf(
      "batch_stage_path(): '%s' is not one of this item's declared outputs: %s",
      name, paste(names(paths), collapse = ", ")), call. = FALSE)
  }
  paths[[name]]
}

# --- batch_record()/batch_prior()/batch_skip() scoped accessor --------------
# (design PHASE6_DESIGN.md sections 7, 9.2, 9.3)

# One package-level environment holding the CURRENT batch_task() item's
# opt-in consumer-skip state: whether the accessor is answerable at all
# (`active`), the PRIOR marker's own record captured at step 0 (`prior`, or
# `NULL`) -- batch_prior() reads `prior$details` from this -- and whatever
# the target itself has passed to batch_record() so far (`details`, last
# call wins). Entered/exited TIGHTLY around do.call() in .batch_execute(),
# mirroring `.batch_stage_env` exactly (see its own comment for why a
# private environment, not options(), and why one shared slot is safe: only
# one item ever runs at a time inside one worker subprocess).
.batch_record_env <- new.env(parent = emptyenv())
.batch_record_env$active <- FALSE
.batch_record_env$prior <- NULL
.batch_record_env$details <- NULL

#' Enter batch_record()/batch_prior() scope for one item's `do.call()`
#'
#' Returns the PRIOR `{active, prior, details}` so the caller can restore it
#' on exit (save/restore, exactly like [.batch_stage_scope_enter()]).
#' @param prior This item's step-0 `prior` record (design section 9.2), or
#'   `NULL`.
#' @noRd
.batch_record_scope_enter <- function(prior) {
  saved <- list(active = .batch_record_env$active, prior = .batch_record_env$prior,
    details = .batch_record_env$details)
  .batch_record_env$active <- TRUE
  .batch_record_env$prior <- prior
  .batch_record_env$details <- NULL
  invisible(saved)
}

#' Exit batch_record()/batch_prior() scope, restoring the PRIOR state
#' @param saved The `{active, prior, details}` [.batch_record_scope_enter()] returned.
#' @noRd
.batch_record_scope_exit <- function(saved = list(active = FALSE, prior = NULL, details = NULL)) {
  .batch_record_env$active <- saved$active
  .batch_record_env$prior <- saved$prior
  .batch_record_env$details <- saved$details
  invisible(NULL)
}

#' Attach an opaque `details` value to THIS item's new marker
#'
#' Callable ONLY from inside the target of a `batch_task()` item (i.e. only
#' in a batchit worker subprocess, while that one target call is running,
#' between the `.batch_record_scope_enter()`/`_exit()` pair tightly wrapping
#' `do.call()` in `.batch_execute()`) -- the opt-in half of the consumer-skip
#' mechanism (design PHASE6_DESIGN.md section 7): the target may call this
#' any number of times during its own run; the LAST call wins (design
#' section 9.3). `details` is entirely opaque to batchit -- never inspected,
#' compared, or interpreted (design section 0) -- it travels straight into
#' the item's committed marker (`.batch_commit_task()`'s `details` field) and
#' is handed back verbatim to a LATER run of the SAME item via
#' [batch_prior()]. It must be something [qs2::qs_save()] can serialize; an
#' unserializable (or otherwise invalid) value fails the target's own commit
#' at the marker-temp-write step (design section 9.3) -- BEFORE the old
#' marker is removed, so a failing `batch_record()` payload can never destroy
#' a previously valid commit.
#'
#' Calling this outside an active `batch_task()` target run -- including
#' during a return-value dispatch ([batch_run()]/[batch_stream()]/
#' [batch_fn()]), which has no marker/skip machinery at all -- is an error.
#'
#' @param details Any value [qs2::qs_save()] can serialize.
#' @return `invisible(NULL)`.
#' @examples
#' \dontrun{
#' # inside a batch_task() target:
#' my_target <- function(x) {
#'   batch_record(list(computed_from = x))
#'   list(primary = x)
#' }
#' }
#' @export
batch_record <- function(details) {
  if (!isTRUE(.batch_record_env$active)) {
    stop(paste0(
      "batch_record(): no batch_task() target run is active -- only callable ",
      "from inside the target of a batch_task() item"), call. = FALSE)
  }
  .batch_record_env$details <- details
  invisible(NULL)
}

#' Return the PRIOR run's `batch_record()` details for THIS item
#'
#' Callable ONLY from inside the target of a `batch_task()` item, exactly
#' like [batch_record()]. Returns the `details` value THIS SAME item's PRIOR
#' successful commit passed to `batch_record()`, captured at STEP 0 -- before
#' `do.call()` even started (design PHASE6_DESIGN.md section 9.2) -- from the
#' final marker at this item's derived marker path, but ONLY if that marker
#' decodes AND its protocol, attempt token, and committed output map all
#' verify against THIS item's own declared outputs; a malformed, foreign,
#' absent, or symlinked marker, or one belonging to a differently-shaped
#' item, all make this return `NULL`, exactly like there being no prior at
#' all. A VALID prior marker whose `details` is itself `NULL`/absent ALSO
#' makes this return `NULL` -- i.e. a target that never called
#' `batch_record()` on its prior run disables skip for the next one, since
#' there is nothing for the target to decide currency from.
#'
#' The target is expected to inspect this value and decide for itself
#' whether the prior outputs are still current; if so, it should RETURN
#' [batch_skip()] instead of recomputing. batchit ascribes NO meaning to
#' `details` and never makes this decision itself (design section 0).
#'
#' @return The prior `details` value, or `NULL`.
#' @examples
#' \dontrun{
#' my_target <- function(x) {
#'   prior <- batch_prior()
#'   if (!is.null(prior) && identical(prior$computed_from, x)) {
#'     return(batch_skip())
#'   }
#'   batch_record(list(computed_from = x))
#'   list(primary = x)
#' }
#' }
#' @export
batch_prior <- function() {
  if (!isTRUE(.batch_record_env$active)) {
    stop(paste0(
      "batch_prior(): no batch_task() target run is active -- only callable ",
      "from inside the target of a batch_task() item"), call. = FALSE)
  }
  prior <- .batch_record_env$prior
  if (is.null(prior)) return(NULL)
  prior[["details"]]
}

#' Sentinel: tell batchit the prior committed outputs are current
#'
#' RETURN this from a `batch_task()` target (do not call it merely for a
#' side effect) to mean "do not recompute -- the outputs a prior run of this
#' item already committed are still current; reuse them" (design
#' PHASE6_DESIGN.md sections 7, 9.2). Reachable only when [batch_prior()]
#' returned non-`NULL` for this item; batchit then RE-VERIFIES the prior
#' marker and RE-STATS every declared output before honouring the request
#' (design section 9.2 point 4) -- a target that returns this without a
#' valid prior, or whose prior/outputs no longer verify at that moment,
#' fails loud with the marker left completely untouched. Like
#' [batch_record()]/[batch_prior()], only callable from inside the target of
#' an active `batch_task()` item.
#'
#' @return A sentinel object (class `"batch_skip"`); RETURN it, do not act on
#'   it yourself.
#' @examples
#' \dontrun{
#' my_target <- function(x) {
#'   if (!is.null(batch_prior())) return(batch_skip())
#'   list(primary = x)
#' }
#' }
#' @export
batch_skip <- function() {
  if (!isTRUE(.batch_record_env$active)) {
    stop(paste0(
      "batch_skip(): no batch_task() target run is active -- only callable ",
      "from inside the target of a batch_task() item"), call. = FALSE)
  }
  structure(list(), class = "batch_skip")
}

#' Is `x` the [batch_skip()] sentinel a target returned?
#' @noRd
.batch_is_skip <- function(x) inherits(x, "batch_skip")

# --- step-0 prior-marker read + skip-time re-verify --------------------------
# (design PHASE6_DESIGN.md sections 9.2, 9.3 -- CHILD-side; exempt from the
# file-banner doctrine rule for the same reason `.batch_commit_task()` is.)

#' Is `record` a well-formed batchit marker record for THIS item's `outputs`?
#'
#' Structural verification only (mirrors the read-back check
#' `.batch_commit_task()`'s own step 7 performs on a marker it JUST wrote,
#' generalised to a marker written by some EARLIER commit): exactly the
#' fields `.batch_commit_task()` writes (`protocol`, `attempt`, `committed`,
#' `details` -- no more, no fewer), the CURRENT protocol number, a
#' non-empty attempt-token string, and a committed output map that is
#' EXACTLY `outputs` (names AND paths) -- not merely non-empty or
#' overlapping. Total: every comparison here is on plain base types
#' (`identical()`, which never dispatches), so a hostile `record` cannot
#' make this throw; the caller still wraps its OWN read of the marker in a
#' `tryCatch`, since decoding an arbitrary file can fail before this
#' function is ever reached.
#' @noRd
.batch_valid_marker_record <- function(record, outputs) {
  if (!is.list(record)) return(FALSE)
  nm <- names(record)
  if (is.null(nm) || any(!nzchar(nm)) || anyDuplicated(nm)) return(FALSE)
  if (!identical(sort(nm), sort(c("protocol", "attempt", "committed", "details")))) {
    return(FALSE)
  }
  if (!identical(record[["protocol"]], .BATCH_PROTOCOL)) return(FALSE)
  attempt <- record[["attempt"]]
  if (!is.character(attempt) || length(attempt) != 1L || is.na(attempt) || !nzchar(attempt)) {
    return(FALSE)
  }
  committed <- record[["committed"]]
  if (!is.character(committed) || is.null(names(committed)) ||
      anyDuplicated(names(committed)) ||
      !identical(sort(names(committed)), sort(names(outputs))) ||
      !identical(committed[order(names(committed))], outputs[order(names(outputs))])) {
    return(FALSE)
  }
  TRUE
}

#' Read + verify the PRIOR marker at step 0, BEFORE `do.call()` runs the target
#'
#' Reads the marker EXACTLY ONCE (design PHASE6_DESIGN.md section 9.2 point
#' 1), before the target ever runs, and accepts it as a usable `prior` only
#' if it decodes to a well-formed batchit marker record AND that record's
#' protocol/attempt-token/committed-output-map verify against THIS item's
#' own declared `outputs` -- i.e. it really is a marker some prior attempt
#' of THIS SAME item produced for these exact output paths, not a
#' foreign/malformed/stale file that happens to sit at the derived marker
#' path. An absent, unreadable, malformed, foreign, directory, or
#' (defensively) SYMLINKED marker all resolve to `prior = NULL` -- never an
#' error, and never a partial/best-effort acceptance.
#'
#' Sanctioned by design section 0 ("...or to hand a consumer its own prior
#' `details`") -- this is a CHILD-side read, never a launch decision (the
#' item has already been unconditionally dispatched by the time this runs);
#' the marker itself is left completely untouched.
#' @param marker_path This item's derived (or explicit) marker path.
#' @param outputs This item's declared output map (already both-ends
#'   validated and normalized).
#' @return The decoded marker record (a list), or `NULL`.
#' @noRd
.batch_read_prior_marker <- function(marker_path, outputs) {
  tryCatch(
    {
      if (!file.exists(marker_path) || dir.exists(marker_path) ||
          .batch_is_symlink(marker_path)) {
        return(NULL)
      }
      record <- qs2::qs_read(marker_path)
      if (!.batch_valid_marker_record(record, outputs)) return(NULL)
      record
    },
    error = function(e) NULL
  )
}

#' Child-side declared-output commit (design PHASE6_DESIGN.md section 3.3)
#'
#' `fn_kind = "package"`; either commit style. Runs the 7-step sequence: (1)
#' PREPARE every output temp -- `return`: validate the target's return names
#' match the declared outputs EXACTLY, then qs2-serialize each value
#' (declaration order); `staged_writer`: the target's return value is
#' IGNORED (it streamed each output to `batch_stage_path(<name>)` instead,
#' BEFORE this function is even called -- see `.batch_execute()`), so step 1
#' here is a pure ASSERTION that every declared output now exists at its
#' pre-computed staging path as a regular, non-symlink file (an
#' undeclared/never-written name -> error, zero renames); (2) prepare + close
#' the marker temp; (3) verify every temp is a regular non-symlink file; (4)
#' remove the OLD final marker and verify removal; (5) rename every output
#' temp to its final path; (6) rename the marker temp to its final path LAST
#' (the atomic commit point); (7) read back the marker and verify the
#' attempt token, then emit the commit record. Steps 2-7 are IDENTICAL
#' between the two styles -- only step 1 differs in HOW the output temp gets
#' onto disk (written here, vs. already written by the target).
#'
#' Total for the caller's purposes: on ANY failure -- wrong/missing return
#' names (`return`), a never-written declared output (`staged_writer`), a
#' serialization failure, a rename failure, a marker-verification failure --
#' every temp/stage file this call is tracking is removed (via `on.exit`) and
#' the condition is re-thrown, so `.batch_execute()`'s outer `tryCatch` turns
#' it into the usual structured error envelope. A VALID final marker (one
#' that decodes and whose protocol/attempt-token/committed-output-map verify)
#' is the witness of a complete commit -- never bare pathname existence: this
#' function never removes a temp AFTER it has been renamed to a final path
#' (it is no longer a temp at that point), and it never "rolls back" an
#' already-renamed final -- a crash between two output renames leaves a torn
#' state with NO valid marker to vouch for it (an unrelated marker left over
#' from a PRIOR attempt, if the crash happened before step 4 removed it, is
#' NOT evidence of THIS attempt -- only a marker whose attempt token matches
#' is), which is exactly the point of the witness (nothing downstream may
#' trust a partial commit); see PHASE6_DESIGN.md section 3.3 for the full
#' rationale.
#'
#' This is the one PARENT-adjacent function in this file that DOES read/remove/
#' replace the marker -- by design: it runs in the CHILD, as part of
#' committing, never as part of a launch decision (design section 0).
#'
#' @param value The target's raw return value. For `style = "return"` this
#'   must be a named list matching `outputs`; for `style = "staged_writer"`
#'   it is discarded entirely, unchecked. Never crosses back to the parent.
#' @param outputs Named character vector: declared output name -> final path
#'   (already parent-validated and normalized).
#' @param marker_path Final marker path (already parent-validated and
#'   normalized).
#' @param attempt This dispatch's attempt token (parent-issued).
#' @param details The opaque consumer `details` value (design PHASE6_DESIGN.md
#'   section 7) captured from the target's LAST `batch_record()` call during
#'   `do.call()` (`.batch_execute()` reads it from `.batch_record_env` right
#'   after `do.call()` returns), or `NULL` if the target never called
#'   `batch_record()`. Written into the marker verbatim; batchit never
#'   inspects or interprets it. An unserializable value fails at step 2
#'   (the marker-temp write) -- BEFORE step 4 removes the old marker.
#' @param style `"return"` or `"staged_writer"`.
#' @param stage_map For `style = "staged_writer"` only: the SAME declared
#'   name -> staging-temp-path map [.batch_stage_paths_for()] computed, and
#'   [.batch_stage_scope_enter()]'d, BEFORE `do.call()` ran the target (so
#'   `batch_stage_path()` and this function agree on the exact paths).
#'   Ignored for `style = "return"`.
#' @return `list(committed = outputs, attempt = attempt, skipped = FALSE)` --
#'   the commit record. `skipped` is always `FALSE` here (a real commit just
#'   happened); see [.batch_commit_task_skip()] for the `skipped = TRUE`
#'   sibling.
#' @noRd
.batch_commit_task <- function(value, outputs, marker_path, attempt, details = NULL,
                                 style = "return", stage_map = NULL) {
  declared <- names(outputs)

  # Every temp created below, MINUS anything already renamed to its final path
  # (removed from this vector as each rename succeeds) -- cleaned up on any
  # failure, unconditionally. `on.exit()` reads `pending` at EXIT time (the
  # function's current frame), so later reassignments are seen correctly.
  pending <- character(0)
  ok <- FALSE
  on.exit(if (!ok) unlink(pending, force = TRUE), add = TRUE)

  # --- step 1: prepare every output temp ---------------------------------------
  if (identical(style, "return")) {
    if (!is.list(value) || is.null(names(value)) || anyDuplicated(names(value)) ||
        any(!nzchar(names(value))) || !identical(sort(names(value)), sort(declared))) {
      stop(sprintf(paste0(
        "batch commit: target must return a named list whose names are EXACTLY ",
        "the declared outputs {%s}; got {%s}"),
        paste(declared, collapse = ", "),
        paste(names(value) %||% character(0), collapse = ", ")), call. = FALSE)
    }
    out_tmp <- character(length(declared))
    names(out_tmp) <- declared
    for (nm in declared) {
      final <- outputs[[nm]]
      # Attempt-SCOPED temp name: `<basename>.<attempt>.tmp<random>`. The attempt
      # token is a unique, alphanumeric (glob-safe) nonce, so the parent-side
      # failure sweep can match ONLY this attempt's own temps -- never an unrelated
      # pre-existing file (e.g. a user's `out.qs2.tmp.backup`).
      tmp <- tempfile(pattern = paste0(basename(final), ".", attempt, ".tmp"),
        tmpdir = dirname(final))
      pending <- c(pending, tmp)
      qs2::qs_save(value[[nm]], tmp)
      out_tmp[[nm]] <- tmp
    }
  } else {
    # style == "staged_writer": the target's return VALUE is unconditionally
    # ignored -- there is no return-name-match check for this style (that
    # check is `return`-only). `stage_map` names the EXACT paths
    # batch_stage_path() handed the target (pre-computed in .batch_execute()
    # before do.call()), so step 1 here does no writing of its own: it only
    # ASSERTS every declared name now exists at its staging path as a
    # regular, non-symlink file. Register every stage path for cleanup up
    # front, not just the ones that turn out to exist -- unlink() on an
    # absent path is a silent no-op, so this is safe even when the target
    # wrote nothing at all.
    pending <- c(pending, unname(stage_map))
    for (nm in declared) {
      p <- stage_map[[nm]]
      if (!file.exists(p) || dir.exists(p) || .batch_is_symlink(p)) {
        stop(sprintf(paste0(
          "batch commit: staged_writer target never wrote declared output '%s' ",
          "(expected a non-directory, non-symlink file at batch_stage_path('%s') = %s; ",
          "as at any output destination, base R cannot portably reject a ",
          "FIFO/socket/device special file the target may have created there)"),
          nm, nm, p), call. = FALSE)
      }
    }
    out_tmp <- stage_map
  }

  # --- step 2: prepare + close the marker temp ---------------------------------
  record <- list(protocol = .BATCH_PROTOCOL, attempt = attempt, committed = outputs,
    details = details)
  marker_tmp <- tempfile(pattern = paste0(basename(marker_path), ".", attempt, ".tmp"),
    tmpdir = dirname(marker_path))
  pending <- c(pending, marker_tmp)
  qs2::qs_save(record, marker_tmp)

  # --- step 3: verify every temp is a regular, non-symlink file ----------------
  for (tp in c(out_tmp, marker_tmp)) {
    if (!file.exists(tp) || dir.exists(tp) || .batch_is_symlink(tp)) {
      stop("batch commit: temp file is missing or not a regular file: ", tp,
        call. = FALSE)
    }
  }

  # --- step 4: remove the OLD final marker, verify removal ---------------------
  # The old marker must not survive into this attempt: if it did, and steps 5-7
  # below failed partway, a stale marker could keep vouching for outputs this
  # attempt has already started overwriting.
  if (file.exists(marker_path)) unlink(marker_path, force = TRUE)
  if (file.exists(marker_path)) {
    stop("batch commit: could not remove the existing marker before committing: ",
      marker_path, call. = FALSE)
  }

  # --- step 5: replace every final output ---------------------------------------
  for (nm in declared) {
    .batch_atomic_replace(out_tmp[[nm]], outputs[[nm]])
    pending <- setdiff(pending, out_tmp[[nm]])
  }

  # --- step 6: rename the marker temp -> final marker LAST (the commit point) --
  .batch_atomic_replace(marker_tmp, marker_path)
  pending <- setdiff(pending, marker_tmp)

  # --- step 7: read back the marker, verify, emit the commit record ------------
  final_record <- qs2::qs_read(marker_path)
  if (!identical(final_record[["attempt"]], attempt)) {
    stop("batch commit: marker read-back attempt-token mismatch after commit",
      call. = FALSE)
  }

  ok <- TRUE
  list(committed = outputs, attempt = attempt, skipped = FALSE)
}

#' Child-side skip-and-reuse (design PHASE6_DESIGN.md sections 7, 9.2, 9.3)
#'
#' Reached only when the target RETURNED [batch_skip()] -- `.batch_execute()`
#' calls this INSTEAD OF `.batch_commit_task()` on that path, never both.
#' `prior` is the step-0 record (already decoded and verified against this
#' item's own `outputs`, design section 9.2 point 2); a `NULL` prior is
#' rejected here (the target should not have been able to return
#' `batch_skip()` at all in that case -- `batch_prior()` would have returned
#' `NULL` -- but this is re-checked rather than trusted, per the "no
#' step-0-snapshot is trusted at skip time" rule below).
#'
#' RE-READS and RE-VERIFIES the marker at THIS moment (the step-0 read was a
#' SNAPSHOT taken before `do.call()`; nothing during the target's run could
#' have changed it under batchit's own single-exclusive-writer contract, but
#' this function does not rely on that assumption -- it re-derives the
#' witness fresh) and RE-STATS every declared output as a regular,
#' non-symlink, EXISTING file -- the marker vouches they were fully
#' committed once; only a fresh stat proves they still are (design section
#' 9.2 point 4: "any mismatch/missing -> fail loud, marker untouched").
#'
#' On success: NOTHING is removed, renamed, or written -- no new marker, no
#' temp files, no output replacement -- this is a pure verify-and-reuse. The
#' emitted commit record echoes the RE-VERIFIED marker's OWN attempt token
#' (not a fresh one -- nothing new was committed) and `skipped = TRUE`, so
#' the parent inspector (`.batch_inspect_result()`) can tell a skip apart
#' from a real commit and skip the "attempt must equal the token I just
#' dispatched" check that only makes sense for a fresh commit.
#' @param prior This item's step-0 `prior` record, or `NULL`.
#' @param outputs Named character vector: declared output name -> final path
#'   (already parent-validated and normalized) -- the SAME map passed to
#'   `.batch_commit_task()`.
#' @param marker_path Final marker path (already parent-validated and
#'   normalized).
#' @return `list(committed = outputs, attempt = <the prior marker's own
#'   token>, skipped = TRUE)`.
#' @noRd
.batch_commit_task_skip <- function(prior, outputs, marker_path, attempt) {
  if (is.null(prior)) {
    stop(paste0(
      "batch_skip(): the target returned batch_skip() but there is no valid ",
      "prior commit to reuse for this item (batch_prior() would have ",
      "returned NULL) -- refusing to skip; the marker is left untouched: ",
      marker_path), call. = FALSE)
  }
  # Re-derive the witness fresh -- do NOT trust the step-0 snapshot as still
  # current (design section 9.2 point 4: "RE-READ + match the marker token &
  # output map").
  record <- if (file.exists(marker_path) && !dir.exists(marker_path) &&
      !.batch_is_symlink(marker_path)) {
    tryCatch(qs2::qs_read(marker_path), error = function(e) NULL)
  } else {
    NULL
  }
  if (is.null(record) || !.batch_valid_marker_record(record, outputs) ||
      !identical(record[["attempt"]], prior[["attempt"]])) {
    stop(paste0(
      "batch_skip(): the prior marker changed, or no longer verifies, ",
      "between step 0 and the skip decision -- refusing to reuse it; the ",
      "marker is left untouched: ", marker_path), call. = FALSE)
  }
  for (nm in names(outputs)) {
    p <- outputs[[nm]]
    if (!file.exists(p) || dir.exists(p) || .batch_is_symlink(p)) {
      stop(sprintf(paste0(
        "batch_skip(): declared output '%s' no longer exists as a regular, ",
        "non-symlink file -- refusing to reuse the prior commit; the marker ",
        "is left untouched: %s"), nm, p), call. = FALSE)
    }
  }
  # Return the CURRENT dispatch's attempt token (not the prior marker's): the
  # parent's inspector checks it unconditionally, so a skip cannot bypass the
  # dispatch-identity check. The prior marker's own token was verified above
  # (record$attempt == prior$attempt) as part of re-confirming the witness.
  list(committed = outputs, attempt = attempt, skipped = TRUE)
}

# --- frontend: batch_task() --------------------------------------------------

#' Run a target on each of a fixed list of items, committing DECLARED OUTPUT
#' FILES instead of returning a value
#'
#' The declared-output sibling of [batch_run()] (design PHASE6_DESIGN.md
#' sections 2-3): same transport (a fresh subprocess per item via `processx`,
#' the same worker script, the same both-ends item validation and hash-verified
#' target), but instead of a raw return value crossing back, the target's
#' return is committed to `outputs[[i]]` -- a named map of final file paths --
#' by the CHILD, via an all-or-nothing 7-step rename sequence
#' (`.batch_commit_task()`). A per-item MARKER file is the atomic witness of a
#' complete commit -- but only a VALID, engine-produced marker (one that
#' decodes and whose protocol/attempt-token/committed-output-map verify) is
#' that witness; bare pathname EXISTENCE is not. A target that errors before
#' the old marker is removed (commit step 4) leaves an unrelated pre-existing
#' marker at that path completely untouched, so a file sitting at the marker
#' path does not by itself mean this attempt committed.
#'
#' Two commit styles, for EITHER fn_kind: `style = "return"` (Unit 1 -- the
#' target returns `list(<name> = <value>, ...)`, names matching the declared
#' outputs EXACTLY; each value is qs2-serialized to its declared path) and
#' `style = "staged_writer"` (Unit 2 -- the target instead WRITES each output
#' to [batch_stage_path()]`(<name>)` as it goes; its return value is ignored).
#' There is deliberately no `collect` argument -- the point of `batch_task()`
#' is that raw values never cross back to the parent; only a small commit
#' record does.
#'
#' `fn` is EITHER a `batch_target()` descriptor (`fn_kind = "package"`) OR a
#' bare closure (`fn_kind = "adhoc"`, Phase 6' Unit 3, design PHASE6_DESIGN.md
#' sections 1-2) -- both drive the SAME commit engine (`.batch_commit_task()`,
#' both styles, the same marker/§0 doctrine). A closure is gated by the same
#' self-containedness lint and mandatory `baseenv()` rebase [batch_fn()] uses
#' (see `.batch_lint_adhoc_fn()`); commit-record identity is unaffected either
#' way (it is bound to the marker's own attempt token, never to fn_kind).
#'
#' No batchit-computed "should this item re-run?" logic exists here or anywhere
#' in these Units: every item is dispatched and every target is always run. (A
#' later, explicitly opt-in consumer-skip mechanism is design section 7 --
#' not implemented yet.) Nor does the parent ever inspect a marker's
#' existence or contents before dispatch (design section 0) -- dispatch behaves
#' identically whether a target's marker already exists, is stale, or is
#' malformed; only the CHILD, while committing, ever reads one.
#'
#' @param fn EITHER a `batch_target` descriptor from [batch_target()]
#'   (`fn_kind = "package"`) OR a bare closure (`fn_kind = "adhoc"`):
#'   self-contained (base R, `pkg::`-qualified calls, and its own formals only
#'   -- see `.batch_lint_adhoc_fn()`), not a primitive, and not taking `...`.
#' @param items List of items; each a fully-named list of `fn`'s formals.
#'   Named items keep their name as the item id; unnamed items get their index.
#' @param outputs A list aligned to `items`: `outputs[[i]]` is item `i`'s output
#'   map, a named character vector `c(<name> = <final path>)`. May instead be
#'   NAMED BY ITEM ID (same name set as the derived item ids, any order) when
#'   `items` itself is named. Every path must be absolute; each destination must
#'   be absent or an existing non-directory, non-symlink file (base R cannot
#'   portably distinguish a FIFO/socket/device special file, so such a file is
#'   not rejected here and MAY be replaced by the commit rename); every
#'   output AND every derived marker path must be unique across the WHOLE call.
#' @param style Commit style: `"return"` (the target returns a named list --
#'   Unit 1) or `"staged_writer"` (the target writes each output via
#'   [batch_stage_path()] instead -- Unit 2). Any other value errors.
#' @param n_workers Concurrent subprocesses (validated: finite, whole, >= 1).
#' @param dev_path For `fn_kind = "package"`, the CONSUMER package's source
#'   tree for `devtools::load_all()` in the worker (or `NULL` for the
#'   installed consumer package). For `fn_kind = "adhoc"` there is no
#'   consumer identity, so this instead names BATCHIT'S OWN source tree (see
#'   [batch_fn()]'s `dev_path` doc) -- `NULL` (the default) uses the installed
#'   `batchit`.
#' @param p A progress callback such as a `progressr` progressor, or `NULL`.
#' @param label Optional short stage tag prefixed to the progress message.
#' @param timeout Per-item wall-clock limit in seconds; see [batch_run()].
#' @param target Deprecated former name of `fn` (Unit 1/2 shipped
#'   `batch_task(target = ...)`). Pass `fn` instead; supplying both errors.
#' @return A list, named by item id, in item order: each element is that item's
#'   commit record, `list(committed = <named char: name -> final path>,
#'   attempt = <token>, skipped = <TRUE/FALSE>)`. `skipped` is `TRUE` only
#'   when the target opted in via [batch_prior()]/[batch_skip()] (design
#'   PHASE6_DESIGN.md section 7) and batchit reused the item's prior commit
#'   instead of recomputing; it is `FALSE` for every ordinary commit. Never
#'   the target's raw return value.
#' @examples
#' \dontrun{
#' t <- batch_target("mypkg", "process_one_slice")
#' batch_task(
#'   t,
#'   items = list(list(x = 1), list(x = 2)),
#'   outputs = list(c(main = "/data/out_1.qs2"), c(main = "/data/out_2.qs2")),
#'   n_workers = 2
#' )
#' }
#' @export
batch_task <- function(
  fn,
  items,
  outputs,
  style = "return",
  n_workers,
  dev_path = NULL,
  p = NULL,
  label = NULL,
  timeout = .BATCH_DEFAULT_TIMEOUT,
  target = NULL
) {
  # `target` is the DEPRECATED former name of `fn` (Unit 1/2 shipped
  # `batch_task(target = ...)`; Unit 3 renamed it `fn` because it now also
  # accepts a bare closure). Preserve the old NAMED spelling.
  if (!is.null(target)) {
    if (!missing(fn)) {
      stop(paste0("batch_task(): pass `fn` only -- `target` is the deprecated ",
        "former name of `fn`; do not pass both"), call. = FALSE)
    }
    fn <- target
  }
  # `fn` is EITHER a batch_target() descriptor (fn_kind = "package") OR a bare
  # closure (fn_kind = "adhoc", Phase 6' Unit 3) -- resolved here, ONCE, into
  # the two variables (`fn_kind`, and either `target` or a lint-passed,
  # baseenv()-rebased `fn`) every step below branches on.
  if (inherits(fn, "batch_target")) {
    fn_kind <- "package"
    target <- fn
    formal_names <- target$formal_names
  } else if (is.function(fn)) {
    fn_kind <- "adhoc"
    .batch_lint_adhoc_fn(fn, where = "parent")
    fn <- .batch_rebase_adhoc_closure(fn)
    formal_names <- names(formals(fn))
    if (is.null(formal_names)) formal_names <- character(0)
    target <- NULL
  } else {
    stop(paste0("batch_task(): `fn` must come from batch_target() (fn_kind = ",
      "\"package\") or be a bare closure (fn_kind = \"adhoc\")"), call. = FALSE)
  }
  if (!is.character(style) || length(style) != 1L || is.na(style) || !nzchar(style)) {
    stop("batch_task(): `style` must be a single non-empty string", call. = FALSE)
  }
  if (!(style %in% c("return", "staged_writer"))) {
    stop(sprintf(
      "batch_task(): unknown style '%s' (must be \"return\" or \"staged_writer\")",
      style), call. = FALSE)
  }
  n_workers <- .batch_validate_n_workers(n_workers, "batch_task()")
  # Validate ALL config BEFORE the empty-workload early return -- otherwise a
  # bad dev_path/timeout is silently accepted whenever there is no work.
  timeout <- .batch_validate_timeout(timeout, "batch_task()")
  # For "package", dev_path names the CONSUMER's tree (target$package). For
  # "adhoc" there is no consumer identity -- dev_path instead names BATCHIT'S
  # OWN tree (see batch_fn()'s dev_path doc; the worker interprets it the
  # same way).
  dev_path <- .batch_validate_dev_path(dev_path,
    if (identical(fn_kind, "package")) target$package else "batchit")
  if (!is.list(items)) {
    stop(sprintf("batch_task(): `items` must be a list, got %s", class(items)[1L]),
      call. = FALSE)
  }
  if (!is.list(outputs)) {
    stop(sprintf("batch_task(): `outputs` must be a list, got %s", class(outputs)[1L]),
      call. = FALSE)
  }
  if (length(outputs) != length(items)) {
    stop(sprintf(
      "batch_task(): `outputs` must have the same length as `items` (%d), got %d",
      length(items), length(outputs)), call. = FALSE)
  }

  n_items <- length(items)
  if (n_items == 0L) return(list())

  # Stable per-item ids (item names, else the index) -- shared with batch_run().
  ids <- .batch_item_ids(items)
  # `.batch_task_marker_path()` interpolates the id straight into a filename
  # (`.batchit__<id>`); a `/` or `\` in an id would place that marker in a
  # different (possibly nonexistent) subdirectory than the one just
  # validated. ids come from item NAMES, so a path separator in one is the
  # caller's error -- reject it loudly rather than let it silently derive a
  # broken marker path.
  # `.batch_task_marker_path()` interpolates the id straight into a filename
  # (`.batchit__<id>`); a `/` or `\` in an id would place that marker in a
  # different (possibly nonexistent) subdirectory than the one just
  # validated. ids come from item NAMES, so a path separator in one is the
  # caller's error -- reject it loudly rather than let it silently derive a
  # broken marker path.
  bad_ids <- ids[grepl("[/\\\\]", ids, perl = TRUE)]
  if (length(bad_ids) > 0L) {
    stop(sprintf(paste0(
      "batch_task(): item id(s) must not contain '/' or '\\\\' (interpolated into the ",
      "per-item marker filename .batchit__<id>): %s"),
      paste(unique(bad_ids), collapse = ", ")), call. = FALSE)
  }
  outputs <- .batch_align_outputs_to_ids(outputs, ids, "batch_task()")

  # Validate EVERY item's args and EVERY item's output map up front (not just
  # the first): item schemas are legitimately heterogeneous, so a bad one hides
  # behind a good first one.
  for (i in seq_len(n_items)) {
    if (identical(fn_kind, "package")) {
      .batch_validate_item(target, items[[i]], where = "parent", id = ids[i])
    } else {
      .batch_validate_adhoc_item(formal_names, items[[i]], where = "parent", id = ids[i])
    }
  }
  for (i in seq_len(n_items)) {
    .batch_validate_output_map(outputs[[i]], where = "parent", id = ids[i])
  }
  outputs <- lapply(seq_len(n_items), function(i)
    .batch_validate_output_paths(outputs[[i]], ids[i]))
  markers <- vapply(seq_len(n_items), function(i)
    .batch_task_marker_path(outputs[[i]], ids[i]), character(1))
  # Invocation-wide collision check: every output AND every marker, across all
  # items -- see the file banner for why the marker check is pathname-only.
  .batch_check_task_collisions(outputs, markers, ids)

  attempts <- vapply(seq_len(n_items), function(i) .batch_new_attempt_token(),
    character(1))
  # fn_kind == "adhoc" (Phase 6' Unit 3, design section 9.4): a fresh
  # per-dispatch identity nonce, echoed back by the child and checked by
  # .batch_inspect_result() in place of the package/symbol/hash identity a
  # batch_target descriptor would otherwise supply. Unused (stays NULL) for
  # "package" -- the commit-record attempt-token check already binds identity
  # there.
  nonces <- if (identical(fn_kind, "adhoc")) {
    vapply(seq_len(n_items), function(i) .batch_new_attempt_token(), character(1))
  } else {
    NULL
  }

  script_path <- .batch_worker_script()
  rscript_bin <- file.path(R.home("bin"), "Rscript")

  input_paths <- vapply(seq_len(n_items), function(i) {
    tempfile(pattern = paste0("batch_in_", i, "_"), fileext = ".qs2")
  }, character(1))
  output_paths <- vapply(seq_len(n_items), function(i) {
    tempfile(pattern = paste0("batch_out_", i, "_"), fileext = ".qs2")
  }, character(1))
  # Per-item stdout/stderr goes to a file, not a pipe -- see batch_run()'s log
  # handling, which this mirrors exactly.
  log_paths <- vapply(seq_len(n_items), function(i) {
    tempfile(pattern = paste0("batch_log_", i, "_"), fileext = ".log")
  }, character(1))

  on.exit({
    unlink(input_paths, force = TRUE)
    unlink(output_paths, force = TRUE)
    unlink(log_paths, force = TRUE)
  }, add = TRUE)

  # --vanilla does not reproduce the parent's library path; force it via
  # R_LIBS before startup, exactly like batch_run().
  worker_env <- c(
    "current",
    R_LIBS = paste(.libPaths(), collapse = .Platform$path.sep)
  )

  runner_pkg <- .batch_runner_package()
  for (i in seq_len(n_items)) {
    envelope <- if (identical(fn_kind, "package")) {
      .batch_input_envelope(
        target, dev_path, runner_pkg, ids[i], items[[i]],
        outputs = outputs[[i]], marker = markers[i], style = style,
        attempt = attempts[i])
    } else {
      .batch_input_envelope(
        target = NULL, dev_path = dev_path, runner = runner_pkg, id = ids[i],
        args = items[[i]], fn_kind = "adhoc",
        outputs = outputs[[i]], marker = markers[i], style = style,
        attempt = attempts[i], fn = fn, nonce = nonces[i])
    }
    .batch_write_envelope(envelope, input_paths[i])
  }

  active <- list()
  n_done <- 0L
  next_item <- 1L
  results <- vector("list", n_items)

  on.exit({
    for (entry in active) {
      tryCatch(entry$proc$kill_tree(), error = function(e) NULL)
      # kill_tree() cannot let the child's own on.exit run, so sweep this
      # killed item's attempt-scoped commit temps here too. Without this, a
      # sibling item failing while THIS one is mid-commit leaves exactly the
      # SIGKILL orphan the sweep exists to prevent. (No-op on normal exit:
      # `active` is empty once every item has been collected.)
      tryCatch(
        .batch_sweep_task_temps(outputs[[entry$idx]], markers[entry$idx],
          attempts[entry$idx]),
        error = function(e) NULL)
    }
  }, add = TRUE, after = FALSE)

  if (is.null(p)) message(sprintf("  [0/%d] dispatching workers...", n_items))

  .launch <- function(idx) {
    proc <- processx::process$new(
      command = rscript_bin,
      args = c("--vanilla", script_path, input_paths[idx], output_paths[idx]),
      stdout = log_paths[idx],
      stderr = "2>&1",
      env = worker_env,
      cleanup_tree = TRUE
    )
    list(proc = proc, idx = idx, started = Sys.time())
  }

  # A worker failed -- sweep any commit temps this item's own (killed or
  # errored) attempt may have left behind (see .batch_sweep_task_temps() --
  # the SIGKILL/timeout case is exactly why this is the parent's job: a
  # kill_tree() reaches the child before its own on.exit cleanup can run),
  # surface its log tail, then stop. Identical shape to batch_run()'s
  # .fail(), tagged with batch_task() in the message.
  .fail <- function(entry, what) {
    idx <- entry$idx
    .batch_sweep_task_temps(outputs[[idx]], markers[idx], attempts[idx])
    tail_txt <- .batch_log_tail(log_paths[idx])
    if (nzchar(trimws(tail_txt))) {
      message(sprintf(
        "\n--- item '%s' failed ---\nOUTPUT (stdout+stderr):\n%s\n---",
        ids[idx], tail_txt))
    }
    stop(sprintf("batch_task(): item '%s' %s", ids[idx], what), call. = FALSE)
  }

  # Read + validate one finished item's result envelope while its log is still
  # on disk. Passes THIS item's dispatched outputs/attempt to the inspector so
  # the returned commit record is checked against what was actually sent, not
  # merely well-formed.
  .collect <- function(entry) {
    idx <- entry$idx
    exit_status <- entry$proc$get_exit_status()
    if (!is.null(exit_status) && exit_status != 0L) {
      .fail(entry, sprintf("worker exited %d before writing a result", exit_status))
    }
    path <- output_paths[idx]
    if (!file.exists(path)) {
      .fail(entry, sprintf("produced no result envelope: %s", path))
    }
    envelope <- tryCatch(
      .batch_read_envelope(path),
      error = function(e) {
        .fail(entry, sprintf("wrote an unreadable result envelope (%s): %s",
          path, conditionMessage(e)))
      }
    )
    insp <- if (identical(fn_kind, "package")) {
      .batch_inspect_result(envelope, ids[idx], target,
        expected_outputs = outputs[[idx]], expected_attempt = attempts[idx])
    } else {
      .batch_inspect_result(envelope, ids[idx], target = NULL,
        expected_outputs = outputs[[idx]], expected_attempt = attempts[idx],
        expected_nonce = nonces[idx])
    }
    if (!insp$ok) .fail(entry, insp$reason)
    .batch_surface_warnings(insp$warnings, ids[idx])
    insp$value
  }

  repeat {
    while (length(active) < n_workers && next_item <= n_items) {
      active[[length(active) + 1L]] <- .launch(next_item)
      next_item <- next_item + 1L
    }
    if (length(active) == 0L) break

    still_active <- list()
    for (entry in active) {
      if (!entry$proc$is_alive()) {
        value <- .collect(entry)
        # results[idx] <- list(value), NOT results[[idx]] <- value: the usual
        # NULL-deletion trap (see batch_run()) -- moot here in practice (a
        # commit record is never NULL), kept for consistency/robustness.
        results[entry$idx] <- list(value)
        unlink(log_paths[entry$idx], force = TRUE)
        n_done <- n_done + 1L
        if (!is.null(p)) {
          p(message = paste(
            c(label, ids[entry$idx], format(Sys.time(), "%H:%M:%S")),
            collapse = " "
          ))
        } else if (n_done == n_items || n_done %% max(1L, n_items %/% 20L) == 0L) {
          message(sprintf("  [%d/%d] complete  %s",
            n_done, n_items, format(Sys.time(), "%H:%M:%S")))
        }
      } else if (is.finite(timeout) &&
                 as.numeric(difftime(Sys.time(), entry$started, units = "secs")) > timeout) {
        tryCatch(entry$proc$kill_tree(), error = function(e) NULL)
        .fail(entry, sprintf("exceeded the %g s timeout and was killed", timeout))
      } else {
        still_active[[length(still_active) + 1L]] <- entry
      }
    }
    active <- still_active

    if (length(active) > 0L) Sys.sleep(0.1)
  }

  names(results) <- ids
  results
}

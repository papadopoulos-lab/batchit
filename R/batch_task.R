# Declared-output commit engine (batch_task()) -- Phase 6' Unit 1. Package
# targets, `return` style only; see PHASE6_DESIGN.md sections 2-4, 9.1, 9.5.
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
# Doctrine (PHASE6_DESIGN.md section 0, normative): no batchit LAUNCH decision
# may depend on marker existence or contents. The parent-side functions in this
# file therefore validate only the marker's PATHNAME and its parent directory
# -- they never call file.exists()/file.info()/Sys.readlink() (or read it) on
# the marker path itself. Reading/removing/replacing the marker is exclusively
# the CHILD's job, inside `.batch_commit_task()`, as part of COMMITTING (never
# as part of deciding whether to dispatch). `.batch_commit_task()` is therefore
# the one function below explicitly exempt from that rule.

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
#' orphan `<basename(final)>.tmp*` temps in the output directories. There is
#' no way for the PARENT to know the exact temp names the child generated
#' (they carry a `tempfile()`-random suffix), but it does not need to: every
#' temp `.batch_commit_task()` creates is ATTEMPT-SCOPED --
#' `<basename>.<attempt>.tmp<random>`, where `<attempt>` is this dispatch's
#' unique, alphanumeric (regex-safe) token -- so a `list.files(all.files=TRUE)`
#' match keyed on the literal `.<attempt>.tmp` substring finds ONLY this
#' attempt's own temps (including the DOTFILE marker temp, which `Sys.glob()`
#' would skip). It is keyed on the unique TOKEN, never on the output basename,
#' so an unrelated pre-existing file such as `out.qs2.tmp.backup` (no attempt
#' token) can never match -- safe to remove unconditionally.
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
  # alphanumeric (regex-safe) nonce; match the literal `.<attempt>.tmp`
  # substring, so an unrelated `out.qs2.tmp.backup` (no token) never matches.
  pat <- paste0("\\.", attempt, "\\.tmp")
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

#' Child-side declared-output commit (design PHASE6_DESIGN.md section 3.3)
#'
#' Unit 1: `fn_kind = "package"`, `style = "return"` only. Runs the 7-step
#' sequence: (1) validate the target's return names match the declared outputs
#' EXACTLY, then prepare every output temp (qs2-serialize, declaration order);
#' (2) prepare + close the marker temp; (3) verify every temp is a regular
#' non-symlink file; (4) remove the OLD final marker and verify removal; (5)
#' rename every output temp to its final path; (6) rename the marker temp to
#' its final path LAST (the atomic commit point); (7) read back the marker and
#' verify the attempt token, then emit the commit record.
#'
#' Total for the caller's purposes: on ANY failure -- wrong/missing return
#' names, a serialization failure, a rename failure, a marker-verification
#' failure -- every temp this call created is removed (via `on.exit`) and the
#' condition is re-thrown, so `.batch_execute()`'s outer `tryCatch` turns it
#' into the usual structured error envelope. A VALID final marker (one that
#' decodes and whose protocol/attempt-token/committed-output-map verify) is
#' the witness of a complete commit -- never bare pathname existence: this
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
#' @param value The target's raw return value (a named list). Discarded by the
#'   caller after this call returns -- it never crosses back to the parent.
#' @param outputs Named character vector: declared output name -> final path
#'   (already parent-validated and normalized).
#' @param marker_path Final marker path (already parent-validated and
#'   normalized).
#' @param attempt This dispatch's attempt token (parent-issued).
#' @param details Reserved (design section 7); always `NULL` in Unit 1.
#' @return `list(committed = outputs, attempt = attempt)` -- the commit record.
#' @noRd
.batch_commit_task <- function(value, outputs, marker_path, attempt, details = NULL) {
  declared <- names(outputs)

  if (!is.list(value) || is.null(names(value)) || anyDuplicated(names(value)) ||
      any(!nzchar(names(value))) || !identical(sort(names(value)), sort(declared))) {
    stop(sprintf(paste0(
      "batch commit: target must return a named list whose names are EXACTLY ",
      "the declared outputs {%s}; got {%s}"),
      paste(declared, collapse = ", "),
      paste(names(value) %||% character(0), collapse = ", ")), call. = FALSE)
  }

  # Every temp created below, MINUS anything already renamed to its final path
  # (removed from this vector as each rename succeeds) -- cleaned up on any
  # failure, unconditionally. `on.exit()` reads `pending` at EXIT time (the
  # function's current frame), so later reassignments are seen correctly.
  pending <- character(0)
  ok <- FALSE
  on.exit(if (!ok) unlink(pending, force = TRUE), add = TRUE)

  # --- step 1: prepare every output temp (qs2-serialize, declaration order) ---
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
  list(committed = outputs, attempt = attempt)
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
#' Unit 1 implements only `style = "return"` (the target returns
#' `list(<name> = <value>, ...)`, names matching the declared outputs EXACTLY;
#' each value is qs2-serialized to its declared path) and only package targets
#' (`fn_kind = "package"`, via [batch_target()]). There is deliberately no
#' `collect` argument -- the point of `batch_task()` is that raw values never
#' cross back to the parent; only a small commit record does.
#'
#' No batchit-computed "should this item re-run?" logic exists here or anywhere
#' in this Unit: every item is dispatched and every target is always run. (A
#' later, explicitly opt-in consumer-skip mechanism is design section 7 --
#' not implemented in Unit 1.) Nor does the parent ever inspect a marker's
#' existence or contents before dispatch (design section 0) -- dispatch behaves
#' identically whether a target's marker already exists, is stale, or is
#' malformed; only the CHILD, while committing, ever reads one.
#'
#' @param target A `batch_target` descriptor from [batch_target()].
#' @param items List of items; each a fully-named list of the target's formals.
#'   Named items keep their name as the item id; unnamed items get their index.
#' @param outputs A list aligned to `items`: `outputs[[i]]` is item `i`'s output
#'   map, a named character vector `c(<name> = <final path>)`. May instead be
#'   NAMED BY ITEM ID (same name set as the derived item ids, any order) when
#'   `items` itself is named. Every path must be absolute; each destination must
#'   be absent or an existing non-directory, non-symlink file (base R cannot
#'   portably distinguish a FIFO/socket/device special file, so such a file is
#'   not rejected here and MAY be replaced by the commit rename); every
#'   output AND every derived marker path must be unique across the WHOLE call.
#' @param style Commit style. Only `"return"` is implemented in Unit 1;
#'   `"staged_writer"` errors as not yet supported.
#' @param n_workers Concurrent subprocesses (validated: finite, whole, >= 1).
#' @param dev_path Consumer-package source tree for `devtools::load_all()` in
#'   the worker, or `NULL` for the installed consumer package.
#' @param p A progress callback such as a `progressr` progressor, or `NULL`.
#' @param label Optional short stage tag prefixed to the progress message.
#' @param timeout Per-item wall-clock limit in seconds; see [batch_run()].
#' @return A list, named by item id, in item order: each element is that item's
#'   commit record, `list(committed = <named char: name -> final path>,
#'   attempt = <token>)`. Never the target's raw return value.
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
  target,
  items,
  outputs,
  style = "return",
  n_workers,
  dev_path = NULL,
  p = NULL,
  label = NULL,
  timeout = .BATCH_DEFAULT_TIMEOUT
) {
  if (!inherits(target, "batch_target")) {
    stop("batch_task(): `target` must come from batch_target()", call. = FALSE)
  }
  if (!is.character(style) || length(style) != 1L || is.na(style) || !nzchar(style)) {
    stop("batch_task(): `style` must be a single non-empty string", call. = FALSE)
  }
  if (identical(style, "staged_writer")) {
    stop(paste0("batch_task(): style = \"staged_writer\" is not yet supported ",
      "(Unit 1 implements \"return\" only)"), call. = FALSE)
  }
  if (!identical(style, "return")) {
    stop(sprintf("batch_task(): unknown style '%s' (only \"return\" is supported)",
      style), call. = FALSE)
  }
  n_workers <- .batch_validate_n_workers(n_workers, "batch_task()")
  # Validate ALL config BEFORE the empty-workload early return -- otherwise a
  # bad dev_path/timeout is silently accepted whenever there is no work.
  timeout <- .batch_validate_timeout(timeout, "batch_task()")
  dev_path <- .batch_validate_dev_path(dev_path, target$package)
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
    .batch_validate_item(target, items[[i]], where = "parent", id = ids[i])
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
    envelope <- .batch_input_envelope(
      target, dev_path, runner_pkg, ids[i], items[[i]],
      outputs = outputs[[i]], marker = markers[i], style = style,
      attempt = attempts[i])
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
    insp <- .batch_inspect_result(envelope, ids[idx], target,
      expected_outputs = outputs[[idx]], expected_attempt = attempts[idx])
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

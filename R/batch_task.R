# Declared-output commit engine (run_and_write_files_atomically()). Package
# targets, both commit styles: `return` (the target returns a named list) and
# `staged_writer` (the target streams each output to
# `where_to_write_output(<name>)` instead). See DESIGN.md sections 1, 3, 4
# and 5.
# run_and_write_files_atomically() reuses run()/run_and_collect()'s transport
# (a fresh subprocess per item via
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
# Doctrine (DESIGN.md section 1, normative): no batchit LAUNCH decision
# may depend on marker existence or contents. The parent-side functions in this
# file therefore validate only the marker's PATHNAME and its parent directory
# -- they never call file.exists()/file.info()/Sys.readlink() (or read it) on
# the marker path itself. Reading/removing/replacing the marker is exclusively
# the CHILD's job, inside `.batch_commit_task()`, as part of COMMITTING -- the
# one function below explicitly exempt from that rule.

# --- outputs spec: alignment, structural validation, path validation --------

#' Align a `run_and_write_files_atomically()` `outputs` list to the item ids
#'
#' `outputs` is either POSITIONAL or NAMED BY ITEM ID. POSITIONAL means an
#' unnamed list, 1:1 with `items`/`ids`. NAMED BY ITEM ID uses the same name
#' set as `ids`, in any order. A caller picks it to name items instead of
#' relying on position (design DESIGN.md section 4.6). Either way the return
#' value is a plain (unnamed) list in `ids`
#' order, so every downstream consumer can index it positionally alongside
#' `items`/`ids`.
#' @noRd
.batch_align_outputs_to_ids <- function(outputs, ids, what) {
  onms <- names(outputs)
  if (is.null(onms)) {
    return(outputs)
  }
  if (any(!nzchar(onms)) || anyDuplicated(onms)) {
    stop(
      sprintf(
        "%s: `outputs` names must be non-blank and unique when named by item id",
        what
      ),
      call. = FALSE
    )
  }
  if (!identical(sort(onms), sort(ids))) {
    stop(
      sprintf(
        paste0(
          "%s: named `outputs` must use EXACTLY the same set of ids as `items` -- ",
          "outputs names: {%s}; item ids: {%s}"
        ),
        what,
        paste(sort(onms), collapse = ", "),
        paste(sort(ids), collapse = ", ")
      ),
      call. = FALSE
    )
  }
  unname(outputs[ids])
}

#' Validate one item's output map STRUCTURE (design DESIGN.md section 4.1)
#'
#' Both-ends: the parent calls this at `run_and_write_files_atomically()` dispatch time, the child
#' again inside `.batch_check_envelope()` (a mismatched/corrupted envelope must
#' not reach `do.call()`). Non-empty; every name non-blank and unique; every
#' path a non-empty string; every path unique within this item.
#' @param map A named character vector: `<output name> = <final path>`.
#' @noRd
.batch_validate_output_map <- function(map, where, id) {
  lead <- sprintf(
    "run_and_write_files_atomically() %s-validation [item '%s']",
    where,
    id
  )
  if (!is.character(map) || length(map) == 0L) {
    stop(
      sprintf("%s: outputs must be a non-empty named character vector", lead),
      call. = FALSE
    )
  }
  nms <- names(map)
  if (is.null(nms) || any(is.na(nms)) || any(!nzchar(nms))) {
    stop(
      sprintf("%s: every output must be named (no blank/missing names)", lead),
      call. = FALSE
    )
  }
  if (anyDuplicated(nms)) {
    stop(
      sprintf(
        "%s: duplicate output name(s): %s",
        lead,
        paste(unique(nms[duplicated(nms)]), collapse = ", ")
      ),
      call. = FALSE
    )
  }
  if (any(is.na(map)) || any(!nzchar(map))) {
    stop(
      sprintf("%s: every output path must be a non-empty string", lead),
      call. = FALSE
    )
  }
  if (anyDuplicated(unname(map))) {
    stop(
      sprintf(
        "%s: duplicate output path(s) within this item's output map",
        lead
      ),
      call. = FALSE
    )
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
#' `Sys.readlink()` returns `NA`, not `""`, for a path that does not exist at
#' all. `nzchar(NA_character_)` is `TRUE` by default. So a naive
#' `nzchar(Sys.readlink(path))` misreports every ABSENT path as "is a
#' symlink". An absent path is the common case: an output that doesn't exist
#' yet. This helper is the one place that distinction is made correctly. `NA`
#' (absent) is NOT a symlink. A non-`NA`, non-empty link target IS, even a
#' DANGLING one, which also fails `file.exists()`.
#' @noRd
.batch_is_symlink <- function(path) {
  link <- suppressWarnings(Sys.readlink(path))
  !is.na(link) && nzchar(link)
}

#' Validate + normalize one item's output paths (design DESIGN.md 4.1)
#'
#' Conservative, PARENT-side, filesystem-touching validation of the OUTPUT
#' paths only (never the marker -- see the file banner). Every path MUST be
#' absolute. Its parent directory MUST already exist. The destination MUST be
#' either absent, or an existing non-directory, non-symlink file. A directory,
#' a symlink, or a dangling symlink is rejected, never silently overwritten.
#' Returns the SAME named character vector, with every path replaced by its
#' `normalizePath(mustWork = FALSE)` form. The marker derivation and the
#' invocation-wide collision check both key off that form.
#'
#' Known gap: only directory vs. symlink vs. "everything else" is
#' distinguished, via `dir.exists()` and `Sys.readlink()`. A pre-existing
#' FIFO, socket, or device special file at the destination is NOT detected. It
#' MAY be silently replaced by the commit rename, because POSIX `rename()` can
#' replace such a destination. It is not guaranteed to be rejected. Base R has
#' no portable "is this a regular file" primitive. `file.info()` exposes
#' permission `mode`, not the S_IFREG, S_IFIFO and other type bits. A clean
#' fix would need a compiled or system-call helper. That is not worth the
#' dependency, for what is in practice an operator error at a data-pipeline
#' output path. The cross-invocation hardlink-alias gap is a SEPARATE,
#' explicitly accepted limit (design DESIGN.md section 4.1) -- not
#' this one.
#' @noRd
.batch_validate_output_paths <- function(map, id) {
  lead <- sprintf(
    "run_and_write_files_atomically() parent-validation [item '%s']",
    id
  )
  out <- map
  for (nm in names(map)) {
    path <- map[[nm]]
    if (!.batch_is_absolute_path(path)) {
      stop(
        sprintf("%s: output '%s' is not an absolute path: %s", lead, nm, path),
        call. = FALSE
      )
    }
    parent <- dirname(path)
    if (!dir.exists(parent)) {
      stop(
        sprintf(
          "%s: parent directory of output '%s' does not exist: %s",
          lead,
          nm,
          parent
        ),
        call. = FALSE
      )
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
      stop(
        sprintf(
          "%s: output '%s' is a symlink, which is not permitted: %s",
          lead,
          nm,
          norm
        ),
        call. = FALSE
      )
    }
    if (dir.exists(norm)) {
      stop(
        sprintf(
          "%s: output '%s' is a directory, which is not permitted: %s",
          lead,
          nm,
          norm
        ),
        call. = FALSE
      )
    }
    out[[nm]] <- norm
  }
  out
}

#' Derive an item's marker path deterministically (design DESIGN.md 4.6)
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

#' Invocation-wide output/marker collision check (design DESIGN.md 4.1, 4.6)
#'
#' Within ONE `run_and_write_files_atomically()` call, no two paths -- across every item's outputs
#' AND every item's marker -- may alias each other. The doctrine (sections 1/4.6)
#' forbids any LAUNCH decision depending on marker filesystem state. The
#' markers are ALREADY canonical: each is derived from a normalized output dir
#' plus a plain `.batchit__<id>` basename. So this check compares them EXACTLY
#' as derived. It MUST NOT `normalizePath()` a marker. That would FOLLOW a
#' leaf symlink at the marker pathname. This collision decision would then
#' depend on whether the marker path happens to be a symlink, which is a
#' section-0 violation.
#' `outputs` must already be `.batch_validate_output_paths()`-normalized.
#' @noRd
.batch_check_task_collisions <- function(outputs, markers, ids) {
  all_paths <- c(unlist(outputs, use.names = FALSE), markers)
  if (anyDuplicated(all_paths)) {
    dup <- unique(all_paths[duplicated(all_paths)])
    stop(
      sprintf(
        paste0(
          "run_and_write_files_atomically(): output/marker path collision within this invocation ",
          "(every output and marker must be unique across ALL items): %s"
        ),
        paste(dup, collapse = ", ")
      ),
      call. = FALSE
    )
  }
  invisible(TRUE)
}

#' A high-entropy per-dispatch attempt token
#'
#' The PARENT issues one for every item. It travels in the envelope, and is
#' echoed back in the marker and the commit record. It is the identity the
#' child re-reads after it commits (design DESIGN.md section 4.3 step 7). It
#' is also the identity the parent checks the result against (section 4.5).
#' Built from `tempfile()`, a process-local counter that is unique per call.
#' That is exactly how the mirai compute-profile nonce
#' [.batch_stream_profile()] is built. It is NOT built from R's RNG stream, so
#' a new token can never disturb a caller's `set.seed()` or reproducibility.
#' Distinct per item within a dispatch, and distinct across runs (different
#' session temp state).
#' @noRd
.batch_new_attempt_token <- function() {
  gsub("[^[:alnum:]]", "", basename(tempfile(pattern = "")))
}

#' Best-effort PARENT-side sweep of one item's own commit temps
#'
#' `.batch_commit_task()`'s own `on.exit` cleanup (design DESIGN.md
#' section 4.3) only runs if the CHILD process gets to run R-level unwind code
#' at all. A `kill_tree()` (the timeout path) or an OS-level SIGKILL sends a
#' signal `on.exit` cannot intercept. So a worker killed while mid-commit can
#' orphan two kinds of file:
#' * `<basename(final)>.tmp*` temps in the output directories (`return`
#'   style);
#' * `<basename(final)>.stage*` staging files (`staged_writer` style, Unit 2
#'   -- see [.batch_stage_paths_for()]).
#'
#' The PARENT cannot know the exact temp names the child generated, because
#' they carry a `tempfile()`-random suffix. It does not need to. Every temp
#' either style creates is ATTEMPT-SCOPED: `<basename>.<attempt>.tmp<random>`
#' or `<basename>.<attempt>.stage<random>`. `<attempt>` is this dispatch's
#' unique, alphanumeric (regex-safe) token. So a `list.files(all.files=TRUE)`
#' match, keyed on the literal `.<attempt>.tmp` or `.<attempt>.stage`
#' substring, finds ONLY this attempt's own temps. That includes the DOTFILE
#' marker temp, which `Sys.glob()` would skip. It is keyed on the unique
#' TOKEN, never on the output basename. So an unrelated pre-existing file such
#' as `out.qs2.tmp.backup` or `out.qs2.stage.backup`, with no attempt token,
#' can never match. It is safe to remove a match unconditionally.
#'
#' Deliberately conservative and narrow. It sweeps only the ONE item's own
#' attempt-scoped temps, across the directories it writes into. It never
#' inspects the MARKER's own existence or contents, only its temp-name
#' pattern, so it stays inside the doctrine (design section 1). It runs on
#' FAILURE cleanup, after the item was already dispatched and already failed,
#' never as part of a launch decision.
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
    leftover <- list.files(
      d,
      pattern = pat,
      all.files = TRUE,
      full.names = TRUE
    )
    if (length(leftover) > 0L) unlink(leftover, force = TRUE)
  }
  invisible(TRUE)
}

# --- child-side commit (design DESIGN.md section 4.3) ----------------------

#' Atomically replace `final` with `tmp` (rename, same filesystem)
#'
#' The ONE place a temp becomes a committed final file. Supported semantics
#' are POSIX `rename()` and server-side-atomic CIFS rename-replace. The
#' production target is an uppsala CIFS mount. `file.rename()` overwrite
#' behaviour is not promised identically on every platform and filesystem. So
#' this is a named, single-purpose primitive rather than an inline call, and it
#' mirrors the existing `.batch_write_envelope()` rename.
#' @noRd
.batch_atomic_replace <- function(tmp, final) {
  if (!file.rename(tmp, final)) {
    stop(
      sprintf("batch commit: could not rename %s -> %s", tmp, final),
      call. = FALSE
    )
  }
  invisible(TRUE)
}

# --- standalone atomic qs2 writer -------------------------------------------

#' Atomically write an object to a qs2 file
#'
#' Writes to a uniquely-named temporary file in the same directory as `path`,
#' then renames it into place. Rename-into-place is atomic on POSIX
#' filesystems, and server-side atomic on SMB/CIFS. So an interrupted write
#' leaves the destination either absent or complete. It is never a truncated
#' file that a later read would halt on. An interruption here means a
#' `SIGKILL`, a crash, or a dropped mount. `...` is forwarded to
#' [qs2::qs_save()].
#'
#' The parent directory of `path` must already exist: this function never
#' creates it.
#'
#' What this does **not** promise, stated because the tempting reading is
#' wrong:
#'
#' * **It is not durability.** `file.rename()` is atomic with respect to other
#'   *readers*; it is not an `fsync`. A power loss can still lose a renamed
#'   file whose data has not reached the disk. This protects against a killed
#'   process, not a killed machine.
#' * **It is not a lock.** Two concurrent writers of the same `path` each
#'   produce a complete file and the last rename wins. No reader sees a torn
#'   file, but nothing here decides *which* writer should have won.
#' * **It does not always clean up after itself.** The partial temp file is
#'   removed on an R-level error. But `on.exit()` cannot run after a
#'   `SIGKILL`, so a hard-killed worker leaves its randomly-named `.tmp`
#'   behind. The *destination* is still absent-or-complete, which is the
#'   guarantee that matters; the litter is not.
#'
#' The temporary file is created with [tempfile()] in the destination directory
#' rather than `paste0(path, ".tmp", Sys.getpid())`. A PID suffix is not
#' collision-proof. PIDs are unique only among *live processes on one host*.
#' Data of this kind commonly lives on a share that two hosts mount at once.
#' The same PID on two machines could then pick the same temp path for the
#' same target. Same directory is required: `file.rename()` is not atomic
#' across filesystems.
#'
#' This is a standalone writer, independent of the
#' `run_and_write_files_atomically()` commit engine. Its temp carries no
#' dispatch attempt token, and that engine's failure cleanup does not sweep it.
#'
#' @param object Object to serialize.
#' @param path Destination path. Its parent directory must already exist.
#' @param ... Passed to [qs2::qs_save()] (e.g. `nthreads`).
#' @return `path`, invisibly.
#' @examples
#' path <- file.path(tempdir(), "cars.qs2")
#' write_qs2_atomically(mtcars, path)
#' nrow(qs2::qs_read(path))
#'
#' # The destination is replaced only once the new file is complete, so a
#' # reader never sees a truncated file, and an interrupted write leaves the
#' # previous contents intact.
#' write_qs2_atomically(mtcars[1:5, ], path)
#' nrow(qs2::qs_read(path))
#'
#' unlink(path)
#' @seealso [run_and_write_files_atomically()] for the same guarantee applied
#'   to every output of a dispatched item. That function's commit engine is
#'   separate: this writer emits no marker, and its temporary file is not
#'   swept by that engine's failure cleanup.
#'
#'   `vignette("batchit")` for where this sits relative to
#'   the four dispatch functions.
#' @export
write_qs2_atomically <- function(object, path, ...) {
  dir <- dirname(path)
  tmp <- tempfile(pattern = paste0(basename(path), ".tmp"), tmpdir = dir)

  # Clean up the partial temp file on an R-level failure. Conditional on `ok`:
  # an unconditional unlink would fire AFTER a successful rename, when `tmp` is
  # a pathname another writer may already have taken. This cannot run after a
  # SIGKILL; see the note above. The destination is safe either way, because it
  # only ever comes into existence via the rename below.
  ok <- FALSE
  on.exit(if (!ok) unlink(tmp, force = TRUE), add = TRUE)

  qs2::qs_save(object, tmp, ...)
  # Deliberately NOT `.batch_atomic_replace()`: that helper is the commit
  # engine's single rename point and hard-codes a "batch commit:" message,
  # which a standalone save must not emit.
  if (!file.rename(tmp, path)) {
    stop("write_qs2_atomically(): could not rename ", tmp, " -> ", path)
  }
  ok <- TRUE
  invisible(path)
}

# --- staged_writer scoped accessor (design DESIGN.md section 4.4) ----------

#' Pre-compute one item's per-output staging temp paths (staged_writer only)
#'
#' Attempt-scoped, same directory as each output's final destination (so the
#' later commit rename in `.batch_commit_task()` is same-filesystem):
#' `<basename(final)>.<attempt>.stage<random>`. Called ONCE, in
#' `.batch_execute()`, BEFORE `do.call()` runs the target. The returned map is
#' what `where_to_write_output()` hands the target during the call. The same
#' map, unchanged, is what `.batch_commit_task()` later verifies and renames.
#' It is never recomputed: a second `tempfile()` call would mint a DIFFERENT
#' random path.
#' @noRd
.batch_stage_paths_for <- function(outputs, attempt) {
  declared <- names(outputs)
  stage <- character(length(declared))
  names(stage) <- declared
  for (nm in declared) {
    final <- outputs[[nm]]
    stage[[nm]] <- tempfile(
      pattern = paste0(basename(final), ".", attempt, ".stage"),
      tmpdir = dirname(final)
    )
  }
  stage
}

# One package-level environment holding the CURRENT staged_writer run's
# per-output staging paths, if any. `where_to_write_output()` is called from
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

#' Enter staged_writer scope: `where_to_write_output()` becomes answerable.
#' Returns the PRIOR `{active, paths}` so the caller can restore it on exit.
#' This is save/restore, not an unconditional reset. It is defensive against
#' any nested or in-process reuse, even though one item runs at a time per
#' worker.
#' @noRd
.batch_stage_scope_enter <- function(paths) {
  prior <- list(
    active = .batch_stage_env$active,
    paths = .batch_stage_env$paths
  )
  .batch_stage_env$active <- TRUE
  .batch_stage_env$paths <- paths
  invisible(prior)
}

#' Exit staged_writer scope, restoring the PRIOR `{active, paths}` state.
#'
#' Called from a `finally` wrapped TIGHTLY around `do.call()` in
#' `.batch_execute()`. So `where_to_write_output()` is answerable ONLY while
#' the target itself runs, NOT during the subsequent commit or result
#' construction.
#' It runs on both the target returning normally and the target erroring. Only
#' an OS-level kill (no R-level unwind at all) can skip it, the same limit every
#' other child-side cleanup here already has.
#' @param prior The `{active, paths}` returned by `.batch_stage_scope_enter()`.
#' @noRd
.batch_stage_scope_exit <- function(
  prior = list(active = FALSE, paths = NULL)
) {
  .batch_stage_env$active <- prior$active
  .batch_stage_env$paths <- prior$paths
  invisible(NULL)
}

#' Get the path to write one declared output to, inside a "staged_writer" function
#'
#' When you use `style = "staged_writer"` with [run_and_write_files_atomically()]
#' or [stream_from_parent_and_write_files_atomically()], your function does
#' not return its output. It writes each declared output itself, to the
#' path this function gives you. Call `where_to_write_output(name)` once for
#' each output name you declared in `outputs`, and write to exactly that
#' path. Do not read it back, move it, or rename it yourself. batchit
#' renames it into place, next to the other declared outputs, once your
#' function returns successfully.
#'
#' Use `style = "return"` instead when it's simpler for your function to
#' build R objects and return them in a named list. batchit then serializes
#' each one to its final path for you. Use `"staged_writer"` when your
#' function already writes files itself, for example in a format other than
#' `qs2`, or via another package's own writer. Your function then does not
#' have to build the whole object in memory, just to hand it to batchit to
#' save again.
#'
#' This only works while your function is actually running inside a batchit
#' worker, during a `style = "staged_writer"` item. Calling it at any other
#' time, or asking for a `name` this item didn't declare in `outputs`, is an
#' error.
#'
#' If your function is an inline function (see [run_and_write_files_atomically()]'s
#' `fn` argument), call it as `batchit::where_to_write_output()`. An
#' inline function may only call other packages' functions in
#' package-qualified form, and `batchit` is not automatically attached. If
#' your function instead lives in your own installed package, either import
#' `where_to_write_output` or call it the same package-qualified way.
#'
#' @param name The declared output name to write. Must be one of this
#'   item's `outputs` names.
#' @return A single absolute path string. WRITE to this path; do not read it
#'   back or move/rename it yourself. batchit renames it to the final
#'   destination once every declared output has been staged.
#' @examples
#' \donttest{
#' write_two_files <- function(x) {
#'   saveRDS(x^2, batchit::where_to_write_output("squared"))
#'   writeLines(as.character(x * 2), batchit::where_to_write_output("doubled"))
#'   invisible(NULL) # ignored by batchit for style = "staged_writer"
#' }
#'
#' out_dir <- file.path(tempdir(), "batchit-staged-example")
#' dir.create(out_dir)
#' run_and_write_files_atomically(
#'   fn = write_two_files,
#'   items = list(list(x = 2), list(x = 3)),
#'   outputs = list(
#'     c(squared = file.path(out_dir, "sq_1.rds"), doubled = file.path(out_dir, "db_1.txt")),
#'     c(squared = file.path(out_dir, "sq_2.rds"), doubled = file.path(out_dir, "db_2.txt"))
#'   ),
#'   style = "staged_writer",
#'   n_workers = 2
#' )
#' readRDS(file.path(out_dir, "sq_1.rds")) # 4
#' readLines(file.path(out_dir, "db_1.txt")) # "4"
#'
#' unlink(out_dir, recursive = TRUE)
#' }
#' @seealso [run_and_write_files_atomically()] and
#'   [stream_from_parent_and_write_files_atomically()], the two functions that
#'   establish the active run this reads from.
#'
#'   `vignette("batchit")` for the two rules that go with
#'   calling this inside `fn`.
#' @export
where_to_write_output <- function(name) {
  if (!isTRUE(.batch_stage_env$active)) {
    stop(
      paste0(
        "where_to_write_output(): no staged_writer run_and_write_files_atomically() run is active. It is ",
        "only callable from inside the target of a style = \"staged_writer\" run_and_write_files_atomically() item"
      ),
      call. = FALSE
    )
  }
  if (
    !is.character(name) || length(name) != 1L || is.na(name) || !nzchar(name)
  ) {
    stop(
      "where_to_write_output(): `name` must be a single non-empty string",
      call. = FALSE
    )
  }
  paths <- .batch_stage_env$paths
  if (!(name %in% names(paths))) {
    stop(
      sprintf(
        "where_to_write_output(): '%s' is not one of this item's declared outputs: %s",
        name,
        paste(names(paths), collapse = ", ")
      ),
      call. = FALSE
    )
  }
  paths[[name]]
}

#' Child-side declared-output commit (design DESIGN.md section 4.3)
#'
#' `fn_kind = "package"`; either commit style. Runs this 7-step sequence:
#'
#' 1. PREPARE every output temp. For `return`, validate the target's return
#'    names match the declared outputs EXACTLY, then qs2-serialize each value,
#'    in declaration order. For `staged_writer`, the target's return value is
#'    IGNORED: it streamed each output to `where_to_write_output(<name>)`
#'    instead, BEFORE this function is even called -- see `.batch_execute()`.
#'    So step 1 is then a pure ASSERTION that every declared output now exists
#'    at its pre-computed staging path, as a regular, non-symlink file. An
#'    undeclared or never-written name is an error, with zero renames.
#' 2. Prepare and close the marker temp.
#' 3. Verify every temp is a regular non-symlink file.
#' 4. Remove the OLD final marker and verify removal.
#' 5. Rename every output temp to its final path.
#' 6. Rename the marker temp to its final path LAST, the atomic commit point.
#' 7. Read back the marker and verify the attempt token, then emit the commit
#'    record.
#'
#' Steps 2-7 are IDENTICAL between the two styles. Only step 1 differs, in HOW
#' the output temp gets onto disk: written here, or already written by the
#' target.
#'
#' Total for the caller's purposes. On ANY failure, every temp or stage file
#' this call is tracking is removed, via `on.exit`, and the condition is
#' re-thrown. `.batch_execute()`'s outer `tryCatch` then turns it into the
#' usual structured error envelope. The failures are wrong or missing return
#' names (`return`), and a never-written declared output (`staged_writer`).
#' They also include a serialization failure, a rename failure, and a
#' marker-verification failure.
#'
#' A VALID final marker is the witness of a complete commit, never bare
#' pathname existence. A VALID marker is one that decodes, and whose protocol,
#' attempt token and committed-output map all verify. This function never
#' removes a temp AFTER it was renamed to a final path, because it is no
#' longer a temp at that point. It also never "rolls back" an already-renamed
#' final. A crash between two output renames leaves a torn state, with NO
#' valid marker to vouch for it. An unrelated marker left over from a PRIOR
#' attempt is NOT evidence of THIS attempt. That can happen when the crash
#' came before step 4 removed it. Only a marker whose attempt token matches is
#' evidence. That is exactly the point of the witness: nothing downstream may
#' trust a partial commit. See DESIGN.md section 4.3 for the full rationale.
#'
#' This is the one PARENT-adjacent function in this file that DOES read,
#' remove and replace the marker. That is by design. It runs in the CHILD, as
#' part of the commit, never as part of a launch decision (design section 1).
#'
#' @param value The target's raw return value. For `style = "return"` this
#'   must be a named list matching `outputs`; for `style = "staged_writer"`
#'   it is discarded entirely, unchecked. Never crosses back to the parent.
#' @param outputs Named character vector: declared output name -> final path
#'   (already parent-validated and normalized).
#' @param marker_path Final marker path (already parent-validated and
#'   normalized).
#' @param attempt This dispatch's attempt token (parent-issued).
#' @param style `"return"` or `"staged_writer"`.
#' @param stage_map For `style = "staged_writer"` only. It is the SAME
#'   declared name -> staging-temp-path map that [.batch_stage_paths_for()]
#'   computed. [.batch_stage_scope_enter()] entered that map BEFORE
#'   `do.call()` ran the target. `where_to_write_output()` and this function
#'   therefore agree on the exact paths. Ignored for `style = "return"`.
#' @return `list(committed = outputs, attempt = attempt)` -- the commit
#'   record.
#' @noRd
.batch_commit_task <- function(
  value,
  outputs,
  marker_path,
  attempt,
  style = "return",
  stage_map = NULL
) {
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
    if (
      !is.list(value) ||
        is.null(names(value)) ||
        anyDuplicated(names(value)) ||
        any(!nzchar(names(value))) ||
        !identical(sort(names(value)), sort(declared))
    ) {
      stop(
        sprintf(
          paste0(
            "batch commit: target must return a named list whose names are EXACTLY ",
            "the declared outputs {%s}; got {%s}"
          ),
          paste(declared, collapse = ", "),
          paste(names(value) %||% character(0), collapse = ", ")
        ),
        call. = FALSE
      )
    }
    out_tmp <- character(length(declared))
    names(out_tmp) <- declared
    for (nm in declared) {
      final <- outputs[[nm]]
      # Attempt-SCOPED temp name: `<basename>.<attempt>.tmp<random>`. The attempt
      # token is a unique, alphanumeric (glob-safe) nonce, so the parent-side
      # failure sweep can match ONLY this attempt's own temps -- never an unrelated
      # pre-existing file (e.g. a user's `out.qs2.tmp.backup`).
      tmp <- tempfile(
        pattern = paste0(basename(final), ".", attempt, ".tmp"),
        tmpdir = dirname(final)
      )
      pending <- c(pending, tmp)
      qs2::qs_save(value[[nm]], tmp)
      out_tmp[[nm]] <- tmp
    }
  } else {
    # style == "staged_writer": the target's return VALUE is unconditionally
    # ignored -- there is no return-name-match check for this style (that
    # check is `return`-only). `stage_map` names the EXACT paths
    # where_to_write_output() handed the target (pre-computed in .batch_execute()
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
        stop(
          sprintf(
            paste0(
              "batch commit: staged_writer target never wrote declared output '%s' ",
              "(expected a non-directory, non-symlink file at where_to_write_output('%s') = %s; ",
              "as at any output destination, base R cannot portably reject a ",
              "FIFO/socket/device special file the target may have created there)"
            ),
            nm,
            nm,
            p
          ),
          call. = FALSE
        )
      }
    }
    out_tmp <- stage_map
  }

  # --- step 2: prepare + close the marker temp ---------------------------------
  record <- list(
    protocol = .BATCH_PROTOCOL,
    attempt = attempt,
    committed = outputs
  )
  marker_tmp <- tempfile(
    pattern = paste0(basename(marker_path), ".", attempt, ".tmp"),
    tmpdir = dirname(marker_path)
  )
  pending <- c(pending, marker_tmp)
  qs2::qs_save(record, marker_tmp)

  # --- step 3: verify every temp is a regular, non-symlink file ----------------
  for (tp in c(out_tmp, marker_tmp)) {
    if (!file.exists(tp) || dir.exists(tp) || .batch_is_symlink(tp)) {
      stop(
        "batch commit: temp file is missing or not a regular file: ",
        tp,
        call. = FALSE
      )
    }
  }

  # --- step 4: remove the OLD final marker, verify removal ---------------------
  # The old marker must not survive into this attempt: if it did, and steps 5-7
  # below failed partway, a stale marker could keep vouching for outputs this
  # attempt has already started overwriting.
  if (file.exists(marker_path)) {
    unlink(marker_path, force = TRUE)
  }
  if (file.exists(marker_path)) {
    stop(
      "batch commit: could not remove the existing marker before committing: ",
      marker_path,
      call. = FALSE
    )
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
    stop(
      "batch commit: marker read-back attempt-token mismatch after commit",
      call. = FALSE
    )
  }

  ok <- TRUE
  list(committed = outputs, attempt = attempt)
}

# --- frontend: run_and_write_files_atomically() ------------------------------

#' Run a function once per item, in a fresh worker process, and have batchit write its output files safely
#'
#' Use this when each item's job is to produce one or more files. You get a
#' guarantee that a failed or interrupted item never leaves a half-written
#' file at its final path. Each item runs `fn` in its own, brand-new R process
#' (a worker), with up to `n_workers` running at the same time, like [run()]
#' and [run_and_collect()]. But `fn`'s return value does not cross back to
#' you. batchit writes the files you declared in `outputs`, and hands back a
#' small record of what it wrote.
#'
#' **The guarantee, and its boundary.** batchit stages every one of an item's
#' declared outputs before it replaces any final file. Each staged file goes
#' to a temporary file in its final destination's own directory. batchit then
#' replaces the final files one at a time, by rename, and writes the commit
#' marker last.
#'
#' The guarantee differs across those three phases.
#'
#' BEFORE THE FIRST REPLACEMENT: fully covered. The item can fail here in four
#' ways:
#' - an error in `fn`;
#' - a `"return"` value whose names do not match the declared outputs;
#' - a declared output a `"staged_writer"` never wrote;
#' - a failure serializing a staged file.
#'
#' In each case NO declared output is touched, and whatever was already at
#' those paths (or nothing, if they didn't exist) is left untouched. The
#' item's own previous marker is removed before the first replacement, so it
#' does not survive even here.
#'
#' DURING THE REPLACEMENT LOOP: not transactional. A kill or a rename failure
#' partway through it can leave some of the item's outputs replaced and others
#' not. batchit never rolls back a final it already renamed. An individual
#' file is not left half-written, since rename replacement is atomic under the
#' filesystem semantics batchit supports. But the SET can be torn, and a torn
#' set has no valid marker vouching for it.
#'
#' AFTER THE MARKER IS WRITTEN: committed, even if the call reports failure.
#' The worker serializes its result envelope only after it commits. A failure
#' in that window leaves every final and the marker correctly in place, while
#' the item is reported as failed.
#'
#' A `timeout` is NOT confined to one phase: it measures the worker's whole
#' lifetime and can land in any of the three, including mid-commit.
#'
#' batchit never treats an existing output file as a reason to skip an item.
#' It schedules every item, subject only to validation or an earlier failure
#' stopping the call first.
#'
#' There are two ways for `fn` to produce its declared outputs, chosen with
#' `style`:
#' - `style = "return"` (the default): `fn` returns a named list, one
#'   element per declared output, with names matching `outputs` exactly.
#'   batchit saves each value to its file, in the `qs2` format. Read it
#'   back with `qs2::qs_read()`.
#' - `style = "staged_writer"`: `fn` writes each output itself, to the path
#'   given by [where_to_write_output()]`(<name>)`; its return value is
#'   ignored. Use this when `fn` already writes files on its own, for
#'   example in a format other than `qs2`, or via another package's own
#'   writer. `fn` then does not have to build the whole object in memory,
#'   just to hand it back for batchit to save again.
#'
#' Use [run()] or [run_and_collect()] instead if you are happy to manage your
#' own output files without this guarantee. Use them also if you want a value
#' back in R rather than files on disk. Use
#' [stream_from_parent_and_write_files_atomically()] instead if building
#' every item up front (as a plain list, the way `items` works here) would
#' use too much memory.
#'
#' @param fn The function to run once per item. Either an inline function
#'   written directly in this call, or an object from [package_function()]
#'   naming a function in an installed package. An inline function must be
#'   self-contained: it may only use its own arguments, base R
#'   functions/operators, and `pkg::fun()`-qualified calls to other
#'   packages. That includes a call to [where_to_write_output()], which MUST
#'   be written as `batchit::where_to_write_output()`. See [run()]'s
#'   Advanced section for accepted and rejected examples.
#' @param items One entry per call. Each entry is a named list holding the
#'   arguments for that one call to `fn`. Every argument `fn` takes MUST be
#'   named, including one that has a default value. An omitted optional
#'   argument is treated as a mistake, not as "use the default". A named entry
#'   keeps its name as that item's id; an unnamed entry is identified by its
#'   position instead (1, 2, 3, and so on). An item id MUST NOT contain `/` or
#'   `\`, because batchit builds an internal bookkeeping filename from it; see
#'   `vignette("batchit")`.
#' @param outputs The files `fn` must produce for each item. One element per
#'   item, in the same order as `items`. When `items` is named, you may
#'   instead name `outputs` the same way, with the same names in any order.
#'   Each element is a named character vector giving the FINAL path for each
#'   declared output, e.g. `c(main = "/path/to/result.qs2")`. Every path MUST
#'   be absolute. Every destination MUST either not exist yet, or already be
#'   an ordinary file, not a directory and not a symlink. Every path, across
#'   every item in this one call, MUST be unique.
#' @param style `"return"` (the default) or `"staged_writer"`. See the
#'   description above for what each means for `fn`. Any other value
#'   errors.
#' @param n_workers How many items to run at the same time (a whole number,
#'   1 or more).
#' @param dev_path Advanced; see [run()]'s Advanced section. Leave as `NULL`
#'   (the default) to run the installed version of your package.
#' @param p A progress callback, such as a `progressr` progressor.
#' @param label An optional short label added to each progress message.
#' @param timeout Maximum time, in seconds, to let one item's worker run
#'   before killing it and reporting it as failed; see [run()].
#' @param target Deprecated former name of `fn`, kept for old callers. Pass
#'   `fn` instead; supplying both is an error.
#' @return A list, one element per item, **in the same order as `items`**,
#'   named by item id. Each element describes what was written. Its shape is
#'   `list(committed = <named character vector: output name -> final path
#'   actually written>, attempt = <an internal per-item identifier; you can
#'   ignore this>)`. Never `fn`'s raw return value.
#' @examples
#' \donttest{
#' # style = "return": fn returns a named list, and batchit saves each
#' # value to its declared path (as qs2 files).
#' make_two_values <- function(x) list(squared = x^2, doubled = x * 2)
#'
#' out_dir <- file.path(tempdir(), "batchit-return-example")
#' dir.create(out_dir)
#' result <- run_and_write_files_atomically(
#'   fn = make_two_values,
#'   items = list(list(x = 2), list(x = 3)),
#'   outputs = list(
#'     c(squared = file.path(out_dir, "sq_1.qs2"), doubled = file.path(out_dir, "db_1.qs2")),
#'     c(squared = file.path(out_dir, "sq_2.qs2"), doubled = file.path(out_dir, "db_2.qs2"))
#'   ),
#'   n_workers = 2
#' )
#' result
#' qs2::qs_read(file.path(out_dir, "sq_1.qs2")) # 4
#'
#' # style = "staged_writer": fn writes each output itself. See
#' # ?where_to_write_output for a complete example.
#'
#' unlink(out_dir, recursive = TRUE)
#' }
#' @family dispatch functions
#' @seealso [where_to_write_output()], which `fn` calls under
#'   `style = "staged_writer"`, and [write_qs2_atomically()] for the same
#'   rename-into-place guarantee on a single file with no dispatch.
#'
#'   `vignette("batchit")` states exactly what the
#'   atomic-write guarantee covers in each of its three phases.
#' @section Advanced:
#' Uses the same fresh-worker-per-item transport as [run()] and
#' [run_and_collect()], one `processx` subprocess per item. It also uses the
#' same code-identity check when `fn` is a [package_function()] reference. See
#' [run()]'s Advanced section for both.
#'
#' After an item commits successfully, batchit leaves a small bookkeeping
#' file named `.batchit__<item id>`, as its own record that this run finished
#' writing every declared file. There is ONE marker per item, in the
#' directory of that item's lexicographically first declared output path. That
#' is beside the outputs when they share a directory, and in one of them when
#' they do not. Do not create, read, or rely on a file with that name
#' yourself. batchit manages it entirely, and overwrites it cleanly the next
#' time that item id is committed.
#' @export
run_and_write_files_atomically <- function(
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
  # `target` is the DEPRECATED former name of `fn` (Unit 1/2 originally
  # shipped this parameter as `target = ...`; Unit 3 renamed it `fn` because
  # it now also accepts a bare closure). Preserve the old NAMED spelling.
  if (!is.null(target)) {
    if (!missing(fn)) {
      stop(
        paste0(
          "run_and_write_files_atomically(): pass `fn` only -- `target` is the deprecated ",
          "former name of `fn`; do not pass both"
        ),
        call. = FALSE
      )
    }
    fn <- target
  }
  # `fn` is EITHER a package_function() descriptor (fn_kind = "package") OR a bare
  # closure (fn_kind = "adhoc", Phase 6' Unit 3) -- resolved here, ONCE, into
  # the two variables (`fn_kind`, and either `target` or a lint-passed,
  # baseenv()-rebased `fn`) every step below branches on.
  if (inherits(fn, "package_function")) {
    fn_kind <- "package"
    target <- fn
    formal_names <- target$formal_names
  } else if (is.function(fn)) {
    fn_kind <- "adhoc"
    .batch_lint_adhoc_fn(fn, where = "parent")
    fn <- .batch_rebase_adhoc_closure(fn)
    formal_names <- names(formals(fn))
    if (is.null(formal_names)) {
      formal_names <- character(0)
    }
    target <- NULL
  } else {
    stop(
      paste0(
        "run_and_write_files_atomically(): `fn` must come from package_function() (fn_kind = ",
        "\"package\") or be a bare closure (fn_kind = \"adhoc\")"
      ),
      call. = FALSE
    )
  }
  if (
    !is.character(style) ||
      length(style) != 1L ||
      is.na(style) ||
      !nzchar(style)
  ) {
    stop(
      "run_and_write_files_atomically(): `style` must be a single non-empty string",
      call. = FALSE
    )
  }
  if (!(style %in% c("return", "staged_writer"))) {
    stop(
      sprintf(
        "run_and_write_files_atomically(): unknown style '%s' (must be \"return\" or \"staged_writer\")",
        style
      ),
      call. = FALSE
    )
  }
  n_workers <- .batch_validate_n_workers(
    n_workers,
    "run_and_write_files_atomically()"
  )
  # Validate ALL config BEFORE the empty-workload early return -- otherwise a
  # bad dev_path/timeout is silently accepted whenever there is no work.
  timeout <- .batch_validate_timeout(
    timeout,
    "run_and_write_files_atomically()"
  )
  # For "package", dev_path names the CONSUMER's tree (target$package). For
  # "adhoc" there is no consumer identity -- dev_path instead names BATCHIT'S
  # OWN tree (see run()'s dev_path doc; the worker interprets it the
  # same way).
  dev_path <- .batch_validate_dev_path(
    dev_path,
    if (identical(fn_kind, "package")) target$package else "batchit"
  )
  if (!is.list(items)) {
    stop(
      sprintf(
        "run_and_write_files_atomically(): `items` must be a list, got %s",
        class(items)[1L]
      ),
      call. = FALSE
    )
  }
  if (!is.list(outputs)) {
    stop(
      sprintf(
        "run_and_write_files_atomically(): `outputs` must be a list, got %s",
        class(outputs)[1L]
      ),
      call. = FALSE
    )
  }
  if (length(outputs) != length(items)) {
    stop(
      sprintf(
        "run_and_write_files_atomically(): `outputs` must have the same length as `items` (%d), got %d",
        length(items),
        length(outputs)
      ),
      call. = FALSE
    )
  }

  n_items <- length(items)
  if (n_items == 0L) {
    return(list())
  }

  # Stable per-item ids (item names, else the index) -- shared with run()/run_and_collect().
  ids <- .batch_item_ids(items)
  # `.batch_task_marker_path()` interpolates the id straight into a filename
  # (`.batchit__<id>`); a `/` or `\` in an id would place that marker in a
  # different (possibly nonexistent) subdirectory than the one just
  # validated. ids come from item NAMES, so a path separator in one is the
  # caller's error -- reject it loudly rather than let it silently derive a
  # broken marker path.
  bad_ids <- ids[grepl("[/\\\\]", ids, perl = TRUE)]
  if (length(bad_ids) > 0L) {
    stop(
      sprintf(
        paste0(
          "run_and_write_files_atomically(): item id(s) must not contain '/' or '\\\\' (interpolated into the ",
          "per-item marker filename .batchit__<id>): %s"
        ),
        paste(unique(bad_ids), collapse = ", ")
      ),
      call. = FALSE
    )
  }
  outputs <- .batch_align_outputs_to_ids(
    outputs,
    ids,
    "run_and_write_files_atomically()"
  )

  # Validate EVERY item's args and EVERY item's output map up front (not just
  # the first): item schemas are legitimately heterogeneous, so a bad one hides
  # behind a good first one.
  for (i in seq_len(n_items)) {
    if (identical(fn_kind, "package")) {
      .batch_validate_item(target, items[[i]], where = "parent", id = ids[i])
    } else {
      .batch_validate_adhoc_item(
        formal_names,
        items[[i]],
        where = "parent",
        id = ids[i]
      )
    }
  }
  for (i in seq_len(n_items)) {
    .batch_validate_output_map(outputs[[i]], where = "parent", id = ids[i])
  }
  outputs <- lapply(seq_len(n_items), function(i) {
    .batch_validate_output_paths(outputs[[i]], ids[i])
  })
  markers <- vapply(
    seq_len(n_items),
    function(i) {
      .batch_task_marker_path(outputs[[i]], ids[i])
    },
    character(1)
  )
  # Invocation-wide collision check: every output AND every marker, across all
  # items -- see the file banner for why the marker check is pathname-only.
  .batch_check_task_collisions(outputs, markers, ids)

  attempts <- vapply(
    seq_len(n_items),
    function(i) .batch_new_attempt_token(),
    character(1)
  )
  # fn_kind == "adhoc" (design section 7): a fresh
  # per-dispatch identity nonce, echoed back by the child and checked by
  # .batch_inspect_result() in place of the package/symbol/hash identity a
  # package_function descriptor would otherwise supply. Unused (stays NULL) for
  # "package" -- the commit-record attempt-token check already binds identity
  # there.
  nonces <- if (identical(fn_kind, "adhoc")) {
    vapply(
      seq_len(n_items),
      function(i) .batch_new_attempt_token(),
      character(1)
    )
  } else {
    NULL
  }

  script_path <- .batch_worker_script()
  rscript_bin <- file.path(R.home("bin"), "Rscript")

  input_paths <- vapply(
    seq_len(n_items),
    function(i) {
      tempfile(pattern = paste0("batch_in_", i, "_"), fileext = ".qs2")
    },
    character(1)
  )
  output_paths <- vapply(
    seq_len(n_items),
    function(i) {
      tempfile(pattern = paste0("batch_out_", i, "_"), fileext = ".qs2")
    },
    character(1)
  )
  # Per-item stdout/stderr goes to a file, not a pipe -- see run()/run_and_collect()'s log
  # handling, which this mirrors exactly.
  log_paths <- vapply(
    seq_len(n_items),
    function(i) {
      tempfile(pattern = paste0("batch_log_", i, "_"), fileext = ".log")
    },
    character(1)
  )

  on.exit(
    {
      unlink(input_paths, force = TRUE)
      unlink(output_paths, force = TRUE)
      unlink(log_paths, force = TRUE)
    },
    add = TRUE
  )

  # --vanilla does not reproduce the parent's library path; force it via
  # R_LIBS before startup, exactly like run()/run_and_collect().
  worker_env <- c(
    "current",
    R_LIBS = paste(.libPaths(), collapse = .Platform$path.sep)
  )

  runner_pkg <- .batch_runner_package()
  for (i in seq_len(n_items)) {
    envelope <- if (identical(fn_kind, "package")) {
      .batch_input_envelope(
        target,
        dev_path,
        runner_pkg,
        ids[i],
        items[[i]],
        outputs = outputs[[i]],
        marker = markers[i],
        style = style,
        attempt = attempts[i]
      )
    } else {
      .batch_input_envelope(
        target = NULL,
        dev_path = dev_path,
        runner = runner_pkg,
        id = ids[i],
        args = items[[i]],
        fn_kind = "adhoc",
        outputs = outputs[[i]],
        marker = markers[i],
        style = style,
        attempt = attempts[i],
        fn = fn,
        nonce = nonces[i]
      )
    }
    .batch_write_envelope(envelope, input_paths[i])
  }

  active <- list()
  n_done <- 0L
  next_item <- 1L
  results <- vector("list", n_items)

  on.exit(
    {
      for (entry in active) {
        tryCatch(entry$proc$kill_tree(), error = function(e) NULL)
        # kill_tree() cannot let the child's own on.exit run, so sweep this
        # killed item's attempt-scoped commit temps here too. Without this, a
        # sibling item failing while THIS one is mid-commit leaves exactly the
        # SIGKILL orphan the sweep exists to prevent. (No-op on normal exit:
        # `active` is empty once every item has been collected.)
        tryCatch(
          .batch_sweep_task_temps(
            outputs[[entry$idx]],
            markers[entry$idx],
            attempts[entry$idx]
          ),
          error = function(e) NULL
        )
      }
    },
    add = TRUE,
    after = FALSE
  )

  if (is.null(p)) {
    message(sprintf("  [0/%d] dispatching workers...", n_items))
  }

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
  # surface its log tail, then stop. Identical shape to run()/run_and_collect()'s
  # .fail(), tagged with run_and_write_files_atomically() in the message.
  .fail <- function(entry, what) {
    idx <- entry$idx
    .batch_sweep_task_temps(outputs[[idx]], markers[idx], attempts[idx])
    tail_txt <- .batch_log_tail(log_paths[idx])
    if (nzchar(trimws(tail_txt))) {
      message(sprintf(
        "\n--- item '%s' failed ---\nOUTPUT (stdout+stderr):\n%s\n---",
        ids[idx],
        tail_txt
      ))
    }
    stop(
      sprintf("run_and_write_files_atomically(): item '%s' %s", ids[idx], what),
      call. = FALSE
    )
  }

  # Read + validate one finished item's result envelope while its log is still
  # on disk. Passes THIS item's dispatched outputs/attempt to the inspector so
  # the returned commit record is checked against what was actually sent, not
  # merely well-formed.
  .collect <- function(entry) {
    idx <- entry$idx
    exit_status <- entry$proc$get_exit_status()
    if (!is.null(exit_status) && exit_status != 0L) {
      .fail(
        entry,
        sprintf("worker exited %d before writing a result", exit_status)
      )
    }
    path <- output_paths[idx]
    if (!file.exists(path)) {
      .fail(entry, sprintf("produced no result envelope: %s", path))
    }
    envelope <- tryCatch(
      .batch_read_envelope(path),
      error = function(e) {
        .fail(
          entry,
          sprintf(
            "wrote an unreadable result envelope (%s): %s",
            path,
            conditionMessage(e)
          )
        )
      }
    )
    insp <- if (identical(fn_kind, "package")) {
      .batch_inspect_result(
        envelope,
        ids[idx],
        target,
        expected_outputs = outputs[[idx]],
        expected_attempt = attempts[idx]
      )
    } else {
      .batch_inspect_result(
        envelope,
        ids[idx],
        target = NULL,
        expected_outputs = outputs[[idx]],
        expected_attempt = attempts[idx],
        expected_nonce = nonces[idx]
      )
    }
    if (!insp$ok) {
      .fail(entry, insp$reason)
    }
    .batch_surface_warnings(insp$warnings, ids[idx])
    insp$value
  }

  repeat {
    while (length(active) < n_workers && next_item <= n_items) {
      active[[length(active) + 1L]] <- .launch(next_item)
      next_item <- next_item + 1L
    }
    if (length(active) == 0L) {
      break
    }

    still_active <- list()
    for (entry in active) {
      if (!entry$proc$is_alive()) {
        value <- .collect(entry)
        # results[idx] <- list(value), NOT results[[idx]] <- value: the usual
        # NULL-deletion trap (see run()/run_and_collect()) -- moot here in practice (a
        # commit record is never NULL), kept for consistency/robustness.
        results[entry$idx] <- list(value)
        unlink(log_paths[entry$idx], force = TRUE)
        n_done <- n_done + 1L
        if (!is.null(p)) {
          p(
            message = paste(
              c(label, ids[entry$idx], format(Sys.time(), "%H:%M:%S")),
              collapse = " "
            )
          )
        } else if (
          n_done == n_items || n_done %% max(1L, n_items %/% 20L) == 0L
        ) {
          message(sprintf(
            "  [%d/%d] complete  %s",
            n_done,
            n_items,
            format(Sys.time(), "%H:%M:%S")
          ))
        }
      } else if (
        is.finite(timeout) &&
          as.numeric(difftime(Sys.time(), entry$started, units = "secs")) >
            timeout
      ) {
        tryCatch(entry$proc$kill_tree(), error = function(e) NULL)
        .fail(
          entry,
          sprintf("exceeded the %g s timeout and was killed", timeout)
        )
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

# Execution for the dispatcher in R/batch.R. The child side resolves the target
# and runs one envelope. It never throws. The parent side is .batch_run_impl(),
# the shape-A worker pool behind run() and run_and_collect().

# --- child-side execution ----------------------------------------------------

#' Resolve and verify a target in the child process
#'
#' The child may have loaded a different code version than the parent hashed
#' (installed vs dev, or a stale dev tree). If the target's body/formals hash
#' differs, refuse: running a different version than the parent dispatched is the
#' stale-code hole the descriptor exists to close.
#'
#' Note the deliberate NARROWNESS: the hash covers the target's own body and
#' formals only. This is a settled decision. It matches the body+formals
#' identity used for cache/replay in the originating pipeline. A changed
#' HELPER the target calls, a namespace constant it closes over, an S4/R6
#' method table, or a dependency's version are outside it. So this guarantees
#' "same target definition", not "provably identical behaviour" -- the latter
#' is not claimed.
#' @noRd
.batch_resolve_target <- function(meta) {
  # Exact `[[` on the untrusted meta (never `$`, which partial-matches).
  target <- package_function(
    meta[["package"]],
    meta[["symbol"]],
    version = meta[["version"]]
  )
  if (!identical(target$hash, meta[["hash"]])) {
    stop(
      sprintf(
        paste0(
          ".batch_worker: %s::%s resolved to a DIFFERENT code version ",
          "than the parent dispatched (parent hash %s, child hash %s). ",
          "Refusing to run -- check the dev path / installed package version."
        ),
        meta[["package"]],
        meta[["symbol"]],
        meta[["hash"]],
        target$hash
      ),
      call. = FALSE
    )
  }
  return(target)
}

#' Execute one envelope in the child and build the result envelope
#'
#' Total by design: it always returns a result envelope, never throws. Every
#' failure the child can hit is caught into ONE structured error envelope,
#' with status "error", value NULL and `error$message`. The failures are
#' target resolution, the hash mismatch, child-side item re-validation, and
#' the target's own R-level errors. That uniformity is the point. Every
#' frontend surfaces every failure the same way. `run()`, `run_and_collect()`
#' and `run_and_write_files_atomically()` read a file;
#' `stream_from_parent_and_write_files_atomically()` reads a daemon return.
#' Without the uniformity, a resolve error would crash the worker while a
#' target error returned an envelope. `meta$collect == FALSE` drops the value
#' entirely. Shape-A direct-writers put gigabytes on disk themselves. The
#' whole architecture exists so those never cross back to the parent; only the
#' status does.
#' @noRd
.batch_execute <- function(env) {
  # The reported id lets the parent match a result to the item it dispatched;
  # extract it defensively so even a malformed envelope carries one (or NA).
  # Exact `[[` throughout (never `$`, which partial-matches an untrusted field).
  id <- tryCatch(env[["meta"]][["id"]], error = function(e) NA_character_)

  outcome <- tryCatch(
    {
      .batch_check_envelope(env)
      meta <- env[["meta"]]
      fn_kind <- meta[["fn_kind"]]
      if (identical(fn_kind, "package")) {
        target <- .batch_resolve_target(meta)
        .batch_validate_item(
          target,
          env[["args"]],
          where = "child",
          id = meta[["id"]]
        )
        fn <- get(
          meta[["symbol"]],
          envir = asNamespace(meta[["package"]]),
          inherits = FALSE
        )
        result_target <- list(
          package = target$package,
          symbol = target$symbol,
          hash = target$hash
        )
      } else {
        # fn_kind == "adhoc" (Phase 6' Unit 3): .batch_check_envelope() above
        # already re-linted meta$fn for self-containedness (design section 6)
        # and required meta$nonce -- there is no package/symbol to resolve.
        # Rebase AGAIN defensively right before do.call(): the parent already
        # rebased onto baseenv() before serializing (and qs2 round-trips a
        # baseenv()-rooted closure by RECONNECTING to the child's own
        # baseenv(), not by carrying a snapshot -- see .batch_rebase_adhoc_closure()),
        # but a hand-crafted envelope reaching the worker directly (bypassing
        # run()/run_and_collect()/run_and_write_files_atomically()) must never
        # get to run an un-rebased closure just because it happened to still
        # pass the lint.
        fn <- .batch_rebase_adhoc_closure(meta[["fn"]])
        fmls <- names(formals(fn))
        if (is.null(fmls)) {
          fmls <- character(0)
        }
        .batch_validate_adhoc_item(
          fmls,
          env[["args"]],
          where = "child",
          id = meta[["id"]]
        )
        result_target <- list(fn_kind = "adhoc", nonce = meta[["nonce"]])
      }

      # style/outputs are already both-fully-validated by .batch_check_envelope()
      # above -- BEFORE do.call() ever runs the target: style is one of
      # "return"/"staged_writer" whenever outputs is present, NULL otherwise.
      outputs <- meta[["outputs"]]
      style <- meta[["style"]]
      task_dispatch <- !is.null(outputs)

      stage_map <- NULL
      staged <- task_dispatch && identical(style, "staged_writer")
      stage_prior <- NULL
      if (staged) {
        # Pre-compute EVERY declared output's staging path BEFORE do.call()
        # (design DESIGN.md section 4.4), and register them for cleanup
        # in THIS frame: a target that errors PARTWAY through streaming never
        # reaches .batch_commit_task(), so only an on.exit registered before
        # do.call() still fires. Safe through a successful commit too -- by then
        # every path has been renamed away, so unlink() on an absent path is a
        # no-op. Then enter scope so where_to_write_output() can answer.
        stage_map <- .batch_stage_paths_for(outputs, meta[["attempt"]])
        on.exit(unlink(stage_map, force = TRUE), add = TRUE)
        stage_prior <- .batch_stage_scope_enter(stage_map)
      }

      # Capture the target's warnings into the envelope instead of letting them
      # scroll off into a log the parent deletes on success. This matters for a
      # target that catches a downstream failure, WARNs, and still returns a
      # partial (status "ok") result -- without this the incomplete result would
      # be stored with no word to the parent.
      warns <- character()
      value <- tryCatch(
        withCallingHandlers(
          do.call(fn, env[["args"]]),
          warning = function(w) {
            warns[[length(warns) + 1L]] <<- .batch_condition_message(w)
            invokeRestart("muffleWarning")
          }
        ),
        # Exit the staged_writer scope the INSTANT the target returns or
        # errors -- NOT during the commit below. where_to_write_output() must
        # be answerable ONLY while the target itself runs (design section
        # 4.4); leaving it active through the commit would let e.g. a classed
        # `outputs` map's `[[` method reach it after the target is done.
        finally = {
          if (staged) .batch_stage_scope_exit(stage_prior)
        }
      )

      if (is.null(outputs)) {
        list(
          status = "ok",
          value = if (isTRUE(meta[["collect"]])) value else NULL,
          error = NULL,
          warnings = utils::head(warns, 100L),
          target = result_target
        )
      } else {
        # Declared-output commit dispatch (run_and_write_files_atomically(),
        # design DESIGN.md section 4.3). The raw target `value` is
        # discarded after commit (unconditionally for staged_writer, or once
        # matched against `outputs` for return) -- it never crosses back,
        # only the small commit record does.
        commit <- .batch_commit_task(
          value,
          outputs,
          meta[["marker"]],
          meta[["attempt"]],
          style = style,
          stage_map = stage_map
        )
        list(
          status = "ok",
          value = commit,
          error = NULL,
          warnings = utils::head(warns, 100L),
          target = result_target
        )
      }
    },
    error = function(e) {
      return(list(
        status = "error",
        value = NULL,
        error = list(
          message = .batch_condition_message(e),
          call = tryCatch(
            paste(deparse(conditionCall(e)), collapse = " "),
            error = function(e2) "<unprintable call>"
          )
        ),
        warnings = character(),
        target = NULL
      ))
    }
  )

  return(list(
    protocol = .BATCH_PROTOCOL,
    id = id,
    status = outcome$status,
    value = outcome$value,
    error = outcome$error,
    warnings = outcome$warnings,
    target = outcome$target
  ))
}

# --- shape A: fresh subprocess per item, via processx ------------------------

#' Shared shape-A transport: run `fn` on each of a fixed list of items
#'
#' The ONE internal implementation behind [run()], [run_and_collect()], and
#' (via a bare closure) the former ad-hoc-closure frontend. It is folded in
#' here rather than kept as a separate frontend. The package-vs-closure choice
#' is a property of the `fn` argument's TYPE, not a separate function name.
#'
#' `fn` is EITHER a `package_function` descriptor from [package_function()]
#' (`fn_kind = "package"`) OR a bare closure (`fn_kind = "adhoc"`). A closure
#' must be self-contained: base R, `pkg::`-qualified calls, and its own
#' formals only -- see `.batch_lint_adhoc_fn()`. It must not be a primitive,
#' and it must not take `...`. That self-containedness LINT gates it, and
#' batchit unconditionally rebases it onto `baseenv()` before it is ever
#' serialized (see `.batch_rebase_adhoc_closure()`). Production and auditable
#' stages SHOULD prefer a `package_function()` descriptor, which is
#' hash-verified and resolvable by package+symbol. `adhoc` dispatch is for
#' throwaway or exploratory work, where that overhead is not the point.
#'
#' Shape A of the contract: the items already exist. Each is a small named
#' list of `fn`'s formals, and the worker opens its own data. So a fresh R
#' process per item is not a cost to amortise, but the memory strategy itself.
#' A large analysis item can peak at tens of GB, and R does not return that
#' memory to the OS. Process exit is how it is reclaimed. This is why batchit
#' does NOT reuse workers: worker reuse would defeat exactly this.
#'
#' The contract this transport enforces:
#' * both-end validation;
#' * a hash-verified target descriptor, or, for `adhoc`, a per-dispatch
#'   identity nonce;
#' * per-item logs written to files, never pipes -- a chatty worker that fills
#'   the OS pipe buffer is what deadlocks a pipe transport;
#' * a bounded log tail on failure;
#' * a loud stop on the first failure.
#'
#' Warnings a target captures are surfaced in the parent, tagged by item id.
#'
#' batchit is thread-agnostic: it sets no BLAS / data.table thread counts and
#' passes none to the worker. If `fn` is itself multi-threaded, dividing
#' cores across `n_workers` (to avoid oversubscription) is the CONSUMER's
#' responsibility, not the runner's.
#'
#' The worker script is always the runner's (batchit's). `dev_path`, when
#' given, is the CONSUMER's source tree for `fn_kind = "package"`. For
#' `fn_kind = "adhoc"` it is batchit's own source tree instead, because an
#' adhoc closure has no separate consumer identity to load. When runner and
#' consumer differ, the worker loads both: the consumer via
#' `dev_path`/`requireNamespace`, the runner via `requireNamespace`.
#'
#' @param fn EITHER a `package_function` descriptor from [package_function()]
#'   OR a bare closure -- see the details above.
#' @param items List of items; each a fully-named list of `fn`'s formals.
#'   Named items keep their name as the item id; unnamed items get their index.
#' @param n_workers Concurrent subprocesses (validated: finite, whole, >= 1).
#' @param dev_path Source tree for `devtools::load_all()` in the worker, or
#'   `NULL` for the installed package. A given-but-wrong path errors rather
#'   than silently falling back to installed code.
#' @param collect If `TRUE`, return each item's value in item order. If
#'   `FALSE`, the worker still reports status, but its value never crosses
#'   back. Use `FALSE` for targets that write their output themselves.
#' @param p A progress callback such as a `progressr` progressor, or `NULL`. It
#'   is called once per completed item with `message = <id and time>`.
#' @param label Optional short stage tag prefixed to the progress message.
#' @param timeout Per-item wall-clock limit in seconds; a worker that exceeds it
#'   is killed and reported as a failure. Defaults to a generous hang-catcher
#'   (the internal `.BATCH_DEFAULT_TIMEOUT`, 6 hours); pass `Inf` to disable.
#' @param .caller The public-facing caller name (`"run"` or `"run_and_collect"`),
#'   used only to make error/label strings read correctly.
#' @return If `collect`, a list of values in item order; else `invisible(NULL)`.
#' @noRd
.batch_run_impl <- function(
  fn,
  items,
  n_workers,
  dev_path = NULL,
  collect,
  p = NULL,
  label = NULL,
  timeout = .BATCH_DEFAULT_TIMEOUT,
  .caller
) {
  # `fn` is EITHER a package_function() descriptor (fn_kind = "package") OR a bare
  # closure (fn_kind = "adhoc", folded in from the former ad-hoc-closure
  # frontend) -- resolved
  # here, ONCE, into the two variables (`fn_kind`, and either `target` or a
  # lint-passed, baseenv()-rebased `fn`) every step below branches on. Mirrors
  # run_and_write_files_atomically()'s identical dispatch (the declared-output
  # commit-engine source file).
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
      sprintf(
        "%s(): `fn` must come from package_function() or be a function",
        .caller
      ),
      call. = FALSE
    )
  }

  n_workers <- .batch_validate_n_workers(n_workers, sprintf("%s()", .caller))
  # Validate ALL config BEFORE the empty-workload early return -- otherwise a bad
  # dev_path/timeout/collect is silently accepted whenever there is no work.
  collect <- .batch_validate_collect(collect, sprintf("%s()", .caller))
  timeout <- .batch_validate_timeout(timeout, sprintf("%s()", .caller))
  # For "package", dev_path names the CONSUMER's tree (target$package). For
  # "adhoc" there is no consumer identity -- dev_path instead names BATCHIT'S
  # OWN tree (an adhoc closure has no separate consumer identity to load).
  dev_path <- .batch_validate_dev_path(
    dev_path,
    if (identical(fn_kind, "package")) target$package else "batchit"
  )
  # `items` must be a LIST of items, checked before the empty-workload return so
  # an empty atomic (character(0)/numeric(0)) cannot slip past the container
  # contract while a non-empty atomic would be rejected.
  if (!is.list(items)) {
    stop(
      sprintf(
        "%s(): `items` must be a list, got %s",
        .caller,
        class(items)[1L]
      ),
      call. = FALSE
    )
  }

  n_items <- length(items)
  if (n_items == 0L) {
    return(if (collect) list() else invisible(NULL))
  }

  # Stable per-item ids (item names, else the index), validated unique so a
  # reported failure identifies exactly the right item.
  ids <- .batch_item_ids(items)

  # Validate EVERY item up front (not items[[1]]): item schemas are legitimately
  # heterogeneous, so a bad one hides behind a good first one.
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

  # fn_kind == "adhoc": a fresh, high-entropy per-item identity nonce -- an
  # adhoc envelope has no package/symbol/hash for the parent to check the
  # result against, so this token (echoed back by the child) takes that role.
  # Unused (stays NULL) for "package".
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
      return(tempfile(pattern = paste0("batch_in_", i, "_"), fileext = ".qs2"))
    },
    character(1)
  )
  output_paths <- vapply(
    seq_len(n_items),
    function(i) {
      return(tempfile(pattern = paste0("batch_out_", i, "_"), fileext = ".qs2"))
    },
    character(1)
  )
  # Per-item stdout/stderr goes to a file, not a pipe -- the pipe's fixed OS
  # buffer is what deadlocks a chatty worker. "Bounded" here is about RAM: only
  # the last 64 KB is ever read back (.batch_log_tail), so a huge log never OOMs
  # the PARENT. The on-disk file is transient (unlinked per item) and its size is
  # bounded in practice by `timeout` (write-rate x wall-clock); a truly
  # pathological infinite-printer is caught by that, not by an fs-level cap.
  log_paths <- vapply(
    seq_len(n_items),
    function(i) {
      return(tempfile(pattern = paste0("batch_log_", i, "_"), fileext = ".log"))
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

  # --vanilla does not reproduce the parent's library path, and .libPaths cannot
  # travel in the payload (the child needs qs2 to READ the payload). Force it via
  # R_LIBS before startup. "current" keeps the rest of the environment inherited.
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
        collect = collect
      )
    } else {
      .batch_input_envelope(
        target = NULL,
        dev_path = dev_path,
        runner = runner_pkg,
        id = ids[i],
        args = items[[i]],
        fn_kind = "adhoc",
        collect = collect,
        fn = fn,
        nonce = nonces[i]
      )
    }
    .batch_write_envelope(envelope, input_paths[i])
  }

  active <- list()
  n_done <- 0L
  next_item <- 1L
  results <- if (collect) vector("list", n_items) else NULL

  on.exit(
    {
      for (entry in active) {
        tryCatch(entry$proc$kill_tree(), error = function(e) NULL)
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
    return(list(proc = proc, idx = idx, started = Sys.time()))
  }

  # A worker failed -- surface its log tail, then stop (the loud error path;
  # nothing about the failed item is persisted). One place, so every failure path
  # (nonzero exit, missing/unreadable envelope, error status, timeout) reports
  # the same way.
  .fail <- function(entry, what) {
    idx <- entry$idx
    tail_txt <- .batch_log_tail(log_paths[idx])
    if (nzchar(trimws(tail_txt))) {
      message(sprintf(
        "\n--- item '%s' failed ---\nOUTPUT (stdout+stderr):\n%s\n---",
        ids[idx],
        tail_txt
      ))
    }
    stop(sprintf("%s(): item '%s' %s", .caller, ids[idx], what), call. = FALSE)
  }

  # Read + validate one finished item's result envelope while its log is still on
  # disk. A zero exit status is not a result: the worker can exit 0 having
  # written nothing (killed after opening the file), or the target can have
  # returned an error envelope. Both are failures here.
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
        return(.fail(
          entry,
          sprintf(
            "wrote an unreadable result envelope (%s): %s",
            path,
            conditionMessage(e)
          )
        ))
      }
    )
    insp <- if (identical(fn_kind, "package")) {
      .batch_inspect_result(envelope, ids[idx], target)
    } else {
      .batch_inspect_result(
        envelope,
        ids[idx],
        target = NULL,
        expected_nonce = nonces[idx]
      )
    }
    if (!insp$ok) {
      .fail(entry, insp$reason)
    }
    .batch_surface_warnings(insp$warnings, ids[idx])
    return(insp$value)
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
        # results[idx] <- list(value), NOT results[[idx]] <- value: assigning a
        # NULL value with [[<- DELETES the element, shortening the list and
        # shifting every result gathered after it. Completion is in worker-finish
        # order, so a NULL item finishing after a higher slot is filled corrupts
        # positions. Single-bracket-with-list() assigns the NULL in place.
        if (collect) {
          results[entry$idx] <- list(value)
        }
        unlink(log_paths[entry$idx], force = TRUE)
        n_done <- n_done + 1L
        if (!is.null(p)) {
          # The tick names the completed ITEM, not just a timestamp: on a
          # multi-day stage the operator needs "which unit just finished", and
          # the stable id is sitting right here.
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

  if (collect) return(results) else return(invisible(NULL))
}

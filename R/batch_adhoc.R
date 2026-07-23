# Phase 6' Unit 3 (see PHASE6_DESIGN.md sections 1, 2, 4, 5, 9.4): the `adhoc`
# fn_kind -- dispatch a bare closure VALUE instead of a package_function()
# descriptor. Gated by a best-effort static self-containedness LINT
# (codetools::findGlobals()) applied at BOTH ends (parent: early UX at
# dispatch time -- batch_fn() / batch_task() with a bare closure; child:
# correctness, inside .batch_check_envelope() -- a worker must never simply
# trust that an envelope reaching it actually went through a frontend's own
# check). A closure that PASSES the lint is unconditionally rebased onto
# baseenv() before it is ever serialized, which severs its original enclosing
# environment -- closing the large/secret environment carriage path the lint
# itself cannot detect (see .batch_rebase_adhoc_closure()): proven by hand
# that qs2 round-trips a closure's ORIGINAL custom environment intact (an
# object bound there survives serialization whole), while a baseenv()-rooted
# closure reconnects to the receiving session's OWN baseenv() instead.
#
# NARROWED PROMISE (design section 5): this is a best-effort static lint that
# rejects DIRECTLY DETECTABLE unqualified global references. It does NOT
# prove behavioural closure, hermetic execution, portability, or dependency
# identity. Known blind spots: get()/mget()/assign()/a string-argument
# do.call(), eval(parse(...)), substitute(), .GlobalEnv, a formula's/
# attribute's own environment, <<-, S4/R5/R6 method dispatch, and any other
# ambient state a closure can reach without a syntactically visible free
# variable. Production stages stay on fn_kind = "package" (a hash-verified,
# auditable descriptor); fn_kind = "adhoc" is for ad-hoc dispatch only.

#' Self-containedness lint for an adhoc closure (design PHASE6_DESIGN.md section 5)
#'
#' Runs at BOTH ends: a frontend (`batch_fn()` / `batch_task()` with a bare
#' closure) calls this at dispatch time for early UX; `.batch_check_envelope()`
#' calls it again in the CHILD, because a worker must never simply trust that
#' whatever reached it over the wire actually passed a frontend's own check.
#'
#' Rejects, in order, NAMING the offending symbol(s) where relevant:
#' * a non-function;
#' * a primitive (no real formals/body/environment to lint or rebase);
#' * a closure whose formals include `...` (same prohibition as a package
#'   [package_function()]);
#' * a closure referencing any global -- inspecting BOTH
#'   `codetools::findGlobals()`'s `$functions` and `$variables` -- that is
#'   neither (a) bound in `baseenv()` (covers every base function, base
#'   operator, and base constant: `+`, `if`, `{`, `::`, `T`, `pi`, ...) nor
#'   (b) a `pkg::`/`pkg:::`-qualified reference (verified: codetools does not
#'   resolve the identifiers either side of `::`/`:::` as globals -- only the
#'   `::`/`:::` call itself is reported, and that call is itself a base
#'   function, so `pkg::fun()` is never independently flagged).
#'
#' @param fn Candidate closure.
#' @param where "parent" or "child", for the error message.
#' @param id Optional item id, for the error message.
#' @return `TRUE`, invisibly; stops on any violation.
#' @noRd
.batch_lint_adhoc_fn <- function(fn, where = "parent", id = NULL) {
  loc <- if (is.null(id)) "" else sprintf(" [item '%s']", id)
  lead <- sprintf(".batch adhoc %s-validation%s", where, loc)

  if (!is.function(fn)) {
    stop(sprintf("%s: adhoc `fn` must be a function, got %s", lead, class(fn)[1L]),
      call. = FALSE)
  }
  if (is.primitive(fn)) {
    stop(sprintf(paste0(
      "%s: adhoc `fn` must be a closure, not a primitive -- a primitive has ",
      "no real formals/body/environment to lint or rebase"), lead), call. = FALSE)
  }
  fmls <- names(formals(fn))
  if (is.null(fmls)) fmls <- character(0)
  if ("..." %in% fmls) {
    stop(sprintf(paste0(
      "%s: adhoc `fn` takes `...`, which is prohibited -- same as a package ",
      "package_function(): a dispatch target must have a fixed formal list so a ",
      "mistyped or missing argument can be caught."), lead), call. = FALSE)
  }

  globals <- codetools::findGlobals(fn, merge = FALSE)
  candidates <- unique(c(globals$functions, globals$variables))
  is_base <- vapply(candidates, function(nm) {
    isTRUE(tryCatch(exists(nm, envir = baseenv(), inherits = FALSE),
      error = function(e) FALSE))
  }, logical(1))
  bad <- sort(candidates[!is_base])
  if (length(bad) > 0L) {
    stop(sprintf(paste0(
      "%s: adhoc `fn` is not self-contained -- it references global(s) that ",
      "are neither base R nor `pkg::`-qualified: %s. Every value the closure ",
      "needs must be a base function/operator/constant, a declared formal, ",
      "or referenced via an explicit `pkg::fun()` call. (This is a ",
      "best-effort static lint -- see PHASE6_DESIGN.md section 5 for its ",
      "documented blind spots; it does not prove behavioural closure.)"),
      lead, paste(bad, collapse = ", ")), call. = FALSE)
  }
  invisible(TRUE)
}

#' Rebase an accepted adhoc closure onto `baseenv()` (design section 5, mandatory)
#'
#' Called ONLY after `.batch_lint_adhoc_fn()` has accepted `fn` -- once, by
#' the parent, before the closure is ever serialized, and again, defensively,
#' by the child right before `do.call()` (see `.batch_execute()`), in case a
#' hand-crafted envelope reached the worker with a closure that was never
#' rebased in the first place. Severs the closure's original enclosing
#' environment and reconnects it to `baseenv()` instead. There is no
#' env-preservation mode; a closure that needs anything beyond base R + its
#' own formals + `pkg::`-qualified calls is out of scope for `adhoc` by
#' design.
#' @noRd
.batch_rebase_adhoc_closure <- function(fn) {
  # Strip attributes FIRST: `structure(fn, payload = <big/secret object>)` is a
  # carrier the findGlobals lint never sees (the object is not a free global)
  # and would otherwise serialize to the child. Removing all attributes off a
  # closure does not affect how it CALLS (srcref/class/etc. are not needed to
  # run it). Then sever the enclosing environment. Together these enforce "code,
  # not captured data" for the two common carriers; the remaining exotic ones
  # (an object graph embedded in a default-argument expression or a bytecode
  # constant) stay documented blind spots (design section 5), not enforced.
  attributes(fn) <- NULL
  environment(fn) <- baseenv()
  fn
}

#' Validate one adhoc item's args against the closure's OWN formals
#'
#' The `adhoc` sibling of [.batch_validate_item()] (which is keyed to a
#' `package_function` descriptor's package+symbol for its error-message lead):
#' identical rules (every formal named explicitly, no positional/duplicate/
#' unknown argument -- see [.batch_validate_item_against_formals()]), applied
#' against a bare formal-name vector instead, since an adhoc closure carries
#' no package/symbol identity to report.
#' @noRd
.batch_validate_adhoc_item <- function(formal_names, args, where = "parent", id = NULL) {
  loc <- if (is.null(id)) "" else sprintf(" [item '%s']", id)
  lead <- sprintf(".batch %s-validation%s: <adhoc fn>", where, loc)
  .batch_validate_item_against_formals(formal_names, lead, args)
}

# --- frontend: batch_fn() -----------------------------------------------------

#' Run a bare closure on each of a fixed list of items, one subprocess per item
#'
#' The `adhoc` sibling of [batch_run()] (design PHASE6_DESIGN.md sections 1-2,
#' 4-5, 9.4): the SAME transport (a fresh `processx` subprocess per item, the
#' same `inst/batch_worker.R`, the same both-ends item validation and
#' result-envelope inspection), but `fn` is a bare closure VALUE -- serialized
#' straight into the envelope -- instead of a [package_function()] descriptor
#' resolved by package+symbol.
#'
#' The closure is gated by a best-effort static self-containedness LINT (see
#' `.batch_lint_adhoc_fn()`): it may reference only base R (including base
#' operators/constants), its own declared formals, and explicit
#' `pkg::fun()`/`pkg:::fun()` calls -- any other free variable is rejected,
#' NAMING it, before any subprocess is launched. `...` in `fn`'s formals is
#' prohibited, exactly like a package [package_function()]. Once accepted, the
#' closure is unconditionally rebased onto `baseenv()` before it is ever
#' serialized (see `.batch_rebase_adhoc_closure()`) -- there is no
#' env-preservation mode, so anything the closure needs beyond base R + its
#' own formals + `pkg::`-qualified calls must be passed as an item argument.
#'
#' Because an adhoc closure carries no package/symbol/hash identity, a result
#' is instead bound to the dispatch that produced it via the item id (already
#' checked) PLUS a fresh, high-entropy per-item nonce issued here and echoed
#' back by the child -- see `.batch_inspect_result()`'s `expected_nonce`.
#'
#' Production/auditable stages should prefer [batch_run()] with a
#' [package_function()] descriptor (hash-verified, resolvable by package+symbol,
#' so a stale/wrong code version is caught); `adhoc` dispatch is for
#' throwaway/exploratory work where that overhead is not the point. The lint
#' is a best-effort static check, not a proof -- see `.batch_lint_adhoc_fn()`
#' for its documented blind spots.
#'
#' @param fn A bare closure: self-contained (base R, `pkg::`-qualified calls,
#'   and its own formals only -- see `.batch_lint_adhoc_fn()`), not a primitive,
#'   and not taking `...`.
#' @param items List of items; each a fully-named list of `fn`'s formals.
#'   Named items keep their name as the item id; unnamed items get their
#'   index.
#' @param n_workers Concurrent subprocesses (validated: finite, whole, >= 1).
#' @param dev_path For `adhoc` dispatch this names BATCHIT'S OWN source tree
#'   (loaded via `devtools::load_all()` in the worker), NOT a consumer
#'   package -- an adhoc closure has no separate consumer identity to load,
#'   so there is nothing else `dev_path` could sensibly name here. A
#'   given-but-wrong path errors rather than silently falling back to the
#'   installed package. `NULL` (the default) uses the installed `batchit`,
#'   which is what any downstream caller wants; a non-`NULL` value is for
#'   developing/testing batchit's own `adhoc` code without reinstalling it
#'   first. A closure's own `pkg::fun()` calls are unaffected either way --
#'   they resolve via ordinary lazy namespace loading in the worker, exactly
#'   like any other R code.
#' @param collect If `TRUE`, return each item's value in item order; if
#'   `FALSE` (the default here), the worker still reports status but its
#'   value never crosses back.
#' @param p A progress callback such as a `progressr` progressor, or `NULL`.
#' @param label Optional short stage tag prefixed to the progress message.
#' @param timeout Per-item wall-clock limit in seconds; see [batch_run()].
#' @return If `collect`, a list of values in item order; else
#'   `invisible(NULL)`.
#' @examples
#' \dontrun{
#' batch_fn(
#'   function(x) x * 2,
#'   items = list(list(x = 1), list(x = 2)),
#'   n_workers = 2, collect = TRUE
#' )
#' }
#' @export
batch_fn <- function(
  fn,
  items,
  n_workers,
  dev_path = NULL,
  collect = FALSE,
  p = NULL,
  label = NULL,
  timeout = .BATCH_DEFAULT_TIMEOUT
) {
  # Lint + rebase BEFORE anything else -- an early, clear rejection beats a
  # confusing failure deep inside dispatch, and every downstream step
  # (formal-name extraction, item validation, envelope building) must see the
  # ALREADY-rebased closure, never the original.
  .batch_lint_adhoc_fn(fn, where = "parent")
  fn <- .batch_rebase_adhoc_closure(fn)
  fmls <- names(formals(fn))
  if (is.null(fmls)) fmls <- character(0)

  n_workers <- .batch_validate_n_workers(n_workers, "batch_fn()")
  # Validate ALL config BEFORE the empty-workload early return -- otherwise a
  # bad dev_path/timeout/collect is silently accepted whenever there is no work.
  collect <- .batch_validate_collect(collect, "batch_fn()")
  timeout <- .batch_validate_timeout(timeout, "batch_fn()")
  # dev_path for adhoc names BATCHIT'S OWN tree (see the parameter doc) --
  # there is no separate consumer package identity to validate it against.
  dev_path <- .batch_validate_dev_path(dev_path, "batchit")
  if (!is.list(items)) {
    stop(sprintf("batch_fn(): `items` must be a list, got %s", class(items)[1L]),
      call. = FALSE)
  }

  n_items <- length(items)
  if (n_items == 0L) return(if (collect) list() else invisible(NULL))

  # Stable per-item ids (item names, else the index) -- shared with batch_run().
  ids <- .batch_item_ids(items)

  # Validate EVERY item up front (not items[[1]]): item schemas are
  # legitimately heterogeneous, so a bad one hides behind a good first one.
  for (i in seq_len(n_items)) {
    .batch_validate_adhoc_item(fmls, items[[i]], where = "parent", id = ids[i])
  }

  # A fresh, high-entropy identity nonce PER ITEM (design section 9.4): an
  # adhoc envelope has no package/symbol/hash for the parent to check the
  # result against, so this token -- echoed back by the child in the result's
  # `target` field -- takes that role. Built exactly like the batch_task()
  # attempt token (same `tempfile()`-based generator, same "never touches
  # R's RNG stream" guarantee); reused rather than duplicated.
  nonces <- vapply(seq_len(n_items), function(i) .batch_new_attempt_token(),
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
      target = NULL, dev_path = dev_path, runner = runner_pkg, id = ids[i],
      args = items[[i]], fn_kind = "adhoc", collect = collect,
      fn = fn, nonce = nonces[i])
    .batch_write_envelope(envelope, input_paths[i])
  }

  active <- list()
  n_done <- 0L
  next_item <- 1L
  results <- if (collect) vector("list", n_items) else NULL

  on.exit({
    for (entry in active) {
      tryCatch(entry$proc$kill_tree(), error = function(e) NULL)
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

  # A worker failed -- surface its log tail, then stop. Identical shape to
  # batch_run()'s .fail(), tagged with batch_fn() in the message.
  .fail <- function(entry, what) {
    idx <- entry$idx
    tail_txt <- .batch_log_tail(log_paths[idx])
    if (nzchar(trimws(tail_txt))) {
      message(sprintf(
        "\n--- item '%s' failed ---\nOUTPUT (stdout+stderr):\n%s\n---",
        ids[idx], tail_txt))
    }
    stop(sprintf("batch_fn(): item '%s' %s", ids[idx], what), call. = FALSE)
  }

  # Read + validate one finished item's result envelope while its log is
  # still on disk, exactly like batch_run()'s .collect() -- but the inspector
  # is told this item's NONCE instead of a package/symbol/hash target.
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
    insp <- .batch_inspect_result(envelope, ids[idx], target = NULL,
      expected_nonce = nonces[idx])
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
        # results[idx] <- list(value), NOT results[[idx]] <- value: assigning
        # a NULL value with [[<- DELETES the element -- see batch_run()'s
        # identical comment.
        if (collect) results[entry$idx] <- list(value)
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

  if (collect) results else invisible(NULL)
}

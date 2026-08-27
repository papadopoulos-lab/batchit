# Shape B of the dispatcher in R/batch.R: the parent produces items lazily
# under backpressure, over a mirai bounded queue. Delivery uses the same atomic
# declared-output commit engine as run_and_write_files_atomically().

# --- shape B: lazy producer, bounded queue, via mirai ------------------------

# Session-local counter + high-entropy session nonce for private mirai
# compute-profile names. mirai compute profiles are session-local, but the
# profile REGISTRY is session-WIDE: a bare `.batch_stream_<counter>` is unique
# only among calls through THIS closure, so if another caller/package already
# owns `.batch_stream_1`, our daemons() would reset (and our on.exit destroy)
# THEIR profile -- mirai resets existing daemons when daemons() is called again
# for the same profile. So the counter is namespaced by a session nonce:
# collision now requires another party to have claimed a name under the runner's
# reserved `.batch_stream_<nonce>_` prefix in the SAME session, where <nonce> is
# high-entropy and session-specific -- not merely a small integer. The nonce is
# derived from basename(tempfile()), which embeds the pid + random hex WITHOUT
# touching R's RNG stream (so it cannot disturb a caller's
# set.seed()/reproducibility); it is computed once, lazily, and cached alongside
# the counter. The generated name still carries the `.batch_stream_` prefix and
# so can never be "default" -- the never-touch-the-default guarantee still holds
# by construction.
.batch_stream_profile <- local({
  i <- 0L
  nonce <- NULL
  function() {
    if (is.null(nonce)) {
      nonce <<- gsub("[^[:alnum:]]", "", basename(tempfile(pattern = "")))
    }
    i <<- i + 1L
    return(sprintf(".batch_stream_%s_%d", nonce, i))
  }
})

#' Like [run_and_write_files_atomically()], but build each item lazily instead of all at once
#'
#' [run()], [run_and_collect()] and [run_and_write_files_atomically()] all
#' require the full `items` list up front. Use this function when that list
#' would itself use too much memory. For example, each item is a large data
#' slice, or there are far too many items to hold as a list at once. Instead
#' of an `items` list, you give an `ids` vector and a
#' `producer(id)` function that builds one item's arguments at a time.
#' batchit keeps at most `min(2 * n_workers, length(ids))` items in flight,
#' and calls `producer()` only when one of those slots is free. That bounds
#' how many produced items exist at once. A free slot is not the same as an
#' idle worker. When every worker is busy, roughly `n_workers` further items
#' may already be produced and queued. Everything else works like
#' [run_and_write_files_atomically()]: each item's function runs on a
#' background worker, and its declared output files are written safely. See
#' that function's help page for the atomic-write guarantee and the two
#' `style`s.
#'
#' Two restrictions specific to this function. `fn` must be an object from
#' [package_function()], because an inline function is not accepted here,
#' unlike [run_and_write_files_atomically()]. And it requires the `mirai`
#' package to be installed. There is also no way to get a raw return value
#' back; only the output-file record described below, exactly as in
#' [run_and_write_files_atomically()].
#'
#' @param fn An object from [package_function()], naming a function in an
#'   installed package. An inline function is not accepted here.
#' @param ids One id per item, in the order you want items produced and run.
#'   Must be unique, non-missing values (coerced to character).
#' @param producer A function of one argument, an item's id, that builds
#'   and returns that one item. The item is a named list holding all of
#'   `fn`'s arguments. It has exactly the shape one element of `items` has
#'   for [run_and_write_files_atomically()]. Called once per id, in your R
#'   session (never on a worker), only when one of the
#'   `min(2 * n_workers, length(ids))` in-flight slots is free. So load or
#'   build each item's data inside this function, rather than before calling
#'   `stream_from_parent_and_write_files_atomically()`.
#' @param outputs A list aligned to `ids`: `outputs[[i]]` is item `i`'s
#'   output map, a named character vector `c(<name> = <final path>)`. May
#'   instead be named by item id (same name set as `ids`, any order). The
#'   rules are the same as for [run_and_write_files_atomically()]'s
#'   `outputs`. Every path MUST be absolute. Every destination MUST be absent
#'   or an existing plain file, not a directory and not a symlink. Every
#'   output path, across every item in this one call, MUST be unique.
#' @param style `"return"` (the target returns a named list) or
#'   `"staged_writer"` (the target writes each output via
#'   [where_to_write_output()] instead). See
#'   [run_and_write_files_atomically()] for what each means. Any other
#'   value errors.
#' @param n_workers Number of persistent background workers (`mirai`
#'   daemons) to run at once.
#' @param dev_path The source tree of the package named in `fn`, loaded once
#'   per worker with `devtools::load_all()`, instead of using the installed
#'   package. Leave as `NULL` (the default) to use the installed package. A
#'   path that doesn't exist, or doesn't match that package, is an error,
#'   even when there turn out to be no items to run.
#' @param p A progress callback, such as a `progressr` progressor.
#' @param label An optional short label added to each progress message.
#' @param timeout Maximum time, in seconds, to let one item run before it is
#'   treated as failed (6 hours by default; `Inf` disables the limit).
#' @return A list, named by id, **in the same order as `ids`**. Each element
#'   describes what that item wrote. Its shape is
#'   `list(committed = <named character vector: output name -> final path
#'   written>, attempt = <an internal per-item identifier; you can ignore
#'   this>)`. Never `fn`'s raw return value.
#' @examples
#' \dontrun{
#' # `write_one_slice()` must live in an INSTALLED package. This function
#' # loads it by package name + function name (never by value, unlike the
#' # other three dispatch functions), so it cannot be an inline function
#' # defined at the console. Put it in your own package's R/ directory,
#' # install the package, then replace "yourpkg" below with its name:
#' #
#' #   write_one_slice <- function(slice) list(main = slice)
#'
#' out_dir <- tempdir()
#' ids <- c("a", "b", "c")
#' stream_from_parent_and_write_files_atomically(
#'   fn = package_function("yourpkg", "write_one_slice"),
#'   ids = ids,
#'   producer = function(id) list(slice = toupper(id)),
#'   outputs = setNames(
#'     lapply(ids, function(id) c(main = file.path(out_dir, paste0(id, ".qs2")))),
#'     ids
#'   ),
#'   n_workers = 2
#' )
#' }
#' @family dispatch functions
#' @seealso `vignette("batchit")` for a worked comparison
#'   of all four dispatch functions.
#' @section Advanced:
#' This function runs its workers as persistent `mirai` daemons, in a
#' private compute profile it creates and tears down for this call only.
#' It never touches or resets any daemon configuration you already had
#' outside this call. A background worker loads the package named in `fn`
#' once, when it starts (not once per item).
#'
#' At most `2 * n_workers` items are in flight at once, each carrying its
#' own `timeout`. `producer()` is not called again until an in-flight slot
#' frees up, which is what keeps memory bounded. An item that hangs past
#' its timeout resolves as an error instead of blocking the others forever.
#'
#' As with [run()]/[run_and_collect()], batchit does not set BLAS or
#' `data.table` thread counts; divide your CPU cores across `n_workers`
#' yourself if `fn` is itself multi-threaded.
#' @export
stream_from_parent_and_write_files_atomically <- function(
  fn,
  ids,
  producer,
  outputs,
  style = "return",
  n_workers,
  dev_path = NULL,
  p = NULL,
  label = NULL,
  timeout = .BATCH_DEFAULT_TIMEOUT
) {
  if (!inherits(fn, "package_function")) {
    stop(
      "stream_from_parent_and_write_files_atomically(): `fn` must come from package_function()",
      call. = FALSE
    )
  }
  target <- fn
  if (!is.function(producer)) {
    stop(
      "stream_from_parent_and_write_files_atomically(): `producer` must be a function of one id",
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
      "stream_from_parent_and_write_files_atomically(): `style` must be a single non-empty string",
      call. = FALSE
    )
  }
  if (!(style %in% c("return", "staged_writer"))) {
    stop(
      sprintf(
        paste0(
          "stream_from_parent_and_write_files_atomically(): unknown style '%s' ",
          "(must be \"return\" or \"staged_writer\")"
        ),
        style
      ),
      call. = FALSE
    )
  }
  n_workers <- .batch_validate_n_workers(
    n_workers,
    "stream_from_parent_and_write_files_atomically()"
  )
  # Validate ALL config BEFORE the empty-workload early return.
  ids <- .batch_check_ids(ids)
  timeout <- .batch_validate_timeout(
    timeout,
    "stream_from_parent_and_write_files_atomically()"
  )
  dev_path <- .batch_validate_dev_path(dev_path, target$package)
  runner_pkg <- .batch_runner_package()
  if (!is.list(outputs)) {
    stop(
      sprintf(
        "stream_from_parent_and_write_files_atomically(): `outputs` must be a list, got %s",
        class(outputs)[1L]
      ),
      call. = FALSE
    )
  }
  if (length(outputs) != length(ids)) {
    stop(
      sprintf(
        paste0(
          "stream_from_parent_and_write_files_atomically(): `outputs` must have the same length as ",
          "`ids` (%d), got %d"
        ),
        length(ids),
        length(outputs)
      ),
      call. = FALSE
    )
  }

  n <- length(ids)
  if (n == 0L) {
    return(list())
  }
  if (!requireNamespace("mirai", quietly = TRUE)) {
    stop(
      "stream_from_parent_and_write_files_atomically() requires the 'mirai' package",
      call. = FALSE
    )
  }

  # `.batch_task_marker_path()` interpolates the id straight into a filename
  # (`.batchit__<id>`); a `/` or `\` in an id would place that marker in a
  # different (possibly nonexistent) subdirectory than the one just
  # validated -- reject it loudly rather than let it silently derive a broken
  # marker path.
  bad_ids <- ids[grepl("[/\\\\]", ids, perl = TRUE)]
  if (length(bad_ids) > 0L) {
    stop(
      sprintf(
        paste0(
          "stream_from_parent_and_write_files_atomically(): item id(s) must not contain '/' or '\\\\' ",
          "(interpolated into the per-item marker filename .batchit__<id>): %s"
        ),
        paste(unique(bad_ids), collapse = ", ")
      ),
      call. = FALSE
    )
  }
  outputs <- .batch_align_outputs_to_ids(
    outputs,
    ids,
    "stream_from_parent_and_write_files_atomically()"
  )

  # Validate EVERY item's output map up front (not just the first): item
  # schemas are legitimately heterogeneous, so a bad one hides behind a good
  # first one.
  for (i in seq_len(n)) {
    .batch_validate_output_map(outputs[[i]], where = "parent", id = ids[i])
  }
  outputs <- lapply(seq_len(n), function(i) {
    return(.batch_validate_output_paths(outputs[[i]], ids[i]))
  })
  markers <- vapply(
    seq_len(n),
    function(i) {
      return(.batch_task_marker_path(outputs[[i]], ids[i]))
    },
    character(1)
  )
  # Invocation-wide collision check: every output AND every marker, across all
  # items.
  .batch_check_task_collisions(outputs, markers, ids)

  attempts <- vapply(
    seq_len(n),
    function(i) .batch_new_attempt_token(),
    character(1)
  )

  # A fresh PRIVATE profile per invocation (see [.batch_stream_profile()]).
  # Because the generated name carries the reserved `.batch_stream_<nonce>_`
  # prefix it can never be "default", so daemons(n)/daemons(0) here can never
  # reset the caller's default profile, and the high-entropy session nonce makes
  # a collision with another party's session-wide profile name a non-issue by
  # construction -- no ownership predicate or collision policy to maintain.
  compute <- .batch_stream_profile()
  mirai::daemons(n_workers, .compute = compute)
  # Tear the daemons down on exit, THEN sweep every item's attempt-scoped commit
  # temps. mirai cannot guarantee a daemon runs its own on.exit cleanup when it
  # is force-terminated -- a per-item timeout or a sibling-item abort can kill a
  # daemon mid-commit -- so the parent removes any orphaned `.<attempt>.tmp` /
  # `.<attempt>.stage` files here, exactly as the Shape-A processx path does
  # after a kill_tree() (see .batch_sweep_task_temps() + run_and_write_files_
  # atomically()'s on.exit). A successfully-committed item has no temps left (its
  # were renamed to finals), so this is a no-op on the happy path; the unique
  # per-item attempt token scopes each sweep to that item's own leftovers.
  on.exit(
    {
      mirai::daemons(0L, .compute = compute)
      for (i in seq_len(n)) {
        tryCatch(
          .batch_sweep_task_temps(outputs[[i]], markers[i], attempts[i]),
          error = function(e) NULL
        )
      }
    },
    add = TRUE
  )

  # Load the consumer AND (when it differs) the runner package ONCE per
  # persistent daemon -- not per task. The daemon needs .batch_execute resolvable
  # in the runner's namespace, while the consumer supplies the target.
  if (is.null(dev_path)) {
    mirai::everywhere(
      {
        requireNamespace(.consumer, quietly = TRUE)
        if (!identical(.runner, .consumer)) {
          requireNamespace(.runner, quietly = TRUE)
        }
      },
      .consumer = target$package,
      .runner = runner_pkg,
      .compute = compute
    )
  } else {
    mirai::everywhere(
      {
        suppressPackageStartupMessages(devtools::load_all(.dev, quiet = TRUE))
        # Load the RUNNER too when it differs from the consumer: the daemon needs
        # <runner>:::.batch_execute, which devtools::load_all(consumer) does not
        # provide once runner != consumer (the extraction seam).
        if (!identical(.runner, .consumer)) {
          requireNamespace(.runner, quietly = TRUE)
        }
      },
      .dev = dev_path,
      .consumer = target$package,
      .runner = runner_pkg,
      .compute = compute
    )
  }

  # Double the workers, capped at the id count. Deliberately `2 * n_workers`
  # (double), NOT `2L * n_workers`: integer multiplication OVERFLOWS to NA for a
  # validated-but-absurd worker count near .Machine$integer.max, and NA in the
  # `length(inflight) >= max_inflight` guard would error. Double arithmetic can't
  # overflow here; the min() with n bounds it.
  max_inflight <- min(2 * n_workers, n)
  task_timeout_ms <- if (length(timeout) == 1L && is.finite(timeout)) {
    timeout * 1000
  } else {
    NULL
  }
  results <- vector("list", n)
  inflight <- list()
  n_done <- 0L

  .stream_fail <- function(item, reason) {
    stop(
      sprintf(
        "stream_from_parent_and_write_files_atomically(): id '%s' %s",
        item$id,
        reason
      ),
      call. = FALSE
    )
  }

  # Drain the OLDEST in-flight task (FIFO). Two failure channels, identical in
  # spirit to run()/run_and_collect()/run_and_write_files_atomically(): a
  # daemon-level error value (the task expression itself blew up, the package
  # would not load, or the per-task timeout fired) and a commit-level error
  # envelope, inspected via .batch_inspect_result() against THIS item's
  # dispatched outputs/attempt -- so a stale or substituted commit result can
  # never be accepted.
  drain_one <- function() {
    item <- inflight[[1L]]
    v <- mirai::call_mirai(item$h)$data
    if (mirai::is_error_value(v)) {
      .stream_fail(item, sprintf("daemon/timeout error: %s", as.character(v)))
    }
    insp <- .batch_inspect_result(
      v,
      item$id,
      target,
      expected_outputs = outputs[[item$pos]],
      expected_attempt = attempts[item$pos]
    )
    if (!insp$ok) {
      .stream_fail(item, insp$reason)
    }
    .batch_surface_warnings(insp$warnings, item$id)
    # results[pos] <- list(value), not [[<-: the same NULL-deletion trap as
    # run()/run_and_collect() -- moot here in practice (a commit record is
    # never NULL), kept for consistency/robustness.
    results[item$pos] <<- list(insp$value)
    inflight[[1L]] <<- NULL
    n_done <<- n_done + 1L
    if (!is.null(p)) {
      return(p(
        message = if (is.null(label)) {
          as.character(item$id)
        } else {
          paste(label, item$id)
        }
      ))
    }
  }

  for (i in seq_len(n)) {
    # Backpressure: block the producer until an in-flight slot frees. This is why
    # shape B does not blow up memory -- producer(id) is not even called until
    # there is somewhere to put its result.
    while (length(inflight) >= max_inflight) {
      drain_one()
    }

    id <- ids[[i]]
    args <- producer(id)
    .batch_validate_item(target, args, where = "parent", id = id)
    envelope <- .batch_input_envelope(
      target,
      dev_path,
      runner_pkg,
      id,
      args,
      outputs = outputs[[i]],
      marker = markers[i],
      style = style,
      attempt = attempts[i]
    )
    h <- mirai::mirai(
      {
        get(".batch_execute", envir = asNamespace(.runner))(.env)
      },
      .env = envelope,
      .runner = runner_pkg,
      .compute = compute,
      .timeout = task_timeout_ms
    )
    inflight[[length(inflight) + 1L]] <- list(id = id, pos = i, h = h)
  }

  while (length(inflight) > 0L) {
    drain_one()
  }

  names(results) <- as.character(ids)
  return(results)
}

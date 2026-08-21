# One dispatcher, one contract. batchit was extracted from swereg after Phases
# 0-3 of the one-dispatcher project (see README.md and swereg's PROJECT.md); this
# is that dispatcher, now standing on its own.
#
# The dispatcher is package-neutral by design: it imports nothing from any
# consumer's domain code, so the same runner serves any consumer package. The
# only helpers it leans on from outside itself -- .batch_hash_function(),
# .batch_validate_n_workers() -- are batchit's own, domain-free, and live in
# R/batch_helpers.R. (.batch_log_tail() lives in R/batch.R.)
#
# Shape A, ONE shared contract, three frontends over ONE internal impl
# (.batch_run_impl()):
#   run(fn, items, ...)              -- run each item, return nothing.
#   run_and_collect(fn, items, ...)  -- run each item, return a list of values
#                                        in item order.
#   run_and_write_files_atomically(fn, items, outputs, style, ...) (the
#                                     declared-output commit-engine source file)
#                                     -- each item commits declared output files
#                                        atomically instead of returning a value.
# `fn` is EITHER a package_function() descriptor OR a bare closure (folded in
# from the former ad-hoc-closure frontend) -- see .batch_run_impl()'s fn_kind branch.
# stream_from_parent_and_write_files_atomically(fn, ids, producer, outputs, ...)
# is shape B: the parent IS the producer, items are generated lazily under
# backpressure (mirai bounded queue), and delivery is via the same atomic
# declared-output commit engine run_and_write_files_atomically() uses -- fn is
# package_function()-only (no ad-hoc closure support; DESIGN.md section 3).
# All four share target/fn resolution, both-end validation, the result
# envelope, and failure semantics. They differ only in internal transport,
# which is private.
#
# Runner vs consumer (the extraction seam): batchit is the RUNNER; a target's
# `package` names the CONSUMER, which is a DIFFERENT package. The worker script is
# always the runner's (.batch_worker_script() -> system.file(package = batchit));
# `dev_path`, when given, is the CONSUMER's source tree and supplies only the
# consumer's code. The worker and the mirai daemon each load BOTH packages (see
# inst/batch_worker.R and stream_from_parent_and_write_files_atomically(), in
# R/batch_stream.R).
#
# The dispatcher spans six files in R/, split by role:
#   batch.R           -- this banner, the protocol constants, package_function(),
#                        run(), run_and_collect(), worker-script and dev-path
#                        resolution, and .batch_log_tail().
#   batch_validate.R  -- item, id, timeout and collect validation.
#   batch_envelope.R  -- the private IPC codec and the envelope contract.
#   batch_execute.R   -- child-side execution and the shape-A worker pool.
#   batch_result.R    -- parent-side inspection of a result envelope.
#   batch_stream.R    -- shape B: the mirai streaming atomic writer.

# Bumped to 2 (see DESIGN.md section 2): the envelope gained a
# REQUIRED meta$fn_kind discriminator ("package" | "adhoc") plus the
# declared-output commit fields (outputs/marker/style/attempt) used by
# run_and_write_files_atomically(). An old (protocol 1) envelope has none of these, so a
# version-skewed worker must reject it rather than mis-execute --
# .batch_check_envelope() enforces that, and the worker now verifies protocol
# BEFORE loading any CONSUMER package (see inst/batch_worker.R).
.BATCH_PROTOCOL <- 2L

# Generous per-item wall-clock default: a hang-catcher, not a deadline. Long
# enough that no legitimate item (e.g., in the originating registry pipeline a
# multi-hour, ~20 GB analysis panel) hits it, short enough that a deadlocked or
# infinite-looping worker does not sit forever. Callers with genuinely longer
# items must raise it explicitly. Referenced as the default for run() /
# run_and_collect() / stream_from_parent_and_write_files_atomically()'s
# `timeout` formal (documented there rather than exported).
.BATCH_DEFAULT_TIMEOUT <- 6 * 3600

# --- target descriptor -------------------------------------------------------

#' Identify a function in an installed package, so a worker can run it
#'
#' Builds a small object that names a function in an installed package. Pass
#' that object as the `fn` argument to [run()], [run_and_collect()],
#' [run_and_write_files_atomically()], or
#' [stream_from_parent_and_write_files_atomically()]. It is the alternative
#' to an inline function, written directly in one of those calls (see their
#' help pages). `package_function()` is required for
#' `stream_from_parent_and_write_files_atomically()`. It is recommended for
#' the other three, whenever you want a production run to verify what every
#' worker runs. Each worker then checks that it is running the code you
#' tested, not just whatever happens to be installed. For a quick one-off
#' run, an inline function is simpler and needs no setup.
#'
#' The object this function returns always identifies a function by package
#' name + function name + a hash of its code. It is never the function
#' itself, a bare function name, or a closure. You can also pass your
#' function directly as `fn`, which is a different thing. `run()`,
#' `run_and_collect()` and `run_and_write_files_atomically()` accept a
#' function that way (see their `fn` argument). Only
#' `stream_from_parent_and_write_files_atomically()` requires the form this
#' function builds.
#'
#' A function that takes `...` is rejected. batchit checks every item's
#' argument names against the function's own fixed argument list. `...` would
#' make a mistyped or missing argument impossible to catch reliably.
#'
#' @param package Name of the installed package holding your function (a
#'   single string). It does not need to be `batchit` itself.
#' @param symbol Name of your function inside that package (a single
#'   string). It can be an exported OR an internal (unexported) function
#'   name.
#' @param version A version label to record for your own reference. Defaults
#'   to the package's currently installed version. This is informational
#'   only: what a worker actually checks before running is the code hash
#'   below, not this version string.
#' @return An object of class `"package_function"`. It is a list with
#'   elements `package`, `symbol`, `version`, `hash` and `formal_names`.
#'   `hash` is a hash of the function's code, used to verify the worker
#'   loaded the same definition. `formal_names` holds the function's argument
#'   names. Pass the whole object as `fn`.
#' @examples
#' # `stats` ships with R, so this always works. In your own project, name
#' # your own package and function here instead.
#' t <- package_function("stats", "sd")
#' t$formal_names
#' @seealso [run()], [run_and_collect()], [run_and_write_files_atomically()]
#'   and [stream_from_parent_and_write_files_atomically()], which all accept
#'   the descriptor this returns as their `fn`.
#'
#'   `vignette("batchit")` for when to prefer this over
#'   an inline function.
#' @section Advanced:
#' The code hash is deliberately narrow: it covers only the function's own
#' body and its own argument list. Four things lie outside it:
#' * a changed helper function it calls;
#' * a constant it refers to elsewhere;
#' * an S4/R6 method table;
#' * a dependency's version.
#'
#' So a matching hash proves "the same function definition", not "provably
#' identical behaviour". batchit also strips comments and whitespace before
#' it computes the hash, with `utils::removeSource()`. The hash then agrees
#' across an installed package and a `devtools::load_all()` source tree.
#' Those two otherwise disagree on identical code.
#' @export
package_function <- function(package, symbol, version = NULL) {
  if (!is.character(package) || length(package) != 1L || !nzchar(package)) {
    stop(
      "package_function(): `package` must be a non-empty string",
      call. = FALSE
    )
  }
  if (!is.character(symbol) || length(symbol) != 1L || !nzchar(symbol)) {
    stop(
      "package_function(): `symbol` must be a non-empty string",
      call. = FALSE
    )
  }
  ns <- tryCatch(
    asNamespace(package),
    error = function(e) {
      stop(
        sprintf(
          "package_function(): package '%s' is not available: %s",
          package,
          conditionMessage(e)
        ),
        call. = FALSE
      )
    }
  )
  if (!exists(symbol, envir = ns, inherits = FALSE)) {
    stop(
      sprintf(
        "package_function(): '%s' is not defined in package '%s'",
        symbol,
        package
      ),
      call. = FALSE
    )
  }
  fn <- get(symbol, envir = ns, inherits = FALSE)
  if (!is.function(fn)) {
    stop(
      sprintf("package_function(): %s::%s is not a function", package, symbol),
      call. = FALSE
    )
  }
  # names(formals(fn)) is NULL for a zero-argument function; normalise so
  # formal_names is always a character vector (possibly empty), never NULL --
  # otherwise a legitimate no-arg target looks like a malformed descriptor.
  fmls <- names(formals(fn))
  if (is.null(fmls)) {
    fmls <- character(0)
  }
  if ("..." %in% fmls) {
    stop(
      sprintf(
        paste0(
          "package_function(): %s::%s takes `...`, which is incompatible ",
          "with reliable argument validation. A dispatch target must have a ",
          "fixed formal list so a mistyped or missing argument can be caught."
        ),
        package,
        symbol
      ),
      call. = FALSE
    )
  }
  structure(
    list(
      package = package,
      symbol = symbol,
      version = version %||% as.character(utils::packageVersion(package)),
      # removeSource() FIRST: the identity hash must be independent of srcref, or
      # the parent and child disagree whenever they load the same code with
      # different keep.source -- which is exactly what happens under R CMD check
      # (parent = installed package, no srcref; child = devtools::load_all,
      # srcref) and made every dispatched item falsely "resolve to a DIFFERENT
      # code version". The logical body+formals are what identity means here.
      hash = .batch_hash_function(utils::removeSource(fn)),
      formal_names = fmls
    ),
    class = "package_function"
  )
}

# --- bounded log tail --------------------------------------------------------

#' Bounded tail of a worker's log file
#'
#' Reads at most the last `max_bytes` of `path` and returns its last `n` lines.
#'
#' Bounded on the way IN, which is the whole point. A naive version would
#' `readLines()` the entire file and only then take the tail. That version
#' would OOM the **parent** when a worker died after it emitted a multi-GB
#' log. One worker's failure would become the whole run's. Never more than
#' `max_bytes` enters memory. This runs at exactly the worst moment (while
#' reporting a worker's failure), so it must not itself be able to blow up.
#'
#' Worker output is not guaranteed to be text. A C library can emit a NUL, and
#' a seek into the middle of a file can slice a multi-byte character in half.
#' `rawToChar()` errors on an embedded NUL, and `strsplit()` errors on an
#' invalid multibyte string. An unscrubbed version would then report "(no
#' output captured)" for a worker that did in fact say exactly what was wrong.
#' Bytes are therefore scrubbed, not trusted.
#'
#' @param path Log file path.
#' @param n Maximum lines to return.
#' @param max_bytes Maximum bytes to read from the end of the file.
#' @return A single string, `""` if there is nothing readable to report.
#' @noRd
.batch_log_tail <- function(path, n = 100L, max_bytes = 64000) {
  if (!file.exists(path)) {
    return("")
  }
  size <- file.size(path)
  if (is.na(size) || size == 0L) {
    return("")
  }

  from <- max(0, size - max_bytes)
  txt <- tryCatch(
    {
      con <- file(path, "rb")
      on.exit(close(con), add = TRUE)
      if (from > 0) {
        seek(con, where = from, origin = "start")
      }
      bytes <- readBin(con, "raw", n = min(size, max_bytes))
      bytes <- bytes[bytes != as.raw(0L)]
      raw_txt <- rawToChar(bytes)
      Encoding(raw_txt) <- "UTF-8"
      iconv(raw_txt, from = "UTF-8", to = "UTF-8", sub = "?")
    },
    error = function(e) ""
  )
  if (length(txt) != 1L || is.na(txt) || !nzchar(txt)) {
    return("")
  }

  lines <- strsplit(txt, "\n", fixed = TRUE)[[1]]
  # A mid-line seek makes the first fragment partial; drop it rather than report
  # a truncated line as though it were real output.
  if (from > 0 && length(lines) > 1L) {
    lines <- lines[-1L]
  }
  clipped <- from > 0 || length(lines) > n
  if (length(lines) > n) {
    lines <- utils::tail(lines, n)
  }

  paste(
    c(
      if (clipped) {
        sprintf("... (tail of %s; %s bytes total)", path, format(size))
      },
      lines
    ),
    collapse = "\n"
  )
}

# --- worker-script + dev-path resolution -------------------------------------

#' The package this runner is compiled into ("batchit")
#'
#' Resolved from the runner's own namespace, so it is correct whether batchit is
#' installed or `devtools::load_all()`ed. The `%||% "batchit"` fallback covers
#' only the degenerate case where `packageName()` cannot resolve (e.g. sourced
#' loose), and names the runner the child must load for `.batch_execute`.
#' @noRd
.batch_runner_package <- function() {
  utils::packageName(environment(.batch_runner_package)) %||% "batchit"
}

#' Validate a consumer dev path, or pass NULL through
#'
#' A dev path that was ASKED FOR but is wrong is an error, never a silent
#' fall-through to installed code. The tree MUST exist. It MUST be an R
#' package SOURCE tree, not an installed package. It MUST name the consumer
#' package. Returns the normalised path, or `NULL` for the installed-package
#' case. Shared by
#' [run()]/[run_and_collect()]/[run_and_write_files_atomically()] (processx)
#' and [stream_from_parent_and_write_files_atomically()] (mirai) so all of them
#' enforce the same policy. `consumer_package` is the target's `package` -- the
#' dev tree must be the CONSUMER's source, not the runner's.
#' @noRd
.batch_validate_dev_path <- function(dev_path, consumer_package) {
  if (is.null(dev_path)) {
    return(NULL)
  }
  dev_path <- normalizePath(dev_path, mustWork = FALSE)
  if (!dir.exists(dev_path)) {
    stop(
      ".batch: dev_path was given but does not exist: ",
      dev_path,
      "\n  Refusing to fall back to the installed package, which would ",
      "silently run different code than you asked for.\n  Pass dev_path = NULL ",
      "to use the installed package deliberately.",
      call. = FALSE
    )
  }
  # An INSTALLED package is not a source tree: it carries Meta/package.rds (which
  # R writes at install and a source tree never has), and install has promoted
  # inst/* to the package root, so the load_all()-able source the dispatcher
  # needs is not where a dev tree keeps it. Reject it LOUDLY rather than limp -- a
  # dev_path resolving to an installed layout is a caller bug (e.g. a dev-path
  # probe misfiring under R CMD check), and proceeding is exactly the "wrong
  # dev_path silently limps" failure.
  if (file.exists(file.path(dev_path, "Meta", "package.rds"))) {
    stop(
      ".batch: dev_path is an installed package, not a source tree: ",
      dev_path,
      "\n  (it has Meta/package.rds; an installed layout has no inst/ subdir, so ",
      "the load_all() source is absent.)",
      "\n  Pass dev_path = NULL to use the installed package deliberately.",
      call. = FALSE
    )
  }
  dcf_path <- file.path(dev_path, "DESCRIPTION")
  if (!file.exists(dcf_path)) {
    stop(
      ".batch: dev_path is not an R package source tree ",
      "(no DESCRIPTION): ",
      dev_path,
      call. = FALSE
    )
  }
  dev_pkg <- tryCatch(
    unname(read.dcf(dcf_path, fields = "Package")[1L, 1L]),
    error = function(e) NA_character_
  )
  if (is.na(dev_pkg) || !identical(dev_pkg, consumer_package)) {
    stop(
      sprintf(
        ".batch: dev_path points at package '%s', not '%s': %s",
        dev_pkg,
        consumer_package,
        dev_path
      ),
      call. = FALSE
    )
  }
  dev_path
}

#' Locate the runner's inst/batch_worker.R (always from the RUNNER package)
#'
#' The extraction seam: the worker script is ALWAYS the runner's (batchit's),
#' resolved via `system.file("batch_worker.R", package = <runner>)`, never the
#' consumer's `dev_path`. `system.file()` resolves into batchit's own source
#' `inst/` under `pkgload`/`devtools::load_all()` dev of batchit. It resolves
#' into the installed package otherwise. So batchit's own dev workflow keeps
#' working, while the consumer's tree only ever supplies the consumer's code
#' (via `dev_path`), not the worker script.
#' @noRd
.batch_worker_script <- function() {
  runner <- .batch_runner_package()
  script <- system.file("batch_worker.R", package = runner)
  if (!nzchar(script) || !file.exists(script)) {
    stop(
      ".batch_worker_script(): inst/batch_worker.R not found in the runner package '",
      runner,
      "'",
      call. = FALSE
    )
  }
  script
}

# --- shape A frontends: run() and run_and_collect() --------------------------
# Both run over .batch_run_impl(), in R/batch_execute.R.

#' Run a function once per item, in a fresh worker process, discarding the results
#'
#' Use this as a parallel `for` loop. `fn` runs once per item, each call in
#' its own, brand-new R process (a worker). Up to `n_workers` calls run at the
#' same time. Use this specifically when you don't need anything back in your
#' R session. For example, `fn` writes its own files, or is called purely for
#' a side effect. If you want each call's return value back, use
#' [run_and_collect()] instead; it works identically otherwise. If you want
#' batchit itself to manage output files safely, so a failed item never leaves
#' a half-written file, use [run_and_write_files_atomically()] instead. Files
#' that `fn` writes on its own here get none of that protection. If `fn` is
#' interrupted partway through one of those writes, whatever it already wrote
#' is left exactly as it is.
#'
#' If any item's worker errors, exits unexpectedly, or exceeds `timeout`, the
#' whole call stops immediately with an R error (printing that worker's
#' captured output first). It does not continue past the failure.
#'
#' @param fn The function to run once per item. Either an inline function
#'   written directly in this call, or an object from [package_function()]
#'   naming a function in an installed package. An inline function must be
#'   self-contained: it may only use its own arguments, base R
#'   functions/operators, and `pkg::fun()`-qualified calls to other
#'   packages. See the Advanced section below for accepted and rejected
#'   examples.
#' @param items One entry per call. Each entry is a named list holding the
#'   arguments for that one call to `fn`. Every argument `fn` takes MUST be
#'   named, including one that has a default value. An omitted optional
#'   argument is treated as a mistake, not as "use the default". A silently
#'   dropped argument is therefore caught, rather than passed through
#'   unnoticed. A named entry keeps its name as that item's id, used in
#'   progress messages and error messages. An unnamed entry is identified by
#'   its position instead (1, 2, 3, and so on).
#' @param n_workers How many items to run at the same time (a whole number,
#'   1 or more).
#' @param dev_path Advanced; see the Advanced section below. Leave as `NULL`
#'   (the default) to run the installed version of your package.
#' @param p A progress callback, such as a `progressr` progressor. Leave as
#'   `NULL` (the default) to print simple progress messages instead.
#' @param label An optional short label added to each progress message (for
#'   example, a stage name).
#' @param timeout Maximum time, in seconds, to let one item's worker run
#'   before killing it and reporting it as failed. Defaults to 6 hours; pass
#'   `Inf` to disable the limit.
#' @return Nothing useful (`invisible(NULL)`). Use [run_and_collect()] if you
#'   need each item's return value.
#' @examples
#' \donttest{
#' out_dir <- file.path(tempdir(), "batchit-run-example")
#' dir.create(out_dir)
#' run(
#'   fn = function(x, dir) saveRDS(x^2, file.path(dir, paste0(x, ".rds"))),
#'   items = list(
#'     list(x = 1, dir = out_dir),
#'     list(x = 2, dir = out_dir),
#'     list(x = 3, dir = out_dir)
#'   ),
#'   n_workers = 2
#' )
#' list.files(out_dir)
#' readRDS(file.path(out_dir, "2.rds")) # 4
#'
#' unlink(out_dir, recursive = TRUE)
#' }
#' @family dispatch functions
#' @seealso `vignette("batchit")` for a worked comparison
#'   of all four dispatch functions.
#' @section Advanced:
#' Accepted and rejected inline functions:
#' ```r
#' # Allowed, uses only its own argument and base R:
#' function(x) x^2
#'
#' # Allowed, calls another package's function, package-qualified:
#' function(x) data.table::data.table(x = x, y = x^2)
#'
#' # NOT allowed, `threshold` is not an argument of this function:
#' threshold <- 10
#' function(x) x > threshold
#'
#' # NOT allowed, `my_helper` is a plain call to a function defined
#' # outside this one:
#' my_helper <- function(x) x * 2
#' function(x) my_helper(x)
#' ```
#' When `fn` is a [package_function()] reference, each worker re-checks a
#' hash of its code before it runs. The worker refuses to run if that code
#' changed since you called `package_function()`. See that function's help
#' page for what the hash does and does not cover.
#'
#' `dev_path` names a package source tree to load in the worker with
#' `devtools::load_all()`, instead of the installed package. Name the package
#' from your `package_function()` reference. For an inline `fn`, name
#' batchit's own source tree instead. A path that doesn't exist, or doesn't
#' match the expected package, is an error rather than a silent fall-back to
#' the installed version.
#'
#' batchit does not set BLAS or `data.table` thread counts. If `fn` is
#' itself multi-threaded, reduce its thread count yourself when running
#' several workers at once, to avoid oversubscribing your CPU cores.
#' @export
run <- function(
  fn,
  items,
  n_workers,
  dev_path = NULL,
  p = NULL,
  label = NULL,
  timeout = .BATCH_DEFAULT_TIMEOUT
) {
  .batch_run_impl(
    fn,
    items,
    n_workers,
    dev_path = dev_path,
    collect = FALSE,
    p = p,
    label = label,
    timeout = timeout,
    .caller = "run"
  )
}

#' Run a function once per item, in a fresh worker process, and collect the results
#'
#' Use this as a parallel version of `lapply()`. `fn` runs once per item,
#' each call in its own, brand-new R process (a worker). Up to `n_workers`
#' calls run at the same time. You get back a list of each call's return
#' value. If you don't need the return values, because `fn` writes its own
#' output or is called for a side effect, use [run()] instead. It works
#' identically but discards them.
#'
#' A small object can go directly in an item's arguments. It then travels to
#' the worker with the rest of that item. For a large object, prefer a
#' different route. Have `fn` load it itself inside the worker, for example
#' from disk, rather than pass it through `items`.
#'
#' If any item's worker errors, exits unexpectedly, or exceeds `timeout`,
#' the whole call stops immediately with an R error (printing that worker's
#' captured output first). It never returns a partial list, and it never
#' puts an error object in a failed item's slot.
#'
#' @param fn The function to run once per item. Either an inline function
#'   written directly in this call, or an object from [package_function()]
#'   naming a function in an installed package. An inline function must be
#'   self-contained: it may only use its own arguments, base R
#'   functions/operators, and `pkg::fun()`-qualified calls to other
#'   packages. See [run()]'s Advanced section for accepted and rejected
#'   examples.
#' @param items One entry per call. Each entry is a named list holding the
#'   arguments for that one call to `fn`. Every argument `fn` takes MUST be
#'   named, including one that has a default value. An omitted optional
#'   argument is treated as a mistake, not as "use the default". A silently
#'   dropped argument is therefore caught, rather than passed through
#'   unnoticed. A named entry keeps its name as that item's id, used in
#'   progress messages and error messages. An unnamed entry is identified by
#'   its position instead (1, 2, 3, and so on).
#' @param n_workers How many items to run at the same time (a whole number,
#'   1 or more).
#' @param dev_path Advanced; see [run()]'s Advanced section. Leave as `NULL`
#'   (the default) to run the installed version of your package.
#' @param p A progress callback, such as a `progressr` progressor. Leave as
#'   `NULL` (the default) to print simple progress messages instead.
#' @param label An optional short label added to each progress message (for
#'   example, a stage name).
#' @param timeout Maximum time, in seconds, to let one item's worker run
#'   before killing it and reporting it as failed. Defaults to 6 hours; pass
#'   `Inf` to disable the limit.
#' @return A list of each item's return value, one element per item, **in
#'   the same order as `items`** (not the order workers happened to
#'   finish). The list itself is never named by item id, even if `items`
#'   was named, unlike [run_and_write_files_atomically()] and
#'   [stream_from_parent_and_write_files_atomically()], whose results are.
#' @examples
#' \donttest{
#' squares <- run_and_collect(
#'   fn = function(x) x^2,
#'   items = list(list(x = 2), list(x = 3), list(x = 4)),
#'   n_workers = 2
#' )
#' squares
#' }
#' @family dispatch functions
#' @seealso `vignette("batchit")` for a worked comparison
#'   of all four dispatch functions.
#' @section Advanced:
#' Fresh worker processes are not just a convenience here. They are the
#' memory strategy for memory-heavy work. When one item's analysis peaks at,
#' say, tens of gigabytes, R does not hand that memory back to the operating
#' system on its own. The worker process's exit is what reclaims it. This
#' is why batchit starts a new worker per item instead of reusing one across
#' items.
#'
#' When `fn` is a [package_function()] reference, each worker re-checks a
#' hash of its code before it runs. The worker refuses to run if that code
#' changed since you called `package_function()`. Any warning `fn` raises is
#' captured and re-raised in your R session once that item finishes,
#' labelled with its item id.
#'
#' batchit does not set BLAS or `data.table` thread counts. If `fn` is
#' itself multi-threaded, reduce its thread count yourself when running
#' several workers at once, to avoid oversubscribing your CPU cores.
#' @export
run_and_collect <- function(
  fn,
  items,
  n_workers,
  dev_path = NULL,
  p = NULL,
  label = NULL,
  timeout = .BATCH_DEFAULT_TIMEOUT
) {
  .batch_run_impl(
    fn,
    items,
    n_workers,
    dev_path = dev_path,
    collect = TRUE,
    p = p,
    label = label,
    timeout = timeout,
    .caller = "run_and_collect"
  )
}

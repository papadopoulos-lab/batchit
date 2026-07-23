# Runner-internal helpers -- batchit's own copies, deliberately self-contained so
# batchit depends on no consumer package. Each is a domain-free lift of a helper
# the originating registry pipeline (swereg) used before the dispatcher was
# extracted:
#   .batch_hash_function     <- .hash_function
#   .batch_validate_n_workers <- .validate_n_workers
#   .batch_safe_n_cores      <- .safe_n_cores
# swereg's .threads_per_worker is deliberately NOT carried: thread policy is the
# CONSUMER's, and batchit is thread-agnostic.

# NULL-coalescing operator. Base R gained `%||%` only in 4.4.0; batchit defines
# its own so it works on the declared floor (R >= 4.1.0) and stays self-contained.
`%||%` <- function(x, y) if (is.null(x)) y else x

#' Stable-across-sessions identity hash of a function's body and formals
#'
#' Hashes exactly `list(body(fn), formals(fn))` -- deliberately NOT the whole
#' function object, whose enclosing environment varies across R sessions and
#' would make the hash non-deterministic. This is the identity used by
#' [package_function()]: an edit to a target's body or formals moves the hash, while
#' a comment or whitespace change does not (provided the caller has stripped
#' srcref first via `utils::removeSource()`; see [package_function()]).
#'
#' @param fn A function.
#' @return A single xxhash64 digest string.
#' @noRd
.batch_hash_function <- function(fn) {
  stopifnot(is.function(fn))
  digest::digest(
    list(body = body(fn), formals = formals(fn)),
    algo = "xxhash64"
  )
}

#' Usable core count, never `NA`
#'
#' [parallel::detectCores()] is documented to return `NA` when it cannot
#' determine the core count. An unguarded use feeds that `NA` into a division
#' (`floor(NA / n_workers)`) or a thread count, where it only surfaces much later
#' and a long way from the cause. One helper, so there is one place to be wrong.
#' Carried from the originating pipeline for consumers that want a safe core
#' count; batchit itself sets no thread counts.
#'
#' @param fallback Value to use when the core count cannot be determined.
#' @return A positive integer.
#' @noRd
.batch_safe_n_cores <- function(fallback = 1L) {
  n <- suppressWarnings(parallel::detectCores())
  if (length(n) != 1L || is.na(n) || !is.finite(n) || n < 1L) {
    return(as.integer(fallback))
  }
  as.integer(n)
}

#' Validate a worker count, loudly
#'
#' Callers that do `as.integer(n_workers)` *before* any check silently turn
#' `2.5` into `2`, so the validation never sees the bad value. Validate first,
#' convert second.
#'
#' @param n_workers Candidate worker count.
#' @param what Caller name, for the error message.
#' @return `n_workers` as a positive integer.
#' @noRd
.batch_validate_n_workers <- function(n_workers, what = "n_workers") {
  # The upper bound is not cosmetic. A whole double above .Machine$integer.max
  # passes every other test here, but `as.integer()` turns it into NA (with a
  # warning) -- and that NA then flows PAST this function into callers that
  # mutate state before their own `n_workers <= 1L` check trips on it. So it must
  # be rejected BEFORE coercion, like every other bad value, to keep the "a
  # rejected count changes nothing" invariant true.
  if (
    !is.numeric(n_workers) || length(n_workers) != 1L || is.na(n_workers) ||
      !is.finite(n_workers) || n_workers < 1L ||
      !isTRUE(n_workers == floor(n_workers)) ||
      n_workers > .Machine$integer.max
  ) {
    stop(
      what, ": n_workers must be a single whole number in [1, ",
      .Machine$integer.max, "], got: ",
      paste(utils::capture.output(utils::str(n_workers)), collapse = " "),
      call. = FALSE
    )
  }
  as.integer(n_workers)
}

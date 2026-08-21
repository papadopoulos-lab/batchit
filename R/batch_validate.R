# Caller-input validation for the dispatcher in R/batch.R: work items, item
# ids, the timeout and the collect flag. Item validation is the one part that
# runs at both ends. The child re-runs it because it may hold a different code
# version than the parent hashed.

# --- item validation (runs at BOTH ends) -------------------------------------

#' Validate one work item against its target's formals
#'
#' The contract, enforced identically in the parent (early UX) and the child
#' (correctness -- the child may have loaded a different code version). Every
#' rule here exists because its absence was a real bug:
#'
#' * **Every formal must be named, including optional ones.** An optional formal
#'   was silently dropped for a year in the originating pipeline precisely
#'   because the old check only demanded the required ones. Demanding all of them
#'   makes "an optional arg silently absent" indistinguishable from a typo, which
#'   is the point.
#' * **No positional, duplicate, or blank names**, and **no argument that is not
#'   a formal** -- a typo'd field name must be rejected, not silently ignored.
#'
#' @param target A `package_function` descriptor (its `formal_names` is the schema).
#' @param args The item: a fully-named list of arguments.
#' @param where "parent" or "child", for the error message.
#' @param id Optional item id, for the error message.
#' @return `TRUE`, invisibly; stops on any violation.
#' @noRd
.batch_validate_item <- function(target, args, where = "parent", id = NULL) {
  loc <- if (is.null(id)) "" else sprintf(" [item '%s']", id)
  lead <- sprintf(
    ".batch %s-validation%s: %s::%s",
    where,
    loc,
    target$package,
    target$symbol
  )
  .batch_validate_item_against_formals(target$formal_names, lead, args)
}

#' The formal-name-schema core of item validation. Two callers share it.
#' [.batch_validate_item()] passes a `package_function` descriptor's
#' `formal_names`. The `adhoc` sibling `.batch_validate_adhoc_item()` passes a
#' bare closure's own `formal_names`; it has no package/symbol identity to
#' build a lead from. See `R/batch_adhoc.R` (DESIGN.md sections 2 and 5).
#' Takes an already-built `lead` string so both callers keep their own
#' distinct error-message shape.
#' @noRd
.batch_validate_item_against_formals <- function(formal_names, lead, args) {
  if (!is.list(args)) {
    stop(
      sprintf("%s -- item must be a list, got %s", lead, class(args)[1L]),
      call. = FALSE
    )
  }
  nms <- names(args)
  if (length(args) > 0L && (is.null(nms) || any(!nzchar(nms)))) {
    stop(
      sprintf(
        "%s -- every argument must be named (no positional arguments)",
        lead
      ),
      call. = FALSE
    )
  }
  if (anyDuplicated(nms)) {
    dup <- unique(nms[duplicated(nms)])
    stop(
      sprintf(
        "%s -- duplicate argument name(s): %s",
        lead,
        paste(dup, collapse = ", ")
      ),
      call. = FALSE
    )
  }
  extra <- setdiff(nms, formal_names)
  if (length(extra) > 0L) {
    stop(
      sprintf(
        "%s -- argument(s) that are not formals of the target: %s",
        lead,
        paste(extra, collapse = ", ")
      ),
      call. = FALSE
    )
  }
  missing <- setdiff(formal_names, nms)
  if (length(missing) > 0L) {
    stop(
      sprintf(
        paste0(
          "%s -- formal(s) not supplied: %s. Every formal must be named ",
          "explicitly, including optional ones -- that is what catches a ",
          "silently-defaulted argument (the shape of a real dropped-argument bug)."
        ),
        lead,
        paste(missing, collapse = ", ")
      ),
      call. = FALSE
    )
  }
  invisible(TRUE)
}

#' Derive stable per-item ids for `run()`/`run_and_collect()` (item names, else index)
#'
#' A named item keeps its name; an unnamed one gets its 1-based index. The
#' result must be unique, so a reported failure identifies exactly one item. A
#' duplicate name is a caller error, not something to paper over. So is a name
#' that collides with another item's index.
#' @noRd
.batch_item_ids <- function(items) {
  n <- length(items)
  ids <- names(items)
  if (is.null(ids)) {
    ids <- rep_len("", n)
  }
  ids[is.na(ids)] <- ""
  blank <- !nzchar(ids)
  ids[blank] <- as.character(seq_len(n))[blank]
  if (anyDuplicated(ids)) {
    stop(
      sprintf(
        paste0(
          ".batch_item_ids(): item ids are not unique: %s. Name items ",
          "uniquely, or leave them all unnamed to use positional indices."
        ),
        paste(unique(ids[duplicated(ids)]), collapse = ", ")
      ),
      call. = FALSE
    )
  }
  ids
}

#' Validate an explicit id vector for `stream_from_parent_and_write_files_atomically()`
#' (non-empty, non-NA, unique)
#' @noRd
.batch_check_ids <- function(ids) {
  ids <- as.character(ids)
  if (any(is.na(ids)) || any(!nzchar(ids))) {
    stop(
      "stream_from_parent_and_write_files_atomically(): every id must be a non-empty, non-NA string",
      call. = FALSE
    )
  }
  if (anyDuplicated(ids)) {
    stop(
      "stream_from_parent_and_write_files_atomically(): ids must be unique: ",
      paste(unique(ids[duplicated(ids)]), collapse = ", "),
      call. = FALSE
    )
  }
  ids
}

#' Validate the `timeout` config -- a single positive number of seconds, or Inf
#'
#' Rejected loudly rather than silently disabled. A vector, `NA`, a
#' non-numeric, zero or a negative would otherwise do one of two harmful
#' things. `c(1, 2)` or `NA` would turn the timeout OFF without a word. A
#' negative would make every item time out instantly. Validate before any
#' early return so an empty workload cannot hide a bad value.
#' @noRd
.batch_validate_timeout <- function(timeout, what) {
  if (
    length(timeout) != 1L ||
      !is.numeric(timeout) ||
      is.na(timeout) ||
      timeout <= 0
  ) {
    stop(
      sprintf(
        paste0(
          "%s: timeout must be a single positive number of seconds ",
          "(or Inf to disable); got: %s"
        ),
        what,
        paste(utils::capture.output(utils::str(timeout)), collapse = " ")
      ),
      call. = FALSE
    )
  }
  as.numeric(timeout)
}

#' Validate the `collect` flag -- a single TRUE/FALSE
#' @noRd
.batch_validate_collect <- function(collect, what) {
  if (!is.logical(collect) || length(collect) != 1L || is.na(collect)) {
    stop(
      sprintf("%s: collect must be a single TRUE or FALSE", what),
      call. = FALSE
    )
  }
  collect
}

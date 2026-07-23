# Phase 6' Unit 3 (see PHASE6_DESIGN.md sections 1, 2, 4, 5, 9.4): the `adhoc`
# fn_kind -- dispatch a bare closure VALUE instead of a package_function()
# descriptor. Gated by a best-effort static self-containedness LINT
# (codetools::findGlobals()) applied at BOTH ends (parent: early UX at
# dispatch time -- run()/run_and_collect() / run_and_write_files_atomically()
# with a bare closure; child: correctness, inside .batch_check_envelope() --
# a worker must never simply trust that an envelope reaching it actually went
# through a frontend's own check). A closure that PASSES the lint is
# unconditionally rebased onto
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
#' Runs at BOTH ends: a frontend (`run()`/`run_and_collect()` /
#' `run_and_write_files_atomically()` with a bare closure) calls this at
#' dispatch time for early UX; `.batch_check_envelope()`
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

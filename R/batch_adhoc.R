# See DESIGN.md sections 2, 3, 5, 6 and 7: the `adhoc`
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
# NARROWED PROMISE (design section 6): this is a best-effort static lint that
# rejects DIRECTLY DETECTABLE unqualified global references. It does NOT
# prove behavioural closure, hermetic execution, portability, or dependency
# identity. Known blind spots: get()/mget()/assign()/a string-argument
# do.call(), eval(parse(...)), substitute(), .GlobalEnv, a formula's/
# attribute's own environment, <<-, S4/R5/R6 method dispatch, and any other
# ambient state a closure can reach without a syntactically visible free
# variable. Production stages stay on fn_kind = "package" (a hash-verified,
# auditable descriptor); fn_kind = "adhoc" is for ad-hoc dispatch only.

#' Self-containedness lint for an adhoc closure (design DESIGN.md section 6)
#'
#' This lint runs at BOTH ends. A frontend calls it at dispatch time, for early
#' feedback: `run()`, `run_and_collect()` or
#' `run_and_write_files_atomically()`, each with a bare closure.
#' `.batch_check_envelope()` calls it again in the CHILD. A worker must never
#' simply trust that whatever reached it over the wire actually passed a
#' frontend's own check.
#'
#' Rejects, in order, NAMING the offending symbol(s) where relevant:
#' * a non-function;
#' * a primitive (no real formals/body/environment to lint or rebase);
#' * a closure whose formals include `...` (same prohibition as a package
#'   [package_function()]);
#' * a closure that references a global which is neither (a) nor (b) below.
#'   The check inspects BOTH `codetools::findGlobals()`'s `$functions` and
#'   `$variables`. (a) is a name bound in `baseenv()`. That covers every base
#'   function, base operator, and base constant: `+`, `if`, `{`, `::`, `T`,
#'   `pi`, and the rest. (b) is a `pkg::`/`pkg:::`-qualified reference.
#'   Verified: codetools does not resolve the identifiers either side of
#'   `::`/`:::` as globals. It reports only the `::`/`:::` call itself, and
#'   that call is itself a base function, so `pkg::fun()` is never
#'   independently flagged.
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
    stop(
      sprintf("%s: adhoc `fn` must be a function, got %s", lead, class(fn)[1L]),
      call. = FALSE
    )
  }
  if (is.primitive(fn)) {
    stop(
      sprintf(
        paste0(
          "%s: adhoc `fn` must be a closure, not a primitive -- a primitive has ",
          "no real formals/body/environment to lint or rebase"
        ),
        lead
      ),
      call. = FALSE
    )
  }
  fmls <- names(formals(fn))
  if (is.null(fmls)) {
    fmls <- character(0)
  }
  if ("..." %in% fmls) {
    stop(
      sprintf(
        paste0(
          "%s: adhoc `fn` takes `...`, which is prohibited -- same as a package ",
          "package_function(): a dispatch target must have a fixed formal list so a ",
          "mistyped or missing argument can be caught."
        ),
        lead
      ),
      call. = FALSE
    )
  }

  globals <- codetools::findGlobals(fn, merge = FALSE)
  candidates <- unique(c(globals$functions, globals$variables))
  is_base <- vapply(
    candidates,
    function(nm) {
      isTRUE(tryCatch(
        exists(nm, envir = baseenv(), inherits = FALSE),
        error = function(e) FALSE
      ))
    },
    logical(1)
  )
  bad <- sort(candidates[!is_base])
  if (length(bad) > 0L) {
    stop(
      sprintf(
        paste0(
          "%s: adhoc `fn` is not self-contained. It references global(s) that ",
          "are neither base R nor `pkg::`-qualified: %s. Every value the closure ",
          "needs must be a base function/operator/constant, a declared formal, ",
          "or referenced via an explicit `pkg::fun()` call. (This is a ",
          "best-effort static lint; see the \"Choosing a dispatch function\" ",
          "vignette for its documented blind spots. It does not prove ",
          "behavioural closure.)"
        ),
        lead,
        paste(bad, collapse = ", ")
      ),
      call. = FALSE
    )
  }
  invisible(TRUE)
}

#' Rebase an accepted adhoc closure onto `baseenv()` (design section 6, mandatory)
#'
#' Called ONLY after `.batch_lint_adhoc_fn()` accepted `fn`. The parent calls
#' it once, before the closure is ever serialized. The child calls it again,
#' defensively, right before `do.call()` (see `.batch_execute()`). That second
#' call covers a hand-crafted envelope that reached the worker with a closure
#' which was never rebased. Severs the closure's original enclosing
#' environment and reconnects it to `baseenv()` instead. There is no
#' env-preservation mode. A closure that needs anything beyond base R, its own
#' formals and `pkg::`-qualified calls is out of scope for `adhoc`, by design.
#' @noRd
.batch_rebase_adhoc_closure <- function(fn) {
  # Strip attributes FIRST: `structure(fn, payload = <big/secret object>)` is a
  # carrier the findGlobals lint never sees (the object is not a free global)
  # and would otherwise serialize to the child. Removing all attributes off a
  # closure does not affect how it CALLS (srcref/class/etc. are not needed to
  # run it). Then sever the enclosing environment. Together these enforce "code,
  # not captured data" for the two common carriers; the remaining exotic ones
  # (an object graph embedded in a default-argument expression or a bytecode
  # constant) stay documented blind spots (design section 6), not enforced.
  attributes(fn) <- NULL
  environment(fn) <- baseenv()
  fn
}

#' Validate one adhoc item's args against the closure's OWN formals
#'
#' The `adhoc` sibling of [.batch_validate_item()]. That function is keyed to a
#' `package_function` descriptor's package+symbol, for its error-message lead.
#' The rules here are identical: every formal named explicitly, and no
#' positional, duplicate or unknown argument. See
#' [.batch_validate_item_against_formals()]. This one applies those rules
#' against a bare formal-name vector instead, because an adhoc closure carries
#' no package/symbol identity to report.
#' @noRd
.batch_validate_adhoc_item <- function(
  formal_names,
  args,
  where = "parent",
  id = NULL
) {
  loc <- if (is.null(id)) "" else sprintf(" [item '%s']", id)
  lead <- sprintf(".batch %s-validation%s: <adhoc fn>", where, loc)
  .batch_validate_item_against_formals(formal_names, lead, args)
}

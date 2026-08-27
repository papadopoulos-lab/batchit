# Parent-side inspection of a result envelope, for the dispatcher in R/batch.R.
# The inspector is total: a malformed result becomes a reason string, never a
# throw. The parent re-emits the warnings the child captured, tagged by item id.

#' Inspect a result envelope in the parent: accept it, or say why not
#'
#' Makes the result-envelope fields load-bearing rather than decorative. It is
#' TOTAL: a non-list or otherwise malformed result becomes a `reason`, never a
#' throw. It therefore flows through the caller's uniform failure path, like
#' any other failure. That path logs, then stops loudly. Shared by both
#' frontends so they accept/reject identically. Returns
#' `list(ok, reason, value, warnings)`.
#'
#' Checks, in order:
#'
#' 1. the result is a list;
#' 2. protocol;
#' 3. status;
#' 4. the id matches the dispatched id;
#' 5. on success, the identity of the code that actually ran;
#' 6. that a successful envelope actually carries a `value` field.
#'
#' For `fn_kind = "package"`, check 5 requires the FULL executed-target
#' identity -- package, symbol AND hash -- to match what was dispatched. The
#' contract defines identity as all three, since a body/formals hash can
#' collide across two functions. For `fn_kind = "adhoc"` there is no package
#' identity, so check 5 uses `expected_nonce` (see below) instead.
#'
#' `expected_outputs`/`expected_attempt` are both `NULL` by default. A caller
#' sets them only when it inspects a `run_and_write_files_atomically()`
#' result, which is a declared-output commit. The value field is then a commit
#' record, not raw data. It is checked against the `outputs` actually
#' DISPATCHED for this item (design DESIGN.md section 4.5). Names AND paths
#' must match exactly. A stale or substituted result is otherwise rejected,
#' the same way a wrong id or a wrong target identity is. The record's
#' `attempt` token is checked against `expected_attempt` UNCONDITIONALLY.
#' Existing (return-value) callers pass neither and are unaffected.
#'
#' `expected_nonce` is `NULL` by default. A caller sets it only when it
#' inspects an `adhoc` (Phase 6' Unit 3) result. An adhoc envelope carries no
#' package/symbol/hash descriptor for the child to echo back. Identity is
#' instead bound to the id, already checked above, PLUS a fresh, high-entropy
#' per-dispatch nonce. The parent issues that nonce, and the child echoes it
#' in its result `target` field as `list(fn_kind = "adhoc", nonce = <nonce>)`
#' (design DESIGN.md section 7). `target` itself is unused on this path, and
#' may be `NULL`.
#' @noRd
.batch_inspect_result <- function(
  envelope,
  expected_id,
  target,
  expected_outputs = NULL,
  expected_attempt = NULL,
  expected_nonce = NULL
) {
  # Total BY CONSTRUCTION: any error while inspecting a hostile or corrupt result
  # -- a classed object with a throwing `[[`/`format` method, a field that errors
  # on access -- becomes a failure reason, so it flows through the caller's
  # uniform .fail() path rather than crashing the pool.
  return(tryCatch(
    .batch_inspect_result_impl(
      envelope,
      expected_id,
      target,
      expected_outputs,
      expected_attempt,
      expected_nonce
    ),
    error = function(e) {
      return(list(
        ok = FALSE,
        reason = paste0(
          "malformed result envelope: ",
          .batch_condition_message(e)
        )
      ))
    }
  ))
}

#' @noRd
.batch_inspect_result_impl <- function(
  envelope,
  expected_id,
  target,
  expected_outputs = NULL,
  expected_attempt = NULL,
  expected_nonce = NULL
) {
  if (!is.list(envelope)) {
    return(list(
      ok = FALSE,
      reason = sprintf(
        "result is not a list (got %s)",
        class(envelope)[1L]
      )
    ))
  }
  # Reject missing / blank / DUPLICATE field names: `$` returns the first match,
  # so a result carrying both `protocol = 1L` and `protocol = 99L` (or duplicate
  # id/target fields) could otherwise smuggle a bad value behind a good one.
  nm <- names(envelope)
  if (is.null(nm) || any(!nzchar(nm)) || anyDuplicated(nm)) {
    return(list(
      ok = FALSE,
      reason = "result envelope has missing, blank, or duplicate field names"
    ))
  }
  # Every field is read with EXACT `[[`, never `$`: `$` partial-matches, so an
  # absent `status`/`id`/`target` beside a longer-named field (`status_x`) would
  # otherwise resolve to the wrong value. (`target` is the dispatched descriptor,
  # our own trusted list, so `target$...` stays `$`.)
  if (!identical(envelope[["protocol"]], .BATCH_PROTOCOL)) {
    return(list(
      ok = FALSE,
      reason = sprintf(
        "result envelope has wrong/missing protocol: %s",
        format(envelope[["protocol"]] %||% "<none>")
      )
    ))
  }
  # id is checked BEFORE status and STRICTLY (a single character, identical -- no
  # numeric-to-string coercion): a result must be the one dispatched for THIS
  # item even when it carries an error. The worker echoes the dispatched id on
  # every path, including its load-failure fallback, so an error result still
  # gets id-validated here and its message surfaced at the status check below.
  eid <- envelope[["id"]]
  if (
    !is.character(eid) ||
      length(eid) != 1L ||
      !identical(eid, as.character(expected_id))
  ) {
    return(list(
      ok = FALSE,
      reason = sprintf(
        "result envelope id mismatch: expected '%s', got %s",
        expected_id,
        format(eid %||% "<none>")
      )
    ))
  }
  if (!identical(envelope[["status"]], "ok")) {
    # `error` may be malformed (e.g. a bare string) -- do not let extracting the
    # message throw; the inspector stays total.
    msg <- tryCatch(envelope[["error"]][["message"]], error = function(e) NULL)
    if (!is.character(msg) || length(msg) != 1L) {
      msg <- "failed with no error message"
    }
    return(list(ok = FALSE, reason = sprintf("returned an error: %s", msg)))
  }
  tgt <- envelope[["target"]]
  # `anyDuplicated(names(tgt))`: a nested `target = list(package="a",
  # package="evil", ...)` must not let the first `package` win and leave the
  # executed identity ambiguous.
  if (!is.list(tgt) || anyDuplicated(names(tgt))) {
    return(list(
      ok = FALSE,
      reason = "result envelope has a malformed target field"
    ))
  }
  if (!is.null(expected_nonce)) {
    # adhoc (design section 7): no package identity to
    # check -- bind on fn_kind == "adhoc" plus the per-dispatch nonce the
    # parent issued and the child echoed back (id was already checked above).
    if (
      !is.character(expected_nonce) ||
        length(expected_nonce) != 1L ||
        is.na(expected_nonce) ||
        !identical(tgt[["fn_kind"]], "adhoc") ||
        !identical(tgt[["nonce"]], expected_nonce)
    ) {
      return(list(
        ok = FALSE,
        reason = "result came from a different adhoc dispatch than expected (nonce mismatch)"
      ))
    }
  } else {
    if (
      !identical(tgt[["package"]], target$package) ||
        !identical(tgt[["symbol"]], target$symbol) ||
        !identical(tgt[["hash"]], target$hash)
    ) {
      return(list(
        ok = FALSE,
        reason = sprintf(
          "result came from a different target than dispatched (expected %s::%s, hash %s)",
          target$package,
          target$symbol,
          target$hash
        )
      ))
    }
  }
  if (!("value" %in% names(envelope))) {
    return(list(
      ok = FALSE,
      reason = "successful result envelope has no value field"
    ))
  }
  warnings <- envelope[["warnings"]]
  # Never coerce an arbitrary object (as.character() on a closure throws); a
  # non-character warnings field is simply dropped, keeping the inspector total.
  if (!is.character(warnings)) {
    warnings <- character()
  }

  # Declared-output commit result (run_and_write_files_atomically()): the
  # value is a small commit record, never raw data. Validate it matches
  # EXACTLY what was dispatched -- names AND paths of the committed map, AND
  # the attempt token THIS dispatch issued -- so a stale or substituted
  # result can never be accepted as this item's commit.
  if (!is.null(expected_outputs)) {
    val <- envelope[["value"]]
    val_nm <- names(val)
    # The commit record's names must be EXACTLY {"committed", "attempt"} --
    # no missing, no blank, and critically no EXTRA field. Allowing extras
    # would let a worker smuggle arbitrary raw data back to the parent (e.g.
    # `list(committed = ..., attempt = ..., raw = <huge>)`), defeating the
    # whole point of run_and_write_files_atomically() (only a small commit
    # record ever crosses back; see design DESIGN.md section 4.5).
    if (
      !is.list(val) ||
        is.null(val_nm) ||
        any(!nzchar(val_nm)) ||
        anyDuplicated(val_nm) ||
        !identical(sort(val_nm), sort(c("committed", "attempt")))
    ) {
      return(list(
        ok = FALSE,
        reason = paste0(
          "commit result value must have EXACTLY the fields committed, attempt ",
          "(no more, no fewer) -- got: ",
          paste(val_nm %||% "<none>", collapse = ", ")
        )
      ))
    }
    committed <- val[["committed"]]
    if (
      !is.character(committed) ||
        is.null(names(committed)) ||
        anyDuplicated(names(committed)) ||
        !identical(sort(names(committed)), sort(names(expected_outputs))) ||
        !identical(
          committed[order(names(committed))],
          expected_outputs[order(names(expected_outputs))]
        )
    ) {
      return(list(
        ok = FALSE,
        reason = "committed output map does not match the outputs dispatched for this item"
      ))
    }
    attempt <- val[["attempt"]]
    if (
      !is.character(attempt) ||
        length(attempt) != 1L ||
        is.na(attempt) ||
        !nzchar(attempt)
    ) {
      return(list(
        ok = FALSE,
        reason = "commit attempt token is missing or not a non-empty string"
      ))
    }
    # The attempt token is UNCONDITIONALLY the token THIS dispatch issued --
    # a stale, misrouted, or substituted result envelope is rejected here.
    if (!identical(attempt, expected_attempt)) {
      return(list(
        ok = FALSE,
        reason = "commit attempt token does not match what was dispatched"
      ))
    }
  }

  return(list(
    ok = TRUE,
    reason = NULL,
    value = envelope[["value"]],
    warnings = warnings
  ))
}

#' Re-emit a completed item's captured warnings in the parent, tagged by id
#' @noRd
.batch_surface_warnings <- function(warnings, id) {
  for (w in warnings) {
    warning(sprintf("[batch item '%s'] %s", id, w), call. = FALSE)
  }
  return(invisible(NULL))
}

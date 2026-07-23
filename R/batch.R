# One dispatcher, one contract. batchit was extracted from swereg after Phases
# 0-3 of the one-dispatcher project (see README.md and swereg's PROJECT.md); this
# is that dispatcher, now standing on its own.
#
# The file is package-neutral by design: it imports nothing from any consumer's
# domain code, so the same runner serves any consumer package. The only helpers
# it leans on -- .batch_hash_function(), .batch_validate_n_workers() -- are
# batchit's own, domain-free, and live in R/batch_helpers.R. (.batch_log_tail()
# lives here.)
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
# batch_stream(target, ids, ...) is shape B: the parent IS the producer, items
# are generated lazily under backpressure (mirai bounded queue).
# All four share target/fn resolution, both-end validation, the result
# envelope, and failure semantics. They differ only in internal transport,
# which is private.
#
# Runner vs consumer (the extraction seam): batchit is the RUNNER; a target's
# `package` names the CONSUMER, which is a DIFFERENT package. The worker script is
# always the runner's (.batch_worker_script() -> system.file(package = batchit));
# `dev_path`, when given, is the CONSUMER's source tree and supplies only the
# consumer's code. The worker and the mirai daemon each load BOTH packages (see
# inst/batch_worker.R and .batch_stream() below).

# Bumped to 2 for Phase 6' Unit 1 (see PHASE6_DESIGN.md): the envelope gained a
# REQUIRED meta$fn_kind discriminator ("package" | "adhoc") plus the
# declared-output commit fields (outputs/marker/style/attempt/details) used by
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
# run_and_collect() / batch_stream()'s `timeout` formal (documented there
# rather than exported).
.BATCH_DEFAULT_TIMEOUT <- 6 * 3600

# --- target descriptor -------------------------------------------------------

#' Describe a dispatch target
#'
#' A target is a *descriptor*, never a function object, name, or closure:
#' package + symbol + a hash of the function's body and formals. Package name
#' plus symbol alone is insufficient -- development code, installed code and
#' cache identity can differ -- so the descriptor also records a
#' `digest(list(body, formals))` identity hash. The child re-computes that hash
#' after loading the target and refuses to run if it differs, which closes the
#' stale-code / wrong-version hole a bare package+symbol reference would leave.
#'
#' The hash is deliberately narrow: it covers the target's OWN body and formals
#' only. A changed helper the target calls, a namespace constant it closes over,
#' an S4/R6 method table, or a dependency's version are outside it -- so this
#' proves "same target definition", not "provably identical behaviour", and the
#' latter is not claimed. `utils::removeSource()` is applied before hashing so
#' the identity is independent of srcref (comments / whitespace): otherwise an
#' installed package (no srcref) and a `devtools::load_all()` tree (srcref)
#' disagree on identical code, which is exactly what happens when the parent runs
#' the installed package while a worker dev-loads the source.
#'
#' A target that takes `...` is rejected: arbitrary dots are incompatible with
#' the reliable detection of a mistyped or missing argument that the contract
#' depends on.
#'
#' @param package Package holding the target (character scalar). This is the
#'   CONSUMER package; it need not be `batchit`.
#' @param symbol Name of the target function in that package (character scalar).
#'   May be an internal (unexported) symbol -- it is resolved in the package's
#'   namespace.
#' @param version Optional recorded version; defaults to the package's installed
#'   version. Advisory only -- the hash is what the child actually checks.
#' @return A `package_function` descriptor: a list with class `"package_function"` and
#'   elements `package`, `symbol`, `version`, `hash`, `formal_names`.
#' @examples
#' \dontrun{
#' # target an exported or internal function of any installed package
#' t <- package_function("mypkg", "process_one_slice")
#' t$formal_names
#' }
#' @export
package_function <- function(package, symbol, version = NULL) {
  if (!is.character(package) || length(package) != 1L || !nzchar(package)) {
    stop("package_function(): `package` must be a non-empty string", call. = FALSE)
  }
  if (!is.character(symbol) || length(symbol) != 1L || !nzchar(symbol)) {
    stop("package_function(): `symbol` must be a non-empty string", call. = FALSE)
  }
  ns <- tryCatch(
    asNamespace(package),
    error = function(e) {
      stop(
        sprintf("package_function(): package '%s' is not available: %s",
          package, conditionMessage(e)),
        call. = FALSE
      )
    }
  )
  if (!exists(symbol, envir = ns, inherits = FALSE)) {
    stop(
      sprintf("package_function(): '%s' is not defined in package '%s'",
        symbol, package),
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
  if (is.null(fmls)) fmls <- character(0)
  if ("..." %in% fmls) {
    stop(
      sprintf(
        paste0("package_function(): %s::%s takes `...`, which is incompatible ",
          "with reliable argument validation. A dispatch target must have a ",
          "fixed formal list so a mistyped or missing argument can be caught."),
        package, symbol),
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
  lead <- sprintf(".batch %s-validation%s: %s::%s",
    where, loc, target$package, target$symbol)
  .batch_validate_item_against_formals(target$formal_names, lead, args)
}

#' The formal-name-schema core of item validation, shared by [.batch_validate_item()]
#' (a `package_function` descriptor's `formal_names`) and the `adhoc` sibling
#' `.batch_validate_adhoc_item()` (a bare closure's own `formal_names`, no
#' package/symbol identity to build a lead from) -- see `R/batch_adhoc.R`
#' (Phase 6' Unit 3, PHASE6_DESIGN.md sections 1, 4). Takes an already-built
#' `lead` string so both callers keep their own distinct error-message shape.
#' @noRd
.batch_validate_item_against_formals <- function(formal_names, lead, args) {
  if (!is.list(args)) {
    stop(sprintf("%s -- item must be a list, got %s",
      lead, class(args)[1L]), call. = FALSE)
  }
  nms <- names(args)
  if (length(args) > 0L && (is.null(nms) || any(!nzchar(nms)))) {
    stop(sprintf("%s -- every argument must be named (no positional arguments)",
      lead), call. = FALSE)
  }
  if (anyDuplicated(nms)) {
    dup <- unique(nms[duplicated(nms)])
    stop(sprintf("%s -- duplicate argument name(s): %s",
      lead, paste(dup, collapse = ", ")), call. = FALSE)
  }
  extra <- setdiff(nms, formal_names)
  if (length(extra) > 0L) {
    stop(sprintf("%s -- argument(s) that are not formals of the target: %s",
      lead, paste(extra, collapse = ", ")), call. = FALSE)
  }
  missing <- setdiff(formal_names, nms)
  if (length(missing) > 0L) {
    stop(sprintf(
      paste0("%s -- formal(s) not supplied: %s. Every formal must be named ",
        "explicitly, including optional ones -- that is what catches a ",
        "silently-defaulted argument (the shape of a real dropped-argument bug)."),
      lead, paste(missing, collapse = ", ")), call. = FALSE)
  }
  invisible(TRUE)
}

# --- private IPC codec -------------------------------------------------------
# The runner owns its OWN transport, matched at both ends, deliberately separate
# from any persistence a consumer uses for its scientific files. In particular
# the read side does NOT run any R6/duck-typed post-read hook: envelopes are
# always plain lists. The wire format is qs2-standard, so the --vanilla worker
# can read/write it with bare `qs2::` before any package loads.

#' @noRd
.batch_write_envelope <- function(object, path) {
  dir <- dirname(path)
  tmp <- tempfile(pattern = paste0(basename(path), ".tmp"), tmpdir = dir)
  ok <- FALSE
  on.exit(if (!ok) unlink(tmp, force = TRUE), add = TRUE)
  qs2::qs_save(object, tmp)
  if (!file.rename(tmp, path)) {
    stop(".batch_write_envelope(): could not rename ", tmp, " -> ", path,
      call. = FALSE)
  }
  ok <- TRUE
  invisible(path)
}

#' @noRd
.batch_read_envelope <- function(path) {
  qs2::qs_read(path)
}

#' Extract a condition's message without ever throwing
#'
#' `conditionMessage()` dispatches, so a hostile condition (from a target, or a
#' classed object with a registered `conditionMessage` method) could itself throw
#' -- which would escape an error handler and defeat the "total" guarantee. Used
#' wherever a condition arising from untrusted code is rendered to text.
#' @noRd
.batch_condition_message <- function(e) {
  tryCatch(conditionMessage(e), error = function(e2) "<unprintable condition>")
}

#' Validate the STRUCTURE of an input envelope (not its arguments)
#'
#' Cheap structural gate run in the child before anything trusts the envelope:
#' protocol number, meta presence, and the identity fields must be well-formed
#' strings. Without this the protocol number is decorative and a version-skewed
#' or corrupt envelope produces a confusing error deep inside resolution instead
#' of a clear one here. Argument validation (against the target's formals) is a
#' separate step -- see `.batch_validate_item()`.
#'
#' Branches on `meta$fn_kind` (design PHASE6_DESIGN.md sections 1/4): `"package"`
#' requires `package`/`symbol`/`hash` and forbids `fn`/`nonce`; `"adhoc"` is
#' the reverse -- requires `fn` (the closure, re-linted for self-containedness
#' HERE -- design section 5, `.batch_lint_adhoc_fn()` in `R/batch_adhoc.R` --
#' the CHILD-side correctness copy of the check a frontend already ran at
#' dispatch time) and `nonce` (its per-dispatch identity token, design section
#' 9.4), and forbids `package`/`symbol`/`hash` (there is no package to
#' resolve). Also branches on whether `meta$outputs` is present: absent means today's
#' return-value dispatch (`collect` required; `style`/`marker`/`attempt`
#' forbidden); present means a declared-output commit dispatch (`style`/
#' `marker`/`attempt` required; `collect` forbidden) -- design section 4. Any
#' `meta` field outside the known set is rejected, not silently ignored.
#' @noRd
.batch_check_envelope <- function(env) {
  if (!is.list(env)) {
    stop(".batch envelope is not a list (got ", class(env)[1L], ")", call. = FALSE)
  }
  # Duplicate outer field names would let field selection pick the first of two;
  # and every field is read with EXACT `[[`, never `$` -- `$` partial-matches, so
  # `env$meta` would match an outer field named `metadata`, and `meta$dev_path` a
  # field named `dev_path_payload`, letting a noncanonical name control behaviour.
  if (anyDuplicated(names(env))) {
    stop(".batch envelope has duplicate field names", call. = FALSE)
  }
  # Unknown top-level fields are rejected, not ignored -- the same policy
  # already applied to meta (design PHASE6_DESIGN.md section 4) extended to
  # the outer envelope, so a typo'd or smuggled top-level field cannot ride
  # along silently.
  known_top_fields <- c("protocol", "meta", "args")
  unknown_top <- setdiff(names(env), known_top_fields)
  if (length(unknown_top) > 0L) {
    stop(sprintf(".batch envelope has unknown top-level field(s): %s",
      paste(unknown_top, collapse = ", ")), call. = FALSE)
  }
  if (!identical(env[["protocol"]], .BATCH_PROTOCOL)) {
    stop(sprintf(".batch envelope protocol mismatch: expected %s, got %s",
      .BATCH_PROTOCOL, format(env[["protocol"]] %||% "<none>")), call. = FALSE)
  }
  meta <- env[["meta"]]
  if (!is.list(meta)) {
    stop(".batch envelope has no meta list", call. = FALSE)
  }
  if (anyDuplicated(names(meta))) {
    stop(".batch envelope meta has duplicate field names", call. = FALSE)
  }
  known_meta_fields <- c("fn_kind", "id", "runner_package", "dev_path", "version",
    "package", "symbol", "hash", "collect", "outputs", "marker", "style",
    "attempt", "details", "fn", "nonce")
  unknown <- setdiff(names(meta), known_meta_fields)
  if (length(unknown) > 0L) {
    stop(sprintf(".batch envelope meta has unknown field(s): %s",
      paste(unknown, collapse = ", ")), call. = FALSE)
  }

  # id / runner_package are required regardless of fn_kind: id lets the parent
  # match a result to the item it dispatched; runner_package is a load-deciding
  # field (it names the namespace that supplies .batch_execute), so both
  # transports must accept the SAME complete schema, or one could pass an
  # envelope the other's worker rejects.
  for (f in c("id", "runner_package")) {
    v <- meta[[f]]
    if (!is.character(v) || length(v) != 1L || is.na(v) || !nzchar(v)) {
      stop(sprintf(".batch envelope meta$%s is missing or not a non-empty string", f),
        call. = FALSE)
    }
  }

  fn_kind <- meta[["fn_kind"]]
  if (!is.character(fn_kind) || length(fn_kind) != 1L || is.na(fn_kind) ||
      !(fn_kind %in% c("package", "adhoc"))) {
    stop(sprintf(
      ".batch envelope meta$fn_kind is missing or not one of \"package\"/\"adhoc\": %s",
      format(fn_kind %||% "<none>")), call. = FALSE)
  }
  if (identical(fn_kind, "package")) {
    for (f in c("package", "symbol", "hash")) {
      v <- meta[[f]]
      if (!is.character(v) || length(v) != 1L || is.na(v) || !nzchar(v)) {
        stop(sprintf(".batch envelope meta$%s is missing or not a non-empty string", f),
          call. = FALSE)
      }
    }
    if (!is.null(meta[["fn"]]) || !is.null(meta[["nonce"]])) {
      stop(paste0(".batch envelope: meta$fn/meta$nonce are forbidden when ",
        "fn_kind is \"package\" (adhoc-only fields)"), call. = FALSE)
    }
  } else {
    # fn_kind == "adhoc" (Phase 6' Unit 3, PHASE6_DESIGN.md sections 1, 4, 5):
    # no package/symbol/hash to resolve -- the closure and its per-dispatch
    # identity nonce (section 9.4) travel directly in meta$fn / meta$nonce.
    for (f in c("package", "symbol", "hash")) {
      if (!is.null(meta[[f]])) {
        stop(sprintf(paste0(".batch envelope: meta$%s is forbidden when fn_kind is ",
          "\"adhoc\" (there is no package to resolve)"), f), call. = FALSE)
      }
    }
    # Re-lint HERE, in the CHILD: design section 5's self-containedness check
    # runs at BOTH ends. A frontend (run()/run_and_collect() /
    # run_and_write_files_atomically() with a bare closure) already linted at
    # dispatch time (early UX); this is the
    # correctness copy -- a worker must never simply trust that an envelope
    # reaching it actually went through a frontend's own check. Also enforces
    # "closure, not a primitive" and "no `...`" (see .batch_lint_adhoc_fn() in
    # R/batch_adhoc.R).
    .batch_lint_adhoc_fn(meta[["fn"]], where = "child", id = meta[["id"]])
    nonce <- meta[["nonce"]]
    if (!is.character(nonce) || length(nonce) != 1L || is.na(nonce) || !nzchar(nonce)) {
      stop(".batch envelope meta$nonce is missing or not a non-empty string", call. = FALSE)
    }
  }

  outputs <- meta[["outputs"]]
  if (is.null(outputs)) {
    collect <- meta[["collect"]]
    if (!is.logical(collect) || length(collect) != 1L || is.na(collect)) {
      stop(".batch envelope meta$collect is missing or not a logical flag", call. = FALSE)
    }
    if (!is.null(meta[["style"]]) || !is.null(meta[["marker"]]) ||
        !is.null(meta[["attempt"]])) {
      stop(paste0(".batch envelope: meta$style/marker/attempt are forbidden when ",
        "meta$outputs is absent (return-value dispatch)"), call. = FALSE)
    }
    if (!is.null(meta[["details"]])) {
      stop(paste0(".batch envelope: meta$details is forbidden when meta$outputs is ",
        "absent (return-value dispatch)"), call. = FALSE)
    }
  } else {
    if (!is.null(meta[["collect"]])) {
      stop(paste0(".batch envelope: meta$collect is forbidden when meta$outputs is ",
        "present (declared-output commit dispatch)"), call. = FALSE)
    }
    .batch_validate_output_map(outputs, where = "child", id = meta[["id"]])
    # The CHILD may replay independently (it is not merely a passive
    # executor of whatever the parent already checked), so it re-validates
    # the same conservative path rules the parent enforced at dispatch time
    # (design PHASE6_DESIGN.md section 3.1) -- reusing
    # .batch_validate_output_paths() -- rather than trusting structural
    # presence alone. Crucially the child must NOT silently re-normalize a
    # path into something DIFFERENT from what the parent dispatched (that
    # would let the child commit to a path the parent never validated): so
    # every output path must already be exactly its own normalized form, or
    # this rejects rather than "fixing" it.
    normalized_outputs <- .batch_validate_output_paths(outputs, meta[["id"]])
    if (!identical(normalized_outputs, outputs)) {
      stop(sprintf(paste0(
        ".batch envelope meta$outputs [item '%s']: output path(s) are not already ",
        "absolute/normalized (the parent must dispatch already-normalized paths; the ",
        "child re-validates but never silently re-normalizes a path into something ",
        "different)"), meta[["id"]]), call. = FALSE)
    }
    style <- meta[["style"]]
    if (!is.character(style) || length(style) != 1L || is.na(style) || !nzchar(style)) {
      stop(".batch envelope meta$style is missing or not a non-empty string", call. = FALSE)
    }
    # Reject any style other than "return"/"staged_writer" HERE -- BEFORE the
    # target ever runs (this function is called before do.call() in
    # .batch_execute()). Letting a side-effecting target run for an envelope
    # whose style will fail anyway is exactly the ordering bug this closes.
    if (!(style %in% c("return", "staged_writer"))) {
      stop(sprintf(paste0(
        ".batch envelope meta$style '%s' is not supported (must be \"return\" or ",
        "\"staged_writer\") -- rejected before the target runs"), style), call. = FALSE)
    }
    marker <- meta[["marker"]]
    if (!is.character(marker) || length(marker) != 1L || is.na(marker) || !nzchar(marker)) {
      stop(".batch envelope meta$marker is missing or not a non-empty string", call. = FALSE)
    }
    if (!.batch_is_absolute_path(marker)) {
      stop(sprintf(".batch envelope meta$marker [item '%s'] is not an absolute path: %s",
        meta[["id"]], marker), call. = FALSE)
    }
    marker_parent <- dirname(marker)
    if (!dir.exists(marker_parent)) {
      stop(sprintf(paste0(
        ".batch envelope meta$marker [item '%s']: parent directory does not exist: %s"),
        meta[["id"]], marker_parent), call. = FALSE)
    }
    # Symmetric with the output-path re-validation: the parent derives the
    # marker from an already-normalized output dir, so a non-normalized marker
    # like ".../sub/../.batchit__1" is a corrupted/hostile envelope. Normalize
    # only the PARENT dir + reattach the untouched basename -- do NOT normalize
    # the whole path, which would FOLLOW a leaf marker symlink and reject the
    # envelope; a marker whose leaf is a symlink must instead reach the child's
    # step-0 read and become prior = NULL (a normal recompute), per design
    # section 9.2 -- .batch_read_prior_marker() makes that leaf decision.
    norm_marker <- file.path(
      normalizePath(dirname(marker), mustWork = FALSE), basename(marker))
    if (!identical(marker, norm_marker)) {
      stop(sprintf(
        ".batch envelope meta$marker [item '%s'] is not already absolute/normalized",
        meta[["id"]]), call. = FALSE)
    }
    attempt <- meta[["attempt"]]
    if (!is.character(attempt) || length(attempt) != 1L || is.na(attempt) || !nzchar(attempt)) {
      stop(".batch envelope meta$attempt is missing or not a non-empty string", call. = FALSE)
    }
    # details NEVER travels on the wire, even after Unit 4 (design
    # PHASE6_DESIGN.md section 7): the parent never sets it -- the real
    # `details` value is produced CHILD-side, by the target calling
    # batch_record() during do.call() (see .batch_execute()), and flows
    # straight into .batch_commit_task()'s marker write, never through this
    # envelope. So a non-NULL value here can only be a corrupted/hostile
    # envelope.
    if (!is.null(meta[["details"]])) {
      stop(paste0(".batch envelope: meta$details must be NULL (details is produced ",
        "CHILD-side via batch_record(), never carried in the dispatch envelope)"),
        call. = FALSE)
    }
  }

  if (!is.list(env[["args"]])) {
    stop(".batch envelope args is not a list", call. = FALSE)
  }
  invisible(TRUE)
}

# --- child-side execution ----------------------------------------------------

#' Resolve and verify a target in the child process
#'
#' The child may have loaded a different code version than the parent hashed
#' (installed vs dev, or a stale dev tree). If the target's body/formals hash
#' differs, refuse: running a different version than the parent dispatched is the
#' stale-code hole the descriptor exists to close.
#'
#' Note the deliberate NARROWNESS (a settled decision, matching the body+formals
#' identity used for cache/replay in the originating pipeline): the hash covers
#' the target's own body and formals only. A changed HELPER the target calls, a
#' namespace constant it closes over, an S4/R6 method table, or a dependency's
#' version are outside it. So this guarantees "same target definition", not
#' "provably identical behaviour" -- the latter is not claimed.
#' @noRd
.batch_resolve_target <- function(meta) {
  # Exact `[[` on the untrusted meta (never `$`, which partial-matches).
  target <- package_function(meta[["package"]], meta[["symbol"]],
    version = meta[["version"]])
  if (!identical(target$hash, meta[["hash"]])) {
    stop(
      sprintf(
        paste0(".batch_worker: %s::%s resolved to a DIFFERENT code version ",
          "than the parent dispatched (parent hash %s, child hash %s). ",
          "Refusing to run -- check the dev path / installed package version."),
        meta[["package"]], meta[["symbol"]], meta[["hash"]], target$hash),
      call. = FALSE
    )
  }
  target
}

#' Execute one envelope in the child and build the result envelope
#'
#' Total by design: it always returns a result envelope, never throws. Every
#' failure the child can hit -- target resolution, the hash mismatch, child-side
#' item re-validation, and the target's own R-level errors -- is caught into ONE
#' structured error envelope (status "error", value NULL, `error$message`). That
#' uniformity is the point: every frontend (`run()`/`run_and_collect()`/
#' `run_and_write_files_atomically()` reading a file, `batch_stream` reading a
#' daemon return) surfaces every failure the same way,
#' instead of a resolve error crashing the worker while a target error returns an
#' envelope. `meta$collect == FALSE` drops the value entirely: shape-A
#' direct-writers put gigabytes on disk themselves, and the whole architecture
#' exists so those never cross back to the parent -- only the status does.
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
        .batch_validate_item(target, env[["args"]], where = "child", id = meta[["id"]])
        fn <- get(meta[["symbol"]], envir = asNamespace(meta[["package"]]),
          inherits = FALSE)
        result_target <- list(package = target$package, symbol = target$symbol,
          hash = target$hash)
      } else {
        # fn_kind == "adhoc" (Phase 6' Unit 3): .batch_check_envelope() above
        # already re-linted meta$fn for self-containedness (design section 5)
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
        if (is.null(fmls)) fmls <- character(0)
        .batch_validate_adhoc_item(fmls, env[["args"]], where = "child", id = meta[["id"]])
        result_target <- list(fn_kind = "adhoc", nonce = meta[["nonce"]])
      }

      # style/outputs are already both-fully-validated by .batch_check_envelope()
      # above -- BEFORE do.call() ever runs the target: style is one of
      # "return"/"staged_writer" whenever outputs is present, NULL otherwise.
      outputs <- meta[["outputs"]]
      style <- meta[["style"]]
      task_dispatch <- !is.null(outputs)

      # Step 0 (design PHASE6_DESIGN.md section 9.2, normative) -- done FIRST,
      # before ANY scope is entered, so where_to_write_output()/batch_record()/
      # batch_prior() are answerable ONLY during do.call() and NEVER during this
      # marker read. ONLY for a declared-output commit dispatch: read the final
      # marker EXACTLY ONCE and accept it as `prior` only if it decodes and its
      # protocol/attempt-token/committed-output-map verify against THIS item's
      # own declared outputs (a malformed, foreign, absent, or symlinked marker
      # all become `prior = NULL`). Sanctioned by design section 0 ("...or to
      # hand a consumer its own prior details") -- NEVER a launch decision (the
      # item was already unconditionally dispatched); the marker is left
      # completely untouched. A return-value dispatch has no marker/skip
      # machinery, so `prior` stays NULL and the record scope is never entered.
      prior <- if (task_dispatch) .batch_read_prior_marker(meta[["marker"]], outputs) else NULL

      stage_map <- NULL
      staged <- task_dispatch && identical(style, "staged_writer")
      stage_prior <- NULL
      if (staged) {
        # Pre-compute EVERY declared output's staging path BEFORE do.call()
        # (design PHASE6_DESIGN.md section 3.4), and register them for cleanup
        # in THIS frame: a target that errors PARTWAY through streaming never
        # reaches .batch_commit_task(), so only an on.exit registered before
        # do.call() still fires. Safe through a successful commit too -- by then
        # every path has been renamed away, so unlink() on an absent path is a
        # no-op; it ALSO covers a batch_skip()ped target that wrote a stage
        # first (design section 9.3: skip is a successful early exit and must
        # remove its own current-attempt stage/temp files -- the stage is
        # never renamed on that path, so this same unconditional unlink
        # removes it). Then enter scope so where_to_write_output() can answer.
        stage_map <- .batch_stage_paths_for(outputs, meta[["attempt"]])
        on.exit(unlink(stage_map, force = TRUE), add = TRUE)
        stage_prior <- .batch_stage_scope_enter(stage_map)
      }

      # Enter the record scope (batch_record()/batch_prior()) AFTER step 0 has
      # captured `prior` above -- answerable only during do.call(), exited in
      # the finally() below (like the stage scope).
      record_prior_state <- if (task_dispatch) .batch_record_scope_enter(prior) else NULL

      # Capture the target's warnings into the envelope instead of letting them
      # scroll off into a log the parent deletes on success. This matters for a
      # target that catches a downstream failure, WARNs, and still returns a
      # partial (status "ok") result -- without this the incomplete result would
      # be stored with no word to the parent.
      warns <- character()
      recorded_details <- NULL
      value <- tryCatch(
        withCallingHandlers(
          do.call(fn, env[["args"]]),
          warning = function(w) {
            warns[[length(warns) + 1L]] <<- .batch_condition_message(w)
            invokeRestart("muffleWarning")
          }
        ),
        # Exit EVERY scope the INSTANT the target returns or errors -- NOT
        # during the commit/skip handling below. where_to_write_output()/
        # batch_record()/batch_prior() must be answerable ONLY while the
        # target itself runs (design sections 3.4, 9.3); leaving them active
        # through the commit would let e.g. a classed `outputs` map's `[[`
        # method reach them after the target is done. `recorded_details` --
        # whatever the target last passed to batch_record(), design section
        # 9.3's "last call wins" -- is captured HERE, before the record scope
        # is torn down; this runs on success, on the target's own error, AND
        # when the target returned batch_skip() (all three are a "normal
        # return" from do.call()'s point of view here).
        finally = {
          if (task_dispatch) recorded_details <- .batch_record_env$details
          if (staged) .batch_stage_scope_exit(stage_prior)
          if (task_dispatch) .batch_record_scope_exit(record_prior_state)
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
      } else if (.batch_is_skip(value)) {
        # design sections 7, 9.2 point 4, 9.3: the target decided the PRIOR
        # committed outputs are current. Verify + reuse -- no new marker, no
        # rename, nothing removed; any mismatch/missing output fails loud
        # with the marker left untouched (.batch_commit_task_skip()).
        commit <- .batch_commit_task_skip(prior, outputs, meta[["marker"]],
          meta[["attempt"]])
        list(
          status = "ok",
          value = commit,
          error = NULL,
          warnings = utils::head(warns, 100L),
          target = result_target
        )
      } else {
        # Declared-output commit dispatch (run_and_write_files_atomically(),
        # design PHASE6_DESIGN.md section 3.3). The raw target `value` is discarded
        # after commit (unconditionally for staged_writer, or once matched
        # against `outputs` for return) -- it never crosses back, only the
        # small commit record does. `recorded_details` is whatever the
        # target last passed to batch_record() (design section 7), or NULL
        # if it never called it.
        commit <- .batch_commit_task(value, outputs, meta[["marker"]],
          meta[["attempt"]], recorded_details, style = style, stage_map = stage_map)
        list(
          status = "ok",
          value = commit,
          error = NULL,
          warnings = utils::head(warns, 100L),
          target = result_target
        )
      }
    },
    error = function(e) list(
      status = "error",
      value = NULL,
      error = list(
        message = .batch_condition_message(e),
        call = tryCatch(paste(deparse(conditionCall(e)), collapse = " "),
          error = function(e2) "<unprintable call>")
      ),
      warnings = character(),
      target = NULL
    )
  )

  list(
    protocol = .BATCH_PROTOCOL,
    id = id,
    status = outcome$status,
    value = outcome$value,
    error = outcome$error,
    warnings = outcome$warnings,
    target = outcome$target
  )
}

#' Inspect a result envelope in the parent: accept it, or say why not
#'
#' Makes the result-envelope fields load-bearing rather than decorative, and is
#' TOTAL -- a non-list or otherwise malformed result becomes a `reason`, never a
#' throw, so it flows through the caller's uniform failure path (logging, then a
#' loud stop) like any other failure. Shared by both frontends so they
#' accept/reject identically. Returns `list(ok, reason, value, warnings)`.
#'
#' Checks, in order: the result is a list; protocol; status; the id matches the
#' dispatched id; and (on success) identity of the code that actually ran --
#' for `fn_kind = "package"`, the FULL executed-target identity (package,
#' symbol AND hash; the contract defines identity as all three, since a
#' body/formals hash can collide across two functions) matches what was
#' dispatched; for `fn_kind = "adhoc"` there is no package identity, so
#' `expected_nonce` (see below) is checked instead -- plus that a successful
#' envelope actually carries a `value` field.
#'
#' `expected_outputs`/`expected_attempt` (both `NULL` by default) are set only
#' when inspecting a `run_and_write_files_atomically()` (declared-output
#' commit) result: the value
#' field is then a commit record, not raw data, and is checked against the
#' `outputs` actually DISPATCHED for this item (design PHASE6_DESIGN.md
#' section 3.5) -- names AND paths must match exactly, or a stale/substituted
#' result is rejected the same way a wrong id or wrong target identity is. The
#' record's `attempt` token is checked against `expected_attempt` too, UNLESS
#' the record's own `skipped` field is `TRUE` (design sections 7, 9.2, 9.3):
#' a skip's token is the item's PRIOR marker's own (nothing new was
#' committed), so it is never expected to equal the token freshly issued for
#' THIS dispatch. Existing (return-value) callers pass neither and are
#' unaffected.
#'
#' `expected_nonce` (`NULL` by default) is set only when inspecting an `adhoc`
#' (Phase 6' Unit 3) result: an adhoc envelope carries no package/symbol/hash
#' descriptor for the child to echo back, so identity is instead bound to the
#' id (already checked above) PLUS a fresh, high-entropy per-dispatch nonce
#' the parent issued and the child echoes in its result `target` field as
#' `list(fn_kind = "adhoc", nonce = <nonce>)` (design PHASE6_DESIGN.md section
#' 9.4) -- `target` itself is unused (may be `NULL`) on this path.
#' @noRd
.batch_inspect_result <- function(envelope, expected_id, target,
                                    expected_outputs = NULL, expected_attempt = NULL,
                                    expected_nonce = NULL) {
  # Total BY CONSTRUCTION: any error while inspecting a hostile or corrupt result
  # -- a classed object with a throwing `[[`/`format` method, a field that errors
  # on access -- becomes a failure reason, so it flows through the caller's
  # uniform .fail() path rather than crashing the pool.
  tryCatch(
    .batch_inspect_result_impl(envelope, expected_id, target,
      expected_outputs, expected_attempt, expected_nonce),
    error = function(e) list(ok = FALSE,
      reason = paste0("malformed result envelope: ", .batch_condition_message(e)))
  )
}

#' @noRd
.batch_inspect_result_impl <- function(envelope, expected_id, target,
                                         expected_outputs = NULL, expected_attempt = NULL,
                                         expected_nonce = NULL) {
  if (!is.list(envelope)) {
    return(list(ok = FALSE, reason = sprintf(
      "result is not a list (got %s)", class(envelope)[1L])))
  }
  # Reject missing / blank / DUPLICATE field names: `$` returns the first match,
  # so a result carrying both `protocol = 1L` and `protocol = 99L` (or duplicate
  # id/target fields) could otherwise smuggle a bad value behind a good one.
  nm <- names(envelope)
  if (is.null(nm) || any(!nzchar(nm)) || anyDuplicated(nm)) {
    return(list(ok = FALSE,
      reason = "result envelope has missing, blank, or duplicate field names"))
  }
  # Every field is read with EXACT `[[`, never `$`: `$` partial-matches, so an
  # absent `status`/`id`/`target` beside a longer-named field (`status_x`) would
  # otherwise resolve to the wrong value. (`target` is the dispatched descriptor,
  # our own trusted list, so `target$...` stays `$`.)
  if (!identical(envelope[["protocol"]], .BATCH_PROTOCOL)) {
    return(list(ok = FALSE, reason = sprintf(
      "result envelope has wrong/missing protocol: %s",
      format(envelope[["protocol"]] %||% "<none>"))))
  }
  # id is checked BEFORE status and STRICTLY (a single character, identical -- no
  # numeric-to-string coercion): a result must be the one dispatched for THIS
  # item even when it carries an error. The worker echoes the dispatched id on
  # every path, including its load-failure fallback, so an error result still
  # gets id-validated here and its message surfaced at the status check below.
  eid <- envelope[["id"]]
  if (!is.character(eid) || length(eid) != 1L ||
      !identical(eid, as.character(expected_id))) {
    return(list(ok = FALSE, reason = sprintf(
      "result envelope id mismatch: expected '%s', got %s",
      expected_id, format(eid %||% "<none>"))))
  }
  if (!identical(envelope[["status"]], "ok")) {
    # `error` may be malformed (e.g. a bare string) -- do not let extracting the
    # message throw; the inspector stays total.
    msg <- tryCatch(envelope[["error"]][["message"]], error = function(e) NULL)
    if (!is.character(msg) || length(msg) != 1L) msg <- "failed with no error message"
    return(list(ok = FALSE, reason = sprintf("returned an error: %s", msg)))
  }
  tgt <- envelope[["target"]]
  # `anyDuplicated(names(tgt))`: a nested `target = list(package="a",
  # package="evil", ...)` must not let the first `package` win and leave the
  # executed identity ambiguous.
  if (!is.list(tgt) || anyDuplicated(names(tgt))) {
    return(list(ok = FALSE,
      reason = "result envelope has a malformed target field"))
  }
  if (!is.null(expected_nonce)) {
    # adhoc (Phase 6' Unit 3, design section 9.4): no package identity to
    # check -- bind on fn_kind == "adhoc" plus the per-dispatch nonce the
    # parent issued and the child echoed back (id was already checked above).
    if (!is.character(expected_nonce) || length(expected_nonce) != 1L ||
        is.na(expected_nonce) || !identical(tgt[["fn_kind"]], "adhoc") ||
        !identical(tgt[["nonce"]], expected_nonce)) {
      return(list(ok = FALSE,
        reason = "result came from a different adhoc dispatch than expected (nonce mismatch)"))
    }
  } else {
    if (!identical(tgt[["package"]], target$package) ||
        !identical(tgt[["symbol"]], target$symbol) ||
        !identical(tgt[["hash"]], target$hash)) {
      return(list(ok = FALSE, reason = sprintf(
        "result came from a different target than dispatched (expected %s::%s, hash %s)",
        target$package, target$symbol, target$hash)))
    }
  }
  if (!("value" %in% names(envelope))) {
    return(list(ok = FALSE, reason = "successful result envelope has no value field"))
  }
  warnings <- envelope[["warnings"]]
  # Never coerce an arbitrary object (as.character() on a closure throws); a
  # non-character warnings field is simply dropped, keeping the inspector total.
  if (!is.character(warnings)) warnings <- character()

  # Declared-output commit result (run_and_write_files_atomically()): the
  # value is a small commit record, never raw data. Validate it matches
  # EXACTLY what was dispatched --
  # names AND paths of the committed map, AND the attempt token THIS dispatch
  # issued (checked for a fresh commit AND a skip; see below) -- so a stale or
  # substituted result can never be accepted as this item's commit.
  if (!is.null(expected_outputs)) {
    val <- envelope[["value"]]
    val_nm <- names(val)
    # The commit record's names must be EXACTLY {"committed", "attempt",
    # "skipped"} -- no missing, no blank, and critically no EXTRA field.
    # Allowing extras would let a worker smuggle arbitrary raw data back to
    # the parent (e.g. `list(committed = ..., attempt = ..., raw = <huge>)`),
    # defeating the whole point of run_and_write_files_atomically() (only a
    # small commit record ever crosses back; see design PHASE6_DESIGN.md
    # section 3.5).
    if (!is.list(val) || is.null(val_nm) || any(!nzchar(val_nm)) ||
        anyDuplicated(val_nm) ||
        !identical(sort(val_nm), sort(c("committed", "attempt", "skipped")))) {
      return(list(ok = FALSE,
        reason = paste0(
          "commit result value must have EXACTLY the fields committed, attempt, ",
          "skipped (no more, no fewer) -- got: ",
          paste(val_nm %||% "<none>", collapse = ", "))))
    }
    committed <- val[["committed"]]
    if (!is.character(committed) || is.null(names(committed)) ||
        anyDuplicated(names(committed)) ||
        !identical(sort(names(committed)), sort(names(expected_outputs))) ||
        !identical(committed[order(names(committed))],
          expected_outputs[order(names(expected_outputs))])) {
      return(list(ok = FALSE,
        reason = "committed output map does not match the outputs dispatched for this item"))
    }
    skipped <- val[["skipped"]]
    if (!is.logical(skipped) || length(skipped) != 1L || is.na(skipped)) {
      return(list(ok = FALSE,
        reason = "commit result skipped flag is missing or not a single TRUE/FALSE"))
    }
    attempt <- val[["attempt"]]
    if (!is.character(attempt) || length(attempt) != 1L || is.na(attempt) || !nzchar(attempt)) {
      return(list(ok = FALSE,
        reason = "commit attempt token is missing or not a non-empty string"))
    }
    # The attempt token is ALWAYS the token THIS dispatch issued -- for a fresh
    # commit AND for a skip. (A skip verifies the PRIOR marker's own token
    # internally, in .batch_commit_task_skip(); the token it returns to the
    # parent is the CURRENT dispatch's, so `skipped = TRUE` can never be a
    # self-asserted bypass of the dispatch-identity check -- a stale, misrouted,
    # or substituted result envelope is rejected here regardless of the skip
    # flag, exactly as it is for a fresh commit.)
    if (!identical(attempt, expected_attempt)) {
      return(list(ok = FALSE,
        reason = "commit attempt token does not match what was dispatched"))
    }
  }

  list(ok = TRUE, reason = NULL, value = envelope[["value"]], warnings = warnings)
}

#' Re-emit a completed item's captured warnings in the parent, tagged by id
#' @noRd
.batch_surface_warnings <- function(warnings, id) {
  for (w in warnings) {
    warning(sprintf("[batch item '%s'] %s", id, w), call. = FALSE)
  }
  invisible(NULL)
}

# --- bounded log tail --------------------------------------------------------

#' Bounded tail of a worker's log file
#'
#' Reads at most the last `max_bytes` of `path` and returns its last `n` lines.
#'
#' Bounded on the way IN, which is the whole point: a naive version that
#' `readLines()`d the entire file and only then took the tail would OOM the
#' **parent** when a worker died after emitting a multi-GB log -- turning one
#' worker's failure into the whole run's. Never more than `max_bytes` enters
#' memory. This runs at exactly the worst moment (while reporting a worker's
#' failure), so it must not itself be able to blow up.
#'
#' Worker output is not guaranteed to be text. A C library can emit a NUL, and
#' seeking into the middle of a file can slice a multi-byte character in half.
#' `rawToChar()` errors on an embedded NUL and `strsplit()` errors on an invalid
#' multibyte string, so an unscrubbed version would report "(no output
#' captured)" for a worker that had in fact said exactly what was wrong. Bytes
#' are therefore scrubbed, not trusted.
#'
#' @param path Log file path.
#' @param n Maximum lines to return.
#' @param max_bytes Maximum bytes to read from the end of the file.
#' @return A single string, `""` if there is nothing readable to report.
#' @noRd
.batch_log_tail <- function(path, n = 100L, max_bytes = 64000) {
  if (!file.exists(path)) return("")
  size <- file.size(path)
  if (is.na(size) || size == 0L) return("")

  from <- max(0, size - max_bytes)
  txt <- tryCatch(
    {
      con <- file(path, "rb")
      on.exit(close(con), add = TRUE)
      if (from > 0) seek(con, where = from, origin = "start")
      bytes <- readBin(con, "raw", n = min(size, max_bytes))
      bytes <- bytes[bytes != as.raw(0L)]
      raw_txt <- rawToChar(bytes)
      Encoding(raw_txt) <- "UTF-8"
      iconv(raw_txt, from = "UTF-8", to = "UTF-8", sub = "?")
    },
    error = function(e) ""
  )
  if (length(txt) != 1L || is.na(txt) || !nzchar(txt)) return("")

  lines <- strsplit(txt, "\n", fixed = TRUE)[[1]]
  # A mid-line seek makes the first fragment partial; drop it rather than report
  # a truncated line as though it were real output.
  if (from > 0 && length(lines) > 1L) lines <- lines[-1L]
  clipped <- from > 0 || length(lines) > n
  if (length(lines) > n) lines <- utils::tail(lines, n)

  paste(
    c(
      if (clipped) sprintf("... (tail of %s; %s bytes total)", path, format(size)),
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
#' fall-through to installed code: the tree must exist, be an R package SOURCE
#' tree (not an installed package), and name the consumer package. Returns the
#' normalised path, or `NULL` for the installed-package case. Shared by
#' [run()]/[run_and_collect()]/[run_and_write_files_atomically()] (processx)
#' and [batch_stream()] (mirai) so all of them enforce the
#' same policy. `consumer_package` is the target's `package` -- the dev tree must
#' be the CONSUMER's source, not the runner's.
#' @noRd
.batch_validate_dev_path <- function(dev_path, consumer_package) {
  if (is.null(dev_path)) return(NULL)
  dev_path <- normalizePath(dev_path, mustWork = FALSE)
  if (!dir.exists(dev_path)) {
    stop(
      ".batch: dev_path was given but does not exist: ", dev_path,
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
      ".batch: dev_path is an installed package, not a source tree: ", dev_path,
      "\n  (it has Meta/package.rds; an installed layout has no inst/ subdir, so ",
      "the load_all() source is absent.)",
      "\n  Pass dev_path = NULL to use the installed package deliberately.",
      call. = FALSE
    )
  }
  dcf_path <- file.path(dev_path, "DESCRIPTION")
  if (!file.exists(dcf_path)) {
    stop(".batch: dev_path is not an R package source tree ",
      "(no DESCRIPTION): ", dev_path, call. = FALSE)
  }
  dev_pkg <- tryCatch(
    unname(read.dcf(dcf_path, fields = "Package")[1L, 1L]),
    error = function(e) NA_character_
  )
  if (is.na(dev_pkg) || !identical(dev_pkg, consumer_package)) {
    stop(sprintf(
      ".batch: dev_path points at package '%s', not '%s': %s",
      dev_pkg, consumer_package, dev_path), call. = FALSE)
  }
  dev_path
}

#' Locate the runner's inst/batch_worker.R (always from the RUNNER package)
#'
#' The extraction seam: the worker script is ALWAYS the runner's (batchit's),
#' resolved via `system.file("batch_worker.R", package = <runner>)`, never the
#' consumer's `dev_path`. `system.file()` resolves into batchit's own source
#' `inst/` under `pkgload`/`devtools::load_all()` dev of batchit, and into the
#' installed package otherwise -- so batchit's own dev workflow keeps working
#' while the consumer's tree only ever supplies the consumer's code (via
#' `dev_path`), not the worker script.
#' @noRd
.batch_worker_script <- function() {
  runner <- .batch_runner_package()
  script <- system.file("batch_worker.R", package = runner)
  if (!nzchar(script) || !file.exists(script)) {
    stop(".batch_worker_script(): inst/batch_worker.R not found in the runner package '",
      runner, "'", call. = FALSE)
  }
  script
}

#' Build a dispatch input envelope
#'
#' The ONE place EVERY frontend assembles the wire envelope -- `run()`,
#' `run_and_collect()`, `batch_stream()`, and `run_and_write_files_atomically()`
#' -- so none of them can drift in the
#' schema the child reads back (`.batch_check_envelope()` / `.batch_execute()`).
#' `runner` (the runner package name) travels so the worker/daemon knows which
#' package holds `.batch_execute` -- the field that carries the
#' runner-vs-consumer split. `id` is coerced to a string here so a numeric item
#' index and an explicit character id land identically.
#'
#' `fn_kind`/`collect` are the return-value-dispatch fields (unchanged
#' defaults: `run()`/`run_and_collect()`/`batch_stream()` pass only `collect`).
#' `outputs`/`marker`/`style`/`attempt`/`details` are the declared-output
#' commit fields `run_and_write_files_atomically()` supplies instead (design
#' PHASE6_DESIGN.md sections 3/4); `collect` and those five are mutually
#' exclusive, enforced by `.batch_check_envelope()`.
#'
#' `fn`/`nonce` are the `fn_kind = "adhoc"` fields (Phase 6' Unit 3, design
#' sections 1, 4, 9.4): `fn` carries the already-linted, already-baseenv()-
#' rebased closure itself, and `nonce` is its per-dispatch identity token,
#' used in place of the package/symbol/hash identity a `package_function` would
#' otherwise supply -- `run()`/`run_and_collect()` and
#' `run_and_write_files_atomically()` (with a bare closure)
#' pass `target = NULL` and these two instead. Forbidden (must stay `NULL`)
#' for `fn_kind = "package"`, enforced by `.batch_check_envelope()`.
#' @noRd
.batch_input_envelope <- function(target, dev_path, runner, id, args,
                                    fn_kind = "package", collect = NULL,
                                    outputs = NULL, marker = NULL, style = NULL,
                                    attempt = NULL, details = NULL,
                                    fn = NULL, nonce = NULL) {
  list(
    protocol = .BATCH_PROTOCOL,
    meta = list(
      fn_kind = fn_kind,
      package = target$package,
      symbol = target$symbol,
      version = target$version,
      hash = target$hash,
      fn = fn,
      nonce = nonce,
      dev_path = dev_path,
      runner_package = runner,
      id = as.character(id),
      collect = collect,
      outputs = outputs,
      marker = marker,
      style = style,
      attempt = attempt,
      details = details
    ),
    args = args
  )
}

#' Derive stable per-item ids for `run()`/`run_and_collect()` (item names, else index)
#'
#' A named item keeps its name; an unnamed one gets its 1-based index. The
#' result must be unique so a reported failure identifies exactly one item -- a
#' duplicate name (or a name that collides with another item's index) is a
#' caller error, not something to paper over.
#' @noRd
.batch_item_ids <- function(items) {
  n <- length(items)
  ids <- names(items)
  if (is.null(ids)) ids <- rep_len("", n)
  ids[is.na(ids)] <- ""
  blank <- !nzchar(ids)
  ids[blank] <- as.character(seq_len(n))[blank]
  if (anyDuplicated(ids)) {
    stop(sprintf(paste0(".batch_item_ids(): item ids are not unique: %s. Name items ",
      "uniquely, or leave them all unnamed to use positional indices."),
      paste(unique(ids[duplicated(ids)]), collapse = ", ")), call. = FALSE)
  }
  ids
}

#' Validate an explicit id vector for `batch_stream` (non-empty, non-NA, unique)
#' @noRd
.batch_check_ids <- function(ids) {
  ids <- as.character(ids)
  if (any(is.na(ids)) || any(!nzchar(ids))) {
    stop("batch_stream(): every id must be a non-empty, non-NA string", call. = FALSE)
  }
  if (anyDuplicated(ids)) {
    stop("batch_stream(): ids must be unique: ",
      paste(unique(ids[duplicated(ids)]), collapse = ", "), call. = FALSE)
  }
  ids
}

#' Validate the `timeout` config -- a single positive number of seconds, or Inf
#'
#' Rejected loudly rather than silently disabled: a vector, `NA`, a non-numeric,
#' zero or a negative would otherwise either turn the timeout OFF without a word
#' (`c(1, 2)`, `NA`) or make every item time out instantly (a negative). Validate
#' before any early return so an empty workload cannot hide a bad value.
#' @noRd
.batch_validate_timeout <- function(timeout, what) {
  if (length(timeout) != 1L || !is.numeric(timeout) || is.na(timeout) ||
      timeout <= 0) {
    stop(sprintf(paste0("%s: timeout must be a single positive number of seconds ",
      "(or Inf to disable); got: %s"), what,
      paste(utils::capture.output(utils::str(timeout)), collapse = " ")),
      call. = FALSE)
  }
  as.numeric(timeout)
}

#' Validate the `collect` flag -- a single TRUE/FALSE
#' @noRd
.batch_validate_collect <- function(collect, what) {
  if (!is.logical(collect) || length(collect) != 1L || is.na(collect)) {
    stop(sprintf("%s: collect must be a single TRUE or FALSE", what), call. = FALSE)
  }
  collect
}

# --- shape A: fresh subprocess per item, via processx ------------------------

#' Shared shape-A transport: run `fn` on each of a fixed list of items
#'
#' The ONE internal implementation behind [run()], [run_and_collect()], and
#' (via a bare closure) the former ad-hoc-closure frontend -- folded in here rather than
#' kept as a separate frontend, since the package-vs-closure choice is a
#' property of the `fn` argument's TYPE, not a separate function name. `fn` is
#' EITHER a `package_function` descriptor from [package_function()]
#' (`fn_kind = "package"`) OR a bare closure (`fn_kind = "adhoc"`):
#' self-contained (base R, `pkg::`-qualified calls, and its own formals only
#' -- see `.batch_lint_adhoc_fn()`), not a primitive, and not taking `...`. A
#' closure is gated by that self-containedness LINT and unconditionally
#' rebased onto `baseenv()` before it is ever serialized (see
#' `.batch_rebase_adhoc_closure()`); production/auditable stages should prefer
#' a `package_function()` descriptor (hash-verified, resolvable by
#' package+symbol) -- `adhoc` dispatch is for throwaway/exploratory work where
#' that overhead is not the point.
#'
#' Shape A of the contract: the items already exist (each a small named list
#' of `fn`'s formals; the worker opens its own data), so a fresh R process per
#' item is not a cost to amortise but the memory strategy itself -- a large
#' analysis item can peak at tens of GB and R does not return that memory to the
#' OS, so process exit is how it is reclaimed. This is why batchit does NOT reuse
#' workers: worker reuse would defeat exactly this.
#'
#' Both-end validation, a hash-verified target descriptor (or, for `adhoc`, a
#' per-dispatch identity nonce), per-item logs written to files (never pipes
#' -- a chatty worker filling the OS pipe buffer is what deadlocks a pipe
#' transport), a bounded log tail on failure, and a loud stop on the first
#' failure. Warnings a target captures are surfaced in the parent, tagged by
#' item id.
#'
#' batchit is thread-agnostic: it sets no BLAS / data.table thread counts and
#' passes none to the worker. If `fn` is itself multi-threaded, dividing
#' cores across `n_workers` (to avoid oversubscription) is the CONSUMER's
#' responsibility, not the runner's.
#'
#' The worker script is always the runner's (batchit's); `dev_path`, when given,
#' is the CONSUMER's source tree for `fn_kind = "package"` (or batchit's own
#' source tree for `fn_kind = "adhoc"` -- an adhoc closure has no separate
#' consumer identity to load). When runner and consumer differ, the worker
#' loads both (the consumer via `dev_path`/`requireNamespace`, the runner via
#' `requireNamespace`).
#'
#' @param fn EITHER a `package_function` descriptor from [package_function()]
#'   OR a bare closure -- see the details above.
#' @param items List of items; each a fully-named list of `fn`'s formals.
#'   Named items keep their name as the item id; unnamed items get their index.
#' @param n_workers Concurrent subprocesses (validated: finite, whole, >= 1).
#' @param dev_path Source tree for `devtools::load_all()` in the worker, or
#'   `NULL` for the installed package. A given-but-wrong path errors rather
#'   than silently falling back to installed code.
#' @param collect If `TRUE`, return each item's value in item order; if `FALSE`,
#'   the worker still reports status but its value never crosses back (for
#'   targets that write their output themselves).
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
    if (is.null(formal_names)) formal_names <- character(0)
    target <- NULL
  } else {
    stop(sprintf("%s(): `fn` must come from package_function() or be a function",
      .caller), call. = FALSE)
  }

  n_workers <- .batch_validate_n_workers(n_workers, sprintf("%s()", .caller))
  # Validate ALL config BEFORE the empty-workload early return -- otherwise a bad
  # dev_path/timeout/collect is silently accepted whenever there is no work.
  collect <- .batch_validate_collect(collect, sprintf("%s()", .caller))
  timeout <- .batch_validate_timeout(timeout, sprintf("%s()", .caller))
  # For "package", dev_path names the CONSUMER's tree (target$package). For
  # "adhoc" there is no consumer identity -- dev_path instead names BATCHIT'S
  # OWN tree (an adhoc closure has no separate consumer identity to load).
  dev_path <- .batch_validate_dev_path(dev_path,
    if (identical(fn_kind, "package")) target$package else "batchit")
  # `items` must be a LIST of items, checked before the empty-workload return so
  # an empty atomic (character(0)/numeric(0)) cannot slip past the container
  # contract while a non-empty atomic would be rejected.
  if (!is.list(items)) {
    stop(sprintf("%s(): `items` must be a list, got %s", .caller, class(items)[1L]),
      call. = FALSE)
  }

  n_items <- length(items)
  if (n_items == 0L) return(if (collect) list() else invisible(NULL))

  # Stable per-item ids (item names, else the index), validated unique so a
  # reported failure identifies exactly the right item.
  ids <- .batch_item_ids(items)

  # Validate EVERY item up front (not items[[1]]): item schemas are legitimately
  # heterogeneous, so a bad one hides behind a good first one.
  for (i in seq_len(n_items)) {
    if (identical(fn_kind, "package")) {
      .batch_validate_item(target, items[[i]], where = "parent", id = ids[i])
    } else {
      .batch_validate_adhoc_item(formal_names, items[[i]], where = "parent", id = ids[i])
    }
  }

  # fn_kind == "adhoc": a fresh, high-entropy per-item identity nonce -- an
  # adhoc envelope has no package/symbol/hash for the parent to check the
  # result against, so this token (echoed back by the child) takes that role.
  # Unused (stays NULL) for "package".
  nonces <- if (identical(fn_kind, "adhoc")) {
    vapply(seq_len(n_items), function(i) .batch_new_attempt_token(), character(1))
  } else {
    NULL
  }

  script_path <- .batch_worker_script()
  rscript_bin <- file.path(R.home("bin"), "Rscript")

  input_paths <- vapply(seq_len(n_items), function(i) {
    tempfile(pattern = paste0("batch_in_", i, "_"), fileext = ".qs2")
  }, character(1))
  output_paths <- vapply(seq_len(n_items), function(i) {
    tempfile(pattern = paste0("batch_out_", i, "_"), fileext = ".qs2")
  }, character(1))
  # Per-item stdout/stderr goes to a file, not a pipe -- the pipe's fixed OS
  # buffer is what deadlocks a chatty worker. "Bounded" here is about RAM: only
  # the last 64 KB is ever read back (.batch_log_tail), so a huge log never OOMs
  # the PARENT. The on-disk file is transient (unlinked per item) and its size is
  # bounded in practice by `timeout` (write-rate x wall-clock); a truly
  # pathological infinite-printer is caught by that, not by an fs-level cap.
  log_paths <- vapply(seq_len(n_items), function(i) {
    tempfile(pattern = paste0("batch_log_", i, "_"), fileext = ".log")
  }, character(1))

  on.exit({
    unlink(input_paths, force = TRUE)
    unlink(output_paths, force = TRUE)
    unlink(log_paths, force = TRUE)
  }, add = TRUE)

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
        target, dev_path, runner_pkg, ids[i], items[[i]], collect = collect)
    } else {
      .batch_input_envelope(
        target = NULL, dev_path = dev_path, runner = runner_pkg, id = ids[i],
        args = items[[i]], fn_kind = "adhoc", collect = collect,
        fn = fn, nonce = nonces[i])
    }
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
        ids[idx], tail_txt))
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
    insp <- if (identical(fn_kind, "package")) {
      .batch_inspect_result(envelope, ids[idx], target)
    } else {
      .batch_inspect_result(envelope, ids[idx], target = NULL,
        expected_nonce = nonces[idx])
    }
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
        # results[idx] <- list(value), NOT results[[idx]] <- value: assigning a
        # NULL value with [[<- DELETES the element, shortening the list and
        # shifting every result gathered after it. Completion is in worker-finish
        # order, so a NULL item finishing after a higher slot is filled corrupts
        # positions. Single-bracket-with-list() assigns the NULL in place.
        if (collect) results[entry$idx] <- list(value)
        unlink(log_paths[entry$idx], force = TRUE)
        n_done <- n_done + 1L
        if (!is.null(p)) {
          # The tick names the completed ITEM, not just a timestamp: on a
          # multi-day stage the operator needs "which unit just finished", and
          # the stable id is sitting right here.
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

#' Run `fn` on each of a fixed list of items, one subprocess per item, returning nothing
#'
#' The `collect = FALSE` sibling of [run_and_collect()] -- same shape-A
#' transport (see [run_and_collect()] and `.batch_run_impl()` for the shared
#' contract details: hash-verified target/adhoc dispatch, both-end
#' validation, per-item logs, bounded log tail, loud failure). Use this when
#' `fn` writes its own output (or is called purely for a side effect) and no
#' value needs to cross back to the parent.
#'
#' `fn` is EITHER a `package_function()` descriptor (hash-verified,
#' auditable; use in production) OR a bare closure (ad-hoc, gated by a static
#' self-containedness lint and a mandatory `baseenv()` rebase; for tests and
#' one-offs only -- this folds in the former ad-hoc-closure frontend).
#'
#' @param fn EITHER a `package_function` descriptor from [package_function()]
#'   OR a bare closure -- see the details above.
#' @param items List of items; each a fully-named list of `fn`'s formals.
#'   Named items keep their name as the item id; unnamed items get their index.
#' @param n_workers Concurrent subprocesses (validated: finite, whole, >= 1).
#' @param dev_path Source tree for `devtools::load_all()` in the worker, or
#'   `NULL` for the installed package. For a `package_function()` `fn` this is
#'   the CONSUMER's source tree; for a bare-closure `fn` it is batchit's own
#'   (an adhoc closure has no separate consumer identity to load). A
#'   given-but-wrong path errors rather than silently falling back to
#'   installed code.
#' @param p A progress callback such as a `progressr` progressor, or `NULL`. It
#'   is called once per completed item with `message = <id and time>`.
#' @param label Optional short stage tag prefixed to the progress message.
#' @param timeout Per-item wall-clock limit in seconds; a worker that exceeds it
#'   is killed and reported as a failure. Defaults to a generous hang-catcher
#'   (the internal `.BATCH_DEFAULT_TIMEOUT`, 6 hours); pass `Inf` to disable.
#' @return `invisible(NULL)`.
#' @examples
#' \dontrun{
#' t <- package_function("mypkg", "process_one_slice")
#' run(t, items = list(list(x = 1), list(x = 2)), n_workers = 2)
#' }
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
  .batch_run_impl(fn, items, n_workers, dev_path = dev_path, collect = FALSE,
    p = p, label = label, timeout = timeout, .caller = "run")
}

#' Run `fn` on each of a fixed list of items, one subprocess per item, collecting values
#'
#' Shape A of the contract: the items already exist (each a small named list of
#' `fn`'s formals; the worker opens its own data), so a fresh R process per
#' item is not a cost to amortise but the memory strategy itself -- a large
#' analysis item can peak at tens of GB and R does not return that memory to the
#' OS, so process exit is how it is reclaimed. This is why batchit does NOT reuse
#' workers: worker reuse would defeat exactly this.
#'
#' `fn` is EITHER a `package_function()` descriptor (hash-verified,
#' auditable; use in production) OR a bare closure (ad-hoc, gated by a static
#' self-containedness lint and a mandatory `baseenv()` rebase; for tests and
#' one-offs only -- this folds in the former ad-hoc-closure frontend).
#'
#' Both-end validation, a hash-verified target descriptor (or, for a bare
#' closure, a per-dispatch identity nonce), per-item logs written to files
#' (never pipes -- a chatty worker filling the OS pipe buffer is what
#' deadlocks a pipe transport), a bounded log tail on failure, and a loud stop
#' on the first failure. Warnings a target captures are surfaced in the
#' parent, tagged by item id.
#'
#' batchit is thread-agnostic: it sets no BLAS / data.table thread counts and
#' passes none to the worker. If `fn` is itself multi-threaded, dividing
#' cores across `n_workers` (to avoid oversubscription) is the CONSUMER's
#' responsibility, not the runner's.
#'
#' The worker script is always the runner's (batchit's); `dev_path`, when given,
#' is the CONSUMER's source tree. When runner and consumer differ, the worker
#' loads both (the consumer via `dev_path`/`requireNamespace`, the runner via
#' `requireNamespace`).
#'
#' @param fn EITHER a `package_function` descriptor from [package_function()]
#'   OR a bare closure -- see the details above.
#' @param items List of items; each a fully-named list of `fn`'s formals.
#'   Named items keep their name as the item id; unnamed items get their index.
#' @param n_workers Concurrent subprocesses (validated: finite, whole, >= 1).
#' @param dev_path Source tree for `devtools::load_all()` in the worker, or
#'   `NULL` for the installed package. For a `package_function()` `fn` this is
#'   the CONSUMER's source tree; for a bare-closure `fn` it is batchit's own
#'   (an adhoc closure has no separate consumer identity to load). A
#'   given-but-wrong path errors rather than silently falling back to
#'   installed code.
#' @param p A progress callback such as a `progressr` progressor, or `NULL`. It
#'   is called once per completed item with `message = <id and time>`.
#' @param label Optional short stage tag prefixed to the progress message.
#' @param timeout Per-item wall-clock limit in seconds; a worker that exceeds it
#'   is killed and reported as a failure. Defaults to a generous hang-catcher
#'   (the internal `.BATCH_DEFAULT_TIMEOUT`, 6 hours); pass `Inf` to disable.
#' @return A list of values in item order.
#' @examples
#' \dontrun{
#' t <- package_function("mypkg", "process_one_slice")
#' out <- run_and_collect(t, items = list(list(x = 1), list(x = 2)), n_workers = 2)
#' }
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
  .batch_run_impl(fn, items, n_workers, dev_path = dev_path, collect = TRUE,
    p = p, label = label, timeout = timeout, .caller = "run_and_collect")
}

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
    sprintf(".batch_stream_%s_%d", nonce, i)
  }
})

#' Stream a producer's items through a target under backpressure
#'
#' Shape B of the contract: the parent IS the producer. Each item is generated
#' lazily by `producer(id)` and is itself the payload (a data slice), so it must
#' NOT be materialised until there is a worker ready for it -- otherwise the whole
#' dataset lands in memory (or on disk twice) at once. mirai's persistent daemons
#' and in-memory transport are exactly this shape; the shape-A
#' materialise-every-item-to-a-tempfile model is exactly the wrong one for it.
#'
#' Same contract as [run()]/[run_and_collect()] -- target descriptor, both-end validation,
#' result-envelope inspection, warning surfacing and loud failure -- over a
#' different transport. At most `2 * n_workers` items are in flight; the producer
#' for the next id is not called until an in-flight slot frees, which is the
#' backpressure. Each task carries a `timeout`, so a wedged daemon cannot block
#' forever.
#'
#' Never touches mirai's DEFAULT compute profile: `daemons(n)` there would reset
#' and destroy any daemon configuration the caller had. Each invocation allocates
#' a fresh PRIVATE profile under the runner's reserved `.batch_stream_<nonce>_`
#' prefix, where `<nonce>` is a high-entropy, session-specific string -- so the
#' name can never be "default" (that guarantee holds by construction), and a
#' registry collision would require another party to have claimed a name under
#' that same nonce-namespaced prefix in this session. It tears only its own
#' profile down. As with [run()]/[run_and_collect()], batchit is thread-agnostic: any within-
#' item thread policy is the consumer's.
#'
#' The daemon loads the CONSUMER package (via `dev_path`/`requireNamespace`) and,
#' when the runner differs from the consumer, the RUNNER too -- the daemon needs
#' `.batch_execute` resolvable in the runner's namespace.
#'
#' Requires the suggested `mirai` package (parallelism is opt-in).
#'
#' @param target A `package_function` descriptor from [package_function()].
#' @param ids Vector of stable item ids (non-empty, non-NA, unique). Length =
#'   number of items; order is the order of production and of the results.
#' @param producer `function(id)` returning that item -- a fully-named list of
#'   the target's formals. Called once per id, in the parent, under backpressure.
#' @param n_workers Number of mirai daemons (validated).
#' @param dev_path Consumer-package source tree, loaded once per daemon via
#'   `devtools::load_all()`, or `NULL` for the installed consumer package. A
#'   given-but-wrong path errors, even for an empty workload.
#' @param collect If `TRUE`, return each item's value (named by id, in id order);
#'   if `FALSE`, the daemon reports status but no value crosses back.
#' @param p A progress callback such as a `progressr` progressor, or `NULL`.
#' @param label Optional short stage tag prefixed to the progress message.
#' @param timeout Per-item wall-clock limit in seconds (generous default, the
#'   internal `.BATCH_DEFAULT_TIMEOUT` of 6 hours; `Inf` disables). A task
#'   exceeding it resolves to an error and is reported.
#' @return If `collect`, a named list of values in id order; else
#'   `invisible(NULL)`.
#' @examples
#' \dontrun{
#' t <- package_function("mypkg", "write_one_slice")
#' batch_stream(
#'   t,
#'   ids = c("2019", "2020", "2021"),
#'   producer = function(id) list(slice = load_year(id)),
#'   n_workers = 4
#' )
#' }
#' @export
batch_stream <- function(
  target,
  ids,
  producer,
  n_workers,
  dev_path = NULL,
  collect = TRUE,
  p = NULL,
  label = NULL,
  timeout = .BATCH_DEFAULT_TIMEOUT
) {
  if (!inherits(target, "package_function")) {
    stop("batch_stream(): `target` must come from package_function()", call. = FALSE)
  }
  if (!is.function(producer)) {
    stop("batch_stream(): `producer` must be a function of one id", call. = FALSE)
  }
  n_workers <- .batch_validate_n_workers(n_workers, "batch_stream()")
  # Validate ALL config BEFORE the empty-workload early return.
  ids <- .batch_check_ids(ids)
  collect <- .batch_validate_collect(collect, "batch_stream()")
  timeout <- .batch_validate_timeout(timeout, "batch_stream()")
  dev_path <- .batch_validate_dev_path(dev_path, target$package)
  runner_pkg <- .batch_runner_package()

  n <- length(ids)
  if (n == 0L) return(if (collect) list() else invisible(NULL))
  if (!requireNamespace("mirai", quietly = TRUE)) {
    stop("batch_stream() requires the 'mirai' package", call. = FALSE)
  }

  # A fresh PRIVATE profile per invocation (see [.batch_stream_profile()]).
  # Because the generated name carries the reserved `.batch_stream_<nonce>_`
  # prefix it can never be "default", so daemons(n)/daemons(0) here can never
  # reset the caller's default profile, and the high-entropy session nonce makes
  # a collision with another party's session-wide profile name a non-issue by
  # construction -- no ownership predicate or collision policy to maintain.
  compute <- .batch_stream_profile()
  mirai::daemons(n_workers, .compute = compute)
  on.exit(mirai::daemons(0L, .compute = compute), add = TRUE)

  # Load the consumer AND (when it differs) the runner package ONCE per
  # persistent daemon -- not per task. The daemon needs .batch_execute resolvable
  # in the runner's namespace, while the consumer supplies the target.
  if (is.null(dev_path)) {
    mirai::everywhere(
      {
        requireNamespace(.consumer, quietly = TRUE)
        if (!identical(.runner, .consumer)) requireNamespace(.runner, quietly = TRUE)
      },
      .consumer = target$package, .runner = runner_pkg, .compute = compute
    )
  } else {
    mirai::everywhere(
      {
        suppressPackageStartupMessages(devtools::load_all(.dev, quiet = TRUE))
        # Load the RUNNER too when it differs from the consumer: the daemon needs
        # <runner>:::.batch_execute, which devtools::load_all(consumer) does not
        # provide once runner != consumer (the extraction seam).
        if (!identical(.runner, .consumer)) requireNamespace(.runner, quietly = TRUE)
      },
      .dev = dev_path, .consumer = target$package, .runner = runner_pkg,
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
  results <- if (collect) vector("list", n) else NULL
  inflight <- list()
  n_done <- 0L

  .stream_fail <- function(item, reason) {
    stop(sprintf("batch_stream(): id '%s' %s", item$id, reason), call. = FALSE)
  }

  # Drain the OLDEST in-flight task (FIFO). Two failure channels, identical in
  # spirit to run()/run_and_collect(): a daemon-level error value (the task expression itself
  # blew up, the package would not load, or the per-task timeout fired) and a
  # target-level error envelope, both routed through the shared inspector.
  drain_one <- function() {
    item <- inflight[[1L]]
    v <- mirai::call_mirai(item$h)$data
    if (mirai::is_error_value(v)) {
      .stream_fail(item, sprintf("daemon/timeout error: %s", as.character(v)))
    }
    insp <- .batch_inspect_result(v, item$id, target)
    if (!insp$ok) .stream_fail(item, insp$reason)
    .batch_surface_warnings(insp$warnings, item$id)
    # results[pos] <- list(value), not [[<-: the same NULL-deletion trap as
    # run()/run_and_collect() -- a target returning NULL must keep its slot, not vanish.
    if (collect) results[item$pos] <<- list(insp$value)
    inflight[[1L]] <<- NULL
    n_done <<- n_done + 1L
    if (!is.null(p)) {
      p(message = if (is.null(label)) as.character(item$id) else paste(label, item$id))
    }
  }

  for (i in seq_len(n)) {
    # Backpressure: block the producer until an in-flight slot frees. This is why
    # shape B does not blow up memory -- producer(id) is not even called until
    # there is somewhere to put its result.
    while (length(inflight) >= max_inflight) drain_one()

    id <- ids[[i]]
    args <- producer(id)
    .batch_validate_item(target, args, where = "parent", id = id)
    envelope <- .batch_input_envelope(
      target, dev_path, runner_pkg, id, args, collect = collect)
    h <- mirai::mirai(
      {
        get(".batch_execute", envir = asNamespace(.runner))(.env)
      },
      .env = envelope, .runner = runner_pkg, .compute = compute,
      .timeout = task_timeout_ms
    )
    inflight[[length(inflight) + 1L]] <- list(id = id, pos = i, h = h)
  }

  while (length(inflight) > 0L) drain_one()

  if (collect) {
    names(results) <- as.character(ids)
    results
  } else {
    invisible(NULL)
  }
}

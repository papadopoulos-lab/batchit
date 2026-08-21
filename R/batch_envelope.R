# The wire envelope of the dispatcher in R/batch.R. It holds the private qs2
# codec and the structural contract the child enforces. It also holds the one
# builder every frontend calls, plus the print method for `batch_envelope`.

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
    stop(
      ".batch_write_envelope(): could not rename ",
      tmp,
      " -> ",
      path,
      call. = FALSE
    )
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
#' `conditionMessage()` dispatches, so a hostile condition could itself throw.
#' Such a condition comes from a target, or from a classed object with a
#' registered `conditionMessage` method. A throw there would escape an error
#' handler and defeat the "total" guarantee. Used wherever batchit renders a
#' condition from untrusted code to text.
#' @noRd
.batch_condition_message <- function(e) {
  tryCatch(conditionMessage(e), error = function(e2) "<unprintable condition>")
}

#' Validate the STRUCTURE of an input envelope (not its arguments)
#'
#' Cheap structural gate run in the child before anything trusts the envelope:
#' protocol number, meta presence, and the identity fields must be well-formed
#' strings. Without this, the protocol number is decorative. A version-skewed
#' or corrupt envelope would then produce a confusing error deep inside
#' resolution, instead of a clear one here. Argument validation (against the
#' target's formals) is a separate step -- see `.batch_validate_item()`.
#'
#' Branches on `meta$fn_kind` (design DESIGN.md sections 2 and 5).
#' `"package"` requires `package`/`symbol`/`hash` and forbids `fn`/`nonce`.
#' `"adhoc"` is the reverse: it requires `fn` and `nonce`, and forbids
#' `package`/`symbol`/`hash` (there is no package to resolve). `fn` is the
#' closure, re-linted for self-containedness HERE -- design section 6,
#' `.batch_lint_adhoc_fn()` in `R/batch_adhoc.R`. That re-lint is the
#' CHILD-side correctness copy of the check a frontend already ran at dispatch
#' time. `nonce` is the closure's per-dispatch identity token, design section
#' 9.4.
#'
#' Also branches on whether `meta$outputs` is present. Absent means today's
#' return-value dispatch: `collect` required, `style`/`marker`/`attempt`
#' forbidden. Present means a declared-output commit dispatch:
#' `style`/`marker`/`attempt` required, `collect` forbidden. See design
#' section 5. Any `meta` field outside the known set is rejected, not silently
#' ignored.
#' @noRd
.batch_check_envelope <- function(env) {
  if (!is.list(env)) {
    stop(
      ".batch envelope is not a list (got ",
      class(env)[1L],
      ")",
      call. = FALSE
    )
  }
  # Duplicate outer field names would let field selection pick the first of two;
  # and every field is read with EXACT `[[`, never `$` -- `$` partial-matches, so
  # `env$meta` would match an outer field named `metadata`, and `meta$dev_path` a
  # field named `dev_path_payload`, letting a noncanonical name control behaviour.
  if (anyDuplicated(names(env))) {
    stop(".batch envelope has duplicate field names", call. = FALSE)
  }
  # Unknown top-level fields are rejected, not ignored -- the same policy
  # already applied to meta (design DESIGN.md section 5) extended to
  # the outer envelope, so a typo'd or smuggled top-level field cannot ride
  # along silently.
  known_top_fields <- c("protocol", "meta", "args")
  unknown_top <- setdiff(names(env), known_top_fields)
  if (length(unknown_top) > 0L) {
    stop(
      sprintf(
        ".batch envelope has unknown top-level field(s): %s",
        paste(unknown_top, collapse = ", ")
      ),
      call. = FALSE
    )
  }
  if (!identical(env[["protocol"]], .BATCH_PROTOCOL)) {
    stop(
      sprintf(
        ".batch envelope protocol mismatch: expected %s, got %s",
        .BATCH_PROTOCOL,
        format(env[["protocol"]] %||% "<none>")
      ),
      call. = FALSE
    )
  }
  meta <- env[["meta"]]
  if (!is.list(meta)) {
    stop(".batch envelope has no meta list", call. = FALSE)
  }
  if (anyDuplicated(names(meta))) {
    stop(".batch envelope meta has duplicate field names", call. = FALSE)
  }
  known_meta_fields <- c(
    "fn_kind",
    "id",
    "runner_package",
    "dev_path",
    "version",
    "package",
    "symbol",
    "hash",
    "collect",
    "outputs",
    "marker",
    "style",
    "attempt",
    "fn",
    "nonce"
  )
  unknown <- setdiff(names(meta), known_meta_fields)
  if (length(unknown) > 0L) {
    stop(
      sprintf(
        ".batch envelope meta has unknown field(s): %s",
        paste(unknown, collapse = ", ")
      ),
      call. = FALSE
    )
  }

  # id / runner_package are required regardless of fn_kind: id lets the parent
  # match a result to the item it dispatched; runner_package is a load-deciding
  # field (it names the namespace that supplies .batch_execute), so both
  # transports must accept the SAME complete schema, or one could pass an
  # envelope the other's worker rejects.
  for (f in c("id", "runner_package")) {
    v <- meta[[f]]
    if (!is.character(v) || length(v) != 1L || is.na(v) || !nzchar(v)) {
      stop(
        sprintf(
          ".batch envelope meta$%s is missing or not a non-empty string",
          f
        ),
        call. = FALSE
      )
    }
  }

  fn_kind <- meta[["fn_kind"]]
  if (
    !is.character(fn_kind) ||
      length(fn_kind) != 1L ||
      is.na(fn_kind) ||
      !(fn_kind %in% c("package", "adhoc"))
  ) {
    stop(
      sprintf(
        ".batch envelope meta$fn_kind is missing or not one of \"package\"/\"adhoc\": %s",
        format(fn_kind %||% "<none>")
      ),
      call. = FALSE
    )
  }
  if (identical(fn_kind, "package")) {
    for (f in c("package", "symbol", "hash")) {
      v <- meta[[f]]
      if (!is.character(v) || length(v) != 1L || is.na(v) || !nzchar(v)) {
        stop(
          sprintf(
            ".batch envelope meta$%s is missing or not a non-empty string",
            f
          ),
          call. = FALSE
        )
      }
    }
    if (!is.null(meta[["fn"]]) || !is.null(meta[["nonce"]])) {
      stop(
        paste0(
          ".batch envelope: meta$fn/meta$nonce are forbidden when ",
          "fn_kind is \"package\" (adhoc-only fields)"
        ),
        call. = FALSE
      )
    }
  } else {
    # fn_kind == "adhoc" (DESIGN.md sections 2, 5, 6):
    # no package/symbol/hash to resolve -- the closure and its per-dispatch
    # identity nonce (section 7) travel directly in meta$fn / meta$nonce.
    for (f in c("package", "symbol", "hash")) {
      if (!is.null(meta[[f]])) {
        stop(
          sprintf(
            paste0(
              ".batch envelope: meta$%s is forbidden when fn_kind is ",
              "\"adhoc\" (there is no package to resolve)"
            ),
            f
          ),
          call. = FALSE
        )
      }
    }
    # Re-lint HERE, in the CHILD: design section 6's self-containedness check
    # runs at BOTH ends. A frontend (run()/run_and_collect() /
    # run_and_write_files_atomically() with a bare closure) already linted at
    # dispatch time (early UX); this is the
    # correctness copy -- a worker must never simply trust that an envelope
    # reaching it actually went through a frontend's own check. Also enforces
    # "closure, not a primitive" and "no `...`" (see .batch_lint_adhoc_fn() in
    # R/batch_adhoc.R).
    .batch_lint_adhoc_fn(meta[["fn"]], where = "child", id = meta[["id"]])
    nonce <- meta[["nonce"]]
    if (
      !is.character(nonce) ||
        length(nonce) != 1L ||
        is.na(nonce) ||
        !nzchar(nonce)
    ) {
      stop(
        ".batch envelope meta$nonce is missing or not a non-empty string",
        call. = FALSE
      )
    }
  }

  outputs <- meta[["outputs"]]
  if (is.null(outputs)) {
    collect <- meta[["collect"]]
    if (!is.logical(collect) || length(collect) != 1L || is.na(collect)) {
      stop(
        ".batch envelope meta$collect is missing or not a logical flag",
        call. = FALSE
      )
    }
    if (
      !is.null(meta[["style"]]) ||
        !is.null(meta[["marker"]]) ||
        !is.null(meta[["attempt"]])
    ) {
      stop(
        paste0(
          ".batch envelope: meta$style/marker/attempt are forbidden when ",
          "meta$outputs is absent (return-value dispatch)"
        ),
        call. = FALSE
      )
    }
  } else {
    if (!is.null(meta[["collect"]])) {
      stop(
        paste0(
          ".batch envelope: meta$collect is forbidden when meta$outputs is ",
          "present (declared-output commit dispatch)"
        ),
        call. = FALSE
      )
    }
    .batch_validate_output_map(outputs, where = "child", id = meta[["id"]])
    # The CHILD may replay independently (it is not merely a passive
    # executor of whatever the parent already checked), so it re-validates
    # the same conservative path rules the parent enforced at dispatch time
    # (design DESIGN.md section 4.1) -- reusing
    # .batch_validate_output_paths() -- rather than trusting structural
    # presence alone. Crucially the child must NOT silently re-normalize a
    # path into something DIFFERENT from what the parent dispatched (that
    # would let the child commit to a path the parent never validated): so
    # every output path must already be exactly its own normalized form, or
    # this rejects rather than "fixing" it.
    normalized_outputs <- .batch_validate_output_paths(outputs, meta[["id"]])
    if (!identical(normalized_outputs, outputs)) {
      stop(
        sprintf(
          paste0(
            ".batch envelope meta$outputs [item '%s']: output path(s) are not already ",
            "absolute/normalized (the parent must dispatch already-normalized paths; the ",
            "child re-validates but never silently re-normalizes a path into something ",
            "different)"
          ),
          meta[["id"]]
        ),
        call. = FALSE
      )
    }
    style <- meta[["style"]]
    if (
      !is.character(style) ||
        length(style) != 1L ||
        is.na(style) ||
        !nzchar(style)
    ) {
      stop(
        ".batch envelope meta$style is missing or not a non-empty string",
        call. = FALSE
      )
    }
    # Reject any style other than "return"/"staged_writer" HERE -- BEFORE the
    # target ever runs (this function is called before do.call() in
    # .batch_execute()). Letting a side-effecting target run for an envelope
    # whose style will fail anyway is exactly the ordering bug this closes.
    if (!(style %in% c("return", "staged_writer"))) {
      stop(
        sprintf(
          paste0(
            ".batch envelope meta$style '%s' is not supported (must be \"return\" or ",
            "\"staged_writer\") -- rejected before the target runs"
          ),
          style
        ),
        call. = FALSE
      )
    }
    marker <- meta[["marker"]]
    if (
      !is.character(marker) ||
        length(marker) != 1L ||
        is.na(marker) ||
        !nzchar(marker)
    ) {
      stop(
        ".batch envelope meta$marker is missing or not a non-empty string",
        call. = FALSE
      )
    }
    if (!.batch_is_absolute_path(marker)) {
      stop(
        sprintf(
          ".batch envelope meta$marker [item '%s'] is not an absolute path: %s",
          meta[["id"]],
          marker
        ),
        call. = FALSE
      )
    }
    marker_parent <- dirname(marker)
    if (!dir.exists(marker_parent)) {
      stop(
        sprintf(
          paste0(
            ".batch envelope meta$marker [item '%s']: parent directory does not exist: %s"
          ),
          meta[["id"]],
          marker_parent
        ),
        call. = FALSE
      )
    }
    # Symmetric with the output-path re-validation: the parent derives the
    # marker from an already-normalized output dir, so a non-normalized marker
    # like ".../sub/../.batchit__1" is a corrupted/hostile envelope. Normalize
    # only the PARENT dir + reattach the untouched basename -- do NOT normalize
    # the whole path, which would FOLLOW a leaf marker symlink (the same
    # leaf-unresolved treatment `.batch_validate_output_paths()` gives output
    # paths) and could reject an otherwise-valid envelope for the wrong
    # reason; the CHILD's own commit sequence (`.batch_commit_task()`)
    # unconditionally removes and replaces whatever sits at the marker path.
    norm_marker <- file.path(
      normalizePath(dirname(marker), mustWork = FALSE),
      basename(marker)
    )
    if (!identical(marker, norm_marker)) {
      stop(
        sprintf(
          ".batch envelope meta$marker [item '%s'] is not already absolute/normalized",
          meta[["id"]]
        ),
        call. = FALSE
      )
    }
    attempt <- meta[["attempt"]]
    if (
      !is.character(attempt) ||
        length(attempt) != 1L ||
        is.na(attempt) ||
        !nzchar(attempt)
    ) {
      stop(
        ".batch envelope meta$attempt is missing or not a non-empty string",
        call. = FALSE
      )
    }
  }

  if (!is.list(env[["args"]])) {
    stop(".batch envelope args is not a list", call. = FALSE)
  }
  invisible(TRUE)
}

#' Build a dispatch input envelope
#'
#' The ONE place EVERY frontend assembles the wire envelope. Those frontends
#' are `run()`, `run_and_collect()`, `run_and_write_files_atomically()` and
#' `stream_from_parent_and_write_files_atomically()`. None of them can then
#' drift in the schema the child reads back (`.batch_check_envelope()` /
#' `.batch_execute()`). `runner` (the runner package name) travels so the
#' worker/daemon knows which package holds `.batch_execute` -- the field that
#' carries the runner-vs-consumer split. `id` is coerced to a string here so a
#' numeric item index and an explicit character id land identically.
#'
#' `fn_kind`/`collect` are the return-value-dispatch fields (unchanged
#' defaults: `run()`/`run_and_collect()` pass only `collect`).
#' `outputs`/`marker`/`style`/`attempt` are the declared-output commit fields
#' `run_and_write_files_atomically()` and
#' `stream_from_parent_and_write_files_atomically()` supply instead (design
#' DESIGN.md sections 4 and 5). `collect` and those four are mutually
#' exclusive, which `.batch_check_envelope()` enforces.
#'
#' `fn`/`nonce` are the `fn_kind = "adhoc"` fields (Phase 6' Unit 3, design
#' sections 1, 4, 9.4). `fn` carries the already-linted,
#' already-baseenv()-rebased closure itself. `nonce` is its per-dispatch
#' identity token. It stands in for the package/symbol/hash identity a
#' `package_function` would otherwise supply. `run()`, `run_and_collect()` and
#' `run_and_write_files_atomically()`, each with a bare closure, pass
#' `target = NULL` and these two instead. Forbidden (must stay `NULL`) for
#' `fn_kind = "package"`, enforced by `.batch_check_envelope()`.
#' @noRd
.batch_input_envelope <- function(
  target,
  dev_path,
  runner,
  id,
  args,
  fn_kind = "package",
  collect = NULL,
  outputs = NULL,
  marker = NULL,
  style = NULL,
  attempt = NULL,
  fn = NULL,
  nonce = NULL
) {
  # class = "batch_envelope" is ONLY an attribute on this plain list -- it adds
  # a print method for debugging (see print.batch_envelope() below) and nothing
  # else. The worker reads this with bare qs2::qs_read() and
  # .batch_worker_check() / .batch_check_envelope() both access fields via
  # exact `[[`, never S3 dispatch, so the class is inert on the read path: no
  # package needs to be loaded to deserialize or structurally validate it
  # (DESIGN.md section 5).
  structure(
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
        attempt = attempt
      ),
      args = args
    ),
    class = "batch_envelope"
  )
}

#' Print a `batch_envelope` (debugging only)
#'
#' A concise, one-screen summary of the per-item wire envelope -- protocol,
#' target identity (or ad-hoc closure identity), delivery mode, and dev_path if
#' set. Purely cosmetic. The class it dispatches on is otherwise internal (see
#' `.batch_input_envelope()`). This method exists so an envelope printed at
#' the console during debugging is readable, instead of a dump of the raw
#' nested list.
#'
#' @param x A `batch_envelope`.
#' @param ... Ignored.
#' @return `x`, invisibly.
#' @exportS3Method
#' @noRd
print.batch_envelope <- function(x, ...) {
  meta <- x[["meta"]]
  fn_line <- if (identical(meta[["fn_kind"]], "package")) {
    sprintf(
      "%s::%s (hash %s)",
      meta[["package"]],
      meta[["symbol"]],
      substr(meta[["hash"]] %||% "", 1L, 8L)
    )
  } else {
    sprintf("<adhoc closure> (nonce %s)", meta[["nonce"]])
  }
  delivery_line <- if (!is.null(meta[["outputs"]])) {
    sprintf(
      "commit (style=%s, %d outputs)",
      meta[["style"]],
      length(meta[["outputs"]])
    )
  } else {
    sprintf("return (collect=%s)", meta[["collect"]])
  }
  cat(sprintf("<batch_envelope> protocol %s\n", format(x[["protocol"]])))
  cat(sprintf("  fn_kind: %s\n", meta[["fn_kind"]]))
  cat(sprintf("  id:      %s\n", meta[["id"]]))
  cat(sprintf("  fn:      %s\n", fn_line))
  cat(sprintf("  delivery: %s\n", delivery_line))
  if (!is.null(meta[["dev_path"]])) {
    cat(sprintf("  dev_path: %s\n", meta[["dev_path"]]))
  }
  invisible(x)
}

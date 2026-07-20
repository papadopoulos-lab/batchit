# Generic batch worker (shape A) -- the ONE worker script, the process boundary
# only (all dispatch logic lives in package code so it is unit-testable):
#
#   Rscript --vanilla batch_worker.R <input_envelope.qs2> <output_envelope.qs2>
#
# Read the envelope ONCE with bare `qs2::` (no package is loaded yet -- the
# envelope names where to load from), structurally check the fields that decide
# WHAT CODE loads, load the RUNNER package (meta$runner_package -- "batchit")
# and check the envelope's PROTOCOL number using the runner's own constant --
# BEFORE loading the CONSUMER (meta$package / meta$dev_path) -- then hand the
# whole envelope to <runner>:::.batch_execute() (resolve + hash-verify the
# target, re-validate args, run, write result). Runner and consumer are
# different packages here, which is the extraction seam: the runner supplies
# .batch_execute, the consumer supplies the target.
#
# Protocol-before-consumer (Phase 6' Unit 1, PHASE6_DESIGN.md section 1): a
# version-skewed envelope must be rejected before any CONSUMER code loads. The
# runner itself is always loaded first regardless (it is needed both to check
# the protocol and to supply .batch_execute), so "protocol before loading" here
# means "before loading the CONSUMER" -- when runner == consumer (batchit
# testing itself) that one load_all() satisfies both roles at once.
#
# fn_kind == "adhoc" (Phase 6' Unit 3, PHASE6_DESIGN.md sections 1, 4, 5): no
# CONSUMER at all -- meta$package/meta$symbol/meta$hash are absent, and the
# closure to run travels directly in meta$fn (already baseenv()-rebased by
# the parent), with meta$nonce as its per-dispatch identity token in place of
# a package/symbol/hash descriptor. See the runner-load block below for how
# dev_path is interpreted in this case.
#
# Failure contract: any failure at or before .batch_execute() (unreadable or
# malformed envelope, a version-skewed protocol, a consumer/dev tree that will
# not load) writes NOTHING and exits non-zero -- the parent's exit-code channel
# plus the per-item log tail is the diagnostic path. A TARGET-level failure is
# different: .batch_execute() is total and returns a structured error envelope
# (exit 0).

argv <- commandArgs(trailingOnly = TRUE)
input_path <- argv[1L]
output_path <- argv[2L]

# Package-independent STRUCTURAL check, BEFORE any package/dev tree loads (base R
# + bare qs2 only): meta$dev_path / meta$package / meta$runner_package feed
# load_all()/requireNamespace() before the in-package .batch_check_envelope()
# could reject them. Exact `[[`, never `$`: `$` PARTIAL-matches, so `meta$dev_path`
# would resolve a field `dev_path_payload` -- letting a noncanonical field steer
# which code loads.
.batch_worker_check <- function(env) {
  if (!is.list(env) || anyDuplicated(names(env))) {
    stop("batch_worker: envelope is not a list, or has duplicate field names")
  }
  meta <- env[["meta"]]
  if (!is.list(meta) || anyDuplicated(names(meta))) {
    stop("batch_worker: envelope meta is not a list, or has duplicate field names")
  }
  is_str1 <- function(v) is.character(v) && length(v) == 1L && !is.na(v) && nzchar(v)
  # runner_package is REQUIRED, exactly like id: it decides WHICH namespace
  # supplies .batch_execute (the runner-vs-consumer split). Absent -- not merely
  # ill-typed -- it must die here, before any code loads. There is no fall-back
  # to the consumer package: a malformed envelope must never be able to make the
  # consumer namespace supply .batch_execute.
  for (f in c("id", "runner_package")) {
    if (!is_str1(meta[[f]])) {
      stop(sprintf("batch_worker: meta$%s missing or not a non-empty string", f))
    }
  }
  # fn_kind is the OTHER load-deciding field: it is required and must be one
  # of the two known values before anything else is inspected.
  fn_kind <- meta[["fn_kind"]]
  if (!is_str1(fn_kind) || !(fn_kind %in% c("package", "adhoc"))) {
    stop(sprintf(
      "batch_worker: meta$fn_kind missing or invalid (must be 'package' or 'adhoc'), got: %s",
      if (is.null(fn_kind)) "<none>" else format(fn_kind)))
  }
  if (identical(fn_kind, "adhoc")) {
    # Phase 6' Unit 3: no package/symbol/hash to resolve -- the closure
    # travels directly in meta$fn (already baseenv()-rebased by the parent
    # before serialization; re-linted for real, package-load-requiring
    # correctness later, inside <runner>:::.batch_check_envelope()). Only a
    # cheap structural presence check happens HERE, before any package loads
    # -- is.function() is base R, so this needs nothing beyond bare qs2.
    if (!is.function(meta[["fn"]])) {
      stop("batch_worker: meta$fn is missing or not a function (fn_kind = 'adhoc')")
    }
  } else {
    # fn_kind == "package": package/symbol/hash are load-deciding fields,
    # required like id/runner_package.
    for (f in c("package", "symbol", "hash")) {
      if (!is_str1(meta[[f]])) {
        stop(sprintf("batch_worker: meta$%s missing or not a non-empty string", f))
      }
    }
  }
  if (!is.null(meta[["dev_path"]]) && !is_str1(meta[["dev_path"]])) {
    stop("batch_worker: meta$dev_path is not a valid path string")
  }
  invisible(TRUE)
}

env <- qs2::qs_read(input_path)
.batch_worker_check(env)  # validate structure BEFORE loading any code
meta <- env[["meta"]]
dev_path <- meta[["dev_path"]]
package <- meta[["package"]]  # NULL for fn_kind == "adhoc" (no package to resolve)
fn_kind <- meta[["fn_kind"]]
runner <- meta[["runner_package"]]  # REQUIRED (checked above); no consumer fallback

# Load the RUNNER first, ALWAYS -- needed both to supply .batch_execute and to
# check the envelope's PROTOCOL number before the CONSUMER package loads (a
# version-skewed envelope must not get as far as loading potentially
# unrelated/incompatible consumer code). When runner == consumer AND dev_path
# was given, load_all(dev_path) loads both in one step (batchit testing
# itself); otherwise the runner is always the INSTALLED package -- dev_path
# only ever names the CONSUMER's source tree (see .batch_validate_dev_path()).
#
# fn_kind == "adhoc" (Phase 6' Unit 3) has no separate "consumer" identity at
# all -- meta$package is NULL, so `identical(runner, package)` can never be
# TRUE for it. Any dev_path given for an adhoc dispatch is therefore treated
# as naming the RUNNER's (batchit's) own source tree instead (see
# batch_fn()'s `dev_path` doc) -- this is what lets batchit's OWN adhoc test
# suite run against source without a reinstall, mirroring the package-kind
# self-test path above. It is NOT a second dev-tree slot for some other
# helper package: a closure's own `pkg::fun()` calls resolve via ordinary
# lazy namespace loading regardless (see the CONSUMER step below), so this
# limitation only matters if a closure specifically needs a DEV (not
# installed) version of some package other than batchit -- out of scope here.
#
# KNOWN NARROW LIMITATION (documented, not fixed): in the runner==consumer +
# dev_path branch below (package OR adhoc), load_all(dev_path) necessarily
# runs BEFORE the protocol check a few lines down -- there is no way to read
# the DEV TREE's .BATCH_PROTOCOL without loading it (that's the one case the
# installed package's constant cannot be trusted for: the dev tree may have
# bumped the protocol relative to what's installed), and load_all() runs the
# package's own load hooks as a side effect of loading. So a version-skewed
# envelope in THIS one config can trigger the consumer's load hooks before
# being rejected. This only arises when batchit points dev_path at ITS OWN
# source tree (batchit testing itself, package OR adhoc); in every production
# config runner != package and the runner (always the INSTALLED package)
# loads first via requireNamespace() in the branch below, so protocol is
# checked before any consumer code -- dev_path only ever names the CONSUMER
# there, never the runner.
suppressPackageStartupMessages({
  if (!is.null(dev_path) && (identical(fn_kind, "adhoc") || identical(runner, package))) {
    devtools::load_all(dev_path, quiet = TRUE)
  } else if (!requireNamespace(runner, quietly = TRUE)) {
    stop(sprintf("could not load runner package '%s'", runner))
  }
})

runner_protocol <- get(".BATCH_PROTOCOL", envir = asNamespace(runner))
if (!identical(env[["protocol"]], runner_protocol)) {
  stop(sprintf("batch_worker: envelope protocol mismatch: expected %s, got %s",
    runner_protocol,
    if (is.null(env[["protocol"]])) "<none>" else format(env[["protocol"]])))
}

# Now load the CONSUMER, when there is one. fn_kind == "adhoc" has none -- the
# closure is self-contained (or its own package need was already covered by
# the dev_path branch above); any `pkg::fun()` it calls lazy-loads that
# namespace on its own the moment it is evaluated, exactly like ordinary R
# code, so no extra step is needed here for that case.
suppressPackageStartupMessages({
  if (!identical(fn_kind, "adhoc") && !identical(runner, package)) {
    if (!is.null(dev_path)) {
      devtools::load_all(dev_path, quiet = TRUE)
    } else if (!requireNamespace(package, quietly = TRUE)) {
      stop(sprintf("could not load consumer package '%s'", package))
    }
  }
})

ns <- asNamespace(runner)
result <- get(".batch_execute", envir = ns)(env)
get(".batch_write_envelope", envir = ns)(result, output_path)

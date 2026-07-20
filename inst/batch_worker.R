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
  # fn_kind is the OTHER load-deciding field (Phase 6' Unit 1): it is required
  # and must be one of the two known values before anything else is inspected.
  fn_kind <- meta[["fn_kind"]]
  if (!is_str1(fn_kind) || !(fn_kind %in% c("package", "adhoc"))) {
    stop(sprintf(
      "batch_worker: meta$fn_kind missing or invalid (must be 'package' or 'adhoc'), got: %s",
      if (is.null(fn_kind)) "<none>" else format(fn_kind)))
  }
  if (identical(fn_kind, "adhoc")) {
    # Unit 1 implements no adhoc execution -- reject clearly, before any load,
    # rather than attempting to resolve a package/symbol that an adhoc envelope
    # will not carry.
    stop("batch_worker: fn_kind 'adhoc' not yet supported")
  }
  # fn_kind == "package" (the only implemented kind): package/symbol/hash are
  # load-deciding fields, required like id/runner_package.
  for (f in c("package", "symbol", "hash")) {
    if (!is_str1(meta[[f]])) {
      stop(sprintf("batch_worker: meta$%s missing or not a non-empty string", f))
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
package <- meta[["package"]]
runner <- meta[["runner_package"]]  # REQUIRED (checked above); no consumer fallback

# Load the RUNNER first, ALWAYS -- needed both to supply .batch_execute and to
# check the envelope's PROTOCOL number before the CONSUMER package loads (a
# version-skewed envelope must not get as far as loading potentially
# unrelated/incompatible consumer code). When runner == consumer AND dev_path
# was given, load_all(dev_path) loads both in one step (batchit testing
# itself); otherwise the runner is always the INSTALLED package -- dev_path
# only ever names the CONSUMER's source tree (see .batch_validate_dev_path()).
#
# KNOWN NARROW LIMITATION (documented, not fixed): in the runner==consumer +
# dev_path branch below, load_all(dev_path) necessarily runs BEFORE the
# protocol check a few lines down -- there is no way to read the DEV TREE's
# .BATCH_PROTOCOL without loading it (that's the one case the installed
# package's constant cannot be trusted for: the dev tree may have bumped the
# protocol relative to what's installed), and load_all() runs the package's
# own load hooks as a side effect of loading. So a version-skewed envelope in
# THIS one config can trigger the consumer's load hooks before being
# rejected. This only arises when batchit points dev_path at ITS OWN source
# tree (batchit testing itself); in every production config runner != package
# and the runner (always the INSTALLED package) loads first via
# requireNamespace() in the branch below, so protocol is checked before any
# consumer code -- dev_path only ever names the CONSUMER there, never the
# runner.
suppressPackageStartupMessages({
  if (!is.null(dev_path) && identical(runner, package)) {
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

# Now load the CONSUMER (unless it was already loaded above as the runner).
suppressPackageStartupMessages({
  if (!identical(runner, package)) {
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

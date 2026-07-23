# batch_envelope S3 wrapper (PUBLIC_API.md section 3.5, Stage 5 of the public
# API migration): the per-item wire envelope gains a `class = "batch_envelope"`
# attribute plus a `print` method. This must NOT change the wire contract --
# it stays a plain list a worker reads with bare `qs2::qs_read()` and
# structurally checks (`.batch_worker_check()` in inst/batch_worker.R) BEFORE
# any package loads. Both `.batch_worker_check()` and the in-package validator
# `.batch_check_envelope()` (R/batch.R) read every field with exact `[[`, never
# S3 dispatch, so the class attribute must be completely inert to both.
#
# Two things are tested here:
#   1. `.batch_input_envelope()` returns a classed, printable list, and the
#      class does not trip either validator.
#   2. A conformance battery: the STANDALONE `.batch_worker_check()` (extracted
#      from the real inst/batch_worker.R, not re-typed by hand) and
#      `.batch_check_envelope()` AGREE on every load-deciding field -- both
#      accept a valid package/adhoc envelope, and everything the worker check
#      rejects, the in-package check also rejects. (`.batch_check_envelope()`
#      legitimately rejects strictly more than the worker check does -- e.g.
#      unknown fields, output-path normalization -- so exact equivalence is
#      NOT asserted, only this one-directional agreement.)

dev_tree <- normalizePath(testthat::test_path("..", ".."), mustWork = FALSE)
have_tree <- file.exists(file.path(dev_tree, "DESCRIPTION")) &&
  file.exists(file.path(dev_tree, "inst", "batch_worker.R"))

PROTO <- batchit:::.BATCH_PROTOCOL

# --- .batch_input_envelope() / print.batch_envelope() -----------------------

test_that(".batch_input_envelope() returns a classed, printable batch_envelope -- unchanged on the wire", {
  tgt <- batchit::package_function("batchit", ".batch_fixture_echo")
  env <- batchit:::.batch_input_envelope(
    target = tgt, dev_path = NULL, runner = "batchit", id = "item-42",
    args = list(x = 1), fn_kind = "package", collect = TRUE)

  expect_true(inherits(env, "batch_envelope"))
  expect_true(is.list(env))  # a plain list underneath -- class is just an attribute
  expect_identical(names(env), c("protocol", "meta", "args"))

  # the class must be completely inert to the structural validator
  expect_true(batchit:::.batch_check_envelope(env))

  out <- capture.output(print(env))
  expect_true(any(grepl("item-42", out, fixed = TRUE)), info = paste(out, collapse = "\n"))
  expect_true(any(grepl("package", out, fixed = TRUE)), info = paste(out, collapse = "\n"))
})

test_that("print.batch_envelope() summarises an adhoc / declared-output-commit envelope", {
  env <- batchit:::.batch_input_envelope(
    target = NULL, dev_path = "~/some/dev/path", runner = "batchit",
    id = "item-7", args = list(x = 1), fn_kind = "adhoc",
    outputs = c(primary = "/tmp/out.qs2"), marker = "/tmp/.batchit__1",
    style = "return", attempt = "tok1", fn = function(x) x, nonce = "nonce-abc")

  expect_true(inherits(env, "batch_envelope"))
  out <- capture.output(print(env))
  txt <- paste(out, collapse = "\n")
  expect_true(grepl("item-7", txt, fixed = TRUE))
  expect_true(grepl("adhoc", txt, fixed = TRUE))
  expect_true(grepl("nonce-abc", txt, fixed = TRUE))
  expect_true(grepl("commit", txt, fixed = TRUE))
  expect_true(grepl("some/dev/path", txt, fixed = TRUE))
})

test_that("print.batch_envelope() is registered for S3 dispatch (not just callable by name)", {
  env <- batchit:::.batch_input_envelope(
    target = batchit::package_function("batchit", ".batch_fixture_echo"),
    dev_path = NULL, runner = "batchit", id = "1", args = list(x = 1),
    fn_kind = "package", collect = TRUE)
  # print() (generic dispatch), not print.batch_envelope() (direct call)
  expect_output(print(env), "batch_envelope")
})

# --- extract the STANDALONE .batch_worker_check() from inst/batch_worker.R --
#
# NOT source()'d: the full script calls commandArgs()/qs2::qs_read()/
# get(".batch_execute", ...)(env) and would try to actually run a worker.
# Parse the file into top-level expressions, find the ONE
# `.batch_worker_check <- function(...) {...}` assignment, and eval ONLY that
# expression into a fresh environment.

.extract_batch_worker_check <- function() {
  worker_path <- file.path(dev_tree, "inst", "batch_worker.R")
  exprs <- parse(worker_path)
  is_target <- vapply(seq_along(exprs), function(i) {
    e <- exprs[[i]]
    is.call(e) && length(e) == 3L && identical(e[[1L]], as.name("<-")) &&
      identical(e[[2L]], as.name(".batch_worker_check"))
  }, logical(1))
  if (sum(is_target) != 1L) {
    stop("test setup: expected exactly one `.batch_worker_check <- function(...)` ",
      "top-level assignment in inst/batch_worker.R, found ", sum(is_target))
  }
  worker_check_env <- new.env(parent = baseenv())
  eval(exprs[[which(is_target)]], envir = worker_check_env)
  fn <- get(".batch_worker_check", envir = worker_check_env, inherits = FALSE)
  stopifnot(is.function(fn))
  fn
}

test_that(".extract_batch_worker_check() pulls the REAL function out of inst/batch_worker.R, not a stub", {
  skip_if_not(have_tree, "package source tree not available")
  fn <- .extract_batch_worker_check()
  expect_true(is.function(fn))
  # the extracted body must be the real one -- checks the actual load-deciding
  # fields inst/batch_worker.R documents, not a hand-written double standing in
  # for it
  body_text <- paste(deparse(body(fn)), collapse = "\n")
  expect_true(grepl("runner_package", body_text, fixed = TRUE))
  expect_true(grepl("fn_kind", body_text, fixed = TRUE))
  expect_true(grepl("adhoc", body_text, fixed = TRUE))
  # and it actually behaves like the worker check: rejects a non-list outright
  expect_error(fn(42), "not a list")
})

# --- battery: both checks AGREE on the load-deciding fields ------------------

good_pkg_target <- batchit::package_function("batchit", ".batch_fixture_echo")

mk_good_pkg_envelope <- function() batchit:::.batch_input_envelope(
  target = good_pkg_target, dev_path = NULL, runner = "batchit", id = "1",
  args = list(x = 1), fn_kind = "package", collect = TRUE)

mk_good_adhoc_envelope <- function() batchit:::.batch_input_envelope(
  target = NULL, dev_path = NULL, runner = "batchit", id = "1",
  args = list(x = 1), fn_kind = "adhoc", collect = TRUE,
  fn = function(x) x, nonce = "tok")

# does calling `checker` on `env` raise an error?
rejects <- function(checker, env) {
  isTRUE(tryCatch({
    checker(env)
    FALSE
  }, error = function(e) TRUE))
}

test_that(".batch_worker_check() and .batch_check_envelope() both ACCEPT a valid package envelope (classed)", {
  skip_if_not(have_tree, "package source tree not available")
  worker_check <- .extract_batch_worker_check()
  env <- mk_good_pkg_envelope()
  expect_true(inherits(env, "batch_envelope"))
  expect_silent(worker_check(env))
  expect_true(batchit:::.batch_check_envelope(env))
})

test_that(".batch_worker_check() and .batch_check_envelope() both ACCEPT a valid adhoc envelope (classed)", {
  skip_if_not(have_tree, "package source tree not available")
  worker_check <- .extract_batch_worker_check()
  env <- mk_good_adhoc_envelope()
  expect_true(inherits(env, "batch_envelope"))
  expect_silent(worker_check(env))
  expect_true(batchit:::.batch_check_envelope(env))
})

test_that("everything .batch_worker_check() REJECTS, .batch_check_envelope() also rejects", {
  skip_if_not(have_tree, "package source tree not available")
  worker_check <- .extract_batch_worker_check()
  pkg_check <- batchit:::.batch_check_envelope

  cases <- list(
    "missing id" = { e <- mk_good_pkg_envelope(); e$meta$id <- NULL; e },
    "missing runner_package" = { e <- mk_good_pkg_envelope(); e$meta$runner_package <- NULL; e },
    "missing fn_kind" = { e <- mk_good_pkg_envelope(); e$meta$fn_kind <- NULL; e },
    "invalid fn_kind" = { e <- mk_good_pkg_envelope(); e$meta$fn_kind <- "bogus"; e },
    "package-kind missing package" = { e <- mk_good_pkg_envelope(); e$meta$package <- NULL; e },
    "package-kind missing symbol" = { e <- mk_good_pkg_envelope(); e$meta$symbol <- NULL; e },
    "package-kind missing hash" = { e <- mk_good_pkg_envelope(); e$meta$hash <- NULL; e },
    "adhoc-kind missing fn" = { e <- mk_good_adhoc_envelope(); e$meta$fn <- NULL; e }
  )

  for (case_name in names(cases)) {
    env <- cases[[case_name]]
    worker_rejects <- rejects(worker_check, env)
    expect_true(worker_rejects, info = paste("worker check should reject:", case_name))
    if (worker_rejects) {
      expect_true(rejects(pkg_check, env),
        info = paste("in-package check should also reject:", case_name))
    }
  }
})

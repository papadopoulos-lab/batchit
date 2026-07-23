# The `adhoc` fn_kind (Phase 6' Unit 3, see PHASE6_DESIGN.md sections 1, 2, 4,
# 5, 9.4): dispatch a bare closure VALUE, gated by a self-containedness LINT
# (codetools::findGlobals()) applied at BOTH ends, with a mandatory baseenv()
# rebase before serialization. Same real-subprocess discipline as the
# shape-A / declared-output-commit test files: end-to-end tests drive the ACTUAL
# inst/batch_worker.R through the REAL processx transport, never a mocked
# execution path.

dev_tree <- normalizePath(testthat::test_path("..", ".."), mustWork = FALSE)
have_tree <- file.exists(file.path(dev_tree, "DESCRIPTION")) &&
  file.exists(file.path(dev_tree, "inst", "batch_worker.R"))

PROTO <- batchit:::.BATCH_PROTOCOL

# Hand-crafts a raw adhoc envelope and feeds it DIRECTLY to the real worker
# script, bypassing run()/run_and_collect()'s own parent-side lint entirely -- the only way
# to prove the CHILD independently re-lints (design section 5: "applied at
# BOTH ends") rather than merely trusting whatever a frontend already checked.
.run_adhoc_worker_directly <- function(fn, args = list(), nonce = "tok-fixed",
                                         id = "1", collect = TRUE) {
  meta <- list(fn_kind = "adhoc", fn = fn, nonce = nonce, id = id,
    runner_package = "batchit", dev_path = dev_tree, collect = collect)
  env <- list(protocol = PROTO, meta = meta, args = args)
  worker <- file.path(dev_tree, "inst", "batch_worker.R")
  rscript <- file.path(R.home("bin"), "Rscript")
  inp <- withr::local_tempfile(fileext = ".qs2")
  outp <- withr::local_tempfile(fileext = ".qs2")
  errf <- withr::local_tempfile(fileext = ".txt")
  qs2::qs_save(env, inp)
  p <- processx::process$new(rscript, c("--vanilla", worker, inp, outp),
    env = c("current", R_LIBS = paste(.libPaths(), collapse = .Platform$path.sep)),
    stdout = "|", stderr = errf)
  p$wait(timeout = 30000)
  list(
    exit_status = p$get_exit_status(),
    wrote_output = file.exists(outp),
    result = if (file.exists(outp)) batchit:::.batch_read_envelope(outp) else NULL,
    stderr = paste(readLines(errf, warn = FALSE), collapse = "\n")
  )
}

# --- 1: run()/run_and_collect() run a self-contained closure ----------------

test_that("run_and_collect() runs a self-contained closure over items and returns per-item values", {
  skip_if_not(have_tree, "package source tree not available")
  r <- batchit::run_and_collect(
    function(x) x * 2,
    items = list(list(x = 1), list(x = 2), list(x = c(3, 4))),
    n_workers = 2L, dev_path = dev_tree
  )
  expect_identical(r, list(2, 4, c(6, 8)))
})

test_that("run(): drops values but still reports failures", {
  skip_if_not(have_tree, "package source tree not available")
  out <- batchit::run(
    function(x) x * 2,
    items = list(list(x = 1L)), n_workers = 1L, dev_path = dev_tree
  )
  expect_null(out)
  expect_error(
    batchit::run(
      function(x) stop("adhoc boom: ", x, call. = FALSE),
      items = list(list(x = "Y")), n_workers = 1L, dev_path = dev_tree
    ),
    "adhoc boom: Y"
  )
})

test_that("run_and_collect(): a clean closure using base R + an explicit pkg::fun() call passes the lint and runs", {
  skip_if_not(have_tree, "package source tree not available")
  r <- batchit::run_and_collect(
    function(x) stats::sd(x) + 1,
    items = list(list(x = c(1, 2, 3, 4, 5))),
    n_workers = 1L, dev_path = dev_tree
  )
  expect_equal(r[[1]], stats::sd(c(1, 2, 3, 4, 5)) + 1)
})

test_that("run(): validates every item's args against fn's own formals, not just the first", {
  expect_error(
    batchit::run(function(x) x, items = list(list(x = 1L), list()), n_workers = 1L),
    "not supplied"
  )
})

test_that("run()/run_and_collect(): an empty item list returns without dispatching", {
  expect_identical(batchit::run_and_collect(function(x) x, items = list(), n_workers = 1L),
    list())
  expect_null(batchit::run(function(x) x, items = list(), n_workers = 1L))
})

# --- 2: the self-containedness LINT, at BOTH ends ----------------------------

test_that(".batch_lint_adhoc_fn() rejects a closure with a free global VARIABLE, naming it", {
  df <- 99  # the free variable the closure below will reference
  bad <- function(x) x + df
  expect_error(batchit:::.batch_lint_adhoc_fn(bad, where = "parent"), "df")
})

test_that(".batch_lint_adhoc_fn() rejects a closure calling an unqualified non-base HELPER, naming it", {
  bad <- function(x) helper(x)
  expect_error(batchit:::.batch_lint_adhoc_fn(bad, where = "parent"), "helper")
})

test_that(".batch_lint_adhoc_fn() accepts a closure using only base R + pkg::fun()", {
  ok <- function(x) {
    y <- stats::sd(x)
    if (y > 0) y else 0
  }
  expect_true(batchit:::.batch_lint_adhoc_fn(ok, where = "parent"))
})

test_that("run() (the PARENT) rejects a closure with a free global variable, naming it, BEFORE any dispatch", {
  outer_val <- 7
  bad <- function(x) x + outer_val
  expect_error(
    batchit::run(bad, items = list(list(x = 1L)), n_workers = 1L),
    "outer_val"
  )
})

test_that("run() (the PARENT) rejects a closure calling an unqualified non-base helper, naming it", {
  bad <- function(x) not_a_real_helper(x)
  expect_error(
    batchit::run(bad, items = list(list(x = 1L)), n_workers = 1L),
    "not_a_real_helper"
  )
})

test_that("the REAL worker (the CHILD) independently re-lints and rejects a free-global closure, naming it -- proving the lint is NOT parent-only", {
  skip_if_not(have_tree, "package source tree not available")
  leaky_secret <- "should never reach the child"
  bad <- function() leaky_secret
  r <- .run_adhoc_worker_directly(bad, args = list())
  # .batch_check_envelope() runs inside .batch_execute()'s TOTAL tryCatch, so
  # an adhoc lint failure is a normal "status = error" result (exit 0), not a
  # worker crash -- exactly like the existing "unsupported style" child-side
  # test in the shape-A test file.
  expect_true(r$wrote_output)
  expect_identical(r$result$status, "error")
  expect_match(r$result$error$message, "leaky_secret")
})

test_that("the REAL worker (the CHILD) independently re-lints and rejects an unqualified-helper closure, naming it", {
  skip_if_not(have_tree, "package source tree not available")
  bad <- function() some_undeclared_helper()
  r <- .run_adhoc_worker_directly(bad, args = list())
  expect_true(r$wrote_output)
  expect_identical(r$result$status, "error")
  expect_match(r$result$error$message, "some_undeclared_helper")
})

test_that("the REAL worker (the CHILD) accepts and runs a clean self-contained closure", {
  skip_if_not(have_tree, "package source tree not available")
  r <- .run_adhoc_worker_directly(function(x) x * 3, args = list(x = 7))
  expect_true(r$wrote_output)
  expect_identical(r$result$status, "ok")
  expect_identical(r$result$value, 21)
})

# --- 3: `...` and non-function rejected --------------------------------------

test_that("run(): an adhoc closure taking `...` is rejected", {
  expect_error(
    batchit::run(function(x, ...) x, items = list(list(x = 1L)), n_workers = 1L),
    "\\.\\.\\."
  )
})

test_that("run(): a non-function `fn` is rejected", {
  expect_error(
    batchit::run(42, items = list(list(x = 1L)), n_workers = 1L),
    "must come from package_function\\(\\) or be a function"
  )
  expect_error(
    batchit::run("not a function either", items = list(list(x = 1L)), n_workers = 1L),
    "must come from package_function\\(\\) or be a function"
  )
})

test_that(".batch_lint_adhoc_fn() rejects a primitive", {
  expect_error(batchit:::.batch_lint_adhoc_fn(sum, where = "parent"), "primitive")
})

# --- 4: mandatory baseenv() rebase -- the enclosing environment is NOT carried

test_that(".batch_rebase_adhoc_closure() severs the closure's original environment", {
  e <- new.env()
  e$shared_secret <- "TOP SECRET"
  leaky <- function() get("shared_secret", envir = environment())
  environment(leaky) <- e
  expect_identical(leaky(), "TOP SECRET")  # precondition: works BEFORE rebase

  rebased <- batchit:::.batch_rebase_adhoc_closure(leaky)
  expect_true(identical(environment(rebased), baseenv()))
  expect_error(rebased(), "shared_secret")  # object 'shared_secret' not found
})

test_that("run_and_collect(): a closure that passes the lint via get()/environment() (a documented blind spot) still FAILS at runtime, because the rebase severed its enclosing env -- proving the env is NOT carried across the real subprocess boundary", {
  skip_if_not(have_tree, "package source tree not available")
  e <- new.env()
  e$shared_secret <- "TOP SECRET VALUE"
  leaky <- function() get("shared_secret", envir = environment())
  environment(leaky) <- e

  # get()/environment() are both base -- codetools does not flag this as a
  # free global, so the LINT alone would accept it (a documented blind spot,
  # PHASE6_DESIGN.md section 5). It still fails at RUN time in the real child
  # subprocess, because .batch_rebase_adhoc_closure() rebased it onto
  # baseenv() before it was ever serialized.
  expect_true(batchit:::.batch_lint_adhoc_fn(leaky, where = "parent"))
  expect_error(
    batchit::run_and_collect(leaky, items = list(list()), n_workers = 1L, dev_path = dev_tree),
    "shared_secret"
  )
})

# --- 5: run_and_write_files_atomically() with a bare closure (adhoc) + declared outputs ---------

test_that("run_and_write_files_atomically() with a bare closure (adhoc) commits every declared output + a marker, through the real worker", {
  skip_if_not(have_tree, "package source tree not available")
  dir <- withr::local_tempdir()
  out1 <- file.path(dir, "a_primary.qs2")
  out2 <- file.path(dir, "a_secondary.qs2")

  r <- batchit::run_and_write_files_atomically(
    function(x) list(primary = x, secondary = x * 10),
    items = list(only = list(x = 21L)),
    outputs = list(only = c(primary = out1, secondary = out2)),
    n_workers = 1L, dev_path = dev_tree
  )

  expect_true(file.exists(out1))
  expect_true(file.exists(out2))
  expect_identical(qs2::qs_read(out1), 21L)
  expect_identical(qs2::qs_read(out2), 210)

  marker <- file.path(dir, ".batchit__only")
  expect_true(file.exists(marker))
  rec <- qs2::qs_read(marker)
  expect_identical(rec$protocol, PROTO)
  expect_setequal(names(rec$committed), c("primary", "secondary"))

  expect_identical(names(r), "only")
  expect_setequal(names(r$only$committed), c("primary", "secondary"))
  expect_true(is.character(r$only$attempt) && nzchar(r$only$attempt))
})

test_that("run_and_write_files_atomically() with a bare closure (adhoc) + style = \"staged_writer\" commits via where_to_write_output()", {
  skip_if_not(have_tree, "package source tree not available")
  dir <- withr::local_tempdir()
  out1 <- file.path(dir, "sw_primary.qs2")
  out2 <- file.path(dir, "sw_secondary.qs2")

  r <- batchit::run_and_write_files_atomically(
    function(x) {
      qs2::qs_save(x, batchit::where_to_write_output("primary"))
      qs2::qs_save(x * 10, batchit::where_to_write_output("secondary"))
      invisible(NULL)
    },
    items = list(only = list(x = 5L)),
    outputs = list(only = c(primary = out1, secondary = out2)),
    style = "staged_writer",
    n_workers = 1L, dev_path = dev_tree
  )

  expect_true(file.exists(out1))
  expect_true(file.exists(out2))
  expect_identical(qs2::qs_read(out1), 5L)
  expect_identical(qs2::qs_read(out2), 50)
  expect_setequal(names(r$only$committed), c("primary", "secondary"))
})

test_that("run_and_write_files_atomically() with a bare closure (adhoc): a bad closure is rejected at DISPATCH, before any worker runs", {
  bad <- function(x) x + some_outer_free_variable
  expect_error(
    batchit::run_and_write_files_atomically(bad, items = list(list(x = 1L)),
      outputs = list(c(primary = "/tmp/whatever_a.qs2")),
      n_workers = 1L),
    "some_outer_free_variable"
  )
})

test_that("run_and_write_files_atomically(): `fn` that is neither a package_function() nor a function is rejected", {
  expect_error(
    batchit::run_and_write_files_atomically("not a target or a function",
      items = list(list(x = 1L)), outputs = list(c(primary = "/tmp/x.qs2")),
      n_workers = 1L),
    "package_function\\(\\)|bare closure"
  )
})

# --- 6: adhoc result identity -- wrong id/nonce rejected ---------------------

test_that(".batch_inspect_result() accepts a well-formed adhoc result and rejects a WRONG nonce", {
  good <- list(protocol = PROTO, id = "1", status = "ok", value = 42,
    warnings = character(),
    target = list(fn_kind = "adhoc", nonce = "nonce-abc"))
  expect_true(batchit:::.batch_inspect_result(good, "1", target = NULL,
    expected_nonce = "nonce-abc")$ok)

  wrong_nonce <- good
  wrong_nonce$target$nonce <- "nonce-DIFFERENT"
  r1 <- batchit:::.batch_inspect_result(wrong_nonce, "1", target = NULL,
    expected_nonce = "nonce-abc")
  expect_false(r1$ok)
  expect_match(r1$reason, "nonce")

  not_adhoc <- good
  not_adhoc$target$fn_kind <- "package"
  r2 <- batchit:::.batch_inspect_result(not_adhoc, "1", target = NULL,
    expected_nonce = "nonce-abc")
  expect_false(r2$ok)
})

test_that(".batch_inspect_result() rejects an adhoc result claiming the WRONG id, even with a matching nonce", {
  # id is checked BEFORE the target/nonce identity block, for every fn_kind.
  wrong_id <- list(protocol = PROTO, id = "OTHER-ITEM", status = "ok", value = 42,
    warnings = character(),
    target = list(fn_kind = "adhoc", nonce = "nonce-abc"))
  r <- batchit:::.batch_inspect_result(wrong_id, "1", target = NULL,
    expected_nonce = "nonce-abc")
  expect_false(r$ok)
  expect_match(r$reason, "id mismatch")
})

test_that("run()/run_and_collect(): the REAL worker's echoed nonce is verified by the parent inspector (a tampered nonce is rejected)", {
  skip_if_not(have_tree, "package source tree not available")
  r <- .run_adhoc_worker_directly(function(x) x, args = list(x = 1L), nonce = "the-real-nonce")
  expect_identical(r$result$status, "ok")
  expect_identical(r$result$target$fn_kind, "adhoc")
  expect_identical(r$result$target$nonce, "the-real-nonce")

  # the parent inspector, given the CORRECT nonce, accepts it...
  insp_ok <- batchit:::.batch_inspect_result(r$result, "1", target = NULL,
    expected_nonce = "the-real-nonce")
  expect_true(insp_ok$ok)
  # ...but rejects the SAME result if the dispatcher expected a DIFFERENT one
  # (e.g. a stale/substituted result for this item's slot).
  insp_bad <- batchit:::.batch_inspect_result(r$result, "1", target = NULL,
    expected_nonce = "a-different-nonce-entirely")
  expect_false(insp_bad$ok)
  expect_match(insp_bad$reason, "nonce")
})

# --- envelope-level structural checks (adhoc branch) -------------------------

test_that(".batch_check_envelope() requires meta$fn and meta$nonce for fn_kind = \"adhoc\", and forbids package/symbol/hash", {
  base_meta <- list(id = "1", runner_package = "batchit", fn_kind = "adhoc",
    collect = TRUE)
  ok_fn <- function(x) x
  good <- list(protocol = PROTO, meta = c(base_meta, list(fn = ok_fn, nonce = "tok")),
    args = list())
  expect_true(batchit:::.batch_check_envelope(good))

  no_fn <- good; no_fn$meta$fn <- NULL
  expect_error(batchit:::.batch_check_envelope(no_fn), "not self-contained|function")

  no_nonce <- good; no_nonce$meta$nonce <- NULL
  expect_error(batchit:::.batch_check_envelope(no_nonce), "nonce")

  with_pkg <- good; with_pkg$meta$package <- "batchit"
  expect_error(batchit:::.batch_check_envelope(with_pkg), "forbidden")
})

test_that(".batch_check_envelope() forbids meta$fn/meta$nonce for fn_kind = \"package\"", {
  base_meta <- list(id = "1", runner_package = "batchit", fn_kind = "package",
    package = "batchit", symbol = "s", hash = "h", collect = TRUE)
  good <- list(protocol = PROTO, meta = base_meta, args = list())
  expect_true(batchit:::.batch_check_envelope(good))

  with_fn <- good; with_fn$meta$fn <- function(x) x
  expect_error(batchit:::.batch_check_envelope(with_fn), "forbidden")

  with_nonce <- good; with_nonce$meta$nonce <- "tok"
  expect_error(batchit:::.batch_check_envelope(with_nonce), "forbidden")
})

# --- the CHILD's defensive rebase is load-bearing ----------------------------

test_that("the CHILD independently rebases an adhoc closure's env (defensive rebase is load-bearing, not just the parent's)", {
  skip_if_not(have_tree, "package source tree not available")
  # This closure PASSES the lint -- `get`/`environment` are base and "secret"
  # is a string literal, not a free global -- but at RUNTIME it reads a binding
  # from its enclosing environment. .run_adhoc_worker_directly() bypasses the
  # frontend's parent-side rebase, so ONLY the child's own defensive rebase
  # (in .batch_execute()) can sever that env. Rebased to baseenv(), the lookup
  # fails; without the child rebase the carried env would return 42. This is
  # what makes the child rebase -- not merely the parent's -- load-bearing.
  secret_fn <- local({
    secret <- 42L
    function() get("secret", environment())
  })
  res <- .run_adhoc_worker_directly(secret_fn)
  expect_identical(res$result$status, "error")
  expect_match(res$result$error$message, "secret", fixed = TRUE)
})

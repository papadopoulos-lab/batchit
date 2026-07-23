# THE runner != consumer proof -- the boundary swereg-inside-swereg never
# exercised, because there the runner and the consumer were the same package.
#
# Here the RUNNER is batchit and the CONSUMER is a throwaway package `seamtest`,
# and the worker/daemon loads BOTH from INSTALLED libraries (dev_path = NULL).
# This is the extraction's production-boundary equivalent: it must drive REAL
# subprocesses, so it builds and installs a real consumer package, then dispatches
# through the real inst/batch_worker.R (shape A) and a real mirai daemon (shape B).
#
# Why an install is required: with dev_path = NULL the worker/daemon loads the
# consumer via requireNamespace() and the runner (batchit) via requireNamespace()
# too. So seamtest must be installed, and -- when these tests run against a SOURCE
# tree (pkgload / devtools::load_all, where batchit is not installed anywhere) --
# batchit must be installed into the same temp library, so the child can load it.
# Under R CMD check batchit is already installed, so only seamtest is built.

skip_on_cran()  # this file installs packages; opt-in only (NOT_CRAN)

dev_tree <- normalizePath(testthat::test_path("..", ".."), mustWork = FALSE)
running_from_source <- file.exists(file.path(dev_tree, "DESCRIPTION")) &&
  file.exists(file.path(dev_tree, "inst", "batch_worker.R"))

.seam_install <- function(srcdir, lib) {
  rbin <- file.path(R.home("bin"), "R")
  out <- suppressWarnings(system2(
    rbin,
    c("CMD", "INSTALL", "--no-multiarch", "--no-docs", "--no-byte-compile",
      paste0("--library=", lib), srcdir),
    stdout = TRUE, stderr = TRUE))
  status <- attr(out, "status")
  if (!is.null(status) && status != 0L) {
    stop("R CMD INSTALL failed for ", srcdir, ":\n", paste(out, collapse = "\n"))
  }
  invisible(TRUE)
}

.seam_write_consumer <- function(dir) {
  dir.create(file.path(dir, "R"), recursive = TRUE, showWarnings = FALSE)
  writeLines(c(
    "Package: seamtest",
    "Title: Throwaway Consumer for the batchit Seam Test",
    "Version: 0.0.1",
    "Authors@R: person('Richard', 'White', email = 'hello@rwhite.no', role = c('aut','cre'))",
    "Maintainer: Richard Aubrey White <hello@rwhite.no>",
    "Description: A minimal consumer package used only to prove the batchit",
    "    runner != consumer boundary. Not for distribution.",
    "License: MIT + file LICENSE",
    "Encoding: UTF-8"
  ), file.path(dir, "DESCRIPTION"))
  writeLines(c("YEAR: 2026", "COPYRIGHT HOLDER: Richard Aubrey White"),
    file.path(dir, "LICENSE"))
  writeLines(c("export(seam_echo)", "export(seam_boom)", "export(seam_task_ok)"),
    file.path(dir, "NAMESPACE"))
  writeLines(c(
    "seam_echo <- function(x) x",
    "seam_boom <- function(message) stop(message, call. = FALSE)",
    "seam_task_ok <- function(x) list(primary = x)"
  ), file.path(dir, "R", "seam.R"))
  invisible(dir)
}

# --- file-level setup: build the consumer, install, extend the library path ---

seam_lib <- tempfile("seam_lib_")
dir.create(seam_lib)
withr::defer(unlink(seam_lib, recursive = TRUE, force = TRUE), teardown_env())

seam_src <- tempfile("seamtest_src_")
.seam_write_consumer(seam_src)

seam_ready <- tryCatch(
  {
    .seam_install(seam_src, seam_lib)
    # Under a source tree, the child cannot requireNamespace("batchit") unless an
    # installed batchit is on its library path -- install THIS source into the
    # same temp lib so the runner the child loads is the code under test.
    if (running_from_source) .seam_install(dev_tree, seam_lib)
    TRUE
  },
  error = function(e) {
    message("seam test setup failed: ", conditionMessage(e))
    FALSE
  }
)

if (seam_ready) {
  old_libpaths <- .libPaths()
  .libPaths(c(seam_lib, old_libpaths))
  withr::defer(.libPaths(old_libpaths), teardown_env())
  # Export the library path so the fresh Rscript worker (shape A) AND the mirai
  # daemon (shape B) both inherit it. run()/run_and_collect() set R_LIBS from .libPaths()
  # itself, but the mirai daemon relies on the inherited environment.
  old_rlibs <- Sys.getenv("R_LIBS", unset = NA_character_)
  Sys.setenv(R_LIBS = paste(.libPaths(), collapse = .Platform$path.sep))
  withr::defer({
    if (is.na(old_rlibs)) Sys.unsetenv("R_LIBS") else Sys.setenv(R_LIBS = old_rlibs)
  }, teardown_env())
}

# --- (1) shape A: run_and_collect() through the REAL worker, both packages installed ---

test_that("run_and_collect(): runner=batchit + consumer=seamtest, both from installed libs", {
  skip_if_not(seam_ready, "could not build/install the seam packages")
  tgt <- batchit::package_function("seamtest", "seam_echo")
  # the target is the CONSUMER's -- not batchit's
  expect_identical(tgt$package, "seamtest")
  expect_identical(tgt$formal_names, "x")

  # named items -> the names are the item ids (used for failure reporting); the
  # returned value list is in item order and UNNAMED (run_and_collect()'s contract --
  # only stream_from_parent_and_write_files_atomically() names its results by id).
  r <- batchit::run_and_collect(
    tgt,
    items = list(a = list(x = "hello-seam"), b = list(x = 42L)),
    n_workers = 2L, dev_path = NULL   # <-- both packages come from installed libs
  )
  expect_identical(r, list("hello-seam", 42L))
})

# --- (2) shape A: a consumer failure returns a structured error naming the item -

test_that("run_and_collect(): a consumer error comes back structured and names the item", {
  skip_if_not(seam_ready, "could not build/install the seam packages")
  tgt <- batchit::package_function("seamtest", "seam_boom")
  # error names the failing item id ('the_item') AND carries the consumer message
  expect_error(
    batchit::run_and_collect(
      tgt, items = list(the_item = list(message = "seam-detonate")),
      n_workers = 1L, dev_path = NULL),
    "the_item")
  expect_error(
    batchit::run_and_collect(
      tgt, items = list(the_item = list(message = "seam-detonate")),
      n_workers = 1L, dev_path = NULL),
    "seam-detonate")
})

# --- (3) shape B: stream_from_parent_and_write_files_atomically() through a REAL mirai daemon ---

test_that("stream_from_parent_and_write_files_atomically(): runner=batchit + consumer=seamtest through a real daemon", {
  skip_if_not_installed("mirai")
  skip_if_not(seam_ready, "could not build/install the seam packages")
  tgt <- batchit::package_function("seamtest", "seam_task_ok")
  dir <- withr::local_tempdir()
  outs <- list(
    p = c(primary = file.path(dir, "p.qs2")),
    q = c(primary = file.path(dir, "q.qs2")),
    r = c(primary = file.path(dir, "r.qs2"))
  )
  res <- batchit::stream_from_parent_and_write_files_atomically(
    tgt,
    ids = c("p", "q", "r"),
    producer = function(id) list(x = paste0("slice-", id)),
    outputs = outs,
    n_workers = 2L, dev_path = NULL   # <-- daemon loads both from installed libs
  )
  expect_identical(names(res), c("p", "q", "r"))
  expect_identical(qs2::qs_read(outs[["p"]][["primary"]]), "slice-p")
  expect_identical(qs2::qs_read(outs[["q"]][["primary"]]), "slice-q")
  expect_identical(qs2::qs_read(outs[["r"]][["primary"]]), "slice-r")
})

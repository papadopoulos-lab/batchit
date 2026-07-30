# write_qs2_atomically(): the standalone atomic qs2 writer. Independent of the
# run_and_write_files_atomically() commit engine -- its temp carries no
# dispatch attempt token, and it must never emit that engine's "batch commit:"
# error prefix.

test_that("write_qs2_atomically() round-trips and leaves no litter", {
  dir <- withr::local_tempdir()
  path <- file.path(dir, "x.qs2")

  write_qs2_atomically(list(a = 1L, b = "two"), path)

  expect_true(file.exists(path))
  expect_identical(qs2::qs_read(path), list(a = 1L, b = "two"))
  expect_identical(list.files(dir, all.files = TRUE, no.. = TRUE), "x.qs2")
})

test_that("a failed rename leaves the OLD value at the SAME destination", {
  dir <- withr::local_tempdir()
  path <- file.path(dir, "x.qs2")
  qs2::qs_save(list(old = TRUE), path)

  # Force the rename to fail against THIS path, so the assertion is about the
  # destination that already holds a value. A filesystem-level failure that
  # keeps a readable old value at the same path is not available here: the two
  # real ways to make file.rename() fail (destination is a non-empty
  # directory; destination directory is not writable) either replace the value
  # with a directory or also block the temp cleanup. See the extra
  # filesystem-real check below for the non-empty-directory case.
  testthat::local_mocked_bindings(file.rename = function(from, to) FALSE, .package = "base")

  expect_error(write_qs2_atomically(list(new = TRUE), path), "could not rename")

  expect_identical(qs2::qs_read(path), list(old = TRUE))
  expect_identical(list.files(dir, all.files = TRUE, no.. = TRUE), "x.qs2")
})

test_that("a rename failure against a real non-empty directory preserves it", {
  dir <- withr::local_tempdir()
  path <- file.path(dir, "x.qs2")
  dir.create(path)
  file.create(file.path(path, "occupant.txt"))

  # `file.rename()`'s own warning propagates -- it is not swallowed.
  expect_warning(
    expect_error(write_qs2_atomically(list(new = TRUE), path), "could not rename"),
    "Is a directory"
  )

  expect_true(dir.exists(path))
  expect_identical(list.files(path), "occupant.txt")
  expect_identical(list.files(dir, all.files = TRUE, no.. = TRUE), "x.qs2")
})

test_that("the rename error names write_qs2_atomically(), never batch commit", {
  dir <- withr::local_tempdir()
  path <- file.path(dir, "x.qs2")
  testthat::local_mocked_bindings(file.rename = function(from, to) FALSE, .package = "base")

  msg <- tryCatch(
    {
      write_qs2_atomically(1:3, path)
      NA_character_
    },
    error = function(e) conditionMessage(e)
  )

  expect_true(grepl("could not rename", msg, fixed = TRUE))
  expect_true(grepl("write_qs2_atomically()", msg, fixed = TRUE))
  expect_false(grepl("batch commit", msg, fixed = TRUE))
})

test_that("the temp is created beside the destination, with no attempt token", {
  dir <- withr::local_tempdir()
  path <- file.path(dir, "x.qs2")
  seen <- NULL

  testthat::local_mocked_bindings(
    qs_save = function(object, file, ...) {
      seen <<- file
      writeLines("payload", file)
      invisible(TRUE)
    },
    .package = "qs2"
  )

  write_qs2_atomically(1:3, path)

  expect_false(is.null(seen))
  expect_identical(
    normalizePath(dirname(seen)),
    normalizePath(dir)
  )
  # `<basename(path)>.tmp<random>` and nothing else: no `.<attempt>.` segment,
  # so `.batch_sweep_task_temps()`'s `\.<attempt>\.(tmp|stage)` can never match
  # it.
  expect_match(basename(seen), "^x\\.qs2\\.tmp[A-Za-z0-9]+$")
})

test_that("write_qs2_atomically() returns the supplied path invisibly", {
  dir <- withr::local_tempdir()
  path <- file.path(dir, "x.qs2")

  res <- withVisible(write_qs2_atomically(1:3, path))

  expect_identical(res$value, path)
  expect_false(res$visible)
})

test_that("write_qs2_atomically() is exported from batchit", {
  expect_true("write_qs2_atomically" %in% getNamespaceExports("batchit"))

  dir <- withr::local_tempdir()
  path <- file.path(dir, "x.qs2")
  batchit::write_qs2_atomically(1:3, path)
  expect_identical(qs2::qs_read(path), 1:3)
})

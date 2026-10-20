# The parent derives each output path and the marker. The child re-validates
# both with identical(). Both sides MUST normalise with
# .batch_normalize_parent(), so both produce the same string.
#
# On Windows, dirname() returns `/` separators, and normalizePath() returns `\`
# by default. A default call on one side gave a string the other side
# rejected. On Linux, normalizePath() ignores winslash, so these tests mock it
# to honour winslash as it does on Windows. On Windows the mock changes nothing.

# The file captures base::normalizePath() before any mock, so that the mock
# cannot call itself.
real_normalize_path <- base::normalizePath

windows_normalize_path <- function(path, winslash = "\\", mustWork = NA) {
  out <- real_normalize_path(path, winslash = winslash, mustWork = mustWork)
  return(gsub("/", winslash, out, fixed = TRUE))
}

# The parent-side derivation that run_and_write_files_atomically() and
# stream_from_parent_and_write_files_atomically() run for each item.
derive_item <- function(outputs, id) {
  norm <- batchit:::.batch_validate_output_paths(outputs, id)
  marker <- batchit:::.batch_task_marker_path(norm, id)
  return(list(outputs = norm, marker = marker))
}

envelope_for <- function(derived, id) {
  return(batchit:::.batch_input_envelope(
    target = batchit::package_function("batchit", ".batch_fixture_echo"),
    dev_path = NULL,
    runner = "batchit",
    id = id,
    args = list(),
    outputs = derived$outputs,
    marker = derived$marker,
    style = "return",
    attempt = "tok"
  ))
}

test_that("the parent-derived outputs and marker pass the child's re-validation with Windows separators", {
  root <- real_normalize_path(withr::local_tempdir(), winslash = "/")
  dir_a <- file.path(root, "a")
  dir_b <- file.path(root, "b")
  dir.create(dir_a)
  dir.create(dir_b)
  id <- "00001_persons"
  outputs <- c(
    second = file.path(dir_b, "persons.qs2"),
    first = file.path(dir_a, "persons.qs2")
  )

  testthat::local_mocked_bindings(
    normalizePath = windows_normalize_path,
    .package = "base"
  )
  # The mock is live: a call with the default winslash gives `\` separators.
  expect_match(normalizePath(root), "\\", fixed = TRUE)

  derived <- derive_item(outputs, id)

  # The parent keeps `/` separators, so the strings are the input paths.
  expect_identical(derived$outputs, outputs)
  expect_identical(derived$marker, file.path(dir_a, paste0(".batchit__", id)))
  expect_identical(
    batchit:::.batch_normalize_parent(derived$marker),
    derived$marker
  )
  # The child accepts what the parent derived.
  expect_true(batchit:::.batch_check_envelope(envelope_for(derived, id)))
})

test_that(".batch_normalize_parent() resolves the parent and keeps a symlinked leaf unresolved", {
  root <- real_normalize_path(withr::local_tempdir(), winslash = "/")
  real <- file.path(root, "real.qs2")
  file.create(real)
  alias <- file.path(root, "alias.qs2")
  ok <- suppressWarnings(file.symlink(real, alias))
  skip_if_not(
    isTRUE(ok) && nzchar(suppressWarnings(Sys.readlink(alias))),
    "symlinks unsupported here"
  )
  sub <- file.path(root, "sub")
  dir.create(sub)

  expect_identical(batchit:::.batch_normalize_parent(alias), alias)
  expect_identical(
    batchit:::.batch_normalize_parent(file.path(sub, "..", "alias.qs2")),
    alias
  )
})

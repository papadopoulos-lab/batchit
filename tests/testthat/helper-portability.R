# Two helpers that let one test suite run on Linux and on Windows.
#
# The R-hub Windows run on 2026-10-20 failed 162 expectations. Two causes made
# 159 of them:
#
#   * 156 came from generated shell scripts and bash stubs. The Windows runner
#     has no bash that runs them.
#   * 3 came from paths. Windows has no "/tmp", and a raw `tempdir()` path
#     there holds `\` separators that the package rejects.

# Skip the rest of a block that runs a shell script under bash.
#
# Call it immediately before the first bash run, so that every expectation
# above it still runs on Windows. A block that only reads the generated text
# MUST NOT call it.
#
# The test is the operating system, not the presence of a `bash` binary. A
# Linux host without bash is a broken host, and its tests MUST fail.
skip_without_bash <- function() {
  testthat::skip_if(
    .Platform$OS.type == "windows",
    paste(
      "runs a generated shell script or a bash stub,",
      "and Windows has no bash that runs it"
    )
  )
}

# A temporary directory, in the form the package gives an output path.
#
# `.batch_normalize_parent()` normalises with `winslash = "/"`. On Windows a
# raw `withr::local_tempdir()` path holds `\`, so the child-side check
# rejects it as not normalised. On Linux the result equals the raw path.
#
# The directory is deleted when the frame `envir` exits.
local_test_dir <- function(envir = parent.frame()) {
  dir <- withr::local_tempdir(.local_envir = envir)
  return(normalizePath(dir, winslash = "/", mustWork = TRUE))
}

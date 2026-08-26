# The release invariant: DESCRIPTION's Version and the newest NEWS.md heading
# name the same release.
#
# Both readers here run against the package, not against the source tree.
# `packageVersion()` reads the loaded DESCRIPTION, and `system.file()` finds the
# installed NEWS.md. So no `skip_if_not()` guards this file. `R CMD check` runs
# the tests from a built tarball, where a source-tree path does not exist. A
# skipped test reports green there, and stays red on a developer machine.
#
# No assertion below names a version literal. A literal is green for one release
# and red at every bump after it.

news_path <- function() {
  system.file("NEWS.md", package = "batchit")
}

# Every release heading in NEWS.md, in file order.
news_versions <- function(path) {
  heads <- grep("^# batchit ", readLines(path, warn = FALSE), value = TRUE)
  package_version(sub("^# batchit ", "", heads))
}

test_that("the package ships NEWS.md, so the release check can read it", {
  path <- news_path()
  expect_true(nzchar(path))
  expect_true(file.exists(path))
  expect_gt(length(news_versions(path)), 0L)
})

test_that("DESCRIPTION's Version and the newest NEWS.md heading agree", {
  newest <- news_versions(news_path())[1]
  expect_identical(
    as.character(packageVersion("batchit")),
    as.character(newest)
  )
})

test_that("NEWS.md lists its releases newest first", {
  # A release that lands out of order gives two trees one ordering. That is the
  # defect CalVer exists to prevent, and nothing else in the suite sees it.
  versions <- news_versions(news_path())
  expect_true(all(versions[-length(versions)] > versions[-1]))
})

# Opt-in consumer skip -- batch_record()/batch_prior()/batch_skip() (Phase 6'
# Unit 4; see PHASE6_DESIGN.md sections 7, 9.2, 9.3). Same real-subprocess
# discipline as test-batch_task.R: these drive the ACTUAL inst/batch_worker.R
# through the real processx transport and the real .batch_commit_task()/
# .batch_commit_task_skip() paths -- never a mocked commit path.

dev_tree <- normalizePath(testthat::test_path("..", ".."), mustWork = FALSE)
have_tree <- file.exists(file.path(dev_tree, "DESCRIPTION")) &&
  file.exists(file.path(dev_tree, "inst", "batch_worker.R"))

mk <- function(sym) batchit::package_function("batchit", sym)
PROTO <- batchit:::.BATCH_PROTOCOL

named_list <- function(id, value) {
  x <- list(value)
  names(x) <- id
  x
}

# --- 1: batch_record() lands in the marker; last call wins ------------------

test_that("batch_record(details) lands in the item's new marker, through the real worker", {
  skip_if_not(have_tree, "package source tree not available")
  dir <- withr::local_tempdir()
  out1 <- file.path(dir, "rec_primary.qs2")
  out2 <- file.path(dir, "rec_secondary.qs2")

  batchit::batch_task(
    mk(".batch_fixture_task_report_prior"),
    items = named_list("only", list(x = 42L)),
    outputs = named_list("only", c(primary = out1, secondary = out2)),
    n_workers = 1L, dev_path = dev_tree
  )

  marker <- file.path(dir, ".batchit__only")
  expect_true(file.exists(marker))
  rec <- qs2::qs_read(marker)
  expect_identical(rec$details, list(computed_from = 42L))
})

test_that("batch_record() called TWICE -> the LAST call wins (design section 9.3)", {
  skip_if_not(have_tree, "package source tree not available")
  dir <- withr::local_tempdir()
  out1 <- file.path(dir, "twice_primary.qs2")
  out2 <- file.path(dir, "twice_secondary.qs2")

  batchit::batch_task(
    mk(".batch_fixture_task_record_twice"),
    items = named_list("only", list(x = 7L)),
    outputs = named_list("only", c(primary = out1, secondary = out2)),
    n_workers = 1L, dev_path = dev_tree
  )

  marker <- file.path(dir, ".batchit__only")
  rec <- qs2::qs_read(marker)
  expect_identical(rec$details, list(which = "second", x = 7L))
})

# --- 2: batch_prior() -- NULL on a first run, prior details on a second -----

test_that("batch_prior() returns NULL on a first run (no prior marker); a SECOND run of the same item returns the first run's details", {
  skip_if_not(have_tree, "package source tree not available")
  dir <- withr::local_tempdir()
  id <- "prior_seq"
  out1 <- file.path(dir, paste0(id, "_primary.qs2"))
  out2 <- file.path(dir, paste0(id, "_secondary.qs2"))

  r1 <- batchit::batch_task(
    mk(".batch_fixture_task_report_prior"),
    items = named_list(id, list(x = 5L)),
    outputs = named_list(id, c(primary = out1, secondary = out2)),
    n_workers = 1L, dev_path = dev_tree
  )
  # "primary" is what the TARGET itself observed batch_prior() to be --
  # NULL, since there was no marker before this run.
  expect_null(qs2::qs_read(out1))

  r2 <- batchit::batch_task(
    mk(".batch_fixture_task_report_prior"),
    items = named_list(id, list(x = 9L)),
    outputs = named_list(id, c(primary = out1, secondary = out2)),
    n_workers = 1L, dev_path = dev_tree
  )
  # this run's target saw the FIRST run's batch_record() details.
  expect_identical(qs2::qs_read(out1), list(computed_from = 5L))
  expect_false(r1[[id]]$skipped)
  expect_false(r2[[id]]$skipped)
})

test_that("a malformed/foreign marker at the derived path -> batch_prior() returns NULL, not garbage", {
  skip_if_not(have_tree, "package source tree not available")
  dir <- withr::local_tempdir()
  id <- "prior_garbage"
  out1 <- file.path(dir, paste0(id, "_primary.qs2"))
  out2 <- file.path(dir, paste0(id, "_secondary.qs2"))
  marker <- file.path(dir, paste0(".batchit__", id))

  # not even a valid qs2 payload
  writeLines("not a real marker, and not even qs2", marker)

  r <- batchit::batch_task(
    mk(".batch_fixture_task_report_prior"),
    items = named_list(id, list(x = 3L)),
    outputs = named_list(id, c(primary = out1, secondary = out2)),
    n_workers = 1L, dev_path = dev_tree
  )
  expect_null(qs2::qs_read(out1))
  expect_false(r[[id]]$skipped)
  # the garbage marker really was overwritten by the CHILD's own commit.
  rec <- qs2::qs_read(marker)
  expect_identical(rec$protocol, PROTO)
})

test_that("a WELL-FORMED marker for a DIFFERENT output map (stale/foreign shape) -> batch_prior() returns NULL", {
  # A marker that decodes fine and even has the right FIELD NAMES, but whose
  # `committed` map does not match THIS item's declared outputs, must not be
  # accepted as this item's own prior -- proven-red without the structural
  # verify: batch_prior() would hand back a details value that was never
  # actually vouched for these output paths.
  skip_if_not(have_tree, "package source tree not available")
  dir <- withr::local_tempdir()
  id <- "prior_wrong_shape"
  out1 <- file.path(dir, paste0(id, "_primary.qs2"))
  out2 <- file.path(dir, paste0(id, "_secondary.qs2"))
  marker <- file.path(dir, paste0(".batchit__", id))

  fake_record <- list(protocol = PROTO, attempt = "some-old-token",
    committed = c(primary = "/tmp/totally_different_primary.qs2",
      secondary = "/tmp/totally_different_secondary.qs2"),
    details = list(computed_from = 999L))
  qs2::qs_save(fake_record, marker)

  r <- batchit::batch_task(
    mk(".batch_fixture_task_report_prior"),
    items = named_list(id, list(x = 3L)),
    outputs = named_list(id, c(primary = out1, secondary = out2)),
    n_workers = 1L, dev_path = dev_tree
  )
  expect_null(qs2::qs_read(out1))
  expect_false(r[[id]]$skipped)
})

# --- 3: batch_skip() -- a second run reuses the prior outputs ---------------

test_that("batch_skip(): a second run whose target inspects batch_prior() and returns batch_skip() -> the prior outputs are PRESERVED, not recomputed; no new marker; item recorded done", {
  skip_if_not(have_tree, "package source tree not available")
  dir <- withr::local_tempdir()
  id <- "skip_reuse"
  out1 <- file.path(dir, paste0(id, "_primary.qs2"))
  out2 <- file.path(dir, paste0(id, "_secondary.qs2"))
  marker <- file.path(dir, paste0(".batchit__", id))

  r1 <- batchit::batch_task(
    mk(".batch_fixture_task_skip_if_prior"),
    items = named_list(id, list(x = 5L)),
    outputs = named_list(id, c(primary = out1, secondary = out2)),
    n_workers = 1L, dev_path = dev_tree
  )
  expect_false(r1[[id]]$skipped)
  rec1 <- qs2::qs_read(marker)

  # PROVEN-RED WITHOUT THE SKIP PATH: dispatching again with a DIFFERENT x
  # would recompute and overwrite out1/out2 with 999L-derived values, and
  # would mint a NEW attempt token in a NEW marker. With the skip path, the
  # target sees a valid prior and returns batch_skip() instead.
  r2 <- batchit::batch_task(
    mk(".batch_fixture_task_skip_if_prior"),
    items = named_list(id, list(x = 999L)),
    outputs = named_list(id, c(primary = out1, secondary = out2)),
    n_workers = 1L, dev_path = dev_tree
  )
  rec2 <- qs2::qs_read(marker)

  expect_true(r2[[id]]$skipped)
  # outputs untouched -- still the FIRST run's values, not 999L-derived.
  expect_identical(qs2::qs_read(out1), 5L)
  expect_identical(qs2::qs_read(out2), 50)
  # NO new marker written -- same attempt token, byte-identical record.
  expect_identical(rec1$attempt, rec2$attempt)
  expect_identical(rec1, rec2)
  # the skip's own commit record carries THIS (second) dispatch's OWN fresh
  # token -- which the parent's inspector verified against what it just issued
  # -- so it necessarily DIFFERS from the first run's marker token (the prior
  # marker itself, rec1/rec2, is untouched; the reused token is not exposed).
  expect_false(identical(r2[[id]]$attempt, rec1$attempt))
  expect_identical(unname(r2[[id]]$committed[["primary"]]),
    normalizePath(out1, mustWork = FALSE))
})

# --- 4: batch_skip() with NO valid prior -> error, marker untouched ---------

test_that("batch_skip() with no valid prior (first run) -> error, marker untouched", {
  skip_if_not(have_tree, "package source tree not available")
  dir <- withr::local_tempdir()
  out1 <- file.path(dir, "noprior_primary.qs2")
  out2 <- file.path(dir, "noprior_secondary.qs2")
  marker <- file.path(dir, ".batchit__1")

  expect_error(
    batchit::batch_task(
      mk(".batch_fixture_task_always_skip"),
      items = list(list(x = 1L)),
      outputs = list(c(primary = out1, secondary = out2)),
      n_workers = 1L, dev_path = dev_tree
    ),
    "no valid prior"
  )
  expect_false(file.exists(marker))
  expect_false(file.exists(out1))
  expect_false(file.exists(out2))
})

# --- 5: batch_skip() when a declared output was externally deleted ----------

test_that("batch_skip() when a declared output was externally deleted -> fails loud (skip re-stats outputs), marker untouched", {
  skip_if_not(have_tree, "package source tree not available")
  dir <- withr::local_tempdir()
  id <- "skip_missing_output"
  out1 <- file.path(dir, paste0(id, "_primary.qs2"))
  out2 <- file.path(dir, paste0(id, "_secondary.qs2"))
  marker <- file.path(dir, paste0(".batchit__", id))

  batchit::batch_task(
    mk(".batch_fixture_task_skip_if_prior"),
    items = named_list(id, list(x = 5L)),
    outputs = named_list(id, c(primary = out1, secondary = out2)),
    n_workers = 1L, dev_path = dev_tree
  )
  rec_before <- qs2::qs_read(marker)
  file.remove(out1)

  expect_error(
    batchit::batch_task(
      mk(".batch_fixture_task_skip_if_prior"),
      items = named_list(id, list(x = 999L)),
      outputs = named_list(id, c(primary = out1, secondary = out2)),
      n_workers = 1L, dev_path = dev_tree
    ),
    "no longer exists"
  )
  expect_false(file.exists(out1))
  expect_true(file.exists(out2))
  # the marker is completely untouched by the failed skip attempt.
  rec_after <- qs2::qs_read(marker)
  expect_identical(rec_before, rec_after)
})

# --- 6: staged_writer target writes a stage then batch_skip()s --------------

test_that("batch_task() style = \"staged_writer\": a target that writes a stage then batch_skip()s -> the stage temp is cleaned; prior outputs preserved", {
  skip_if_not(have_tree, "package source tree not available")
  dir <- withr::local_tempdir()
  id <- "staged_skip"
  out1 <- file.path(dir, paste0(id, "_primary.qs2"))
  out2 <- file.path(dir, paste0(id, "_secondary.qs2"))
  marker <- file.path(dir, paste0(".batchit__", id))

  r1 <- batchit::batch_task(
    mk(".batch_fixture_task_staged_skip_if_prior"),
    items = named_list(id, list(x = 5L)),
    outputs = named_list(id, c(primary = out1, secondary = out2)),
    style = "staged_writer",
    n_workers = 1L, dev_path = dev_tree
  )
  expect_false(r1[[id]]$skipped)
  rec1 <- qs2::qs_read(marker)

  r2 <- batchit::batch_task(
    mk(".batch_fixture_task_staged_skip_if_prior"),
    items = named_list(id, list(x = 999L)),
    outputs = named_list(id, c(primary = out1, secondary = out2)),
    style = "staged_writer",
    n_workers = 1L, dev_path = dev_tree
  )
  rec2 <- qs2::qs_read(marker)

  expect_true(r2[[id]]$skipped)
  expect_identical(qs2::qs_read(out1), 5L)
  expect_identical(qs2::qs_read(out2), 50)
  expect_identical(rec1$attempt, rec2$attempt)
  # no leftover STAGE temp survives the skip (the primary stage the target
  # wrote before deciding to skip is cleaned by the SAME unconditional
  # on.exit(unlink(stage_map)) a normal commit relies on).
  expect_length(Sys.glob(file.path(dir, "*.stage*")), 0L)
})

# --- 7: S0 lockdown, extended to Unit 4 --------------------------------------

test_that("batch_task()'s parent body never references the Unit 4 CHILD-only skip helpers", {
  src <- paste(deparse(body(batchit::batch_task)), collapse = "\n")
  forbidden <- c(".batch_read_prior_marker", ".batch_commit_task_skip",
    ".batch_record_scope_enter", ".batch_record_scope_exit",
    "batch_prior(", "batch_skip(", "batch_record(")
  hits <- forbidden[vapply(forbidden, function(p) grepl(p, src, fixed = TRUE), logical(1))]
  expect_length(hits, 0L)
})

test_that("batch_task() dispatch/commit is identical whether a REAL VALID prior marker exists or not, for a target that never calls batch_prior()/batch_skip() (S0 lockdown, extended to Unit 4)", {
  # The existing S0 lockdown test in test-batch_task.R proves this for an
  # ABSENT and a GARBAGE marker. This extends it to a REAL, VALID marker
  # (produced by an actual prior commit) -- proving that a marker's
  # VALIDITY, not just its absence or corruption, has zero effect on
  # dispatch/commit for a consumer that does not opt in to batch_prior()/
  # batch_skip().
  skip_if_not(have_tree, "package source tree not available")
  dir <- withr::local_tempdir()
  id <- "lock_valid_marker"
  out1 <- file.path(dir, paste0(id, "_primary.qs2"))
  out2 <- file.path(dir, paste0(id, "_secondary.qs2"))
  marker <- file.path(dir, paste0(".batchit__", id))

  run_once <- function(x) {
    batchit::batch_task(
      mk(".batch_fixture_task_ok"),
      items = named_list(id, list(x = x)),
      outputs = named_list(id, c(primary = out1, secondary = out2)),
      n_workers = 1L, dev_path = dev_tree
    )
  }

  r1 <- run_once(11L)
  expect_true(file.exists(marker))  # a REAL, valid marker now sits here

  # Dispatch AGAIN with a DIFFERENT x, same item id/paths. .batch_fixture_
  # task_ok never calls batch_prior()/batch_skip(), so it must simply
  # recompute exactly as a fresh run would, regardless of the now-VALID
  # marker sitting at the derived path.
  r2 <- run_once(22L)
  expect_identical(qs2::qs_read(out1), 22L)
  expect_false(r2[[id]]$skipped)
  expect_false(identical(r1[[id]]$attempt, r2[[id]]$attempt))
})

# --- 8: batch_record()/batch_prior()/batch_skip() error outside a target run

test_that("batch_record() errors when called outside an active batch_task() target run", {
  expect_error(batchit::batch_record(list(x = 1)), "no batch_task\\(\\) target run is active")
})

test_that("batch_prior() errors when called outside an active batch_task() target run", {
  expect_error(batchit::batch_prior(), "no batch_task\\(\\) target run is active")
})

test_that("batch_skip() errors when called outside an active batch_task() target run", {
  expect_error(batchit::batch_skip(), "no batch_task\\(\\) target run is active")
})

# --- the current-dispatch attempt token binds a SKIP result too --------------

test_that(".batch_inspect_result rejects a skip result whose attempt token is NOT this dispatch's (skipped=TRUE is no self-asserted bypass)", {
  # A skip's result carries the CURRENT dispatch's attempt token, and the parent
  # inspector checks it UNCONDITIONALLY. A worker (or a stale/misrouted result
  # envelope) that sets skipped=TRUE but echoes the wrong token must be rejected,
  # even though its committed map is correct.
  t <- mk(".batch_fixture_task_ok")
  outputs <- c(primary = "/tmp/p.qs2", secondary = "/tmp/s.qs2")
  env <- list(
    protocol = PROTO, id = "1", status = "ok",
    value = list(committed = outputs, attempt = "STALE_OR_FORGED_TOKEN", skipped = TRUE),
    error = NULL, warnings = character(),
    target = list(package = t$package, symbol = t$symbol, hash = t$hash)
  )
  insp <- batchit:::.batch_inspect_result(
    env, expected_id = "1", target = t,
    expected_outputs = outputs, expected_attempt = "THIS_DISPATCH_TOKEN")
  expect_false(insp$ok)
  expect_match(insp$reason, "attempt token", fixed = TRUE)
})

# --- a SYMLINKED marker path -> prior=NULL + normal recompute (not rejection) -

test_that("batch_task(): a marker path that is a SYMLINK does not reject the envelope -- it recomputes (prior = NULL)", {
  skip_if_not(have_tree, "package source tree not available")
  dir <- withr::local_tempdir()
  out1 <- file.path(dir, "sym_primary.qs2")
  out2 <- file.path(dir, "sym_secondary.qs2")
  # Pre-plant a SYMLINK at this item's derived marker path. Per design 9.2 the
  # child's step-0 read must treat it as no valid prior (prior = NULL) and the
  # target must run + commit normally -- NOT be rejected before it ever runs
  # (which is what normalizePath()-following-the-leaf used to do).
  marker <- file.path(dir, ".batchit__only")
  link_target <- file.path(dir, "unrelated_file"); file.create(link_target)
  ok <- suppressWarnings(file.symlink(link_target, marker))
  skip_if_not(isTRUE(ok) && nzchar(suppressWarnings(Sys.readlink(marker))),
    "symlinks unsupported here")

  batchit::batch_task(
    mk(".batch_fixture_task_ok"),
    items = named_list("only", list(x = 7L)),
    outputs = named_list("only", c(primary = out1, secondary = out2)),
    n_workers = 1L, dev_path = dev_tree
  )
  expect_identical(qs2::qs_read(out1), 7L)                 # recomputed + committed
  expect_false(nzchar(suppressWarnings(Sys.readlink(marker))))  # symlink replaced
  expect_identical(qs2::qs_read(marker)$protocol, PROTO)   # a real engine marker
})

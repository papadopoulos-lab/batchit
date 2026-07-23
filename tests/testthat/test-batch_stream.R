# Shape B of the ONE contract, atomic-commit flavor: the parent is the
# producer, items are generated lazily under backpressure, and a bounded
# number are in flight at once -- but delivery is via the SAME declared-output
# commit engine run_and_write_files_atomically() uses (.batch_execute() ->
# .batch_commit_task(), transport-agnostic), instead of a raw return value.
# stream_from_parent_and_write_files_atomically() shares target resolution,
# validation, the result-envelope inspector and the failure semantics with
# run_and_write_files_atomically(); only the transport differs (mirai in-memory
# vs processx qs2 files). Tested through a REAL mirai daemon and the REAL
# commit engine, never a mock.
# (Here runner == consumer == batchit; runner != consumer is proven in
# test-batch_seam.R.)

skip_if_not_installed("mirai")

dev_tree <- normalizePath(testthat::test_path("..", ".."), mustWork = FALSE)
have_tree <- file.exists(file.path(dev_tree, "DESCRIPTION")) &&
  file.exists(file.path(dev_tree, "inst", "batch_worker.R"))

mk <- function(sym) batchit::package_function("batchit", sym)
PROTO <- batchit:::.BATCH_PROTOCOL

# --- 1: happy path, style = "return" -- every declared output + marker committed, through a REAL daemon ---

test_that("stream_from_parent_and_write_files_atomically() commits every declared output + a marker, through a real daemon", {
  skip_on_cran()
  skip_if_not(have_tree, "package source tree not available")
  dir <- withr::local_tempdir()
  seen <- character()
  producer <- function(id) {
    seen[[length(seen) + 1L]] <<- id
    list(x = as.integer(id))
  }
  outs <- list(
    `1` = c(primary = file.path(dir, "a_primary.qs2"), secondary = file.path(dir, "a_secondary.qs2")),
    `2` = c(primary = file.path(dir, "b_primary.qs2"), secondary = file.path(dir, "b_secondary.qs2"))
  )

  r <- batchit::stream_from_parent_and_write_files_atomically(
    mk(".batch_fixture_task_ok"),
    ids = c("1", "2"),
    producer = producer,
    outputs = outs,
    n_workers = 2L, dev_path = dev_tree
  )

  # producer called exactly once per id, in id order
  expect_identical(seen, c("1", "2"))

  expect_true(file.exists(outs[["1"]][["primary"]]))
  expect_true(file.exists(outs[["1"]][["secondary"]]))
  expect_identical(qs2::qs_read(outs[["1"]][["primary"]]), 1L)
  expect_identical(qs2::qs_read(outs[["1"]][["secondary"]]), 10)
  expect_true(file.exists(outs[["2"]][["primary"]]))
  expect_identical(qs2::qs_read(outs[["2"]][["primary"]]), 2L)

  marker1 <- file.path(dir, ".batchit__1")
  expect_true(file.exists(marker1))
  rec <- qs2::qs_read(marker1)
  # the marker is a real {protocol, attempt, committed} record
  expect_setequal(names(rec), c("protocol", "attempt", "committed"))
  expect_identical(rec$protocol, PROTO)
  expect_setequal(names(rec$committed), c("primary", "secondary"))

  # results in id order, named by id -- each a commit record {committed, attempt}
  expect_identical(names(r), c("1", "2"))
  expect_setequal(names(r[["1"]]), c("committed", "attempt"))
  expect_setequal(names(r[["1"]]$committed), c("primary", "secondary"))
  expect_true(is.character(r[["1"]]$attempt) && nzchar(r[["1"]]$attempt))
})

# --- 2: happy path, style = "staged_writer" ----------------------------------

test_that("stream_from_parent_and_write_files_atomically() style = \"staged_writer\": commits every declared output written via where_to_write_output(), through a real daemon", {
  skip_on_cran()
  skip_if_not(have_tree, "package source tree not available")
  dir <- withr::local_tempdir()
  out1 <- file.path(dir, "sw_primary.qs2")
  out2 <- file.path(dir, "sw_secondary.qs2")

  r <- batchit::stream_from_parent_and_write_files_atomically(
    mk(".batch_fixture_task_staged_ok"),
    ids = "only",
    producer = function(id) list(x = 21L),
    outputs = list(only = c(primary = out1, secondary = out2)),
    style = "staged_writer",
    n_workers = 1L, dev_path = dev_tree
  )

  expect_true(file.exists(out1))
  expect_true(file.exists(out2))
  expect_identical(qs2::qs_read(out1), 21L)
  expect_identical(qs2::qs_read(out2), 210)

  marker <- file.path(dir, ".batchit__only")
  expect_true(file.exists(marker))
  rec <- qs2::qs_read(marker)
  expect_setequal(names(rec), c("protocol", "attempt", "committed"))
  expect_identical(rec$protocol, PROTO)

  expect_setequal(names(r$only), c("committed", "attempt"))
  # no leftover STAGE temp survives a successful commit
  expect_length(Sys.glob(file.path(dir, "*.stage*")), 0L)
})

# --- 3: PROVEN-RED (a) -- return-style target names a name NOT in the declared outputs ---

test_that("stream_from_parent_and_write_files_atomically(): target return with an UNDECLARED extra name -> error, ZERO outputs/marker, through a real daemon", {
  skip_on_cran()
  skip_if_not(have_tree, "package source tree not available")
  dir <- withr::local_tempdir()
  out1 <- file.path(dir, "e_primary.qs2")
  out2 <- file.path(dir, "e_secondary.qs2")
  before <- list.files(dir, all.files = TRUE, no.. = TRUE)

  expect_error(
    batchit::stream_from_parent_and_write_files_atomically(
      mk(".batch_fixture_task_extra_name"),
      ids = "1",
      producer = function(id) list(x = 1L),
      outputs = list(`1` = c(primary = out1, secondary = out2)),
      n_workers = 1L, dev_path = dev_tree
    ),
    "declared outputs"
  )
  expect_false(file.exists(out1))
  expect_false(file.exists(out2))
  expect_false(file.exists(file.path(dir, ".batchit__1")))
  expect_identical(sort(list.files(dir, all.files = TRUE, no.. = TRUE)), sort(before))
})

# --- 4: PROVEN-RED (b) -- staged_writer target writes NOTHING ---------------

test_that("stream_from_parent_and_write_files_atomically() style = \"staged_writer\": target writes NOTHING -> error, no marker, through a real daemon", {
  skip_on_cran()
  skip_if_not(have_tree, "package source tree not available")
  dir <- withr::local_tempdir()
  out1 <- file.path(dir, "sw_nothing_primary.qs2")
  out2 <- file.path(dir, "sw_nothing_secondary.qs2")
  before <- list.files(dir, all.files = TRUE, no.. = TRUE)

  expect_error(
    batchit::stream_from_parent_and_write_files_atomically(
      mk(".batch_fixture_task_staged_writes_nothing"),
      ids = "1",
      producer = function(id) list(x = 1L),
      outputs = list(`1` = c(primary = out1, secondary = out2)),
      style = "staged_writer",
      n_workers = 1L, dev_path = dev_tree
    ),
    "never wrote"
  )
  expect_false(file.exists(out1))
  expect_false(file.exists(out2))
  expect_false(file.exists(file.path(dir, ".batchit__1")))
  expect_identical(sort(list.files(dir, all.files = TRUE, no.. = TRUE)), sort(before))
})

# --- 5: PROVEN-RED (c) -- a target error mid-run fails loud, no torn finals, no marker ---

test_that("stream_from_parent_and_write_files_atomically(): a target error leaves no marker, no torn finals, that id fails loud, through a real daemon", {
  skip_on_cran()
  skip_if_not(have_tree, "package source tree not available")
  dir <- withr::local_tempdir()
  out1 <- file.path(dir, "c_primary.qs2")
  out2 <- file.path(dir, "c_secondary.qs2")
  before <- list.files(dir, all.files = TRUE, no.. = TRUE)

  expect_error(
    batchit::stream_from_parent_and_write_files_atomically(
      mk(".batch_fixture_task_boom"),
      ids = "1",
      producer = function(id) list(x = 1L),
      outputs = list(`1` = c(primary = out1, secondary = out2)),
      n_workers = 1L, dev_path = dev_tree
    ),
    "task target detonated"
  )
  expect_false(file.exists(out1))
  expect_false(file.exists(out2))
  expect_false(file.exists(file.path(dir, ".batchit__1")))
  expect_identical(sort(list.files(dir, all.files = TRUE, no.. = TRUE)), sort(before))
})

# --- 6: backpressure -- producer is gated by the in-flight limit ------------

test_that("stream_from_parent_and_write_files_atomically() applies backpressure -- producer is gated by in-flight limit", {
  skip_on_cran()
  skip_if_not(have_tree, "package source tree not available")
  # 1 worker => max_inflight = 2. The producer records its parent-side call
  # time. With backpressure, producer(3) cannot be called until a daemon
  # drains id 1 (~1s of sleep + commit), so call 3 lands well after call 1.
  dir <- withr::local_tempdir()
  times <- numeric(0)
  ids <- as.character(1:4)
  producer <- function(id) {
    times[[length(times) + 1L]] <<- as.numeric(Sys.time())
    list(x = as.integer(id), seconds = 1)
  }
  outs <- stats::setNames(
    lapply(ids, function(id) c(
      primary = file.path(dir, paste0(id, "_primary.qs2")),
      secondary = file.path(dir, paste0(id, "_secondary.qs2")))),
    ids)

  batchit::stream_from_parent_and_write_files_atomically(
    mk(".batch_fixture_task_slow"),
    ids = ids,
    producer = producer,
    outputs = outs,
    n_workers = 1L, dev_path = dev_tree
  )
  expect_length(times, 4L)
  expect_gt(times[[3]] - times[[1]], 0.5)
})

# --- 7: item validation -------------------------------------------------------

test_that("stream_from_parent_and_write_files_atomically() validates each produced item against the target", {
  skip_on_cran()
  skip_if_not(have_tree, "package source tree not available")
  # A producer that yields an item missing the target's formal is rejected in
  # the parent, before it is ever dispatched to a daemon.
  producer <- function(id) list()  # .batch_fixture_task_ok needs `x`
  expect_error(
    batchit::stream_from_parent_and_write_files_atomically(
      mk(".batch_fixture_task_ok"),
      ids = "a", producer = producer,
      outputs = list(a = c(primary = "/tmp/p.qs2", secondary = "/tmp/s.qs2")),
      n_workers = 1L, dev_path = dev_tree
    ),
    "not supplied"
  )
})

# --- 8: never touches mirai's DEFAULT compute profile ------------------------

test_that("stream_from_parent_and_write_files_atomically() never dispatches on mirai's DEFAULT compute profile", {
  skip_on_cran()
  skip_if_not(have_tree, "package source tree not available")
  dir <- withr::local_tempdir()
  # daemons(n)/daemons(0) on the default profile reset and destroy whatever the
  # caller had. The caller here holds 1 daemon on the default profile;
  # stream_from_parent_and_write_files_atomically() must claim its own and
  # leave the default alone.
  mirai::daemons(1L, dispatcher = FALSE)
  on.exit(mirai::daemons(0L), add = TRUE)
  expect_equal(mirai::status()$connections, 1L)

  batchit::stream_from_parent_and_write_files_atomically(
    mk(".batch_fixture_task_ok"),
    ids = c("a", "b"), producer = function(id) list(x = 1L),
    outputs = list(
      a = c(primary = file.path(dir, "a1.qs2"), secondary = file.path(dir, "a2.qs2")),
      b = c(primary = file.path(dir, "b1.qs2"), secondary = file.path(dir, "b2.qs2"))
    ),
    n_workers = 1L, dev_path = dev_tree
  )
  # the caller's default-profile daemon is untouched
  expect_equal(mirai::status()$connections, 1L)
})

# --- 9: two back-to-back calls each get a fresh, usable profile -------------

test_that("two back-to-back stream_from_parent_and_write_files_atomically() calls each get a fresh, usable profile", {
  skip_on_cran()
  skip_if_not(have_tree, "package source tree not available")
  dir <- withr::local_tempdir()
  r1 <- batchit::stream_from_parent_and_write_files_atomically(
    mk(".batch_fixture_task_ok"),
    ids = "a", producer = function(id) list(x = 1L),
    outputs = list(a = c(primary = file.path(dir, "r1_1.qs2"), secondary = file.path(dir, "r1_2.qs2"))),
    n_workers = 1L, dev_path = dev_tree
  )
  r2 <- batchit::stream_from_parent_and_write_files_atomically(
    mk(".batch_fixture_task_ok"),
    ids = "b", producer = function(id) list(x = 2L),
    outputs = list(b = c(primary = file.path(dir, "r2_1.qs2"), secondary = file.path(dir, "r2_2.qs2"))),
    n_workers = 1L, dev_path = dev_tree
  )
  expect_identical(names(r1), "a")
  expect_identical(names(r2), "b")
  expect_identical(qs2::qs_read(file.path(dir, "r1_1.qs2")), 1L)
  expect_identical(qs2::qs_read(file.path(dir, "r2_1.qs2")), 2L)
})

test_that(".batch_stream_profile() namespaces its counter under a session nonce", {
  # The private profile name is `.batch_stream_<nonce>_<counter>`: the counter is
  # unique only within this closure, but the profile registry is session-WIDE, so
  # the high-entropy session nonce is what keeps two parties' names from colliding.
  # Pure string logic -- no mirai/daemons needed. Shared verbatim with
  # run_and_write_files_atomically()'s Shape-A sibling; this function is now the
  # sole consumer of this helper.
  n1 <- batchit:::.batch_stream_profile()
  n2 <- batchit:::.batch_stream_profile()

  pat <- "^\\.batch_stream_[[:alnum:]]+_[0-9]+$"
  expect_match(n1, pat)
  expect_match(n2, pat)          # OLD `.batch_stream_1` shape fails this (no `_<counter>`)
  expect_false(identical(n1, "default"))
  expect_false(identical(n2, "default"))

  nonce <- function(x) sub("^\\.batch_stream_(.*)_[0-9]+$", "\\1", x)
  ctr   <- function(x) as.integer(sub("^.*_([0-9]+)$", "\\1", x))
  # same session nonce (the OLD counter-only shape would give differing "nonces")
  expect_identical(nonce(n1), nonce(n2))
  expect_true(nzchar(nonce(n1)))
  # counters differ and advance
  expect_false(identical(n1, n2))
  expect_equal(ctr(n2), ctr(n1) + 1L)
})

# --- 10: per-item timeout -----------------------------------------------------

test_that("stream_from_parent_and_write_files_atomically() surfaces a wedged/slow task via its per-item timeout", {
  skip_on_cran()
  skip_if_not(have_tree, "package source tree not available")
  dir <- withr::local_tempdir()
  t0 <- Sys.time()
  expect_error(
    batchit::stream_from_parent_and_write_files_atomically(
      mk(".batch_fixture_task_slow"),
      ids = "slow", producer = function(id) list(x = 1L, seconds = 120),
      outputs = list(slow = c(primary = file.path(dir, "t1.qs2"), secondary = file.path(dir, "t2.qs2"))),
      n_workers = 1L, dev_path = dev_tree, timeout = 3
    ),
    "daemon/timeout error"
  )
  expect_lt(as.numeric(difftime(Sys.time(), t0, units = "secs")), 60)
})

# --- 11: dispatch-time validation, before doing any work ---------------------

test_that("stream_from_parent_and_write_files_atomically() validates ids, outputs, style, config and dev_path before doing any work", {
  ok_outputs_1 <- list(a = c(primary = "/tmp/p.qs2", secondary = "/tmp/s.qs2"))
  # `fn` must be a package_function() descriptor
  expect_error(
    batchit::stream_from_parent_and_write_files_atomically(
      function(x) x, ids = "a", producer = function(id) list(x = id),
      outputs = ok_outputs_1, n_workers = 1L),
    "package_function")
  # duplicate ids
  expect_error(
    batchit::stream_from_parent_and_write_files_atomically(mk(".batch_fixture_task_ok"),
      ids = c("a", "a"), producer = function(id) list(x = 1L),
      outputs = list(c(primary = "/tmp/p.qs2", secondary = "/tmp/s.qs2"),
        c(primary = "/tmp/p2.qs2", secondary = "/tmp/s2.qs2")),
      n_workers = 1L),
    "unique")
  # NA / empty id
  expect_error(
    batchit::stream_from_parent_and_write_files_atomically(mk(".batch_fixture_task_ok"),
      ids = c("a", NA), producer = function(id) list(x = 1L),
      outputs = list(c(primary = "/tmp/p.qs2", secondary = "/tmp/s.qs2"),
        c(primary = "/tmp/p2.qs2", secondary = "/tmp/s2.qs2")),
      n_workers = 1L),
    "non-empty, non-NA")
  # timeout validated as a scalar, not silently disabled
  expect_error(
    batchit::stream_from_parent_and_write_files_atomically(mk(".batch_fixture_task_ok"),
      ids = "a", producer = function(id) list(x = 1L),
      outputs = ok_outputs_1, n_workers = 1L, timeout = c(1, 2)),
    "single positive")
  # unknown style
  expect_error(
    batchit::stream_from_parent_and_write_files_atomically(mk(".batch_fixture_task_ok"),
      ids = "a", producer = function(id) list(x = 1L),
      outputs = ok_outputs_1, style = "bogus", n_workers = 1L),
    "unknown style")
  # outputs length must match ids
  expect_error(
    batchit::stream_from_parent_and_write_files_atomically(mk(".batch_fixture_task_ok"),
      ids = c("a", "b"), producer = function(id) list(x = 1L),
      outputs = ok_outputs_1, n_workers = 1L),
    "same length")
  # given-but-wrong dev_path errors even with an empty workload
  expect_error(
    batchit::stream_from_parent_and_write_files_atomically(mk(".batch_fixture_task_ok"),
      ids = character(0), producer = function(id) list(x = 1L),
      outputs = list(), n_workers = 1L,
      dev_path = "/no/such/tree"),
    "does not exist")
})

test_that("stream_from_parent_and_write_files_atomically(): an empty id vector returns an empty list without dispatching", {
  expect_identical(
    batchit::stream_from_parent_and_write_files_atomically(mk(".batch_fixture_task_ok"),
      ids = character(0), producer = function(id) list(x = 1L),
      outputs = list(), n_workers = 1L),
    list()
  )
})

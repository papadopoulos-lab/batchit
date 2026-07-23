# Declared-output commit (run_and_write_files_atomically()) -- Phase 6' Unit 1 (see
# PHASE6_DESIGN.md). Same real-subprocess discipline as the shape-A test file: these
# drive the ACTUAL inst/batch_worker.R through the real processx transport and
# the real .batch_commit_task() rename sequence -- never a mocked commit path.

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

# --- 1: declared outputs + marker committed through the real worker ---------

test_that("run_and_write_files_atomically() commits every declared output + a marker, through the real worker", {
  skip_if_not(have_tree, "package source tree not available")
  dir <- withr::local_tempdir()
  out1 <- file.path(dir, "a_primary.qs2")
  out2 <- file.path(dir, "a_secondary.qs2")

  r <- batchit::run_and_write_files_atomically(
    mk(".batch_fixture_task_ok"),
    items = named_list("only", list(x = 21L)),
    outputs = named_list("only", c(primary = out1, secondary = out2)),
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

test_that("run_and_write_files_atomically() accepts POSITIONAL outputs (unnamed items, unnamed outputs list)", {
  skip_if_not(have_tree, "package source tree not available")
  dir <- withr::local_tempdir()
  o1 <- c(primary = file.path(dir, "p1_a.qs2"), secondary = file.path(dir, "p1_b.qs2"))
  o2 <- c(primary = file.path(dir, "p2_a.qs2"), secondary = file.path(dir, "p2_b.qs2"))

  r <- batchit::run_and_write_files_atomically(
    mk(".batch_fixture_task_ok"),
    items = list(list(x = 1L), list(x = 2L)),
    outputs = list(o1, o2),
    n_workers = 2L, dev_path = dev_tree
  )
  expect_length(r, 2L)
  expect_true(all(file.exists(c(o1, o2))))
  expect_identical(qs2::qs_read(o1[["primary"]]), 1L)
  expect_identical(qs2::qs_read(o2[["primary"]]), 2L)
})

# --- 2: wrong-named target return -> error, ZERO outputs/marker, temps clean -

test_that("run_and_write_files_atomically(): target return missing a declared name -> error, ZERO outputs/marker, temps cleaned", {
  skip_if_not(have_tree, "package source tree not available")
  dir <- withr::local_tempdir()
  out1 <- file.path(dir, "b_primary.qs2")
  out2 <- file.path(dir, "b_secondary.qs2")
  before <- list.files(dir, all.files = TRUE, no.. = TRUE)

  expect_error(
    batchit::run_and_write_files_atomically(
      mk(".batch_fixture_task_missing_name"),
      items = list(list(x = 1L)),
      outputs = list(c(primary = out1, secondary = out2)),
      n_workers = 1L, dev_path = dev_tree
    ),
    "declared outputs"
  )
  expect_false(file.exists(out1))
  expect_false(file.exists(out2))
  expect_false(file.exists(file.path(dir, ".batchit__1")))
  expect_identical(sort(list.files(dir, all.files = TRUE, no.. = TRUE)), sort(before))
})

test_that("run_and_write_files_atomically(): target return with an UNDECLARED extra name -> error, ZERO outputs/marker, temps cleaned", {
  skip_if_not(have_tree, "package source tree not available")
  dir <- withr::local_tempdir()
  out1 <- file.path(dir, "e_primary.qs2")
  out2 <- file.path(dir, "e_secondary.qs2")
  before <- list.files(dir, all.files = TRUE, no.. = TRUE)

  expect_error(
    batchit::run_and_write_files_atomically(
      mk(".batch_fixture_task_extra_name"),
      items = list(list(x = 1L)),
      outputs = list(c(primary = out1, secondary = out2)),
      n_workers = 1L, dev_path = dev_tree
    ),
    "declared outputs"
  )
  expect_false(file.exists(out1))
  expect_false(file.exists(out2))
  expect_identical(sort(list.files(dir, all.files = TRUE, no.. = TRUE)), sort(before))
})

# --- 3: a target error leaves no marker, no torn finals, no temps -----------

test_that("run_and_write_files_atomically(): a target error leaves no marker, no torn finals, no leftover temps", {
  skip_if_not(have_tree, "package source tree not available")
  dir <- withr::local_tempdir()
  out1 <- file.path(dir, "c_primary.qs2")
  out2 <- file.path(dir, "c_secondary.qs2")
  before <- list.files(dir, all.files = TRUE, no.. = TRUE)

  expect_error(
    batchit::run_and_write_files_atomically(
      mk(".batch_fixture_task_boom"),
      items = list(list(x = 1L)),
      outputs = list(c(primary = out1, secondary = out2)),
      n_workers = 1L, dev_path = dev_tree
    ),
    "task target detonated"
  )
  expect_false(file.exists(out1))
  expect_false(file.exists(out2))
  expect_false(file.exists(file.path(dir, ".batchit__1")))
  expect_identical(sort(list.files(dir, all.files = TRUE, no.. = TRUE)), sort(before))
})

# --- 4: exit-0-wrote-nothing -> loud failure, no marker ----------------------

test_that("run_and_write_files_atomically(): target returns an empty list ('wrote nothing') -> loud failure, no marker", {
  skip_if_not(have_tree, "package source tree not available")
  dir <- withr::local_tempdir()
  out1 <- file.path(dir, "d_primary.qs2")
  out2 <- file.path(dir, "d_secondary.qs2")

  expect_error(
    batchit::run_and_write_files_atomically(
      mk(".batch_fixture_task_empty"),
      items = list(list(x = 1L)),
      outputs = list(c(primary = out1, secondary = out2)),
      n_workers = 1L, dev_path = dev_tree
    ),
    "declared outputs"
  )
  expect_false(file.exists(out1))
  expect_false(file.exists(file.path(dir, ".batchit__1")))
})

# --- 4b: mid-commit PARTIAL failure ------------------------------------------
# Every failure test above fails BEFORE .batch_commit_task() ever creates a
# temp (name validation, or the target erroring before .batch_commit_task()
# even runs) -- so its on.exit/pending cleanup path, and the parent-side
# SIGKILL/timeout temp sweep (PHASE6_DESIGN.md "Timeout/SIGKILL temp leak"),
# were untested. These two close that gap.

test_that("run_and_write_files_atomically(): commit fails PARTWAY through preparing temps (one already created) -- child's own on.exit cleans it up, no marker, no leak", {
  skip_if_not(have_tree, "package source tree not available")
  # Two declared outputs in TWO separate directories: primary's stays
  # writable throughout; secondary's is chmod'd READ-ONLY *before* dispatch.
  # Both directories EXIST, so parent-side dispatch validation passes
  # (.batch_validate_output_paths() checks dir.exists(), not writability) --
  # the failure only happens INSIDE .batch_commit_task()'s step-1 loop:
  # primary's temp is created successfully FIRST (declaration order), THEN
  # secondary's qs2::qs_save() fails with permission denied. A genuine
  # partial commit: one real temp exists on disk when the failure hits.
  base <- withr::local_tempdir()
  dir1 <- file.path(base, "writable"); dir.create(dir1)
  dir2 <- file.path(base, "readonly"); dir.create(dir2)
  out1 <- file.path(dir1, "primary.qs2")
  out2 <- file.path(dir2, "secondary.qs2")
  Sys.chmod(dir2, "0500")
  withr::defer(Sys.chmod(dir2, "0700"))  # let withr delete the tempdir after

  # Prove the CHILD's own on.exit(pending) cleanup is load-bearing, not the
  # parent sweep: no-op the PARENT-side sweep, so the ONLY thing that can remove
  # primary's real, already-created temp is the child's own on.exit (which runs
  # in the subprocess, unaffected by this parent-process mock). Without this,
  # the parent sweep would clean up too and mask whether the child cleanup works.
  testthat::local_mocked_bindings(
    .batch_sweep_task_temps = function(...) invisible(TRUE),
    .package = "batchit"
  )

  expect_error(
    batchit::run_and_write_files_atomically(
      mk(".batch_fixture_task_ok"),
      items = list(list(x = 1L)),
      outputs = list(c(primary = out1, secondary = out2)),
      n_workers = 1L, dev_path = dev_tree
    )
  )

  expect_false(file.exists(out1))
  expect_false(file.exists(out2))
  expect_false(file.exists(file.path(dir1, ".batchit__1")))
  expect_false(file.exists(file.path(dir2, ".batchit__1")))
  # no leftover temp in EITHER directory: the child's own on.exit(pending)
  # cleanup removed primary's real, successfully-created temp before the
  # (cleanly exited, status "error") worker even wrote its result envelope.
  expect_length(Sys.glob(file.path(dir1, "*.tmp*")), 0L)
  expect_length(Sys.glob(file.path(dir2, "*.tmp*")), 0L)
})

test_that("run_and_write_files_atomically(): a timeout-killed item's ATTEMPT-SCOPED temps are swept, but an UNRELATED file is not (SIGKILL leak fix + no over-deletion)", {
  skip_if_not(have_tree, "package source tree not available")
  # A real kill_tree() sends SIGKILL, which R's on.exit cannot intercept, so a
  # worker killed mid-commit can orphan its commit temps. There is no hook to
  # land a real kill deterministically inside that short window, so instead:
  # FIX the attempt token (so the test knows the exact temp shape the child
  # would have produced -- `<basename>.<token>.tmp<random>`), drive a REAL
  # timeout-kill (the target sleeps far past `timeout`), and PRE-SEED both this
  # attempt's temps AND an UNRELATED file. The parent sweep (same `.fail()`
  # path) must remove ONLY this attempt's temps -- keyed on the unique token --
  # and leave the unrelated file untouched (the over-deletion the round-2
  # review caught: a broad `<basename>.tmp*` glob would delete a user's
  # `out.qs2.tmp.backup`).
  testthat::local_mocked_bindings(
    .batch_new_attempt_token = function() "TESTTOKENabc123",
    .package = "batchit"
  )
  dir <- withr::local_tempdir()
  out1 <- file.path(dir, "k_primary.qs2")
  out2 <- file.path(dir, "k_secondary.qs2")
  marker <- file.path(dir, ".batchit__slow")

  # This attempt's own temps (attempt-scoped) -- MUST be swept.
  scoped_out1 <- tempfile(
    pattern = paste0(basename(out1), ".TESTTOKENabc123.tmp"), tmpdir = dir)
  scoped_marker <- tempfile(
    pattern = paste0(basename(marker), ".TESTTOKENabc123.tmp"), tmpdir = dir)
  # An UNRELATED pre-existing file carrying NO attempt token -- MUST survive.
  unrelated <- file.path(dir, "k_primary.qs2.tmp.backup")
  file.create(scoped_out1, scoped_marker, unrelated)
  expect_true(all(file.exists(c(scoped_out1, scoped_marker, unrelated))))

  expect_error(
    batchit::run_and_write_files_atomically(
      mk(".batch_fixture_task_slow"),
      items = named_list("slow", list(x = 1L, seconds = 30)),
      outputs = named_list("slow", c(primary = out1, secondary = out2)),
      n_workers = 1L, dev_path = dev_tree, timeout = 1
    ),
    "timeout|killed"
  )

  # This attempt's temps swept; the unrelated `.tmp.backup` untouched.
  expect_false(file.exists(scoped_out1))
  expect_false(file.exists(scoped_marker))
  expect_true(file.exists(unrelated))
  expect_false(file.exists(out1))
  expect_false(file.exists(out2))
  expect_false(file.exists(marker))
})

# --- 5: S0 LOCKDOWN -- no launch decision may depend on marker state --------

test_that("run_and_write_files_atomically(): dispatch behaves IDENTICALLY for the SAME id/paths, with vs without a pre-existing marker (S0 lockdown, behavioural)", {
  skip_if_not(have_tree, "package source tree not available")
  # Same id, same output paths, same derived marker path for BOTH runs
  # (sequentially -- a prior version of this test used DIFFERENT ids/paths
  # per run and only checked "both succeeded", which cannot actually show
  # dispatch is IDENTICAL, only that it works in both cases).
  dir <- withr::local_tempdir()
  id <- "lock_same"
  out1 <- file.path(dir, paste0(id, "_primary.qs2"))
  out2 <- file.path(dir, paste0(id, "_secondary.qs2"))
  marker <- file.path(dir, paste0(".batchit__", id))
  items <- named_list(id, list(x = 7L))
  outs <- named_list(id, c(primary = out1, secondary = out2))

  run_once <- function() {
    r <- batchit::run_and_write_files_atomically(
      mk(".batch_fixture_task_ok"),
      items = items, outputs = outs,
      n_workers = 1L, dev_path = dev_tree
    )
    list(
      committed_names = sort(names(r[[id]]$committed)),
      committed_paths = unname(sort(r[[id]]$committed)),
      out1_val = qs2::qs_read(out1),
      out2_val = qs2::qs_read(out2),
      out1_exists = file.exists(out1),
      out2_exists = file.exists(out2),
      marker_exists = file.exists(marker)
    )
  }

  # run 1: no pre-existing marker (the common case)
  r1 <- run_once()

  # reset to identical starting conditions -- EXCEPT this time a GARBAGE
  # marker (not even a valid qs2 payload) sits at the EXACT SAME derived
  # marker path before dispatch. If the parent's launch decision depended on
  # marker state at all, this is where the two runs would diverge.
  file.remove(out1, out2, marker)
  writeLines("not a real marker, and not even qs2", marker)
  r2 <- run_once()

  # every OBSERVABLE dispatch outcome is identical between the two runs --
  # except the attempt token, which is a fresh random value issued by the
  # PARENT on every dispatch by design (not a marker-state effect), so it is
  # deliberately excluded from this comparison.
  expect_identical(r1$committed_names, r2$committed_names)
  expect_identical(r1$committed_paths, r2$committed_paths)
  expect_identical(r1$out1_val, r2$out1_val)
  expect_identical(r1$out2_val, r2$out2_val)
  expect_identical(r1$out1_exists, r2$out1_exists)
  expect_identical(r1$out2_exists, r2$out2_exists)
  expect_identical(r1$marker_exists, r2$marker_exists)
  # the garbage marker really was overwritten by the CHILD's own commit
  # (never read or trusted by the parent) -- it now decodes to a real record.
  rec <- qs2::qs_read(marker)
  expect_identical(rec$protocol, PROTO)
})

# --- 5b: S0 LOCKDOWN, AST-based static guard ---------------------------------
# Replaces a line-regex guard (evadable by a multiline call, or by reading an
# INTERMEDIATE variable derived from the marker, e.g.
# `witness <- markers[idx]; if (file.exists(witness))`) with a real AST walk:
# parse the function's body (`body()`/`as.list()` recursion), track which
# variables are marker-derived via fixed-point ASSIGNMENT taint propagation,
# and flag any call to a marker-READING function whose arguments mention a
# tainted variable -- wherever in the body it occurs, including inside a
# NESTED closure (`.fail <- function(...) {...}` is itself a sub-expression
# of run_and_write_files_atomically()'s own body).

# Every call anywhere inside `expr`, recursively -- including inside a nested
# function literal.
.ast_all_calls <- function(expr) {
  out <- list()
  if (is.call(expr)) {
    out[[length(out) + 1L]] <- expr
    for (part in as.list(expr)) {
      if (is.call(part)) out <- c(out, .ast_all_calls(part))
    }
  }
  out
}

# Fixed-point taint propagation from `seed` (marker-derived variable names):
# any variable ASSIGNED from an expression that mentions an already-tainted
# variable becomes tainted too -- so `witness <- markers[idx]` taints
# `witness`, not just literal occurrences of `markers`. Reports every call to
# one of `forbidden` whose arguments mention a (possibly newly-grown) tainted
# variable, anywhere in `fn`'s body.
.ast_marker_reads <- function(fn, seed, forbidden) {
  calls <- .ast_all_calls(body(fn))
  tainted <- seed
  repeat {
    grown <- tainted
    for (cl in calls) {
      head <- cl[[1]]
      if (is.symbol(head) && as.character(head) %in% c("<-", "=", "<<-") &&
          length(cl) >= 3 && is.symbol(cl[[2]])) {
        rhs_vars <- all.vars(cl[[3]])
        if (any(rhs_vars %in% grown)) grown <- union(grown, as.character(cl[[2]]))
      }
    }
    if (identical(grown, tainted)) break
    tainted <- grown
  }
  hits <- character(0)
  for (cl in calls) {
    head <- cl[[1]]
    fn_name <- if (is.symbol(head)) {
      as.character(head)
    } else if (is.call(head) && identical(head[[1]], as.symbol("::"))) {
      paste0(as.character(head[[2]]), "::", as.character(head[[3]]))
    } else {
      NA_character_
    }
    if (!is.na(fn_name) && fn_name %in% forbidden && any(all.vars(cl) %in% tainted)) {
      hits <- c(hits, paste(deparse(cl), collapse = " "))
    }
  }
  hits
}

.MARKER_READ_FNS <- c("file.exists", "file.info", "Sys.readlink", "readLines",
  "qs2::qs_read", "qs_read", "file.access",
  # normalizePath() FOLLOWS a leaf symlink at the given path, so calling it on a
  # marker in the launch path makes a launch decision depend on marker
  # filesystem state -- a section-0 violation (caught round-3). Forbidden too.
  "normalizePath")

test_that(".ast_marker_reads() catches a planted marker read, direct AND via an intermediate variable (proves the detector works, before trusting it on production code)", {
  direct_bad <- function() {
    marker <- "/tmp/.batchit__x"
    if (file.exists(marker)) TRUE else FALSE
  }
  expect_true(length(.ast_marker_reads(direct_bad, "marker", .MARKER_READ_FNS)) >= 1L)

  # the intermediate-variable evasion a plain same-line regex would miss:
  # `witness` does not itself contain "marker", so grepping a line for both
  # "marker" and "file.exists" together would not flag this.
  evasion_bad <- function() {
    markers <- c("/tmp/.batchit__x")
    idx <- 1L
    witness <- markers[idx]
    if (file.exists(witness)) TRUE else FALSE
  }
  hits <- .ast_marker_reads(evasion_bad, "markers", .MARKER_READ_FNS)
  expect_true(length(hits) >= 1L)
  expect_match(hits, "file.exists", fixed = TRUE, all = FALSE)

  # a MULTILINE evasion (assignment on one line, the forbidden call on a
  # later line) -- a naive same-line regex would also miss this shape.
  multiline_bad <- function(marker_path) {
    m <- marker_path
    info <- file.info(m)
    info
  }
  expect_true(length(.ast_marker_reads(multiline_bad, "marker_path", .MARKER_READ_FNS)) >= 1L)

  qs2_evasion <- function(marker_path) {
    m <- marker_path
    qs2::qs_read(m)
  }
  expect_true(length(.ast_marker_reads(qs2_evasion, "marker_path", .MARKER_READ_FNS)) >= 1L)

  # a clean function that only builds a STRING from the marker path (exactly
  # what .batch_task_marker_path() does) produces NO hits -- proving the
  # detector isn't just flagging every mention of "marker".
  clean <- function() {
    marker <- "/tmp/.batchit__x"
    nchar(marker) > 0
  }
  expect_length(.ast_marker_reads(clean, "marker", .MARKER_READ_FNS), 0L)
})

test_that("run_and_write_files_atomically()'s PARENT-side dispatch path has NO marker-state read (S0 lockdown, AST-based)", {
  # Every parent-side function that handles a marker path: run_and_write_files_atomically()
  # itself (which includes its nested .launch()/.collect()/.fail() closures,
  # since those are sub-expressions of its own body) plus the two small
  # marker-aware helpers it calls. `.batch_commit_task()` is the CHILD-side
  # function legitimately exempt (design section 0 / the file banner) and is
  # deliberately NOT included.
  # Every PARENT-side (pre-dispatch) function that RECEIVES or DERIVES a marker
  # path: run_and_write_files_atomically() itself, the two marker-aware helpers it calls, AND
  # .batch_input_envelope() (which takes `marker` and builds the wire envelope)
  # -- so a planted marker read in that callee is caught too. (.batch_execute()
  # and .batch_commit_task() are deliberately EXEMPT: they run in the child,
  # as part of committing an already-dispatched item, never as a launch
  # decision -- design section 0.)
  fns <- list(
    run_and_write_files_atomically = batchit::run_and_write_files_atomically,
    .batch_check_task_collisions = batchit:::.batch_check_task_collisions,
    .batch_task_marker_path = batchit:::.batch_task_marker_path,
    .batch_input_envelope = batchit:::.batch_input_envelope
  )
  hits <- unlist(lapply(fns, .ast_marker_reads,
    seed = c("marker", "markers", "marker_path", "norm_markers"),
    forbidden = .MARKER_READ_FNS))
  expect_length(hits, 0L)
})

test_that("run_and_write_files_atomically(): a SYMLINKED output leaf is rejected, not silently followed", {
  # `normalizePath(whole_path)` would resolve `alias.qs2 -> real.qs2` and commit
  # to the target; parent-only normalization keeps the leaf un-resolved so the
  # symlink is caught. Rejected at dispatch (parent-side), before any worker.
  skip_if_not(have_tree, "package source tree not available")
  base <- withr::local_tempdir()
  real <- file.path(base, "real.qs2"); file.create(real)
  alias <- file.path(base, "alias.qs2")
  ok <- suppressWarnings(file.symlink(real, alias))
  skip_if_not(
    isTRUE(ok) && nzchar(suppressWarnings(Sys.readlink(alias))),
    "symlinks unsupported here")
  expect_error(
    batchit::run_and_write_files_atomically(
      mk(".batch_fixture_task_ok"),
      items = list(list(x = 1L)),
      outputs = list(c(primary = alias)),
      n_workers = 1L, dev_path = dev_tree
    ),
    "symlink"
  )
})

# --- 6: protocol bump -- an OLD-protocol envelope is rejected ---------------

test_that("an envelope carrying the OLD protocol number is rejected (protocol bump)", {
  # The bump itself, pinned to the actual number (not just "differs from
  # whatever it currently is") -- a regression that silently reverted the
  # bump would not be caught by a test that only compares against PROTO - 1L,
  # since that literal tracks the LIVE constant rather than asserting what it
  # must be.
  expect_identical(batchit:::.BATCH_PROTOCOL, 2L)

  good_meta <- list(fn_kind = "package", package = "batchit", symbol = "s",
    hash = "h", id = "1", runner_package = "batchit", collect = TRUE)
  # the LITERAL old protocol number (1L), not `PROTO - 1L`: the latter would
  # keep "passing" even if the bump were accidentally reverted (PROTO back to
  # 1, PROTO - 1L back to 0 -- still "an old number", proving nothing about
  # whether 1 specifically is rejected).
  old <- list(protocol = 1L, meta = good_meta, args = list())
  expect_error(batchit:::.batch_check_envelope(old), "protocol mismatch")

  current <- list(protocol = PROTO, meta = good_meta, args = list())
  expect_true(batchit:::.batch_check_envelope(current))
})

test_that("the REAL worker rejects an OLD-protocol envelope BEFORE the target ever runs", {
  skip_if_not(have_tree, "package source tree not available")
  worker <- file.path(dev_tree, "inst", "batch_worker.R")
  rscript <- file.path(R.home("bin"), "Rscript")
  meta <- list(fn_kind = "package", package = "batchit",
    symbol = ".batch_fixture_echo", hash = mk(".batch_fixture_echo")$hash,
    id = "1", collect = TRUE, runner_package = "batchit", dev_path = dev_tree)
  # LITERAL old protocol (1L) -- see the rationale in the test above.
  env <- list(protocol = 1L, meta = meta, args = list(x = "SHOULD-NOT-RUN"))
  inp <- withr::local_tempfile(fileext = ".qs2")
  outp <- withr::local_tempfile(fileext = ".qs2")
  errf <- withr::local_tempfile(fileext = ".txt")
  qs2::qs_save(env, inp)

  p <- processx::process$new(rscript, c("--vanilla", worker, inp, outp),
    env = c("current", R_LIBS = paste(.libPaths(), collapse = .Platform$path.sep)),
    stdout = "|", stderr = errf)
  p$wait(timeout = 30000)

  expect_false(file.exists(outp))
  expect_false(identical(p$get_exit_status(), 0L))
  err <- paste(readLines(errf, warn = FALSE), collapse = "\n")
  expect_match(err, "protocol mismatch")
})

# --- 7: commit-record shape -- committed + attempt, never raw ---------------

test_that("run_and_write_files_atomically()'s result is the commit record (committed + attempt), never the raw value", {
  skip_if_not(have_tree, "package source tree not available")
  dir <- withr::local_tempdir()
  out1 <- file.path(dir, "g_primary.qs2")
  out2 <- file.path(dir, "g_secondary.qs2")

  r <- batchit::run_and_write_files_atomically(
    mk(".batch_fixture_task_ok"),
    items = list(list(x = 999999L)),
    outputs = list(c(primary = out1, secondary = out2)),
    n_workers = 1L, dev_path = dev_tree
  )

  rec <- r[[1]]
  expect_setequal(names(rec), c("committed", "attempt"))
  expect_identical(unname(rec$committed[["primary"]]), normalizePath(out1, mustWork = FALSE))
  expect_identical(unname(rec$committed[["secondary"]]), normalizePath(out2, mustWork = FALSE))
  expect_true(is.character(rec$attempt) && nzchar(rec$attempt))
  # the raw computed value (999999 * 10 = 9999990) must not appear anywhere
  # in the record itself
  expect_false(any(vapply(unlist(rec), function(v) identical(v, "9999990"), logical(1))))
  # ... it DID get written to disk -- the record only ever carries paths
  expect_identical(qs2::qs_read(out2), 9999990)
})

test_that(".batch_inspect_result() rejects a commit record with the WRONG attempt token or a substituted output map", {
  tgt <- list(package = "batchit", symbol = "s", hash = "H")
  dispatched_outputs <- c(primary = "/tmp/x_primary.qs2", secondary = "/tmp/x_secondary.qs2")
  good <- list(protocol = PROTO, id = "1", status = "ok",
    warnings = character(),
    target = list(package = "batchit", symbol = "s", hash = "H"),
    value = list(committed = dispatched_outputs, attempt = "tok-abc"))
  expect_true(batchit:::.batch_inspect_result(good, "1", tgt,
    expected_outputs = dispatched_outputs, expected_attempt = "tok-abc")$ok)

  wrong_attempt <- good
  wrong_attempt$value$attempt <- "tok-DIFFERENT"
  r1 <- batchit:::.batch_inspect_result(wrong_attempt, "1", tgt,
    expected_outputs = dispatched_outputs, expected_attempt = "tok-abc")
  expect_false(r1$ok)
  expect_match(r1$reason, "attempt")

  substituted <- good
  substituted$value$committed <- c(primary = "/tmp/EVIL.qs2", secondary = "/tmp/x_secondary.qs2")
  r2 <- batchit:::.batch_inspect_result(substituted, "1", tgt,
    expected_outputs = dispatched_outputs, expected_attempt = "tok-abc")
  expect_false(r2$ok)
})

test_that(".batch_inspect_result() rejects a commit record with an EXTRA field (raw-data smuggling)", {
  # A worker returning list(committed = ..., attempt = ..., raw = <huge>)
  # must be rejected -- allowing extras would let raw data ride along behind
  # a well-formed-looking commit record, defeating the entire point of
  # run_and_write_files_atomically() (only a small commit record ever
  # crosses back).
  tgt <- list(package = "batchit", symbol = "s", hash = "H")
  dispatched_outputs <- c(primary = "/tmp/x_primary.qs2", secondary = "/tmp/x_secondary.qs2")
  smuggled <- list(protocol = PROTO, id = "1", status = "ok",
    warnings = character(),
    target = list(package = "batchit", symbol = "s", hash = "H"),
    value = list(committed = dispatched_outputs, attempt = "tok-abc",
      raw = 1:1e6))
  r <- batchit:::.batch_inspect_result(smuggled, "1", tgt,
    expected_outputs = dispatched_outputs, expected_attempt = "tok-abc")
  expect_false(r$ok)
  expect_match(r$reason, "EXACTLY")
})

test_that(".batch_inspect_result() rejects a commit record MISSING a required field", {
  tgt <- list(package = "batchit", symbol = "s", hash = "H")
  dispatched_outputs <- c(primary = "/tmp/x_primary.qs2", secondary = "/tmp/x_secondary.qs2")
  missing_attempt <- list(protocol = PROTO, id = "1", status = "ok",
    warnings = character(),
    target = list(package = "batchit", symbol = "s", hash = "H"),
    value = list(committed = dispatched_outputs))
  r <- batchit:::.batch_inspect_result(missing_attempt, "1", tgt,
    expected_outputs = dispatched_outputs, expected_attempt = "tok-abc")
  expect_false(r$ok)
  expect_match(r$reason, "EXACTLY")

  missing_committed <- list(protocol = PROTO, id = "1", status = "ok",
    warnings = character(),
    target = list(package = "batchit", symbol = "s", hash = "H"),
    value = list(attempt = "tok-abc"))
  r2 <- batchit:::.batch_inspect_result(missing_committed, "1", tgt,
    expected_outputs = dispatched_outputs, expected_attempt = "tok-abc")
  expect_false(r2$ok)
  expect_match(r2$reason, "EXACTLY")
})

# --- 8: style = "staged_writer" (Phase 6' Unit 2) ----------------------------
# Same real-subprocess discipline as the "return"-style tests above: the
# target STREAMS each declared output to where_to_write_output(<name>) instead of
# returning it; the return value is unconditionally ignored by the commit
# engine.

test_that("run_and_write_files_atomically() style = \"staged_writer\": commits every declared output written via where_to_write_output() + a marker, through the real worker", {
  skip_if_not(have_tree, "package source tree not available")
  dir <- withr::local_tempdir()
  out1 <- file.path(dir, "sw_ok_primary.qs2")
  out2 <- file.path(dir, "sw_ok_secondary.qs2")

  r <- batchit::run_and_write_files_atomically(
    mk(".batch_fixture_task_staged_ok"),
    items = named_list("only", list(x = 21L)),
    outputs = named_list("only", c(primary = out1, secondary = out2)),
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
  expect_identical(rec$protocol, PROTO)
  expect_setequal(names(rec$committed), c("primary", "secondary"))

  expect_identical(names(r), "only")
  expect_setequal(names(r$only$committed), c("primary", "secondary"))
  expect_true(is.character(r$only$attempt) && nzchar(r$only$attempt))

  # no leftover STAGE temp survives a successful commit
  expect_length(Sys.glob(file.path(dir, "*.stage*")), 0L)
})

test_that("run_and_write_files_atomically() style = \"staged_writer\": target writes only SOME declared outputs -> error, NO marker, staged files cleaned, no torn finals", {
  skip_if_not(have_tree, "package source tree not available")
  dir <- withr::local_tempdir()
  out1 <- file.path(dir, "sw_missing_primary.qs2")
  out2 <- file.path(dir, "sw_missing_secondary.qs2")
  before <- list.files(dir, all.files = TRUE, no.. = TRUE)

  expect_error(
    batchit::run_and_write_files_atomically(
      mk(".batch_fixture_task_staged_missing"),
      items = list(list(x = 1L)),
      outputs = list(c(primary = out1, secondary = out2)),
      style = "staged_writer",
      n_workers = 1L, dev_path = dev_tree
    ),
    "never wrote"
  )
  expect_false(file.exists(out1))
  expect_false(file.exists(out2))
  expect_false(file.exists(file.path(dir, ".batchit__1")))
  # written stage temp (primary) AND never-written stage temp (secondary) are
  # both gone -- nothing left behind by a partial staged_writer commit
  expect_identical(sort(list.files(dir, all.files = TRUE, no.. = TRUE)), sort(before))
})

test_that("run_and_write_files_atomically() style = \"staged_writer\": target writes one stage then ERRORS mid-run -> .batch_execute()'s own cleanup removes the partial stage (commit never reached)", {
  # Distinct from the 'missing' test above, which RETURNS normally and so
  # reaches .batch_commit_task()'s cleanup. Here the target stop()s DURING
  # do.call() -- after writing one stage -- so .batch_commit_task() is never
  # entered, and only the on.exit(unlink(stage_map)) registered in
  # .batch_execute()'s own frame BEFORE do.call() can remove the written
  # stage. Proves that outer cleanup is load-bearing (codex Unit-2 round 1).
  skip_if_not(have_tree, "package source tree not available")
  dir <- withr::local_tempdir()
  out1 <- file.path(dir, "sw_pboom_primary.qs2")
  out2 <- file.path(dir, "sw_pboom_secondary.qs2")
  before <- list.files(dir, all.files = TRUE, no.. = TRUE)

  # No-op the PARENT sweep so the ONLY thing that can remove the written stage
  # is .batch_execute()'s own on.exit in the CHILD (unaffected by this
  # parent-process mock). Without this, the parent sweep would clean the stage
  # too and mask whether the child-side outer cleanup is load-bearing.
  testthat::local_mocked_bindings(
    .batch_sweep_task_temps = function(...) invisible(TRUE),
    .package = "batchit"
  )

  expect_error(
    batchit::run_and_write_files_atomically(
      mk(".batch_fixture_task_staged_partial_boom"),
      items = list(list(x = 1L)),
      outputs = list(c(primary = out1, secondary = out2)),
      style = "staged_writer",
      n_workers = 1L, dev_path = dev_tree
    ),
    "detonated"
  )
  expect_false(file.exists(out1))
  expect_false(file.exists(out2))
  expect_false(file.exists(file.path(dir, ".batchit__1")))
  # The primary stage the target wrote before erroring must be swept by
  # .batch_execute()'s own on.exit -- nothing left behind.
  expect_identical(sort(list.files(dir, all.files = TRUE, no.. = TRUE)), sort(before))
})

test_that("where_to_write_output(): errors when called OUTSIDE a staged_writer run", {
  expect_error(
    batchit::where_to_write_output("primary"),
    "no staged_writer.*run is active"
  )
})

test_that("run_and_write_files_atomically() style = \"staged_writer\": where_to_write_output() with an UNDECLARED name errors, through the real worker", {
  skip_if_not(have_tree, "package source tree not available")
  dir <- withr::local_tempdir()
  out1 <- file.path(dir, "sw_badname_primary.qs2")
  out2 <- file.path(dir, "sw_badname_secondary.qs2")

  expect_error(
    batchit::run_and_write_files_atomically(
      mk(".batch_fixture_task_staged_bad_name"),
      items = list(list(x = 1L)),
      outputs = list(c(primary = out1, secondary = out2)),
      style = "staged_writer",
      n_workers = 1L, dev_path = dev_tree
    ),
    "not one of this item's declared outputs"
  )
  expect_false(file.exists(out1))
  expect_false(file.exists(out2))
})

test_that("run_and_write_files_atomically() style = \"staged_writer\": a timeout-killed item's ATTEMPT-SCOPED STAGE leftovers are swept, but an UNRELATED file is not (token-scoping, not just suffix-shape)", {
  skip_if_not(have_tree, "package source tree not available")
  # Mirrors the "return"-style SIGKILL-leak test above, but for staged_writer's
  # OWN temp shape: `<basename>.<attempt>.stage<random>`, not `.tmp`. Before
  # .batch_sweep_task_temps()'s pattern is widened to match `.stage` too, this
  # test is RED: the pre-seeded staged leftovers below survive the sweep
  # (only the marker's `.tmp` temp, if any, would ever have matched).
  testthat::local_mocked_bindings(
    .batch_new_attempt_token = function() "TESTTOKENstage1",
    .package = "batchit"
  )
  dir <- withr::local_tempdir()
  out1 <- file.path(dir, "sw_slow_primary.qs2")
  out2 <- file.path(dir, "sw_slow_secondary.qs2")
  marker <- file.path(dir, ".batchit__slowstage")

  # This attempt's own STAGE leftovers (as a killed worker mid-stream would
  # leave behind) -- MUST be swept.
  scoped_stage1 <- tempfile(
    pattern = paste0(basename(out1), ".TESTTOKENstage1.stage"), tmpdir = dir)
  scoped_stage2 <- tempfile(
    pattern = paste0(basename(out2), ".TESTTOKENstage1.stage"), tmpdir = dir)
  # An UNRELATED pre-existing file carrying NO attempt token -- MUST survive.
  unrelated <- file.path(dir, "sw_slow_primary.qs2.stage.backup")
  file.create(scoped_stage1, scoped_stage2, unrelated)
  expect_true(all(file.exists(c(scoped_stage1, scoped_stage2, unrelated))))

  expect_error(
    batchit::run_and_write_files_atomically(
      mk(".batch_fixture_task_staged_slow"),
      items = named_list("slowstage", list(x = 1L, seconds = 30)),
      outputs = named_list("slowstage", c(primary = out1, secondary = out2)),
      style = "staged_writer",
      n_workers = 1L, dev_path = dev_tree, timeout = 1
    ),
    "timeout|killed"
  )

  # This attempt's stage leftovers swept; the unrelated `.stage.backup` untouched.
  expect_false(file.exists(scoped_stage1))
  expect_false(file.exists(scoped_stage2))
  expect_true(file.exists(unrelated))
  expect_false(file.exists(out1))
  expect_false(file.exists(out2))
  expect_false(file.exists(marker))
})

# --- supplementary: dispatch-time validation ---------------------------------

test_that("run_and_write_files_atomically(): an unknown style is rejected", {
  expect_error(
    batchit::run_and_write_files_atomically(mk(".batch_fixture_task_ok"), items = list(list(x = 1L)),
      outputs = list(c(primary = "/tmp/x.qs2", secondary = "/tmp/y.qs2")),
      style = "bogus", n_workers = 1L),
    "unknown style"
  )
})

test_that("run_and_write_files_atomically(): `outputs` length must match `items`", {
  expect_error(
    batchit::run_and_write_files_atomically(mk(".batch_fixture_task_ok"),
      items = list(list(x = 1L), list(x = 2L)),
      outputs = list(c(primary = "/tmp/x.qs2", secondary = "/tmp/y.qs2")),
      n_workers = 1L),
    "same length"
  )
})

test_that("run_and_write_files_atomically(): a non-absolute output path is rejected", {
  expect_error(
    batchit::run_and_write_files_atomically(mk(".batch_fixture_task_ok"), items = list(list(x = 1L)),
      outputs = list(c(primary = "relative/path.qs2", secondary = "/tmp/y.qs2")),
      n_workers = 1L),
    "absolute"
  )
})

test_that("run_and_write_files_atomically(): an output path whose parent directory does not exist is rejected", {
  expect_error(
    batchit::run_and_write_files_atomically(mk(".batch_fixture_task_ok"), items = list(list(x = 1L)),
      outputs = list(c(primary = "/no/such/dir/x.qs2", secondary = "/tmp/y.qs2")),
      n_workers = 1L),
    "does not exist"
  )
})

test_that("run_and_write_files_atomically(): an output path that is an existing DIRECTORY is rejected", {
  dir <- withr::local_tempdir()
  expect_error(
    batchit::run_and_write_files_atomically(mk(".batch_fixture_task_ok"), items = list(list(x = 1L)),
      outputs = list(c(primary = dir, secondary = file.path(dir, "y.qs2"))),
      n_workers = 1L),
    "directory"
  )
})

test_that("run_and_write_files_atomically(): output paths colliding ACROSS two items in one call are rejected", {
  dir <- withr::local_tempdir()
  same_path <- file.path(dir, "shared.qs2")
  expect_error(
    batchit::run_and_write_files_atomically(mk(".batch_fixture_task_ok"),
      items = list(list(x = 1L), list(x = 2L)),
      outputs = list(
        c(primary = same_path, secondary = file.path(dir, "s1.qs2")),
        c(primary = file.path(dir, "s2.qs2"), secondary = same_path)
      ),
      n_workers = 1L),
    "collision"
  )
})

test_that("run_and_write_files_atomically(): an item id containing '/' or '\\\\' is rejected (it is interpolated into the marker filename)", {
  dir <- withr::local_tempdir()
  out1 <- file.path(dir, "p.qs2")
  out2 <- file.path(dir, "s.qs2")
  bad_items <- named_list("x/y", list(x = 1L))
  bad_outputs <- named_list("x/y", c(primary = out1, secondary = out2))
  expect_error(
    batchit::run_and_write_files_atomically(mk(".batch_fixture_task_ok"), items = bad_items,
      outputs = bad_outputs, n_workers = 1L),
    "must not contain"
  )
  bad_items2 <- named_list("a\\b", list(x = 1L))
  bad_outputs2 <- named_list("a\\b", c(primary = out1, secondary = out2))
  expect_error(
    batchit::run_and_write_files_atomically(mk(".batch_fixture_task_ok"), items = bad_items2,
      outputs = bad_outputs2, n_workers = 1L),
    "must not contain"
  )
})

test_that("run_and_write_files_atomically(): an empty item list returns an empty list without dispatching", {
  expect_identical(
    batchit::run_and_write_files_atomically(mk(".batch_fixture_task_ok"), items = list(), outputs = list(),
      n_workers = 1L),
    list()
  )
})

test_that("run_and_write_files_atomically(): a given-but-wrong dev_path errors EVEN for an empty workload", {
  expect_error(
    batchit::run_and_write_files_atomically(mk(".batch_fixture_task_ok"), items = list(), outputs = list(),
      n_workers = 1L, dev_path = "/no/such/tree"),
    "does not exist"
  )
})

test_that("run_and_write_files_atomically(): the deprecated `target = ` alias still works (Unit 1/2 shipped it before the fn rename)", {
  skip_if_not(have_tree, "package source tree not available")
  dir <- withr::local_tempdir()
  out1 <- file.path(dir, "alias_primary.qs2")
  out2 <- file.path(dir, "alias_secondary.qs2")
  # The OLD spelling: run_and_write_files_atomically(target = <descriptor>, ...).
  batchit::run_and_write_files_atomically(
    target = mk(".batch_fixture_task_ok"),
    items = named_list("only", list(x = 5L)),
    outputs = named_list("only", c(primary = out1, secondary = out2)),
    n_workers = 1L, dev_path = dev_tree
  )
  expect_identical(qs2::qs_read(out1), 5L)

  # Passing BOTH `fn` and `target` is a clear error, not a silent pick.
  expect_error(
    batchit::run_and_write_files_atomically(
      mk(".batch_fixture_task_ok"), target = mk(".batch_fixture_task_ok"),
      items = named_list("only", list(x = 1L)),
      outputs = named_list("only",
        c(primary = file.path(dir, "b1.qs2"), secondary = file.path(dir, "b2.qs2"))),
      n_workers = 1L, dev_path = dev_tree
    ),
    "do not pass both"
  )
})

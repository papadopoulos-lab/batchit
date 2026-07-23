# run() / run_and_collect() (shape A), tested THROUGH the real process boundary.
#
# Helper tests and dependency demos must not substitute for proving the actual
# parent -> dispatcher -> worker -> cleanup -> completion path. So the end-to-end
# tests here spawn REAL Rscript subprocesses driving the REAL inst/batch_worker.R
# over the REAL envelope codec. They cannot use dev_path = NULL when batchit is
# only source-loaded: the *installed* batchit on the box may lack the batch
# fixtures/symbols, so the worker must load_all() the source tree, which is what
# a consumer's dev workflow does too. (Here runner == consumer == batchit; the
# runner != consumer boundary is proven in test-batch_seam.R.)

dev_tree <- normalizePath(testthat::test_path("..", ".."), mustWork = FALSE)
have_tree <- file.exists(file.path(dev_tree, "DESCRIPTION")) &&
  file.exists(file.path(dev_tree, "inst", "batch_worker.R"))

mk <- function(sym) batchit::package_function("batchit", sym)

# The CURRENT protocol number, read dynamically rather than hardcoded: every
# raw envelope literal below must carry a protocol that actually matches
# .BATCH_PROTOCOL, or a test would start failing for the WRONG reason (a
# protocol mismatch) the moment the number is bumped, instead of exercising
# what it claims to test.
PROTO <- batchit:::.BATCH_PROTOCOL

# --- target descriptor -------------------------------------------------------

test_that("package_function() records the srcref-stripped identity hash", {
  tgt <- mk(".batch_fixture_echo")
  fn <- batchit:::.batch_fixture_echo
  # the hash is .batch_hash_function() of the SOURCE-STRIPPED function (see below)
  expect_identical(tgt$hash, batchit:::.batch_hash_function(utils::removeSource(fn)))
  expect_identical(tgt$formal_names, "x")
  expect_s3_class(tgt, "package_function")
})

test_that("package_function()'s identity hash is srcref-independent (the R CMD check keep.source bug)", {
  # CI caught this where local tests could not: under R CMD check the PARENT runs
  # the installed package (srcref stripped) while the worker devtools::load_all()s
  # the source (srcref attached), so `.batch_hash_function(fn)` -- which serialises
  # the body INCLUDING its srcref -- produced two different hashes for identical
  # code, and every dispatched item "resolved to a DIFFERENT code version".
  # Identity must depend only on body + formals, so package_function hashes
  # removeSource(fn).
  code <- "function(a, b = 2) { # a comment\n  a + b\n}"
  f_src   <- eval(parse(text = code, keep.source = TRUE))
  f_nosrc <- eval(parse(text = code, keep.source = FALSE))
  expect_false(is.null(attr(body(f_src), "srcref")))    # precondition: has srcref
  expect_true(is.null(attr(body(f_nosrc), "srcref")))
  # the two loadings hash the SAME after source-stripping (they must not disagree)
  expect_identical(
    batchit:::.batch_hash_function(utils::removeSource(f_src)),
    batchit:::.batch_hash_function(utils::removeSource(f_nosrc)))
  # and `.batch_hash_function(fn)` WITHOUT stripping differs -- the bug the fix removes
  expect_false(identical(
    batchit:::.batch_hash_function(f_src),
    batchit:::.batch_hash_function(f_nosrc)))
})

test_that("package_function() normalises a zero-argument target to character(0)", {
  # names(formals(fn)) is NULL for a no-arg function; if that NULL reaches the
  # descriptor a legitimate target looks malformed and run_and_collect() rejects it.
  tgt <- mk(".batch_fixture_pid")
  expect_identical(tgt$formal_names, character(0))
})

test_that("package_function() rejects a `...` target, a non-function, and a missing symbol", {
  # `...` defeats reliable typo detection -- the whole point of the contract.
  expect_error(mk("paste"), "`\\.\\.\\.`|not defined")  # paste is base, not batchit
  expect_error(batchit::package_function("batchit", ".BATCH_PROTOCOL"), "not a function")
  expect_error(mk(".no_such_symbol_here"), "not defined in package")
  expect_error(batchit::package_function("no.such.pkg", "x"), "not available")
})

test_that("a real `...`-taking target is rejected by name", {
  # message() takes `...`; wrap it as a base symbol to hit the dots branch.
  expect_error(batchit::package_function("base", "message"), "`\\.\\.\\.`")
})

# --- parent-side validation (every item, every formal) -----------------------

test_that(".batch_validate_item() enforces the full item contract", {
  tgt <- mk(".batch_fixture_echo")  # one formal: x
  expect_true(batchit:::.batch_validate_item(tgt, list(x = 1L)))

  # missing formal (the dropped-optional-argument shape): a default is no excuse
  expect_error(batchit:::.batch_validate_item(tgt, list()), "not supplied")
  # extra name that is not a formal -- a typo must be caught, not ignored
  expect_error(batchit:::.batch_validate_item(tgt, list(x = 1L, y = 2L)),
    "not formals")
  # positional (unnamed) argument
  expect_error(batchit:::.batch_validate_item(tgt, list(1L)), "must be named")
  # duplicate name
  bad <- list(1L, 2L); names(bad) <- c("x", "x")
  expect_error(batchit:::.batch_validate_item(tgt, bad), "duplicate")
  # not a list at all
  expect_error(batchit:::.batch_validate_item(tgt, 1L), "must be a list")
})

test_that("run_and_collect() validates EVERY item, not just the first", {
  skip_if_not(have_tree, "package source tree not available")
  tgt <- mk(".batch_fixture_echo")
  # first item is valid, second is missing its formal: must be rejected before
  # any subprocess is launched (heterogeneous schemas hide behind a good first).
  expect_error(
    batchit::run_and_collect(tgt, items = list(list(x = 1L), list()),
      n_workers = 1L, dev_path = dev_tree),
    "not supplied"
  )
})

# --- private codec -----------------------------------------------------------

test_that("the envelope codec round-trips and does NOT run any post-read hook", {
  # .batch_read_envelope must be plain qs2 transport: any R6/duck-typed post-read
  # hook is consumer persistence policy, not generic IPC, and an envelope is
  # always a plain list. Prove no hook fires by planting a check_version member
  # that would error if invoked.
  tmp <- withr::local_tempfile(fileext = ".qs2")
  poison <- list2env(list(
    check_version = function() stop("check_version must NOT run in the codec")
  ))
  batchit:::.batch_write_envelope(list(a = 1L, env = poison), tmp)
  expect_silent(got <- batchit:::.batch_read_envelope(tmp))
  expect_identical(got$a, 1L)
})

# --- end-to-end through a real subprocess ------------------------------------

test_that("run_and_collect() drives the real worker end-to-end and preserves order", {
  skip_if_not(have_tree, "package source tree not available")
  r <- batchit::run_and_collect(
    mk(".batch_fixture_echo"),
    items = list(list(x = "a"), list(x = 2L), list(x = c(3, 4, 5))),
    n_workers = 2L, dev_path = dev_tree
  )
  expect_identical(r, list("a", 2L, c(3, 4, 5)))
})

test_that("a NULL result is PRESERVED in place, not dropped (results[idx] <- list())", {
  # `results[[idx]] <- NULL` deletes the element; but with in-order (single-worker)
  # completion the very next item extends the list back and MASKS the bug. It only
  # manifests when the NULL item finishes AFTER a higher-indexed item has filled
  # its slot. So: item 2 (returns NULL) sleeps; items 1 and 3 are instant; two
  # workers -> item 3 completes and fills slot 3 while item 2 is still sleeping,
  # then item 2's NULL is assigned last. Under the bug that deletes slot 2 and the
  # result is length 2.
  skip_if_not(have_tree, "package source tree not available")
  r <- batchit::run_and_collect(
    mk(".batch_fixture_slow_echo"),
    items = list(
      list(x = 1L,   seconds = 0),
      list(x = NULL, seconds = 8),
      list(x = 3L,   seconds = 0)
    ),
    n_workers = 2L, dev_path = dev_tree
  )
  expect_length(r, 3L)
  expect_identical(r[[1]], 1L)
  expect_null(r[[2]])
  expect_identical(r[[3]], 3L)
})

test_that("a target error returns a STRUCTURED error envelope (exit 0), surfaced by message", {
  skip_if_not(have_tree, "package source tree not available")
  expect_error(
    batchit::run_and_collect(mk(".batch_fixture_boom"),
      items = list(list(message = "kaboom-XYZ")),
      n_workers = 1L, dev_path = dev_tree),
    "kaboom-XYZ"
  )
})

test_that("a worker that dies WITHOUT an envelope is caught by the exit-code channel", {
  skip_if_not(have_tree, "package source tree not available")
  # .batch_fixture_crash quit(status=3) mid-execute -- no error condition, no
  # result envelope. The structured-error channel cannot see this; the exit-code
  # channel must.
  expect_error(
    batchit::run_and_collect(mk(".batch_fixture_crash"),
      items = list(list()), n_workers = 1L, dev_path = dev_tree),
    "exited 3 before writing a result"
  )
})

test_that("the child refuses a target whose code differs from what the parent hashed", {
  skip_if_not(have_tree, "package source tree not available")
  bad <- mk(".batch_fixture_echo")
  bad$hash <- "deadbeefdeadbeef"  # a hash the child cannot reproduce
  expect_error(
    batchit::run_and_collect(bad, items = list(list(x = 1L)),
      n_workers = 1L, dev_path = dev_tree),
    "DIFFERENT code version"
  )
})

test_that("each item runs in a FRESH process (the memory strategy, not an accident)", {
  skip_if_not(have_tree, "package source tree not available")
  pids <- batchit::run_and_collect(mk(".batch_fixture_pid"),
    items = list(list(), list(), list()), n_workers = 1L, dev_path = dev_tree)
  expect_length(unique(unlist(pids)), 3L)
})

test_that("a per-item timeout kills a runaway worker and reports it", {
  skip_if_not(have_tree, "package source tree not available")
  t0 <- Sys.time()
  expect_error(
    batchit::run_and_collect(mk(".batch_fixture_sleep"),
      items = list(list(seconds = 60)),
      n_workers = 1L, dev_path = dev_tree, timeout = 2),
    "timeout"
  )
  # it must not actually wait 60s
  expect_lt(as.numeric(difftime(Sys.time(), t0, units = "secs")), 30)
})

test_that("run() reports status but returns no values", {
  skip_if_not(have_tree, "package source tree not available")
  # success path: no error, invisible(NULL)
  out <- batchit::run(mk(".batch_fixture_echo"),
    items = list(list(x = 1L)), n_workers = 1L, dev_path = dev_tree)
  expect_null(out)
  # and a failure is STILL surfaced even though no value is collected
  expect_error(
    batchit::run(mk(".batch_fixture_boom"),
      items = list(list(message = "still-loud")),
      n_workers = 1L, dev_path = dev_tree),
    "still-loud"
  )
})

test_that("run_and_collect() leaves no temp input/output/log files behind", {
  skip_if_not(have_tree, "package source tree not available")
  before <- list.files(tempdir(), pattern = "^batch_(in|out|log)_")
  batchit::run_and_collect(mk(".batch_fixture_echo"),
    items = list(list(x = 1L), list(x = 2L)), n_workers = 2L, dev_path = dev_tree)
  after <- list.files(tempdir(), pattern = "^batch_(in|out|log)_")
  expect_identical(sort(after), sort(before))
})

test_that("a FAILING run also leaves no temp files behind", {
  skip_if_not(have_tree, "package source tree not available")
  before <- list.files(tempdir(), pattern = "^batch_(in|out|log)_")
  expect_error(
    batchit::run_and_collect(mk(".batch_fixture_boom"),
      items = list(list(message = "x")), n_workers = 1L, dev_path = dev_tree),
    "returned an error")
  after <- list.files(tempdir(), pattern = "^batch_(in|out|log)_")
  expect_identical(sort(after), sort(before))
})

# --- envelope + result validation (now load-bearing, not decorative) ---------

test_that(".batch_check_envelope() rejects malformed input envelopes", {
  good <- list(protocol = PROTO, meta = list(fn_kind = "package", package = "batchit",
    symbol = "s", hash = "h", id = "1", runner_package = "batchit", collect = TRUE),
    args = list())
  expect_true(batchit:::.batch_check_envelope(good))
  expect_error(batchit:::.batch_check_envelope(42), "not a list")
  expect_error(batchit:::.batch_check_envelope(within(good, protocol <- 99L)),
    "protocol mismatch")
  expect_error(batchit:::.batch_check_envelope(within(good, meta <- NULL)), "no meta")
  bad_pkg <- good; bad_pkg$meta$package <- NA_character_
  expect_error(batchit:::.batch_check_envelope(bad_pkg), "package")
  bad_col <- good; bad_col$meta$collect <- "yes"
  expect_error(batchit:::.batch_check_envelope(bad_col), "collect")
})

test_that(".batch_check_envelope() REQUIRES a non-empty runner_package", {
  # runner_package is the field that carries the runner-vs-consumer split; if the
  # checker omits it, a malformed envelope with no runner_package passes the shared
  # structural gate and the worker falls back to the CONSUMER namespace for
  # .batch_execute -- exactly the runner/consumer confusion the seam must prevent.
  good <- list(protocol = PROTO, meta = list(fn_kind = "package", package = "batchit",
    symbol = "s", hash = "h", id = "1", runner_package = "batchit", collect = TRUE),
    args = list())
  expect_true(batchit:::.batch_check_envelope(good))
  # absent
  no_rp <- good; no_rp$meta$runner_package <- NULL
  expect_error(batchit:::.batch_check_envelope(no_rp), "runner_package")
  # empty string
  empty_rp <- good; empty_rp$meta$runner_package <- ""
  expect_error(batchit:::.batch_check_envelope(empty_rp), "runner_package")
  # NA
  na_rp <- good; na_rp$meta$runner_package <- NA_character_
  expect_error(batchit:::.batch_check_envelope(na_rp), "runner_package")
})

test_that(".batch_check_envelope() REQUIRES a valid meta$fn_kind (Phase 6' Unit 1/3)", {
  good <- list(protocol = PROTO, meta = list(fn_kind = "package", package = "batchit",
    symbol = "s", hash = "h", id = "1", runner_package = "batchit", collect = TRUE),
    args = list())
  expect_true(batchit:::.batch_check_envelope(good))
  # missing
  no_fk <- good; no_fk$meta$fn_kind <- NULL
  expect_error(batchit:::.batch_check_envelope(no_fk), "fn_kind")
  # invalid value
  bad_fk <- good; bad_fk$meta$fn_kind <- "bogus"
  expect_error(batchit:::.batch_check_envelope(bad_fk), "fn_kind")
  # "adhoc" is a structurally valid enum value, but (Phase 6' Unit 3) it needs
  # its OWN shape -- fn/nonce present, package/symbol/hash ABSENT -- not the
  # package envelope with fn_kind merely flipped (package/symbol/hash still
  # present is now correctly rejected; see the dedicated adhoc envelope tests
  # in test-batch_adhoc.R).
  adhoc <- list(protocol = PROTO, meta = list(fn_kind = "adhoc", fn = function(x) x,
    nonce = "tok", id = "1", runner_package = "batchit", collect = TRUE),
    args = list())
  expect_true(batchit:::.batch_check_envelope(adhoc))
  adhoc_with_package <- good; adhoc_with_package$meta$fn_kind <- "adhoc"
  expect_error(batchit:::.batch_check_envelope(adhoc_with_package), "forbidden")
})

test_that(".batch_check_envelope() rejects an unknown meta field", {
  good <- list(protocol = PROTO, meta = list(fn_kind = "package", package = "batchit",
    symbol = "s", hash = "h", id = "1", runner_package = "batchit", collect = TRUE),
    args = list())
  bogus <- good
  bogus$meta$totally_unexpected_field <- "x"
  expect_error(batchit:::.batch_check_envelope(bogus), "unknown field")
})

test_that(".batch_check_envelope() rejects an unknown TOP-LEVEL envelope field", {
  good <- list(protocol = PROTO, meta = list(fn_kind = "package", package = "batchit",
    symbol = "s", hash = "h", id = "1", runner_package = "batchit", collect = TRUE),
    args = list())
  expect_true(batchit:::.batch_check_envelope(good))
  bogus <- good
  bogus$unexpected <- "smuggled"
  expect_error(batchit:::.batch_check_envelope(bogus), "unknown top-level field")
})

test_that(".batch_check_envelope() enforces the outputs<->style/marker/attempt/collect exclusivity", {
  base_meta <- list(fn_kind = "package", package = "batchit", symbol = "s",
    hash = "h", id = "1", runner_package = "batchit")
  # outputs present -> collect forbidden
  with_outputs <- list(protocol = PROTO, meta = c(base_meta, list(
    outputs = c(a = "/tmp/a.qs2"), marker = "/tmp/.batchit__1", style = "return",
    attempt = "tok", collect = TRUE)), args = list())
  expect_error(batchit:::.batch_check_envelope(with_outputs), "collect")
  # outputs present, collect absent, style/marker/attempt present -> ok
  ok_task <- list(protocol = PROTO, meta = c(base_meta, list(
    outputs = c(a = "/tmp/a.qs2"), marker = "/tmp/.batchit__1", style = "return",
    attempt = "tok")), args = list())
  expect_true(batchit:::.batch_check_envelope(ok_task))
  # outputs ABSENT -> style/marker/attempt forbidden
  with_style_no_outputs <- list(protocol = PROTO, meta = c(base_meta, list(
    collect = TRUE, style = "return")), args = list())
  expect_error(batchit:::.batch_check_envelope(with_style_no_outputs),
    "style/marker/attempt are forbidden")
})

test_that(".batch_check_envelope() re-validates output/marker PATH SHAPE on the child side (not just structural presence)", {
  # The child MAY replay independently of the parent, so it must re-validate
  # what the parent already checked at dispatch time -- not merely trust that
  # the envelope carries well-typed strings. These reuse
  # .batch_validate_output_paths()'s conservative rules (absolute, already
  # normalized, parent dir exists, destination absent/regular-non-symlink).
  base_meta <- function(extra) {
    c(list(fn_kind = "package", package = "batchit", symbol = "s", hash = "h",
      id = "1", runner_package = "batchit", style = "return",
      attempt = "tok"), extra)
  }
  wrap <- function(meta) list(protocol = PROTO, meta = meta, args = list())

  # non-absolute output path
  rel_out <- wrap(base_meta(list(
    outputs = c(a = "relative/x.qs2"), marker = "/tmp/.batchit__1")))
  expect_error(batchit:::.batch_check_envelope(rel_out), "absolute")

  # output whose PARENT DIRECTORY does not exist
  bad_parent <- wrap(base_meta(list(
    outputs = c(a = "/no/such/dir/x.qs2"), marker = "/tmp/.batchit__1")))
  expect_error(batchit:::.batch_check_envelope(bad_parent), "does not exist")

  # output that is an existing DIRECTORY
  dir <- withr::local_tempdir()
  as_dir <- wrap(base_meta(list(
    outputs = c(a = dir), marker = "/tmp/.batchit__1")))
  expect_error(batchit:::.batch_check_envelope(as_dir), "directory")

  # a path that is absolute but NOT ALREADY in normalizePath() form (contains
  # a `..` segment): the child must reject it rather than silently
  # re-normalize it into a DIFFERENT path than the parent dispatched.
  # normalizePath(mustWork = FALSE) only actually COLLAPSES a `..` segment
  # when the full path already exists on disk (an absent tail is left
  # untouched, literally) -- so the destination must pre-exist for this to
  # actually exercise the divergence.
  file.create(file.path(dir, "x.qs2"))
  unnormalized <- wrap(base_meta(list(
    outputs = c(a = file.path(dir, "..", basename(dir), "x.qs2")),
    marker = "/tmp/.batchit__1")))
  expect_error(batchit:::.batch_check_envelope(unnormalized), "normalized")

  # marker: non-absolute
  rel_marker <- wrap(base_meta(list(
    outputs = c(a = file.path(dir, "x.qs2")), marker = "relative/.batchit__1")))
  expect_error(batchit:::.batch_check_envelope(rel_marker), "absolute")

  # marker: parent directory does not exist
  bad_marker_parent <- wrap(base_meta(list(
    outputs = c(a = file.path(dir, "x.qs2")), marker = "/no/such/dir/.batchit__1")))
  expect_error(batchit:::.batch_check_envelope(bad_marker_parent), "does not exist")

  # a fully valid envelope still passes
  ok <- wrap(base_meta(list(
    outputs = c(a = file.path(dir, "x.qs2")),
    marker = file.path(dir, ".batchit__1"))))
  expect_true(batchit:::.batch_check_envelope(ok))
})

test_that(".batch_check_envelope() accepts \"return\" AND \"staged_writer\", and rejects any OTHER style, BEFORE the target could run", {
  # Phase 6' Units 1-2 implement style = "return" and style = "staged_writer".
  # A bad style must be rejected HERE (structurally, before .batch_execute()
  # ever calls do.call()) -- not only later, deep inside the branch that runs
  # after the target executes.
  dir <- withr::local_tempdir()
  base_meta <- function(style) list(fn_kind = "package", package = "batchit",
    symbol = "s", hash = "h", id = "1", runner_package = "batchit",
    outputs = c(a = file.path(dir, "x.qs2")), marker = file.path(dir, ".batchit__1"),
    style = style, attempt = "tok")
  expect_error(
    batchit:::.batch_check_envelope(list(protocol = PROTO,
      meta = base_meta("bogus_style"), args = list())),
    "not supported")
  expect_true(batchit:::.batch_check_envelope(list(protocol = PROTO,
    meta = base_meta("return"), args = list())))
  expect_true(batchit:::.batch_check_envelope(list(protocol = PROTO,
    meta = base_meta("staged_writer"), args = list())))
})

test_that("a side-effecting target does NOT run when the REAL worker receives a declared-output envelope with an unsupported style", {
  # The production wiring, not just the helper: drive the REAL worker with a
  # style it cannot execute, and prove the target never ran (its side effect
  # -- a file it would write on its own -- must be absent). Before the fix
  # this style check ran INSIDE .batch_execute() AFTER do.call(), so a
  # side-effecting target executed for an envelope that was always going to
  # be rejected.
  skip_if_not(have_tree, "package source tree not available")
  dir <- withr::local_tempdir()
  side_effect_file <- file.path(dir, "SHOULD_NOT_EXIST.txt")
  worker <- file.path(dev_tree, "inst", "batch_worker.R")
  rscript <- file.path(R.home("bin"), "Rscript")
  meta <- list(fn_kind = "package", package = "batchit",
    symbol = ".batch_fixture_side_effect_writer", hash = mk(".batch_fixture_side_effect_writer")$hash,
    id = "1", runner_package = "batchit", dev_path = dev_tree,
    outputs = c(a = file.path(dir, "out.qs2")), marker = file.path(dir, ".batchit__1"),
    style = "bogus_style", attempt = "tok")
  env <- list(protocol = PROTO, meta = meta,
    args = list(path = side_effect_file))
  inp <- withr::local_tempfile(fileext = ".qs2")
  outp <- withr::local_tempfile(fileext = ".qs2")
  errf <- withr::local_tempfile(fileext = ".txt")
  qs2::qs_save(env, inp)

  p <- processx::process$new(rscript, c("--vanilla", worker, inp, outp),
    env = c("current", R_LIBS = paste(.libPaths(), collapse = .Platform$path.sep)),
    stdout = "|", stderr = errf)
  p$wait(timeout = 30000)

  # .batch_check_envelope() runs INSIDE .batch_execute()'s tryCatch (which is
  # TOTAL by design), so an unsupported style is a normal "status = error"
  # result envelope (exit 0), not a worker crash -- the message lives in the
  # result's error$message, not stderr.
  expect_false(file.exists(side_effect_file), info =
    "the target's own side effect exists -- it ran despite an unsupported style")
  expect_true(file.exists(outp))
  res <- batchit:::.batch_read_envelope(outp)
  expect_identical(res$status, "error")
  expect_match(res$error$message, "not supported")
})

test_that(".batch_check_envelope() requires meta$details to be NULL on BOTH dispatch branches", {
  dir <- withr::local_tempdir()
  # return-value branch (outputs absent): details forbidden
  return_meta <- list(fn_kind = "package", package = "batchit", symbol = "s",
    hash = "h", id = "1", runner_package = "batchit", collect = TRUE,
    details = "smuggled")
  expect_error(
    batchit:::.batch_check_envelope(list(protocol = PROTO, meta = return_meta, args = list())),
    "details")
  # declared-output branch: details must be NULL (Unit 1 contract -- reserved
  # for a future opt-in consumer-skip mechanism, design PHASE6_DESIGN.md
  # section 7, not implemented here)
  task_meta <- list(fn_kind = "package", package = "batchit", symbol = "s",
    hash = "h", id = "1", runner_package = "batchit",
    outputs = c(a = file.path(dir, "x.qs2")), marker = file.path(dir, ".batchit__1"),
    style = "return", attempt = "tok", details = "smuggled")
  expect_error(
    batchit:::.batch_check_envelope(list(protocol = PROTO, meta = task_meta, args = list())),
    "details")
})

test_that(".batch_execute() is TOTAL: a malformed envelope yields an error envelope, not a throw", {
  res <- batchit:::.batch_execute(list(protocol = 1L, meta = NULL, args = list()))
  expect_identical(res$status, "error")
  expect_false(is.null(res$error$message))
  # even a non-list env must not throw
  expect_identical(batchit:::.batch_execute(42)$status, "error")
})

test_that(".batch_inspect_result() makes protocol, id and FULL target identity load-bearing, and is total", {
  tgt <- list(package = "batchit", symbol = "s", hash = "H")
  ok <- list(protocol = PROTO, id = "7", status = "ok", value = 99L,
    warnings = character(),
    target = list(package = "batchit", symbol = "s", hash = "H"))
  expect_true(batchit:::.batch_inspect_result(ok, "7", tgt)$ok)
  # TOTAL: a non-list result is a failure REASON, not a throw (so it flows through
  # the caller's uniform failure path instead of crashing the inspector).
  nl <- batchit:::.batch_inspect_result("garbage", "7", tgt)
  expect_false(nl$ok)
  expect_match(nl$reason, "not a list")
  # wrong protocol (PROTO + 1L is guaranteed different from the current protocol,
  # unlike a hardcoded literal that could coincidentally BECOME correct)
  expect_false(batchit:::.batch_inspect_result(within(ok, protocol <- PROTO + 1L), "7", tgt)$ok)
  # error status carries the message
  err <- list(protocol = PROTO, id = "7", status = "error",
    error = list(message = "boom"), warnings = character())
  expect_match(batchit:::.batch_inspect_result(err, "7", tgt)$reason, "boom")
  # id mismatch -- a valid-looking result for the WRONG item is rejected
  expect_false(batchit:::.batch_inspect_result(ok, "8", tgt)$ok)
  # identity is package + symbol + hash, not hash alone: each mismatch rejected
  expect_false(batchit:::.batch_inspect_result(ok, "7",
    list(package = "batchit", symbol = "s", hash = "DIFFERENT"))$ok)
  sym <- batchit:::.batch_inspect_result(ok, "7",
    list(package = "batchit", symbol = "OTHER", hash = "H"))
  expect_false(sym$ok)
  expect_match(sym$reason, "different target")
  expect_false(batchit:::.batch_inspect_result(ok, "7",
    list(package = "other", symbol = "s", hash = "H"))$ok)
  # a success envelope with NO value field is rejected; a legitimate NULL is not
  novalue <- ok
  novalue$value <- NULL
  expect_false(batchit:::.batch_inspect_result(novalue, "7", tgt)$ok)
  null_ok <- list(protocol = PROTO, id = "7", status = "ok", value = NULL,
    warnings = character(),
    target = list(package = "batchit", symbol = "s", hash = "H"))
  expect_true(batchit:::.batch_inspect_result(null_ok, "7", tgt)$ok)
})

test_that("run_and_collect() validates timeout as a scalar, even for empty work", {
  # `collect` is no longer a user-facing parameter (it is now encoded in the
  # function name, run() vs run_and_collect()), so there is no longer a
  # caller-supplied `collect` value to validate here -- .batch_validate_collect()
  # still runs internally, but always against the fixed TRUE/FALSE the
  # frontend itself passes.
  ie <- list(list(x = 1L))
  expect_error(batchit::run_and_collect(mk(".batch_fixture_echo"), ie, 1L,
    dev_path = NULL, timeout = c(1, 2)), "single positive")
  expect_error(batchit::run_and_collect(mk(".batch_fixture_echo"), ie, 1L,
    dev_path = NULL, timeout = NA_real_), "single positive")
  expect_error(batchit::run_and_collect(mk(".batch_fixture_echo"), ie, 1L,
    dev_path = NULL, timeout = -5), "single positive")
  # validated even when there is NO work (no early-return bypass)
  expect_error(batchit::run_and_collect(mk(".batch_fixture_echo"), list(), 1L,
    dev_path = NULL, timeout = -1), "single positive")
})

test_that(".batch_inspect_result() stays total on malformed list fields and is strict on id", {
  tgt <- list(package = "batchit", symbol = "s", hash = "H")
  ok <- list(protocol = PROTO, id = "7", status = "ok", value = 1L,
    warnings = character(),
    target = list(package = "batchit", symbol = "s", hash = "H"))
  # a bare-string `error` (not a list) must not throw while extracting the message
  es <- list(protocol = PROTO, id = "7", status = "error", error = "boom",
    warnings = character())
  expect_false(batchit:::.batch_inspect_result(es, "7", tgt)$ok)
  # a NUMERIC id is rejected (strict identical, no as.character coercion)
  num_id <- ok; num_id$id <- 7L
  expect_false(batchit:::.batch_inspect_result(num_id, "7", tgt)$ok)
  # a non-character `warnings` (e.g. a closure) is DROPPED, not coerced (which
  # would throw), keeping the inspector total
  weird <- ok; weird$warnings <- mean
  rw <- batchit:::.batch_inspect_result(weird, "7", tgt)
  expect_true(rw$ok)
  expect_identical(rw$warnings, character())
  # DUPLICATE critical field names cannot smuggle a bad value behind a good one:
  # `$protocol` would return the first (matching one here); the name check
  # rejects the envelope BEFORE the (duplicated) protocol value is even read.
  dup <- list(protocol = PROTO, protocol = 99L, id = "7", status = "ok", value = 1L,
    warnings = character(),
    target = list(package = "batchit", symbol = "s", hash = "H"))
  d <- batchit:::.batch_inspect_result(dup, "7", tgt)
  expect_false(d$ok)
  expect_match(d$reason, "duplicate field names")
})

test_that(".batch_inspect_result() is total even against a hostile classed object", {
  tgt <- list(package = "batchit", symbol = "s", hash = "H")
  # The inspector reads fields with EXACT `[[`, so the realistic hostile object is
  # one whose `[[` method throws (a `$` method would never be invoked). It must
  # yield a failure REASON, not crash the pool -- the whole inspection is wrapped.
  registerS3method("[[", "batchHostile", function(x, i, ...) stop("hostile [[ access"))
  hostile <- structure(
    list(protocol = PROTO, id = "7", status = "ok"), class = "batchHostile")
  r <- batchit:::.batch_inspect_result(hostile, "7", tgt)
  expect_false(r$ok)
  expect_match(r$reason, "malformed result envelope")

  # even a condition whose OWN conditionMessage() method throws must not escape
  # (the error handler renders the message safely). No throw here == the guarantee.
  registerS3method("[[", "batchHostile2",
    function(x, i, ...) stop(structure(
      class = c("hostCond", "error", "condition"), list(message = "m", call = NULL))))
  registerS3method("conditionMessage", "hostCond",
    function(c) stop("conditionMessage itself throws"))
  hostile2 <- structure(
    list(protocol = PROTO, id = "7", status = "ok"), class = "batchHostile2")
  r2 <- batchit:::.batch_inspect_result(hostile2, "7", tgt)
  expect_false(r2$ok)
  expect_match(r2$reason, "malformed result envelope")
})

test_that(".batch_inspect_result() rejects DUPLICATE names in the nested target too", {
  tgt <- list(package = "batchit", symbol = "s", hash = "H")
  ok <- list(protocol = PROTO, id = "7", status = "ok", value = 1L,
    warnings = character(),
    target = list(package = "batchit", symbol = "s", hash = "H"))
  # `target = list(package="batchit", package="evil", ...)` must not resolve via
  # the first `$package` and leave the executed identity ambiguous.
  dup_tgt <- ok
  dup_tgt$target <- list(package = "batchit", package = "evil", symbol = "s", hash = "H")
  expect_false(batchit:::.batch_inspect_result(dup_tgt, "7", tgt)$ok)
})

test_that(".batch_check_envelope() rejects duplicate outer and meta field names", {
  gm <- list(fn_kind = "package", package = "batchit", symbol = "s", hash = "h",
    id = "1", collect = TRUE)
  expect_error(
    batchit:::.batch_check_envelope(list(protocol = PROTO, protocol = PROTO,
      meta = gm, args = list())),
    "duplicate field names")
  expect_error(
    batchit:::.batch_check_envelope(list(protocol = PROTO,
      meta = c(gm, list(package = "evil")), args = list())),
    "meta has duplicate")
})

test_that("the REAL worker validates envelope structure BEFORE loading any code", {
  # The production wiring, not just the helper: a malformed envelope must be
  # rejected by the standalone worker BEFORE it acts on meta to load code. The
  # envelope has DUPLICATE meta$package AND a dev_path that would fail to load if
  # reached -- so if the worker validated first its stderr says "duplicate field
  # names", and if it loaded first it would mention the bad dev_path. The worker
  # writes NO envelope on a pre-execute failure: it exits non-zero and the
  # structural error goes to stderr. This is the actual caller -> worker boundary
  # through a real subprocess.
  skip_if_not(have_tree, "package source tree not available")
  worker <- file.path(dev_tree, "inst", "batch_worker.R")
  rscript <- file.path(R.home("bin"), "Rscript")
  meta <- list(package = "batchit", package = "batchit",
    symbol = ".batch_fixture_echo", hash = "x", id = "1", collect = TRUE,
    runner_package = "batchit", dev_path = "/nonexistent/would/fail/to/load")
  env <- list(protocol = 1L, meta = meta, args = list(x = 1L))
  inp <- withr::local_tempfile(fileext = ".qs2")
  outp <- withr::local_tempfile(fileext = ".qs2")
  errf <- withr::local_tempfile(fileext = ".txt")
  qs2::qs_save(env, inp)

  p <- processx::process$new(rscript, c("--vanilla", worker, inp, outp),
    env = c("current", R_LIBS = paste(.libPaths(), collapse = .Platform$path.sep)),
    stdout = "|", stderr = errf)
  p$wait(timeout = 30000)

  # failure contract: writes NOTHING, exits non-zero
  expect_false(file.exists(outp))
  expect_false(identical(p$get_exit_status(), 0L))
  err <- paste(readLines(errf, warn = FALSE), collapse = "\n")
  expect_match(err, "duplicate field names")
  # proof it did NOT load first: the error is structural, not about the bad path
  expect_no_match(err, "nonexistent|load_all|devtools")
})

test_that("the REAL worker REQUIRES runner_package -- missing it dies WITHOUT running the target", {
  # runner_package must be REQUIRED at the pre-load structural check, exactly like
  # package/hash/id. This envelope is otherwise a perfectly valid echo dispatch
  # (correct hash, a dev_path that loads) with ONLY meta$runner_package absent.
  # The OLD worker fell back to the consumer package for .batch_execute and ran the
  # target to success (exit 0, output written) -- letting a malformed envelope make
  # the consumer namespace supply .batch_execute. The worker must now reject it
  # BEFORE loading any code: write NOTHING, exit non-zero.
  skip_if_not(have_tree, "package source tree not available")
  worker <- file.path(dev_tree, "inst", "batch_worker.R")
  rscript <- file.path(R.home("bin"), "Rscript")
  meta <- list(package = "batchit", symbol = ".batch_fixture_echo",
    hash = mk(".batch_fixture_echo")$hash, id = "1", collect = TRUE,
    dev_path = dev_tree)  # NOTE: no runner_package
  env <- list(protocol = 1L, meta = meta, args = list(x = "SHOULD-NOT-RUN"))
  inp <- withr::local_tempfile(fileext = ".qs2")
  outp <- withr::local_tempfile(fileext = ".qs2")
  errf <- withr::local_tempfile(fileext = ".txt")
  qs2::qs_save(env, inp)

  p <- processx::process$new(rscript, c("--vanilla", worker, inp, outp),
    env = c("current", R_LIBS = paste(.libPaths(), collapse = .Platform$path.sep)),
    stdout = "|", stderr = errf)
  p$wait(timeout = 30000)

  # failure contract: writes NOTHING, exits non-zero
  expect_false(file.exists(outp))
  expect_false(identical(p$get_exit_status(), 0L))
  err <- paste(readLines(errf, warn = FALSE), collapse = "\n")
  expect_match(err, "runner_package")
  # proof it rejected BEFORE loading: the error is structural, not about dev_path
  expect_no_match(err, "load_all|devtools")
})

test_that("the REAL worker uses EXACT field extraction (no `$` partial-match steering loading)", {
  # `$` partial-matches in R: `meta$dev_path` would resolve a field named
  # `dev_path_payload` when no exact `dev_path` exists. The worker uses exact `[[`,
  # so a noncanonical field cannot steer which code is loaded. Envelope carries
  # `dev_path_payload = "/attacker/tree..."` and NO exact `dev_path`; under `$` the
  # worker would `load_all()` that path -- under `[[` it never consults it. The
  # attacker path must therefore appear NOWHERE across the worker's whole output.
  skip_if_not(have_tree, "package source tree not available")
  worker <- file.path(dev_tree, "inst", "batch_worker.R")
  rscript <- file.path(R.home("bin"), "Rscript")
  meta <- list(dev_path_payload = "/attacker/tree/would/be/loaded",
    fn_kind = "package", package = "batchit", symbol = ".batch_fixture_echo",
    hash = "x", id = "1", collect = TRUE, runner_package = "batchit")
  env <- list(protocol = PROTO, meta = meta, args = list(x = 1L))
  inp <- withr::local_tempfile(fileext = ".qs2")
  outp <- withr::local_tempfile(fileext = ".qs2")
  outf <- withr::local_tempfile(fileext = ".txt")
  errf <- withr::local_tempfile(fileext = ".txt")
  qs2::qs_save(env, inp)

  p <- processx::process$new(rscript, c("--vanilla", worker, inp, outp),
    env = c("current", R_LIBS = paste(.libPaths(), collapse = .Platform$path.sep)),
    stdout = outf, stderr = errf)
  p$wait(timeout = 30000)

  combined <- paste(c(
    readLines(outf, warn = FALSE), readLines(errf, warn = FALSE),
    if (file.exists(outp)) unlist(batchit:::.batch_read_envelope(outp))
  ), collapse = " ")
  expect_no_match(combined, "attacker/tree", fixed = TRUE)
})

test_that("run_and_collect() rejects a non-list `items` container, even when empty", {
  expect_error(batchit::run_and_collect(mk(".batch_fixture_echo"), character(0), 1L,
    dev_path = NULL), "must be a list")
  expect_error(batchit::run_and_collect(mk(".batch_fixture_echo"), 1:3, 1L,
    dev_path = NULL), "must be a list")
})

# --- warnings, memory, ids, empty-workload validation ------------------------

test_that("a successful target's warnings are surfaced in the parent, tagged by id", {
  skip_if_not(have_tree, "package source tree not available")
  expect_warning(
    batchit::run_and_collect(mk(".batch_fixture_warn"),
      items = list(only = list(x = "WOT")), n_workers = 1L, dev_path = dev_tree),
    "\\[batch item 'only'\\].*WOT"
  )
})

test_that("collect = FALSE drops the target value before it enters the envelope", {
  # The shape-A memory guarantee, tested at the executor: a large return must not
  # be carried back when collect = FALSE.
  env <- list(protocol = PROTO, meta = list(fn_kind = "package", package = "batchit",
    symbol = ".batch_fixture_big", version = "0",
    hash = mk(".batch_fixture_big")$hash, dev_path = NULL,
    runner_package = "batchit", id = "1", collect = FALSE),
    args = list(n = 1e6))
  res <- batchit:::.batch_execute(env)
  expect_identical(res$status, "ok")
  expect_null(res$value)
  # with collect = TRUE the same call DOES carry the value (control)
  env$meta$collect <- TRUE
  expect_length(batchit:::.batch_execute(env)$value, 1e6)
})

test_that("a given-but-wrong dev_path errors EVEN for an empty workload", {
  # An early return must not skip input validation.
  expect_error(
    batchit::run_and_collect(mk(".batch_fixture_echo"), items = list(),
      n_workers = 1L, dev_path = "/no/such/tree"),
    "does not exist")
})

test_that(".batch_validate_dev_path() REJECTS an installed package as a dev tree", {
  # Runner-level guard: a dev_path that resolves to an INSTALLED layout
  # (Meta/package.rds; DESCRIPTION naming the consumer, so it clears the name
  # check) must error, never limp. This is the R CMD check shape -- a dev-path
  # probe handing back .Rcheck/<pkg> -- caught at the runner boundary even if a
  # caller's probe misfires. It has NO inst/ subdir (install promotes inst/* to
  # the root), so proceeding would fail deeper with a confusing "load_all source
  # absent" instead of this clear message.
  installed <- file.path(withr::local_tempdir(), "batchit")
  dir.create(file.path(installed, "Meta"), recursive = TRUE)
  saveRDS(list(), file.path(installed, "Meta", "package.rds"))
  writeLines("Package: batchit", file.path(installed, "DESCRIPTION"))
  expect_error(
    batchit:::.batch_validate_dev_path(installed, "batchit"),
    "installed package")
})

test_that(".batch_validate_dev_path() accepts a real source tree unchanged", {
  # The converse of the guard above: a DESCRIPTION-carrying source tree with no
  # Meta/package.rds is returned normalised, so the rejection cannot regress into
  # rejecting legitimate dev trees.
  src <- file.path(withr::local_tempdir(), "batchit")
  dir.create(src, recursive = TRUE)
  writeLines("Package: batchit", file.path(src, "DESCRIPTION"))
  expect_identical(
    batchit:::.batch_validate_dev_path(src, "batchit"),
    normalizePath(src, mustWork = FALSE))
})

test_that("duplicate item ids are rejected", {
  # dev_path = NULL (not dev_tree): this errors during id validation, before any
  # dispatch, and NULL is always valid.
  bad <- list(list(x = 1L), list(x = 2L))
  names(bad) <- c("dup", "dup")
  expect_error(
    batchit::run_and_collect(mk(".batch_fixture_echo"), items = bad,
      n_workers = 1L, dev_path = NULL),
    "not unique")
})

# `slurm_status()` runs `squeue` and `sacct`. Nothing here needs Slurm.
#
# Every block builds its `PATH` with `slurm_stub_path()` from
# `helper-slurm-stubs.R`. That helper refuses every scheduler command a block
# left unstubbed, so a block cannot reach the host. Read the top of that file
# for what the guard does not cover.
#
# WHAT THESE BLOCKS DO NOT PROVE. A stub answers with text this file wrote.
# They say nothing about the output a real `squeue` or `sacct` writes, nor
# about which jobs a real accounting database holds. The measurement against
# Slurm 25.11.2 lives in the report of the change that added this function.

# The stub `PATH`, live until the calling block returns.
#
# The two defaults print nothing and exit 0, which is a scheduler that answers
# and holds no job. A block overrides the one it is about.
local_scheduler <- function(
  squeue = slurm_stub_fixed(""),
  sacct = slurm_stub_fixed(""),
  envir = parent.frame()
) {
  dir <- withr::local_tempdir(.local_envir = envir)
  withr::local_envvar(
    PATH = slurm_stub_path(dir, list(squeue = squeue, sacct = sacct)),
    .local_envir = envir
  )
  return(invisible(dir))
}

# One `squeue` line. The order is the `-o` format `slurm_status()` asks for.
squeue_row <- function(job_id, user, name, state, elapsed, reason) {
  return(paste(job_id, user, name, state, elapsed, reason, sep = "|"))
}

# One `sacct` line. The order is the `--format=` `slurm_status()` asks for, and
# it is NOT the `squeue` order: the exit code sits where the elapsed time sits
# above.
sacct_row <- function(job_id, user, name, state, exit_code, elapsed) {
  return(paste(job_id, user, name, state, exit_code, elapsed, sep = "|"))
}

# Join lines into the one string `slurm_stub_fixed()` takes.
rows <- function(...) {
  return(paste(c(...), collapse = "\n"))
}

# The body of a stub that records its own arguments, one per line, and then
# answers like `slurm_stub_fixed()`.
stub_recording <- function(argfile, out = "") {
  return(c(
    paste0("printf '%s\\n' \"$@\" > ", shQuote(argfile, type = "sh")),
    slurm_stub_fixed(out)
  ))
}

# The body of a `sacct` stub that answers only when it is given `-S`.
#
# This is the real defect, mimicked. `sacct` with no `-S` reports the jobs that
# started today and exits 0, so a chain that started earlier comes back empty
# and never errors. A block that drives this stub goes red if `slurm_status()`
# drops the flag.
stub_sacct_needs_start <- function(out) {
  return(c(
    "batchit_has_start=",
    "for batchit_arg in \"$@\"; do",
    "  if [ \"$batchit_arg\" = '-S' ]; then batchit_has_start=1; fi",
    "done",
    "if [ -z \"$batchit_has_start\" ]; then exit 0; fi",
    slurm_stub_fixed(out)
  ))
}

# The body of a `sacct` stub that honours `-j`, and ignores every other query.
#
# The real `sacct` returns the jobs its query names. This one holds several
# rows. Given `-j`, it prints the rows whose job id that flag lists. Given no
# `-j`, it prints every row it holds, which is what a name query returns: every
# run that ever carried the name, whichever chain made it.
stub_sacct_by_id <- function(out) {
  return(c(
    "batchit_ids=",
    "batchit_next=",
    "for batchit_arg in \"$@\"; do",
    "  if [ -n \"$batchit_next\" ]; then",
    "    batchit_ids=\"$batchit_arg\"",
    "    batchit_next=",
    "    continue",
    "  fi",
    "  if [ \"$batchit_arg\" = '-j' ]; then batchit_next=1; fi",
    "done",
    paste0(
      "printf '%s\\n' ",
      shQuote(out, type = "sh"),
      " | while IFS= read -r batchit_line; do"
    ),
    "  batchit_id=\"${batchit_line%%|*}\"",
    "  if [ -z \"$batchit_ids\" ]; then",
    "    printf '%s\\n' \"$batchit_line\"",
    "    continue",
    "  fi",
    "  case \",$batchit_ids,\" in",
    "    *\",$batchit_id,\"*) printf '%s\\n' \"$batchit_line\" ;;",
    "  esac",
    "done",
    "exit 0"
  ))
}

# Read one flag's value out of a recorded argument list.
stub_arg_after <- function(args, flag) {
  at <- which(args == flag)
  testthat::expect_length(at, 1L)
  return(args[[at + 1L]])
}

# The message of the error a call raises, or a failure when it raises none.
status_error <- function(expr) {
  msg <- tryCatch(
    {
      force(expr)
      NA_character_
    },
    error = function(e) conditionMessage(e)
  )
  testthat::expect_false(is.na(msg))
  return(msg)
}

# Write a chain of `job_names` into `dir` and return the job paths.
write_chain <- function(dir, job_names) {
  jobs <- lapply(job_names, function(name) {
    return(batchit::slurm_it(
      script = "true",
      name = name,
      cpus = 2,
      mem = "1G",
      time = "01:00:00"
    ))
  })
  return(batchit::slurm_write(jobs, dir))
}

# --- 1. the overview unions the two sources -----------------------------------

test_that("slurm_status() unions the live queue and the accounting database", {
  local_scheduler(
    squeue = slurm_stub_fixed(
      squeue_row("90", "alice", "proj_s1", "PENDING", "0:00", "Resources")
    ),
    sacct = slurm_stub_fixed(rows(
      sacct_row("16", "bob", "nftest", "COMPLETED", "0:0", "00:00:01"),
      sacct_row("17", "bob", "envdump", "FAILED", "1:0", "00:10:00")
    ))
  )
  x <- batchit::slurm_status()

  expect_s3_class(x, "data.frame")
  expect_identical(
    names(x),
    c("job_id", "user", "name", "state", "exit_code", "elapsed", "reason")
  )
  # The live row first, then the two the accounting database adds.
  expect_identical(x[["job_id"]], c("90", "16", "17"))
  expect_identical(x[["user"]], c("alice", "bob", "bob"))
  expect_identical(x[["name"]], c("proj_s1", "nftest", "envdump"))
  expect_identical(x[["state"]], c("PENDING", "COMPLETED", "FAILED"))
  # `squeue` reports no exit code, and `sacct` reports no reason.
  expect_identical(x[["exit_code"]], c(NA, "0:0", "1:0"))
  expect_identical(x[["elapsed"]], c("0:00", "00:00:01", "00:10:00"))
  expect_identical(x[["reason"]], c("Resources", NA, NA))
})

test_that("slurm_status() reports a live job the accounting query missed", {
  # Two queries against two stores can disagree. A row that only `squeue`
  # returns MUST still reach the caller. A function that intersected the two
  # would report a shorter queue than the scheduler holds.
  local_scheduler(
    squeue = slurm_stub_fixed(
      squeue_row("91", "alice", "proj_s2", "PENDING", "0:00", "Dependency")
    )
  )
  x <- batchit::slurm_status()
  expect_identical(x[["job_id"]], "91")
  expect_identical(x[["reason"]], "Dependency")
})

# --- 2. a job in both sources appears once, and takes the live row ------------

test_that("a job in both sources appears once and takes the squeue row", {
  # Job 90 is RUNNING, so both commands report it. Three fields separate the
  # two rows: the reason, the exit code and the elapsed time. A result that
  # took the `sacct` row would lose the reason, which is the column the live
  # source exists for.
  local_scheduler(
    squeue = slurm_stub_fixed(
      squeue_row("90", "alice", "proj_s1", "RUNNING", "00:05:00", "None")
    ),
    sacct = slurm_stub_fixed(rows(
      sacct_row("90", "alice", "proj_s1", "RUNNING", "0:0", "00:05:22"),
      sacct_row("16", "bob", "nftest", "COMPLETED", "0:0", "00:00:01")
    ))
  )
  x <- batchit::slurm_status()

  expect_identical(nrow(x), 2L)
  expect_identical(x[["job_id"]], c("90", "16"))
  expect_identical(x[["reason"]], c("None", NA))
  expect_identical(x[["exit_code"]], c(NA, "0:0"))
  expect_identical(x[["elapsed"]], c("00:05:00", "00:00:01"))
})

# --- 3. `sacct` is always given `-S` ------------------------------------------

test_that("slurm_status() gives sacct a start time, so a chain is visible", {
  # The stub answers only when it sees `-S`. A `slurm_status()` that dropped
  # the flag would come back empty here, and an empty result reads as
  # "nothing is running".
  local_scheduler(
    sacct = stub_sacct_needs_start(
      sacct_row("16", "bob", "nftest", "COMPLETED", "0:0", "00:00:01")
    )
  )
  x <- batchit::slurm_status()
  expect_identical(x[["job_id"]], "16")
})

test_that("the overview asks the accounting database for the last 7 days", {
  tmp <- withr::local_tempdir()
  argfile <- file.path(tmp, "sacct-args")
  local_scheduler(sacct = stub_recording(argfile))
  batchit::slurm_status()

  args <- readLines(argfile)
  expect_true("-S" %in% args)
  expect_identical(args[[which(args == "-S") + 1L]], "now-7days")
  # `-X` keeps a job step from adding a second row for one job.
  expect_true("-X" %in% args)
})

# --- 4. an unanswerable scheduler is an error, never an empty result ----------

test_that("a failing sacct raises an error that names the command", {
  local_scheduler(
    sacct = c(
      "printf 'sacct: error: Problem talking to the database\\n' >&2",
      "exit 1"
    )
  )
  msg <- status_error(batchit::slurm_status())
  expect_match(msg, "slurm_status():", fixed = TRUE)
  expect_match(msg, "sacct", fixed = TRUE)
  expect_match(msg, "exited 1", fixed = TRUE)
  # The command's own message travels with it, because that text holds the
  # diagnosis.
  expect_match(msg, "Problem talking to the database", fixed = TRUE)
})

test_that("a failing squeue raises an error that names the command", {
  local_scheduler(
    squeue = c(
      "printf 'squeue: error: Unable to contact slurm controller\\n' >&2",
      "exit 1"
    )
  )
  msg <- status_error(batchit::slurm_status())
  expect_match(msg, "squeue", fixed = TRUE)
  expect_match(msg, "exited 1", fixed = TRUE)
  expect_match(msg, "Unable to contact slurm controller", fixed = TRUE)
})

test_that("an absent sacct raises an error rather than reporting no jobs", {
  # A `PATH` that holds `squeue` and nothing else. This is the machine with no
  # Slurm, and a zero-row answer there would read as a quiet queue.
  dir <- withr::local_tempdir()
  slurm_stub_write(dir, "squeue", slurm_stub_fixed(""))
  withr::local_envvar(PATH = dir)

  msg <- status_error(batchit::slurm_status())
  expect_match(msg, "`sacct` is not on the PATH", fixed = TRUE)
  expect_match(msg, "no jobs", fixed = TRUE)
})

test_that("a line the parser cannot read raises an error", {
  local_scheduler(sacct = slurm_stub_fixed("16|ricwh321|nftest"))
  msg <- status_error(batchit::slurm_status())
  expect_match(msg, "cannot read", fixed = TRUE)
  expect_match(msg, "MUST hold 6 fields", fixed = TRUE)
  expect_match(msg, "Line 1 holds 3", fixed = TRUE)
  expect_match(msg, "16|ricwh321|nftest", fixed = TRUE)
})

# --- 5. an empty window is not an error --------------------------------------

test_that("an empty window returns zero rows and every column", {
  # Both stubs answer and hold no job. `x$state` on this result MUST be
  # character(0), so a caller can subset it without a guard.
  local_scheduler()
  x <- batchit::slurm_status()

  expect_s3_class(x, "data.frame")
  expect_identical(nrow(x), 0L)
  expect_identical(
    names(x),
    c("job_id", "user", "name", "state", "exit_code", "elapsed", "reason")
  )
  expect_identical(x[["state"]], character(0))
  expect_identical(x[["reason"]], character(0))
  expect_true(all(vapply(x, is.character, logical(1))))
})

test_that("an empty last field reaches the caller as an empty string", {
  # `strsplit()` drops a trailing empty field. A line ending in the separator
  # would otherwise look short, and the call would refuse output it can
  # read.
  local_scheduler(
    squeue = slurm_stub_fixed(
      squeue_row("90", "alice", "proj_s1", "PENDING", "0:00", "")
    )
  )
  x <- batchit::slurm_status()
  expect_identical(nrow(x), 1L)
  expect_identical(x[["reason"]], "")
})

# --- 6. the directory form ----------------------------------------------------

test_that("the directory form reads the job names from *.sh, not submit.sh", {
  # The names reach `squeue`, which is the source that sees a job before it
  # starts. `sacct` is asked for job ids instead, and section 7 drives that.
  tmp <- withr::local_tempdir()
  chain <- file.path(tmp, "chain")
  write_chain(chain, c("proj_s1", "proj_s2"))
  argfile <- file.path(tmp, "squeue-args")

  local_scheduler(squeue = stub_recording(argfile))
  batchit::slurm_status(chain)

  args <- readLines(argfile)
  expect_true("--name=proj_s1,proj_s2" %in% args)
  # `submit.sh` is the driver. It names no job, and `squeue --name=submit`
  # would match a job somebody else called `submit`.
  expect_false(any(grepl("submit", args, fixed = TRUE)))
})

test_that("the directory form starts the window at the oldest .sh mtime", {
  # Not a constant, and not today. The chain's own scripts say when it was
  # written, and that is the only date left once the submitting session ends.
  tmp <- withr::local_tempdir()
  chain <- file.path(tmp, "chain")
  paths <- write_chain(chain, c("proj_s1", "proj_s2"))
  # One job started, so the chain has a job id to ask the database for.
  writeLines("done", file.path(chain, "proj_s1_41.out"))
  written <- as.POSIXct("2026-08-01 09:15:00", tz = "")
  Sys.setFileTime(paths[[1]], written)
  argfile <- file.path(tmp, "sacct-args")

  local_scheduler(sacct = stub_recording(argfile))
  batchit::slurm_status(chain)

  args <- readLines(argfile)
  expect_true("-S" %in% args)
  expect_identical(
    stub_arg_after(args, "-S"),
    format(written, "%Y-%m-%dT%H:%M:%S")
  )
})

test_that("a log older than the scripts moves the window back to that log", {
  # A chain rewritten after it ran carries new script times and old logs. A
  # window that started at the newest script would hide the run those logs
  # name, and `sacct` reports an empty window rather than an error.
  tmp <- withr::local_tempdir()
  chain <- file.path(tmp, "chain")
  write_chain(chain, "proj_s1")
  log <- file.path(chain, "proj_s1_41.out")
  writeLines("done", log)
  ran <- as.POSIXct("2026-07-04 06:30:00", tz = "")
  Sys.setFileTime(log, ran)
  argfile <- file.path(tmp, "sacct-args")

  local_scheduler(sacct = stub_recording(argfile))
  batchit::slurm_status(chain)

  expect_identical(
    stub_arg_after(readLines(argfile), "-S"),
    format(ran, "%Y-%m-%dT%H:%M:%S")
  )
})

test_that("sacct is asked for parsable output, so a job name survives", {
  # The default table truncates a job name to ten characters and marks it with
  # `+`, so `batchit_inside` arrives as `batchit_i+`.
  tmp <- withr::local_tempdir()
  argfile <- file.path(tmp, "sacct-args")
  local_scheduler(sacct = stub_recording(argfile))
  batchit::slurm_status()
  expect_true("--parsable2" %in% readLines(argfile))
})

test_that("the directory form adds the out and err paths of each job", {
  tmp <- withr::local_tempdir()
  chain <- file.path(tmp, "chain")
  write_chain(chain, c("proj_s1", "proj_s2"))
  # `slurm_write()` sets --output=<dir>/<name>_%j.out, so job 5512 wrote
  # these two files and job 5513 wrote nothing yet.
  writeLines("done", file.path(chain, "proj_s1_5512.out"))
  writeLines("", file.path(chain, "proj_s1_5512.err"))

  local_scheduler(
    sacct = slurm_stub_fixed(rows(
      sacct_row("5512", "bob", "proj_s1", "COMPLETED", "0:0", "00:00:01"),
      sacct_row("5513", "bob", "proj_s2", "RUNNING", "0:0", "00:00:03")
    ))
  )
  x <- batchit::slurm_status(chain)

  expect_identical(
    names(x),
    c(
      "job_id",
      "user",
      "name",
      "state",
      "exit_code",
      "elapsed",
      "reason",
      "out",
      "err"
    )
  )
  expect_identical(
    x[["out"]],
    c(normalizePath(file.path(chain, "proj_s1_5512.out")), NA)
  )
  expect_identical(
    x[["err"]],
    c(normalizePath(file.path(chain, "proj_s1_5512.err")), NA)
  )
})

test_that("the overview carries no out or err column", {
  local_scheduler(
    sacct = slurm_stub_fixed(
      sacct_row("16", "bob", "nftest", "COMPLETED", "0:0", "00:00:01")
    )
  )
  x <- batchit::slurm_status()
  expect_false("out" %in% names(x))
  expect_false("err" %in% names(x))
})

test_that("the directory form rejects a value that names no chain", {
  tmp <- withr::local_tempdir()
  local_scheduler()

  expect_error(batchit::slurm_status(1L), "MUST be one non-NA string")
  expect_error(batchit::slurm_status(NA_character_), "MUST be one non-NA")
  expect_error(batchit::slurm_status(c(tmp, tmp)), "MUST be one non-NA")
  expect_error(batchit::slurm_status(file.path(tmp, "absent")), "no directory")

  # A directory with no chain in it. An empty answer here would read as a
  # finished chain.
  expect_error(batchit::slurm_status(tmp), "holds no `.sh` file")

  # The driver alone names no job.
  only_driver <- file.path(tmp, "driver-only")
  dir.create(only_driver)
  writeLines("#!/bin/bash", file.path(only_driver, "submit.sh"))
  expect_error(batchit::slurm_status(only_driver), "no job script")
})

test_that("the live queue is asked before the accounting database", {
  # `slurm_status()` holds each answer in a local. R evaluates an argument when
  # the callee first touches it, so a nested call would leave the order to
  # `.slurm_status_union()`.
  tmp <- withr::local_tempdir()
  order_file <- file.path(tmp, "order")
  record <- function(name) {
    return(c(
      paste0(
        "printf '%s\\n' ",
        shQuote(name, type = "sh"),
        " >> ",
        shQuote(order_file, type = "sh")
      ),
      "exit 0"
    ))
  }
  local_scheduler(squeue = record("squeue"), sacct = record("sacct"))
  batchit::slurm_status()
  expect_identical(readLines(order_file), c("squeue", "sacct"))
})

# --- 7. the directory form identifies a job by the id on disk ----------------

test_that("the directory form returns only the runs whose logs are on disk", {
  # The chain was written once and submitted twice. Job 41 ran on Monday and
  # job 57 ran on Wednesday, so this directory holds a log for each.
  #
  # Job 23 carries the same name and left no log here. Another user ran it, or
  # an earlier chain in another directory did. A query by name returns it, and
  # the caller cannot tell it from a run of this chain.
  tmp <- withr::local_tempdir()
  chain <- file.path(tmp, "chain")
  write_chain(chain, "proj_s1")
  writeLines("done", file.path(chain, "proj_s1_41.out"))
  writeLines("done", file.path(chain, "proj_s1_57.out"))

  local_scheduler(
    sacct = stub_sacct_by_id(rows(
      sacct_row("41", "bob", "proj_s1", "COMPLETED", "0:0", "00:00:01"),
      sacct_row("57", "bob", "proj_s1", "COMPLETED", "0:0", "00:00:02"),
      sacct_row("23", "carol", "proj_s1", "FAILED", "1:0", "00:00:03")
    ))
  )
  x <- batchit::slurm_status(chain)

  on_disk <- c("41", "57")
  expect_setequal(x[["job_id"]], on_disk)
  # The invariant, stated as itself: no row reaches the caller whose job id is
  # absent from this directory.
  expect_true(all(x[["job_id"]] %in% on_disk))
  expect_false("23" %in% x[["job_id"]])
})

test_that("the directory form gives sacct the job ids, not the job names", {
  tmp <- withr::local_tempdir()
  chain <- file.path(tmp, "chain")
  write_chain(chain, "proj_s1")
  writeLines("done", file.path(chain, "proj_s1_41.out"))
  writeLines("done", file.path(chain, "proj_s1_57.out"))
  argfile <- file.path(tmp, "sacct-args")

  local_scheduler(sacct = stub_recording(argfile))
  batchit::slurm_status(chain)

  args <- readLines(argfile)
  ids <- strsplit(stub_arg_after(args, "-j"), ",", fixed = TRUE)[[1L]]
  expect_setequal(ids, c("41", "57"))
  expect_false(any(grepl("--name=", args, fixed = TRUE)))
})

test_that("the id query still gives sacct a start time", {
  # `sacct -j` obeys the same today-only default as `sacct --name=`. A job id
  # is exact and still invisible without `-S`. The stub answers only when it
  # sees the flag, so a dropped flag comes back empty here.
  tmp <- withr::local_tempdir()
  chain <- file.path(tmp, "chain")
  write_chain(chain, "proj_s1")
  writeLines("done", file.path(chain, "proj_s1_41.out"))

  local_scheduler(
    sacct = stub_sacct_needs_start(
      sacct_row("41", "bob", "proj_s1", "COMPLETED", "0:0", "00:00:01")
    )
  )
  x <- batchit::slurm_status(chain)
  expect_identical(x[["job_id"]], "41")
})

test_that("an array task id and a heterogeneous id survive the parse", {
  # Both the job name and the job id hold `_`. A split on the last `_` reads
  # the array task `0` and calls it the job.
  tmp <- withr::local_tempdir()
  chain <- file.path(tmp, "chain")
  write_chain(chain, "002-ozel_s1")
  writeLines("done", file.path(chain, "002-ozel_s1_21_0.out"))
  writeLines("done", file.path(chain, "002-ozel_s1_17+1.out"))
  argfile <- file.path(tmp, "sacct-args")

  local_scheduler(sacct = stub_recording(argfile))
  batchit::slurm_status(chain)

  ids <- strsplit(stub_arg_after(readLines(argfile), "-j"), ",", fixed = TRUE)
  expect_setequal(ids[[1L]], c("21_0", "17+1"))
})

test_that("the longer job name claims a log that both names prefix", {
  # `proj` and `proj_s1` both prefix `proj_s1_57.out`. Under the shorter name
  # the id reads `s1_57`, which names no job.
  tmp <- withr::local_tempdir()
  chain <- file.path(tmp, "chain")
  write_chain(chain, c("proj", "proj_s1"))
  writeLines("done", file.path(chain, "proj_41.out"))
  writeLines("done", file.path(chain, "proj_s1_57.out"))
  argfile <- file.path(tmp, "sacct-args")

  local_scheduler(sacct = stub_recording(argfile))
  batchit::slurm_status(chain)

  ids <- strsplit(stub_arg_after(readLines(argfile), "-j"), ",", fixed = TRUE)
  expect_setequal(ids[[1L]], c("41", "57"))
})

test_that("a queued job with no log file still reaches the caller", {
  # `proj_s1` started and left a log. `proj_s2` waits on it, so nothing on
  # disk names job 58 and only the live queue holds it. A directory form that
  # read the logs alone would report a chain of one job.
  tmp <- withr::local_tempdir()
  chain <- file.path(tmp, "chain")
  write_chain(chain, c("proj_s1", "proj_s2"))
  writeLines("done", file.path(chain, "proj_s1_57.out"))

  local_scheduler(
    squeue = slurm_stub_fixed(
      squeue_row("58", "bob", "proj_s2", "PENDING", "0:00", "Dependency")
    ),
    sacct = stub_sacct_by_id(
      sacct_row("57", "bob", "proj_s1", "COMPLETED", "0:0", "00:00:01")
    )
  )
  x <- batchit::slurm_status(chain)

  expect_identical(x[["job_id"]], c("58", "57"))
  expect_identical(x[["name"]], c("proj_s2", "proj_s1"))
  expect_identical(x[["state"]], c("PENDING", "COMPLETED"))
  expect_identical(x[["reason"]], c("Dependency", NA))
})

test_that("a chain that started no job asks the accounting database nothing", {
  # No log file, so no job id exists to ask for. A name query would answer
  # with a previous run, and there is no id here to tell it apart.
  tmp <- withr::local_tempdir()
  chain <- file.path(tmp, "chain")
  write_chain(chain, "proj_s1")
  argfile <- file.path(tmp, "sacct-args")

  local_scheduler(
    squeue = slurm_stub_fixed(
      squeue_row("58", "bob", "proj_s1", "PENDING", "0:00", "Priority")
    ),
    sacct = stub_recording(argfile)
  )
  x <- batchit::slurm_status(chain)

  expect_false(file.exists(argfile))
  expect_identical(x[["job_id"]], "58")
  expect_identical(
    names(x),
    c(
      "job_id",
      "user",
      "name",
      "state",
      "exit_code",
      "elapsed",
      "reason",
      "out",
      "err"
    )
  )
})

# --- 8. neither command reports memory ---------------------------------------

test_that("slurm_status() reports no memory column", {
  # `MaxRSS` is empty for every job on Slurm 25.11.2, and a blank memory column
  # reads as "the job used no memory". The real peak is in the job's own .out
  # file, which `slurm_write()` puts there.
  tmp <- withr::local_tempdir()
  argfile <- file.path(tmp, "sacct-args")
  local_scheduler(sacct = stub_recording(argfile))
  x <- batchit::slurm_status()

  expect_false(any(grepl("mem", names(x), ignore.case = TRUE)))
  expect_false(any(grepl("MaxRSS", readLines(argfile), fixed = TRUE)))
})

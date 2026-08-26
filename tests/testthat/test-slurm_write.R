# slurm_write() turns a validated description into executable shell, so most of
# what matters here is behaviour rather than text. Three properties cannot be
# read off a generated file at all, and each one has its own block below:
#
#   * the exit code survives the EXIT trap,
#   * a version refusal stops the job body,
#   * the driver hands `afterok` the job id alone.
#
# `bash -n` proves syntax and nothing else. Its failure code is 2, not 1.

ok_job <- function(name, ...) {
  args <- list(
    script = "true",
    name = name,
    cpus = 2,
    mem = "1G",
    time = "01:00:00"
  )
  over <- list(...)
  for (nm in names(over)) {
    args[nm] <- list(over[[nm]])
  }
  do.call(batchit::slurm_it, args)
}

# Run a generated file and return its status with both streams.
#
# stdout and stderr go to separate files. Two redirections to one file each
# open it with truncation, and the two streams then overwrite each other.
run_bash <- function(path, tmp, tag) {
  out <- file.path(tmp, paste0(tag, ".out"))
  err <- file.path(tmp, paste0(tag, ".err"))
  status <- system2("bash", shQuote(path), stdout = out, stderr = err)
  list(
    status = status,
    out = readLines(out, warn = FALSE),
    err = readLines(err, warn = FALSE)
  )
}

# --- the API -----------------------------------------------------------------

test_that("slurm_write() takes two arguments", {
  # The peak-memory path is an option, not a third formal. A formal would put a
  # cluster-wide property on every call site.
  expect_identical(names(formals(batchit::slurm_write)), c("x", "dir"))
})

# --- what gets written -------------------------------------------------------

test_that("slurm_write() writes one file for each job, plus the driver", {
  tmp <- withr::local_tempdir()
  dir <- file.path(tmp, "chain")

  paths <- withVisible(batchit::slurm_write(
    list(ok_job("proj_s1"), ok_job("proj_s2")),
    dir
  ))
  expect_false(paths[["visible"]])
  out <- paths[["value"]]

  expect_length(out, 3L)
  expect_identical(basename(out), c("proj_s1.sh", "proj_s2.sh", "submit.sh"))
  expect_true(all(file.exists(out)))
  expect_identical(
    unname(as.character(file.mode(out))),
    rep("755", 3L)
  )
})

test_that("slurm_write() accepts one bare slurm_it object", {
  tmp <- withr::local_tempdir()
  out <- batchit::slurm_write(ok_job("solo"), file.path(tmp, "chain"))

  expect_identical(basename(out), c("solo.sh", "submit.sh"))
})

test_that("slurm_write() owns dir and deletes the previous chain", {
  tmp <- withr::local_tempdir()
  dir <- file.path(tmp, "chain")

  five <- batchit::slurm_write(
    lapply(paste0("s", 1:5), ok_job),
    dir
  )
  four <- batchit::slurm_write(
    lapply(paste0("s", 1:4), ok_job),
    dir
  )

  # The orphaned fifth file is unreferenced by the new driver, and it still
  # runs by hand. That is the reason the directory is owned rather than added
  # to.
  expect_false(file.exists(five[[5]]))
  expect_setequal(
    list.files(dir, pattern = "\\.sh$"),
    c(paste0("s", 1:4, ".sh"), "submit.sh")
  )
  expect_true(all(file.exists(four)))
})

# --- the invariant -----------------------------------------------------------

test_that("no job file names the submission command", {
  tmp <- withr::local_tempdir()
  paths <- batchit::slurm_write(
    list(ok_job("proj_s1"), ok_job("proj_s2")),
    file.path(tmp, "chain")
  )
  jobs <- paths[1:2]
  driver <- paths[[3]]

  for (p in jobs) {
    lines <- readLines(p, warn = FALSE)
    expect_identical(
      sum(grepl("sbatch", lines, fixed = TRUE)),
      0L,
      info = basename(p)
    )
  }
  expect_gt(
    sum(grepl("sbatch", readLines(driver, warn = FALSE), fixed = TRUE)),
    0L
  )
})

test_that("every generated file is syntactically valid bash", {
  tmp <- withr::local_tempdir()
  paths <- batchit::slurm_write(
    list(
      ok_job("proj_s1", require_r_package = c(stats = "1.0")),
      ok_job("proj_s2", exclusive = TRUE, sbatch = c(partition = "core")),
      ok_job("proj_s3", requeue = FALSE, script = "echo one\necho two")
    ),
    file.path(tmp, "chain")
  )

  for (p in paths) {
    expect_identical(
      system2("bash", c("-n", shQuote(p))),
      0L,
      info = basename(p)
    )
  }
})

# --- the directives ----------------------------------------------------------

test_that("every job file carries the four automatic items", {
  tmp <- withr::local_tempdir()
  dir <- file.path(tmp, "chain")
  paths <- batchit::slurm_write(list(ok_job("proj_s1")), dir)
  lines <- readLines(paths[[1]], warn = FALSE)
  abs_dir <- dirname(paths[[1]])

  expect_true(paste0("#SBATCH --output=", abs_dir, "/proj_s1_%j.out") %in% lines)
  expect_true(paste0("#SBATCH --error=", abs_dir, "/proj_s1_%j.err") %in% lines)
  expect_true(any(grepl("^printf 'batchit_start ", lines)))
  expect_true(any(grepl("batchit_record_peak_memory", lines)))
  expect_true("trap batchit_on_exit EXIT" %in% lines)

  # The trap's first statement is what captures the status the body exited
  # with. A statement before it overwrites that status.
  trap_open <- which(lines == "batchit_on_exit() {")
  expect_length(trap_open, 1L)
  expect_identical(lines[[trap_open + 1L]], "  batchit_status=$?")
})

test_that("time is always set, and exclusive has an explicit false case", {
  tmp <- withr::local_tempdir()
  paths <- batchit::slurm_write(
    list(
      ok_job("shared"),
      ok_job("whole_node", exclusive = TRUE, requeue = FALSE)
    ),
    file.path(tmp, "chain")
  )
  shared <- readLines(paths[[1]], warn = FALSE)
  whole <- readLines(paths[[2]], warn = FALSE)

  expect_true("#SBATCH --time=01:00:00" %in% shared)
  expect_true("#SBATCH --time=01:00:00" %in% whole)

  # The false case is the absence of the directive, because Slurm has no
  # negative form of it. So no token of that name may appear anywhere.
  expect_identical(sum(grepl("exclusive", shared, fixed = TRUE)), 0L)
  expect_true("#SBATCH --exclusive" %in% whole)

  expect_true("#SBATCH --requeue" %in% shared)
  expect_true("#SBATCH --no-requeue" %in% whole)
})

test_that("an extra sbatch option reaches the job as a directive", {
  tmp <- withr::local_tempdir()
  paths <- batchit::slurm_write(
    list(ok_job("proj_s1", sbatch = c(partition = "core", "mail-type" = "FAIL"))),
    file.path(tmp, "chain")
  )
  lines <- readLines(paths[[1]], warn = FALSE)

  expect_true("#SBATCH --partition=core" %in% lines)
  expect_true("#SBATCH --mail-type=FAIL" %in% lines)
})

# --- the chain ---------------------------------------------------------------

test_that("the driver wires each job to the one before it with afterok", {
  tmp <- withr::local_tempdir()
  paths <- batchit::slurm_write(
    list(ok_job("proj_s1"), ok_job("proj_s2"), ok_job("proj_s3")),
    file.path(tmp, "chain")
  )
  lines <- readLines(paths[[4]], warn = FALSE)
  submits <- grep("sbatch", lines, fixed = TRUE, value = TRUE)

  expect_length(submits, 3L)
  expect_false(grepl("--dependency", submits[[1]], fixed = TRUE))
  expect_true(grepl(
    "--dependency=afterok:\"$batchit_jid_1\"",
    submits[[2]],
    fixed = TRUE
  ))
  expect_true(grepl(
    "--dependency=afterok:\"$batchit_jid_2\"",
    submits[[3]],
    fixed = TRUE
  ))
  expect_true(all(grepl(
    "--kill-on-invalid-dep=yes",
    submits[2:3],
    fixed = TRUE
  )))
})

test_that("the driver hands afterok the job id alone", {
  tmp <- withr::local_tempdir()
  paths <- batchit::slurm_write(
    list(ok_job("proj_s1"), ok_job("proj_s2")),
    file.path(tmp, "chain")
  )

  # A stub on PATH stands in for the scheduler. It records its own arguments
  # and answers in the federated form, `jobid;cluster`. The whole of that
  # string reaching afterok: is a dependency Slurm never satisfies.
  bin <- file.path(tmp, "bin")
  dir.create(bin)
  stub <- file.path(bin, "sbatch")
  writeLines(
    c(
      "#!/bin/bash",
      "printf '%s\\n' \"$*\" >> \"$SBATCH_LOG\"",
      "printf '%s;cluster1\\n' \"$(wc -l < \"$SBATCH_LOG\")\""
    ),
    stub
  )
  Sys.chmod(stub, "0755")
  log <- file.path(tmp, "sbatch.log")

  run <- withr::with_envvar(
    c(
      PATH = paste(bin, Sys.getenv("PATH"), sep = ":"),
      SBATCH_LOG = log
    ),
    run_bash(paths[[3]], tmp, "driver")
  )

  expect_identical(run[["status"]], 0L)
  argv <- readLines(log, warn = FALSE)
  expect_length(argv, 2L)
  expect_false(grepl("--dependency", argv[[1]], fixed = TRUE))
  expect_true(grepl("--dependency=afterok:1 ", argv[[2]], fixed = TRUE))
  expect_identical(sum(grepl("cluster1", argv, fixed = TRUE)), 0L)
  expect_true("batchit_submitted proj_s2 2" %in% run[["out"]])
})

# --- behaviour that no amount of text parsing reaches -------------------------

test_that("the exit code survives the EXIT trap", {
  tmp <- withr::local_tempdir()
  paths <- batchit::slurm_write(
    list(ok_job("dies", script = "exit 37")),
    file.path(tmp, "chain")
  )

  run <- run_bash(paths[[1]], tmp, "dies")

  expect_identical(run[["status"]], 37L)
  expect_true(any(grepl("^batchit_end ", run[["out"]])))
  expect_true("batchit_exit_code 37" %in% run[["out"]])
})

test_that("a require_r_package refusal stops the job body", {
  tmp <- withr::local_tempdir()
  marker <- file.path(tmp, "marker")
  paths <- batchit::slurm_write(
    list(ok_job(
      "gated",
      script = paste0("touch ", shQuote(marker)),
      require_r_package = c(stats = "0.1")
    )),
    file.path(tmp, "chain")
  )

  run <- run_bash(paths[[1]], tmp, "gated")

  # Printing a complaint and running the body anyway is the failure mode, so
  # the marker is the assertion, not the message.
  expect_false(file.exists(marker))
  expect_false(identical(run[["status"]], 0L))
  expect_true(any(grepl("is not at version 0.1", run[["err"]])))
})

test_that("a satisfied require_r_package lets the job body run", {
  tmp <- withr::local_tempdir()
  marker <- file.path(tmp, "marker")
  installed <- as.character(utils::packageVersion("stats"))
  paths <- batchit::slurm_write(
    list(ok_job(
      "gated",
      script = paste0("touch ", shQuote(marker)),
      require_r_package = stats::setNames(installed, "stats")
    )),
    file.path(tmp, "chain")
  )

  run <- run_bash(paths[[1]], tmp, "gated")

  expect_identical(run[["status"]], 0L)
  expect_true(file.exists(marker))
})

# --- peak memory, one branch at a time ---------------------------------------

test_that("a job that cannot read the counter reports VmHWM", {
  tmp <- withr::local_tempdir()
  absent <- file.path(tmp, "absent-counter")
  expect_false(file.exists(absent))

  withr::local_options(batchit.memory_peak_path = absent)
  paths <- batchit::slurm_write(
    list(ok_job("fallback")),
    file.path(tmp, "chain")
  )
  run <- run_bash(paths[[1]], tmp, "fallback")

  expect_identical(run[["status"]], 0L)
  expect_true(any(grepl("^batchit_vmhwm_kb [0-9]+$", run[["out"]])))
  expect_identical(
    sum(grepl("batchit_memory_peak_bytes", run[["out"]], fixed = TRUE)),
    0L
  )
})

test_that("a job that can read the counter reports its value", {
  tmp <- withr::local_tempdir()
  counter <- file.path(tmp, "memory.peak")
  writeLines("123456789", counter)

  withr::local_options(batchit.memory_peak_path = counter)
  paths <- batchit::slurm_write(
    list(ok_job("primary")),
    file.path(tmp, "chain")
  )
  run <- run_bash(paths[[1]], tmp, "primary")

  expect_identical(run[["status"]], 0L)
  expect_true("batchit_memory_peak_bytes 123456789" %in% run[["out"]])
  expect_true(
    paste0("batchit_memory_peak_path='", counter, "'") %in%
      readLines(paths[[1]], warn = FALSE)
  )
  expect_identical(
    sum(grepl("batchit_vmhwm_kb", run[["out"]], fixed = TRUE)),
    0L
  )
})

test_that("the default job reads the cgroup v2 counter", {
  tmp <- withr::local_tempdir()
  paths <- batchit::slurm_write(list(ok_job("proj_s1")), file.path(tmp, "chain"))
  lines <- readLines(paths[[1]], warn = FALSE)

  # The two branch tests above each set `batchit.memory_peak_path`, so this is
  # what ties the branches back to the path a real job reads. No option is set
  # here, so the job carries the default.
  expect_null(getOption("batchit.memory_peak_path"))
  expect_true(
    "batchit_memory_peak_path='/sys/fs/cgroup/memory.peak'" %in% lines
  )
})

# --- rejections --------------------------------------------------------------

test_that("slurm_write() rejects a job set it cannot write", {
  tmp <- withr::local_tempdir()
  dir <- file.path(tmp, "chain")

  expect_error(
    batchit::slurm_write(list(ok_job("same"), ok_job("same")), dir),
    "own `name`"
  )
  expect_error(
    batchit::slurm_write(list(ok_job("submit")), dir),
    "MUST NOT take the name"
  )
  expect_error(batchit::slurm_write(list(), dir), "at least one job")
  expect_error(batchit::slurm_write("proj_s1", dir), "slurm_it object")
  expect_error(
    batchit::slurm_write(list(ok_job("proj_s1"), "proj_s2"), dir),
    "`x\\[\\[2\\]\\]`"
  )
})

test_that("slurm_write() rejects a directory a directive cannot carry", {
  tmp <- withr::local_tempdir()
  job <- list(ok_job("proj_s1"))

  expect_error(
    batchit::slurm_write(job, file.path(tmp, "a dir")),
    "whitespace character"
  )
  expect_error(batchit::slurm_write(job, ""), "not whitespace")
  expect_error(batchit::slurm_write(job, c("a", "b")), "one non-NA string")
  withr::with_options(
    list(batchit.memory_peak_path = ""),
    expect_error(
      batchit::slurm_write(job, file.path(tmp, "ok")),
      "not whitespace"
    )
  )
})

# --- the reserved-key prefix rule -------------------------------------------

test_that("slurm_it() rejects an abbreviation of a reserved sbatch key", {
  abbreviations <- c("jo", "cp", "me", "ti", "ou", "er", "ex", "req", "no", "de")
  for (key in abbreviations) {
    expect_error(
      batchit::slurm_it(
        script = "true",
        name = "j",
        cpus = 2,
        mem = "1G",
        time = "01:00:00",
        sbatch = stats::setNames("x", key)
      ),
      "MUST NOT set",
      info = key
    )
  }

  # A name that abbreviates nothing reserved still passes.
  job <- batchit::slurm_it(
    script = "true",
    name = "j",
    cpus = 2,
    mem = "1G",
    time = "01:00:00",
    sbatch = c(partition = "core", "mail-type" = "FAIL", nice = "10")
  )
  expect_identical(names(job[["sbatch"]]), c("partition", "mail-type", "nice"))
})

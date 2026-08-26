# The preflight lives in the generated `submit.sh`, so nothing here reads the
# R that builds it. Each block writes a chain, puts stub `hostname`, `sinfo`,
# `squeue` and `sbatch` programs first on `PATH`, runs the driver, and asserts
# the EXIT STATUS. A message alone would pass while the driver submitted
# anyway.
#
# `sbatch` is stubbed because the accepted case has to reach exit 0. Without
# it, `set -e` stops the driver at a missing `sbatch`, every case exits
# non-zero, and a refusal becomes indistinguishable from a submission.
#
# `slurm_stub_path()` in `helper-slurm-stubs.R` writes the stubs. It shims
# every other scheduler command as well, so no block here can read the state
# of the machine it runs on.
#
# WHAT THESE BLOCKS DO NOT PROVE. A PATH stub answers the protocol this file
# invented. It says nothing about the argument spelling the real `sinfo` and
# `squeue` accept, the output grammar they produce, which users' jobs `squeue`
# reports, or whether two `submit.sh` runs started at the same time can both
# pass.

ok_job <- function(name) {
  batchit::slurm_it(
    script = "true",
    name = name,
    cpus = 2,
    mem = "1G",
    time = "01:00:00"
  )
}

# Build a chain, stub the scheduler, run `submit.sh`, and return its status.
#
# `sinfo_out` is the text the stub `sinfo` prints, with `\n` for the several
# lines a node in more than one partition emits. `squeue_out` is the same for
# job names.
run_submit <- function(
  job_names,
  sinfo_out,
  squeue_out = "",
  sinfo_status = 0L,
  squeue_status = 0L
) {
  tmp <- withr::local_tempdir()
  chain <- file.path(tmp, "chain")

  batchit::slurm_write(lapply(job_names, ok_job), chain)

  # Every generated file MUST parse. `bash -n` proves syntax and nothing else.
  for (sh in list.files(chain, pattern = "\\.sh$", full.names = TRUE)) {
    testthat::expect_identical(
      system2("bash", c("-n", shQuote(sh))),
      0L,
      info = sh
    )
  }

  driver <- file.path(chain, "submit.sh")
  out <- file.path(tmp, "driver.out")
  err <- file.path(tmp, "driver.err")
  withr::local_envvar(
    PATH = slurm_stub_path(
      file.path(tmp, "stubs"),
      list(
        hostname = slurm_stub_fixed("stub-node"),
        sinfo = slurm_stub_fixed(sinfo_out, sinfo_status),
        squeue = slurm_stub_fixed(squeue_out, squeue_status),
        sbatch = slurm_stub_fixed("424242")
      )
    )
  )
  status <- system2("bash", shQuote(driver), stdout = out, stderr = err)
  list(
    status = status,
    out = readLines(out, warn = FALSE),
    err = readLines(err, warn = FALSE)
  )
}

# --- 1. a node that cannot accept work ---------------------------------------

test_that("submit.sh refuses every node state that cannot run work", {
  # `~` marks power save and `+DRAIN` is a compound state. Both refuse,
  # because refusing is the conservative direction.
  for (state in c(
    "drained",
    "down",
    "draining",
    "reserved",
    "idle~",
    "idle+DRAIN"
  )) {
    r <- run_submit("proj_s1", sinfo_out = state)
    expect_identical(r[["status"]], 1L, info = state)
    expect_match(paste(r[["err"]], collapse = "\n"), "REFUSED", info = state)
    # It refused before it submitted.
    expect_identical(r[["out"]], character(0), info = state)
  }
})

test_that("submit.sh refuses when any partition reports the node drained", {
  # `sinfo` writes one line per node and partition. A node drained in one
  # partition and idle in another arrives as `drained,idle` after
  # `sort -u | paste -sd,`.
  #
  # EVERY state MUST be able to run work. A membership test on the joined
  # value accepts `drained,idle`, because `idle` is present, and the
  # submission then waits PENDING forever on a node that will not run it.
  r <- run_submit("proj_s1", sinfo_out = "drained\nidle")
  expect_identical(r[["status"]], 1L)
  expect_match(paste(r[["err"]], collapse = "\n"), "drained,idle", fixed = TRUE)
  expect_match(paste(r[["err"]], collapse = "\n"), "State=RESUME", fixed = TRUE)
  expect_identical(r[["out"]], character(0))
})

test_that("submit.sh refuses when sinfo reports no state for the node", {
  # Verified against Slurm 25.11.2: `sinfo -h -n <unknown> -o '%T'` exits 0
  # and prints nothing. So the empty result needs its own branch.
  r <- run_submit("proj_s1", sinfo_out = "")
  expect_identical(r[["status"]], 1L)
  expect_match(paste(r[["err"]], collapse = "\n"), "no state for node")
  expect_identical(r[["out"]], character(0))
})

test_that("submit.sh refuses when sinfo itself fails", {
  r <- run_submit("proj_s1", sinfo_out = "idle", sinfo_status = 1L)
  expect_identical(r[["status"]], 1L)
  expect_match(paste(r[["err"]], collapse = "\n"), "sinfo failed")
  expect_identical(r[["out"]], character(0))
})

# --- 2. a node that can, with the suffix sinfo writes -------------------------

test_that("submit.sh accepts every node state that can run work", {
  # `idle*` carries the suffix `sinfo` writes on a node slurmctld cannot
  # reach. Without `tr -d '*'` the driver refuses a node that can run work.
  for (state in c("idle", "mixed", "allocated", "idle*")) {
    r <- run_submit("proj_s1", sinfo_out = state)
    expect_identical(r[["status"]], 0L, info = state)
    expect_identical(
      r[["out"]],
      "batchit_submitted proj_s1 424242",
      info = state
    )
  }
})

test_that("submit.sh accepts a multi-partition node whose states all run work", {
  # `sort -u | paste -sd,` joins the several lines. Without `paste` the value
  # keeps its line break, no branch matches, and a healthy node refuses.
  for (state in c("idle\nidle", "idle\nmixed", "allocated\nidle")) {
    r <- run_submit("proj_s1", sinfo_out = state)
    expect_identical(r[["status"]], 0L, info = state)
    expect_identical(
      r[["out"]],
      "batchit_submitted proj_s1 424242",
      info = state
    )
  }
})

# --- 3. a duplicate already in the queue --------------------------------------

test_that("submit.sh refuses a job name already in squeue", {
  r <- run_submit(
    c("proj_s1", "proj_s2"),
    sinfo_out = "idle",
    squeue_out = "someone_else\nproj_s2"
  )
  expect_identical(r[["status"]], 1L)
  expect_match(paste(r[["err"]], collapse = "\n"), "proj_s2 is already queued")
  expect_identical(r[["out"]], character(0))
})

test_that("submit.sh submits when squeue names no job in the chain", {
  r <- run_submit(
    "proj_s1",
    sinfo_out = "idle",
    squeue_out = "proj_s1_other\nother_proj_s1"
  )
  # `grep -x` matches the whole line, so neither near miss is a duplicate.
  expect_identical(r[["status"]], 0L)
  expect_identical(r[["out"]], "batchit_submitted proj_s1 424242")
})

# --- 4. squeue that cannot answer ---------------------------------------------

test_that("submit.sh refuses when squeue exits non-zero", {
  # Fail closed. An unanswerable squeue leaves a second chain possible, and
  # that is a reason to stop.
  r <- run_submit("proj_s1", sinfo_out = "idle", squeue_status = 1L)
  expect_identical(r[["status"]], 1L)
  expect_match(paste(r[["err"]], collapse = "\n"), "squeue failed")
  expect_identical(r[["out"]], character(0))
})

# --- 5. the version gate must not depend on the calling environment ----------
#
# Two independent defects hid here, and the second one only appeared once the
# first was fixed.
#
#   * `R CMD check` exports R_TESTS=startup.Rs. An `Rscript` subprocess that
#     inherits it tries to source that name from its own working directory,
#     does not find it, and dies.
#   * `R CMD check` also puts a directory first on `PATH` holding a dummy
#     `Rscript` that prints a complaint and exits 1. See
#     `tools:::add_dummies()`. It enforces Writing R Extensions section 1.6.
#
# Either one makes the gate refuse a version that is installed, so the job
# body never runs. The blocks below drive both, and each assertion carries the
# subprocess output, because a bare status of 1 does not say which cause fired.

test_that("the version gate names Rscript by an absolute path", {
  paths <- batchit::slurm_write(
    list(batchit::slurm_it(
      script = "true",
      name = "gated",
      cpus = 1,
      mem = "1G",
      time = "00:01:00",
      require_r_package = c(stats = "4.5.2")
    )),
    file.path(withr::local_tempdir(), "chain")
  )
  gate <- grep("packageVersion", readLines(paths[[1]]), value = TRUE)

  expect_length(gate, 1L)
  expect_match(
    gate,
    paste0(" ", shQuote(file.path(R.home("bin"), "Rscript"), type = "sh"), " "),
    fixed = TRUE
  )
  # A bare `Rscript` resolves against PATH, which is the defect.
  expect_no_match(gate, "! env -u R_TESTS Rscript ", fixed = TRUE)
})

test_that("the option batchit.rscript_path names the interpreter", {
  withr::local_options(batchit.rscript_path = "/opt/R/4.5.2/bin/Rscript")
  paths <- batchit::slurm_write(
    list(batchit::slurm_it(
      script = "true",
      name = "gated",
      cpus = 1,
      mem = "1G",
      time = "00:01:00",
      require_r_package = c(stats = "4.5.2")
    )),
    file.path(withr::local_tempdir(), "chain")
  )
  gate <- grep("packageVersion", readLines(paths[[1]]), value = TRUE)

  expect_match(gate, "'/opt/R/4.5.2/bin/Rscript'", fixed = TRUE)
  expect_identical(system2("bash", c("-n", shQuote(paths[[1]]))), 0L)
})

test_that("the version gate ignores a dummy Rscript on PATH", {
  # `tools:::add_dummies()` writes exactly this script and puts its directory
  # first on PATH for the whole of `R CMD check`. Matching the spelling of the
  # generated line would not prove the gate survives it, so this block drives
  # the mechanism.
  tmp <- withr::local_tempdir()
  marker <- file.path(tmp, "marker")
  stubs <- file.path(tmp, "stubs")
  dir.create(stubs)
  writeLines(
    c(
      "#!/bin/bash",
      paste0(
        "echo \"'Rscript' should not be used without a path",
        " -- see par. 1.6 of the manual\""
      ),
      "exit 1"
    ),
    file.path(stubs, "Rscript")
  )
  Sys.chmod(file.path(stubs, "Rscript"), "0755")

  installed <- as.character(utils::packageVersion("stats"))
  paths <- batchit::slurm_write(
    list(batchit::slurm_it(
      script = paste0("touch ", shQuote(marker)),
      name = "gated",
      cpus = 1,
      mem = "1G",
      time = "00:01:00",
      require_r_package = stats::setNames(installed, "stats")
    )),
    file.path(tmp, "chain")
  )

  withr::local_envvar(
    PATH = paste(stubs, Sys.getenv("PATH"), sep = .Platform$path.sep)
  )
  out <- file.path(tmp, "gated.out")
  err <- file.path(tmp, "gated.err")
  status <- system2("bash", shQuote(paths[[1]]), stdout = out, stderr = err)
  why <- paste(
    c("stderr:", readLines(err, warn = FALSE), "stdout:", readLines(out, warn = FALSE)),
    collapse = "\n"
  )

  expect_identical(status, 0L, info = why)
  expect_true(file.exists(marker), info = why)
})

test_that("the version gate runs under a leaked R_TESTS", {
  # This block sets R_TESTS itself, so it reproduces the failure under
  # `pkgload::load_all()` as well as under `R CMD check`.
  tmp <- withr::local_tempdir()
  marker <- file.path(tmp, "marker")
  installed <- as.character(utils::packageVersion("stats"))
  paths <- batchit::slurm_write(
    list(batchit::slurm_it(
      script = paste0("touch ", shQuote(marker)),
      name = "gated",
      cpus = 1,
      mem = "1G",
      time = "00:01:00",
      require_r_package = stats::setNames(installed, "stats")
    )),
    file.path(tmp, "chain")
  )
  expect_identical(system2("bash", c("-n", shQuote(paths[[1]]))), 0L)

  # The marker is the assertion. A gate that prints a complaint and runs the
  # body anyway would pass an assertion on the message alone.
  withr::local_envvar(R_TESTS = "startup.Rs")
  out <- file.path(tmp, "gated.out")
  err <- file.path(tmp, "gated.err")
  status <- system2("bash", shQuote(paths[[1]]), stdout = out, stderr = err)
  why <- paste(
    c(
      paste("R_TESTS=", Sys.getenv("R_TESTS")),
      paste("wd=", getwd()),
      "stderr:", readLines(err, warn = FALSE),
      "stdout:", readLines(out, warn = FALSE)
    ),
    collapse = "\n"
  )
  expect_identical(status, 0L, info = why)
  expect_true(file.exists(marker), info = why)
  expect_false(any(grepl("startup.Rs", readLines(err, warn = FALSE))), info = why)
})

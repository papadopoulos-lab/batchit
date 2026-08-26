# `slurm_submit()` runs a generated `submit.sh`. Nothing here needs Slurm.
#
# Every block builds its `PATH` with `slurm_stub_path()` from
# `helper-slurm-stubs.R`. That helper writes a refusing shim for every
# scheduler command the block did not stub, so a block that reaches a host
# binary fails on a machine that has Slurm as well as on one that does not.
#
# WHAT THESE BLOCKS DO NOT PROVE. A stub answers the protocol this file
# invented. They say nothing about the output that a real `sbatch` writes,
# nor about the exit status a real `sbatch` uses for each kind of rejection.

ok_job <- function(name) {
  batchit::slurm_it(
    script = "true",
    name = name,
    cpus = 2,
    mem = "1G",
    time = "01:00:00"
  )
}

# The body of a stub `sbatch` that prints `ids[[n]]` on its call number `n`.
#
# It exits 1 once the calls outrun `ids`, which is how a chain reaches a
# partial submission: the earlier jobs are queued and the driver stops.
# `counter` is a file, because each call is its own process.
sbatch_counting <- function(counter, ids) {
  c(
    paste0(
      "batchit_n=$(cat ",
      shQuote(counter, type = "sh"),
      " 2>/dev/null || echo 0)"
    ),
    "batchit_n=$((batchit_n + 1))",
    paste0("printf '%s' \"$batchit_n\" > ", shQuote(counter, type = "sh")),
    paste0(
      "batchit_ids=(",
      paste(shQuote(ids, type = "sh"), collapse = " "),
      ")"
    ),
    "if [ \"$batchit_n\" -le \"${#batchit_ids[@]}\" ]; then",
    "  printf '%s\\n' \"${batchit_ids[$((batchit_n - 1))]}\"",
    "  exit 0",
    "fi",
    paste0(
      "printf 'sbatch: error: Batch job submission failed: ",
      "Invalid account\\n' >&2"
    ),
    "exit 1"
  )
}

# Write a chain, stub the scheduler, and run `slurm_submit()` on it.
#
# `shape` picks which of the three accepted forms reaches the function:
# the vector `slurm_write()` returned, the directory, or the driver path.
#
# The whole run happens here, so the stub `PATH` is live for the call and
# gone after it.
run_submit <- function(
  job_names,
  ids = c("5512", "5513", "5514"),
  sinfo_out = "idle",
  squeue_out = "",
  shape = "paths"
) {
  tmp <- withr::local_tempdir()
  chain <- file.path(tmp, "chain")
  paths <- batchit::slurm_write(lapply(job_names, ok_job), chain)

  withr::local_envvar(
    PATH = slurm_stub_path(
      file.path(tmp, "stubs"),
      list(
        hostname = slurm_stub_fixed("stub-node"),
        sinfo = slurm_stub_fixed(sinfo_out),
        squeue = slurm_stub_fixed(squeue_out),
        sbatch = sbatch_counting(file.path(tmp, "sbatch-calls"), ids)
      )
    )
  )
  x <- switch(
    shape,
    paths = paths,
    dir = dirname(paths[[length(paths)]]),
    driver = paths[[length(paths)]],
    stop("unknown shape")
  )
  batchit::slurm_submit(x)
}

# The message of the error `run_submit()` raises, or a failure when it raises
# none. Returning the text lets one block assert several facts about it.
submit_error <- function(...) {
  msg <- tryCatch(
    {
      run_submit(...)
      NA_character_
    },
    error = function(e) conditionMessage(e)
  )
  testthat::expect_false(is.na(msg))
  msg
}

# --- 1. what it returns -------------------------------------------------------

test_that("slurm_submit() returns the driver's job ids, named by stage", {
  ids <- run_submit(c("proj_s1", "proj_s2"))
  expect_identical(ids, c(proj_s1 = "5512", proj_s2 = "5513"))
  expect_type(ids, "character")
  expect_identical(names(ids), c("proj_s1", "proj_s2"))
})

test_that("slurm_submit() keeps chain order in the ids it returns", {
  # A chain of three separates order from the alphabet: the ids ascend with
  # position, so a result sorted by name would still hold.
  ids <- run_submit(c("s3", "s1", "s2"))
  expect_identical(ids, c(s3 = "5512", s1 = "5513", s2 = "5514"))
})

# --- 2. the three shapes `x` accepts -----------------------------------------

test_that("slurm_submit() accepts the paths, the directory and the driver", {
  expected <- c(proj_s1 = "5512", proj_s2 = "5513")
  for (shape in c("paths", "dir", "driver")) {
    expect_identical(
      run_submit(c("proj_s1", "proj_s2"), shape = shape),
      expected,
      info = shape
    )
  }
})

test_that("slurm_submit() rejects a value that names no driver", {
  tmp <- withr::local_tempdir()
  chain <- file.path(tmp, "chain")
  paths <- batchit::slurm_write(lapply(c("proj_s1"), ok_job), chain)

  expect_error(batchit::slurm_submit(1L), "MUST be a character vector")
  expect_error(batchit::slurm_submit(list(chain)), "MUST be a character vector")
  expect_error(batchit::slurm_submit(character(0)), "MUST be a character")
  expect_error(batchit::slurm_submit(NA_character_), "MUST be a character")
  expect_error(batchit::slurm_submit("  "), "not whitespace")

  # A job file is a real file in the chain, and running it here would run the
  # job in this session.
  expect_error(batchit::slurm_submit(paths[[1]]), "MUST be submit.sh")
  expect_error(
    batchit::slurm_submit(file.path(tmp, "absent")),
    "MUST be submit.sh"
  )
  expect_error(
    batchit::slurm_submit(file.path(tmp, "absent", "submit.sh")),
    "no file at"
  )
})

# --- 3. a refusal carries the driver's own message ----------------------------

test_that("slurm_submit() errors on a refusal, with the driver's message", {
  msg <- submit_error("proj_s1", sinfo_out = "drained")
  expect_match(msg, "the driver exited 1", fixed = TRUE)
  expect_match(msg, "queued nothing", fixed = TRUE)
  # Verbatim. The refusal names the state and the command that repairs it.
  expect_match(msg, "batchit: REFUSED:", fixed = TRUE)
  expect_match(msg, "node stub-node is in state 'drained'", fixed = TRUE)
  expect_match(
    msg,
    "sudo scontrol update NodeName=stub-node State=RESUME",
    fixed = TRUE
  )
})

test_that("the driver still refuses a chain whose name is already queued", {
  # This is the generated preflight, not a check in R. `slurm_submit()` adds
  # no second guard, so a duplicate is refused by one policy in one place.
  msg <- submit_error(c("proj_s1", "proj_s2"), squeue_out = "proj_s2")
  expect_match(msg, "a job named proj_s2 is already queued", fixed = TRUE)
  expect_match(msg, "queued nothing", fixed = TRUE)
})

# --- 4. the partial submission ------------------------------------------------

test_that("slurm_submit() names the jobs queued before the driver stopped", {
  # The driver runs under `set -euo pipefail`, so an `sbatch` that fails at
  # the second job leaves the first one in the queue. An error that reported
  # the failure alone would hide it.
  msg <- submit_error(c("proj_s1", "proj_s2"), ids = "5512")
  expect_match(msg, "5512", fixed = TRUE)
  expect_match(msg, "1 job already queued: proj_s1=5512", fixed = TRUE)
  expect_match(msg, "Cancel it: scancel 5512", fixed = TRUE)
  # The driver's own message travels with it.
  expect_match(msg, "Batch job submission failed", fixed = TRUE)
})

test_that("slurm_submit() names every queued job when two of three landed", {
  msg <- submit_error(c("proj_s1", "proj_s2", "proj_s3"), ids = c("77", "78"))
  expect_match(
    msg,
    "2 jobs already queued: proj_s1=77, proj_s2=78",
    fixed = TRUE
  )
  expect_match(msg, "Cancel them: scancel 77 78", fixed = TRUE)
})

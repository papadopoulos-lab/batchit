# `inside_slurm_job()` reads two environment variables. Every block below sets
# both of them, so no block depends on the environment the suite runs in. A
# suite that itself runs under Slurm gets the same answers as one that does
# not.
#
# WHAT THESE BLOCKS DO NOT PROVE. A set variable is not a Slurm job. Slurm is
# what puts `SLURM_JOB_ID` in a job's environment, and nothing here runs
# `sbatch`. The proof that a real job carries the variable is a submitted job,
# and it lives outside this suite.

test_that("neither variable set reports outside a job", {
  withr::local_envvar(c(SLURM_JOB_ID = NA, SLURM_JOBID = NA))
  expect_false(inside_slurm_job())
})

test_that("SLURM_JOB_ID reports inside a job", {
  withr::local_envvar(c(SLURM_JOB_ID = "17", SLURM_JOBID = NA))
  expect_true(inside_slurm_job())
})

test_that("SLURM_JOBID alone reports inside a job", {
  # The legacy name. A Slurm old enough to set it and not `SLURM_JOB_ID` still
  # started a job. Without the fallback, this function would report the payload
  # as the submitter.
  withr::local_envvar(c(SLURM_JOB_ID = NA, SLURM_JOBID = "17"))
  expect_true(inside_slurm_job())
})

test_that("a heterogeneous job id reports inside a job", {
  # A heterogeneous job carries `<id>+<offset>`, so the id is not all digits.
  # A digit check would report FALSE here, inside a genuine job, and the
  # payload would submit itself again.
  withr::local_envvar(c(SLURM_JOB_ID = "17+1", SLURM_JOBID = NA))
  expect_true(inside_slurm_job())
})

test_that("an empty value reports outside a job", {
  # `Sys.getenv()` answers "" for a variable that is not set, so an empty
  # value and an absent one MUST give one answer.
  withr::local_envvar(c(SLURM_JOB_ID = "", SLURM_JOBID = ""))
  expect_false(inside_slurm_job())
})

test_that("a whitespace-only job id reports inside a job", {
  # R/slurm_it.R, R/slurm_write.R and R/slurm_submit.R each reject a
  # whitespace-only field with `grepl("[^[:space:]]", x)`. This function does
  # not use that check. Slurm never writes such a value, so the only source is
  # a person. The two mistakes do not cost the same: a false negative makes the
  # payload submit itself.
  withr::local_envvar(c(SLURM_JOB_ID = " ", SLURM_JOBID = NA))
  expect_true(inside_slurm_job())
})

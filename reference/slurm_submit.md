# Submit a written Slurm job chain

Runs a `submit.sh` that
[`slurm_write()`](https://papadopoulos-lab.github.io/batchit/reference/slurm_write.md)
wrote, and returns the job ids the driver submitted. The names of the
returned vector are the stage names.

## Usage

``` r
slurm_submit(x)
```

## Arguments

- x:

  What to run. Three shapes reach the same driver.

  1.  The character vector
      [`slurm_write()`](https://papadopoulos-lab.github.io/batchit/reference/slurm_write.md)
      returned. Its last element is the `submit.sh` path.

  2.  A directory that holds `submit.sh`.

  3.  The path of a `submit.sh`.

  Any other value is an error. The named file MUST be `submit.sh`: a job
  file runs under Slurm, so running one here would run the job in this
  session.

## Value

Named character vector of job ids, in chain order. The names are the
stage names.

## Details

[`slurm_write()`](https://papadopoulos-lab.github.io/batchit/reference/slurm_write.md)
writes the chain and submits nothing. `slurm_submit()` submits it. They
stay separate calls, so a caller reads `submit.sh` between them:

    paths <- slurm_write(jobs, dir)
    writeLines(readLines(paths[[length(paths)]]))
    ids <- slurm_submit(paths)

## Where the ids come from

The driver prints one line for each submission, and `slurm_submit()`
reads those lines:

    batchit_submitted proj_s1 5512
    batchit_submitted proj_s2 5513

Nothing reads `sbatch`'s own output. The driver pipes that output
through `cut -d';' -f1`, because a federated cluster writes
`jobid;cluster` there.

`slurm_submit()` writes those lines to its own standard output before it
parses them. The driver writes to a temporary file that this call
deletes, so without the echo an interactive caller sees no submission at
all.

## What an error carries

A driver that exits non-zero stops this call. The error carries the
driver's standard error verbatim, because that text holds the diagnosis
and the repair. A drained node reports the `scontrol update` command
that resumes it.

The driver runs under `set -euo pipefail`. So an `sbatch` that fails
part way through a chain stops the driver with the earlier jobs ALREADY
QUEUED. The error then names each queued stage and its id, and it gives
the `scancel` command that cancels them.

## Two calls cannot both submit the same chain

The generated driver refuses a job name it finds in `squeue`, and it
fails closed. `slurm_submit()` adds no second check. One policy in one
place cannot disagree with itself.

## See also

[`vignette("batchit")`](https://papadopoulos-lab.github.io/batchit/articles/batchit.md),
section "Slurm: write a chain of jobs".

Other slurm:
[`inside_slurm_job()`](https://papadopoulos-lab.github.io/batchit/reference/inside_slurm_job.md),
[`slurm_it()`](https://papadopoulos-lab.github.io/batchit/reference/slurm_it.md),
[`slurm_status()`](https://papadopoulos-lab.github.io/batchit/reference/slurm_status.md),
[`slurm_write()`](https://papadopoulos-lab.github.io/batchit/reference/slurm_write.md)

## Examples

``` r
if (FALSE) { # \dontrun{
jobs <- list(
  slurm_it(
    script = "Rscript s1_build.R",
    name = "proj_s1",
    cpus = 6,
    mem = "85G",
    time = "12:00:00"
  ),
  slurm_it(
    script = "Rscript s2_report.R",
    name = "proj_s2",
    cpus = 2,
    mem = "8G",
    time = "01:00:00"
  )
)
paths <- slurm_write(jobs, "~/chain")
slurm_submit(paths)
} # }
```

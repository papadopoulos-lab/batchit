# Is this R process inside a Slurm job?

Reports whether Slurm started this R process. A script that submits
itself calls this, so it submits from the login session and never from
inside the job.

## Usage

``` r
inside_slurm_job()
```

## Value

`TRUE` when this process runs inside a Slurm job, and `FALSE` otherwise.

## Details

Without the test, the submitting branch runs inside the job as well, and
the job submits itself again:

    if (!inside_slurm_job()) {
      slurm_submit(slurm_write(jobs, dir))
      quit(save = "no")
    }
    # Below here runs inside the job.

## What it reads

It reads `SLURM_JOB_ID` first. It falls back to `SLURM_JOBID`, which the
`sbatch` manual page keeps for backward compatibility. Measured on Slurm
25.11.2: a login shell carries no `SLURM_` variable at all, and a
one-task job carries 33 of them.

Any non-empty value counts as inside a job. A digit check would be
wrong, because a heterogeneous job carries an id such as `17+1`. A false
negative there makes the payload submit itself, which costs more than a
false positive from a hand-set variable.

`plnr::is_run_directly()` does not answer this question. It tests the
call depth, not the environment. Measured on this machine, it returns
`TRUE` on the login node and inside a Slurm job.

## See also

[`vignette("batchit")`](https://papadopoulos-lab.github.io/batchit/articles/batchit.md),
section "Slurm: write a chain of jobs".

Other slurm:
[`slurm_it()`](https://papadopoulos-lab.github.io/batchit/reference/slurm_it.md),
[`slurm_status()`](https://papadopoulos-lab.github.io/batchit/reference/slurm_status.md),
[`slurm_submit()`](https://papadopoulos-lab.github.io/batchit/reference/slurm_submit.md),
[`slurm_write()`](https://papadopoulos-lab.github.io/batchit/reference/slurm_write.md)

## Examples

``` r
inside_slurm_job()
#> [1] FALSE
```

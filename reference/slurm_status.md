# Report what Slurm says about a job chain

Returns one row for each job, from the live queue and the accounting
database together. Call it with no argument for an overview, or with the
directory of a written chain for that chain alone.

## Usage

``` r
slurm_status(dir = NULL)
```

## Arguments

- dir:

  The directory
  [`slurm_write()`](https://papadopoulos-lab.github.io/batchit/reference/slurm_write.md)
  wrote a chain into, or `NULL` for the overview. A directory reports
  that chain's own jobs, and it adds the `out` and `err` columns.

## Value

A `data.frame`, one row for each job. Every column is character.

- `job_id`:

  The job id, as Slurm writes it. Measured against Slurm 25.11.2: one
  array task carries `<id>_<task>`, and a range of pending array tasks
  carries `<id>_[<first>-<last>]` in one row. Both commands write the
  same string, so such a job still appears once.

- `user`:

  The user who submitted the job.

- `name`:

  The job name.

- `state`:

  Slurm's own state name: `PENDING`, `RUNNING`, `COMPLETED`, `FAILED`,
  and the rest.

- `exit_code`:

  Slurm's `<exit>:<signal>` pair, and `NA` for a row the live queue
  supplied.

- `elapsed`:

  Wall-clock time, as its own source writes it. `sacct` writes
  `HH:MM:SS`, or `D-HH:MM:SS` past one day. `squeue` prints the days and
  the hours only where they are needed, so a job two seconds in reads
  `0:02`.

- `reason`:

  Why a job waits, such as `Dependency` or `Resources`. Slurm writes
  `None` where it reports no reason, and this function writes `NA` for a
  row the accounting database supplied.

- `out`, `err`:

  The `dir` form only. The job's log files, and `NA` where the file is
  absent.

The live rows come first, and the rows only the accounting database
holds follow them. A window that holds no job returns zero rows and
every column, so `x$state` on an empty result is `character(0)` and not
an error.

## Details

    slurm_status() # queued or running now, plus the last 7 days
    slurm_status("~/chain") # the jobs whose scripts live in that directory

## The two sources

`squeue` reports what is queued or running now, and it is the only
source of the pending `reason`. It forgets a job the moment that job
ends.

`sacct` reads the accounting database, so it reports the final state,
the exit code and the elapsed time of a job that finished. It carries no
reason.

A job that is queued or running appears in both. Its `squeue` row is the
one that reaches the caller, because that row carries the reason.

## Why a directory needs no R session

The session that submitted the chain is gone by the time anybody asks.
So the `dir` form reads the chain off disk, and it reads two kinds of
file.

Each job that started wrote `<name>_<job id>.out`, because
[`slurm_write()`](https://papadopoulos-lab.github.io/batchit/reference/slurm_write.md)
sets `#SBATCH --output=<dir>/<name>_%j.out`. Those job ids identify the
run exactly, and `sacct` receives them. A chain submitted twice
therefore reports the run whose logs are on disk.

A job that has not started yet wrote no log. Only `squeue` sees such a
job, and only by job name. The `.sh` files that
[`slurm_write()`](https://papadopoulos-lab.github.io/batchit/reference/slurm_write.md)
wrote supply those names.

The `sacct` window starts at the oldest modification time of those
files, the `.sh` scripts and the `.out` logs together.

## The pending rows come from a name match

A job name is not unique, so `squeue` MAY return a job that is not this
chain's. Another user runs a job of the same name, or a later submission
of this chain sits in the queue.

## It refuses rather than reports calm

A scheduler that cannot answer stops the call. An absent `squeue` or
`sacct`, a non-zero exit, and a line the parser cannot read are each an
error that names the command.

The `-S` flag is why that matters. `sacct` defaults to the jobs that
started today, and it reports an empty result for a window that holds
nothing. A chain started on Monday would read as "nothing is running" on
Wednesday. Every `sacct` call here passes `-S`.

A window that genuinely holds no job is a different case, and it is not
an error.

## There is no memory column

`MaxRSS` is empty for every job on Slurm 25.11.2, and a blank memory
column reads as "the job used no memory".
[`slurm_write()`](https://papadopoulos-lab.github.io/batchit/reference/slurm_write.md)
writes the real peak into each job's own `.out` file, from the cgroup v2
counter of the job's own cgroup. Read it there.

## See also

[`vignette("batchit")`](https://papadopoulos-lab.github.io/batchit/articles/batchit.md),
section "Slurm: write a chain of jobs".

Other slurm:
[`inside_slurm_job()`](https://papadopoulos-lab.github.io/batchit/reference/inside_slurm_job.md),
[`slurm_it()`](https://papadopoulos-lab.github.io/batchit/reference/slurm_it.md),
[`slurm_submit()`](https://papadopoulos-lab.github.io/batchit/reference/slurm_submit.md),
[`slurm_write()`](https://papadopoulos-lab.github.io/batchit/reference/slurm_write.md)

## Examples

``` r
if (FALSE) { # \dontrun{
slurm_status()
slurm_status("~/chain")
} # }
```

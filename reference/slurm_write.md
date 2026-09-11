# Write a Slurm job chain

Writes one bash file for each job, plus `submit.sh`. It submits nothing.

## Usage

``` r
slurm_write(x, dir)
```

## Arguments

- x:

  One `slurm_it` object, or a list of them. List position is chain
  order: job `i` waits for job `i - 1` to succeed. Every job MUST take
  its own `name`, and no job may take the name `submit`.

- dir:

  Character(1). The directory to write into. `slurm_write()` creates it
  when it is absent, and it owns every `*.sh` file in it. The path MUST
  hold no whitespace character, because it reaches `#SBATCH --output=`.

## Value

Character vector of the paths written, invisibly. The job paths come
first, in chain order, and the `submit.sh` path comes last. Every path
is mode 0755.

## Details

`slurm_write()` owns `dir`. It deletes every `*.sh` file there before it
writes. The caller regenerates the chain on every run. So a chain of
four written over a chain of five MUST NOT leave the fifth job file
behind. The new `submit.sh` does not name that file, and it still runs
by hand.

`submit.sh` is the only generated file that names the submission
command. A job file runs under Slurm and knows nothing about the chain.

## What every job file carries

Four items reach every job file, and no argument controls them.

1.  The output and error paths, under `dir`.

2.  A start timestamp, before the job body.

3.  Peak memory, read on exit.

4.  An end timestamp and the exit code, from an `EXIT` trap.

Item 3 reads the cgroup v2 counter of the job's own cgroup. The job
derives that path at run time from `/proc/self/cgroup`. The root counter
`/sys/fs/cgroup/memory.peak` is not readable inside a Slurm job.

A job that cannot read its counter prints
`batchit_peak_memory_unavailable`. It reports no number. batchit reads
no second counter. `VmHWM` from `/proc/self/status` measures the job's
own shell. It read 4,744 kB against a payload that held 2,000,000,000
bytes in a child R process.

The option `batchit.memory_peak_path` names an explicit counter and
turns the derivation off. Set it where the cluster keeps the counter
somewhere else.

The trap captures the exit status in its first statement. So the job
reports the status its body exited with, and not the status of the
trap's own work.

A job file runs under `set -euo pipefail`. The body stops at its first
failing command, which is what a chain built on `--dependency=afterok`
needs.

## The version gate and its interpreter

A job that names `require_r_package` carries a version gate before its
body. The gate MUST NOT depend on the environment that starts the job.
So it runs the interpreter under `env -u R_TESTS`. It also names that
interpreter by an absolute path.

The path defaults to `file.path(R.home("bin"), "Rscript")`, which is the
R that writes the chain. Set the option `batchit.rscript_path` where the
compute node keeps R somewhere else. A bare `Rscript` would name
whichever one comes first on the node's `PATH`. A gate that cannot say
which R it asked proves nothing about a version.

`R CMD check` exports `R_TESTS`, and every subprocess inherits it. So
this matters to a package that tests a generated job under
`R CMD check`. A production Slurm job carries no `R_TESTS`, so the unset
costs nothing there.

The gate prints the version it read, as `batchit: <package> <version>`.
The job log then names the version the work ran under, and not only the
version a refusal wanted.

The job then puts the directory of that interpreter first on `PATH`, and
it does so after the gate. A bare `Rscript` in the body is therefore the
binary the gate checked. The gate itself still reads the `PATH` the job
started with, so a dummy `Rscript` first on that `PATH` cannot reach it.

## What `submit.sh` checks before it submits

`submit.sh` runs two checks. A refusal writes `batchit: REFUSED:` to
standard error, exits 1, and submits nothing.

1.  EVERY state `sinfo` reports for the node MUST be `idle`, `mixed` or
    `allocated`. The driver names the node with `hostname -s`. It
    deletes the trailing `*` that marks a node slurmctld cannot reach.
    It joins with commas the several lines that a node in more than one
    partition emits, then tests each one. A node drained in one
    partition and idle in another reports `drained,idle`, and it cannot
    run the job.

2.  A job name in the chain MUST NOT already appear in `squeue`. This
    check fails closed. A `squeue` that exits non-zero refuses the
    submission, because it leaves a duplicate possible.

The node check reads the node the driver itself runs on. Run `submit.sh`
on a login node, and `hostname -s` names that login node.

## What the tests of `submit.sh` do not prove

The tests drive the generated `submit.sh` with stub `hostname`, `sinfo`,
`squeue` and `sbatch` programs on `PATH`. So they prove the shell
branching against a protocol the tests wrote. Four things stay unproven.

1.  The argument spelling that the real `sinfo` and `squeue` accept.

2.  The output grammar that the real `sinfo` and `squeue` produce.

3.  Which users' jobs `squeue` reports. The check reads every job the
    caller can see, and no option scopes it to one user.

4.  That two `submit.sh` runs started at the same time cannot both pass.
    Each one reads `squeue` before either one submits.

## See also

[`vignette("batchit")`](https://papadopoulos-lab.github.io/batchit/articles/batchit.md),
section "Slurm: write a chain of jobs".

Other slurm:
[`inside_slurm_job()`](https://papadopoulos-lab.github.io/batchit/reference/inside_slurm_job.md),
[`slurm_it()`](https://papadopoulos-lab.github.io/batchit/reference/slurm_it.md),
[`slurm_status()`](https://papadopoulos-lab.github.io/batchit/reference/slurm_status.md),
[`slurm_submit()`](https://papadopoulos-lab.github.io/batchit/reference/slurm_submit.md)

## Examples

``` r
dir <- file.path(tempdir(), "batchit-chain")
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
paths <- slurm_write(jobs, dir)
basename(paths)
#> [1] "proj_s1.sh" "proj_s2.sh" "submit.sh" 
unlink(dir, recursive = TRUE)
```

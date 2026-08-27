# Package index

## Dispatch a function across subprocesses

Run one function over many items, in worker processes: a fresh one per
item for the first three, a reused pool for the fourth. Each takes `fn`,
either a
[`package_function()`](https://papadopoulos-lab.github.io/batchit/reference/package_function.md)
descriptor (hash-verified) or a bare closure for all but the streaming
function. They differ in how each item’s data arrives and in what comes
back, a return value or declared output files that batchit stages and
then commits.

- [`run()`](https://papadopoulos-lab.github.io/batchit/reference/run.md)
  : Run a function once per item, in a fresh worker process, discarding
  the results

- [`run_and_collect()`](https://papadopoulos-lab.github.io/batchit/reference/run_and_collect.md)
  : Run a function once per item, in a fresh worker process, and collect
  the results

- [`run_and_write_files_atomically()`](https://papadopoulos-lab.github.io/batchit/reference/run_and_write_files_atomically.md)
  : Run a function once per item, in a fresh worker process, and have
  batchit write its output files safely

- [`stream_from_parent_and_write_files_atomically()`](https://papadopoulos-lab.github.io/batchit/reference/stream_from_parent_and_write_files_atomically.md)
  :

  Like
  [`run_and_write_files_atomically()`](https://papadopoulos-lab.github.io/batchit/reference/run_and_write_files_atomically.md),
  but build each item lazily instead of all at once

## Building a dispatch

Helpers used when constructing a dispatch: name the target function
(hash-verified against what the worker loads), and, inside a
`staged_writer` target, resolve where to write a declared output.

- [`package_function()`](https://papadopoulos-lab.github.io/batchit/reference/package_function.md)
  : Identify a function in an installed package, so a worker can run it
- [`where_to_write_output()`](https://papadopoulos-lab.github.io/batchit/reference/where_to_write_output.md)
  : Get the path to write one declared output to, inside a
  "staged_writer" function

## Writing one file atomically

A standalone atomic qs2 writer, usable on its own with no dispatch: it
writes to a temporary file beside the destination and renames it into
place, so the destination is never a truncated file. Independent of the
[`run_and_write_files_atomically()`](https://papadopoulos-lab.github.io/batchit/reference/run_and_write_files_atomically.md)
commit engine.

- [`write_qs2_atomically()`](https://papadopoulos-lab.github.io/batchit/reference/write_qs2_atomically.md)
  : Atomically write an object to a qs2 file

## Running a chain of Slurm jobs

The route for work too long to sit in one R session.
[`slurm_it()`](https://papadopoulos-lab.github.io/batchit/reference/slurm_it.md)
validates one job description.
[`slurm_write()`](https://papadopoulos-lab.github.io/batchit/reference/slurm_write.md)
turns a list of them into one bash file per job, plus the `submit.sh`
driver, and it submits nothing.
[`slurm_submit()`](https://papadopoulos-lab.github.io/batchit/reference/slurm_submit.md)
runs that driver and returns the job ids, named by stage.
[`slurm_status()`](https://papadopoulos-lab.github.io/batchit/reference/slurm_status.md)
reports what the live queue and the accounting database say about those
jobs.
[`inside_slurm_job()`](https://papadopoulos-lab.github.io/batchit/reference/inside_slurm_job.md)
reports whether this R process runs inside a Slurm job, which is what a
self-submitting script needs to know.

- [`slurm_it()`](https://papadopoulos-lab.github.io/batchit/reference/slurm_it.md)
  : Describe one Slurm job
- [`slurm_write()`](https://papadopoulos-lab.github.io/batchit/reference/slurm_write.md)
  : Write a Slurm job chain
- [`slurm_submit()`](https://papadopoulos-lab.github.io/batchit/reference/slurm_submit.md)
  : Submit a written Slurm job chain
- [`slurm_status()`](https://papadopoulos-lab.github.io/batchit/reference/slurm_status.md)
  : Report what Slurm says about a job chain
- [`inside_slurm_job()`](https://papadopoulos-lab.github.io/batchit/reference/inside_slurm_job.md)
  : Is this R process inside a Slurm job?

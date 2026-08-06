# batchit: run one R function across many parallel worker processes

`batchit` runs one R function once per item in a list of inputs, each
call in its own worker process. It then either collects the return
values, or has the worker write output files for you. Pick one of four
functions, depending on what you need:

## Details

|  |  |
|----|----|
| Your situation | Use |
| Items already exist; run for side effects, ignore the return values | [`run()`](https://papadopoulos-lab.github.io/batchit/reference/run.md) |
| Items already exist; collect the return values | [`run_and_collect()`](https://papadopoulos-lab.github.io/batchit/reference/run_and_collect.md) |
| Items already exist; let batchit write output files atomically | [`run_and_write_files_atomically()`](https://papadopoulos-lab.github.io/batchit/reference/run_and_write_files_atomically.md) |
| Too many/too-large items to build up front; build them lazily and write files | [`stream_from_parent_and_write_files_atomically()`](https://papadopoulos-lab.github.io/batchit/reference/stream_from_parent_and_write_files_atomically.md) |

Each item is a named list. It holds the arguments for one call to your
function. Every argument must be named, including one that has a default
value. Your function can be an inline function you write directly in the
call. It can instead be a reference to a function in an installed
package, built by
[`package_function()`](https://papadopoulos-lab.github.io/batchit/reference/package_function.md).
See that function's help page for when to prefer one over the other.

See
[`vignette("batchit")`](https://papadopoulos-lab.github.io/batchit/articles/batchit.md)
for a worked example of each function. It also gives the rules an inline
function must follow, and exactly what the atomic-write guarantee
covers.

## Advanced

[`run()`](https://papadopoulos-lab.github.io/batchit/reference/run.md),
[`run_and_collect()`](https://papadopoulos-lab.github.io/batchit/reference/run_and_collect.md),
and
[`run_and_write_files_atomically()`](https://papadopoulos-lab.github.io/batchit/reference/run_and_write_files_atomically.md)
each run their items in a fresh `processx` subprocess, one per item.
[`stream_from_parent_and_write_files_atomically()`](https://papadopoulos-lab.github.io/batchit/reference/stream_from_parent_and_write_files_atomically.md)
instead runs its items on persistent `mirai` background workers. Items
can then be produced lazily, under a bounded amount of in-flight memory,
rather than built into one list up front.

When `fn` is a
[`package_function()`](https://papadopoulos-lab.github.io/batchit/reference/package_function.md)
reference, batchit checks that each worker loaded the exact same
function definition your R session did. That check is a hash of the
function's body and arguments. batchit also validates every item's
argument names against the function's own arguments, in both your R
session and the worker, before anything runs. batchit does not change
BLAS or `data.table` thread settings. If your function is itself
multi-threaded, divide your CPU cores across `n_workers` yourself.

## See also

Useful links:

- <https://papadopoulos-lab.github.io/batchit/>

- <https://github.com/papadopoulos-lab/batchit>

- Report bugs at <https://github.com/papadopoulos-lab/batchit/issues>

## Author

**Maintainer**: Richard Aubrey White <hello@rwhite.no>
([ORCID](https://orcid.org/0000-0002-6747-1726))

Authors:

- Richard Aubrey White <hello@rwhite.no>
  ([ORCID](https://orcid.org/0000-0002-6747-1726))

# Run a function once per item, in a fresh worker process, and have batchit write its output files safely

Use this when each item's job is to produce one or more files. You get a
guarantee that a failed or interrupted item never leaves a half-written
file at its final path. Each item runs `fn` in its own, brand-new R
process (a worker), with up to `n_workers` running at the same time,
like
[`run()`](https://papadopoulos-lab.github.io/batchit/reference/run.md)
and
[`run_and_collect()`](https://papadopoulos-lab.github.io/batchit/reference/run_and_collect.md).
But `fn`'s return value does not cross back to you. batchit writes the
files you declared in `outputs`, and hands back a small record of what
it wrote.

## Usage

``` r
run_and_write_files_atomically(
  fn,
  items,
  outputs,
  style = "return",
  n_workers,
  dev_path = NULL,
  p = NULL,
  label = NULL,
  timeout = .BATCH_DEFAULT_TIMEOUT,
  target = NULL
)
```

## Arguments

- fn:

  The function to run once per item. Either an inline function written
  directly in this call, or an object from
  [`package_function()`](https://papadopoulos-lab.github.io/batchit/reference/package_function.md)
  naming a function in an installed package. An inline function must be
  self-contained: it may only use its own arguments, base R
  functions/operators, and `pkg::fun()`-qualified calls to other
  packages. That includes a call to
  [`where_to_write_output()`](https://papadopoulos-lab.github.io/batchit/reference/where_to_write_output.md),
  which MUST be written as
  [`batchit::where_to_write_output()`](https://papadopoulos-lab.github.io/batchit/reference/where_to_write_output.md).
  See
  [`run()`](https://papadopoulos-lab.github.io/batchit/reference/run.md)'s
  Advanced section for accepted and rejected examples.

- items:

  One entry per call. Each entry is a named list holding the arguments
  for that one call to `fn`. Every argument `fn` takes MUST be named,
  including one that has a default value. An omitted optional argument
  is treated as a mistake, not as "use the default". A named entry keeps
  its name as that item's id; an unnamed entry is identified by its
  position instead (1, 2, 3, and so on). An item id MUST NOT contain `/`
  or `\`, because batchit builds an internal bookkeeping filename from
  it; see
  [`vignette("batchit")`](https://papadopoulos-lab.github.io/batchit/articles/batchit.md).

- outputs:

  The files `fn` must produce for each item. One element per item, in
  the same order as `items`. When `items` is named, you may instead name
  `outputs` the same way, with the same names in any order. Each element
  is a named character vector giving the FINAL path for each declared
  output, e.g. `c(main = "/path/to/result.qs2")`. Every path MUST be
  absolute. Every destination MUST either not exist yet, or already be
  an ordinary file, not a directory and not a symlink. Every path,
  across every item in this one call, MUST be unique.

- style:

  `"return"` (the default) or `"staged_writer"`. See the description
  above for what each means for `fn`. Any other value errors.

- n_workers:

  How many items to run at the same time (a whole number, 1 or more).

- dev_path:

  Advanced; see
  [`run()`](https://papadopoulos-lab.github.io/batchit/reference/run.md)'s
  Advanced section. Leave as `NULL` (the default) to run the installed
  version of your package.

- p:

  A progress callback, such as a `progressr` progressor.

- label:

  An optional short label added to each progress message.

- timeout:

  Maximum time, in seconds, to let one item's worker run before killing
  it and reporting it as failed; see
  [`run()`](https://papadopoulos-lab.github.io/batchit/reference/run.md).

- target:

  Deprecated former name of `fn`, kept for old callers. Pass `fn`
  instead; supplying both is an error.

## Value

A list, one element per item, **in the same order as `items`**, named by
item id. Each element describes what was written. Its shape is
`list(committed = <named character vector: output name -> final path actually written>, attempt = <an internal per-item identifier; you can ignore this>)`.
Never `fn`'s raw return value.

## Details

**The guarantee, and its boundary.** batchit stages every one of an
item's declared outputs before it replaces any final file. Each staged
file goes to a temporary file in its final destination's own directory.
batchit then replaces the final files one at a time, by rename, and
writes the commit marker last.

The guarantee differs across those three phases.

BEFORE THE FIRST REPLACEMENT: fully covered. The item can fail here in
four ways:

- an error in `fn`;

- a `"return"` value whose names do not match the declared outputs;

- a declared output a `"staged_writer"` never wrote;

- a failure serializing a staged file.

In each case NO declared output is touched, and whatever was already at
those paths (or nothing, if they didn't exist) is left untouched. The
item's own previous marker is removed before the first replacement, so
it does not survive even here.

DURING THE REPLACEMENT LOOP: not transactional. A kill or a rename
failure partway through it can leave some of the item's outputs replaced
and others not. batchit never rolls back a final it already renamed. An
individual file is not left half-written, since rename replacement is
atomic under the filesystem semantics batchit supports. But the SET can
be torn, and a torn set has no valid marker vouching for it.

AFTER THE MARKER IS WRITTEN: committed, even if the call reports
failure. The worker serializes its result envelope only after it
commits. A failure in that window leaves every final and the marker
correctly in place, while the item is reported as failed.

A `timeout` is NOT confined to one phase: it measures the worker's whole
lifetime and can land in any of the three, including mid-commit.

batchit never treats an existing output file as a reason to skip an
item. It schedules every item, subject only to validation or an earlier
failure stopping the call first.

There are two ways for `fn` to produce its declared outputs, chosen with
`style`:

- `style = "return"` (the default): `fn` returns a named list, one
  element per declared output, with names matching `outputs` exactly.
  batchit saves each value to its file, in the `qs2` format. Read it
  back with
  [`qs2::qs_read()`](https://rdrr.io/pkg/qs2/man/qs_read.html).

- `style = "staged_writer"`: `fn` writes each output itself, to the path
  given by
  [`where_to_write_output()`](https://papadopoulos-lab.github.io/batchit/reference/where_to_write_output.md)`(<name>)`;
  its return value is ignored. Use this when `fn` already writes files
  on its own, for example in a format other than `qs2`, or via another
  package's own writer. `fn` then does not have to build the whole
  object in memory, just to hand it back for batchit to save again.

Use
[`run()`](https://papadopoulos-lab.github.io/batchit/reference/run.md)
or
[`run_and_collect()`](https://papadopoulos-lab.github.io/batchit/reference/run_and_collect.md)
instead if you are happy to manage your own output files without this
guarantee. Use them also if you want a value back in R rather than files
on disk. Use
[`stream_from_parent_and_write_files_atomically()`](https://papadopoulos-lab.github.io/batchit/reference/stream_from_parent_and_write_files_atomically.md)
instead if building every item up front (as a plain list, the way
`items` works here) would use too much memory.

## Advanced

Uses the same fresh-worker-per-item transport as
[`run()`](https://papadopoulos-lab.github.io/batchit/reference/run.md)
and
[`run_and_collect()`](https://papadopoulos-lab.github.io/batchit/reference/run_and_collect.md),
one `processx` subprocess per item. It also uses the same code-identity
check when `fn` is a
[`package_function()`](https://papadopoulos-lab.github.io/batchit/reference/package_function.md)
reference. See
[`run()`](https://papadopoulos-lab.github.io/batchit/reference/run.md)'s
Advanced section for both.

After an item commits successfully, batchit leaves a small bookkeeping
file named `.batchit__<item id>`, as its own record that this run
finished writing every declared file. There is ONE marker per item, in
the directory of that item's lexicographically first declared output
path. That is beside the outputs when they share a directory, and in one
of them when they do not. Do not create, read, or rely on a file with
that name yourself. batchit manages it entirely, and overwrites it
cleanly the next time that item id is committed.

## See also

[`where_to_write_output()`](https://papadopoulos-lab.github.io/batchit/reference/where_to_write_output.md),
which `fn` calls under `style = "staged_writer"`, and
[`write_qs2_atomically()`](https://papadopoulos-lab.github.io/batchit/reference/write_qs2_atomically.md)
for the same rename-into-place guarantee on a single file with no
dispatch.

[`vignette("batchit")`](https://papadopoulos-lab.github.io/batchit/articles/batchit.md)
states exactly what the atomic-write guarantee covers in each of its
three phases.

Other dispatch functions:
[`run()`](https://papadopoulos-lab.github.io/batchit/reference/run.md),
[`run_and_collect()`](https://papadopoulos-lab.github.io/batchit/reference/run_and_collect.md),
[`stream_from_parent_and_write_files_atomically()`](https://papadopoulos-lab.github.io/batchit/reference/stream_from_parent_and_write_files_atomically.md)

## Examples

``` r
# \donttest{
# style = "return": fn returns a named list, and batchit saves each
# value to its declared path (as qs2 files).
make_two_values <- function(x) list(squared = x^2, doubled = x * 2)

out_dir <- file.path(tempdir(), "batchit-return-example")
dir.create(out_dir)
result <- run_and_write_files_atomically(
  fn = make_two_values,
  items = list(list(x = 2), list(x = 3)),
  outputs = list(
    c(squared = file.path(out_dir, "sq_1.qs2"), doubled = file.path(out_dir, "db_1.qs2")),
    c(squared = file.path(out_dir, "sq_2.qs2"), doubled = file.path(out_dir, "db_2.qs2"))
  ),
  n_workers = 2
)
#>   [0/2] dispatching workers...
#>   [1/2] complete  09:35:40
#>   [2/2] complete  09:35:40
result
#> $`1`
#> $`1`$committed
#>                                           squared 
#> "/tmp/RtmpCi4CoX/batchit-return-example/sq_1.qs2" 
#>                                           doubled 
#> "/tmp/RtmpCi4CoX/batchit-return-example/db_1.qs2" 
#> 
#> $`1`$attempt
#> [1] "1ad7512fb955"
#> 
#> 
#> $`2`
#> $`2`$committed
#>                                           squared 
#> "/tmp/RtmpCi4CoX/batchit-return-example/sq_2.qs2" 
#>                                           doubled 
#> "/tmp/RtmpCi4CoX/batchit-return-example/db_2.qs2" 
#> 
#> $`2`$attempt
#> [1] "1ad7259cb5a8"
#> 
#> 
qs2::qs_read(file.path(out_dir, "sq_1.qs2")) # 4
#> [1] 4

# style = "staged_writer": fn writes each output itself. See
# ?where_to_write_output for a complete example.

unlink(out_dir, recursive = TRUE)
# }
```

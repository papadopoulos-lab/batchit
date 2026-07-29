# Run a function once per item, in a fresh worker process, and have batchit write its output files safely

Use this when each item's job is to produce one or more files, and you
want a guarantee that a failed or interrupted item never leaves a
half-written file at its final path. Each item runs `fn` in its own,
brand-new R process (a worker), with up to `n_workers` running at the
same time – like
[`run()`](https://papadopoulos-lab.github.io/batchit/reference/run.md)
and
[`run_and_collect()`](https://papadopoulos-lab.github.io/batchit/reference/run_and_collect.md)
– but instead of `fn`'s return value crossing back to you, batchit
writes the files you declared in `outputs` and hands back a small record
of what it wrote.

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
  packages (including a call to
  [`where_to_write_output()`](https://papadopoulos-lab.github.io/batchit/reference/where_to_write_output.md),
  which must be written as
  [`batchit::where_to_write_output()`](https://papadopoulos-lab.github.io/batchit/reference/where_to_write_output.md))
  – see
  [`run()`](https://papadopoulos-lab.github.io/batchit/reference/run.md)'s
  Advanced section for accepted and rejected examples.

- items:

  One entry per call. Each entry is a named list holding the arguments
  for that one call to `fn` – every argument `fn` takes must be named,
  including ones with a default value (an omitted optional argument is
  treated as a mistake, not "use the default"). A named entry keeps its
  name as that item's id; an unnamed entry is identified by its position
  instead (1, 2, 3, ...). Item ids must not contain `/` or `\` (they're
  used to build an internal bookkeeping filename – see the Advanced
  section of the package README).

- outputs:

  The files `fn` must produce for each item. One element per item, in
  the same order as `items` (or, when `items` is named, you may instead
  name `outputs` the same way – same names, any order). Each element is
  a named character vector giving the FINAL path for each declared
  output, e.g. `c(main = "/path/to/result.qs2")`. Every path must be
  absolute; every destination must either not exist yet, or already be
  an ordinary file (not a directory or a symlink); and every path,
  across every item in this one call, must be unique.

- style:

  `"return"` (the default) or `"staged_writer"` – see the description
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
item id. Each element describes what was written –
`list(committed = <named character vector: output name -> final path actually written>, attempt = <an internal per-item identifier; you can ignore this>)`.
Never `fn`'s raw return value.

## Details

**The guarantee, and its boundary.** batchit stages every one of an
item's declared outputs – each to a temporary file in its final
destination's own directory – before it replaces any final file. It then
replaces the final files one at a time, by rename, and writes the commit
marker last.

The guarantee differs across those three phases.

BEFORE THE FIRST REPLACEMENT – fully covered. An error in `fn`, a
`"return"` value whose names do not match the declared outputs, a
declared output a `"staged_writer"` never wrote, a failure serializing a
staged file – in each case NO declared output is touched, and whatever
was already at those paths (or nothing, if they didn't exist) is left
untouched. The item's own previous marker is removed before the first
replacement, so it does not survive even here.

DURING THE REPLACEMENT LOOP – not transactional. A kill or a rename
failure partway through it can leave some of the item's outputs replaced
and others not; batchit never rolls back a final it has already renamed.
An individual file is not left half-written – rename replacement is
atomic under the filesystem semantics batchit supports – but the SET can
be torn, and a torn set has no valid marker vouching for it.

AFTER THE MARKER IS WRITTEN – committed, even if the call reports
failure. The worker serializes its result envelope only after
committing, so a failure in that window leaves every final and the
marker correctly in place while the item is reported as failed.

A `timeout` is NOT confined to one phase: it measures the worker's whole
lifetime and can land in any of the three, including mid-commit.

batchit never treats an existing output file as a reason to skip an
item; it schedules every item, subject to validation or an earlier
failure stopping the call first.

There are two ways for `fn` to produce its declared outputs, chosen with
`style`:

- `style = "return"` (the default): `fn` returns a named list, one
  element per declared output, with names matching `outputs` exactly;
  batchit saves each value to its file (in the `qs2` format – read it
  back with
  [`qs2::qs_read()`](https://rdrr.io/pkg/qs2/man/qs_read.html)).

- `style = "staged_writer"`: `fn` writes each output itself, to the path
  given by
  [`where_to_write_output()`](https://papadopoulos-lab.github.io/batchit/reference/where_to_write_output.md)`(<name>)`;
  its return value is ignored. Use this when `fn` already writes files
  on its own (for example, in a format other than `qs2`, or via another
  package's own writer), so it doesn't have to build the whole object in
  memory just to hand it back for batchit to save again.

Use
[`run()`](https://papadopoulos-lab.github.io/batchit/reference/run.md)
or
[`run_and_collect()`](https://papadopoulos-lab.github.io/batchit/reference/run_and_collect.md)
instead if you're happy managing your own output files without this
guarantee, or want a value back in R rather than files on disk. Use
[`stream_from_parent_and_write_files_atomically()`](https://papadopoulos-lab.github.io/batchit/reference/stream_from_parent_and_write_files_atomically.md)
instead if building every item up front (as a plain list, the way
`items` works here) would use too much memory.

## Advanced

Uses the same fresh-worker-per-item transport as
[`run()`](https://papadopoulos-lab.github.io/batchit/reference/run.md)
and
[`run_and_collect()`](https://papadopoulos-lab.github.io/batchit/reference/run_and_collect.md)
(one `processx` subprocess per item), and the same code-identity check
when `fn` is a
[`package_function()`](https://papadopoulos-lab.github.io/batchit/reference/package_function.md)
reference – see
[`run()`](https://papadopoulos-lab.github.io/batchit/reference/run.md)'s
Advanced section for both.

After an item commits successfully, batchit leaves a small bookkeeping
file named `.batchit__<item id>`, as its own record that this run
finished writing every declared file. There is ONE marker per item, in
the directory of that item's lexicographically first declared output
path – beside the outputs when they share a directory, and in one of
them when they do not. Don't create, read, or rely on a file with that
name yourself; batchit manages it entirely, and overwrites it cleanly
the next time that item id is committed.

## Examples

``` r
if (FALSE) { # \dontrun{
# style = "return": fn returns a named list, and batchit saves each
# value to its declared path (as qs2 files).
make_two_values <- function(x) list(squared = x^2, doubled = x * 2)

out_dir <- tempdir()
result <- run_and_write_files_atomically(
  fn = make_two_values,
  items = list(list(x = 2), list(x = 3)),
  outputs = list(
    c(squared = file.path(out_dir, "sq_1.qs2"), doubled = file.path(out_dir, "db_1.qs2")),
    c(squared = file.path(out_dir, "sq_2.qs2"), doubled = file.path(out_dir, "db_2.qs2"))
  ),
  n_workers = 2
)
result
qs2::qs_read(file.path(out_dir, "sq_1.qs2")) # 4

# style = "staged_writer": fn writes each output itself -- see
# ?where_to_write_output for a complete example.
} # }
```

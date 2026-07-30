# Like [`run_and_write_files_atomically()`](https://papadopoulos-lab.github.io/batchit/reference/run_and_write_files_atomically.md), but build each item lazily instead of all at once

Use this when building the full `items` list up front (the way
[`run()`](https://papadopoulos-lab.github.io/batchit/reference/run.md),
[`run_and_collect()`](https://papadopoulos-lab.github.io/batchit/reference/run_and_collect.md),
and
[`run_and_write_files_atomically()`](https://papadopoulos-lab.github.io/batchit/reference/run_and_write_files_atomically.md)
all require) would itself use too much memory, for example when each
item is a large data slice, or there are far too many items to hold as a
list at once. Instead of an `items` list, you give an `ids` vector and a
`producer(id)` function that builds one item's arguments at a time.
batchit keeps at most `min(2 * n_workers, length(ids))` items in flight
and calls `producer()` only when one of those slots is free, which is
what bounds how many produced items exist at once. A free slot is not
the same as an idle worker: when every worker is busy, roughly
`n_workers` further items may already be produced and queued. Everything
else works like
[`run_and_write_files_atomically()`](https://papadopoulos-lab.github.io/batchit/reference/run_and_write_files_atomically.md):
each item's function runs on a background worker, and its declared
output files are written safely. See that function's help page for the
atomic-write guarantee and the two `style`s.

## Usage

``` r
stream_from_parent_and_write_files_atomically(
  fn,
  ids,
  producer,
  outputs,
  style = "return",
  n_workers,
  dev_path = NULL,
  p = NULL,
  label = NULL,
  timeout = .BATCH_DEFAULT_TIMEOUT
)
```

## Arguments

- fn:

  An object from
  [`package_function()`](https://papadopoulos-lab.github.io/batchit/reference/package_function.md),
  naming a function in an installed package. An inline function is not
  accepted here.

- ids:

  One id per item, in the order you want items produced and run. Must be
  unique, non-missing values (coerced to character).

- producer:

  A function of one argument, an item's id, that builds and returns that
  one item: a named list holding all of `fn`'s arguments, exactly as one
  element of `items` would be for
  [`run_and_write_files_atomically()`](https://papadopoulos-lab.github.io/batchit/reference/run_and_write_files_atomically.md).
  Called once per id, in your R session (never on a worker), only when
  one of the `min(2 * n_workers, length(ids))` in-flight slots is free.
  So load or build each item's data inside this function, rather than
  before calling `stream_from_parent_and_write_files_atomically()`.

- outputs:

  A list aligned to `ids`: `outputs[[i]]` is item `i`'s output map, a
  named character vector `c(<name> = <final path>)`. May instead be
  named by item id (same name set as `ids`, any order). Same rules as
  [`run_and_write_files_atomically()`](https://papadopoulos-lab.github.io/batchit/reference/run_and_write_files_atomically.md)'s
  `outputs`: every path absolute; every destination absent or an
  existing plain file (not a directory or a symlink); every output path,
  across every item in this one call, unique.

- style:

  `"return"` (the target returns a named list) or `"staged_writer"` (the
  target writes each output via
  [`where_to_write_output()`](https://papadopoulos-lab.github.io/batchit/reference/where_to_write_output.md)
  instead). See
  [`run_and_write_files_atomically()`](https://papadopoulos-lab.github.io/batchit/reference/run_and_write_files_atomically.md)
  for what each means. Any other value errors.

- n_workers:

  Number of persistent background workers (`mirai` daemons) to run at
  once.

- dev_path:

  The source tree of the package named in `fn`, loaded once per worker
  with
  [`devtools::load_all()`](https://devtools.r-lib.org/reference/load_all.html),
  instead of using the installed package. Leave as `NULL` (the default)
  to use the installed package. A path that doesn't exist, or doesn't
  match that package, is an error, even when there turn out to be no
  items to run.

- p:

  A progress callback, such as a `progressr` progressor.

- label:

  An optional short label added to each progress message.

- timeout:

  Maximum time, in seconds, to let one item run before it is treated as
  failed (6 hours by default; `Inf` disables the limit).

## Value

A list, named by id, **in the same order as `ids`**: each element
describes what that item wrote, as
`list(committed = <named character vector: output name -> final path written>, attempt = <an internal per-item identifier; you can ignore this>)`.
Never `fn`'s raw return value.

## Details

Two restrictions specific to this function. `fn` must be an object from
[`package_function()`](https://papadopoulos-lab.github.io/batchit/reference/package_function.md),
because an inline function is not accepted here, unlike
[`run_and_write_files_atomically()`](https://papadopoulos-lab.github.io/batchit/reference/run_and_write_files_atomically.md).
And it requires the `mirai` package to be installed. There is also no
way to get a raw return value back; only the output-file record
described below, exactly as in
[`run_and_write_files_atomically()`](https://papadopoulos-lab.github.io/batchit/reference/run_and_write_files_atomically.md).

## Advanced

This function runs its workers as persistent `mirai` daemons, in a
private compute profile it creates and tears down for this call only. It
never touches or resets any daemon configuration you already had outside
this call. A background worker loads the package named in `fn` once,
when it starts (not once per item).

At most `2 * n_workers` items are in flight at once, each carrying its
own `timeout`: `producer()` is not called again until an in-flight slot
frees up, which is what keeps memory bounded. An item that hangs past
its timeout resolves as an error instead of blocking the others forever.

As with
[`run()`](https://papadopoulos-lab.github.io/batchit/reference/run.md)/[`run_and_collect()`](https://papadopoulos-lab.github.io/batchit/reference/run_and_collect.md),
batchit does not set BLAS or `data.table` thread counts; divide your CPU
cores across `n_workers` yourself if `fn` is itself multi-threaded.

## Examples

``` r
if (FALSE) { # \dontrun{
# `write_one_slice()` must live in an INSTALLED package. This function
# loads it by package name + function name (never by value, unlike the
# other three dispatch functions), so it cannot be an inline function
# defined at the console. Put it in your own package's R/ directory,
# install the package, then replace "yourpkg" below with its name:
#
#   write_one_slice <- function(slice) list(main = slice)

out_dir <- tempdir()
ids <- c("a", "b", "c")
stream_from_parent_and_write_files_atomically(
  fn = package_function("yourpkg", "write_one_slice"),
  ids = ids,
  producer = function(id) list(slice = toupper(id)),
  outputs = setNames(
    lapply(ids, function(id) c(main = file.path(out_dir, paste0(id, ".qs2")))),
    ids
  ),
  n_workers = 2
)
} # }
```

# Run a function once per item, in a fresh worker process, and collect the results

Use this as a parallel version of
[`lapply()`](https://rdrr.io/r/base/lapply.html): `fn` runs once per
item, each call in its own, brand-new R process (a worker), with up to
`n_workers` running at the same time, and you get back a list of each
call's return value. If you don't need the return values – `fn` writes
its own output, or is called for a side effect – use
[`run()`](https://papadopoulos-lab.github.io/batchit/reference/run.md)
instead; it works identically but discards them.

## Usage

``` r
run_and_collect(
  fn,
  items,
  n_workers,
  dev_path = NULL,
  p = NULL,
  label = NULL,
  timeout = .BATCH_DEFAULT_TIMEOUT
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
  packages – see
  [`run()`](https://papadopoulos-lab.github.io/batchit/reference/run.md)'s
  Advanced section for accepted and rejected examples.

- items:

  One entry per call. Each entry is a named list holding the arguments
  for that one call to `fn` – every argument `fn` takes must be named,
  including ones with a default value (an omitted optional argument is
  treated as a mistake, not "use the default", so a silently dropped
  argument is caught rather than passed through unnoticed). A named
  entry keeps its name as that item's id (used in progress messages and
  error messages); an unnamed entry is identified by its position
  instead (1, 2, 3, ...).

- n_workers:

  How many items to run at the same time (a whole number, 1 or more).

- dev_path:

  Advanced; see
  [`run()`](https://papadopoulos-lab.github.io/batchit/reference/run.md)'s
  Advanced section. Leave as `NULL` (the default) to run the installed
  version of your package.

- p:

  A progress callback, such as a `progressr` progressor. Leave as `NULL`
  (the default) to print simple progress messages instead.

- label:

  An optional short label added to each progress message (for example, a
  stage name).

- timeout:

  Maximum time, in seconds, to let one item's worker run before killing
  it and reporting it as failed. Defaults to 6 hours; pass `Inf` to
  disable the limit.

## Value

A list of each item's return value, one element per item, **in the same
order as `items`** (not the order workers happened to finish). The list
itself is never named by item id – even if `items` was named – unlike
[`run_and_write_files_atomically()`](https://papadopoulos-lab.github.io/batchit/reference/run_and_write_files_atomically.md)
and
[`stream_from_parent_and_write_files_atomically()`](https://papadopoulos-lab.github.io/batchit/reference/stream_from_parent_and_write_files_atomically.md),
whose results are.

## Details

A small object can be included directly in an item's arguments (it
travels to the worker with the rest of that item), but for a large
object it is usually better to have `fn` load it itself inside the
worker (for example, read it from disk) rather than pass it through
`items`.

If any item's worker errors, exits unexpectedly, or exceeds `timeout`,
the whole call stops immediately with an R error (printing that worker's
captured output first) – it never returns a partial list, and it never
puts an error object in a failed item's slot.

## Advanced

Fresh worker processes are not just a convenience here – they're the
memory strategy for memory-heavy work. When one item's analysis peaks
at, say, tens of gigabytes, R does not hand that memory back to the
operating system on its own; exiting the worker process is what reclaims
it. This is why batchit starts a new worker per item instead of reusing
one across items.

When `fn` is a
[`package_function()`](https://papadopoulos-lab.github.io/batchit/reference/package_function.md)
reference, each worker re-checks a hash of its code before running it,
and refuses to run if that code has changed since you called
[`package_function()`](https://papadopoulos-lab.github.io/batchit/reference/package_function.md).
Any warning `fn` raises is captured and re-raised in your R session once
that item finishes, labelled with its item id.

batchit does not set BLAS or `data.table` thread counts. If `fn` is
itself multi-threaded, reduce its thread count yourself when running
several workers at once, to avoid oversubscribing your CPU cores.

## Examples

``` r
if (FALSE) { # \dontrun{
squares <- run_and_collect(
  fn = function(x) x^2,
  items = list(list(x = 2), list(x = 3), list(x = 4)),
  n_workers = 2
)
squares
} # }
```

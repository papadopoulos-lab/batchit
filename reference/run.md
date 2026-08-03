# Run a function once per item, in a fresh worker process, discarding the results

Use this as a parallel `for` loop: `fn` runs once per item, each call in
its own, brand-new R process (a worker), with up to `n_workers` running
at the same time. Use this specifically when you don't need anything
back in your R session, for example when `fn` writes its own files, or
is called purely for a side effect. If you want each call's return value
back, use
[`run_and_collect()`](https://papadopoulos-lab.github.io/batchit/reference/run_and_collect.md)
instead; it works identically otherwise. If you want batchit itself to
manage output files safely (so a failed item never leaves a half-written
file), use
[`run_and_write_files_atomically()`](https://papadopoulos-lab.github.io/batchit/reference/run_and_write_files_atomically.md)
instead. Files that `fn` writes on its own here get none of that
protection: if `fn` is interrupted partway through writing one, whatever
it already wrote is left exactly as it is.

## Usage

``` r
run(
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
  packages. See the Advanced section below for accepted and rejected
  examples.

- items:

  One entry per call. Each entry is a named list holding the arguments
  for that one call to `fn`. Every argument `fn` takes must be named,
  including ones with a default value (an omitted optional argument is
  treated as a mistake, not "use the default", so a silently dropped
  argument is caught rather than passed through unnoticed). A named
  entry keeps its name as that item's id (used in progress messages and
  error messages); an unnamed entry is identified by its position
  instead (1, 2, 3, ...).

- n_workers:

  How many items to run at the same time (a whole number, 1 or more).

- dev_path:

  Advanced; see the Advanced section below. Leave as `NULL` (the
  default) to run the installed version of your package.

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

Nothing useful (`invisible(NULL)`). Use
[`run_and_collect()`](https://papadopoulos-lab.github.io/batchit/reference/run_and_collect.md)
if you need each item's return value.

## Details

If any item's worker errors, exits unexpectedly, or exceeds `timeout`,
the whole call stops immediately with an R error (printing that worker's
captured output first). It does not continue past the failure.

## Advanced

Accepted and rejected inline functions:

    # Allowed, uses only its own argument and base R:
    function(x) x^2

    # Allowed, calls another package's function, package-qualified:
    function(x) data.table::data.table(x = x, y = x^2)

    # NOT allowed, `threshold` is not an argument of this function:
    threshold <- 10
    function(x) x > threshold

    # NOT allowed, `my_helper` is a plain call to a function defined
    # outside this one:
    my_helper <- function(x) x * 2
    function(x) my_helper(x)

When `fn` is a
[`package_function()`](https://papadopoulos-lab.github.io/batchit/reference/package_function.md)
reference, each worker re-checks a hash of its code before running it,
and refuses to run if that code has changed since you called
[`package_function()`](https://papadopoulos-lab.github.io/batchit/reference/package_function.md).
See that function's help page for what the hash does and does not cover.

`dev_path` names a package source tree to load in the worker with
[`devtools::load_all()`](https://devtools.r-lib.org/reference/load_all.html),
instead of using the installed package: the package named in your
[`package_function()`](https://papadopoulos-lab.github.io/batchit/reference/package_function.md)
reference, or (for an inline `fn`) batchit's own source tree. A path
that doesn't exist, or doesn't match the expected package, is an error
rather than a silent fall-back to the installed version.

batchit does not set BLAS or `data.table` thread counts. If `fn` is
itself multi-threaded, reduce its thread count yourself when running
several workers at once, to avoid oversubscribing your CPU cores.

## See also

[`vignette("choosing-a-dispatch-function")`](https://papadopoulos-lab.github.io/batchit/articles/choosing-a-dispatch-function.md)
for a worked comparison of all four dispatch functions.

Other dispatch functions:
[`run_and_collect()`](https://papadopoulos-lab.github.io/batchit/reference/run_and_collect.md),
[`run_and_write_files_atomically()`](https://papadopoulos-lab.github.io/batchit/reference/run_and_write_files_atomically.md),
[`stream_from_parent_and_write_files_atomically()`](https://papadopoulos-lab.github.io/batchit/reference/stream_from_parent_and_write_files_atomically.md)

## Examples

``` r
# \donttest{
out_dir <- file.path(tempdir(), "batchit-run-example")
dir.create(out_dir)
run(
  fn = function(x, dir) saveRDS(x^2, file.path(dir, paste0(x, ".rds"))),
  items = list(
    list(x = 1, dir = out_dir),
    list(x = 2, dir = out_dir),
    list(x = 3, dir = out_dir)
  ),
  n_workers = 2
)
#>   [0/3] dispatching workers...
#>   [1/3] complete  18:21:58
#>   [2/3] complete  18:21:58
#>   [3/3] complete  18:21:58
list.files(out_dir)
#> [1] "1.rds" "2.rds" "3.rds"
readRDS(file.path(out_dir, "2.rds")) # 4
#> [1] 4

unlink(out_dir, recursive = TRUE)
# }
```

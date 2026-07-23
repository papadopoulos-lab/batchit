# Run `fn` on each of a fixed list of items, one subprocess per item, returning nothing

The `collect = FALSE` sibling of
[`run_and_collect()`](https://papadopoulos-lab.github.io/batchit/reference/run_and_collect.md)
– same shape-A transport (see
[`run_and_collect()`](https://papadopoulos-lab.github.io/batchit/reference/run_and_collect.md)
and `.batch_run_impl()` for the shared contract details: hash-verified
target/adhoc dispatch, both-end validation, per-item logs, bounded log
tail, loud failure). Use this when `fn` writes its own output (or is
called purely for a side effect) and no value needs to cross back to the
parent.

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

  EITHER a `package_function` descriptor from
  [`package_function()`](https://papadopoulos-lab.github.io/batchit/reference/package_function.md)
  OR a bare closure – see the details above.

- items:

  List of items; each a fully-named list of `fn`'s formals. Named items
  keep their name as the item id; unnamed items get their index.

- n_workers:

  Concurrent subprocesses (validated: finite, whole, \>= 1).

- dev_path:

  Source tree for
  [`devtools::load_all()`](https://devtools.r-lib.org/reference/load_all.html)
  in the worker, or `NULL` for the installed package. For a
  [`package_function()`](https://papadopoulos-lab.github.io/batchit/reference/package_function.md)
  `fn` this is the CONSUMER's source tree; for a bare-closure `fn` it is
  batchit's own (an adhoc closure has no separate consumer identity to
  load). A given-but-wrong path errors rather than silently falling back
  to installed code.

- p:

  A progress callback such as a `progressr` progressor, or `NULL`. It is
  called once per completed item with `message = <id and time>`.

- label:

  Optional short stage tag prefixed to the progress message.

- timeout:

  Per-item wall-clock limit in seconds; a worker that exceeds it is
  killed and reported as a failure. Defaults to a generous hang-catcher
  (the internal `.BATCH_DEFAULT_TIMEOUT`, 6 hours); pass `Inf` to
  disable.

## Value

`invisible(NULL)`.

## Details

`fn` is EITHER a
[`package_function()`](https://papadopoulos-lab.github.io/batchit/reference/package_function.md)
descriptor (hash-verified, auditable; use in production) OR a bare
closure (ad-hoc, gated by a static self-containedness lint and a
mandatory [`baseenv()`](https://rdrr.io/r/base/environment.html) rebase;
for tests and one-offs only – this folds in the former ad-hoc-closure
frontend).

## Examples

``` r
if (FALSE) { # \dontrun{
t <- package_function("mypkg", "process_one_slice")
run(t, items = list(list(x = 1), list(x = 2)), n_workers = 2)
} # }
```

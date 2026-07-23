# Run `fn` on each of a fixed list of items, one subprocess per item, collecting values

Shape A of the contract: the items already exist (each a small named
list of `fn`'s formals; the worker opens its own data), so a fresh R
process per item is not a cost to amortise but the memory strategy
itself – a large analysis item can peak at tens of GB and R does not
return that memory to the OS, so process exit is how it is reclaimed.
This is why batchit does NOT reuse workers: worker reuse would defeat
exactly this.

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

A list of values in item order.

## Details

`fn` is EITHER a
[`package_function()`](https://papadopoulos-lab.github.io/batchit/reference/package_function.md)
descriptor (hash-verified, auditable; use in production) OR a bare
closure (ad-hoc, gated by a static self-containedness lint and a
mandatory [`baseenv()`](https://rdrr.io/r/base/environment.html) rebase;
for tests and one-offs only – this folds in the former ad-hoc-closure
frontend).

Both-end validation, a hash-verified target descriptor (or, for a bare
closure, a per-dispatch identity nonce), per-item logs written to files
(never pipes – a chatty worker filling the OS pipe buffer is what
deadlocks a pipe transport), a bounded log tail on failure, and a loud
stop on the first failure. Warnings a target captures are surfaced in
the parent, tagged by item id.

batchit is thread-agnostic: it sets no BLAS / data.table thread counts
and passes none to the worker. If `fn` is itself multi-threaded,
dividing cores across `n_workers` (to avoid oversubscription) is the
CONSUMER's responsibility, not the runner's.

The worker script is always the runner's (batchit's); `dev_path`, when
given, is the CONSUMER's source tree. When runner and consumer differ,
the worker loads both (the consumer via `dev_path`/`requireNamespace`,
the runner via `requireNamespace`).

## Examples

``` r
if (FALSE) { # \dontrun{
t <- package_function("mypkg", "process_one_slice")
out <- run_and_collect(t, items = list(list(x = 1), list(x = 2)), n_workers = 2)
} # }
```

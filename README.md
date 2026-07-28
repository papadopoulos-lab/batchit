# batchit

`batchit` runs one R function many times in parallel, each call in its own
worker process, and then either gives you the return values back or writes
each call's output files for you.

## Quick start

```r
library(batchit)

squares <- run_and_collect(
  fn = function(x) x^2,
  items = list(list(x = 2), list(x = 3), list(x = 4)),
  n_workers = 2
)

squares
#> [[1]]
#> [1] 4
#>
#> [[2]]
#> [1] 9
#>
#> [[3]]
#> [1] 16
```

Three things happened:

- Each element of `items` is one call's arguments, as a named list. `list(x = 2)`
  means "call `fn` with `x = 2`".
- Each call ran in its own, brand-new R process (a **worker**). Up to
  `n_workers` (here, 2) calls ran at the same time.
- The results came back as a list, **in the same order as `items`** -- not in
  the order the workers happened to finish.

## Which function do I want?

| Your situation | Use |
|---|---|
| Items already exist; run for side effects, ignore the return values | `run()` |
| Items already exist; collect the return values | `run_and_collect()` |
| Items already exist; let batchit write output files atomically | `run_and_write_files_atomically()` |
| Too many/too-large items to build up front; build them lazily and write files | `stream_from_parent_and_write_files_atomically()` |

`run()`, `run_and_collect()`, and `run_and_write_files_atomically()` all work
the same way as the quick start above: you build the full `items` list first,
and each item runs in a fresh worker process. A fresh process per item matters
for memory-heavy work -- when a worker's R session exits, the operating system
reclaims all the memory it used, which is not true if the same worker were
reused for the next item.

`stream_from_parent_and_write_files_atomically()` is for when building the
full `items` list first would itself use too much memory (for example: each
item is a large data slice, or there are far too many items to hold as a
list). Instead, you give it an `ids` vector and a function that produces one
item's arguments at a time, and batchit calls that function only when a
worker is free -- so at most a bounded number of items exist in memory at
once. The trade-off: this function uses a small number of long-running
background workers instead of one fresh process per item, so a single
worker's memory is not automatically reclaimed between items the way process
exit reclaims it for the other three functions. It's a better fit for many
small-to-medium items than for a few huge ones.

## Writing the function you dispatch (`fn`)

Every one of the four functions above takes an `fn` argument: the function to
run once per item. You can pass it two ways:

- **An inline function**, written directly in your call -- as in the quick
  start above. Supported by `run()`, `run_and_collect()`, and
  `run_and_write_files_atomically()`. NOT supported by
  `stream_from_parent_and_write_files_atomically()`, which requires the
  second form below.
- **A reference built by `package_function(package, symbol)`**, naming a
  function that already lives in an installed R package (see
  `?package_function`). Use this for production runs, where you want every
  worker to verify it is running the exact code you tested, rather than
  whatever happens to be installed. Required by
  `stream_from_parent_and_write_files_atomically()`; optional (but
  recommended) for the other three.

### Rules for an inline function

An inline `fn` must be self-contained: it may only use (1) its own arguments,
(2) base R functions and operators, and (3) other packages' functions called
with an explicit `pkg::fun()` prefix. It must not take `...`.

```r
# Allowed -- uses only its own argument and base R:
function(x) x^2

# Allowed -- calls another package's function, package-qualified:
function(x) data.table::data.table(x = x, y = x^2)

# NOT allowed -- `threshold` is not an argument of this function:
threshold <- 10
function(x) x > threshold

# NOT allowed -- `my_helper` is a plain (non-package-qualified) call to a
# function defined outside this one:
my_helper <- function(x) x * 2
function(x) my_helper(x)
```

If your function needs something from outside its own arguments, either pass
it in as an extra argument (add it to every item), reference it with
`pkg::fun()` if it lives in an installed package, or move the function itself
into a package and use `package_function()` instead.

## Writing output files safely

`run_and_write_files_atomically()` and
`stream_from_parent_and_write_files_atomically()` give you a guarantee about
the files each item produces: **a failed or interrupted item never leaves a
half-written file at its final path.** batchit writes each declared output to
a temporary file next to its destination, and only renames the temporary
files into place after every one of that item's outputs has finished writing
successfully. If anything goes wrong partway through an item -- an error in
`fn`, a timeout, a rename failure -- none of that item's files are replaced;
whatever was already there (or nothing, if it didn't exist yet) is left
untouched. Every item is always run: batchit never checks whether an
output already exists and skips the item because of it.

You tell each of these functions what to write with the `outputs` argument:
one absolute final path per declared output name, per item, e.g.
`c(main = "/data/result.qs2")`. There are two ways for `fn` to actually
produce those files, chosen with the `style` argument:

- **`style = "return"`** (the default): `fn` returns a named list, one
  element per declared output, and batchit saves each value to its file (in
  the `qs2` format -- read it back with `qs2::qs_read()`).
- **`style = "staged_writer"`**: `fn` writes each output itself, to the path
  given by `where_to_write_output(<name>)`; its return value is ignored. Use
  this when `fn` already writes files on its own (for example, in a format
  other than `qs2`, or via another package's writer function), so it doesn't
  have to build the whole object in memory just to hand it back for batchit
  to save again.

Both functions return a list, one element per item, describing what was
written -- never `fn`'s raw return value. See `?run_and_write_files_atomically`
and `?stream_from_parent_and_write_files_atomically` for complete, runnable
examples of both styles.

## What you see when something goes wrong

If any item's worker errors, exits unexpectedly, or runs longer than
`timeout` seconds (6 hours by default), the whole call stops immediately with
an R error -- it does not continue past the failure or return a partial
result. Before stopping, batchit prints that worker's captured output (stdout
and stderr, up to about 64 KB) so you can see what happened.

## Installation

```r
pak::pak("papadopoulos-lab/batchit")
```

`stream_from_parent_and_write_files_atomically()` additionally needs the
`mirai` package:

```r
pak::pak("mirai")
```

## Advanced

The notes below explain how batchit works internally. You don't need them to
use the package -- they matter if you're debugging something unusual, or
deciding whether to use `package_function()` in production.

- **Code-identity check.** When `fn` is a `package_function()` reference,
  each worker re-loads that function and computes a hash of its body and
  arguments, then refuses to run if that hash doesn't match what your R
  session computed when you called `package_function()`. This catches a
  worker silently running an older or different version of your code (for
  example, an installed package that is out of date compared to a
  development version you tested against). The hash covers only the target
  function's own body and arguments -- a changed helper function it calls, a
  changed constant it refers to, or a different dependency version are not
  covered, so this proves "the same function definition", not "provably
  identical behaviour". The hash also ignores comments and whitespace, so it
  agrees whether the function was loaded from an installed package or from
  `devtools::load_all()`.
- **Argument-name checking.** For every item, batchit checks that you named
  every one of `fn`'s arguments -- including ones with a default value -- and
  named nothing else, in both your R session (before dispatching) and inside
  the worker (before running). Requiring every argument by name, defaults
  included, is what catches an argument you meant to set but silently left
  out; a missing-but-optional argument would otherwise look identical to one
  you deliberately left at its default.
- **`dev_path`.** Every dispatch function takes a `dev_path` argument: the
  source tree of the package your `fn` lives in, loaded in each worker with
  `devtools::load_all()` instead of the installed package. Leave it `NULL`
  (the default) to use the installed package. A path that doesn't exist, or
  doesn't match the package you named, is an error -- it never silently falls
  back to the installed version.
- **Thread settings.** batchit does not set BLAS or `data.table` thread
  counts for you. If `fn` is itself multi-threaded, reduce its thread count
  yourself when running several workers at once, so the workers don't
  compete for the same CPU cores (oversubscription).
- **The internal marker file.** After an item commits its output files
  successfully, batchit leaves a small bookkeeping file named
  `.batchit__<item id>` next to them, as its own record that this specific
  run finished writing every declared output. Don't create, read, or rely on
  a file with that name yourself -- batchit manages it entirely, and
  overwrites it cleanly the next time that same item id is committed. Item
  ids (from `items`' names, or from `ids` for the streaming function) must
  not contain `/` or `\`, since this filename is built directly from them.
- **`stream_from_parent_and_write_files_atomically()`'s background
  workers.** This function runs its workers as persistent `mirai` daemons,
  in a private compute profile it creates and tears down for that one call
  -- it never touches or resets any `mirai` daemon configuration you already
  had. At most `2 * n_workers` items are held in memory at once: the
  function that produces the next item's arguments is not called until a
  worker is free, which is what keeps memory bounded.

## Provenance

`batchit` began as part of the
[`swereg`](https://github.com/papadopoulos-lab/swereg) package, where the
same dispatch logic ran registry-analysis pipelines in production. It was
later extracted into its own package so other projects could use it without
depending on `swereg`. See swereg's `PROJECT.md` for that history.

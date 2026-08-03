# Choosing a dispatch function

batchit runs one R function many times, each call in a separate worker
process. Four functions do that. They share one shape and differ on two
axes: how each call’s arguments reach the worker process, and what comes
back.

This article walks through all four with worked examples, then covers
the two ways to name the function you dispatch, and states exactly what
the atomic-write guarantee covers. It ends with
[`write_qs2_atomically()`](https://papadopoulos-lab.github.io/batchit/reference/write_qs2_atomically.md),
the one exported function that is not a dispatch function at all.

The examples below are shown rather than executed. Each one starts real
worker processes, and one of them needs a function installed in your own
package. Output appears as `#>` comments instead.

## The shape all four share

Three ideas appear in every one of the four functions.

**`fn`** is the function to run once per item.

**An item is one call’s arguments, as a named list.** `list(x = 2)`
means “call `fn` with `x = 2`”. Three of the four take a list of items,
as `items`.

**`n_workers`** is how many items run at the same time.

A **worker process** is a separate R process.
[`run()`](https://papadopoulos-lab.github.io/batchit/reference/run.md),
[`run_and_collect()`](https://papadopoulos-lab.github.io/batchit/reference/run_and_collect.md)
and
[`run_and_write_files_atomically()`](https://papadopoulos-lab.github.io/batchit/reference/run_and_write_files_atomically.md)
start a fresh one for every item.
[`stream_from_parent_and_write_files_atomically()`](https://papadopoulos-lab.github.io/batchit/reference/stream_from_parent_and_write_files_atomically.md)
instead reuses a small pool of persistent worker processes (`mirai`
daemons).

A fresh process per item is a memory strategy, not a convenience. R may
hold on to a large allocation after the objects using it are gone, so
letting the process exit is the reliable way to reclaim it. This matters
when one item peaks at many gigabytes.

Throughout this article, the **parent R session** is the session you
call batchit from.

## Which one do I want?

Two things decide it.

**What do you want back?** Each item’s return value; nothing, because
`fn` has an external side effect; or output files that batchit writes
and guards for you.

**Can you hold every item in memory at once?** Usually yes. Say no when
one item’s arguments are a large data slice, or when there are far too
many items to keep as one list.

| What you want back | Items | Use |
|----|----|----|
| each item’s return value | all in memory | [`run_and_collect()`](https://papadopoulos-lab.github.io/batchit/reference/run_and_collect.md) |
| nothing | all in memory | [`run()`](https://papadopoulos-lab.github.io/batchit/reference/run.md) |
| output files batchit writes | all in memory | [`run_and_write_files_atomically()`](https://papadopoulos-lab.github.io/batchit/reference/run_and_write_files_atomically.md) |
| output files batchit writes | produced one at a time | [`stream_from_parent_and_write_files_atomically()`](https://papadopoulos-lab.github.io/batchit/reference/stream_from_parent_and_write_files_atomically.md) |

Lazy production is available only in combination with batchit-managed
output files. There is no streaming function that hands back raw return
values.

Before reaching for the streaming function, consider the simpler
alternative: put a small identifier or file path in each item and have
`fn` load the large data itself, inside its worker process. That keeps
the fresh-process-per-item memory behaviour, which the streaming
function gives up.

## `run_and_collect()`: a parallel `lapply()`

Use this when you need every item’s return value.

``` r

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

Results come back **in the order of `items`**, not the order the worker
processes happened to finish. The returned list is never named by item
id, even when `items` was named. The two file-writing functions below do
name theirs, so this asymmetry is worth remembering.

Every return value travels from the worker process back to the parent R
session. A small object can also travel into a worker process as part of
an item, but for a large one it is usually better to have `fn` read it
from disk itself.

## `run()`: run items and discard the return values

Use this when `fn` is called for an effect outside R: it writes its own
files, or updates a database. It works exactly like
[`run_and_collect()`](https://papadopoulos-lab.github.io/batchit/reference/run_and_collect.md)
and returns `invisible(NULL)`.

The effect has to be external. Each item runs in a separate R process,
so assigning to a global variable inside `fn` changes that worker
process and not the parent R session.

``` r

out_dir <- tempdir()

run(
  fn = function(x, dir) qs2::qs_save(x^2, file.path(dir, paste0(x, ".qs2"))),
  items = list(
    list(x = 1, dir = out_dir),
    list(x = 2, dir = out_dir),
    list(x = 3, dir = out_dir)
  ),
  n_workers = 2
)

qs2::qs_read(file.path(out_dir, "2.qs2"))
#> [1] 4
```

Files that `fn` writes on its own, as here, get no protection from
batchit. If this `fn` were interrupted partway through writing `2.qs2`,
a half-written `2.qs2` would be left at that path.
[`run_and_write_files_atomically()`](https://papadopoulos-lab.github.io/batchit/reference/run_and_write_files_atomically.md)
is what prevents that.

## `run_and_write_files_atomically()`: batchit writes the files

Declare, per item, the final path of every file that item must produce.
batchit writes each one to a temporary file in the same directory as its
destination, and replaces the final files only after every one of that
item’s outputs has been written successfully.

`outputs` is one named character vector per item, in the same order as
`items`. When `items` is named, `outputs` may carry the same names
instead, in any order. Every path must be absolute, its parent directory
must already exist, and every path across the whole call must be unique.
A destination may already exist as a plain file, in which case it is
replaced; a directory or a symlink there is rejected. (Base R cannot
portably reject a FIFO, socket or device file, so those are not caught.)

### `style = "return"` (the default)

`fn` returns a named list, one element per declared output. Its names
must be the same set as the declared output names, in any order, with no
duplicates and none missing or extra. batchit saves each value to its
path in the `qs2` format.

``` r

out_dir <- tempdir()

result <- run_and_write_files_atomically(
  fn = function(x) list(squared = x^2, doubled = x * 2),
  items = list(list(x = 2), list(x = 3)),
  outputs = list(
    c(squared = file.path(out_dir, "sq_1.qs2"),
      doubled = file.path(out_dir, "db_1.qs2")),
    c(squared = file.path(out_dir, "sq_2.qs2"),
      doubled = file.path(out_dir, "db_2.qs2"))
  ),
  n_workers = 2
)

qs2::qs_read(file.path(out_dir, "sq_1.qs2"))
#> [1] 4
```

The return value is not `fn`’s return value. It is a record of what was
written, one element per item, in the order of `items` and named by item
id:

``` r

str(result[[1]])
#> List of 2
#>  $ committed: Named chr [1:2] "/tmp/.../sq_1.qs2" "/tmp/.../db_1.qs2"
#>   ..- attr(*, "names")= chr [1:2] "squared" "doubled"
#>  $ attempt  : chr "..."
```

`committed` maps each declared output name to the final path actually
written. `attempt` is an internal per-item identifier; ignore it.

### `style = "staged_writer"`: `fn` writes the files itself

Ask `where_to_write_output(name)` for the path to write each declared
output to, and write there. `fn`’s return value is discarded without
being examined.

``` r

write_two_files <- function(x) {
  qs2::qs_save(x^2, batchit::where_to_write_output("squared"))
  writeLines(as.character(x * 2), batchit::where_to_write_output("doubled"))
  invisible(NULL)
}

out_dir <- tempdir()

run_and_write_files_atomically(
  fn = write_two_files,
  items = list(list(x = 2), list(x = 3)),
  outputs = list(
    c(squared = file.path(out_dir, "sq_1.qs2"),
      doubled = file.path(out_dir, "db_1.txt")),
    c(squared = file.path(out_dir, "sq_2.qs2"),
      doubled = file.path(out_dir, "db_2.txt"))
  ),
  style = "staged_writer",
  n_workers = 2
)

readLines(file.path(out_dir, "db_1.txt"))
#> [1] "4"
```

Discarding the return value does not mean batchit takes your word for
it. Before committing, it checks that every declared output now exists
at its staging path as a plain, non-symlink file, and errors naming the
output that is missing.

Two rules for
[`where_to_write_output()`](https://papadopoulos-lab.github.io/batchit/reference/where_to_write_output.md).
Write to the path it returns and leave it alone otherwise, because
batchit moves it into place itself. And call it as
[`batchit::where_to_write_output()`](https://papadopoulos-lab.github.io/batchit/reference/where_to_write_output.md)
from an inline function, because an inline function may only call other
packages in package-qualified form.

Pick `"staged_writer"` when `fn` already writes files on its own, in a
format other than `qs2` or through another package’s writer. It then
writes each file directly, instead of building the whole object in
memory to hand back for batchit to serialize. Pick `"return"` the rest
of the time, which is most of the time.

## `stream_from_parent_and_write_files_atomically()`: build items lazily

Use this when building the full `items` list would itself use too much
memory. Instead of `items`, give an `ids` vector and a `producer(id)`
function that builds one item.

batchit keeps at most `min(2 * n_workers, length(ids))` items in flight,
and calls `producer()` only when one of those slots is free. Note that a
slot is not the same as an idle worker process: when every worker
process is busy, roughly `n_workers` further items can already be
produced and queued.

The bound covers **produced item arguments only**. The `ids` vector, the
`outputs` list and the accumulating result list all live in the parent R
session for the whole call, and none of them is bounded by `n_workers`.
Streaming solves the problem of items too large to hold all at once; it
does not make the per-item bookkeeping free.

``` r

# `write_one_slice()` must live in an INSTALLED package: this function loads it
# by package name and function name, never by value. Put it in your own
# package's R/ directory, install, and replace "yourpkg" below.
#
#   write_one_slice <- function(slice) list(main = slice)

out_dir <- tempdir()
ids <- c("a", "b", "c")

stream_from_parent_and_write_files_atomically(
  fn = package_function("yourpkg", "write_one_slice"),
  ids = ids,
  # Replace this with your own loader; it runs in the parent R session.
  producer = function(id) list(slice = toupper(id)),
  outputs = setNames(
    lapply(ids, function(id) c(main = file.path(out_dir, paste0(id, ".qs2")))),
    ids
  ),
  n_workers = 2
)
```

`producer()` runs in the parent R session, never in a worker process, so
it is an ordinary function. The self-containedness rules below apply to
`fn`, not to it. Load or build each item’s data inside `producer()`;
doing it beforehand defeats the point.

Once `producer()` returns an item, batchit applies the same `outputs`
validation, the same two `style`s and the same commit record as
[`run_and_write_files_atomically()`](https://papadopoulos-lab.github.io/batchit/reference/run_and_write_files_atomically.md).

Three differences from the other three functions.

1.  `fn` must come from
    [`package_function()`](https://papadopoulos-lab.github.io/batchit/reference/package_function.md).
    An inline function is not accepted.
2.  It needs the `mirai` package: `pak::pak("mirai")`.
3.  Its worker processes are persistent `mirai` daemons. A worker
    process’s memory is **not** reclaimed between items the way process
    exit reclaims it elsewhere, so this suits many small-to-medium items
    better than a few huge ones.

Those daemons live in a private compute profile that batchit creates and
tears down for the one call. It never touches a `mirai` daemon
configuration you set up yourself.

## Naming the function: inline or `package_function()`

An **inline function** is an ordinary R function passed by value,
written directly in the call, or assigned to a variable first, as
`write_two_files` was above. It is the quick option, and every example
here except the streaming one uses it.

It must be self-contained: it may use only its own arguments, base R,
and `pkg::fun()`-qualified calls to other packages.

``` r

# Allowed, own argument and base R:
function(x) x^2

# Allowed, another package, package-qualified:
function(path) qs2::qs_read(path)

# NOT allowed, `threshold` is not an argument of this function:
threshold <- 10
function(x) x > threshold

# NOT allowed, `my_helper` is a plain call to a function defined outside:
my_helper <- function(x) x * 2
function(x) my_helper(x)
```

batchit checks this with a best-effort static scan, not a proof.
Indirect lookups such as [`get()`](https://rdrr.io/r/base/get.html),
`eval(parse())` or a string-based
[`do.call()`](https://rdrr.io/r/base/do.call.html) can pass the check
and still fail in the worker process, because the function’s environment
is replaced before it is sent. Keep to the rule even where the check
lets something through.

If `fn` needs something from outside its own arguments, pass it in as
another argument, reference it as `pkg::fun()`, or move it into a
package.

**`package_function(package, symbol)`** names a function in an installed
package instead. It records a hash of that function’s code, and a worker
process refuses to run if the definition it loads does not match. Use it
for production runs.

``` r

fn <- package_function("yourpkg", "fit_one_model")
fn$formal_names
#> [1] "id" "n_iter"
```

The hash is deliberately narrow. It covers the target function’s own
body and formals, and nothing else. A changed helper it calls, a changed
constant, and a different dependency version are all outside it. A match
proves the body and formals are the definition the parent R session
hashed, not that behaviour is identical. It ignores comments and
whitespace, so an installed package and a
[`devtools::load_all()`](https://devtools.r-lib.org/reference/load_all.html)
tree agree on identical code.

`symbol` may name an internal function; it does not have to be exported.

## Name every argument, every time

For every item, batchit checks that you named **every** formal `fn` has,
including ones with a default, and nothing else. It checks in the parent
R session before dispatching, and again in the worker process.

``` r

fn <- function(x, scale = 1) x * scale

# Rejected, `scale` has a default but it still must be named:
items <- list(list(x = 2))

# Correct:
items <- list(list(x = 2, scale = 1))
```

Requiring defaults to be named is what makes a forgotten argument
visible. An argument you meant to set but left out otherwise looks
exactly like one you deliberately left at its default. For the same
reason, `fn` must not take `...`.

## What the atomic-write guarantee covers

batchit stages every one of an item’s declared outputs before it
replaces any final file. It then replaces the final files one at a time,
each by a rename within the destination directory. Last, it writes a
marker recording the commit. The guarantee is different in each of those
three phases.

**Before the first replacement: fully covered.** Suppose the item fails
here, with an error in `fn`, a `"return"` value whose names do not match
the declared outputs, a declared output a `"staged_writer"` never wrote,
or a failure serializing one of the staged files. Then **no declared
output** is touched. Whatever was at those paths stays exactly as it
was, and if nothing was there, nothing appears. The item’s own previous
marker is removed before the first replacement, so that one does not
survive even here.

**During the replacement loop: not transactional.** If the worker
process is killed, or a rename fails, partway through the loop, some of
the item’s outputs can be new while others are still old. batchit never
rolls back a file it has already renamed. An individual file is not left
half-written, since rename replacement is atomic under the filesystem
semantics batchit supports, but the *set* can be torn.

**After the marker is written: committed, but the call may still report
failure.** The worker serializes its result envelope only after
committing. If that fails, or the worker is killed in that window, every
final file and the marker are correctly in place while the call reports
the item as failed.

**A timeout is not confined to one phase.** `timeout` measures the
worker process’s whole lifetime, so it can land in any of the three.
batchit’s own source notes that a timeout can kill a worker mid-commit.
Do not read “timeout” as a pre-replacement failure.

The marker is what tells a complete commit from a torn one: a small file
named `.batchit__<item id>`, written only after every replacement has
succeeded. A torn set has no valid marker vouching for it. batchit
places one per item, in the directory of the item’s lexicographically
first declared output path. That is beside the outputs when they share a
directory, and in one of them when they do not. Do not create, read or
depend on that file yourself; batchit manages it. Because the name is
built from the item id, an id used with either file-writing function
must not contain `/` or `\`.

**Not a skip mechanism.** batchit never treats an existing output file
as a reason to skip an item. It schedules every item, subject only to
validation or an earlier failure stopping the call first.

**Per item, not per call.** When one item fails the call stops, but
items that already committed keep their files. batchit does not undo
them.

## When something fails

If an item’s worker process raises an error, exits unexpectedly, or runs
past `timeout`, the call stops with an R error. It does not continue
past the failure, and it never returns a partial result with an error
object in the failed slot. Work already running may finish before the
call unwinds.

[`run()`](https://papadopoulos-lab.github.io/batchit/reference/run.md),
[`run_and_collect()`](https://papadopoulos-lab.github.io/batchit/reference/run_and_collect.md)
and
[`run_and_write_files_atomically()`](https://papadopoulos-lab.github.io/batchit/reference/run_and_write_files_atomically.md)
print the failing worker process’s combined stdout and stderr first (the
last 64,000 bytes, and at most 100 lines) so the cause is visible.
[`stream_from_parent_and_write_files_atomically()`](https://papadopoulos-lab.github.io/batchit/reference/stream_from_parent_and_write_files_atomically.md)
reports the error that came back through `mirai`; it has no equivalent
captured-log tail.

On success, a worker process’s stdout and stderr are discarded. Warnings
are the exception: up to the first 100 warnings per item are carried
back and re-raised in the parent R session, labelled with the item id.

**Only a completed item’s warnings reach you.** If an item warns and
then fails, the error envelope carries no warnings, and the call raises
the error alone. Those warnings are still in the worker’s captured
output, which the three non-streaming functions print when they report
the failure, so read that log rather than expecting a warning.

`timeout` is 6 hours by default, per item. Pass `Inf` to disable it.

Item ids come from the names of `items`, or from `ids` when streaming,
and they label progress and error messages. Name your items, so that a
message reads `item 'fit_03' exceeded the timeout` rather than
`item '3'`.

## Two settings worth knowing

**`dev_path`** loads a package source tree in each worker process with
[`devtools::load_all()`](https://devtools.r-lib.org/reference/load_all.html),
instead of using the installed package. Which tree it must name depends
on `fn`:

- with a
  [`package_function()`](https://papadopoulos-lab.github.io/batchit/reference/package_function.md)
  target, it is that package’s source tree. Load the same tree in the
  parent R session before building the descriptor, so the hash the
  parent records matches the code the worker process loads.
- with an inline function, there is no consumer package to load, and
  `dev_path` can only name batchit’s own source tree. It is useful when
  developing batchit itself.

Leave it `NULL` to use installed packages. A path that does not exist,
or that does not hold the expected package, is an error. It never falls
back to the installed version quietly.

**Thread counts.** batchit does not set BLAS or `data.table` thread
counts for you. If `fn` is itself multi-threaded, lower its thread count
when running many worker processes, or they will compete for the same
cores.

## Writing one file atomically, with no dispatch

`write_qs2_atomically(object, path, ...)` is the commit engine’s
rename-into-place step, on its own. It writes to a uniquely-named
temporary file in the destination’s own directory, then renames it over
the destination. No workers, no items, no `fn`.

``` r

write_qs2_atomically(mtcars, file.path(tempdir(), "cars.qs2"))
qs2::qs_read(file.path(tempdir(), "cars.qs2"))
```

Use it wherever an interrupted write would leave a truncated file that a
later read halts on, which is the failure that makes a long pipeline
restart from the beginning. The destination is left either absent or
complete, never partial.

It is independent of
[`run_and_write_files_atomically()`](https://papadopoulos-lab.github.io/batchit/reference/run_and_write_files_atomically.md):
it writes no marker, its temporary file carries no dispatch attempt
token, and that function’s failure cleanup does not sweep it. Three
things it does **not** promise are worth reading in
[`?write_qs2_atomically`](https://papadopoulos-lab.github.io/batchit/reference/write_qs2_atomically.md)
before relying on it: it is not durability (a rename is not an `fsync`,
so a power loss can still lose the file), it is not a lock (two
concurrent writers each produce a complete file and the last rename
wins), and a `SIGKILL` leaves the temporary file behind, since
[`on.exit()`](https://rdrr.io/r/base/on.exit.html) cannot run.

## See also

- [`?run`](https://papadopoulos-lab.github.io/batchit/reference/run.md),
  [`?run_and_collect`](https://papadopoulos-lab.github.io/batchit/reference/run_and_collect.md),
  [`?run_and_write_files_atomically`](https://papadopoulos-lab.github.io/batchit/reference/run_and_write_files_atomically.md),
  [`?stream_from_parent_and_write_files_atomically`](https://papadopoulos-lab.github.io/batchit/reference/stream_from_parent_and_write_files_atomically.md)
  for the full argument reference.
- [`?package_function`](https://papadopoulos-lab.github.io/batchit/reference/package_function.md)
  and
  [`?where_to_write_output`](https://papadopoulos-lab.github.io/batchit/reference/where_to_write_output.md)
  for the two helpers.
- [`?write_qs2_atomically`](https://papadopoulos-lab.github.io/batchit/reference/write_qs2_atomically.md)
  for the standalone atomic writer.

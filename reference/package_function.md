# Identify a function in an installed package, so a worker can run it

Builds a small object that names a function in an installed package.
Pass that object as the `fn` argument to
[`run()`](https://papadopoulos-lab.github.io/batchit/reference/run.md),
[`run_and_collect()`](https://papadopoulos-lab.github.io/batchit/reference/run_and_collect.md),
[`run_and_write_files_atomically()`](https://papadopoulos-lab.github.io/batchit/reference/run_and_write_files_atomically.md),
or
[`stream_from_parent_and_write_files_atomically()`](https://papadopoulos-lab.github.io/batchit/reference/stream_from_parent_and_write_files_atomically.md).
It is the alternative to an inline function, written directly in one of
those calls (see their help pages). `package_function()` is required for
[`stream_from_parent_and_write_files_atomically()`](https://papadopoulos-lab.github.io/batchit/reference/stream_from_parent_and_write_files_atomically.md).
It is recommended for the other three, whenever you want a production
run to verify what every worker runs. Each worker then checks that it is
running the code you tested, not just whatever happens to be installed.
For a quick one-off run, an inline function is simpler and needs no
setup.

## Usage

``` r
package_function(package, symbol, version = NULL)
```

## Arguments

- package:

  Name of the installed package holding your function (a single string).
  It does not need to be `batchit` itself.

- symbol:

  Name of your function inside that package (a single string). It can be
  an exported OR an internal (unexported) function name.

- version:

  A version label to record for your own reference. Defaults to the
  package's currently installed version. This is informational only:
  what a worker actually checks before running is the code hash below,
  not this version string.

## Value

An object of class `"package_function"`. It is a list with elements
`package`, `symbol`, `version`, `hash` and `formal_names`. `hash` is a
hash of the function's code, used to verify the worker loaded the same
definition. `formal_names` holds the function's argument names. Pass the
whole object as `fn`.

## Details

The object this function returns always identifies a function by package
name + function name + a hash of its code. It is never the function
itself, a bare function name, or a closure. You can also pass your
function directly as `fn`, which is a different thing.
[`run()`](https://papadopoulos-lab.github.io/batchit/reference/run.md),
[`run_and_collect()`](https://papadopoulos-lab.github.io/batchit/reference/run_and_collect.md)
and
[`run_and_write_files_atomically()`](https://papadopoulos-lab.github.io/batchit/reference/run_and_write_files_atomically.md)
accept a function that way (see their `fn` argument). Only
[`stream_from_parent_and_write_files_atomically()`](https://papadopoulos-lab.github.io/batchit/reference/stream_from_parent_and_write_files_atomically.md)
requires the form this function builds.

A function that takes `...` is rejected. batchit checks every item's
argument names against the function's own fixed argument list. `...`
would make a mistyped or missing argument impossible to catch reliably.

## Advanced

The code hash is deliberately narrow: it covers only the function's own
body and its own argument list. Four things lie outside it:

- a changed helper function it calls;

- a constant it refers to elsewhere;

- an S4/R6 method table;

- a dependency's version.

So a matching hash proves "the same function definition", not "provably
identical behaviour". batchit also strips comments and whitespace before
it computes the hash, with
[`utils::removeSource()`](https://rdrr.io/r/utils/removeSource.html).
The hash then agrees across an installed package and a
[`devtools::load_all()`](https://devtools.r-lib.org/reference/load_all.html)
source tree. Those two otherwise disagree on identical code.

## See also

[`run()`](https://papadopoulos-lab.github.io/batchit/reference/run.md),
[`run_and_collect()`](https://papadopoulos-lab.github.io/batchit/reference/run_and_collect.md),
[`run_and_write_files_atomically()`](https://papadopoulos-lab.github.io/batchit/reference/run_and_write_files_atomically.md)
and
[`stream_from_parent_and_write_files_atomically()`](https://papadopoulos-lab.github.io/batchit/reference/stream_from_parent_and_write_files_atomically.md),
which all accept the descriptor this returns as their `fn`.

[`vignette("choosing-a-dispatch-function")`](https://papadopoulos-lab.github.io/batchit/articles/choosing-a-dispatch-function.md)
for when to prefer this over an inline function.

## Examples

``` r
# `stats` ships with R, so this always works. In your own project, name
# your own package and function here instead.
t <- package_function("stats", "sd")
t$formal_names
#> [1] "x"     "na.rm"
```

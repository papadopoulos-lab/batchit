# batchit

`batchit` runs one R function many times in parallel, each call in its own
worker process, and then either gives you the return values back or writes
each call's output files for you.

Full documentation: <https://papadopoulos-lab.github.io/batchit/>

## Installation

```r
pak::pak("papadopoulos-lab/batchit")
```

`stream_from_parent_and_write_files_atomically()` additionally needs `mirai`:

```r
pak::pak("mirai")
```

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
- The results came back as a list, **in the same order as `items`**, not in
  the order the workers happened to finish.

## Which function do I want?

| Your situation | Use |
|---|---|
| Collect every call's return value, like a parallel `lapply()` | `run_and_collect()` |
| Run for a side effect outside R; ignore the return values | `run()` |
| Have batchit write each item's declared output files, atomically | `run_and_write_files_atomically()` |
| The same, but the items are too many or too large to build up front | `stream_from_parent_and_write_files_atomically()` |
| Write one object to one file atomically, with no dispatch at all | `write_qs2_atomically()` |

The first four take an `fn` argument: the function to run once per item. The
first three accept an inline function, or a function named in an installed
package with `package_function()`, in which case each worker hashes the
definition it loaded and refuses to run code that differs from what you
dispatched. `stream_from_parent_and_write_files_atomically()` accepts only the
`package_function()` form.

The first three also start a brand-new R process for each item, which is the
memory strategy: process exit is what reclaims a large allocation. The streaming
function instead reuses a small pool of persistent `mirai` workers, so it trades
that reclamation away for the ability to build items lazily.

The two file-writing functions guarantee that **a failed or interrupted item
never leaves a half-written file at its final path**. Each item's outputs are
staged beside their destinations, renamed into place one at a time, and a commit
marker is written last.

## Documentation

- [**Choosing a dispatch function**](https://papadopoulos-lab.github.io/batchit/articles/choosing-a-dispatch-function.html)
  — all four functions with worked examples, the rules an inline `fn` must
  follow, and exactly what the atomic-write guarantee does and does not cover.
  Also available as `vignette("choosing-a-dispatch-function")`.
- [**Reference**](https://papadopoulos-lab.github.io/batchit/reference/index.html)
  — every argument of every exported function.
- [**Changelog**](https://papadopoulos-lab.github.io/batchit/news/index.html)

## Provenance

`batchit` began as part of the
[`swereg`](https://github.com/papadopoulos-lab/swereg) package, where the
same dispatch logic ran registry-analysis pipelines in production. It was
later extracted into its own package so other projects could use it without
depending on `swereg`. `DESIGN.md` in this repository records the design
decisions; swereg's `PROJECT.md` records the extraction itself.

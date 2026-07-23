# Run a target on each of a fixed list of items, committing DECLARED OUTPUT FILES instead of returning a value

The declared-output sibling of
[`run()`](https://papadopoulos-lab.github.io/batchit/reference/run.md)/[`run_and_collect()`](https://papadopoulos-lab.github.io/batchit/reference/run_and_collect.md)
(design PHASE6_DESIGN.md sections 2-3): same transport (a fresh
subprocess per item via `processx`, the same worker script, the same
both-ends item validation and hash-verified target), but instead of a
raw return value crossing back, the target's return is committed to
`outputs[[i]]` – a named map of final file paths – by the CHILD, via an
all-or-nothing 7-step rename sequence (`.batch_commit_task()`). A
per-item MARKER file is the atomic witness of a complete commit – but
only a VALID, engine-produced marker (one that decodes and whose
protocol/attempt-token/committed-output-map verify) is that witness;
bare pathname EXISTENCE is not. A target that errors before the old
marker is removed (commit step 4) leaves an unrelated pre-existing
marker at that path completely untouched, so a file sitting at the
marker path does not by itself mean this attempt committed.

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

  EITHER a `package_function` descriptor from
  [`package_function()`](https://papadopoulos-lab.github.io/batchit/reference/package_function.md)
  (`fn_kind = "package"`) OR a bare closure (`fn_kind = "adhoc"`):
  self-contained (base R, `pkg::`-qualified calls, and its own formals
  only – see `.batch_lint_adhoc_fn()`), not a primitive, and not taking
  `...`.

- items:

  List of items; each a fully-named list of `fn`'s formals. Named items
  keep their name as the item id; unnamed items get their index.

- outputs:

  A list aligned to `items`: `outputs[[i]]` is item `i`'s output map, a
  named character vector `c(<name> = <final path>)`. May instead be
  NAMED BY ITEM ID (same name set as the derived item ids, any order)
  when `items` itself is named. Every path must be absolute; each
  destination must be absent or an existing non-directory, non-symlink
  file (base R cannot portably distinguish a FIFO/socket/device special
  file, so such a file is not rejected here and MAY be replaced by the
  commit rename); every output AND every derived marker path must be
  unique across the WHOLE call.

- style:

  Commit style: `"return"` (the target returns a named list – Unit 1) or
  `"staged_writer"` (the target writes each output via
  [`where_to_write_output()`](https://papadopoulos-lab.github.io/batchit/reference/where_to_write_output.md)
  instead – Unit 2). Any other value errors.

- n_workers:

  Concurrent subprocesses (validated: finite, whole, \>= 1).

- dev_path:

  For `fn_kind = "package"`, the CONSUMER package's source tree for
  [`devtools::load_all()`](https://devtools.r-lib.org/reference/load_all.html)
  in the worker (or `NULL` for the installed consumer package). For
  `fn_kind = "adhoc"` there is no consumer identity, so this instead
  names BATCHIT'S OWN source tree (see
  [`run()`](https://papadopoulos-lab.github.io/batchit/reference/run.md)'s
  `dev_path` doc) – `NULL` (the default) uses the installed `batchit`.

- p:

  A progress callback such as a `progressr` progressor, or `NULL`.

- label:

  Optional short stage tag prefixed to the progress message.

- timeout:

  Per-item wall-clock limit in seconds; see
  [`run()`](https://papadopoulos-lab.github.io/batchit/reference/run.md).

- target:

  Deprecated former name of `fn` (Unit 1/2 originally shipped this
  parameter as `target = ...`). Pass `fn` instead; supplying both
  errors.

## Value

A list, named by item id, in item order: each element is that item's
commit record,
`list(committed = <named char: name -> final path>, attempt = <token>)`.
Never the target's raw return value.

## Details

Two commit styles, for EITHER fn_kind: `style = "return"` (Unit 1 – the
target returns `list(<name> = <value>, ...)`, names matching the
declared outputs EXACTLY; each value is qs2-serialized to its declared
path) and `style = "staged_writer"` (Unit 2 – the target instead WRITES
each output to
[`where_to_write_output()`](https://papadopoulos-lab.github.io/batchit/reference/where_to_write_output.md)`(<name>)`
as it goes; its return value is ignored). There is deliberately no
`collect` argument – the point of `run_and_write_files_atomically()` is
that raw values never cross back to the parent; only a small commit
record does.

`fn` is EITHER a
[`package_function()`](https://papadopoulos-lab.github.io/batchit/reference/package_function.md)
descriptor (`fn_kind = "package"`) OR a bare closure
(`fn_kind = "adhoc"`, Phase 6' Unit 3, design PHASE6_DESIGN.md sections
1-2) – both drive the SAME commit engine (`.batch_commit_task()`, both
styles, the same marker/§0 doctrine). A closure is gated by the same
self-containedness lint and mandatory
[`baseenv()`](https://rdrr.io/r/base/environment.html) rebase
[`run()`](https://papadopoulos-lab.github.io/batchit/reference/run.md)/
[`run_and_collect()`](https://papadopoulos-lab.github.io/batchit/reference/run_and_collect.md)
use (see `.batch_lint_adhoc_fn()`); commit-record identity is unaffected
either way (it is bound to the marker's own attempt token, never to
fn_kind).

No batchit-computed "should this item re-run?" logic exists here or
anywhere in these Units: every item is dispatched and every target is
always run (PUBLIC_API.md section 5: the former opt-in consumer-skip
mechanism, design section 7, was removed – no consumer ever needed it).
Nor does the parent ever inspect a marker's existence or contents before
dispatch (design section 0) – dispatch behaves identically whether a
target's marker already exists, is stale, or is malformed; only the
CHILD, while committing, ever reads one.

## Examples

``` r
if (FALSE) { # \dontrun{
t <- package_function("mypkg", "process_one_slice")
run_and_write_files_atomically(
  t,
  items = list(list(x = 1), list(x = 2)),
  outputs = list(c(main = "/data/out_1.qs2"), c(main = "/data/out_2.qs2")),
  n_workers = 2
)
} # }
```

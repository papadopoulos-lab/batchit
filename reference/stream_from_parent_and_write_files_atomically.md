# Stream a producer's items through a target, committing DECLARED OUTPUT FILES instead of returning a value

The Shape B analog of
[`run_and_write_files_atomically()`](https://papadopoulos-lab.github.io/batchit/reference/run_and_write_files_atomically.md):
the parent IS the producer. Each item is generated lazily by
`producer(id)` and is itself the payload (a data slice), so it must NOT
be materialised until there is a worker ready for it – otherwise the
whole dataset lands in memory (or on disk twice) at once. mirai's
persistent daemons and in-memory transport are exactly this shape; the
shape-A materialise-every-item-to-a-tempfile model is exactly the wrong
one for it. Delivery, though, is via the SAME atomic declared-output
commit engine
[`run_and_write_files_atomically()`](https://papadopoulos-lab.github.io/batchit/reference/run_and_write_files_atomically.md)
uses, instead of a raw return value crossing back: the commit engine
(`.batch_execute()` -\> `.batch_commit_task()`, in the CHILD) is
transport-agnostic – it reads the envelope's `outputs`/`marker`/`style`/
`attempt` fields and commits identically whether the envelope arrived
via `processx` or `mirai` – so this function changes only the
PARENT-side transport and wiring, never the child.

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

  A `package_function` descriptor from
  [`package_function()`](https://papadopoulos-lab.github.io/batchit/reference/package_function.md).

- ids:

  Vector of stable item ids (non-empty, non-NA, unique). Length = number
  of items; order is the order of production and dispatch.

- producer:

  `function(id)` returning that item – a fully-named list of `fn`'s
  formals. Called once per id, in the parent, under backpressure; only
  its RESULT crosses to a worker.

- outputs:

  A list aligned to `ids`: `outputs[[i]]` is item `i`'s output map, a
  named character vector `c(<name> = <final path>)`. May instead be
  NAMED BY ITEM ID (same name set as `ids`, any order). Same validation
  as
  [`run_and_write_files_atomically()`](https://papadopoulos-lab.github.io/batchit/reference/run_and_write_files_atomically.md)'s
  `outputs`: every path absolute; each destination absent or an existing
  non-directory, non-symlink file; every output AND every derived marker
  path unique across the whole call.

- style:

  Commit style: `"return"` (the target returns a named list) or
  `"staged_writer"` (the target writes each output via
  [`where_to_write_output()`](https://papadopoulos-lab.github.io/batchit/reference/where_to_write_output.md)
  instead); see
  [`run_and_write_files_atomically()`](https://papadopoulos-lab.github.io/batchit/reference/run_and_write_files_atomically.md).
  Any other value errors.

- n_workers:

  Number of mirai daemons (validated).

- dev_path:

  Consumer-package source tree, loaded once per daemon via
  [`devtools::load_all()`](https://devtools.r-lib.org/reference/load_all.html),
  or `NULL` for the installed consumer package. A given-but-wrong path
  errors, even for an empty workload.

- p:

  A progress callback such as a `progressr` progressor, or `NULL`.

- label:

  Optional short stage tag prefixed to the progress message.

- timeout:

  Per-item wall-clock limit in seconds (generous default, the internal
  `.BATCH_DEFAULT_TIMEOUT` of 6 hours; `Inf` disables). A task exceeding
  it resolves to an error and is reported.

## Value

A list, named by id, in id order: each element is that item's commit
record,
`list(committed = <named char: name -> final path>, attempt = <token>)`.
Never the target's raw return value.

## Details

Two commit styles, exactly as in
[`run_and_write_files_atomically()`](https://papadopoulos-lab.github.io/batchit/reference/run_and_write_files_atomically.md):
`style = "return"` (the target returns `list(<name> = <value>, ...)`,
names matching the declared outputs EXACTLY) and
`style = "staged_writer"` (the target instead WRITES each output to
[`where_to_write_output()`](https://papadopoulos-lab.github.io/batchit/reference/where_to_write_output.md)`(<name>)`
as it goes; its return value is ignored). A per-item MARKER file is the
atomic witness of a complete commit – but only a VALID, engine-produced
marker (one that decodes and whose
protocol/attempt-token/committed-output-map verify) is that witness;
bare pathname existence is not. There is deliberately no `collect`
argument – only a small commit record ever crosses back, never a raw
value.

`fn` is a
[`package_function()`](https://papadopoulos-lab.github.io/batchit/reference/package_function.md)
descriptor ONLY – unlike
[`run_and_write_files_atomically()`](https://papadopoulos-lab.github.io/batchit/reference/run_and_write_files_atomically.md),
this function does not also accept a bare closure. Shape B's sole
consumer (`save_rawbatch`) uses a package function, so ad-hoc-over-mirai
support is deliberately out of scope (PUBLIC_API.md section 3.2).

Same both-end validation, result-envelope inspection, warning surfacing
and loud failure as
[`run()`](https://papadopoulos-lab.github.io/batchit/reference/run.md)/[`run_and_collect()`](https://papadopoulos-lab.github.io/batchit/reference/run_and_collect.md)/[`run_and_write_files_atomically()`](https://papadopoulos-lab.github.io/batchit/reference/run_and_write_files_atomically.md),
over the mirai transport. At most `2 * n_workers` items are in flight;
the producer for the next id is not called until an in-flight slot
frees, which is the backpressure. Each task carries a `timeout`, so a
wedged daemon cannot block forever.

Never touches mirai's DEFAULT compute profile: `daemons(n)` there would
reset and destroy any daemon configuration the caller had. Each
invocation allocates a fresh PRIVATE profile under the runner's reserved
`.batch_stream_<nonce>_` prefix, where `<nonce>` is a high-entropy,
session-specific string – so the name can never be "default" (that
guarantee holds by construction), and a registry collision would require
another party to have claimed a name under that same nonce-namespaced
prefix in this session. It tears only its own profile down. As with
[`run()`](https://papadopoulos-lab.github.io/batchit/reference/run.md)/[`run_and_collect()`](https://papadopoulos-lab.github.io/batchit/reference/run_and_collect.md),
batchit is thread-agnostic: any within- item thread policy is the
consumer's.

The daemon loads the CONSUMER package (via
`dev_path`/`requireNamespace`) and, when the runner differs from the
consumer, the RUNNER too – the daemon needs `.batch_execute` resolvable
in the runner's namespace.

Requires the suggested `mirai` package (parallelism is opt-in).

## Examples

``` r
if (FALSE) { # \dontrun{
t <- package_function("mypkg", "write_one_slice")
stream_from_parent_and_write_files_atomically(
  t,
  ids = c("2019", "2020", "2021"),
  producer = function(id) list(slice = load_year(id)),
  outputs = list(
    `2019` = c(main = "/data/2019.qs2"),
    `2020` = c(main = "/data/2020.qs2"),
    `2021` = c(main = "/data/2021.qs2")
  ),
  n_workers = 4
)
} # }
```

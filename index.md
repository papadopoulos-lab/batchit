# batchit

**One subprocess dispatcher with a both-ends-validated contract.**

`batchit` runs one R function across many subprocesses, and it makes the
parent/child boundary a *contract* rather than an assumption. A
**target** is a descriptor — package + symbol + a
`digest(list(body, formals))` identity hash — never a closure, so the
child can refuse code that differs from what the parent dispatched. Work
**items** are validated against the target’s formals at *both* ends.
Every result comes back in a structured **envelope** (protocol, id,
status, value-or-error, executed-target identity, captured warnings).

## The two shapes

There is one contract and two transports, matched to two real workload
shapes.

**Shape A —
[`run()`](https://papadopoulos-lab.github.io/batchit/reference/run.md) /
[`run_and_collect()`](https://papadopoulos-lab.github.io/batchit/reference/run_and_collect.md)**:
the items already exist; run a fresh process per item. Process exit *is*
the memory strategy for memory-bound work (a worker that peaks at tens
of GB does not hand that memory back to the OS, so reuse would be the
wrong thing). Transport: `processx`, one child per item.
[`run()`](https://papadopoulos-lab.github.io/batchit/reference/run.md)
returns nothing (for a target that writes its own output);
[`run_and_collect()`](https://papadopoulos-lab.github.io/batchit/reference/run_and_collect.md)
returns each item’s value, in item order. `fn` is either a
[`package_function()`](https://papadopoulos-lab.github.io/batchit/reference/package_function.md)
descriptor (hash-verified, production) or a bare closure (ad-hoc, gated
by a self-containedness lint — for tests and one-offs).

``` r

t <- batchit::package_function("mypkg", "process_one_slice")
out <- batchit::run_and_collect(
  t,
  items = list(list(x = 1), list(x = 2), list(x = 3)),
  n_workers = 3
)
```

**Shape A, declared-output variant —
[`run_and_write_files_atomically()`](https://papadopoulos-lab.github.io/batchit/reference/run_and_write_files_atomically.md)**:
same transport, but instead of a value crossing back, each item commits
its declared output files atomically (a 7-step rename sequence,
witnessed by a per-item marker file) — see `PUBLIC_API.md` section 3.1.

**Shape B —
[`stream_from_parent_and_write_files_atomically()`](https://papadopoulos-lab.github.io/batchit/reference/stream_from_parent_and_write_files_atomically.md)**:
the parent *is* the producer and each item is itself the payload (a data
slice), generated lazily under bounded backpressure so the whole dataset
never lands in memory (or on disk twice) at once. Transport: `mirai`
daemons, at most `2 * n_workers` items in flight. Delivery is via the
same atomic declared-output commit engine as
[`run_and_write_files_atomically()`](https://papadopoulos-lab.github.io/batchit/reference/run_and_write_files_atomically.md)
— a commit record crosses back, never a raw value. `fn` is a
[`package_function()`](https://papadopoulos-lab.github.io/batchit/reference/package_function.md)
descriptor only (no ad-hoc closure support — the sole consumer,
`save_rawbatch`, uses a package function).

``` r

t <- batchit::package_function("mypkg", "write_one_slice")
batchit::stream_from_parent_and_write_files_atomically(
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
```

## The contract

- **Target = package + symbol + body/formals hash.** The child
  re-computes the hash after loading and refuses to run a different code
  version than dispatched. The hash is srcref-independent, so
  installed-vs-`load_all` code identity holds.
- **Every formal must be named on every item, including optional ones**
  — that is what catches a silently-dropped optional argument, not just
  a typo.
- **Validation runs at both ends.** Parent = early UX (every item, not
  just the first); child = correctness (it may have loaded a different
  version).
- **No positional / duplicate / blank names, and no `...` targets.**
- **Result envelope**: protocol, id, status, value-or-structured-error,
  executed target identity (package + symbol + hash), captured warnings.
  Atomicity is scoped to the envelope, not to whatever files a target
  writes.
- **[`run()`](https://papadopoulos-lab.github.io/batchit/reference/run.md)
  drops the value entirely** — for targets that write their own output,
  only the status crosses back;
  [`run_and_collect()`](https://papadopoulos-lab.github.io/batchit/reference/run_and_collect.md)
  is the sibling that returns each item’s value.
- **The default mirai profile is never touched**; each stream claims a
  fresh, nonce-namespaced private profile and tears only it down.
- **Thread-agnostic**: batchit sets no BLAS / data.table thread counts.
  Any within-item thread policy is the consumer’s.
- **Runner vs consumer**: the worker script is always the runner’s
  (batchit’s); `dev_path`, when given, is the *consumer’s* source tree.
  The worker and daemon load both packages.

## Installation

``` r

pak::pak("papadopoulos-lab/batchit")
```

Parallel shape B needs the suggested `mirai` package (parallelism is
opt-in).

## Provenance

`batchit` was extracted from
[`swereg`](https://github.com/papadopoulos-lab/swereg) after Phases 0–3
of the one-dispatcher project — where the contract was designed, the
correctness defects at the parent/child boundary were fixed, and every
legacy engine was routed through this single dispatcher. See swereg’s
`PROJECT.md` for that history and the design rationale. The one
non-mechanical change at extraction was the runner-vs-consumer loading
seam (swereg was both; batchit is only the runner).

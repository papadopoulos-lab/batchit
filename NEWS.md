# batchit 26.7.19

`runner_package` is now a **required** envelope field, with no consumer fallback.
Previously the worker validated `meta$runner_package` only when present and, when
absent, fell back to the consumer package for `.batch_execute` — so a malformed
envelope could make the *consumer* namespace supply the runner's executor, the
exact runner/consumer confusion the extraction seam exists to prevent. The shared
`.batch_check_envelope()` also omitted `runner_package`, so the two transports
accepted an incomplete schema. Now: the worker's pre-load structural check treats
`runner_package` like `package`/`hash`/`id` (a non-empty string or die before any
code loads), the worker resolves `.batch_execute` from the runner namespace
unconditionally, and `.batch_check_envelope()` requires `runner_package` too.
Regression tests cover both the checker and a real worker invocation on an
envelope missing the field.

# batchit 26.7.18

Initial release. `batchit` is the one subprocess dispatcher extracted from
`swereg` after Phases 0–3 of the one-dispatcher project (see swereg's
`PROJECT.md`): the design of a parent/child dispatch contract, the correctness
fixes to every boundary defect, and the routing of every legacy engine through a
single dispatcher, all done inside swereg first.

Public API:

- `batch_target(package, symbol, version = NULL)` — a dispatch *descriptor*:
  package + symbol + a srcref-independent `digest(list(body, formals))` identity
  hash. Rejects `...`-taking targets. The child re-verifies the hash and refuses
  a different code version than dispatched.
- `batch_run(target, items, n_workers, ...)` — shape A: a fresh subprocess per
  item via `processx`, the memory strategy for memory-bound work.
- `batch_stream(target, ids, producer, n_workers, ...)` — shape B: a lazy
  producer with bounded backpressure via `mirai` daemons, for items generated on
  demand.

Both frontends share one contract: both-ends item validation against the
target's formals (every formal named, including optional ones; no positional /
duplicate / blank names), a structured result envelope (protocol, id, status,
value-or-error, executed-target identity, captured warnings surfaced in the
parent), `collect = FALSE` to drop values for self-writing targets, per-item
timeouts, bounded log tails on failure, and a total, fail-closed inspector.

The extraction seam (the one non-mechanical change vs. swereg, where runner and
consumer were the same package):

- The worker script is now **always** resolved from the runner package
  (`system.file("batch_worker.R", package = "batchit")`); a consumer's `dev_path`
  supplies only the consumer's code, never the worker script.
- The processx worker and the mirai daemon each load **both** the consumer
  (via `dev_path` or `requireNamespace`) and the runner (`requireNamespace`),
  skipping the second load only when runner and consumer coincide.
- `meta$runner_package` carries the runner name across the boundary.

Every security property from swereg is preserved: exact `[[` field extraction, a
pre-load structural check of the load-deciding fields (including a required,
non-empty `runner_package` as of 26.7.19), source-tree-vs-installed `dev_path`
discrimination, child-side hash re-verification, a total `.batch_execute`, and a
total result inspector.

`test-batch_seam.R` is new and has no swereg ancestor: it builds and installs a
throwaway consumer package and dispatches through the real worker and a real
mirai daemon with **runner = batchit and consumer = seamtest**, proving the seam
that swereg-inside-swereg could not.

# batchit (development)

Public API migration, Stage 2 (see `PUBLIC_API.md`): the naming-v2 rename
sweep. `batch_run(target, items, ..., collect = TRUE/FALSE)` is now TWO
functions with `collect` folded into the name — `run(fn, items, ...)`
(`collect = FALSE`) and `run_and_collect(fn, items, ...)` (`collect = TRUE`)
— sharing one internal implementation (`.batch_run_impl()`). `batch_fn()` is
retired as a separate export: both `run()` and `run_and_collect()` now accept
`fn` as EITHER a `package_function()` descriptor OR a bare closure (the
former `batch_fn()` behaviour), gated by the same self-containedness lint and
mandatory `baseenv()` rebase as before. `batch_task()` is renamed to
`run_and_write_files_atomically()` — a pure name change; its body (styles
`"return"`/`"staged_writer"`, the `target =` deprecated-alias support, the
declared-output commit engine) is unchanged. `package_function()` and
`where_to_write_output()` (renamed in Stage 1) are unaffected.
`batch_record()`/`batch_prior()`/`batch_skip()` keep their names in this
stage (scheduled for deletion in a later stage, PUBLIC_API.md section 5) —
only their error-message text was updated to reference
`run_and_write_files_atomically()` instead of the old `batch_task()` name,
since they are only ever callable from inside one of its targets.
`batch_stream()` is untouched (Shape B, handled in a later stage). See
`PUBLIC_API.md` section 4 for the full old->new mapping.

Public API migration, Stage 3 (see `PUBLIC_API.md` section 5): the Phase 6'
Unit 4 opt-in consumer-skip mechanism — `batch_record()`, `batch_prior()`,
`batch_skip()`, the marker's `details` field, and the commit record's
`skipped` field — is REMOVED. No consumer ever needed it (the TTE stages
are skip-free by doctrine, Phase 5'); `run_and_write_files_atomically()`'s
commit record returns to its pre-Unit-4 shape, `list(committed, attempt)`,
and the marker record returns to `list(protocol, attempt, committed)`. No
protocol bump (`.BATCH_PROTOCOL` stays `2L`): the skip fields were additive
without a bump, so removing them needs none. Every item is unconditionally
dispatched and every target is always run, exactly as in Unit 1-3; re-add
only if a real consumer ever needs it.

Phase 6' Unit 3 (see `PHASE6_DESIGN.md`): a new `fn_kind = "adhoc"` dispatch
kind, alongside the existing `fn_kind = "package"` (a `package_function()`
descriptor). `adhoc` dispatches a bare closure VALUE, serialized straight into
the envelope, instead of resolving a package+symbol. New exported frontend
`batch_fn(fn, items, n_workers, dev_path = NULL, collect = FALSE, ...)` is the
adhoc, return-value sibling of `batch_run()`; `batch_task(fn, ...)` now also
accepts a bare closure (`fn` is EITHER a `package_function()` descriptor OR a bare
closure) — the same declared-output commit engine, both styles, and the same
§0 marker doctrine hold for adhoc too.

An adhoc closure is gated by a best-effort static self-containedness LINT
(`codetools::findGlobals()`, new Imports dependency), applied at BOTH ends —
the frontend at dispatch time (early UX) and `.batch_check_envelope()` again
in the CHILD (correctness: a worker never simply trusts that an envelope
reaching it went through a frontend's own check). The closure may reference
only base R (functions, operators, and constants — anything bound in
`baseenv()`), its own declared formals, and explicit `pkg::fun()`/`pkg:::fun()`
calls; any other free variable is rejected, NAMING it. `...` in the closure's
formals is prohibited, exactly like a package `package_function()`; a primitive or
non-function is rejected too. This is a best-effort static lint, not a proof —
it does not detect `get()`/`mget()`/`assign()`/a string-argument `do.call()`,
`eval(parse(...))`, `substitute()`, `.GlobalEnv`, a formula's/attribute's own
environment, `<<-`, S4/R5/R6 dispatch, or other ambient state reachable without
a syntactically visible free variable.

Once accepted, the closure is UNCONDITIONALLY rebased onto `baseenv()` before
it is ever serialized — there is no env-preservation mode. This closes the
large/secret enclosing-environment carriage path the lint itself cannot
detect: proven that an un-rebased closure's original environment (and
anything bound in it) round-trips through the qs2 wire intact, while a
`baseenv()`-rooted closure instead reconnects to the RECEIVING session's own
`baseenv()` — so a closure that only passes the lint because it reaches its
enclosing environment indirectly (e.g. `get("x", envir = environment())`, a
documented blind spot) still fails at run time in the real child subprocess.

Because an adhoc envelope carries no package/symbol/hash identity, a result is
instead bound to the id (already checked) plus a fresh, high-entropy
per-dispatch NONCE the parent issues and the child echoes back in the result's
`target` field (`list(fn_kind = "adhoc", nonce = <nonce>)`); `.batch_inspect_
result()` branches on `fn_kind` (via its new `expected_nonce` argument) and
rejects a result claiming the wrong id or the wrong nonce exactly like a wrong
package/symbol/hash is rejected for `fn_kind = "package"`.

`dev_path` for `adhoc` dispatch (`batch_fn()`, or `batch_task()` with a bare
closure) has no consumer package to validate against, so it instead names
BATCHIT'S OWN source tree — this is what lets batchit's own adhoc test suite
run against source without a reinstall (mirroring the existing package-kind
"runner == consumer" self-test path); `NULL` (the default) uses the installed
`batchit`, which is what any downstream caller wants. A closure's own
`pkg::fun()` calls are unaffected either way, resolving via ordinary lazy
namespace loading in the worker.

Phase 6' Unit 2 (see `PHASE6_DESIGN.md`): `batch_task()` now supports `style =
"staged_writer"` alongside `style = "return"` (Unit 1). Instead of returning a
named list, a `staged_writer` target WRITES each declared output to
`where_to_write_output(<name>)` — a new exported accessor that returns the exact
attempt-scoped staging path batchit pre-computed for that output, in the same
directory as its final destination. The target's return value is
unconditionally ignored (no return-name-match check for this style). Commit
step 1 becomes an ASSERTION rather than a write: every declared name must
exist at its staging path as a regular, non-symlink file once the target
returns, or the item fails loudly with zero renames — steps 2-7 (marker
prepare, temp verification, old-marker removal, output renames, marker rename
LAST, read-back verification) are identical between the two styles.
`where_to_write_output()` errors clearly when called outside an active
`staged_writer` run, or for a name that is not one of the item's declared
outputs. The parent-side failure sweep (`.batch_sweep_task_temps()`, used on a
timeout/SIGKILL) now matches BOTH `.<attempt>.tmp` (marker + `return`-style
output temps) and `.<attempt>.stage` (`staged_writer` staging files), still
keyed on the unique per-dispatch attempt token so an unrelated pre-existing
file is never swept.

Phase 6' Unit 1 (see `PHASE6_DESIGN.md`): a new declared-output commit engine,
`batch_task()`, alongside the existing return-value `batch_run()`/
`batch_stream()`. `batch_task(target, items, outputs, style = "return",
n_workers, dev_path = NULL, ...)` runs a package target once per item (the
same `processx`-per-item transport as `batch_run()`) and, instead of returning
a value, commits it to `outputs[[i]]` — a declared name -> final-path map — via
an all-or-nothing 7-step rename sequence run in the CHILD. A per-item marker
file (`.batchit__<item id>`) is the atomic witness of a complete commit — but
only a VALID, engine-produced marker (one that decodes and whose
protocol/attempt-token/committed-output-map verify) is that witness; bare
pathname existence at that path is not (a target that errors before the old
marker is removed leaves an unrelated pre-existing marker untouched).
`batch_task()` has no `collect` argument — the point is that raw values never
cross back to the parent, only a small commit record
(`list(committed = <name -> path>, attempt = <token>)`) does.

This unit implements ONLY package targets (`fn_kind = "package"`) and ONLY
`style = "return"`; `fn_kind = "adhoc"` and `style = "staged_writer"` are
structurally recognised but rejected with a clear "not yet supported" error
(later units). No consumer-opt-in skip/reuse logic exists yet (design section
7) — every item is always dispatched and always recomputed.

Normative doctrine (design section 0): no batchit dispatch decision may ever
depend on a marker's existence or contents — `batch_task()`'s parent-side code
validates only a marker's PATHNAME and parent directory, never reads/stats it;
only the child, while committing, ever touches one. A source-level lockdown
test guards this statically.

The wire protocol bumped (`.BATCH_PROTOCOL` 1 -> 2): the envelope gained a
required `meta$fn_kind` discriminator plus the declared-output commit fields
(`outputs`/`marker`/`style`/`attempt`). An old-protocol envelope is rejected,
and the worker now verifies protocol BEFORE loading any CONSUMER package (it
always loads the RUNNER first). `.batch_check_envelope()` also now rejects
any unknown `meta` field, closing the "typo'd field silently ignored" gap.

Adversarial-review hardening of Unit 1: the CHILD's `.batch_check_envelope()`
now re-validates output/marker path shape (already-normalized, absolute,
parent dir exists) and rejects `style != "return"` BEFORE the target ever
runs (previously a side-effecting target could execute for an envelope whose
style would fail anyway), rather than trusting the parent's checks alone.
The top-level envelope now rejects unknown fields, matching the
existing `meta`-field lockdown. A `batch_task()` commit result's value must
have EXACTLY the fields `committed`/`attempt` — no extra field can smuggle
raw data back to the parent. `batch_task()` now sweeps a failed (or killed)
item's own batchit-generated commit temps from the parent side on ANY item
failure — matched by the item's unique, attempt-scoped token
(`<basename>.<attempt>.tmp<random>`, via `list.files(all.files = TRUE)` so the
dotfile marker temp is included), so an unrelated file is never over-deleted.
This closes a temp leak when `kill_tree()`/SIGKILL reaches the child before its
own `on.exit` cleanup can run. Item ids containing `/`
or `\` are now rejected (they are interpolated into the per-item marker
filename).

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

- `package_function(package, symbol, version = NULL)` — a dispatch *descriptor*:
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

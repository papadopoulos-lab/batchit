# Phase 6′ design (v3) — batchit function dispatch + output-commit

Consolidated after the maintainer reframes + codex design rounds 1–2. **Doctrine (settled): batchit
dispatches and delivers outputs; it holds NO staleness opinion of its own.** Correctness + ergonomics
only. Baseline batchit 26.7.19 (HEAD 235174f).

## 0. Normative doctrine invariant (codex-supplied; test around it)
> **No batchit launch decision may depend on marker existence or contents.** Marker reads are
> permitted ONLY while completing or verifying an already-dispatched commit, or to hand a consumer its
> own prior `details` (§7). The marker carries NO batchit-computed input hash, code hash, mtime,
> provenance, or "need-not-run" state — only a protocol number, a random attempt token, the committed
> output names, and (§7) an OPAQUE consumer-supplied `details` value batchit ascribes no meaning to.

A lockdown test asserts batchit never branches *dispatch* on marker state.

## 1. The reframe — dispatch is a function on two orthogonal axes
Envelope `meta` carries:
- **`fn_kind`** — `"package"` (`package`+`symbol`+body/formals `hash`; hash-verified both ends;
  auditable; **production stages**) or `"adhoc"` (a serialized closure; static-lint gated; **ad-hoc
  only**).
- **`outputs`** (optional) — absent → return value (today's `batch_run`, `collect`-gated); present →
  declared-output commit (§3), result is a small commit record, never raw data.
Independent axes; the discriminated envelope codex required. `.BATCH_PROTOCOL` **bumps**; an old
executor rejects a new-shaped envelope (existing check `R/batch.R:258`); the worker checks protocol
BEFORE conditionally loading any consumer package.

## 2. Frontends
- `batch_run(target, items, …)` — unchanged (package fn, return value).
- `batch_task(fn, items, outputs, style, …)` — package|adhoc fn + declared-output commit. No
  `collect`. `fn` = a `batch_target()` descriptor (→ package) or a bare closure (→ adhoc).
- `batch_fn(fn, items, …)` — adhoc fn + return value.
Distinct public contracts; shared internal engine.

## 3. Declared-output commit (`batch_task`)

### 3.1 Outputs spec (per item; never in target args) + conservative path validation
`outputs` = a named character vector `c(<name> = <final path>)`. Lives in `meta`, never in `args`.
**Both-ends validation, conservatively scoped (codex 5):**
- non-empty; unique names; unique paths; absolute; `normalizePath(mustWork=FALSE)`-normalized.
- each destination is **absent OR an existing non-directory, non-symlink file** (dirs + symlinks rejected; base R cannot portably detect a FIFO/socket/device special file, so such a destination is not rejected and may be replaced by the commit rename — documented, not a guarantee).
- parent dir of each output/marker/stage path must already exist.
- **within ONE invocation**, reject any output path that aliases another (this item or a concurrent
  item) — normalize `..`, resolve existing symlinks, check hardlink identity where the platform
  exposes it. **Explicitly NOT promised:** cross-invocation/cross-process exclusivity (no global
  lock), case-fold/Unicode canonicalization on arbitrary mounts, or that an absent path cannot later
  become an alias. Contract assumes a **single exclusive writer** per output; TOCTOU between validate
  and rename is a documented boundary.

### 3.2 Two styles (external_writer dropped) — BOTH IMPLEMENTED (Unit 1 `return`, Unit 2 `staged_writer`)
| style | target does | child does |
|---|---|---|
| `return` | returns `list(<name>=<value>,…)`, names == declared names EXACTLY (unique exact set) | qs2-serialize each value to a unique temp in the destination dir, in declaration order |
| `staged_writer` | writes each output to `batch_stage_path(<name>)` (streaming); return value ignored | pre-computes each output's attempt-scoped staging temp BEFORE `do.call`, enters scope so the accessor can answer, then treats the staged file as the temp (step 1 is an ASSERTION, not a write) |
`return` codec is **qs2**, always. No arbitrary writer closures in the spec.
`staged_writer`'s scoped accessor is backed by a package-level environment
(`.batch_stage_env`), entered/exited around `do.call` in `.batch_execute()` (never inside
`.batch_commit_task()`, since the paths must exist BEFORE the target runs) — see
`batch_stage_path()` and `.batch_stage_paths_for()` in `R/batch_task.R`. The parent-side
sweep (`.batch_sweep_task_temps()`) matches `.<attempt>.tmp` OR `.<attempt>.stage`, covering
both styles' leftover temps under one SIGKILL/timeout cleanup path.

### 3.3 Commit sequence — child-side, in `.batch_execute` after `do.call` (codex 4 order)
1. Run the target; **prepare every output temp** (return: qs2-write each; staged: assert every
   `batch_stage_path(name)` exists as a regular non-symlink file — an undeclared/absent name → error,
   zero renames).
2. **Prepare + close the marker temp**, embedding a fresh **random attempt token** (+ protocol,
   committed names, §7 `details`).
3. Verify every temp (outputs + marker) is a regular non-symlink file.
4. **Remove the old final marker** and verify the removal succeeded (a stale marker must not survive
   into this attempt — the §7 read at step 0 already captured its prior `details`).
5. **Replace every final output** (rename temp → final).
6. **Rename the marker temp → final marker path LAST** (the atomic commit point — the last namespace op).
7. **Read back the final marker and verify the attempt token**; then emit the commit record.
**Cleanup is unconditional** on every failure path (target error after some staged files; partial
`return` serialization; failure mid output-rename loop; marker temp/rename failure; timeout/kill as
far as the parent can reach): remove only remaining temps; **never roll back by guessing old finals
are recoverable**. Preparing everything before step 4 keeps the invalid window minimal and stops a
serialization/marker failure from needlessly destroying the prior valid witness.
**Replacement primitive:** `file.rename()` overwrite semantics differ across POSIX/Windows/CIFS;
unlink-before-rename opens a missing-file window. Contract states supported semantics = POSIX +
server-side-atomic CIFS rename-replace; a platform-atomic-replace helper is supplied/tested, and the
production target (uppsala + CIFS) is the tested path.

### 3.4 `batch_stage_path(name)` (staged_writer only)
Returns the exact per-output sibling temp path batchit will rename from. Backed by a scoped option set
for the `do.call` duration (set/restore + unconditional cleanup). **Rejects an undeclared name**;
errors outside a staged run; partial stages cleaned on failure.

### 3.5 Result record (codex 3 fix)
The commit record echoes the **named output map** actually committed:
`list(committed = <named char: name -> final path>, attempt = <token>)`. The parent inspector compares
`committed` (names AND paths) + `attempt` against the dispatched `outputs` + the token it issued —
NOT a bare name list. No raw value ever crosses back (`batch_task` has no `collect`; the target return
is unconditionally discarded child-side after commit, all styles).

## 4. Discriminated envelope + validation matrix (codex 3) — IMPLEMENTED (Unit 3)
- `fn_kind` REQUIRED (`"package"|"adhoc"`); unknown/missing → reject at both ends.
- package: `package`+`symbol`+`hash` required; `dev_path` valid ONLY here (names the CONSUMER's tree).
- adhoc: closure (`meta$fn`) + per-dispatch nonce (`meta$nonce`) required; NO package/symbol/hash
  (forbidden, both directions — a `package`-kind envelope carrying `fn`/`nonce` is rejected too);
  worker preflight conditional on `fn_kind` (`inst/batch_worker.R`'s `.batch_worker_check()` requires
  `is.function(meta$fn)` for adhoc instead of package/symbol/hash); formals + args get the SAME
  both-end validation as package items (every arg a named formal; no positional; `...` **prohibited**,
  same as targets) via `.batch_validate_adhoc_item()`. `dev_path` for adhoc names BATCHIT'S OWN tree
  (no consumer identity exists to validate against) — resolved decision, see §5 note below.
- `style` required EXACTLY when `outputs` present; forbidden otherwise. Both styles (`return`,
  `staged_writer`) work for either `fn_kind` — style and fn_kind are independent axes, as designed.
- Unknown envelope fields are **rejected, not ignored**.

## 5. `adhoc` + the static self-containedness LINT (not proof) — IMPLEMENTED (Unit 3)
- `codetools::findGlobals(fn, merge=FALSE)` — inspect BOTH `$variables` AND `$functions`. Reject any
  global not in {base/implicit-base + base operators, a `pkg::`/`pkg:::` qualified reference}.
  Implemented as `.batch_lint_adhoc_fn()` (`R/batch_adhoc.R`), applied at BOTH ends: the frontend
  (`batch_fn()` / `batch_task()` with a bare closure) at dispatch time, and `.batch_check_envelope()`
  again in the CHILD. Verified empirically: `pkg::fun()`/`pkg:::fun()` calls are NEVER independently
  flagged by codetools (only the `::`/`:::` call itself is reported, and that is itself base), so no
  special-casing was needed for the qualified-call carve-out.
- **Mandatory** rebase of the (accepted) closure's environment to `baseenv()` before serialization —
  simpler than "optional," and closes the large/secret enclosing-environment carriage path. (No
  env-preservation mode; if ever needed it is a loud documented adhoc limitation.) Implemented as
  `.batch_rebase_adhoc_closure()`; the CHILD re-rebases defensively, right before `do.call()`, in case a
  hand-crafted envelope reached the worker with a closure that was never rebased. Verified empirically:
  an un-rebased closure's original environment (and anything bound in it) round-trips through the qs2
  wire INTACT (proof of the carriage path this closes); a `baseenv()`-rooted closure instead reconnects
  to the RECEIVING session's own `baseenv()`.
- Closure-only acceptance (a primitive is explicitly rejected — no real formals/body/environment to lint
  or rebase); `...` prohibited; `pkg::fun` runs whatever is installed in the child (no version claim).
- **Narrowed promise:** a best-effort static lint rejecting directly detectable unqualified global
  references — it does NOT prove behavioral closure, hermetic execution, portability, or dependency
  identity (blind spots: `get`/`mget`/`assign`/string `do.call`, `eval(parse())`, `substitute`,
  `.GlobalEnv`, formula/attr envs, `<<-`, S4/R5/R6 dispatch, ambient state). Ad-hoc only; production
  stays `fn_kind="package"`. Proven with a closure using `get("x", envir = environment())`: passes the
  lint (both `get`/`environment` are base), yet fails at RUN time in the real child subprocess because
  the rebase severed the environment the `get()` would otherwise have walked.
- **`codetools`** added to DESCRIPTION Imports.
- **`batch_fn(fn, items, n_workers, dev_path = NULL, collect = FALSE, ...)`** — IMPLEMENTED: the adhoc,
  return-value sibling of `batch_run()`, same transport/worker/both-ends validation, `R/batch_adhoc.R`.
- **Adhoc result identity (§9.4) — IMPLEMENTED:** since an adhoc envelope carries no package/symbol/hash,
  `.batch_inspect_result()`/`_impl()` gained an `expected_nonce` argument; when non-`NULL` it replaces the
  package-identity check with `tgt$fn_kind == "adhoc" && tgt$nonce == expected_nonce` (id is already
  checked, unconditionally, earlier in the same function). The nonce is a fresh per-item token from the
  SAME generator as `batch_task()`'s commit `attempt` token (`.batch_new_attempt_token()`, reused, not
  duplicated). For `batch_task()` + adhoc, BOTH `attempt` (commit-record witness, unaffected by fn_kind)
  and `nonce` (adhoc envelope identity) are issued — not redundant: `attempt` binds the MARKER/commit
  record; `nonce` binds the ENVELOPE's executed-code identity, exactly mirroring how `hash` does that job
  for `fn_kind = "package"`.
- **Resolved ambiguity — `dev_path` for adhoc:** the design text was silent on what `dev_path` should mean
  once there is no "consumer" identity to validate against. Resolved as: `dev_path` for `fn_kind = "adhoc"`
  ALWAYS names BATCHIT'S OWN source tree (validated via `.batch_validate_dev_path(dev_path, "batchit")`,
  and the worker's runner-load step treats a given adhoc `dev_path` the same way the package-kind
  `runner == consumer` self-test branch treats its own). This is what lets batchit's own adhoc test suite
  run against source without a reinstall; it is NOT a second dev-tree slot for some other helper package
  a closure's `pkg::fun()` might reference — those resolve via ordinary lazy namespace loading in the
  worker regardless (no pre-loading step needed, verified: R's `::` operator loads a not-yet-loaded
  namespace on its own). A downstream consumer's own `batch_fn()` calls pass `dev_path = NULL` in
  practice, getting the installed `batchit`.
- **Resolved: no `.BATCH_PROTOCOL` bump for Unit 3.** The envelope schema change is purely additive
  (`fn`/`nonce` are new OPTIONAL meta fields); an old (pre-Unit-3) worker already rejects `fn_kind =
  "adhoc"` loudly and structurally, before any code loads (`.batch_worker_check()`'s own hardcoded copy
  of the check), so the existing protocol number already provides the version-skew safety net Unit 1's
  bump was for. Confirmed by NOT needing to touch the `expect_identical(batchit:::.BATCH_PROTOCOL, 2L)`
  pin in `test-batch_task.R`.

## 6. Non-goals
No batchit-computed fingerprints, plan records, provenance sidecars, `task_scope_id`, content hashing,
or batchit DECIDING to skip. §7's skip is CONSUMER-decided; batchit only transports the record.

## 7. Opt-in consumer skip — `.batchit` record + `batch_prior()`/`batch_skip()` (maintainer-approved 2026-07-20; TTE STAYS SKIP-FREE) — REMOVED 2026-07-23
> **SUPERSEDED: this entire mechanism was REMOVED — see `PUBLIC_API.md` §5.** It had no
> consumer (TTE is skip-free by doctrine), so `batch_record()`/`batch_prior()`/`batch_skip()`,
> the `details`/`skipped` fields, and the prior-marker read were deleted; the commit engine is
> back to the pre-skip `{protocol, attempt, committed}` marker / `{committed, attempt}` result
> shape. The section below is retained as the historical design record of what Unit 4 built.

Build as OPT-IN; production s1/s2/s3 pass NO skip logic and always recompute (Phase 5′ unchanged).
- Marker `.batchit` = the commit record + an OPTIONAL consumer `details` value (§0 invariant: opaque to
  batchit; batchit never launches on it).
- **`batch_record(details)`** — fn attaches a small serializable `details` to THIS item's new marker.
  IMPLEMENTED: exported, `R/batch_task.R`. Backed by `.batch_record_env`, a scoped accessor entered/
  exited TIGHTLY around `do.call()` in `.batch_execute()` (mirrors `.batch_stage_env` exactly). Last
  call wins (§9.3); errors if called outside an active `batch_task()` target run.
- **`batch_prior()`** — returns the PRIOR marker's `details` (captured at step 0 before removal), or
  `NULL`. The fn inspects it. IMPLEMENTED: exported, `R/batch_task.R`. Step 0 is
  `.batch_read_prior_marker()` (child-side, before `do.call()`), which reads the final marker EXACTLY
  ONCE and accepts it as `prior` only if it decodes AND its protocol/attempt-token/committed-output-map
  verify against THIS item's own declared outputs (`.batch_valid_marker_record()`) — a malformed,
  foreign, absent, directory, or symlinked marker all become `prior = NULL`. A valid prior whose
  `details` is itself `NULL`/absent also makes `batch_prior()` return `NULL` (skip disabled), exactly as
  specified in §9.2.
- **`batch_skip()`** — fn RETURNS this sentinel → batchit does NOT re-commit: it verifies the prior
  marker + every declared output still exists (marker vouches they were fully committed), records done,
  preserves them, writes no new marker. Reachable only when `batch_prior()` was non-`NULL`. IMPLEMENTED:
  exported sentinel constructor (errors outside an active target run, like the other two accessors);
  `.batch_execute()` detects the sentinel (`.batch_is_skip()`) after `do.call()` and calls
  `.batch_commit_task_skip()` INSTEAD OF `.batch_commit_task()` — re-derives the witness fresh (re-reads
  + re-verifies the marker, re-stats every declared output as a regular non-symlink file), never trusting
  the step-0 snapshot. A `NULL` prior, or anything that no longer verifies/exists, fails loud with the
  marker left completely untouched (§9.2 point 4).
- **Doctrine (reconciled with §0):** batchit READS the marker (to serve `batch_prior` / verify a
  commit) and HONOURS `batch_skip`, but NEVER decides to skip and NEVER branches *launch* on the
  marker. The `details` are the consumer's — a weak `details` that mis-judges currency is the
  consumer's bug, exactly like swereg's own rawbatch/skeleton caches. Safer than the deleted s1 resume:
  the marker is an atomic commit point, not an mtime/existence heuristic.
- **Commit-record shape change:** the commit record gained a third, ALWAYS-present field —
  `list(committed, attempt, skipped)`. `skipped = FALSE` for an ordinary commit (`attempt` is the
  freshly-dispatched token, unchanged behaviour); `skipped = TRUE` for a skip-and-reuse (`attempt` is the
  PRIOR marker's OWN token, since nothing new was committed — by construction it can never equal the
  token this dispatch just issued). `.batch_inspect_result()`'s parent-side check is `skipped`-aware:
  the committed output map (names + paths) is always checked exactly; the attempt-token-must-match-
  dispatch check applies only when `skipped` is `FALSE`. No protocol bump (same reasoning as §5's
  no-bump note — this is a result-envelope shape produced and consumed by the SAME installed version
  within one call, not a dispatch-envelope skew concern).

## 9. Pre-code specifications (codex round-3; design is implementation-ready after these)

**9.1 Per-item output + marker addressing (P0).**
- `batch_task(fn, items, outputs, style, …)`: `outputs` is a **list aligned to `items`** —
  `outputs[[i]]` (a named character vector) is item `i`'s output map. Length must equal
  `length(items)`; if `items` is named, `outputs` may be named-by-item-id instead (same set of names).
- **Marker path is derived deterministically and uniquely per item:**
  `file.path(dirname(sort(output_paths)[1]), paste0(".batchit__", item_id))` — the lexicographically
  first output's directory + the item's already-required unique stable id (so two items sharing a
  directory never collide). Overridable via an explicit per-item marker path if a consumer needs one.
- Marker paths join the **invocation-wide collision check** (§3.1) against every output and every other
  marker. The **parent** validates only the marker *pathname* + its parent directory; it NEVER inspects
  marker existence/type/contents before launch (that is the child's job — §0).

**9.2 Step-0 / skip state machine (P1, normative).** Per item, in the child:
1. After dispatch, BEFORE `do.call`, read the final marker ONCE.
2. Accept it as `prior` ONLY if protocol + attempt token + exact output map decode and structurally
   verify; else `prior = NULL`. Expose `prior$details` via `batch_prior()` (NULL if no valid prior or
   details absent/`NULL` — a valid marker with `NULL` details therefore disables skip; document that).
3. Leave the final marker UNTOUCHED while the function runs.
4. On `batch_skip()`: require a non-NULL valid `prior`, else error (no marker removal); then re-read +
   match the marker token & output map AND re-stat every declared output as a regular non-symlink file;
   on success record done + preserve, writing no new marker; any mismatch/missing → fail loud, marker
   untouched.
5. On normal return: run commit steps §3.3 1–7 (only step 4 removes the old marker — so the old marker
   survives until every new temp is ready).

**9.3 Skip cleanup + `batch_record` (P1).** Skip is a *successful early exit*, so it must remove every
current-attempt stage/temp file before reporting reuse. `batch_record()` called more than once →
**last call wins**. `batch_record()` then `batch_skip()` → new details discarded, prior marker
unchanged. Unserializable/oversized `details` → the NORMAL commit fails BEFORE old-marker removal.
Scoped accessor state (stage dir, prior, record) is restored on success, error, AND skip.

**9.4 Ad-hoc result identity (P1).** The parent inspector today requires package/symbol/hash
(`R/batch.R:465`). Result identity is now **by `fn_kind`**: package results bind on package+symbol+hash
(unchanged); adhoc results bind on the **dispatch attempt token** (the id + a per-dispatch nonce the
parent issued), since an adhoc envelope has no package identity. `.batch_inspect_result` branches on
`fn_kind`.

**9.5 §0 lockdown tests (normative).** Prove: parent scheduling/launch traces are IDENTICAL with
absent / valid / malformed / stale markers; NO marker read occurs before worker dispatch; ONLY an
explicit function-returned `batch_skip()` sentinel enters reuse handling; batchit never compares or
interprets `details`. Plus a parse/AST guard that no dispatch-launch path references marker state.

## 8. swereg migration (separate phase, after batchit ships; NO skip logic)
Stage table: **s2 FIRST (canary, `return`, replaces `.resume_fresh`)** → s1c, s1b (`return`) → s1a, s1d
(`staged_writer`). `save_rawbatch` later; `process_skeletons` + s3 out of scope. Each: swap the
hand-rolled write for a `batch_task` declared-output call (no `batch_prior`/`batch_skip`); proven-red
(killed mid-commit → no marker → item fails loud; wrote-nothing → fails loud); full swereg suite; codex
gate; push; CI. Reinstall batchit before testing; nothing runs mid-pipeline.

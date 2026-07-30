# batchit design

Why batchit is built the way it is. This is the maintainer's document. Users want
`README.md`, the "Choosing a dispatch function" vignette, and the help pages.

It replaces the two documents that used to sit here, `PHASE6_DESIGN.md` and
`PUBLIC_API.md`. Those described the work while it was being planned, so they used
function names that no longer exist and specified a skip mechanism that was later
deleted. Everything below describes batchit as it is now. Section 9 records the
history.

## 1. Doctrine: batchit holds no staleness opinion

This is the invariant everything else is built around.

**No batchit launch decision may depend on a marker file's existence or contents.**
batchit reads a marker only to finish or verify a commit it has already dispatched.
The marker carries a protocol number, a random attempt token, and the committed
output names. It carries no input hash, no code hash, no mtime, and no
"need-not-run" state.

So batchit never decides that an item can be skipped. It schedules every item it is
given. If an output file already exists, batchit replaces it.

A lockdown test asserts that batchit never branches dispatch on marker state:
parent scheduling traces must be identical whether the marker is absent, valid,
malformed, or stale, and no marker read may occur before a worker is dispatched.

The reason for the rule is division of labour. batchit dispatches and delivers
output. Deciding what to run belongs to the consumer, which knows the domain. For
the MHT pipeline that consumer is swereg's `RegistryStudy` R6 class. Do not add a
stateful batch object to batchit.

An **item** is one named argument set for `fn`: a named list whose names match
`fn`'s formals. batchit hands it over through a checked `do.call` and never looks
inside it.

## 2. Two independent axes

Every dispatch is a point on two axes, and the envelope's `meta` block carries
both.

`fn_kind` says how the function reaches the worker.

* `"package"` carries a package name, a symbol, and a hash of the function's body
  and formals. Both ends verify the hash. This is the auditable form, and it is
  what production stages use. `package_function()` builds it.
* `"adhoc"` carries a serialized closure instead. A static lint gates it. The user
  documentation calls this an inline function. It is for tests and one-off work.

`outputs` says what comes back.

* Absent means the worker returns a value, and `collect` decides whether the parent
  keeps it.
* Present means the worker commits declared output files (section 4) and returns a
  small commit record. No raw data crosses back.

The axes are independent: either `fn_kind` works with either delivery mode. The
envelope is discriminated on `fn_kind`, so a field that belongs to one kind is
rejected outright on the other rather than ignored.

`.BATCH_PROTOCOL` guards version skew. An old worker rejects a new-shaped envelope,
and the worker checks the protocol number before it loads any consumer package.

## 3. The public surface

Names are bare and meant to be used qualified, as `batchit::run(...)`. There is no
`batch_` prefix, because the package name already carries it. The names are long
and self-describing on purpose: batchit exports few functions to a wide audience,
so each name states what it does in full.

The four dispatch functions split on one question. Can each worker read its own
data, or must a single reader produce it?

**Each worker reads its own data.** This is the normal case. Every TTE stage fits
it, s1, s2, s3 and skeleton creation alike, which is a statement about which shape
suits them and not about which were migrated. Section 9 records what actually moved
across. You pass the complete list of items, and `fn` both loads and computes
inside the worker.

The first three functions start a fresh worker process per item, and process exit
is what reclaims that item's memory. The streaming function reuses a small pool of
persistent `mirai` daemons instead, and gives that property up.

| Function | Delivery |
|---|---|
| `run(fn, items, n_workers, ...)` | runs each item, returns nothing |
| `run_and_collect(fn, items, n_workers, ...)` | returns a list of values, in item order, NULL-safe |
| `run_and_write_files_atomically(fn, items, outputs, style, n_workers, ...)` | each item commits its output files |

**One reader produces the data.** This is the specialist, for a single sequential
source too large for each worker to read independently. The 55 GB `LMED` file is
the case it exists for, and `save_rawbatch` is its only consumer.

| Function |
|---|
| `stream_from_parent_and_write_files_atomically(fn, ids, producer, outputs, style, n_workers, ...)` |

`producer` is a callback, `function(id)` returning that item's argument set. batchit
calls it in the parent, lazily, one item at a time as in-flight slots free up. Only
the producer's result crosses to the worker, so the producer itself may read the
parent environment freely.

These two shapes are not symmetric halves of a grid. The first is the norm; the
second is one function for one situation.

"NULL-safe" above means a `NULL` return from `fn` keeps its slot in
`run_and_collect()`'s list rather than vanishing, so the result is always the same
length as `items` and indexes alongside it.

Three helpers complete the surface.

* `package_function(package, symbol)` builds the hash-verified descriptor for `fn`.
* `where_to_write_output(name)` is called inside a `style = "staged_writer"`
  target. It returns the sibling temp path to write output `name` to, so a streamed
  write still goes through the atomic commit.
* `write_qs2_atomically(object, path, ...)` is a standalone atomic qs2 writer with
  no dispatch involved. Section 8 covers what it does not promise.

## 4. Declared-output commit

### 4.1 The outputs spec and path validation

`outputs` is a named character vector per item, `c(<name> = <final path>)`. It
lives in the envelope's `meta`, never in the target's `args`, because it is
batchit's business and not the target's.

Both ends validate it, conservatively:

* non-empty, unique names, unique paths, absolute, normalized with
  `normalizePath(mustWork = FALSE)`;
* each destination is either absent or an existing file that is neither a directory
  nor a symlink. Base R cannot portably detect a FIFO, socket, or device file, so
  such a destination is not rejected and the commit rename may replace it. That is
  documented, not guaranteed;
* the parent directory of every output, marker, and stage path must already exist;
* within one invocation, an output path that duplicates another is rejected,
  whether the other belongs to this item or a concurrent one. Every path has
  already had `..` normalized and its existing symlinked ancestors resolved by
  the time `.batch_check_task_collisions()` sees it, and that function then runs
  `anyDuplicated()` across every output and every marker.

What is explicitly not promised:

* **Hardlink aliasing is NOT detected.** The collision check compares normalized
  pathname *strings*. It reads no device or inode identity, so two different paths
  that are hardlinks to one inode both pass. The original design text claimed
  "check hardlink identity where the platform exposes it"; that was never
  implemented, and this document does not carry the claim forward.
* Exclusivity across invocations or processes. There is no global lock.
* Case-fold or Unicode canonicalization on arbitrary mounts.
* That a path absent at validation time cannot become an alias later.

The contract assumes one exclusive writer per output. The TOCTOU window between
validation and rename is a documented boundary.

### 4.2 The two styles

`style` is required exactly when `outputs` is present, and forbidden otherwise.

| style | the target does | the worker does |
|---|---|---|
| `return` | returns `list(<name> = <value>, ...)`, whose names are exactly the declared names | serializes each value with qs2 to a unique temp in the destination directory, in declaration order |
| `staged_writer` | writes each output to `where_to_write_output(<name>)` and returns nothing worth keeping | computes each output's attempt-scoped staging temp before `do.call`, enters scope so the accessor can answer, then treats the staged file as the temp |

The `return` codec is always qs2. The spec has no arbitrary writer closures in it.

`staged_writer`'s scoped accessor is backed by a package-level environment,
`.batch_stage_env`, entered and exited around `do.call` in `.batch_execute()`. It
cannot live inside `.batch_commit_task()`, because the paths have to exist before
the target runs. See `where_to_write_output()` and `.batch_stage_paths_for()` in
`R/batch_task.R`.

The parent-side sweep, `.batch_sweep_task_temps()`, matches `.<attempt>.tmp` or
`.<attempt>.stage`, so one cleanup path covers both styles' leftovers after a
SIGKILL or a timeout.

### 4.3 The commit sequence

Child-side, in `.batch_execute()` after `do.call`:

1. Run the target and prepare every output temp. For `return`, qs2-write each
   value. For `staged_writer`, assert that every `where_to_write_output(name)`
   exists, is not a directory, and is not a symlink. An undeclared or absent name
   is an error here, with zero renames done.
2. Prepare and close the marker temp, embedding a fresh random attempt token, the
   protocol number, and the committed names.
3. Verify that every temp, outputs and marker alike, passes the same three checks.
4. Remove the old final marker and verify the removal succeeded. A stale marker
   must not survive into this attempt.
5. Replace every final output by renaming its temp over it.
6. Rename the marker temp to the final marker path. This is last, and it is the
   commit point.
7. Read the final marker back, verify the attempt token, and emit the commit
   record.

Steps 1 and 3 say "exists, not a directory, not a symlink" rather than "a regular
file" on purpose. That is exactly what `file.exists()`, `dir.exists()` and
`Sys.readlink()` can establish, and it is the same limit section 4.1 records for
destinations: base R has no portable "is this a regular file" primitive, so a FIFO,
socket, or device file at a staging path is not caught.

Cleanup is unconditional on every failure path: a target error after some files
were staged, a partial `return` serialization, a failure midway through the output
rename loop, a marker temp or rename failure, and a timeout or kill as far as the
parent can reach. Cleanup removes remaining temps only. It never rolls back by
guessing that old finals are recoverable.

Preparing everything before step 4 is deliberate. It keeps the invalid window as
short as possible, and it stops a serialization or marker failure from destroying
the previous valid witness for nothing.

The guarantee this buys is different in each phase, and the user documentation says
so in those terms. Before the first replacement, no declared output is touched.
During the replacement loop the set is not transactional: a kill or a rename
failure can leave some outputs replaced and others not, and batchit never rolls
back a final it has already renamed. An individual file is still never
half-written, but the set can be torn, and a torn set has no valid marker vouching
for it. After the marker is written the files are committed even if the call still
reports failure, because the worker serializes its result envelope only after
committing. A timeout is not confined to one phase: it measures the worker's whole
lifetime and can land mid-commit.

**The replacement primitive.** `file.rename()` overwrite semantics differ across
POSIX, Windows, and CIFS, and unlink-before-rename opens a window where the file is
missing. The contract states the supported semantics: POSIX, plus CIFS where the
server does the rename-replace atomically. A platform-atomic-replace helper is
supplied and tested, and the production target (uppsala over CIFS) is the tested
path.

### 4.4 `where_to_write_output(name)`

Only meaningful during a `staged_writer` run. It returns the exact per-output
sibling temp path batchit will rename from. It is backed by scoped state that is
set and restored around `do.call`, with unconditional cleanup. It rejects a name
the item did not declare, and it errors outside a staged run. Partial stages are
cleaned up on failure.

### 4.5 The commit record

The record echoes the named output map that was actually committed:
`list(committed = <named character: name -> final path>, attempt = <token>)`.

The parent inspector compares `committed` on both names and paths against the
`outputs` it dispatched, and compares `attempt` against the token it issued. A bare
list of names would not be enough to catch a stale or substituted result.

No raw value ever crosses back on this path. The target's return value is discarded
in the worker after the commit, in both styles.

### 4.6 Marker and output addressing

`outputs` is a list aligned to `items`: `outputs[[i]]` is item `i`'s output map, and
the length must equal `length(items)`. When `items` is named, `outputs` may be named
by item id instead, carrying the same set of names in any order.

The marker path is derived deterministically per item:

```r
file.path(dirname(sort(output_paths)[1]), paste0(".batchit__", item_id))
```

That is the lexicographically first output's directory plus the item's already
unique stable id, so two items sharing a directory can never collide.

The derivation is not overridable. The original design text said a consumer could
supply an explicit per-item marker path, but no such argument was ever built:
`run_and_write_files_atomically()` and
`stream_from_parent_and_write_files_atomically()` both call
`.batch_task_marker_path()` unconditionally, and neither takes a marker argument.
The envelope carries a `marker` field, but that is batchit filling in its own
derivation, not a consumer override.

Marker paths join the invocation-wide collision check in section 4.1, against every
output and every other marker. The parent validates the marker pathname and its
parent directory only. It never inspects the marker's existence, type, or contents
before launch, which is section 1's job.

Because the filename is built from the item id, an id must not contain `/` or `\`.

## 5. The envelope

The per-item wire unit is an S3 object of class `batch_envelope`:
`structure(list(protocol, meta, args), class = "batch_envelope")`, with a validator
and a `print` method. The dispatchers build one per item and the worker validates
it. Nobody outside batchit constructs or passes one.

It stays a plain list on the wire so a worker can read one with bare `qs2::` before
any package loads. That is the trust gate: it lets the worker refuse a
version-skewed or hostile envelope before loading the code it names. For the same
reason the structural pre-check in `inst/batch_worker.R`,
`.batch_worker_check()`, is a standalone base-R copy rather than a call into the
package. A conformance test asserts the two agree.

The validation matrix:

* `fn_kind` is required and must be `"package"` or `"adhoc"`. Missing or unknown is
  rejected at both ends.
* `package` requires `package`, `symbol`, and `hash`, and forbids `fn` and `nonce`.
* `adhoc` requires the closure in `meta$fn` and a per-dispatch nonce in
  `meta$nonce`, and forbids `package`, `symbol`, and `hash`. The worker preflight
  branches on `fn_kind`, so `.batch_worker_check()` demands `is.function(meta$fn)`
  for adhoc instead of the package identity triple.
* `dev_path` is legal on both kinds. What it must name differs, and section 6
  covers the adhoc case.
* Formals and args get identical validation on both kinds, through
  `.batch_validate_item()` and `.batch_validate_adhoc_item()`. Every argument must
  be a named formal, nothing may be positional, and `...` is prohibited.
* `style` is required exactly when `outputs` is present and forbidden otherwise.
* Any field outside the known set is rejected, not ignored.

**Why every formal must be named, defaults included.** An optional formal was
silently dropped for a year in the originating pipeline, precisely because the old
check demanded only the required ones. Demanding all of them makes "an optional
argument is silently absent" indistinguishable from a typo, which is the point.

**Why adding the adhoc fields did not bump the protocol.** `fn` and `nonce` are
additive optional `meta` fields. An old worker already rejects
`fn_kind = "adhoc"` loudly and structurally, in its own hardcoded
`.batch_worker_check()` copy, before any code loads. So the existing protocol
number already provided the version-skew safety net that the earlier bump to `2`
was for. Removing the skip fields later needed no bump for the same reason.

**Deferred.** The envelope constructor and the in-package validator are written
out separately and have to be kept in step by hand. Deriving both from one
declarative field matrix is a wanted change that was never made.

## 6. Inline functions and the self-containedness lint

`fn_kind = "adhoc"` accepts a closure by value. Two mechanisms make that
acceptable, and neither is a proof.

**The lint.** `.batch_lint_adhoc_fn()` in `R/batch_adhoc.R` runs
`codetools::findGlobals(fn, merge = FALSE)` and inspects both `$variables` and
`$functions`. It rejects any global that is not base R, a base operator, or a
`pkg::`/`pkg:::` qualified reference. It runs at both ends: in the frontend at
dispatch time, and again in `.batch_check_envelope()` in the worker. No
special-casing was needed for the qualified-call carve-out, which was verified
empirically: codetools never flags `pkg::fun()` independently, it reports only the
`::` call itself, and `::` is base.

**The rebase.** An accepted closure's environment is rebased to `baseenv()` before
serialization. This is mandatory rather than optional, which is simpler and closes
the path by which a large or secret enclosing environment would ride along. It is
`.batch_rebase_adhoc_closure()`, and the worker rebases again defensively right
before `do.call()`, in case a hand-crafted envelope arrived carrying a closure that
was never rebased. Also verified empirically: an un-rebased closure's original
environment, and everything bound in it, round-trips through the qs2 wire intact,
which is exactly the carriage path this closes. A `baseenv()`-rooted closure
reconnects instead to the receiving session's own `baseenv()`.

Only closures are accepted. A primitive is rejected, having no real formals, body,
or environment to lint or rebase. `...` is prohibited. A `pkg::fun` call runs
whatever is installed in the worker, and batchit makes no version claim about it.

**The narrowed promise.** This is a best-effort static lint that rejects directly
detectable unqualified global references. It does not prove behavioural closure,
hermetic execution, portability, or dependency identity. The blind spots are
`get`, `mget`, `assign`, string `do.call`, `eval(parse())`, `substitute`,
`.GlobalEnv`, formula and attribute environments, `<<-`, S4/R5/R6 dispatch, and
ambient state. Production stays on `fn_kind = "package"`. Proven with a closure
using `get("x", envir = environment())`: it passes the lint, because both `get` and
`environment` are base, and still fails at run time in a real worker, because the
rebase severed the environment the `get()` would have walked.

`codetools` is in DESCRIPTION Imports for this.

**`dev_path` for adhoc.** With no consumer package there is no consumer identity to
validate against, so `dev_path` always names batchit's own source tree, validated
by `.batch_validate_dev_path(dev_path, "batchit")`. This is what lets batchit's own
adhoc test suite run against source without a reinstall. It is not a second dev
tree slot for some helper package a closure's `pkg::fun()` references. Those
resolve through ordinary lazy namespace loading in the worker, with no pre-loading
step, because R's `::` operator loads a namespace that is not yet loaded on its
own. A downstream consumer passes `dev_path = NULL` and gets the installed batchit.

## 7. Result identity

The parent inspector, `.batch_inspect_result()`, is total: a malformed result
becomes a `reason` string, never a throw, so it flows through the caller's uniform
failure path.

It checks, in order, that the result is a list, the protocol, the status, that the
id matches the dispatched id, and then identity of the code that actually ran.
Identity is by `fn_kind`.

* `package` binds on the full triple, package and symbol and hash. All three,
  because a body/formals hash can collide across two functions.
* `adhoc` has no package identity, so it binds on the id, already checked, plus a
  fresh high-entropy per-dispatch nonce the parent issued and the worker echoes
  back in the result envelope's `target` field as
  `list(fn_kind = "adhoc", nonce = <nonce>)`.

Do not confuse two different things both called `target`. The result envelope's
`target` field is always required to be a list, on both kinds: a `NULL` there is
rejected as "result envelope has a malformed target field". What may be `NULL` on
the adhoc path is the `target` *argument* to `.batch_inspect_result()`, the
descriptor the parent dispatched, because an adhoc dispatch has no descriptor. The
inspector then reads `expected_nonce` instead.

The nonce comes from the same generator as the commit attempt token,
`.batch_new_attempt_token()`, reused rather than duplicated. On an adhoc
`run_and_write_files_atomically()` call both are issued, and they are not
redundant: `attempt` binds the marker and the commit record, `nonce` binds the
envelope's executed-code identity. `nonce` does for adhoc what `hash` does for
package.

## 8. What batchit does not do

**No provenance program.** No batchit-computed fingerprints, plan records,
provenance sidecars, `task_scope_id`, or content hashing. This is the shelved
program section 1 forbids.

**No skip.** batchit never decides to skip an item. See section 9 for the opt-in
consumer skip that was built and then removed.

**No thread management.** batchit sets no BLAS or `data.table` thread counts. A
multi-threaded `fn` has to lower its own thread count when several workers run at
once.

**`write_qs2_atomically()` promises less than it looks like it does.** It is not
durability: `file.rename()` is atomic with respect to readers, not an `fsync`, so a
power loss can still lose a renamed file whose data never reached the disk. It is
not a lock: two concurrent writers of one path each produce a complete file and the
last rename wins. It does not always clean up, because `on.exit()` cannot run after
a `SIGKILL`, so a hard-killed worker leaves its randomly named `.tmp` behind. The
destination is still absent-or-complete, which is the part that matters.

Its temp comes from `tempfile()` in the destination directory rather than
`paste0(path, ".tmp", Sys.getpid())`. A PID suffix is not collision-proof: PIDs are
unique only among live processes on one host, and this kind of data commonly lives
on a share that two hosts mount at once, so the same PID on two machines could pick
the same temp path for the same target. Same directory is required, because
`file.rename()` is not atomic across filesystems.

It is independent of the commit engine. It does its own `file.rename()` rather than
calling `.batch_atomic_replace()`, because that helper hardcodes the
`batch commit:` error prefix, which a standalone save must not emit, and is
documented as the one place a commit temp becomes final. Its temp carries no
dispatch attempt token, so `.batch_sweep_task_temps()` can never match it.

## 9. History

**The naming migration.** The functions were once called `batch_run`, `batch_task`,
`batch_stream`, `batch_target`, `batch_fn`, and `batch_stage_path`. The engine and
the wire protocol did not change; the exports were renamed to the bare
self-documenting names in section 3. `collect` stopped being a flag and became part
of the name, splitting `batch_run` into `run` and `run_and_collect`. `batch_fn`
folded into those two, because package-versus-closure is a property of the `fn`
argument and needs no name of its own. `batch_stream`, which delivered return
values over the mirai transport, was dropped: it had no consumer, and shape B
collapsed to the single atomic-write specialist,
`stream_from_parent_and_write_files_atomically()`. The retired names have no
aliases.

**The opt-in consumer skip, built and removed.** A mechanism once let the consumer
attach an opaque `details` value to an item's marker (`batch_record()`), read the
previous run's `details` back (`batch_prior()`), and return a sentinel that told
batchit to keep the existing outputs instead of recommitting (`batch_skip()`).
batchit never interpreted `details` and never decided to skip, so it did not
violate section 1. It was removed because nothing used it: the TTE stages are
skip-free by doctrine. The commit engine went back to a `{protocol, attempt,
committed}` marker and a `{committed, attempt}` result. Re-add it only if a real
consumer needs it, and read the git history for the state machine before you do.

**The swereg migration.** batchit's dispatch logic began inside swereg, where it ran
registry-analysis pipelines in production, and was extracted so other projects could
use it without depending on swereg. The stages moved over in this order: s2 first as
the canary, replacing `.resume_fresh` with `return`, then s1c and s1b on `return`,
then s1a and s1d on `staged_writer`. `save_rawbatch` came later, on the streaming
function. `process_skeletons` and s3 stayed out of scope. No stage passes skip logic;
they all recompute.

Each stage had to clear the same gates before it moved: swap the hand-rolled write
for a declared-output call, prove the tests red first (kill mid-commit, get no
marker, and see the item fail loudly; write nothing, and see it fail loudly), run
the full swereg suite, pass a codex review, push, and get CI green. batchit had to
be reinstalled before testing, and nothing ran mid-pipeline.

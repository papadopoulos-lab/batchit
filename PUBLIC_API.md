# batchit public API

**Status: authoritative public surface (naming v2). Adopted after design
review, 2026-07-22.**

This document defines the public functions batchit exports and what each
one does. It **supersedes the function NAMES** used in
`PHASE6_DESIGN.md` (`batch_run`, `batch_task`, `batch_stream`,
`batch_target`, `batch_fn`, `batch_stage_path`, `batch_record`,
`batch_prior`, `batch_skip`). It does **not** change the MECHANISM in
`PHASE6_DESIGN.md` — the wire protocol, the envelope, the atomic commit
engine, and the §0 doctrine invariant are all unchanged.

Names are **bare and qualified-use** (`batchit::run(...)`), with no
`batch_` prefix — the package name already carries that. Names are
**full-sentence and self-documenting** by deliberate choice: batchit
exports few functions to a wide (CRAN) audience, so each name states its
behavior in full.

## 1. Mental model

batchit is **brainless muscle**: run one function across many
argument-sets, one fresh subprocess per set. It holds no state, decides
nothing, and knows nothing about the domain.

The **brain** — which items to run, which function, tracking progress —
lives in the **consumer** (for the MHT project, swereg’s `RegistryStudy`
R6 class). Do not add a stateful “batch” object to batchit; that is the
shelved provenance program the §0 doctrine forbids.

An **item** is one named argument-set for `fn` — a named list whose
names match `fn`’s formals. batchit hands it to `fn` as its arguments
through a checked `do.call` (every element a named formal; no
positional; no `...`). batchit never looks inside an item.

## 2. Two shapes

The distinction is: **can each worker read its own data, or must one
reader produce it?**

- **Shape A — the normal case.** Each worker opens its own data. You
  pass the complete list of items; `fn` both loads and computes, running
  in the worker. This covers every TTE stage: s1, s2, s3, and skeleton
  creation.
- **Shape B — the specialist.** A single sequential source too large to
  read independently per worker (the 55 GB `LMED` file). One reader —
  the parent — streams through it once and hands out slices. The
  **sole** consumer is `save_rawbatch`.

Shape A is the norm. Shape B is one function for one situation. They are
not symmetric halves of a grid; do not treat Shape B as a routine
choice.

## 3. The surface

### 3.1 Shape A — the normal API

One `fn` that loads its own data and computes.

| Function | Delivery |
|----|----|
| `run(fn, items, n_workers, ...)` | run each item, return nothing |
| `run_and_collect(fn, items, n_workers, ...)` | return a list of values, in item order |
| `run_and_write_files_atomically(fn, items, outputs, style, n_workers, ...)` | each item commits its output files atomically |

### 3.2 Shape B — the specialist

The parent produces each slice via a callback; workers commit files
atomically.

| Function |
|----|
| `stream_from_parent_and_write_files_atomically(fn, ids, producer, outputs, style, n_workers, ...)` |

`producer` is a callback, `function(id) -> that item's argument-set`.
batchit calls it **in the parent**, lazily, one item at a time as
workers free up (bounded queue). Only the producer’s RESULT crosses to
the worker; the producer function itself stays in the parent and may
access the parent environment freely.

### 3.3 Helpers

- `package_function(package, symbol)` — the hash-verified descriptor for
  `fn`. Names a package function plus a body/formals identity hash, so a
  worker refuses code that differs from what the parent dispatched.
- `where_to_write_output(name)` — called INSIDE a
  `style = "staged_writer"` target; returns the exact sibling temp path
  to write output `name` to, so a streamed write still goes through the
  atomic commit.

### 3.4 `fn`: a package function OR a closure

Every dispatcher’s `fn` accepts either:

- a `package_function(...)` descriptor — hash-verified; **use in
  production**; or
- a bare closure — ad-hoc, gated by a static self-containedness lint and
  a mandatory [`baseenv()`](https://rdrr.io/r/base/environment.html)
  rebase; **for tests and one-offs only**.

This folds in the former `batch_fn`. The package-vs-closure choice is a
property of the `fn` argument, not a separate function name.

### 3.5 `batch_envelope` (internal S3 class)

The per-item wire unit is an S3 `batch_envelope`:
`structure(list(protocol, meta, args), class = "batch_envelope")`, with
a validator and a `print` method. The dispatchers build one envelope per
item; the child validates it. **You never construct or pass an
envelope.**

It stays a plain list on the wire so a worker can read one with bare
`qs2::` BEFORE any package loads — the trust gate that lets the worker
refuse version-skewed or hostile code before loading it. For the same
reason the hardcoded structural pre-check in `inst/batch_worker.R`
(`.batch_worker_check()`) stays a standalone base-R copy; a conformance
test asserts it agrees with the S3 validator.

## 4. Old -\> new mapping

| Old (PHASE6_DESIGN.md) | New | Note |
|----|----|----|
| `batch_run(..., collect = FALSE)` | `run` | collect is now the NAME, not a flag |
| `batch_run(..., collect = TRUE)` | `run_and_collect` |  |
| `batch_task` (Shape A) | `run_and_write_files_atomically` | rename |
| `batch_stream` | *dropped* | Shape B return-value modes have no consumer |
| *(new code)* | `stream_from_parent_and_write_files_atomically` | Shape B + atomic commit; NEW |
| `batch_target` | `package_function` |  |
| `batch_stage_path` | `where_to_write_output` |  |
| `batch_fn` | *folded into* `run` / `run_and_collect` | `fn` accepts a closure |
| `batch_record` / `batch_prior` / `batch_skip` | *deleted* | opt-in skip; no consumer |

## 5. What is dropped, and why

- **`batch_record` / `batch_prior` / `batch_skip`** (the opt-in consumer
  skip) — no consumer. The TTE stages are skip-free by doctrine (Phase
  5’). Re-add only if a real consumer ever needs it.
- **`batch_fn`** as a separate export — the package-vs-closure axis is
  the `fn` argument’s type, so it needs no name of its own.
- **Shape B return-value modes** (`batch_stream` with `collect`) — no
  consumer. Shape B collapses to the single atomic-write specialist.

## 6. Semantics that changed

- **`collect` is no longer a flag.** `run` returns nothing;
  `run_and_collect` returns a list the length of `items`, in item order,
  NULL-safe (a `NULL` return keeps its slot, it does not vanish).
- **`outputs`** — a per-item named character vector,
  `c(<name> = <final path>)`. Commit is atomic: the `.batchit` marker is
  renamed into place last and IS the commit point. See
  `PHASE6_DESIGN.md` section 3.
- **`style`** — `"return"` (the target returns `list(<name> = <value>)`
  and batchit qs2-serializes each) or `"staged_writer"` (the target
  writes each output itself to `where_to_write_output(<name>)`).
- **`producer`** runs in the PARENT; only its result crosses to a
  worker.

## 7. Build plan (separate phase, codex-gated)

1.  **Rename sweep.** Old frontends -\> the new names; split `collect`
    into `run` / `run_and_collect`; fold `batch_fn`; delete the skip
    trio; drop the Shape B return-value modes. Covers `NAMESPACE`,
    roxygen tags, the test files, `NEWS.md`, `README.md`, and
    `PHASE6_DESIGN.md` cross-references. Gate: `rcmdcheck` clean + full
    test suite green.
2.  **Build `stream_from_parent_and_write_files_atomically`.** NEW code:
    the Shape B (mirai/producer) transport plus the child-side commit
    engine that the Shape A atomic path already uses (the commit engine
    reads the envelope and does not care how the item arrived).
    Proven-red test (killed mid-commit -\> no marker -\> item fails
    loud). codex gate.
3.  **`batch_envelope` S3 wrapper** — validator + `print`; conformance
    test vs the hardcoded `.batch_worker_check()`.
4.  *(deferred)* single-source envelope schema, so the constructor and
    the in-package validator derive from one declarative field matrix.

## 8. Doctrine (unchanged)

The §0 normative invariant holds: no batchit LAUNCH decision depends on
marker state. No caching lives in batchit. No stateful batch object. See
`PHASE6_DESIGN.md` sections 0 and 6.

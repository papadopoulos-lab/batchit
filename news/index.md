# Changelog

## batchit 26.7.29

**New vignette: “Choosing a dispatch function”**
(`vignettes/choosing-a-dispatch-function.Rmd`). The pkgdown site had a
reference index but no articles. This walks through all four dispatch
functions with worked examples, states the two questions that pick
between them, and covers the two `style`s, inline `fn` versus
[`package_function()`](https://papadopoulos-lab.github.io/batchit/reference/package_function.md),
the name-every-argument rule, what the atomic guarantee does and does
not cover, and failure behaviour. No code changes: documentation only.

Chunks are `eval = FALSE` with output shown as `#>` comments. Every
example starts real subprocesses, and the streaming one needs a function
installed in the reader’s own package, so executing them at build time
would be slow and partly impossible.

`.github/workflows/R-CMD-check.yaml` gains
`r-lib/actions/setup-pandoc@v2`. `R CMD check` builds and re-renders
vignettes; the pkgdown workflow already had this step, this one did not,
because the package shipped no vignette until now. `DESCRIPTION` gains
`VignetteBuilder: knitr` and `knitr` + `rmarkdown` under `Suggests`.

**pkgdown site adopts the shared house style.** `_pkgdown.yml` switches
from a bare `template: bootstrap: 5` to
`template: package: pkgdowntemplate` – the same template package swereg
uses – and adds a `params: hero:` block (overline, title, lede, and two
calls to action pointing at the new vignette and the reference index),
plus the shared `authors:` footer/sidebar block. `DESCRIPTION` gains
`Config/Needs/website: papadopoulos-lab/pkgdowntemplate`, which is how
the pkgdown workflow installs it (`setup-r-dependencies` with
`needs: website`).

batchit ships no logo, unlike swereg. The hero’s art column is
`auto`-width and the template emits it only when a logo exists, so the
band renders text-only with no gap. Adding `man/figures/logo.png` (and
[`pkgdown::build_favicons()`](https://pkgdown.r-lib.org/reference/build_favicons.html))
would populate it later with no config change.

**CORRECTION: the atomic-write guarantee was documented as stronger than
it is.** `README.md` and the
[`run_and_write_files_atomically()`](https://papadopoulos-lab.github.io/batchit/reference/run_and_write_files_atomically.md)
roxygen both said that on any failure – explicitly including a rename
failure – none of an item’s declared files are replaced. That is false,
and `.batch_commit_task()`’s own internal roxygen has always said so:
step 5 replaces finals one at a time and “never rolls back an
already-renamed final – a crash between two output renames leaves a torn
state”.

All three copies (vignette, `README.md`, roxygen) now state the boundary
by phase:

- **before the first replacement** – an error in `fn`, a `"return"`
  value whose names do not match, an output a `"staged_writer"` never
  wrote, a failure serializing a staged file – no declared output is
  touched;
- **during the replacement loop** – not transactional; a kill or a
  rename failure can leave the set torn, with no valid marker vouching
  for it. An individual file is still never half-written, rename
  replacement being atomic within a filesystem;
- **after the marker is written** – committed, even when the call
  reports failure, because the worker serializes its result envelope
  only after committing.

A `timeout` is explicitly NOT confined to the first phase: it measures
the worker’s whole lifetime and can land mid-commit, which `R/batch.R`’s
own comment notes for the `mirai` path.

Four smaller documentation claims were wrong the same way and are also
corrected: `producer()` is called when an in-flight SLOT frees, not when
a worker is idle (the bound is `min(2 * n_workers, length(ids))`); the
64,000-byte / 100-line captured log tail belongs to the three `processx`
functions and not to the streaming one; with a bare closure `dev_path`
can only name batchit’s OWN source tree; and the `.batchit__<id>` marker
sits in the directory of the item’s lexicographically first declared
output, which is only “beside the outputs” when they share a directory.

No behaviour changed – every edit under `R/` is a `#'` comment. Note
that the release as a whole is not purely documentation: it also adds a
CI step, changes `DESCRIPTION` metadata, and changes the pkgdown site
configuration.

## batchit 26.7.20

**Public API naming migration (v2) complete (`PUBLIC_API.md`).** The
engine and wire protocol are unchanged; the public exports are renamed
to bare, self-documenting names: `run` / `run_and_collect` /
`run_and_write_files_atomically` /
`stream_from_parent_and_write_files_atomically` / `package_function` /
`where_to_write_output`. `batch_fn` is folded into
`run`/`run_and_collect` (the `fn` argument takes a
[`package_function()`](https://papadopoulos-lab.github.io/batchit/reference/package_function.md)
descriptor or a bare closure); the
`batch_record`/`batch_prior`/`batch_skip` consumer-skip mechanism is
removed; and the per-item wire envelope is now a lightweight S3
`batch_envelope` (class + `print` + a worker-check conformance test).
This is a BREAKING rename of every export. See the per-stage entries
below.

## batchit 26.7.19

`runner_package` is now a **required** envelope field, with no consumer
fallback. Previously the worker validated `meta$runner_package` only
when present and, when absent, fell back to the consumer package for
`.batch_execute` — so a malformed envelope could make the *consumer*
namespace supply the runner’s executor, the exact runner/consumer
confusion the extraction seam exists to prevent. The shared
`.batch_check_envelope()` also omitted `runner_package`, so the two
transports accepted an incomplete schema. Now: the worker’s pre-load
structural check treats `runner_package` like `package`/`hash`/`id` (a
non-empty string or die before any code loads), the worker resolves
`.batch_execute` from the runner namespace unconditionally, and
`.batch_check_envelope()` requires `runner_package` too. Regression
tests cover both the checker and a real worker invocation on an envelope
missing the field.

## batchit 26.7.18

Initial release. `batchit` is the one subprocess dispatcher extracted
from `swereg` after Phases 0–3 of the one-dispatcher project (see
swereg’s `PROJECT.md`): the design of a parent/child dispatch contract,
the correctness fixes to every boundary defect, and the routing of every
legacy engine through a single dispatcher, all done inside swereg first.

Public API:

- `package_function(package, symbol, version = NULL)` — a dispatch
  *descriptor*: package + symbol + a srcref-independent
  `digest(list(body, formals))` identity hash. Rejects `...`-taking
  targets. The child re-verifies the hash and refuses a different code
  version than dispatched.
- `batch_run(target, items, n_workers, ...)` — shape A: a fresh
  subprocess per item via `processx`, the memory strategy for
  memory-bound work.
- `batch_stream(target, ids, producer, n_workers, ...)` — shape B: a
  lazy producer with bounded backpressure via `mirai` daemons, for items
  generated on demand.

Both frontends share one contract: both-ends item validation against the
target’s formals (every formal named, including optional ones; no
positional / duplicate / blank names), a structured result envelope
(protocol, id, status, value-or-error, executed-target identity,
captured warnings surfaced in the parent), `collect = FALSE` to drop
values for self-writing targets, per-item timeouts, bounded log tails on
failure, and a total, fail-closed inspector.

The extraction seam (the one non-mechanical change vs. swereg, where
runner and consumer were the same package):

- The worker script is now **always** resolved from the runner package
  (`system.file("batch_worker.R", package = "batchit")`); a consumer’s
  `dev_path` supplies only the consumer’s code, never the worker script.
- The processx worker and the mirai daemon each load **both** the
  consumer (via `dev_path` or `requireNamespace`) and the runner
  (`requireNamespace`), skipping the second load only when runner and
  consumer coincide.
- `meta$runner_package` carries the runner name across the boundary.

Every security property from swereg is preserved: exact `[[` field
extraction, a pre-load structural check of the load-deciding fields
(including a required, non-empty `runner_package` as of 26.7.19),
source-tree-vs-installed `dev_path` discrimination, child-side hash
re-verification, a total `.batch_execute`, and a total result inspector.

`test-batch_seam.R` is new and has no swereg ancestor: it builds and
installs a throwaway consumer package and dispatches through the real
worker and a real mirai daemon with **runner = batchit and consumer =
seamtest**, proving the seam that swereg-inside-swereg could not.

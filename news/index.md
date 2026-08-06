# Changelog

## batchit 26.8.6

**Prose pass against the house standard (ASD-STE100). No claim changed,
no behaviour changed, and no runtime message, warning or error string
changed.** Every edit under `R/` is a `#'` line. The rest is
`vignettes/`, `README.md`, `index.md` and this changelog. Sentences and
paragraphs were split; no section was reordered and no vignette was
restructured.

**The rule the pass enforces is a measured one: at most 25 words in a
description, and at most 20 in an instruction.** batchit is the
reference implementation the rest of the package family is told to copy.
Its prose is therefore the most-read in the family, and a 99-word
sentence is least excusable here.

**Counts before and after, for prose sentences over 25 words.** roxygen2
prose in `R/` went from 115 sentences to 0, and its longest sentence
from 144 words to 25. Vignette prose went from 22 to 0, longest 64 to
25. `NEWS.md` went from 42 to 0, longest 63 to 25. `README.md` went from
3 to 0, longest 38 to 25. `index.md` went from 3 to 0, longest 29 to 20.

The counts come from the sentence measure in the `rw-technical-prose`
skill, extended in three ways. It sees bullets, bold-led lines and HTML
card text. It splits each list item and each roxygen tag block on its
own. And it excludes `@examples` and the other code-bearing roxygen
tags, which would otherwise count example code as prose.

**Eleven long enumerations became lists, because a set of conditions
does not belong inside one prose sentence.** They are:

- the four things outside
  [`package_function()`](https://papadopoulos-lab.github.io/batchit/reference/package_function.md)’s
  code hash;
- the six checks `.batch_inspect_result()` runs, in order;
- the contract `.batch_run_impl()` enforces;
- the two kinds of file `.batch_sweep_task_temps()` sweeps;
- the `.batch_commit_task()` 7-step commit sequence;
- the four pre-replacement failure modes, in
  [`run_and_write_files_atomically()`](https://papadopoulos-lab.github.io/batchit/reference/run_and_write_files_atomically.md)
  and again in the vignette (two lists);
- the three
  [`write_qs2_atomically()`](https://papadopoulos-lab.github.io/batchit/reference/write_qs2_atomically.md)
  non-promises, in the vignette;
- the adhoc lint’s blind spots, in the 26.7.20 entry;
- the shared frontend contract and the preserved security properties,
  both in the 26.7.18 entry (two lists).

Every item carries the same claim its sentence carried.

**RFC-2119 keywords replace a lowercase “must” wherever the text states
an obligation.** That covers the `outputs` path rules on both
file-writing functions, and the name-every-argument rule. It also covers
`.batch_validate_dev_path()`’s three dev-tree conditions, and the
collision check’s “MUST NOT
[`normalizePath()`](https://rdrr.io/r/base/normalizePath.html) a
marker”.

**Two `@return` sections split their lead sentence** so the shape of the
commit record reads as its own statement. The record itself is
unchanged.

`man/` is regenerated with roxygen2 8.0.0, the version `DESCRIPTION`
declares.

## batchit 26.8.3

**Documentation restructure. No behaviour changed, and no runtime
message, warning or error string changed.** The same prose was living in
up to three places at once. Those places were `README.md`, the “Choosing
a dispatch function” vignette, and the `@section Advanced:` blocks of
the help pages. That is three copies to keep true. Each piece now has
one home.

**`index.md` is new, and is what the pkgdown home page now shows.**
pkgdown fills the home body from `index.md` when it exists and from
`README.md` otherwise, so until now the whole README rendered under the
hero band. `index.md` is a short three-card summary, matching the
`index.md` that `swereg` and `mht` already carry. It is
`.Rbuildignore`d, so it does not ship in the tarball.

**`README.md` is cut from about 2,150 words to about 450.** It keeps
what a GitHub visitor needs: what the package is, installation, the
quick start, the which-function-do-I-want table, and links. It hands off
the depth to the vignette, which already covered all of it in more
detail. The inline-`fn` rules, the three-phase atomic-write guarantee,
`dev_path`, thread counts, the marker file and the `mirai` daemon bound
are all in the vignette. One clause was genuinely missing from the
vignette and is added back. That clause has two parts. The in-flight
bound covers produced item arguments only. And `ids`, `outputs` and the
accumulating result list stay resident in the parent session for the
whole call.

**[`write_qs2_atomically()`](https://papadopoulos-lab.github.io/batchit/reference/write_qs2_atomically.md)
is no longer invisible.** It was exported in 26.7.29.1 and then appeared
in no user-facing document: not the README, and not the vignette. Its
help page was the only one with no examples. It is now a row in the
README’s table, a section of the vignette, and has a runnable example.

**Examples are now executed by `R CMD check` instead of being unverified
prose.** Every example used to be wrapped in `\dontrun{}`, so nothing
checked that any of them still worked.
[`package_function()`](https://papadopoulos-lab.github.io/batchit/reference/package_function.md)
and
[`write_qs2_atomically()`](https://papadopoulos-lab.github.io/batchit/reference/write_qs2_atomically.md)
are now plain runnable examples; the four that start real worker
processes moved to `\donttest{}`, which `R CMD check` runs. Only
[`stream_from_parent_and_write_files_atomically()`](https://papadopoulos-lab.github.io/batchit/reference/stream_from_parent_and_write_files_atomically.md)
stays `\dontrun{}`, because it needs `mirai` and a function in an
installed consumer package.

**Cross-links.** The four dispatch functions share an
`@family dispatch functions` tag, so each help page now lists the other
three, and every exported function points at the vignette. Previously
only `batchit-package` had a `\seealso`.

**One `DESCRIPTION` claim was wrong and is corrected.** It said “every
result comes back in a structured envelope carrying the status, the
value or the error, and any captured warnings”. No exported function
returns an envelope; it is the internal parent/worker wire protocol, as
`R/batch.R` says at the point the class is attached. The sentence now
states the user-visible behaviour instead.

**A related trap is now documented rather than implied.** Only a
*completed* item’s warnings are re-raised in the calling session. An
item that warns and then fails builds its error envelope with
`warnings = character()`. The frontends surface warnings only for items
that inspected OK, so those warnings never become R warnings. They
remain in the worker’s captured output, which the three non-streaming
functions print when reporting the failure. The vignette says so under
“When something fails”. It previously left the reader to infer it from
the word “success”.

**The package has a hex logo**, generated by `dev/logo.R` with
`hexSticker`. The motif is item bars across worker lanes. They end
ragged, because a worker takes the next item as soon as it is free. A
local
[`pkgdown::build_site()`](https://pkgdown.r-lib.org/reference/build_site.html)
confirms the template picks `man/figures/logo.png` up on its own: the
built home page carries it in the hero’s `rw-hero-art` column. The
favicons generated from it are committed under `pkgdown/favicon/`, as
`swereg` does, so the site build does not have to regenerate them.

**`R CMD check --as-cran` is clean apart from two expected notes.**
`New submission` (this package is not on CRAN) and the absence of `qpdf`
locally. The URL in `DESCRIPTION` gained its trailing slash, so the
redirect note went away. `pkgdown/`, `dev/`, `index.md` and `Rplots.pdf`
are all `.Rbuildignore`d, so no non-standard top-level file ships.

## batchit 26.7.30

**Documentation pass.** Two user-visible error strings changed; nothing
else about the package’s behaviour did. `README.md`, the “Choosing a
dispatch function” vignette, the exported help pages, the pkgdown hero
and reference descriptions, and this changelog were rewritten in plainer
English. The `DESCRIPTION` title and description were rewritten with
them: the title is now “Run One R Function Across Many Worker
Processes”.

**`PHASE6_DESIGN.md` and `PUBLIC_API.md` are merged into one
`DESIGN.md`.** Both described the work while it was still being planned.
So between them they used function names that no longer exist:
`batch_task`, `batch_fn`, `batch_run`, `batch_stream`, `batch_target`
and `batch_stage_path`. They also specified an opt-in skip mechanism
that was built and then deleted. `DESIGN.md` describes batchit as it is
now, in one document, with the history in its last section. Every
cross-reference in `R/`, `inst/` and `tests/` was repointed at the new
section numbers.

**Three design claims were corrected against the code while merging**,
all of them inherited from the old documents rather than introduced
here. The invocation-wide collision check was documented as checking
hardlink identity; it compares normalized pathname strings only, so two
paths hardlinked to one inode both pass. The per-item marker path was
documented as overridable by a consumer; no such argument exists, and
both file-writing functions derive it unconditionally. A
`staged_writer`’s staged files were documented as verified to be regular
files. The check is exists-and-not-a-directory-and-not-a-symlink. That
is the same limit already recorded for destination paths.

**Two user-visible strings changed.** The self-containedness lint’s
error message used to point at `PHASE6_DESIGN.md`, which the package
never shipped. It now points at the “Choosing a dispatch function”
vignette, which a user can actually open. The
[`where_to_write_output()`](https://papadopoulos-lab.github.io/batchit/reference/where_to_write_output.md)
“no active run” error was reworded. Both still match the existing test
assertions.

## batchit 26.7.29.1

**New export:
[`write_qs2_atomically()`](https://papadopoulos-lab.github.io/batchit/reference/write_qs2_atomically.md).**
A standalone atomic qs2 writer, moved here from swereg’s
`qs2_write_atomic()` with its semantics unchanged. It serializes to a
[`tempfile()`](https://rdrr.io/r/base/tempfile.html) in the
destination’s own directory, then
[`file.rename()`](https://rdrr.io/r/base/files.html)s it into place. So
the destination is either absent or complete, and never truncated. `...`
is forwarded to
[`qs2::qs_save()`](https://rdrr.io/pkg/qs2/man/qs_save.html), the
supplied `path` comes back invisibly, and the partial temp is removed
only when the write failed.

The help page carries the three non-promises verbatim. This is not
durability, because [`file.rename()`](https://rdrr.io/r/base/files.html)
is not an `fsync`. It is not a lock, because two concurrent writers both
produce a complete file and the last rename wins. And it is not
guaranteed cleanup, because
[`on.exit()`](https://rdrr.io/r/base/on.exit.html) cannot run after a
`SIGKILL`, so a hard-killed worker leaves its `.tmp` behind. The
destination is still absent-or-complete. The parent directory must
already exist; this function never creates it.

It is independent of the
[`run_and_write_files_atomically()`](https://papadopoulos-lab.github.io/batchit/reference/run_and_write_files_atomically.md)
commit engine and does not touch it. It does its own
[`file.rename()`](https://rdrr.io/r/base/files.html) rather than call
`.batch_atomic_replace()`. That helper hardcodes the `batch commit:`
error prefix, which a standalone save must not emit. That helper is also
documented as the one place a commit temp becomes final. Its temp is
`<basename(path)>.tmp<random>` and carries no dispatch attempt token, so
`.batch_sweep_task_temps()` can never match it. New tests in
`tests/testthat/test-write_qs2_atomically.R`.

## batchit 26.7.29

**New vignette: “Choosing a dispatch function”**
(`vignettes/choosing-a-dispatch-function.Rmd`). The pkgdown site had a
reference index but no articles. This walks through all four dispatch
functions with worked examples, and states the two questions that pick
between them. It also covers the two `style`s, inline `fn` versus
[`package_function()`](https://papadopoulos-lab.github.io/batchit/reference/package_function.md),
the name-every-argument rule, what the atomic guarantee does and does
not cover, and failure behaviour. No code changes: documentation only.

Chunks are `eval = FALSE` with output shown as `#>` comments. Every
example starts real subprocesses, and the streaming one needs a function
installed in the reader’s own package. To execute them at build time
would be slow, and partly impossible.

`.github/workflows/R-CMD-check.yaml` gains
`r-lib/actions/setup-pandoc@v2`. `R CMD check` builds and re-renders
vignettes. The pkgdown workflow already had this step and this one did
not, because the package shipped no vignette until now. `DESCRIPTION`
gains `VignetteBuilder: knitr` and `knitr` plus `rmarkdown` under
`Suggests`.

**pkgdown site adopts the shared house style.** `_pkgdown.yml` switches
from a bare `template: bootstrap: 5` to
`template: package: pkgdowntemplate`, the same template package swereg
uses. It also adds a `params: hero:` block. That block holds an
overline, a title, a lede, and two calls to action. The two calls to
action point at the new vignette and the reference index. It adds the
shared `authors:` footer and sidebar block too. `DESCRIPTION` gains
`Config/Needs/website: papadopoulos-lab/pkgdowntemplate`, which is how
the pkgdown workflow installs it (`setup-r-dependencies` with
`needs: website`).

batchit ships no logo, unlike swereg. The hero’s art column is
`auto`-width and the template emits it only when a logo exists, so the
band renders text-only with no gap. Adding `man/figures/logo.png` (and
[`pkgdown::build_favicons()`](https://pkgdown.r-lib.org/reference/build_favicons.html))
would populate it later with no config change.

**Correction: the atomic-write guarantee was documented as stronger than
it is.** `README.md` and the
[`run_and_write_files_atomically()`](https://papadopoulos-lab.github.io/batchit/reference/run_and_write_files_atomically.md)
help page both said that on any failure, explicitly including a rename
failure, none of an item’s declared files are replaced. That is false.
`.batch_commit_task()`’s own internal documentation always said so: step
5 replaces finals one at a time and “never rolls back an already-renamed
final. A crash between two output renames leaves a torn state”.

All three copies (vignette, `README.md`, help page) now state the
boundary by phase:

- **before the first replacement**, no declared output is touched. That
  phase covers an error in `fn`, and a `"return"` value whose names do
  not match. It also covers an output a `"staged_writer"` never wrote,
  and a failure serializing a staged file;
- **during the replacement loop**, nothing is transactional. A kill or a
  rename failure can leave the set torn, with no valid marker vouching
  for it. An individual file is still never half-written, rename
  replacement being atomic within a filesystem;
- **after the marker is written**, the files are committed even when the
  call reports failure, because the worker serializes its result
  envelope only after committing.

A `timeout` is explicitly not confined to the first phase. It measures
the worker’s whole lifetime and can land mid-commit, which `R/batch.R`’s
own comment notes for the `mirai` path.

Four smaller documentation claims were wrong the same way and are also
corrected. `producer()` is called when an in-flight slot frees, not when
a worker is idle (the bound is `min(2 * n_workers, length(ids))`). The
64,000-byte and 100-line captured log tail belongs to the three
`processx` functions and not to the streaming one. With a bare closure,
`dev_path` can only name batchit’s own source tree. And the
`.batchit__<id>` marker sits in the directory of the item’s
lexicographically first declared output. That is only “beside the
outputs” when they share a directory.

No behaviour changed. Every edit under `R/` is a `#'` comment. The
release as a whole is not purely documentation. It also adds a CI step,
changes `DESCRIPTION` metadata, and changes the pkgdown site
configuration.

## batchit 26.7.20

**Public API naming migration complete.** The engine and wire protocol
are unchanged. The public exports are renamed to bare, self-documenting
names: `run`, `run_and_collect`, `run_and_write_files_atomically`,
`stream_from_parent_and_write_files_atomically`, `package_function`, and
`where_to_write_output`. `batch_fn` is folded into `run` and
`run_and_collect`, whose `fn` argument now takes either a
[`package_function()`](https://papadopoulos-lab.github.io/batchit/reference/package_function.md)
descriptor or a bare closure. The `batch_record` / `batch_prior` /
`batch_skip` consumer-skip mechanism is removed. The per-item wire
envelope is now a lightweight S3 `batch_envelope` (class, `print`
method, and a worker-check conformance test). This is a breaking rename
of every export. The stages below record how it was done.

**Stage 2: the rename sweep.**
`batch_run(target, items, ..., collect = TRUE/FALSE)` became two
functions with `collect` folded into the name: `run(fn, items, ...)` for
`collect = FALSE` and `run_and_collect(fn, items, ...)` for
`collect = TRUE`, sharing one internal implementation,
`.batch_run_impl()`. `batch_fn()` was retired as a separate export. Both
[`run()`](https://papadopoulos-lab.github.io/batchit/reference/run.md)
and
[`run_and_collect()`](https://papadopoulos-lab.github.io/batchit/reference/run_and_collect.md)
now accept `fn` as either a
[`package_function()`](https://papadopoulos-lab.github.io/batchit/reference/package_function.md)
descriptor or a bare closure, which is the former `batch_fn()`
behaviour. The same self-containedness lint and mandatory
[`baseenv()`](https://rdrr.io/r/base/environment.html) rebase gate it as
before. `batch_task()` was renamed to
[`run_and_write_files_atomically()`](https://papadopoulos-lab.github.io/batchit/reference/run_and_write_files_atomically.md),
a pure name change: its body (styles `"return"` and `"staged_writer"`,
the `target =` deprecated-alias support, the declared-output commit
engine) is unchanged.
[`package_function()`](https://papadopoulos-lab.github.io/batchit/reference/package_function.md)
and
[`where_to_write_output()`](https://papadopoulos-lab.github.io/batchit/reference/where_to_write_output.md),
renamed in stage 1, are unaffected. `batch_record()`, `batch_prior()`
and `batch_skip()` kept their names at this stage. Only their
error-message text changed, to name
[`run_and_write_files_atomically()`](https://papadopoulos-lab.github.io/batchit/reference/run_and_write_files_atomically.md)
instead of `batch_task()`. They are only ever callable from inside one
of its targets.

**Stage 3: the opt-in consumer skip is removed.** `batch_record()`,
`batch_prior()`, `batch_skip()`, the marker’s `details` field, and the
commit record’s `skipped` field are all gone. No consumer ever needed
it, the TTE stages being skip-free by doctrine.
[`run_and_write_files_atomically()`](https://papadopoulos-lab.github.io/batchit/reference/run_and_write_files_atomically.md)’s
commit record returns to `list(committed, attempt)` and the marker
record to `list(protocol, attempt, committed)`. No protocol bump:
`.BATCH_PROTOCOL` stays `2L`, because the skip fields were additive
without a bump, so removing them needs none. Every item is
unconditionally dispatched and every target is always run. Re-add it
only if a real consumer ever needs it.

**Stage 4: the streaming function is rebuilt on the commit engine.** The
former `batch_stream()`, which delivered return values over the mirai
transport, is removed and replaced by a new export,
[`stream_from_parent_and_write_files_atomically()`](https://papadopoulos-lab.github.io/batchit/reference/stream_from_parent_and_write_files_atomically.md).
It keeps `batch_stream()`’s transport verbatim: the private,
nonce-namespaced mirai compute profile, the `everywhere()` package load,
and the lazy-producer loop with `2 * n_workers` backpressure. But it
delivers through the same atomic declared-output commit engine
(`.batch_execute()` then `.batch_commit_task()`) that
[`run_and_write_files_atomically()`](https://papadopoulos-lab.github.io/batchit/reference/run_and_write_files_atomically.md)
uses, instead of returning a raw value. The commit engine is
transport-agnostic and needed no changes on the worker side. `fn` is a
[`package_function()`](https://papadopoulos-lab.github.io/batchit/reference/package_function.md)
descriptor only, with no bare-closure support, unlike
[`run_and_write_files_atomically()`](https://papadopoulos-lab.github.io/batchit/reference/run_and_write_files_atomically.md).
The sole consumer, `save_rawbatch`, uses a package function, so
ad-hoc-over-mirai stays out of scope. Both commit styles work, reusing
[`run_and_write_files_atomically()`](https://papadopoulos-lab.github.io/batchit/reference/run_and_write_files_atomically.md)’s
outputs, marker, collision and attempt-token machinery verbatim
(`.batch_align_outputs_to_ids()`, `.batch_validate_output_map()`,
`.batch_validate_output_paths()`, `.batch_task_marker_path()`,
`.batch_check_task_collisions()`, and `.batch_new_attempt_token()`).
There is no `collect` argument: only a small commit record crosses back,
never a raw value. The retired `batch_stream()` name has no replacement
alias.

**The `adhoc` dispatch kind.** A new `fn_kind = "adhoc"` sits alongside
the existing `fn_kind = "package"`. It dispatches a bare closure by
value, serialized straight into the envelope, instead of resolving a
package and symbol. At the time it landed, the frontend was a new
export,
`batch_fn(fn, items, n_workers, dev_path = NULL, collect = FALSE, ...)`.
That was the ad-hoc return-value sibling of `batch_run()`, and
`batch_task(fn, ...)` also began accepting a bare closure. Stage 2 above
folded `batch_fn()` into
[`run()`](https://papadopoulos-lab.github.io/batchit/reference/run.md)
and
[`run_and_collect()`](https://papadopoulos-lab.github.io/batchit/reference/run_and_collect.md).
The same declared-output commit engine, both styles, and the same marker
doctrine hold for `adhoc` too.

An adhoc closure is gated by a best-effort static self-containedness
lint,
[`codetools::findGlobals()`](https://rdrr.io/pkg/codetools/man/findGlobals.html),
a new Imports dependency. It is applied at both ends: in the frontend at
dispatch time for early feedback, and in `.batch_check_envelope()` again
in the worker for correctness. A worker never simply trusts that an
envelope reaching it went through a frontend’s own check. The closure
may reference only base R, its own declared formals, and explicit
`pkg::fun()` or `pkg:::fun()` calls. Base R here means functions,
operators and constants: anything bound in
[`baseenv()`](https://rdrr.io/r/base/environment.html). Any other free
variable is rejected, and the error names it. `...` in the closure’s
formals is prohibited, exactly as it is for a
[`package_function()`](https://papadopoulos-lab.github.io/batchit/reference/package_function.md)
target, and a primitive or non-function is rejected too. This is a
best-effort static lint, not a proof. It does not detect these blind
spots:

- [`get()`](https://rdrr.io/r/base/get.html),
  [`mget()`](https://rdrr.io/r/base/get.html),
  [`assign()`](https://rdrr.io/r/base/assign.html), and a
  string-argument [`do.call()`](https://rdrr.io/r/base/do.call.html);
- `eval(parse(...))` and
  [`substitute()`](https://rdrr.io/r/base/substitute.html);
- `.GlobalEnv`, and a formula’s or attribute’s own environment;
- `<<-` and S4/R5/R6 dispatch;
- any other ambient state reachable without a syntactically visible free
  variable.

Once accepted, the closure is unconditionally rebased onto
[`baseenv()`](https://rdrr.io/r/base/environment.html) before it is ever
serialized. There is no env-preservation mode. This closes the large or
secret enclosing-environment carriage path the lint itself cannot
detect. Two facts were proven. An un-rebased closure’s original
environment, and everything bound in it, round-trips through the qs2
wire intact. A
[`baseenv()`](https://rdrr.io/r/base/environment.html)-rooted closure
instead reconnects to the receiving session’s own
[`baseenv()`](https://rdrr.io/r/base/environment.html). A closure can
pass the lint and still reach its enclosing environment indirectly, for
example with `get("x", envir = environment())`. Such a closure still
fails at run time in a real worker subprocess.

An adhoc envelope carries no package, symbol or hash identity. So a
result is bound instead to the id, already checked, plus a fresh
high-entropy per-dispatch nonce. The parent issues that nonce, and the
worker echoes it back in the result’s `target` field as
`list(fn_kind = "adhoc", nonce = <nonce>)`. `.batch_inspect_result()`
branches on `fn_kind` through its new `expected_nonce` argument. It
rejects a result claiming the wrong id or the wrong nonce, exactly as a
wrong package, symbol or hash is rejected for `fn_kind = "package"`.

`dev_path` for an adhoc dispatch has no consumer package to validate
against, so it names batchit’s own source tree instead. That is what
lets batchit’s own adhoc test suite run against source without a
reinstall, mirroring the existing package-kind “runner equals consumer”
self-test path. `NULL`, the default, uses the installed `batchit`, which
is what any downstream caller wants. A closure’s own `pkg::fun()` calls
are unaffected either way, resolving through ordinary lazy namespace
loading in the worker.

**`style = "staged_writer"`.** A `staged_writer` target does not return
a named list. It writes each declared output to
`where_to_write_output(<name>)` instead. That exported accessor returns
the exact attempt-scoped staging path batchit pre-computed for that
output, in the same directory as its final destination. The target’s
return value is unconditionally ignored, with no return-name-match check
for this style. Commit step 1 becomes an assertion rather than a write.
Every declared name must exist at its staging path as a regular
non-symlink file once the target returns. Otherwise the item fails
loudly, with zero renames. Steps 2 through 7 (marker prepare, temp
verification, old-marker removal, output renames, marker rename last,
and read-back verification) are identical between the two styles.
[`where_to_write_output()`](https://papadopoulos-lab.github.io/batchit/reference/where_to_write_output.md)
errors clearly when called outside an active `staged_writer` run, or for
a name that is not one of the item’s declared outputs. The parent-side
failure sweep, `.batch_sweep_task_temps()`, is used on a timeout or
SIGKILL. It now matches both `.<attempt>.tmp` (the marker and
`return`-style output temps) and `.<attempt>.stage` (`staged_writer`
staging files). It is still keyed on the unique per-dispatch attempt
token, so an unrelated pre-existing file is never swept.

**The declared-output commit engine itself.** It landed as
`batch_task()`, alongside the return-value `batch_run()` and
`batch_stream()`, and was renamed to
[`run_and_write_files_atomically()`](https://papadopoulos-lab.github.io/batchit/reference/run_and_write_files_atomically.md)
in stage 2 above. It runs a package target once per item, on the same
one-`processx`-subprocess-per-item transport as `batch_run()`. It does
not return a value. It commits the value to `outputs[[i]]`, a declared
name to final-path map, through an all-or-nothing 7-step rename sequence
run in the worker. A per-item marker file, `.batchit__<item id>`, is the
atomic witness of a complete commit. Only a valid engine-produced marker
is: one that decodes and whose protocol, attempt token and committed
output map all verify. Bare pathname existence at that path is not, so a
target that errors before the old marker is removed leaves an unrelated
pre-existing marker untouched. There is no `collect` argument, the whole
point being that raw values never cross back to the parent. Only a small
commit record does,
`list(committed = <name -> path>, attempt = <token>)`.

The doctrine it enforces: no batchit dispatch decision may ever depend
on a marker’s existence or contents. The parent-side code validates only
a marker’s pathname and parent directory, and never reads or stats it.
Only the worker, while committing, ever touches one. A source-level
lockdown test guards this statically.

The wire protocol bumped, `.BATCH_PROTOCOL` 1 to 2: the envelope gained
a required `meta$fn_kind` discriminator plus the declared-output commit
fields (`outputs`, `marker`, `style`, `attempt`). An old-protocol
envelope is rejected, and the worker now verifies the protocol before
loading any consumer package, having always loaded the runner first.
`.batch_check_envelope()` also rejects any unknown `meta` field, closing
the gap where a typo’d field was silently ignored.

Adversarial review of the commit engine hardened four things. The
worker’s `.batch_check_envelope()` now re-validates output and marker
path shape: already-normalized, absolute, and parent directory exists.
It also rejects an unsupported `style` before the target ever runs,
rather than trust the parent’s checks alone. Previously a side-effecting
target could execute for an envelope whose style would fail anyway. The
top-level envelope now rejects unknown fields, matching the existing
`meta` field lockdown. A commit result’s value must have exactly the
fields `committed` and `attempt`, so no extra field can smuggle raw data
back to the parent. And the parent now sweeps a failed or killed item’s
own batchit-generated commit temps on any item failure. It matches them
by the item’s unique attempt-scoped token,
`<basename>.<attempt>.tmp<random>`. It finds them with
`list.files(all.files = TRUE)`, so the dotfile marker temp is included.
An unrelated file is never over-deleted. This closes a temp leak when
`kill_tree()` or a SIGKILL reaches the worker before its own `on.exit`
cleanup can run. Item ids containing `/` or `\` are now rejected, since
they are interpolated into the per-item marker filename.

## batchit 26.7.19

`runner_package` is now a **required** envelope field, with no consumer
fallback. Previously the worker validated `meta$runner_package` only
when present and, when absent, fell back to the consumer package for
`.batch_execute`. So a malformed envelope could make the *consumer*
namespace supply the runner’s executor, the exact runner and consumer
confusion the extraction seam exists to prevent. The shared
`.batch_check_envelope()` also omitted `runner_package`, so the two
transports accepted an incomplete schema. Now the worker’s pre-load
structural check treats `runner_package` like `package`, `hash` and
`id`: a non-empty string or die before any code loads. The worker
resolves `.batch_execute` from the runner namespace unconditionally, and
`.batch_check_envelope()` requires `runner_package` too. Regression
tests cover both the checker and a real worker invocation on an envelope
missing the field.

## batchit 26.7.18

Initial release. `batchit` is the one subprocess dispatcher extracted
from `swereg` after phases 0 to 3 of the one-dispatcher project (see
swereg’s `PROJECT.md`). Those phases were the design of a parent/child
dispatch contract, and the correctness fixes to every boundary defect.
They also routed every legacy engine through a single dispatcher. All of
that was done inside swereg first.

Public API:

- `package_function(package, symbol, version = NULL)` is a dispatch
  *descriptor*: package plus symbol plus a srcref-independent
  `digest(list(body, formals))` identity hash. It rejects `...`-taking
  targets. The worker re-verifies the hash and refuses a different code
  version than the one dispatched.
- `batch_run(target, items, n_workers, ...)` starts a fresh subprocess
  per item via `processx`, which is the memory strategy for memory-bound
  work.
- `batch_stream(target, ids, producer, n_workers, ...)` runs a lazy
  producer with bounded backpressure via `mirai` daemons, for items
  generated on demand.

Both frontends share one contract:

- both-ends item validation against the target’s formals: every formal
  named, including optional ones, and no positional, duplicate or blank
  names;
- a structured result envelope carrying the protocol, id, status, value
  or error, executed-target identity, and captured warnings surfaced in
  the parent;
- `collect = FALSE` to drop values for self-writing targets;
- per-item timeouts;
- bounded log tails on failure;
- a total fail-closed inspector.

The extraction seam is the one non-mechanical change against swereg,
where runner and consumer were the same package:

- The worker script is now **always** resolved from the runner package
  (`system.file("batch_worker.R", package = "batchit")`). A consumer’s
  `dev_path` supplies only the consumer’s code, never the worker script.
- The processx worker and the mirai daemon each load **both** the
  consumer (via `dev_path` or `requireNamespace`) and the runner
  (`requireNamespace`). They skip the second load only when runner and
  consumer coincide.
- `meta$runner_package` carries the runner name across the boundary.

Every security property from swereg is preserved:

- exact `[[` field extraction;
- a pre-load structural check of the load-deciding fields, including a
  required, non-empty `runner_package` as of 26.7.19;
- source-tree-versus-installed `dev_path` discrimination;
- worker-side hash re-verification;
- a total `.batch_execute`;
- a total result inspector.

`test-batch_seam.R` is new and has no swereg ancestor. It builds and
installs a throwaway consumer package. It then dispatches through the
real worker and a real mirai daemon with **runner = batchit and consumer
= seamtest**. That proves the seam that swereg-inside-swereg could not.

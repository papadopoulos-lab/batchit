# Internal fixtures for exercising the dispatcher through a REAL subprocess and a
# REAL mirai daemon. A dispatch target is a descriptor (package + symbol), never
# a closure -- deliberately, so it can be hash-verified across sessions -- which
# means a fixture defined inside a test is unreachable in the worker's freshly
# loaded namespace. Targets must therefore be package-resolvable, so the fixtures
# live HERE, in the package, @noRd, and are used only by
# tests/testthat/test-batch_*.R. (The runner!=consumer boundary that these
# same-package fixtures cannot exercise is proven separately in
# test-batch_seam.R, which builds a throwaway consumer package.)

#' @noRd
.batch_fixture_echo <- function(x) x

#' @noRd
.batch_fixture_boom <- function(message) stop(message, call. = FALSE)

#' @noRd
.batch_fixture_sleep <- function(seconds) {
  Sys.sleep(seconds)
  TRUE
}

# Sleeps, then echoes x. Lets a test force a specific COMPLETION order across
# workers -- e.g. make the NULL-returning item finish last, after a
# higher-indexed item has already filled its slot, which is the only order that
# exposes the results[[idx]] <- NULL deletion bug.
#' @noRd
.batch_fixture_slow_echo <- function(x, seconds) {
  Sys.sleep(seconds)
  x
}

#' @noRd
.batch_fixture_pid <- function() Sys.getpid()

# Terminates the worker HARD (no error condition, no result envelope), so the
# parent must fall back to its exit-code channel -- distinct from
# .batch_fixture_boom(), which raises a catchable error and returns a structured
# error envelope with exit status 0.
#' @noRd
.batch_fixture_crash <- function() quit(save = "no", status = 3L)

# Emits a warning and still returns a value (status "ok"), as a target does when
# a sub-computation fails but a partial result is still useful: the runner must
# carry that warning back to the parent, not lose it.
#' @noRd
.batch_fixture_warn <- function(x) {
  warning("fixture warning about ", x)
  x
}

# Returns a large object. Used to check that collect = FALSE drops the value
# before it is ever put into the result envelope (the shape-A memory guarantee).
#' @noRd
.batch_fixture_big <- function(n) {
  rep_len(42.0, n)
}

# Writes ~n_kb KB to EACH of stdout and stderr. Exercises the deadlock class that
# killed the originating pipeline's pipe transport: a child out-writing the OS
# pipe buffer (64 KB on Linux) blocks forever in write() if the parent only reads
# after exit. run()/run_and_collect()'s file-backed logs must swallow this without blocking.
#' @noRd
.batch_fixture_chatty <- function(n_kb) {
  line <- paste(rep("x", 1023L), collapse = "")
  for (i in seq_len(n_kb)) {
    cat(line, "\n", sep = "", file = stdout())
    cat(line, "\n", sep = "", file = stderr())
  }
  invisible(NULL)
}

# --- Phase 6' Unit 1 fixtures: declared-output commit (run_and_write_files_atomically()) --------
# Targets for the return-style commit engine: a target's return must be a
# named list whose names are EXACTLY the declared outputs (see
# .batch_commit_task(), in the commit-engine source file). These fixtures exercise the
# well-formed case and every documented failure shape.

# Returns exactly two named values -- the well-formed case (declared outputs
# "primary"/"secondary").
#' @noRd
.batch_fixture_task_ok <- function(x) {
  list(primary = x, secondary = x * 10)
}

# Missing a declared name ("secondary" never returned).
#' @noRd
.batch_fixture_task_missing_name <- function(x) {
  list(primary = x)
}

# An UNDECLARED extra name alongside the two declared ones.
#' @noRd
.batch_fixture_task_extra_name <- function(x) {
  list(primary = x, secondary = x * 10, surprise = "unexpected")
}

# Errors before returning anything -- no output could ever have been prepared.
#' @noRd
.batch_fixture_task_boom <- function(x) {
  stop("task target detonated: ", x, call. = FALSE)
}

# Returns an empty list -- "exit 0, wrote nothing": shorter than every declared
# output, the same shape as .batch_fixture_task_missing_name() but for BOTH
# declared names at once.
#' @noRd
.batch_fixture_task_empty <- function(x) {
  list()
}

# Sleeps `seconds` (well past any short test timeout), THEN returns the
# well-formed declared-outputs shape -- lets a test force a real timeout
# kill_tree() (via a short `timeout`) that lands during do.call(), i.e.
# BEFORE .batch_commit_task() ever starts, exercising
# run_and_write_files_atomically()'s timeout/SIGKILL failure path against a REAL subprocess.
#' @noRd
.batch_fixture_task_slow <- function(x, seconds) {
  Sys.sleep(seconds)
  list(primary = x, secondary = x * 10)
}

# Writes a file at `path` as a SIDE EFFECT, then returns. Exists purely to
# make "did the target actually run?" observable from OUTSIDE the subprocess:
# a real file appearing at `path` is unambiguous proof do.call() executed it,
# used to prove a target does NOT run when the worker rejects its envelope
# (e.g. an unsupported commit `style`) before do.call() -- see
# .batch_check_envelope()'s style enforcement.
#' @noRd
.batch_fixture_side_effect_writer <- function(path) {
  writeLines("ran", path)
  list(a = "ran")
}

# --- Phase 6' Unit 2 fixtures: declared-output commit, staged_writer style --
# A staged_writer target WRITES each declared output via where_to_write_output()
# instead of returning it -- its return value is unconditionally IGNORED by
# the commit engine (see .batch_commit_task(), style == "staged_writer"
# branch). These mirror the "return"-style fixtures above (well-formed,
# missing an output, and the where_to_write_output() undeclared-name error).

# Streams both declared outputs ("primary"/"secondary") via
# where_to_write_output(); the return value is deliberately something that would
# FAIL the return-style name-match check (neither "primary" nor "secondary")
# -- proving staged_writer really does ignore it rather than happening to
# pass by coincidence.
#' @noRd
.batch_fixture_task_staged_ok <- function(x) {
  qs2::qs_save(x, where_to_write_output("primary"))
  qs2::qs_save(x * 10, where_to_write_output("secondary"))
  list(this_return_value_is_ignored_by_staged_writer = TRUE)
}

# Writes only ONE of the two declared outputs -- "forgets" secondary.
#' @noRd
.batch_fixture_task_staged_missing <- function(x) {
  qs2::qs_save(x, where_to_write_output("primary"))
  invisible(NULL)
}

# Calls where_to_write_output() with a name that is NOT one of this item's
# declared outputs -- exercises the accessor's own undeclared-name error,
# through the real worker.
#' @noRd
.batch_fixture_task_staged_bad_name <- function(x) {
  where_to_write_output("no_such_declared_output")
  invisible(NULL)
}

# Sleeps `seconds` (well past any short test timeout), THEN streams both
# declared outputs -- lets a test force a real timeout kill_tree() that lands
# during do.call(), i.e. before any output is actually staged, exercising
# run_and_write_files_atomically()'s timeout/SIGKILL sweep for staged_writer's OWN temp shape
# (`.stage`, not `.tmp`).
#' @noRd
.batch_fixture_task_staged_slow <- function(x, seconds) {
  Sys.sleep(seconds)
  qs2::qs_save(x, where_to_write_output("primary"))
  qs2::qs_save(x * 10, where_to_write_output("secondary"))
  invisible(NULL)
}

# Writes ONE stage file, then errors BEFORE .batch_commit_task() is reached --
# exercises the .batch_execute() frame's own on.exit(unlink(stage_map)) cleanup
# of a worker-created partial stage (the child never reaches the commit).
#' @noRd
.batch_fixture_task_staged_partial_boom <- function(x) {
  qs2::qs_save(x, where_to_write_output("primary"))
  stop("staged target detonated after writing one stage")
}

# slurm_write(): the description becomes executable shell
#
# Everything above validates. This part writes. It produces one bash file for
# each job, plus `submit.sh`, and it submits nothing.
#
# The split between the two kinds of file is the invariant. A job file runs
# under Slurm and knows nothing about the chain. `submit.sh` holds the chain,
# and it is the only generated file that names the submission command. So a
# reader who wants to know what reaches the scheduler reads one file.
#
# Four items reach every job file, and no argument controls them. The output
# and error paths. A start timestamp. Peak memory. An end timestamp with the
# exit code, from an EXIT trap.
#
# The trap captures `$?` in its first statement. A statement before that one
# overwrites the status the body exited with, and the job then reports the
# status of the trap's own housekeeping instead.

# The driver's own name. A job may not take it. Both files land in one
# directory as `<name>.sh`, so the job would overwrite the driver.
.SLURM_WRITE_DRIVER_NAME <- "submit"

# The name of the file `slurm_write()` writes the driver into.
#
# `.SLURM_SUBMIT_DRIVER_FILE` lives here, not in R/slurm_submit.R. R sources
# package files in alphabetical order, and this line runs at source time. It
# MUST stay in the same file as `.SLURM_WRITE_DRIVER_NAME`, below it.
.SLURM_SUBMIT_DRIVER_FILE <- paste0(.SLURM_WRITE_DRIVER_NAME, ".sh")

#' Name the `Rscript` the version gate runs.
#'
#' `R.home("bin")` names the R that writes the chain. A bare `Rscript` names
#' whichever one comes first on the node's `PATH`.
#'
#' `R CMD check` makes that difference visible. `tools:::add_dummies()` puts a
#' directory first on `PATH`. The directory holds an `Rscript` that prints a
#' complaint and exits 1. That enforces Writing R Extensions section 1.6.
#'
#' The option `batchit.rscript_path` overrides the default. Set it where the
#' compute node keeps R somewhere other than the machine that writes the chain.
#'
#' @return Character(1). An absolute path.
#' @noRd
.slurm_write_rscript_path <- function() {
  path <- getOption(
    "batchit.rscript_path",
    file.path(R.home("bin"), "Rscript")
  )
  .slurm_write_assert_string(path, "batchit.rscript_path")
  .slurm_it_assert_one_line(path, "batchit.rscript_path")
  return(path)
}

# --- validation helpers ------------------------------------------------------

#' Stop with the house prefix.
#' @param ... Message parts, pasted with no separator.
#' @return Never returns.
#' @noRd
.slurm_write_stop <- function(...) {
  stop("slurm_write(): ", ..., call. = FALSE)
}

#' Stop unless a value is one string that carries a character.
#' @param x The value.
#' @param field Character(1), the field name the message reports.
#' @return `invisible(x)`.
#' @noRd
.slurm_write_assert_string <- function(x, field) {
  ok <- is.character(x) && length(x) == 1L && !is.na(x)
  if (!ok) {
    .slurm_write_stop(
      "`",
      field,
      "` MUST be one non-NA string. Got: ",
      .slurm_it_show(x)
    )
  }
  if (!grepl("[^[:space:]]", x)) {
    .slurm_write_stop(
      "`",
      field,
      "` MUST hold at least one character that is not whitespace."
    )
  }
  return(invisible(x))
}

#' Stop when a directory path would break a `#SBATCH` directive.
#'
#' The path reaches `#SBATCH --output=` and `#SBATCH --error=`. A directive
#' ends at the first whitespace character, so Slurm reads the rest as a
#' separate token and the job writes its log somewhere else.
#'
#' @param x Character(1).
#' @param what Character(1), how the message names the path.
#' @return `invisible(x)`.
#' @noRd
.slurm_write_assert_no_whitespace <- function(x, what) {
  if (grepl("[[:space:]]", x)) {
    .slurm_write_stop(
      what,
      " holds a whitespace character, and it MUST hold none: ",
      .slurm_it_show(x),
      ". It reaches `#SBATCH --output=`, and a directive ends at the first ",
      "whitespace character."
    )
  }
  return(invisible(x))
}

#' Normalise the first argument to a list of jobs, and check the set.
#'
#' A single object is a chain of one. The two checks here are about the set of
#' jobs. `slurm_it()` sees one job, so it can make neither. A name is a file
#' name, and two jobs under one name write one file.
#'
#' @param x One `slurm_it` object, or a list of them.
#' @return A list of `slurm_it` objects.
#' @noRd
.slurm_write_jobs <- function(x) {
  jobs <- if (inherits(x, "slurm_it")) list(x) else x
  if (!is.list(jobs) || length(jobs) == 0L) {
    .slurm_write_stop(
      "`x` MUST be one slurm_it object, or a list of them. A chain holds at ",
      "least one job. Got: ",
      paste(class(x), collapse = "/"),
      "[",
      length(x),
      "]"
    )
  }
  for (i in seq_along(jobs)) {
    if (!inherits(jobs[[i]], "slurm_it")) {
      .slurm_write_stop(
        "`x[[",
        i,
        "]]` MUST be a slurm_it object. Got: ",
        paste(class(jobs[[i]]), collapse = "/")
      )
    }
  }
  used <- vapply(jobs, function(job) job[["name"]], character(1))
  if (anyDuplicated(used) > 0L) {
    .slurm_write_stop(
      "every job MUST take its own `name`, because the name is the file ",
      "name. Two jobs under one name write one file. Repeated: ",
      .slurm_it_show(unique(used[duplicated(used)]))
    )
  }
  if (.SLURM_WRITE_DRIVER_NAME %in% used) {
    .slurm_write_stop(
      "a job MUST NOT take the name `",
      .SLURM_WRITE_DRIVER_NAME,
      "`. The driver writes `",
      .SLURM_WRITE_DRIVER_NAME,
      ".sh` in the same directory, and the job would overwrite it."
    )
  }
  return(jobs)
}

# --- the generated text ------------------------------------------------------

#' Build the version gate for one job.
#'
#' The gate runs before the job body, so a refusal stops the job with nothing
#' done. A job that ran under the wrong package version costs more than a job
#' that did not run: its output looks complete.
#'
#' Each package name and each version reaches a single-quoted shell word.
#' `slurm_it()` accepts letters, digits, periods and hyphens in these two
#' fields and nothing else, so neither can close that quote.
#'
#' The gate runs the interpreter under `env -u R_TESTS`. R reads `R_TESTS` at
#' startup and sources the name it holds. It resolves that name against the
#' subprocess's own working directory, which is rarely the directory holding
#' the file. The subprocess then dies before it reports a version.
#'
#' @param require_r_package Named character vector of package versions.
#' @return Character vector of shell lines. Empty when the job names no
#'   package.
#' @noRd
.slurm_write_version_gate_lines <- function(require_r_package) {
  if (length(require_r_package) == 0L) {
    return(character(0))
  }
  rscript <- shQuote(.slurm_write_rscript_path(), type = "sh")
  lines <- c(
    "# The version gate. A refusal here stops the job before the body runs.",
    ""
  )
  for (i in seq_along(require_r_package)) {
    pkg <- names(require_r_package)[i]
    ver <- require_r_package[[i]]
    lines <- c(
      lines,
      paste0(
        "if ! env -u R_TESTS ",
        rscript,
        " -e 'stopifnot(utils::packageVersion(\"",
        pkg,
        "\") == package_version(\"",
        ver,
        "\"))'; then"
      ),
      paste0(
        "  printf 'batchit: R package ",
        pkg,
        " is not at version ",
        ver,
        ". Refusing to run the job body.\\n' >&2"
      ),
      "  exit 1",
      "fi",
      ""
    )
  }
  return(lines)
}

#' Build the shell lines that record peak memory.
#'
#' The job reads the cgroup v2 counter of its own cgroup. It derives that path
#' at run time from `/proc/self/cgroup`, because the root counter
#' `/sys/fs/cgroup/memory.peak` is not readable inside a Slurm job.
#'
#' A job that cannot read a counter prints `batchit_peak_memory_unavailable`
#' and reports no number. There is no fallback to `VmHWM`, which measures the
#' job's own shell. A job that runs its work in a child process then reports a
#' few thousand kilobytes for work that held gigabytes. That wrong number
#' prints under the same heading a right one uses.
#'
#' `awk` exits 2 when `/proc/self/cgroup` is absent. The job runs under
#' `set -e`, so `|| true` is what stops that from killing the job before its
#' body runs.
#'
#' @param memory_peak_path Character(1), an explicit counter from the option
#'   `batchit.memory_peak_path`, or NULL to derive the path.
#' @return Character vector of shell lines.
#' @noRd
.slurm_write_memory_peak_lines <- function(memory_peak_path) {
  if (is.null(memory_peak_path)) {
    assign_path <- c(
      "# The counter of this job's own cgroup. The root counter",
      "# /sys/fs/cgroup/memory.peak is not readable inside a Slurm job.",
      paste0(
        "batchit_cgroup=$(awk -F: '$1 == \"0\" { print $3 }' ",
        "/proc/self/cgroup 2>/dev/null || true)"
      ),
      "if [ -n \"$batchit_cgroup\" ]; then",
      "  batchit_memory_peak_path=\"/sys/fs/cgroup${batchit_cgroup}/memory.peak\"",
      "else",
      "  batchit_memory_peak_path=\"\"",
      "fi"
    )
  } else {
    assign_path <- paste0(
      "batchit_memory_peak_path=",
      shQuote(memory_peak_path, type = "sh")
    )
  }
  return(c(
    assign_path,
    "",
    "batchit_record_peak_memory() {",
    "  if [ -r \"$batchit_memory_peak_path\" ]; then",
    "    printf 'batchit_memory_peak_bytes %s\\n' \\",
    "      \"$(cat -- \"$batchit_memory_peak_path\")\"",
    "  else",
    "    printf 'batchit_peak_memory_unavailable\\n'",
    "  fi",
    "}"
  ))
}

#' Build the text of one job file.
#'
#' `exclusive = FALSE` emits no line at all, which is the whole of the false
#' case. Slurm has no negative form of that option, so the absence of the
#' directive is what asks for a shared node.
#'
#' @param job One `slurm_it` object.
#' @param dir Character(1), the absolute directory the chain writes into.
#' @param memory_peak_path Character(1) or NULL, as
#'   `.slurm_write_memory_peak_lines()` takes it.
#' @return Character vector of shell lines.
#' @noRd
.slurm_write_job_text <- function(job, dir, memory_peak_path) {
  name <- job[["name"]]
  extra <- job[["sbatch"]]
  header <- c(
    "#!/bin/bash",
    paste0("#SBATCH --job-name=", name),
    paste0("#SBATCH --cpus-per-task=", job[["cpus"]]),
    paste0("#SBATCH --mem=", job[["mem"]]),
    paste0("#SBATCH --time=", job[["time"]]),
    paste0("#SBATCH --output=", dir, "/", name, "_%j.out"),
    paste0("#SBATCH --error=", dir, "/", name, "_%j.err"),
    if (job[["requeue"]]) "#SBATCH --requeue" else "#SBATCH --no-requeue",
    if (job[["exclusive"]]) "#SBATCH --exclusive" else character(0),
    if (length(extra) > 0L) {
      paste0("#SBATCH --", names(extra), "=", extra)
    } else {
      character(0)
    }
  )
  preamble <- c(
    "",
    "# Written by batchit::slurm_write(). An edit here is lost the next time",
    "# the chain is written.",
    "#",
    "# The body stops at its first failing command, which is what a chain",
    "# built on --dependency=afterok needs.",
    "set -euo pipefail",
    "",
    "printf 'batchit_start %s\\n' \"$(date -Iseconds)\"",
    "",
    .slurm_write_memory_peak_lines(memory_peak_path),
    "",
    "batchit_on_exit() {",
    "  batchit_status=$?",
    "  set +e",
    "  printf 'batchit_end %s\\n' \"$(date -Iseconds)\"",
    "  batchit_record_peak_memory",
    "  printf 'batchit_exit_code %s\\n' \"$batchit_status\"",
    "  exit \"$batchit_status\"",
    "}",
    "trap batchit_on_exit EXIT",
    ""
  )
  gate <- .slurm_write_version_gate_lines(job[["require_r_package"]])
  body <- c(
    "# The job body, as the caller wrote it.",
    strsplit(job[["script"]], "\n", fixed = TRUE)[[1]],
    ""
  )
  return(c(header, preamble, gate, body))
}

#' Build the chain tokens for one position in the chain.
#'
#' Position 1 waits for nothing. Every later job waits for the one before it
#' to succeed. `--kill-on-invalid-dep=yes` is what removes a job whose
#' dependency failed, rather than leaving it queued forever.
#'
#' @param i Integer(1), the position in the chain.
#' @return Character vector of `sbatch` tokens. Empty at position 1.
#' @noRd
.slurm_write_dependency_tokens <- function(i) {
  if (i <= 1L) {
    return(character(0))
  }
  return(c(
    paste0("--dependency=afterok:\"$batchit_jid_", i - 1L, "\""),
    "--kill-on-invalid-dep=yes"
  ))
}

#' Build the text of the driver.
#'
#' The driver carries the preflight, then one `sbatch` call for each job.
#'
#' `--parsable` prints the job id alone on most clusters. On a federated
#' cluster it prints `jobid;cluster`, and the whole of that string reaching
#' `afterok:` is a dependency Slurm never satisfies. `cut -d';' -f1` takes the
#' id on both.
#'
#' @param jobs List of `slurm_it` objects, in chain order.
#' @param dir Character(1), the absolute directory the chain writes into.
#' @return Character vector of shell lines.
#' @noRd
.slurm_write_driver_text <- function(jobs, dir) {
  lines <- c(
    "#!/bin/bash",
    "#",
    "# Written by batchit::slurm_write(). An edit here is lost the next time",
    "# the chain is written.",
    "#",
    "# This is the only generated file that names the submission command.",
    "set -euo pipefail",
    "",
    paste0("batchit_dir=", shQuote(dir, type = "sh")),
    "",
    .slurm_write_preflight_lines(jobs)
  )
  for (i in seq_along(jobs)) {
    name <- jobs[[i]][["name"]]
    tokens <- c("--parsable", .slurm_write_dependency_tokens(i))
    lines <- c(
      lines,
      paste0(
        "batchit_jid_",
        i,
        "=\"$(sbatch ",
        paste(tokens, collapse = " "),
        " \"$batchit_dir/",
        name,
        ".sh\" | cut -d';' -f1)\""
      ),
      paste0(
        "printf 'batchit_submitted %s %s\\n' '",
        name,
        "' \"$batchit_jid_",
        i,
        "\""
      ),
      ""
    )
  }
  return(lines)
}

# --- the writer --------------------------------------------------------------

#' Write a Slurm job chain
#'
#' Writes one bash file for each job, plus `submit.sh`. It submits nothing.
#'
#' `slurm_write()` owns `dir`. It deletes every `*.sh` file there before it
#' writes. The caller regenerates the chain on every run. So a chain of four
#' written over a chain of five MUST NOT leave the fifth job file behind. The
#' new `submit.sh` does not name that file, and it still runs by hand.
#'
#' `submit.sh` is the only generated file that names the submission command.
#' A job file runs under Slurm and knows nothing about the chain.
#'
#' @section What every job file carries:
#' Four items reach every job file, and no argument controls them.
#'
#' 1. The output and error paths, under `dir`.
#' 2. A start timestamp, before the job body.
#' 3. Peak memory, read on exit.
#' 4. An end timestamp and the exit code, from an `EXIT` trap.
#'
#' Item 3 reads the cgroup v2 counter of the job's own cgroup. The job derives
#' that path at run time from `/proc/self/cgroup`. The root counter
#' `/sys/fs/cgroup/memory.peak` is not readable inside a Slurm job.
#'
#' A job that cannot read its counter prints `batchit_peak_memory_unavailable`.
#' It reports no number. batchit reads no second counter. `VmHWM` from
#' `/proc/self/status` measures the job's own shell. It read 4,744 kB against a
#' payload that held 2,000,000,000 bytes in a child R process.
#'
#' The option `batchit.memory_peak_path` names an explicit counter and turns
#' the derivation off. Set it where the cluster keeps the counter somewhere
#' else.
#'
#' The trap captures the exit status in its first statement. So the job
#' reports the status its body exited with, and not the status of the trap's
#' own work.
#'
#' A job file runs under `set -euo pipefail`. The body stops at its first
#' failing command, which is what a chain built on `--dependency=afterok`
#' needs.
#'
#' @section The version gate and its interpreter:
#' A job that names `require_r_package` carries a version gate before its body.
#' The gate MUST NOT depend on the environment that starts the job. So it runs
#' the interpreter under `env -u R_TESTS`. It also names that interpreter by an
#' absolute path.
#'
#' The path defaults to `file.path(R.home("bin"), "Rscript")`, which is the R
#' that writes the chain. Set the option `batchit.rscript_path` where the
#' compute node keeps R somewhere else. A bare `Rscript` would name whichever
#' one comes first on the node's `PATH`. A gate that cannot say which R it
#' asked proves nothing about a version.
#'
#' `R CMD check` exports `R_TESTS`, and every subprocess inherits it. So this
#' matters to a package that tests a generated job under `R CMD check`. A
#' production Slurm job carries no `R_TESTS`, so the unset costs nothing there.
#'
#' @section What `submit.sh` checks before it submits:
#' `submit.sh` runs two checks. A refusal writes `batchit: REFUSED:` to
#' standard error, exits 1, and submits nothing.
#'
#' 1. EVERY state `sinfo` reports for the node MUST be `idle`, `mixed` or
#'    `allocated`. The driver names the node with `hostname -s`. It deletes
#'    the trailing `*` that marks a node slurmctld cannot reach. It joins with
#'    commas the several lines that a node in more than one partition emits,
#'    then tests each one. A node drained in one partition and idle in another
#'    reports `drained,idle`, and it cannot run the job.
#' 2. A job name in the chain MUST NOT already appear in `squeue`. This check
#'    fails closed. A `squeue` that exits non-zero refuses the submission,
#'    because it leaves a duplicate possible.
#'
#' The node check reads the node the driver itself runs on. Run `submit.sh` on
#' a login node, and `hostname -s` names that login node.
#'
#' @section What the tests of `submit.sh` do not prove:
#' The tests drive the generated `submit.sh` with stub `hostname`, `sinfo`,
#' `squeue` and `sbatch` programs on `PATH`. So they prove the shell branching
#' against a protocol the tests wrote. Four things stay unproven.
#'
#' 1. The argument spelling that the real `sinfo` and `squeue` accept.
#' 2. The output grammar that the real `sinfo` and `squeue` produce.
#' 3. Which users' jobs `squeue` reports. The check reads every job the caller
#'    can see, and no option scopes it to one user.
#' 4. That two `submit.sh` runs started at the same time cannot both pass.
#'    Each one reads `squeue` before either one submits.
#'
#' @param x One `slurm_it` object, or a list of them. List position is chain
#'   order: job `i` waits for job `i - 1` to succeed. Every job MUST take its
#'   own `name`, and no job may take the name `submit`.
#' @param dir Character(1). The directory to write into. `slurm_write()`
#'   creates it when it is absent, and it owns every `*.sh` file in it. The
#'   path MUST hold no whitespace character, because it reaches
#'   `#SBATCH --output=`.
#' @return Character vector of the paths written, invisibly. The job paths
#'   come first, in chain order, and the `submit.sh` path comes last. Every
#'   path is mode 0755.
#' @family slurm
#' @seealso `vignette("batchit")`, section "Slurm: write a chain of
#'   jobs".
#' @examples
#' dir <- file.path(tempdir(), "batchit-chain")
#' jobs <- list(
#'   slurm_it(
#'     script = "Rscript s1_build.R",
#'     name = "proj_s1",
#'     cpus = 6,
#'     mem = "85G",
#'     time = "12:00:00"
#'   ),
#'   slurm_it(
#'     script = "Rscript s2_report.R",
#'     name = "proj_s2",
#'     cpus = 2,
#'     mem = "8G",
#'     time = "01:00:00"
#'   )
#' )
#' paths <- slurm_write(jobs, dir)
#' basename(paths)
#' unlink(dir, recursive = TRUE)
#' @export
slurm_write <- function(x, dir) {
  jobs <- .slurm_write_jobs(x)
  .slurm_write_assert_string(dir, "dir")
  .slurm_write_assert_no_whitespace(dir, "`dir`")
  memory_peak_path <- getOption("batchit.memory_peak_path")
  if (!is.null(memory_peak_path)) {
    .slurm_write_assert_string(memory_peak_path, "batchit.memory_peak_path")
  }

  if (!dir.exists(dir)) {
    made <- dir.create(dir, recursive = TRUE, showWarnings = FALSE)
    if (!made) {
      .slurm_write_stop("could not create `dir`: ", .slurm_it_show(dir))
    }
  }
  dir_abs <- normalizePath(dir, winslash = "/", mustWork = TRUE)
  .slurm_write_assert_no_whitespace(dir_abs, "the absolute path of `dir`")

  # slurm_write() owns dir. An orphaned job file from a longer previous chain
  # is unreferenced by the new submit.sh, and it still runs by hand.
  stale <- list.files(
    dir_abs,
    pattern = "\\.sh$",
    full.names = TRUE,
    all.files = TRUE
  )
  stale <- stale[!dir.exists(stale)]
  if (length(stale) > 0L) {
    gone <- file.remove(stale)
    if (!all(gone)) {
      .slurm_write_stop(
        "could not delete a stale script in `dir`: ",
        .slurm_it_show(stale[!gone])
      )
    }
  }

  job_paths <- character(length(jobs))
  for (i in seq_along(jobs)) {
    job_paths[[i]] <- file.path(dir_abs, paste0(jobs[[i]][["name"]], ".sh"))
    writeLines(
      .slurm_write_job_text(jobs[[i]], dir_abs, memory_peak_path),
      job_paths[[i]]
    )
  }
  driver_path <- file.path(
    dir_abs,
    paste0(.SLURM_WRITE_DRIVER_NAME, ".sh")
  )
  writeLines(.slurm_write_driver_text(jobs, dir_abs), driver_path)

  out <- c(job_paths, driver_path)
  Sys.chmod(out, "0755")
  return(invisible(out))
}

# --- the preflight the driver runs before its first sbatch --------------------
#
# Both checks are ported from the submit_tte.sh driver that ran the 2026 TTE
# pipeline. Each one has cost a real run, or would have.
#
# The node check reads THIS node. A check on "any node in any state" passes
# while the one node that matters is drained, which is the case it exists to
# catch.
#
# The duplicate check fails closed. Two chains on one directory overwrite each
# other's output. A `squeue` that cannot answer leaves that possibility open,
# so it is a reason to stop.

# The node states that can accept work. Any other state refuses.
#
# EVERY state the node reports must be in this set. A membership test on the
# comma-joined value would accept `drained,idle`, because `idle` is present.
# The node is drained in one partition, so it will not run the job, and the
# submission would wait PENDING until somebody noticed.
.SLURM_WRITE_NODE_STATES_OK <- c("idle", "mixed", "allocated")

#' Build the preflight the driver runs before its first `sbatch`.
#'
#' Four details of the generated shell are load-bearing, and each one has a
#' failure mode that reads as a pass.
#'
#' `tr -d '*'` deletes the suffix `sinfo` writes on a node that slurmctld
#' cannot reach. Without it, `idle*` never matches `idle` and a healthy node
#' refuses.
#'
#' `sort -u | paste -sd,` collapses the several lines a node in more than one
#' partition emits. Without `paste`, the value keeps its line breaks, no
#' branch matches, and a healthy node refuses.
#'
#' `IFS=, read -ra` then splits that value again, and the generated loop tests
#' each state on its own. `read -ra` performs no globbing and starts no
#' pipeline, so it needs neither `set -f` nor a guard against `SIGPIPE`.
#'
#' The duplicate test reads a bash here-string, and not `printf | grep -qxF`.
#' `grep -q` exits at the first match, which sends `SIGPIPE` to `printf`.
#' Under `set -o pipefail` the pipeline then reports 141, and the caller reads
#' that as "no duplicate". Measured on bash 5.3 with 200,000 lines: the
#' pipeline reports 141 and misses a match that is present. A here-string is
#' not a pipeline, so it cannot do this.
#'
#' `sinfo` exits 0 and prints nothing for a node name it does not know, so the
#' empty result needs its own branch. Verified against Slurm 25.11.2.
#'
#' No comment in the generated preflight writes the word `sbatch`. A test
#' counts the submission lines of `submit.sh` by matching that name, and a
#' comment that holds it counts as one more line.
#'
#' @param jobs List of `slurm_it` objects, in chain order.
#' @return Character vector of shell lines.
#' @noRd
.slurm_write_preflight_lines <- function(jobs) {
  names_sh <- vapply(
    jobs,
    function(job) shQuote(job[["name"]], type = "sh"),
    character(1)
  )
  states <- paste(.SLURM_WRITE_NODE_STATES_OK, collapse = " | ")
  return(c(
    "# --- preflight ---------------------------------------------------------",
    "# Both checks run before the first submission, so a refusal costs",
    "# seconds and leaves the queue as it was.",
    "",
    "batchit_refuse() {",
    "  printf 'batchit: REFUSED: %s\\n' \"$*\" >&2",
    "  exit 1",
    "}",
    "",
    "# 1. THIS node must be able to accept work. A check on any node in any",
    "#    state passes while the one node that matters is drained.",
    "if ! batchit_node=\"$(hostname -s)\"; then",
    paste0(
      "  batchit_refuse 'hostname -s failed, so the node this chain would ",
      "run on cannot be identified.'"
    ),
    "fi",
    paste0(
      "if ! batchit_state=\"$(sinfo -h -n \"$batchit_node\" -o '%T' ",
      "| tr -d '*' | sort -u | paste -sd,)\"; then"
    ),
    paste0(
      "  batchit_refuse \"sinfo failed for node $batchit_node. ",
      "Is slurmctld running?\""
    ),
    "fi",
    "if [ -z \"$batchit_state\" ]; then",
    paste0(
      "  batchit_refuse \"sinfo reported no state for node $batchit_node. ",
      "It exits 0 and prints nothing for a node it does not know, so check ",
      "NodeName in slurm.conf.\""
    ),
    "fi",
    "# EVERY state must be able to run work. A node drained in one partition",
    "# and idle in another arrives here as `drained,idle`. It will not run",
    "# the job, so the driver refuses.",
    "IFS=, read -ra batchit_states <<< \"$batchit_state\"",
    "for batchit_one in \"${batchit_states[@]}\"; do",
    "  case \"$batchit_one\" in",
    paste0("    ", states, ") : ;;"),
    "    *)",
    paste0(
      "      batchit_refuse \"node $batchit_node is in state ",
      "'$batchit_state' and will not run work. If it is drained, fix the ",
      "cause first, then: sudo scontrol update NodeName=$batchit_node ",
      "State=RESUME\""
    ),
    "      ;;",
    "  esac",
    "done",
    "",
    "# 2. Refuse a duplicate, and fail closed. A squeue that cannot answer",
    "#    leaves a second chain possible, so it is a reason to stop.",
    "if ! batchit_queued=\"$(squeue -h -o '%j')\"; then",
    paste0(
      "  batchit_refuse 'squeue failed, so a duplicate submission cannot be ",
      "ruled out.'"
    ),
    "fi",
    "# A here-string, and not printf | grep -q: grep -q exits at the first",
    "# match, printf takes SIGPIPE, and pipefail then reports 141 as no match.",
    paste0("for batchit_name in ", paste(names_sh, collapse = " "), "; do"),
    "  if grep -qxF -- \"$batchit_name\" <<< \"$batchit_queued\"; then",
    paste0(
      "    batchit_refuse \"a job named $batchit_name is already queued or ",
      "running.\""
    ),
    "  fi",
    "done",
    ""
  ))
}

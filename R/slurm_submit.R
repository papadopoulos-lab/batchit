# the submitter
#
# `slurm_write()` writes the chain. `slurm_submit()` runs it. The two stay
# separate calls, so a caller reads `submit.sh` between them.
#
# The driver prints one machine-parsable line for each submission:
#
#   batchit_submitted <name> <jobid>
#
# That line is what this function reads. Nothing here reads `sbatch`'s own
# output. The driver pipes that output through `cut -d';' -f1`, because a
# federated cluster writes `jobid;cluster` there.
#
# Nothing here reads `squeue` either. The generated preflight refuses a job
# name it finds in `squeue`, and it fails closed. A second check in R would
# duplicate a policy that lives in the generated text, and the two would
# drift.
#
# The driver runs under `set -euo pipefail`. So an `sbatch` that fails part
# way through a chain stops the driver with the earlier jobs ALREADY QUEUED.
# An error that reported the failure alone would hide them. The error names
# them, and it gives the `scancel` command that cancels them.

# One submission line of the driver, with the stage name and the job id.
#
# Both fields are anchored and hold no whitespace. A line that carries
# anything else is not a submission, and it MUST NOT reach the result.
.SLURM_SUBMIT_LINE_PATTERN <-
  "^batchit_submitted ([^[:space:]]+) ([^[:space:]]+)$"

#' Stop with the house prefix.
#' @param ... Message parts, pasted with no separator.
#' @return Never returns.
#' @noRd
.slurm_submit_stop <- function(...) {
  stop("slurm_submit(): ", ..., call. = FALSE)
}

#' Resolve the first argument to the path of one driver.
#'
#' `slurm_write()` returns the job paths first and the driver path last, so
#' the last element is the driver. A directory holds the driver under the
#' name `slurm_write()` gave it.
#'
#' The resolved file MUST be that driver. A job file runs under Slurm, and
#' running one here would run the job in this session instead.
#'
#' @param x The value the caller passed.
#' @return Character(1), the path of an existing `submit.sh`.
#' @noRd
.slurm_submit_driver_path <- function(x) {
  if (!is.character(x) || length(x) == 0L || anyNA(x)) {
    .slurm_submit_stop(
      "`x` MUST be a character vector with no NA. It takes what ",
      "`slurm_write()` returned, a directory, or the path of one ",
      .SLURM_SUBMIT_DRIVER_FILE,
      ". Got: ",
      .slurm_it_show(x)
    )
  }
  candidate <- x[[length(x)]]
  if (!grepl("[^[:space:]]", candidate)) {
    .slurm_submit_stop(
      "the last element of `x` MUST hold at least one character that is ",
      "not whitespace. Got: ",
      .slurm_it_show(candidate)
    )
  }
  driver <- if (dir.exists(candidate)) {
    file.path(candidate, .SLURM_SUBMIT_DRIVER_FILE)
  } else {
    candidate
  }
  if (!identical(basename(driver), .SLURM_SUBMIT_DRIVER_FILE)) {
    .slurm_submit_stop(
      "`x` names ",
      .slurm_it_show(driver),
      ", and the file it names MUST be ",
      .SLURM_SUBMIT_DRIVER_FILE,
      ". A job file runs under Slurm, so running one here would run the job ",
      "in this session."
    )
  }
  if (!file.exists(driver)) {
    .slurm_submit_stop(
      "no file at ",
      .slurm_it_show(driver),
      ". Write the chain with `slurm_write()` first."
    )
  }
  return(driver)
}

#' Read the job ids out of the driver's standard output.
#'
#' @param lines Character vector, the driver's standard output.
#' @return Named character vector of job ids. The names are the stage names.
#'   Empty when the driver printed no submission line.
#' @noRd
.slurm_submit_ids <- function(lines) {
  fields <- regmatches(
    lines,
    regexec(.SLURM_SUBMIT_LINE_PATTERN, lines)
  )
  fields <- fields[lengths(fields) == 3L]
  ids <- vapply(fields, function(one) one[[3L]], character(1))
  names(ids) <- vapply(fields, function(one) one[[2L]], character(1))
  return(ids)
}

#' Build the message of a failed submission.
#'
#' The ids come first, because a queued job costs the reader something and
#' the driver's own message does not say which jobs are queued.
#'
#' @param status Integer(1), the driver's exit status.
#' @param ids Named character vector of the ids already submitted.
#' @param err Character vector, the driver's standard error, verbatim.
#' @return Character(1).
#' @noRd
.slurm_submit_failure <- function(status, ids, err) {
  headline <- if (length(ids) == 0L) {
    paste0("the driver exited ", status, " and queued nothing.")
  } else {
    c(
      paste0(
        "the driver exited ",
        status,
        " with ",
        length(ids),
        if (length(ids) == 1L) " job" else " jobs",
        " already queued: ",
        paste(paste0(names(ids), "=", ids), collapse = ", ")
      ),
      paste0(
        "Cancel ",
        if (length(ids) == 1L) "it" else "them",
        ": scancel ",
        paste(ids, collapse = " ")
      )
    )
  }
  said <- if (length(err) == 0L) {
    "The driver wrote nothing to standard error."
  } else {
    c("The driver's own message follows.", err)
  }
  return(paste(c(headline, said), collapse = "\n"))
}

#' Submit a written Slurm job chain
#'
#' Runs a `submit.sh` that [slurm_write()] wrote, and returns the job ids the
#' driver submitted. The names of the returned vector are the stage names.
#'
#' `slurm_write()` writes the chain and submits nothing. `slurm_submit()`
#' submits it. They stay separate calls, so a caller reads `submit.sh`
#' between them:
#'
#' ```r
#' paths <- slurm_write(jobs, dir)
#' writeLines(readLines(paths[[length(paths)]]))
#' ids <- slurm_submit(paths)
#' ```
#'
#' @section Where the ids come from:
#' The driver prints one line for each submission, and `slurm_submit()` reads
#' those lines:
#'
#' ```
#' batchit_submitted proj_s1 5512
#' batchit_submitted proj_s2 5513
#' ```
#'
#' Nothing reads `sbatch`'s own output. The driver pipes that output through
#' `cut -d';' -f1`, because a federated cluster writes `jobid;cluster` there.
#'
#' `slurm_submit()` writes those lines to its own standard output before it
#' parses them. The driver writes to a temporary file that this call deletes,
#' so without the echo an interactive caller sees no submission at all.
#'
#' @section What an error carries:
#' A driver that exits non-zero stops this call. The error carries the
#' driver's standard error verbatim, because that text holds the diagnosis
#' and the repair. A drained node reports the `scontrol update` command that
#' resumes it.
#'
#' The driver runs under `set -euo pipefail`. So an `sbatch` that fails part
#' way through a chain stops the driver with the earlier jobs ALREADY QUEUED.
#' The error then names each queued stage and its id, and it gives the
#' `scancel` command that cancels them.
#'
#' @section Two calls cannot both submit the same chain:
#' The generated driver refuses a job name it finds in `squeue`, and it fails
#' closed. `slurm_submit()` adds no second check. One policy in one place
#' cannot disagree with itself.
#'
#' @param x What to run. Three shapes reach the same driver.
#'
#'   1. The character vector [slurm_write()] returned. Its last element is
#'      the `submit.sh` path.
#'   2. A directory that holds `submit.sh`.
#'   3. The path of a `submit.sh`.
#'
#'   Any other value is an error. The named file MUST be `submit.sh`: a job
#'   file runs under Slurm, so running one here would run the job in this
#'   session.
#' @return Named character vector of job ids, in chain order. The names are
#'   the stage names.
#' @family slurm
#' @seealso `vignette("batchit")`, section "Slurm: write a chain of
#'   jobs".
#' @examples
#' \dontrun{
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
#' paths <- slurm_write(jobs, "~/chain")
#' slurm_submit(paths)
#' }
#' @export
slurm_submit <- function(x) {
  driver <- .slurm_submit_driver_path(x)

  # `bash`, and not the file itself. The driver declares `#!/bin/bash` and
  # uses an array and a here-string, so it needs bash. Naming the
  # interpreter also runs the driver where the file system is mounted
  # `noexec`.
  out <- tempfile("batchit-submit-out-")
  err <- tempfile("batchit-submit-err-")
  on.exit(unlink(c(out, err)), add = TRUE)
  status <- as.integer(
    system2("bash", shQuote(driver), stdout = out, stderr = err)
  )

  # The driver's standard output went to a temporary file, and this call
  # deletes it. The echo is what an interactive caller sees.
  writeLines(readLines(out, warn = FALSE))

  ids <- .slurm_submit_ids(readLines(out, warn = FALSE))
  if (!identical(status, 0L)) {
    .slurm_submit_stop(
      .slurm_submit_failure(status, ids, readLines(err, warn = FALSE))
    )
  }
  return(ids)
}

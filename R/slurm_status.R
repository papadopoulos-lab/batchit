# slurm_status(): what the scheduler says, from both of its two memories.
#
# Two commands answer two halves of one question, and neither answers both.
#
# `squeue` reports what is queued or running now. It is the only source of the
# pending REASON. A caller needs that column when a job sits in the queue and
# nothing on screen says why. `squeue` forgets a job the moment it ends.
#
# `sacct` reads the accounting database, so it reports a job that finished: the
# final state, the exit code and the elapsed time. It carries no reason.
#
# So this file asks both, and it prefers the `squeue` row for a job that both
# report. That job is live, and the live source is the one with the reason.
#
# THE TRAP THIS FUNCTION EXISTS AROUND. `sacct` defaults to the jobs that
# started TODAY, and it reports an empty result rather than an error. Measured
# on Slurm 25.11.2: `sacct -a -X` returned 3 jobs, and the same call with
# `-S 2026-08-01` returned 16. A 60-hour chain started on Monday is invisible
# on Wednesday, and no rows read as "nothing is running". Every `sacct` call
# below passes `-S`.
#
# HOW A DIRECTORY NAMES ITS OWN JOBS. A chain is written once and submitted
# more than once, so a job name does not identify a run. Each job that started
# wrote `<name>_<job id>.out`, and those ids are exact. `sacct` receives them.
# A job that has not started yet wrote no log, so only `squeue` finds it, by
# name.
#
# THE SAME SHAPE, ONE LEVEL UP. A scheduler that cannot answer is an error
# here, and never an empty result. An absent command, a non-zero exit and a
# line the parser cannot read each stop the call. A status function that fails
# open reports calm.
#
# WHAT IS DELIBERATELY ABSENT. No memory column. `MaxRSS` is empty for every
# job on this machine, although `jobacct_gather/linux` is configured, and that
# is a defect in Slurm 25.11.2. A blank memory column reads as "the job used no
# memory". `slurm_write()` writes the real peak into each job's own `.out`
# file, from `/sys/fs/cgroup/memory.peak` with a `VmHWM` fallback.

# --- what the two commands are asked for -------------------------------------

# The overview window for the accounting database. `squeue` covers the present,
# so this covers the recent past.
.SLURM_STATUS_OVERVIEW_START <- "now-7days"

# The columns of the result, in this order. Each source names its own fields in
# the order its format string writes them, and then selects this vector. A
# source that forgot a column fails at that selection.
.SLURM_STATUS_COLUMNS <- c(
  "job_id",
  "user",
  "name",
  "state",
  "exit_code",
  "elapsed",
  "reason"
)

# The `squeue` format. `squeue` reports no exit code.
#
# A specifier with no width pads nothing. Measured against Slurm 25.11.2: the
# header of this format prints `JOBID|USER|NAME|STATE|TIME|REASON`, with no
# space beside any separator. So nothing here trims a field, and a job name
# reaches the caller as the scheduler holds it.
.SLURM_STATUS_SQUEUE_FORMAT <- "%i|%u|%j|%T|%M|%r"

# The `sacct` fields. `sacct` reports no reason.
#
# `--parsable2` is what makes these fields readable. The default table truncates
# a job name to ten characters and marks it with `+`, so `batchit_inside`
# arrives as `batchit_i+`.
.SLURM_STATUS_SACCT_FORMAT <- "JobID,User,JobName,State,ExitCode,Elapsed"

# The field separator both commands write.
.SLURM_STATUS_SEPARATOR <- "|"

# The sentinel this file appends to a line before it splits the line.
#
# `strsplit()` DROPS a trailing empty field: `strsplit("a|b|", "|")` returns two
# elements, not three. An empty last field would then look like a short line,
# and this function would refuse output that it can read. With the sentinel the
# last element of the split is always the sentinel, and never a value.
.SLURM_STATUS_SENTINEL <- "|batchit_eol"

# --- talking to the scheduler ------------------------------------------------

#' Stop with the house prefix.
#' @param ... Message parts, pasted with no separator.
#' @return Never returns.
#' @noRd
.slurm_status_stop <- function(...) {
  stop("slurm_status(): ", ..., call. = FALSE)
}

#' Run one scheduler command and return its standard output.
#'
#' Every argument reaches the shell inside single quotes. `system2()` pastes its
#' arguments into one command line and hands that line to a shell. The `|` of a
#' format string would otherwise start a pipeline.
#'
#' An absent command and a non-zero exit are both errors. Neither one is an
#' empty result, because a caller reads an empty result as "no jobs".
#'
#' @param command Character(1), the program to run.
#' @param args Character vector of arguments, unquoted.
#' @return Character vector, the lines the command wrote to standard output.
#' @noRd
.slurm_status_run <- function(command, args) {
  if (!nzchar(Sys.which(command)[[1L]])) {
    .slurm_status_stop(
      "`",
      command,
      "` is not on the PATH, so this session cannot reach the scheduler. An ",
      "empty result would read as `no jobs`, which is a different answer."
    )
  }
  out <- tempfile("batchit-status-out-")
  err <- tempfile("batchit-status-err-")
  on.exit(unlink(c(out, err)), add = TRUE)
  status <- as.integer(suppressWarnings(system2(
    command,
    shQuote(args, type = "sh"),
    stdout = out,
    stderr = err
  )))
  if (!identical(status, 0L)) {
    said <- readLines(err, warn = FALSE)
    .slurm_status_stop(
      "`",
      paste(c(command, args), collapse = " "),
      "` exited ",
      status,
      ". ",
      if (length(said) == 0L) {
        "It wrote nothing to standard error."
      } else {
        paste(c("Its own message follows.", said), collapse = "\n")
      }
    )
  }
  return(readLines(out, warn = FALSE))
}

#' Split the lines of one command into a data frame.
#'
#' A line that does not hold exactly one field for each name in `fields` is an
#' error. Unreadable output and no output are different answers, and only one of
#' them means "no jobs".
#'
#' @param lines Character vector, the command's standard output.
#' @param fields Character vector, the field names in the order the command
#'   writes them.
#' @param what Character(1), the command name the message reports.
#' @return A `data.frame` with one character column for each name in `fields`.
#'   Zero rows for no output.
#' @noRd
.slurm_status_fields <- function(lines, fields, what) {
  n <- length(fields)
  lines <- lines[nzchar(lines)]
  parts <- strsplit(
    paste0(lines, .SLURM_STATUS_SENTINEL, recycle0 = TRUE),
    .SLURM_STATUS_SEPARATOR,
    fixed = TRUE
  )
  wrong <- which(lengths(parts) != n + 1L)
  if (length(wrong) > 0L) {
    first <- wrong[[1L]]
    .slurm_status_stop(
      "`",
      what,
      "` wrote a line this function cannot read. Every line MUST hold ",
      n,
      " fields separated by `",
      .SLURM_STATUS_SEPARATOR,
      "`. Line ",
      first,
      " holds ",
      lengths(parts)[[first]] - 1L,
      ": ",
      .slurm_it_show(lines[[first]])
    )
  }
  # as.character(), because `unlist()` of an empty list is NULL and
  # `matrix(NULL, ncol = n)` is an error. An empty window MUST return every
  # column, so a caller can read `x$state` on it.
  flat <- as.character(unlist(lapply(parts, function(one) {
    return(one[seq_len(n)])
  })))
  return(as.data.frame(matrix(
    flat,
    ncol = n,
    byrow = TRUE,
    dimnames = list(NULL, fields)
  )))
}

#' Ask the live queue.
#'
#' @param args Character vector of extra arguments, such as `--name=`.
#' @return A `data.frame` with `.SLURM_STATUS_COLUMNS`.
#' @noRd
.slurm_status_squeue <- function(args) {
  lines <- .slurm_status_run(
    "squeue",
    c("-a", "--noheader", "-o", .SLURM_STATUS_SQUEUE_FORMAT, args)
  )
  x <- .slurm_status_fields(
    lines,
    c("job_id", "user", "name", "state", "elapsed", "reason"),
    "squeue"
  )
  x[["exit_code"]] <- rep(NA_character_, nrow(x))
  return(x[.SLURM_STATUS_COLUMNS])
}

#' Ask the accounting database.
#'
#' `-X` returns one row for each allocation, so a job step adds no row. `-S` is
#' not optional: without it `sacct` reports the jobs that started today, and it
#' calls a longer chain absent.
#'
#' @param start Character(1), the `-S` value.
#' @param args Character vector of extra arguments, such as `--name=`.
#' @return A `data.frame` with `.SLURM_STATUS_COLUMNS`.
#' @noRd
.slurm_status_sacct <- function(start, args) {
  lines <- .slurm_status_run(
    "sacct",
    c(
      "-a",
      "-X",
      "-S",
      start,
      "--parsable2",
      "--noheader",
      paste0("--format=", .SLURM_STATUS_SACCT_FORMAT),
      args
    )
  )
  x <- .slurm_status_fields(
    lines,
    c("job_id", "user", "name", "state", "exit_code", "elapsed"),
    "sacct"
  )
  x[["reason"]] <- rep(NA_character_, nrow(x))
  return(x[.SLURM_STATUS_COLUMNS])
}

#' Union the two sources on `job_id`, keeping the live row.
#'
#' A job that is queued or running appears in both. The `squeue` row wins,
#' because it carries the reason and the accounting row does not.
#'
#' @param live A `data.frame` from `squeue`.
#' @param past A `data.frame` from `sacct`.
#' @return A `data.frame`, the live rows first.
#' @noRd
.slurm_status_union <- function(live, past) {
  keep <- !past[["job_id"]] %in% live[["job_id"]]
  out <- rbind(live, past[keep, , drop = FALSE])
  row.names(out) <- NULL
  return(out)
}

# --- one written chain -------------------------------------------------------

#' Stop unless `dir` names a directory that exists.
#'
#' @param dir The value the caller passed.
#' @return Character(1), the absolute path.
#' @noRd
.slurm_status_assert_dir <- function(dir) {
  ok <- is.character(dir) && length(dir) == 1L && !is.na(dir)
  if (!ok) {
    .slurm_status_stop(
      "`dir` MUST be one non-NA string, the directory `slurm_write()` wrote ",
      "into. Got: ",
      .slurm_it_show(dir)
    )
  }
  if (!dir.exists(dir)) {
    .slurm_status_stop(
      "no directory at ",
      .slurm_it_show(dir),
      ". Name the directory `slurm_write()` wrote the chain into."
    )
  }
  return(normalizePath(dir, winslash = "/", mustWork = TRUE))
}

#' List the `.sh` files of a written chain.
#'
#' The listing carries `submit.sh` as well as the job scripts. The oldest of
#' their modification times is when the chain was written, and the `sacct`
#' window starts no later than that.
#'
#' @param dir Character(1), an absolute path.
#' @return Character vector of absolute paths.
#' @noRd
.slurm_status_chain_scripts <- function(dir) {
  paths <- list.files(
    dir,
    pattern = "\\.sh$",
    full.names = TRUE,
    all.files = TRUE
  )
  paths <- paths[!dir.exists(paths)]
  if (length(paths) == 0L) {
    .slurm_status_stop(
      "`dir` holds no `.sh` file: ",
      .slurm_it_show(dir),
      ". `slurm_write()` writes one script for each job, plus ",
      .SLURM_SUBMIT_DRIVER_FILE,
      "."
    )
  }
  return(paths)
}

#' Read the job names out of a chain's `.sh` files.
#'
#' `slurm_write()` names each job script for its job, so the file names are the
#' job names. `submit.sh` is the driver and names no job.
#'
#' @param scripts Character vector of `.sh` paths.
#' @param dir Character(1), the directory the message reports.
#' @return Character vector of job names.
#' @noRd
.slurm_status_chain_job_names <- function(scripts, dir) {
  found <- sub("\\.sh$", "", basename(scripts))
  found <- setdiff(found, .SLURM_WRITE_DRIVER_NAME)
  if (length(found) == 0L) {
    .slurm_status_stop(
      "`dir` holds ",
      .SLURM_SUBMIT_DRIVER_FILE,
      " and no job script: ",
      .slurm_it_show(dir),
      ". A chain holds at least one job."
    )
  }
  return(found)
}

#' Escape the characters a regular expression reads as syntax.
#'
#' A job name holds `.` and `-`, which `.SLURM_IT_NAME_PATTERN` allows. A `.`
#' in an unescaped pattern matches any character.
#'
#' @param x Character vector.
#' @return Character vector, each element a literal for a pattern.
#' @noRd
.slurm_status_escape <- function(x) {
  return(gsub("([][{}()+*^$|\\\\?.])", "\\\\\\1", x))
}

#' Read the job ids out of a chain's own log files.
#'
#' `slurm_write()` sets `#SBATCH --output=<dir>/<name>_%j.out`, so every job
#' that started wrote a file whose name carries its job id. Those ids are the
#' chain, and they are exact.
#'
#' The job name is what the match anchors on. A job name holds `_`, and a job
#' id is not always digits. An array task writes `21_0`, and a heterogeneous
#' job writes `17+1`. A split on the last `_` reads `21_0` as `0`.
#'
#' The longer name wins where two names of one chain both prefix one file.
#' Names `p` and `p_s1` both prefix `p_s1_41.out`, and only `p_s1` reads the id
#' `41` out of it.
#'
#' @param dir Character(1), an absolute path.
#' @param job_names Character vector of job names.
#' @return A `data.frame` with a `path` column and a `job_id` column. One row
#'   for each `.out` file a job name claims, and zero rows where none started.
#' @noRd
.slurm_status_chain_logs <- function(dir, job_names) {
  paths <- list.files(
    dir,
    pattern = "\\.out$",
    full.names = TRUE,
    all.files = TRUE
  )
  paths <- paths[!dir.exists(paths)]
  files <- basename(paths)
  job_id <- rep(NA_character_, length(files))
  for (name in job_names[order(nchar(job_names), decreasing = TRUE)]) {
    pattern <- paste0("^", .slurm_status_escape(name), "_(.+)\\.out$")
    hit <- is.na(job_id) & grepl(pattern, files)
    job_id[hit] <- sub(pattern, "\\1", files[hit])
  }
  keep <- !is.na(job_id)
  return(data.frame(path = paths[keep], job_id = job_id[keep]))
}

#' Name the log file one row wrote.
#'
#' `slurm_write()` sets `#SBATCH --output=<dir>/<name>_%j.out`, so the row's own
#' job id picks the file. Two runs of one job leave two files here, and each row
#' reads the file of its own run.
#'
#' @param x A `data.frame` with a `name` and a `job_id` column.
#' @param dir Character(1), an absolute path.
#' @param ext Character(1), `"out"` or `"err"`.
#' @return Character vector of paths, NA where the file is absent.
#' @noRd
.slurm_status_log_paths <- function(x, dir, ext) {
  path <- file.path(
    dir,
    paste0(x[["name"]], "_", x[["job_id"]], ".", ext, recycle0 = TRUE)
  )
  path[!file.exists(path)] <- NA_character_
  return(path)
}

# --- the reader --------------------------------------------------------------

#' Report what Slurm says about a job chain
#'
#' Returns one row for each job, from the live queue and the accounting database
#' together. Call it with no argument for an overview, or with the directory of
#' a written chain for that chain alone.
#'
#' ```r
#' slurm_status() # queued or running now, plus the last 7 days
#' slurm_status("~/chain") # the jobs whose scripts live in that directory
#' ```
#'
#' @section The two sources:
#' `squeue` reports what is queued or running now, and it is the only source of
#' the pending `reason`. It forgets a job the moment that job ends.
#'
#' `sacct` reads the accounting database, so it reports the final state, the
#' exit code and the elapsed time of a job that finished. It carries no reason.
#'
#' A job that is queued or running appears in both. Its `squeue` row is the one
#' that reaches the caller, because that row carries the reason.
#'
#' @section Why a directory needs no R session:
#' The session that submitted the chain is gone by the time anybody asks. So the
#' `dir` form reads the chain off disk, and it reads two kinds of file.
#'
#' Each job that started wrote `<name>_<job id>.out`, because [slurm_write()]
#' sets `#SBATCH --output=<dir>/<name>_%j.out`. Those job ids identify the run
#' exactly, and `sacct` receives them. A chain submitted twice therefore reports
#' the run whose logs are on disk.
#'
#' A job that has not started yet wrote no log. Only `squeue` sees such a job,
#' and only by job name. The `.sh` files that [slurm_write()] wrote supply those
#' names.
#'
#' The `sacct` window starts at the oldest modification time of those files, the
#' `.sh` scripts and the `.out` logs together.
#'
#' @section The pending rows come from a name match:
#' A job name is not unique, so `squeue` MAY return a job that is not this
#' chain's. Another user runs a job of the same name, or a later submission of
#' this chain sits in the queue.
#'
#' @section It refuses rather than reports calm:
#' A scheduler that cannot answer stops the call. An absent `squeue` or `sacct`,
#' a non-zero exit, and a line the parser cannot read are each an error that
#' names the command.
#'
#' The `-S` flag is why that matters. `sacct` defaults to the jobs that started
#' today, and it reports an empty result for a window that holds nothing. A
#' chain started on Monday would read as "nothing is running" on Wednesday.
#' Every `sacct` call here passes `-S`.
#'
#' A window that genuinely holds no job is a different case, and it is not an
#' error.
#'
#' @section There is no memory column:
#' `MaxRSS` is empty for every job on Slurm 25.11.2, and a blank memory column
#' reads as "the job used no memory". [slurm_write()] writes the real peak into
#' each job's own `.out` file, from `/sys/fs/cgroup/memory.peak` with a `VmHWM`
#' fallback. Read it there.
#'
#' @param dir The directory [slurm_write()] wrote a chain into, or `NULL` for
#'   the overview. A directory reports that chain's own jobs, and it adds the
#'   `out` and `err` columns.
#' @return A `data.frame`, one row for each job. Every column is character.
#'
#'   \describe{
#'     \item{`job_id`}{The job id, as Slurm writes it. Measured against Slurm
#'       25.11.2: one array task carries `<id>_<task>`, and a range of pending
#'       array tasks carries `<id>_[<first>-<last>]` in one row. Both commands
#'       write the same string, so such a job still appears once.}
#'     \item{`user`}{The user who submitted the job.}
#'     \item{`name`}{The job name.}
#'     \item{`state`}{Slurm's own state name: `PENDING`, `RUNNING`,
#'       `COMPLETED`, `FAILED`, and the rest.}
#'     \item{`exit_code`}{Slurm's `<exit>:<signal>` pair, and `NA` for a row the
#'       live queue supplied.}
#'     \item{`elapsed`}{Wall-clock time, as its own source writes it. `sacct`
#'       writes `HH:MM:SS`, or `D-HH:MM:SS` past one day. `squeue` prints the
#'       days and the hours only where they are needed, so a job two seconds
#'       in reads `0:02`.}
#'     \item{`reason`}{Why a job waits, such as `Dependency` or `Resources`.
#'       Slurm writes `None` where it reports no reason, and this function
#'       writes `NA` for a row the accounting database supplied.}
#'     \item{`out`, `err`}{The `dir` form only. The job's log files, and `NA`
#'       where the file is absent.}
#'   }
#'
#'   The live rows come first, and the rows only the accounting database holds
#'   follow them. A window that holds no job returns zero rows and every
#'   column, so `x$state` on an empty result is `character(0)` and not an error.
#' @family slurm
#' @seealso `vignette("batchit")`, section "Slurm: write a chain of jobs".
#' @examples
#' \dontrun{
#' slurm_status()
#' slurm_status("~/chain")
#' }
#' @export
slurm_status <- function(dir = NULL) {
  # Two locals below, and never two arguments to one call. R evaluates an
  # argument when the callee first touches it, so a nested call would leave the
  # order of the two commands to `.slurm_status_union()`. The live queue is
  # asked first, so a machine with no scheduler names `squeue`.
  if (is.null(dir)) {
    live <- .slurm_status_squeue(character(0))
    past <- .slurm_status_sacct(.SLURM_STATUS_OVERVIEW_START, character(0))
    return(.slurm_status_union(live, past))
  }
  path <- .slurm_status_assert_dir(dir)
  scripts <- .slurm_status_chain_scripts(path)
  job_names <- .slurm_status_chain_job_names(scripts, path)
  logs <- .slurm_status_chain_logs(path, job_names)
  start <- format(
    min(file.mtime(c(scripts, logs[["path"]]))),
    "%Y-%m-%dT%H:%M:%S"
  )
  live <- .slurm_status_squeue(paste0(
    "--name=",
    paste(job_names, collapse = ",")
  ))
  # A chain with no `.out` file started no job, so the accounting database
  # holds nothing this chain can name. `sacct` is asked for job ids and never
  # for a name, so an empty id list has nothing to ask for.
  ids <- unique(logs[["job_id"]])
  past <- if (length(ids) == 0L) {
    live[0L, , drop = FALSE]
  } else {
    .slurm_status_sacct(start, c("-j", paste(ids, collapse = ",")))
  }
  x <- .slurm_status_union(live, past)
  x[["out"]] <- .slurm_status_log_paths(x, path, "out")
  x[["err"]] <- .slurm_status_log_paths(x, path, "err")
  return(x)
}

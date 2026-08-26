# slurm_it(): one Slurm job, described and validated. Nothing here writes.
#
# The object this file returns becomes executable shell later, in
# slurm_write(). Every value it carries reaches a `#SBATCH` directive or the
# body of a generated script. The validation below is what keeps a shell
# metacharacter out of a submitted job. A missed rule here is an injection
# hole.
#
# Two facts about a generated script drive the rules. A `#SBATCH` directive
# ends at the first newline. A value that carries one escapes its line, and
# the rest of it runs as a command. A directive also ends at the first
# whitespace character, and Slurm reads what follows as a separate token.
#
# A third rule covers emptiness rather than injection. A required field MUST
# hold at least one non-whitespace character. An empty value is not a shell
# escape. It reaches the script as `#SBATCH --partition=` with no argument, or
# as a job body that runs nothing and exits 0. A chain built on
# `--dependency=afterok` then advances past a stage that did no work.
#
# Every pattern below is anchored with `^` and `$`, and every `grepl()` call
# runs with R's default TRE engine. Measured on R 4.5.2: under TRE an anchored
# pattern rejects `"abc\n"`. Under `perl = TRUE` the same pattern ACCEPTS
# `"abc\n"`, because PCRE lets `$` match before a final newline. Do not add
# `perl = TRUE` to any call in this file.
#
# An anchored charset pattern therefore carries the one-line rule and the
# no-whitespace rule for the field it guards. Neither a line break nor a space
# is in any of these charsets. `sbatch` values are the one field with no
# charset pattern, so they carry both checks explicitly.

# --- the patterns every generated literal must satisfy -----------------------

# A Slurm job name, and every file name derived from it.
#
# The leading character is the load-bearing half. A name that starts with `-`
# is a legal file name. A command that receives it positionally reads it as an
# option instead. `sbatch` parses with `getopt_long`, so `-proj.sh` enters the
# option stream rather than naming the script.
.SLURM_IT_NAME_PATTERN <- "^[A-Za-z0-9][A-Za-z0-9_.-]*$"

# A core count. One non-negative whole number, and nothing else.
.SLURM_IT_CPUS_PATTERN <- "^[0-9]+$"

# A memory request in Slurm's own notation.
.SLURM_IT_MEM_PATTERN <- "^[0-9]+[KMGT]?$"

# A wall-clock limit. `HH:MM:SS`, or `D-HH:MM:SS` for a limit past one day.
.SLURM_IT_TIME_PATTERN <- "^([0-9]+-)?[0-9]{2}:[0-9]{2}:[0-9]{2}$"

# An R package name, as Writing R Extensions defines it. It starts with a
# letter. It holds letters, digits and periods only, and it does not end in a
# period. That rule also sets a minimum of two characters.
.SLURM_IT_PACKAGE_PATTERN <- "^[a-zA-Z][a-zA-Z0-9.]*[a-zA-Z0-9]$"

# A version, as `package_version()` accepts it: two or more non-negative
# whole numbers, separated by a period or a hyphen. `package_version("1")` is
# an error, so one number alone is not a version.
.SLURM_IT_VERSION_PATTERN <- "^[0-9]+([.-][0-9]+)+$"

# An `sbatch` long option name, without its leading `--`.
.SLURM_IT_OPTION_PATTERN <- "^[A-Za-z0-9][A-Za-z0-9-]*$"

# The `sbatch` options a caller may not set.
#
# A formal argument of slurm_it() owns nine of these, and the job chain owns
# `dependency`. Slurm accepts a repeated option and takes one of the two
# without saying which. So `sbatch = c(time = "99:00:00")` competes silently
# with the `time` formal.
.SLURM_IT_RESERVED_SBATCH <- c(
  "job-name",
  "cpus-per-task",
  "mem",
  "time",
  "output",
  "error",
  "exclusive",
  "requeue",
  "no-requeue",
  "dependency"
)

# --- validation helpers ------------------------------------------------------

#' Stop with the house prefix.
#' @param ... Message parts, pasted with no separator.
#' @return Never returns.
#' @noRd
.slurm_it_stop <- function(...) {
  stop("slurm_it(): ", ..., call. = FALSE)
}

#' Render a value for an error message, with its escapes visible.
#' @param x Any value.
#' @return Character(1). `"<empty>"` when `x` holds nothing, so a message can
#'   never lose its subject to `paste0()` dropping a zero-length argument.
#' @noRd
.slurm_it_show <- function(x) {
  if (length(x) == 0L) {
    return("<empty>")
  }
  paste(encodeString(as.character(x), quote = "\""), collapse = ", ")
}

#' Stop unless a value is one non-empty, non-NA string.
#'
#' The two rules are two branches, so each one is separately reachable. Folding
#' emptiness into the type test made `""` and a wrong type report the same
#' message, and it hid that `nzchar()` accepts `" "`.
#'
#' @param x The value.
#' @param field Character(1), the field name the message reports.
#' @return `invisible(x)`.
#' @noRd
.slurm_it_assert_string <- function(x, field) {
  ok <- is.character(x) && length(x) == 1L && !is.na(x)
  if (!ok) {
    .slurm_it_stop(
      "`",
      field,
      "` MUST be one non-NA string. Got: ",
      .slurm_it_show(x)
    )
  }
  .slurm_it_assert_nonempty(x, field)
  invisible(x)
}

#' Stop when a value carries no character a command could use.
#'
#' A required field MUST hold at least one non-whitespace character.
#' `nzchar()` is not that test: `nzchar(" ")` is TRUE. A field checked with it
#' accepts a string that a reader reads as empty.
#'
#' @param x Character vector.
#' @param field Character(1), the field name the message reports.
#' @return `invisible(x)`.
#' @noRd
.slurm_it_assert_nonempty <- function(x, field) {
  bad <- x[!grepl("[^[:space:]]", x)]
  if (length(bad) > 0L) {
    .slurm_it_stop(
      "`",
      field,
      "` MUST hold at least one character that is not whitespace. Got: ",
      .slurm_it_show(bad),
      ". An empty value reaches a generated script as a directive with no ",
      "argument, or as a job body that runs nothing and exits 0."
    )
  }
  invisible(x)
}

#' Stop unless a value is one non-NA `TRUE` or `FALSE`.
#' @param x The value.
#' @param field Character(1), the field name the message reports.
#' @return `invisible(x)`.
#' @noRd
.slurm_it_assert_flag <- function(x, field) {
  ok <- is.logical(x) && length(x) == 1L && !is.na(x)
  if (!ok) {
    .slurm_it_stop(
      "`",
      field,
      "` MUST be TRUE or FALSE. Got: ",
      .slurm_it_show(x)
    )
  }
  invisible(x)
}

#' Resolve one scalar to the text a directive will carry.
#'
#' A caller writes `cpus = 6` as readily as `cpus = "6"`, so both arrive here
#' and leave as text. `format()` runs with `scientific = FALSE`, or `1e6`
#' would reach a directive as `"1e+06"`.
#'
#' @param x Character(1) or numeric(1).
#' @param field Character(1), the field name the message reports.
#' @return Character(1).
#' @noRd
.slurm_it_scalar_text <- function(x, field) {
  ok <- length(x) == 1L &&
    !is.na(x) &&
    (is.character(x) || is.numeric(x))
  if (!ok) {
    .slurm_it_stop(
      "`",
      field,
      "` MUST be one non-NA string or number. Got: ",
      .slurm_it_show(x)
    )
  }
  if (is.numeric(x)) {
    format(x, scientific = FALSE, trim = TRUE)
  } else {
    x
  }
}

#' Stop unless a value matches an anchored pattern.
#'
#' The engine is R's default TRE. See the note at the top of this file. Do not
#' pass `perl = TRUE`: PCRE lets `$` match before a final newline, so the
#' pattern then accepts a trailing line break.
#'
#' @param x Character(1).
#' @param field Character(1), the field name the message reports.
#' @param pattern Character(1), an anchored regular expression.
#' @param why Character(1), the reason the rule exists.
#' @return `invisible(x)`.
#' @noRd
.slurm_it_assert_pattern <- function(x, field, pattern, why) {
  if (!grepl(pattern, x)) {
    .slurm_it_stop(
      "`",
      field,
      "` MUST match ",
      pattern,
      ". Got: ",
      .slurm_it_show(x),
      ". ",
      why
    )
  }
  invisible(x)
}

#' Stop when a value would escape its line in generated text.
#' @param x Character vector.
#' @param field Character(1), the field name the message reports.
#' @return `invisible(x)`.
#' @noRd
.slurm_it_assert_one_line <- function(x, field) {
  bad <- x[grepl("[\r\n]", x)]
  if (length(bad) > 0L) {
    .slurm_it_stop(
      "`",
      field,
      "` holds a line break, and every value this object carries MUST be one ",
      "line: ",
      .slurm_it_show(bad),
      ". A `#SBATCH` directive ends at the first newline, so the rest of the ",
      "value would run as a command."
    )
  }
  invisible(x)
}

#' Stop when a value would break a `#SBATCH` directive at a space.
#' @param x Character vector.
#' @param field Character(1), the field name the message reports.
#' @return `invisible(x)`.
#' @noRd
.slurm_it_assert_no_whitespace <- function(x, field) {
  bad <- x[grepl("[[:space:]]", x)]
  if (length(bad) > 0L) {
    .slurm_it_stop(
      "`",
      field,
      "` holds a whitespace character, and every value this object embeds in ",
      "a directive MUST hold none: ",
      .slurm_it_show(bad),
      ". A `#SBATCH` directive ends at the first whitespace character, so ",
      "Slurm would read the rest as a separate option."
    )
  }
  invisible(x)
}

#' Stop unless a value is a fully named character vector with no NA.
#'
#' A duplicate name is an error too. Two entries under one name emit the same
#' option twice, which is the defect the reserved list exists to prevent.
#'
#' @param x The value.
#' @param field Character(1), the field name the message reports.
#' @return `invisible(x)`.
#' @noRd
.slurm_it_assert_named_character <- function(x, field) {
  if (!is.character(x)) {
    .slurm_it_stop(
      "`",
      field,
      "` MUST be a character vector. Got: ",
      paste(class(x), collapse = "/")
    )
  }
  if (length(x) == 0L) {
    return(invisible(x))
  }
  nms <- names(x)
  if (is.null(nms) || any(is.na(nms)) || !all(nzchar(nms))) {
    .slurm_it_stop(
      "`",
      field,
      "` MUST name every element. Got names: ",
      .slurm_it_show(nms)
    )
  }
  if (anyDuplicated(nms) > 0L) {
    .slurm_it_stop(
      "`",
      field,
      "` MUST name each element once. Repeated: ",
      .slurm_it_show(unique(nms[duplicated(nms)]))
    )
  }
  if (any(is.na(x))) {
    .slurm_it_stop("`", field, "` MUST hold no NA value.")
  }
  invisible(x)
}

#' Find the reserved `sbatch` keys one name would reach.
#'
#' `sbatch` parses with `getopt_long`, which accepts an abbreviation that
#' names one option. So `sbatch = c(jo = "x")` reaches sbatch as
#' `--job-name`, and a check on the literal names alone lets it through.
#'
#' A name of two or more characters is therefore reserved when it is a prefix
#' of a reserved key. A one-character name is left to sbatch, which rejects an
#' abbreviation that names more than one option.
#'
#' @param key Character(1), an sbatch long option name without its `--`.
#' @return Character vector of the reserved keys `key` would reach. Empty when
#'   it reaches none.
#' @noRd
.slurm_it_reserved_hits <- function(key) {
  if (nchar(key) < 2L) {
    return(character(0))
  }
  .SLURM_IT_RESERVED_SBATCH[startsWith(.SLURM_IT_RESERVED_SBATCH, key)]
}

# --- the constructor ---------------------------------------------------------

#' Describe one Slurm job
#'
#' Builds a validated description of one Slurm job. It writes nothing, because
#' `slurm_write()` is what turns the object into a job script.
#'
#' Every field this object carries reaches a `#SBATCH` directive or a
#' generated script, so this function checks all of them before it returns.
#' The checks reject a line break, a whitespace character and a shell
#' metacharacter, each in the fields where that character would change what
#' runs.
#'
#' @param script Character(1). The shell command the job runs. This is the one
#'   field that MAY hold more than one line, because it becomes the body of
#'   the generated script rather than a directive. It MUST hold at least one
#'   character that is not whitespace.
#' @param name Character(1). The job identity. It names the job to Slurm, and
#'   it names three files: `<name>.sh`, `<name>_%j.out` and `<name>_%j.err`.
#'   It MUST match `^[A-Za-z0-9][A-Za-z0-9_.-]*$`. The leading character rule
#'   is the load-bearing half: a name that starts with `-` reads as an option.
#' @param cpus Character(1) or one number. The core count, which reaches
#'   `--cpus-per-task`. It MUST be one non-negative whole number.
#' @param mem Character(1) or one number. The memory request in Slurm's own
#'   notation, such as `"85G"`. It MUST be digits, then an optional `K`, `M`,
#'   `G` or `T`.
#' @param time Character(1). The wall-clock limit, as `HH:MM:SS` or
#'   `D-HH:MM:SS`. No other format is accepted.
#' @param requeue Logical(1). `TRUE` asks Slurm to requeue the job after a
#'   node failure. `FALSE` asks Slurm not to.
#' @param exclusive Logical(1). `TRUE` asks for the whole node.
#' @param require_r_package Named character vector. Each name is an R package
#'   the job needs, and each value is the version that package MUST be at.
#'   Defaults to `character(0)`.
#' @param sbatch Named character vector of extra `sbatch` long options,
#'   written without the leading `--`. A name in the reserved list is an
#'   error, because a formal argument or the job chain already sets it. The
#'   reserved names are `job-name`, `cpus-per-task`, `mem`, `time`, `output`,
#'   `error`, `exclusive`, `requeue`, `no-requeue` and `dependency`. Each value
#'   MUST hold at least one character that is not whitespace. Defaults to
#'   `character(0)`.
#' @return An object of class `slurm_it`. It is a list with the elements
#'   `script`, `name`, `cpus`, `mem`, `time`, `requeue`, `exclusive`,
#'   `require_r_package` and `sbatch`. `cpus` and `mem` come back as text,
#'   whichever type the caller passed.
#' @examples
#' job <- slurm_it(
#'   script = "Rscript s1_build.R",
#'   name = "proj_s1",
#'   cpus = 6,
#'   mem = "85G",
#'   time = "12:00:00"
#' )
#' job[["name"]]
#' job[["cpus"]]
#' @export
slurm_it <- function(
  script,
  name,
  cpus,
  mem,
  time,
  requeue = TRUE,
  exclusive = FALSE,
  require_r_package = character(0),
  sbatch = character(0)
) {
  # `script` is the body of the generated file, so it is the one field the
  # one-line rule does not reach. It still must be one real string.
  .slurm_it_assert_string(script, "script")

  .slurm_it_assert_string(name, "name")
  .slurm_it_assert_pattern(
    name,
    "name",
    .SLURM_IT_NAME_PATTERN,
    paste0(
      "The pattern is anchored, so it rejects a line break, a carriage ",
      "return and every whitespace character. It also rejects a leading ",
      "`-`, which sbatch, Rscript and cd each read as an option."
    )
  )

  cpus <- .slurm_it_scalar_text(cpus, "cpus")
  .slurm_it_assert_pattern(
    cpus,
    "cpus",
    .SLURM_IT_CPUS_PATTERN,
    "A core count is one non-negative whole number, and nothing else."
  )

  mem <- .slurm_it_scalar_text(mem, "mem")
  .slurm_it_assert_pattern(
    mem,
    "mem",
    .SLURM_IT_MEM_PATTERN,
    "A memory request is digits, then an optional K, M, G or T."
  )

  .slurm_it_assert_string(time, "time")
  .slurm_it_assert_pattern(
    time,
    "time",
    .SLURM_IT_TIME_PATTERN,
    "A wall-clock limit is HH:MM:SS or D-HH:MM:SS, and nothing else."
  )

  .slurm_it_assert_flag(requeue, "requeue")
  .slurm_it_assert_flag(exclusive, "exclusive")

  .slurm_it_assert_named_character(require_r_package, "require_r_package")
  for (i in seq_along(require_r_package)) {
    pkg <- names(require_r_package)[i]
    .slurm_it_assert_pattern(
      pkg,
      paste0("require_r_package name ", i),
      .SLURM_IT_PACKAGE_PATTERN,
      paste0(
        "An R package name starts with a letter, holds letters, digits and ",
        "periods only, and does not end in a period."
      )
    )
    .slurm_it_assert_pattern(
      require_r_package[[i]],
      paste0("require_r_package[[\"", pkg, "\"]]"),
      .SLURM_IT_VERSION_PATTERN,
      paste0(
        "A version is two or more whole numbers, separated by a period or ",
        "a hyphen."
      )
    )
  }

  .slurm_it_assert_named_character(sbatch, "sbatch")
  for (i in seq_along(sbatch)) {
    key <- names(sbatch)[i]
    .slurm_it_assert_pattern(
      key,
      paste0("sbatch name ", i),
      .SLURM_IT_OPTION_PATTERN,
      paste0(
        "An sbatch long option name holds letters, digits and hyphens only, ",
        "and it is written without its leading `--`."
      )
    )
    hits <- .slurm_it_reserved_hits(key)
    if (length(hits) > 0L) {
      .slurm_it_stop(
        "`sbatch` MUST NOT set `",
        key,
        "`, which a formal argument or the job chain already owns. sbatch ",
        "accepts an abbreviation that names one option, so `",
        key,
        "` reaches it as ",
        paste0("--", hits, collapse = ", "),
        ". Slurm accepts an option twice and takes one of the two without ",
        "saying which. Reserved: ",
        paste(.SLURM_IT_RESERVED_SBATCH, collapse = ", "),
        "."
      )
    }
    .slurm_it_assert_nonempty(sbatch[[i]], paste0("sbatch[[\"", key, "\"]]"))
    .slurm_it_assert_one_line(sbatch[[i]], paste0("sbatch[[\"", key, "\"]]"))
    .slurm_it_assert_no_whitespace(
      sbatch[[i]],
      paste0("sbatch[[\"", key, "\"]]")
    )
  }

  structure(
    list(
      script = script,
      name = name,
      cpus = cpus,
      mem = mem,
      time = time,
      requeue = requeue,
      exclusive = exclusive,
      require_r_package = require_r_package,
      sbatch = sbatch
    ),
    class = "slurm_it"
  )
}

# --- slurm_write(): the description becomes executable shell ------------------
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

# The counter a job reads for peak memory, under cgroup v2. The option
# `batchit.memory_peak_path` overrides it, for a cluster that keeps the counter
# somewhere else.
.SLURM_WRITE_MEMORY_PEAK_PATH <- "/sys/fs/cgroup/memory.peak"

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
  path
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
  invisible(x)
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
  invisible(x)
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
  jobs
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
  lines
}

#' Build the text of one job file.
#'
#' `exclusive = FALSE` emits no line at all, which is the whole of the false
#' case. Slurm has no negative form of that option, so the absence of the
#' directive is what asks for a shared node.
#'
#' @param job One `slurm_it` object.
#' @param dir Character(1), the absolute directory the chain writes into.
#' @param memory_peak_path Character(1), the counter the job reads on exit.
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
    paste0("batchit_memory_peak_path=", shQuote(memory_peak_path, type = "sh")),
    "",
    "batchit_record_peak_memory() {",
    "  if [ -r \"$batchit_memory_peak_path\" ]; then",
    "    printf 'batchit_memory_peak_bytes %s\\n' \\",
    "      \"$(cat -- \"$batchit_memory_peak_path\")\"",
    "  elif [ -r /proc/self/status ]; then",
    "    printf 'batchit_vmhwm_kb %s\\n' \\",
    "      \"$(awk '/^VmHWM:/ { print $2 }' /proc/self/status)\"",
    "  else",
    "    printf 'batchit_peak_memory_unavailable\\n'",
    "  fi",
    "}",
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
  c(header, preamble, gate, body)
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
  c(
    paste0("--dependency=afterok:\"$batchit_jid_", i - 1L, "\""),
    "--kill-on-invalid-dep=yes"
  )
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
  lines
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
#' The option `batchit.memory_peak_path` names the file item 3 reads. It
#' defaults to the cgroup v2 counter, `/sys/fs/cgroup/memory.peak`. A job that
#' cannot read that file reports `VmHWM` from `/proc/self/status` instead. Set
#' the option where the cluster keeps the counter somewhere else.
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
#' @seealso [slurm_it()], which builds each job.
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
  memory_peak_path <- getOption(
    "batchit.memory_peak_path",
    .SLURM_WRITE_MEMORY_PEAK_PATH
  )
  .slurm_write_assert_string(memory_peak_path, "batchit.memory_peak_path")

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
  invisible(out)
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
  c(
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
  )
}

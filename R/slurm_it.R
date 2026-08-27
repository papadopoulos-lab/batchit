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
  return(paste(encodeString(as.character(x), quote = "\""), collapse = ", "))
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
  return(invisible(x))
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
  return(invisible(x))
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
  return(invisible(x))
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
    return(format(x, scientific = FALSE, trim = TRUE))
  } else {
    return(x)
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
  return(invisible(x))
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
  return(invisible(x))
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
  return(invisible(x))
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
  return(invisible(x))
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
  return(.SLURM_IT_RESERVED_SBATCH[startsWith(.SLURM_IT_RESERVED_SBATCH, key)])
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
#' @family slurm
#' @seealso `vignette("batchit")`, section "Slurm: write a chain of
#'   jobs".
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

  return(structure(
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
  ))
}

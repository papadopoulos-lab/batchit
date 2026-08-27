# slurm_it() is a validator with a constructor attached. The object it returns
# becomes executable shell in slurm_write(), so every rejection case below is
# an injection that would otherwise reach a submitted job.
#
# The blocks map one-to-one onto the validation rules in R/slurm_it.R, so a
# deleted branch there fails a named block here rather than a scattered set.

ok_args <- list(
  script = "Rscript s1_build.R",
  name = "proj_s1",
  cpus = 6,
  mem = "85G",
  time = "12:00:00"
)

# Call slurm_it() with the well-formed arguments, overridden by `...`.
#
# It does not use utils::modifyList(). modifyList() DELETES an element it is
# given as NULL, so `call_slurm_it(name = NULL)` would drop `name` entirely and
# R would raise "argument \"name\" is missing" instead of slurm_it()'s own
# rejection. `args[nm] <- list(NULL)` sets the element to NULL and keeps it.
call_slurm_it <- function(...) {
  over <- list(...)
  args <- ok_args
  for (nm in names(over)) {
    args[nm] <- list(over[[nm]])
  }
  do.call(batchit::slurm_it, args)
}

# A short label for a rejected value, for expect_error(info = ).
label_arg <- function(x) {
  paste0(paste(class(x), collapse = "/"), "[", length(x), "]")
}

# --- acceptance --------------------------------------------------------------

test_that("slurm_it() returns a slurm_it object and writes nothing", {
  # An empty directory, made the working directory, is what makes "writes
  # nothing" observable: a relative-path write would land here.
  tmp <- withr::local_tempdir()
  withr::local_dir(tmp)

  job <- batchit::slurm_it(
    script = "Rscript s1_build.R",
    name = "proj_s1",
    cpus = 6,
    mem = "85G",
    time = "12:00:00"
  )

  expect_s3_class(job, "slurm_it")
  expect_true(is.list(job))
  expect_identical(
    names(job),
    c(
      "script",
      "name",
      "cpus",
      "mem",
      "time",
      "requeue",
      "exclusive",
      "require_r_package",
      "sbatch"
    )
  )
  expect_identical(job[["script"]], "Rscript s1_build.R")
  expect_identical(job[["name"]], "proj_s1")
  # cpus arrived as a number and leaves as the text a directive carries.
  expect_identical(job[["cpus"]], "6")
  expect_identical(job[["mem"]], "85G")
  expect_identical(job[["time"]], "12:00:00")
  expect_identical(job[["requeue"]], TRUE)
  expect_identical(job[["exclusive"]], FALSE)
  expect_identical(job[["require_r_package"]], character(0))
  expect_identical(job[["sbatch"]], character(0))

  expect_identical(
    list.files(tmp, recursive = TRUE, all.files = TRUE, no.. = TRUE),
    character(0)
  )
})

test_that("slurm_it() accepts every optional field at once", {
  job <- call_slurm_it(
    script = "Rscript a.R\nRscript b.R",
    time = "2-06:30:00",
    cpus = "12",
    requeue = FALSE,
    exclusive = TRUE,
    require_r_package = c(swereg = "26.8.21", data.table = "1.17-0"),
    sbatch = c(partition = "core", account = "uu-2026")
  )

  expect_s3_class(job, "slurm_it")
  # `script` is the one field that may hold more than one line.
  expect_identical(job[["script"]], "Rscript a.R\nRscript b.R")
  expect_identical(job[["time"]], "2-06:30:00")
  expect_identical(job[["cpus"]], "12")
  expect_identical(job[["requeue"]], FALSE)
  expect_identical(job[["exclusive"]], TRUE)
  expect_identical(
    job[["require_r_package"]],
    c(swereg = "26.8.21", data.table = "1.17-0")
  )
  expect_identical(job[["sbatch"]], c(partition = "core", account = "uu-2026"))
})

# --- rule: one line, on every field except the script body -------------------

test_that("slurm_it() rejects a line break in every field except script", {
  # `name` carries the rule through its anchored pattern.
  expect_error(call_slurm_it(name = "a\nsbatch --wrap=true #"), "slurm_it\\(\\)")
  expect_error(call_slurm_it(name = "proj\n"), "slurm_it\\(\\)")
  expect_error(call_slurm_it(name = "proj\r"), "slurm_it\\(\\)")
  expect_error(call_slurm_it(mem = "85G\n"), "slurm_it\\(\\)")
  expect_error(call_slurm_it(cpus = "6\n"), "slurm_it\\(\\)")
  expect_error(call_slurm_it(time = "12:00:00\n"), "slurm_it\\(\\)")
  expect_error(
    call_slurm_it(sbatch = c(partition = "core\n#SBATCH --time=99:00:00")),
    "line break"
  )
  expect_error(
    call_slurm_it(require_r_package = c(swereg = "26.8.21\n")),
    "slurm_it\\(\\)"
  )
})

test_that("slurm_it() accepts a line break in the script body", {
  job <- call_slurm_it(script = "set -e\nRscript s1.R\n")
  expect_identical(job[["script"]], "set -e\nRscript s1.R\n")
})

# --- rule: no whitespace character at all, on a path-shaped field ------------

test_that("slurm_it() rejects a whitespace character in a path-shaped field", {
  expect_error(call_slurm_it(name = "proj s1"), "slurm_it\\(\\)")
  expect_error(call_slurm_it(name = "proj\ts1"), "slurm_it\\(\\)")
  expect_error(
    call_slurm_it(sbatch = c(partition = "core --time=99:00:00")),
    "whitespace"
  )
})

# --- rule: name matches ^[A-Za-z0-9][A-Za-z0-9_.-]*$ -------------------------

test_that("slurm_it() rejects a name outside the name pattern", {
  # The leading character is the load-bearing half: sbatch, Rscript and cd all
  # read a leading `-` as an option instead of a name.
  expect_error(call_slurm_it(name = "-proj_s1"), "slurm_it\\(\\)")
  expect_error(call_slurm_it(name = ".proj"), "slurm_it\\(\\)")
  expect_error(call_slurm_it(name = "proj;rm -rf /"), "slurm_it\\(\\)")
  expect_error(call_slurm_it(name = "proj$(id)"), "slurm_it\\(\\)")
  expect_error(call_slurm_it(name = "proj/s1"), "slurm_it\\(\\)")

  expect_error(call_slurm_it(name = " "), "slurm_it\\(\\)")

  expect_s3_class(call_slurm_it(name = "9proj_s1.v2-a"), "slurm_it")
})

# --- rule: cpus matches ^[0-9]+$ ---------------------------------------------

test_that("slurm_it() rejects a cpus value outside the cpus pattern", {
  expect_error(call_slurm_it(cpus = "6; rm -rf /"), "slurm_it\\(\\)")
  expect_error(call_slurm_it(cpus = "6.5"), "slurm_it\\(\\)")
  expect_error(call_slurm_it(cpus = 6.5), "slurm_it\\(\\)")
  expect_error(call_slurm_it(cpus = -1), "slurm_it\\(\\)")
  expect_error(call_slurm_it(cpus = ""), "slurm_it\\(\\)")

  expect_identical(call_slurm_it(cpus = 6L)[["cpus"]], "6")
})

# --- rule: mem matches ^[0-9]+[KMGT]?$ ---------------------------------------

test_that("slurm_it() rejects a mem value outside the mem pattern", {
  expect_error(
    batchit::slurm_it(
      script = "true",
      name = "j",
      cpus = 6,
      mem = "85G; rm -rf /",
      time = "01:00:00"
    ),
    "slurm_it\\(\\)"
  )
  expect_error(call_slurm_it(mem = "85 G"), "slurm_it\\(\\)")
  expect_error(call_slurm_it(mem = "85GB"), "slurm_it\\(\\)")
  expect_error(call_slurm_it(mem = "big"), "slurm_it\\(\\)")

  expect_identical(call_slurm_it(mem = "85000")[["mem"]], "85000")
})

# --- rule: time is HH:MM:SS or D-HH:MM:SS, and nothing else ------------------

test_that("slurm_it() rejects a time outside HH:MM:SS and D-HH:MM:SS", {
  expect_error(call_slurm_it(time = "1:00:00"), "slurm_it\\(\\)")
  expect_error(call_slurm_it(time = "12:00"), "slurm_it\\(\\)")
  expect_error(call_slurm_it(time = "12:00:00; ls"), "slurm_it\\(\\)")
  expect_error(call_slurm_it(time = "infinite"), "slurm_it\\(\\)")
  expect_error(call_slurm_it(time = "2_01:00:00"), "slurm_it\\(\\)")

  expect_error(call_slurm_it(time = " "), "slurm_it\\(\\)")

  expect_identical(call_slurm_it(time = "7-00:00:00")[["time"]], "7-00:00:00")
})

# --- rule: scalar, non-NA, non-empty character on all metadata ---------------

test_that("slurm_it() rejects a non-scalar, NA or empty metadata field", {
  for (fld in c("script", "name", "time")) {
    for (bad in list(NULL, NA_character_, character(0), "", c("a", "b"), 1L)) {
      expect_error(
        do.call(call_slurm_it, stats::setNames(list(bad), fld)),
        "slurm_it\\(\\)",
        info = paste(fld, "=", label_arg(bad))
      )
    }
  }
  # `cpus` and `mem` take a number as well as a string, so NULL, NA and a
  # length-2 value are what they reject.
  for (fld in c("cpus", "mem")) {
    for (bad in list(NULL, NA, NA_character_, character(0), c("1", "2"))) {
      expect_error(
        do.call(call_slurm_it, stats::setNames(list(bad), fld)),
        "slurm_it\\(\\)",
        info = paste(fld, "=", label_arg(bad))
      )
    }
  }
  for (fld in c("requeue", "exclusive")) {
    for (bad in list(NULL, NA, "TRUE", c(TRUE, FALSE), 1L)) {
      expect_error(
        do.call(call_slurm_it, stats::setNames(list(bad), fld)),
        "slurm_it\\(\\)",
        info = paste(fld, "=", label_arg(bad))
      )
    }
  }
})

# --- rule: a required field holds at least one non-whitespace character ------

test_that("slurm_it() rejects a whitespace-only script", {
  # `script` becomes the body of the generated file, so it is the one field the
  # one-line rule does not reach. That exemption made it the one field where
  # nzchar() was the whole emptiness test, and nzchar(" ") is TRUE. A
  # whitespace-only body submits a job that runs nothing and exits 0, which a
  # `--dependency=afterok` chain reads as success.
  for (bad in c("", " ", "\t", "\n", "\r\n", "   \t\n  ", "\f", "\v")) {
    expect_error(
      call_slurm_it(script = bad),
      "slurm_it\\(\\)",
      info = paste("script =", encodeString(bad, quote = "\""))
    )
  }

  # Whitespace AROUND a real command is legitimate and stays accepted.
  expect_identical(
    call_slurm_it(script = "  Rscript a.R  ")[["script"]],
    "  Rscript a.R  "
  )
})

test_that("slurm_it() rejects an empty or whitespace-only sbatch value", {
  # An empty value reaches the generated script as `#SBATCH --partition=`, an
  # option with no argument.
  for (bad in c("", " ", "\t", "\n", "  \n ")) {
    expect_error(
      call_slurm_it(sbatch = c(partition = bad)),
      "slurm_it\\(\\)",
      info = paste("sbatch value =", encodeString(bad, quote = "\""))
    )
  }

  # The check reads every element, not the first one.
  expect_error(
    call_slurm_it(sbatch = c(partition = "core", account = "")),
    "slurm_it\\(\\)"
  )
  expect_error(
    call_slurm_it(sbatch = c(account = "", partition = "core")),
    "slurm_it\\(\\)"
  )

  # "0" is a real value for several sbatch options and MUST stay accepted.
  expect_identical(
    call_slurm_it(sbatch = c(nice = "0"))[["sbatch"]],
    c(nice = "0")
  )
})

# --- rule: require_r_package is a named character vector of versions ---------

test_that("slurm_it() rejects a malformed require_r_package", {
  expect_error(call_slurm_it(require_r_package = "26.8.21"), "MUST name every")
  expect_error(
    call_slurm_it(require_r_package = c(swereg = "26.8.21", "1.0.0")),
    "MUST name every"
  )
  expect_error(
    call_slurm_it(require_r_package = c(swereg = "26.8.21", swereg = "26.8.22")),
    "each element once"
  )
  expect_error(call_slurm_it(require_r_package = list(swereg = "1.0")), "slurm_it\\(\\)")
  expect_error(
    call_slurm_it(require_r_package = c(swereg = NA_character_)),
    "no NA value"
  )
  # a name that is not an R package name
  expect_error(call_slurm_it(require_r_package = c("2swereg" = "1.0")), "slurm_it\\(\\)")
  expect_error(call_slurm_it(require_r_package = c("swereg;ls" = "1.0")), "slurm_it\\(\\)")
  # a value that is not a version
  expect_error(call_slurm_it(require_r_package = c(swereg = "latest")), "slurm_it\\(\\)")
  expect_error(call_slurm_it(require_r_package = c(swereg = "1")), "slurm_it\\(\\)")
  expect_error(
    call_slurm_it(require_r_package = c(swereg = "1.0; rm -rf /")),
    "slurm_it\\(\\)"
  )

  job <- call_slurm_it(require_r_package = c(data.table = "1.17-0"))
  expect_identical(job[["require_r_package"]], c(data.table = "1.17-0"))
})

# --- rule: sbatch is a named character vector, and no name is reserved -------

test_that("slurm_it() rejects a reserved sbatch key", {
  reserved <- c(
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
  for (key in reserved) {
    expect_error(
      do.call(
        call_slurm_it,
        list(sbatch = stats::setNames("99:00:00", key))
      ),
      "MUST NOT set",
      info = key
    )
  }

  expect_error(
    batchit::slurm_it(
      script = "true",
      name = "j",
      cpus = 6,
      mem = "1G",
      time = "01:00:00",
      sbatch = c(time = "99:00:00")
    ),
    "slurm_it\\(\\)"
  )
})

test_that("slurm_it() rejects a malformed sbatch vector", {
  expect_error(call_slurm_it(sbatch = "core"), "MUST name every")
  expect_error(call_slurm_it(sbatch = c(partition = "a", partition = "b")), "each element once")
  expect_error(call_slurm_it(sbatch = list(partition = "core")), "slurm_it\\(\\)")
  expect_error(call_slurm_it(sbatch = c(partition = NA_character_)), "no NA value")
  expect_error(call_slurm_it(sbatch = c("--partition" = "core")), "slurm_it\\(\\)")
  expect_error(call_slurm_it(sbatch = c("part ition" = "core")), "slurm_it\\(\\)")

  job <- call_slurm_it(sbatch = c(partition = "core", "mail-type" = "FAIL"))
  expect_identical(job[["sbatch"]], c(partition = "core", "mail-type" = "FAIL"))
})

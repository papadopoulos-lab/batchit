# Stub programs for every block that runs a generated `submit.sh`.
#
# A driver asks the host four questions before it submits: `hostname -s`,
# `sinfo`, `squeue`, then `sbatch`. A block that stubs only some of them
# passes on a machine with Slurm installed, and fails on one without it.
# That is the CI failure on 508315e. The driver block in
# `test-slurm_write.R` stubbed `sbatch` alone, the development machine
# answered `sinfo` from `/usr/bin`, and the CI runner had no `sinfo`.
#
# So a block that runs a driver builds its `PATH` with `slurm_stub_path()`,
# and never by hand.
#
# THE GUARD. `slurm_stub_path()` writes a refusing shim for every command in
# `slurm_stub_commands` that the caller did not stub. A driver that reaches
# an unstubbed one fails on every host, including a host with a healthy
# Slurm. A new block that depends on a host binary therefore fails at once,
# on the author's own machine. The block named `slurm_stub_path() refuses a
# Slurm command the caller left unstubbed` in `test-slurm_write.R` drives
# that shim.
#
# WHAT THE GUARD DOES NOT COVER. The generated shell also calls `tr`, `sort`,
# `paste`, `grep`, `wc` and `cut`. Each one is a function of its input, so it
# answers the same on every machine and a stub would prove nothing. A
# scheduler command outside `slurm_stub_commands` still reaches the host.

# The commands whose answer describes the host, so the answer differs between
# machines. `hostname`, plus the 19 client commands Slurm 25.11.2 installs
# into `/usr/bin`. The generated driver calls four of them today.
slurm_stub_commands <- c(
  "hostname",
  "sacct",
  "sacctmgr",
  "salloc",
  "sattach",
  "sbatch",
  "sbcast",
  "scancel",
  "scontrol",
  "scrontab",
  "sdiag",
  "sh5util",
  "sinfo",
  "sprio",
  "squeue",
  "sreport",
  "srun",
  "sshare",
  "sstat",
  "strigger"
)

# Write one stub program and make it executable.
#
# `body` holds the shell lines below the shebang.
slurm_stub_write <- function(dir, name, body) {
  path <- file.path(dir, name)
  writeLines(c("#!/bin/bash", body), path)
  Sys.chmod(path, "0755")
  path
}

# The body of a stub that prints fixed text and exits with a fixed status.
#
# `out` carries `\n` for a command that writes several lines, such as the
# `sinfo` of a node in more than one partition.
slurm_stub_fixed <- function(out = "", status = 0L) {
  c(
    if (nzchar(out)) paste0("printf '%s\\n' ", shQuote(out, type = "sh")),
    paste0("exit ", status)
  )
}

# Build the stub directory and return the `PATH` a driver runs under.
#
# `stubs` is a named list. Each name is a command, and each element holds the
# shell lines of its body. Every other command in `slurm_stub_commands` gets
# the refusing shim described at the top of this file.
slurm_stub_path <- function(dir, stubs) {
  stopifnot(is.list(stubs), length(stubs) > 0L, !anyNA(names(stubs)))
  stopifnot(all(nzchar(names(stubs))), !anyDuplicated(names(stubs)))
  dir.create(dir, recursive = TRUE, showWarnings = FALSE)

  for (name in names(stubs)) {
    slurm_stub_write(dir, name, stubs[[name]])
  }
  for (name in setdiff(slurm_stub_commands, names(stubs))) {
    slurm_stub_write(
      dir,
      name,
      c(
        paste0(
          "printf 'batchit test guard: %s reached the host. ",
          "Stub it in slurm_stub_path().\\n' ",
          shQuote(name, type = "sh"),
          " >&2"
        ),
        "exit 127"
      )
    )
  }
  paste(dir, Sys.getenv("PATH"), sep = .Platform$path.sep)
}

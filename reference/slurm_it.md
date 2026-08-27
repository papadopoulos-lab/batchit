# Describe one Slurm job

Builds a validated description of one Slurm job. It writes nothing,
because
[`slurm_write()`](https://papadopoulos-lab.github.io/batchit/reference/slurm_write.md)
is what turns the object into a job script.

## Usage

``` r
slurm_it(
  script,
  name,
  cpus,
  mem,
  time,
  requeue = TRUE,
  exclusive = FALSE,
  require_r_package = character(0),
  sbatch = character(0)
)
```

## Arguments

- script:

  Character(1). The shell command the job runs. This is the one field
  that MAY hold more than one line, because it becomes the body of the
  generated script rather than a directive. It MUST hold at least one
  character that is not whitespace.

- name:

  Character(1). The job identity. It names the job to Slurm, and it
  names three files: `<name>.sh`, `<name>_%j.out` and `<name>_%j.err`.
  It MUST match `^[A-Za-z0-9][A-Za-z0-9_.-]*$`. The leading character
  rule is the load-bearing half: a name that starts with `-` reads as an
  option.

- cpus:

  Character(1) or one number. The core count, which reaches
  `--cpus-per-task`. It MUST be one non-negative whole number.

- mem:

  Character(1) or one number. The memory request in Slurm's own
  notation, such as `"85G"`. It MUST be digits, then an optional `K`,
  `M`, `G` or `T`.

- time:

  Character(1). The wall-clock limit, as `HH:MM:SS` or `D-HH:MM:SS`. No
  other format is accepted.

- requeue:

  Logical(1). `TRUE` asks Slurm to requeue the job after a node failure.
  `FALSE` asks Slurm not to.

- exclusive:

  Logical(1). `TRUE` asks for the whole node.

- require_r_package:

  Named character vector. Each name is an R package the job needs, and
  each value is the version that package MUST be at. Defaults to
  `character(0)`.

- sbatch:

  Named character vector of extra `sbatch` long options, written without
  the leading `--`. A name in the reserved list is an error, because a
  formal argument or the job chain already sets it. The reserved names
  are `job-name`, `cpus-per-task`, `mem`, `time`, `output`, `error`,
  `exclusive`, `requeue`, `no-requeue` and `dependency`. Each value MUST
  hold at least one character that is not whitespace. Defaults to
  `character(0)`.

## Value

An object of class `slurm_it`. It is a list with the elements `script`,
`name`, `cpus`, `mem`, `time`, `requeue`, `exclusive`,
`require_r_package` and `sbatch`. `cpus` and `mem` come back as text,
whichever type the caller passed.

## Details

Every field this object carries reaches a `#SBATCH` directive or a
generated script, so this function checks all of them before it returns.
The checks reject a line break, a whitespace character and a shell
metacharacter, each in the fields where that character would change what
runs.

## See also

[`vignette("batchit")`](https://papadopoulos-lab.github.io/batchit/articles/batchit.md),
section "Slurm: write a chain of jobs".

Other slurm:
[`inside_slurm_job()`](https://papadopoulos-lab.github.io/batchit/reference/inside_slurm_job.md),
[`slurm_status()`](https://papadopoulos-lab.github.io/batchit/reference/slurm_status.md),
[`slurm_submit()`](https://papadopoulos-lab.github.io/batchit/reference/slurm_submit.md),
[`slurm_write()`](https://papadopoulos-lab.github.io/batchit/reference/slurm_write.md)

## Examples

``` r
job <- slurm_it(
  script = "Rscript s1_build.R",
  name = "proj_s1",
  cpus = 6,
  mem = "85G",
  time = "12:00:00"
)
job[["name"]]
#> [1] "proj_s1"
job[["cpus"]]
#> [1] "6"
```

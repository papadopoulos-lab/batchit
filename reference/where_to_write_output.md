# The staging path batchit pre-computed for one declared output

Inside a `style = "staged_writer"`
[`run_and_write_files_atomically()`](https://papadopoulos-lab.github.io/batchit/reference/run_and_write_files_atomically.md)
target, WRITE each declared output to `where_to_write_output(<name>)` –
an attempt-scoped temp path in the SAME directory as that output's final
destination (so the later commit rename is same-filesystem) – instead of
returning it. The target's own return value is ignored by the commit
engine; batchit finds out what was written by checking, once the target
returns, that this exact path exists as a regular, non-symlink file
(design PHASE6_DESIGN.md section 3.4) – a declared name the target never
wrote fails the whole item, with zero renames.

## Usage

``` r
where_to_write_output(name)
```

## Arguments

- name:

  The declared output name – must be one of this item's `outputs` names.

## Value

A single absolute path string. WRITE to this path; do not read it back
or move/rename it yourself – batchit renames it to the final destination
once every declared output has been staged.

## Details

Only callable from inside the
[`do.call()`](https://rdrr.io/r/base/do.call.html) of a
`style = "staged_writer"`
[`run_and_write_files_atomically()`](https://papadopoulos-lab.github.io/batchit/reference/run_and_write_files_atomically.md)
item – i.e. only in a batchit worker subprocess, while that one target
call is running. Calling it any other time (outside a staged_writer run
entirely, or for a `name` this item never declared) is an error.

## Examples

``` r
if (FALSE) { # \dontrun{
# inside a style = "staged_writer" target:
my_writer <- function(x) {
  saveRDS(x, where_to_write_output("primary"))
  invisible(NULL)
}
} # }
```

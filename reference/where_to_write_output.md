# Get the path to write one declared output to, inside a "staged_writer" function

When you use `style = "staged_writer"` with
[`run_and_write_files_atomically()`](https://papadopoulos-lab.github.io/batchit/reference/run_and_write_files_atomically.md)
or
[`stream_from_parent_and_write_files_atomically()`](https://papadopoulos-lab.github.io/batchit/reference/stream_from_parent_and_write_files_atomically.md),
your function does not return its output. It writes each declared output
itself, to the path this function gives you. Call
`where_to_write_output(name)` once for each output name you declared in
`outputs`, and write to exactly that path. Do not read it back, move it,
or rename it yourself. batchit renames it into place, next to the other
declared outputs, once your function returns successfully.

## Usage

``` r
where_to_write_output(name)
```

## Arguments

- name:

  The declared output name to write. Must be one of this item's
  `outputs` names.

## Value

A single absolute path string. WRITE to this path; do not read it back
or move/rename it yourself. batchit renames it to the final destination
once every declared output has been staged.

## Details

Use `style = "return"` instead when it's simpler for your function to
build R objects and return them in a named list. batchit then serializes
each one to its final path for you. Use `"staged_writer"` when your
function already writes files itself, for example in a format other than
`qs2`, or via another package's own writer. Your function then does not
have to build the whole object in memory, just to hand it to batchit to
save again.

This only works while your function is actually running inside a batchit
worker, during a `style = "staged_writer"` item. Calling it at any other
time, or asking for a `name` this item didn't declare in `outputs`, is
an error.

If your function is an inline function (see
[`run_and_write_files_atomically()`](https://papadopoulos-lab.github.io/batchit/reference/run_and_write_files_atomically.md)'s
`fn` argument), call it as `batchit::where_to_write_output()`. An inline
function may only call other packages' functions in package-qualified
form, and `batchit` is not automatically attached. If your function
instead lives in your own installed package, either import
`where_to_write_output` or call it the same package-qualified way.

## See also

[`run_and_write_files_atomically()`](https://papadopoulos-lab.github.io/batchit/reference/run_and_write_files_atomically.md)
and
[`stream_from_parent_and_write_files_atomically()`](https://papadopoulos-lab.github.io/batchit/reference/stream_from_parent_and_write_files_atomically.md),
the two functions that establish the active run this reads from.

[`vignette("batchit")`](https://papadopoulos-lab.github.io/batchit/articles/batchit.md)
for the two rules that go with calling this inside `fn`.

## Examples

``` r
# \donttest{
write_two_files <- function(x) {
  saveRDS(x^2, batchit::where_to_write_output("squared"))
  writeLines(as.character(x * 2), batchit::where_to_write_output("doubled"))
  invisible(NULL) # ignored by batchit for style = "staged_writer"
}

out_dir <- file.path(tempdir(), "batchit-staged-example")
dir.create(out_dir)
run_and_write_files_atomically(
  fn = write_two_files,
  items = list(list(x = 2), list(x = 3)),
  outputs = list(
    c(squared = file.path(out_dir, "sq_1.rds"), doubled = file.path(out_dir, "db_1.txt")),
    c(squared = file.path(out_dir, "sq_2.rds"), doubled = file.path(out_dir, "db_2.txt"))
  ),
  style = "staged_writer",
  n_workers = 2
)
#>   [0/2] dispatching workers...
#>   [1/2] complete  09:35:41
#>   [2/2] complete  09:35:41
#> $`1`
#> $`1`$committed
#>                                           squared 
#> "/tmp/RtmpCi4CoX/batchit-staged-example/sq_1.rds" 
#>                                           doubled 
#> "/tmp/RtmpCi4CoX/batchit-staged-example/db_1.txt" 
#> 
#> $`1`$attempt
#> [1] "1ad742bc791c"
#> 
#> 
#> $`2`
#> $`2`$committed
#>                                           squared 
#> "/tmp/RtmpCi4CoX/batchit-staged-example/sq_2.rds" 
#>                                           doubled 
#> "/tmp/RtmpCi4CoX/batchit-staged-example/db_2.txt" 
#> 
#> $`2`$attempt
#> [1] "1ad714cf7195"
#> 
#> 
readRDS(file.path(out_dir, "sq_1.rds")) # 4
#> [1] 4
readLines(file.path(out_dir, "db_1.txt")) # "4"
#> [1] "4"

unlink(out_dir, recursive = TRUE)
# }
```

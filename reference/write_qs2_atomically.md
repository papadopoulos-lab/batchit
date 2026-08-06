# Atomically write an object to a qs2 file

Writes to a uniquely-named temporary file in the same directory as
`path`, then renames it into place. Rename-into-place is atomic on POSIX
filesystems, and server-side atomic on SMB/CIFS. So an interrupted write
leaves the destination either absent or complete. It is never a
truncated file that a later read would halt on. An interruption here
means a `SIGKILL`, a crash, or a dropped mount. `...` is forwarded to
[`qs2::qs_save()`](https://rdrr.io/pkg/qs2/man/qs_save.html).

## Usage

``` r
write_qs2_atomically(object, path, ...)
```

## Arguments

- object:

  Object to serialize.

- path:

  Destination path. Its parent directory must already exist.

- ...:

  Passed to [`qs2::qs_save()`](https://rdrr.io/pkg/qs2/man/qs_save.html)
  (e.g. `nthreads`).

## Value

`path`, invisibly.

## Details

The parent directory of `path` must already exist: this function never
creates it.

What this does **not** promise, stated because the tempting reading is
wrong:

- **It is not durability.**
  [`file.rename()`](https://rdrr.io/r/base/files.html) is atomic with
  respect to other *readers*; it is not an `fsync`. A power loss can
  still lose a renamed file whose data has not reached the disk. This
  protects against a killed process, not a killed machine.

- **It is not a lock.** Two concurrent writers of the same `path` each
  produce a complete file and the last rename wins. No reader sees a
  torn file, but nothing here decides *which* writer should have won.

- **It does not always clean up after itself.** The partial temp file is
  removed on an R-level error. But
  [`on.exit()`](https://rdrr.io/r/base/on.exit.html) cannot run after a
  `SIGKILL`, so a hard-killed worker leaves its randomly-named `.tmp`
  behind. The *destination* is still absent-or-complete, which is the
  guarantee that matters; the litter is not.

The temporary file is created with
[`tempfile()`](https://rdrr.io/r/base/tempfile.html) in the destination
directory rather than `paste0(path, ".tmp", Sys.getpid())`. A PID suffix
is not collision-proof. PIDs are unique only among *live processes on
one host*. Data of this kind commonly lives on a share that two hosts
mount at once. The same PID on two machines could then pick the same
temp path for the same target. Same directory is required:
[`file.rename()`](https://rdrr.io/r/base/files.html) is not atomic
across filesystems.

This is a standalone writer, independent of the
[`run_and_write_files_atomically()`](https://papadopoulos-lab.github.io/batchit/reference/run_and_write_files_atomically.md)
commit engine. Its temp carries no dispatch attempt token, and that
engine's failure cleanup does not sweep it.

## See also

[`run_and_write_files_atomically()`](https://papadopoulos-lab.github.io/batchit/reference/run_and_write_files_atomically.md)
for the same guarantee applied to every output of a dispatched item.
That function's commit engine is separate: this writer emits no marker,
and its temporary file is not swept by that engine's failure cleanup.

[`vignette("batchit")`](https://papadopoulos-lab.github.io/batchit/articles/batchit.md)
for where this sits relative to the four dispatch functions.

## Examples

``` r
path <- file.path(tempdir(), "cars.qs2")
write_qs2_atomically(mtcars, path)
nrow(qs2::qs_read(path))
#> [1] 32

# The destination is replaced only once the new file is complete, so a
# reader never sees a truncated file, and an interrupted write leaves the
# previous contents intact.
write_qs2_atomically(mtcars[1:5, ], path)
nrow(qs2::qs_read(path))
#> [1] 5

unlink(path)
```

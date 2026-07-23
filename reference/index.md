# Package index

## Dispatch a function across subprocesses

Run one function over many items, one fresh subprocess per item. Each
takes `fn` — a
[`package_function()`](https://papadopoulos-lab.github.io/batchit/reference/package_function.md)
descriptor (hash-verified) or a bare closure — and they differ in how
each item’s data arrives and in what comes back: a return value, or
output files committed atomically.

- [`run()`](https://papadopoulos-lab.github.io/batchit/reference/run.md)
  :

  Run `fn` on each of a fixed list of items, one subprocess per item,
  returning nothing

- [`run_and_collect()`](https://papadopoulos-lab.github.io/batchit/reference/run_and_collect.md)
  :

  Run `fn` on each of a fixed list of items, one subprocess per item,
  collecting values

- [`run_and_write_files_atomically()`](https://papadopoulos-lab.github.io/batchit/reference/run_and_write_files_atomically.md)
  : Run a target on each of a fixed list of items, committing DECLARED
  OUTPUT FILES instead of returning a value

- [`stream_from_parent_and_write_files_atomically()`](https://papadopoulos-lab.github.io/batchit/reference/stream_from_parent_and_write_files_atomically.md)
  : Stream a producer's items through a target, committing DECLARED
  OUTPUT FILES instead of returning a value

## Building a dispatch

Helpers used when constructing a dispatch: name the target function
(hash-verified against what the worker loads), and, inside a
`staged_writer` target, resolve where to write a declared output.

- [`package_function()`](https://papadopoulos-lab.github.io/batchit/reference/package_function.md)
  : Describe a dispatch target
- [`where_to_write_output()`](https://papadopoulos-lab.github.io/batchit/reference/where_to_write_output.md)
  : The staging path batchit pre-computed for one declared output

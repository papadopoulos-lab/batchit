#' batchit: run one R function across many parallel worker processes
#'
#' `batchit` runs one R function once per item in a list of inputs, each
#' call in its own worker process, and either collects the return values or
#' has the worker write output files for you. Pick one of four functions,
#' depending on what you need:
#'
#' | Your situation | Use |
#' |---|---|
#' | Items already exist; run for side effects, ignore the return values | [run()] |
#' | Items already exist; collect the return values | [run_and_collect()] |
#' | Items already exist; let batchit write output files atomically | [run_and_write_files_atomically()] |
#' | Too many/too-large items to build up front; build them lazily and write files | [stream_from_parent_and_write_files_atomically()] |
#'
#' Each item is a named list holding the arguments for one call to your
#' function (every argument must be named, including ones with a default
#' value). Your function can be either an inline function you write directly
#' in the call, or a reference to a function in an installed package built
#' by [package_function()]. See that function's help page for when to
#' prefer one over the other.
#'
#' For a runnable quick-start example and a fuller explanation of each
#' function, see the README at
#' <https://github.com/papadopoulos-lab/batchit>.
#'
#' @section Advanced:
#' `run()`, `run_and_collect()`, and `run_and_write_files_atomically()` each
#' run their items in a fresh `processx` subprocess, one per item.
#' `stream_from_parent_and_write_files_atomically()` instead runs its items
#' on persistent `mirai` background workers, so items can be produced
#' lazily, under a bounded amount of in-flight memory, instead of being
#' built into a list up front.
#'
#' When `fn` is a [package_function()] reference, batchit checks that each
#' worker loaded the exact same function definition your R session did
#' (via a hash of the function's body and arguments), and validates every
#' item's argument names against the function's own arguments, in both
#' your R session and the worker, before anything runs. batchit does not
#' change BLAS or `data.table` thread settings; if your function is itself
#' multi-threaded, divide your CPU cores across `n_workers` yourself.
#' @keywords internal
"_PACKAGE"

# mirai injects these by NAME into the quoted `mirai::mirai()` / `everywhere()`
# expressions in stream_from_parent_and_write_files_atomically() (.consumer /
# .runner / .dev are cross-process load hints; .env is the envelope), so
# codetools sees them as free variables inside those blocks. They are not
# package globals -- declare them so the spurious "no visible binding for
# global variable" NOTE does not fire.
utils::globalVariables(c(".consumer", ".dev", ".env", ".runner"))

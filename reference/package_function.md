# Describe a dispatch target

A target is a *descriptor*, never a function object, name, or closure:
package + symbol + a hash of the function's body and formals. Package
name plus symbol alone is insufficient – development code, installed
code and cache identity can differ – so the descriptor also records a
`digest(list(body, formals))` identity hash. The child re-computes that
hash after loading the target and refuses to run if it differs, which
closes the stale-code / wrong-version hole a bare package+symbol
reference would leave.

## Usage

``` r
package_function(package, symbol, version = NULL)
```

## Arguments

- package:

  Package holding the target (character scalar). This is the CONSUMER
  package; it need not be `batchit`.

- symbol:

  Name of the target function in that package (character scalar). May be
  an internal (unexported) symbol – it is resolved in the package's
  namespace.

- version:

  Optional recorded version; defaults to the package's installed
  version. Advisory only – the hash is what the child actually checks.

## Value

A `package_function` descriptor: a list with class `"package_function"`
and elements `package`, `symbol`, `version`, `hash`, `formal_names`.

## Details

The hash is deliberately narrow: it covers the target's OWN body and
formals only. A changed helper the target calls, a namespace constant it
closes over, an S4/R6 method table, or a dependency's version are
outside it – so this proves "same target definition", not "provably
identical behaviour", and the latter is not claimed.
[`utils::removeSource()`](https://rdrr.io/r/utils/removeSource.html) is
applied before hashing so the identity is independent of srcref
(comments / whitespace): otherwise an installed package (no srcref) and
a
[`devtools::load_all()`](https://devtools.r-lib.org/reference/load_all.html)
tree (srcref) disagree on identical code, which is exactly what happens
when the parent runs the installed package while a worker dev-loads the
source.

A target that takes `...` is rejected: arbitrary dots are incompatible
with the reliable detection of a mistyped or missing argument that the
contract depends on.

## Examples

``` r
if (FALSE) { # \dontrun{
# target an exported or internal function of any installed package
t <- package_function("mypkg", "process_one_slice")
t$formal_names
} # }
```

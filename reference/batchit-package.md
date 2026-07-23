# batchit: One Subprocess Dispatcher with a Both-Ends-Validated Contract

A generic parent/child dispatch contract for running one R function
across many subprocesses. A package target is a descriptor – package
plus symbol plus a body/formals identity hash, never a closure – so the
child can refuse code that differs from what the parent dispatched; an
ad-hoc target dispatches a self-contained closure by value instead. Work
items are validated at both ends against the target's formals, and every
result comes back in a structured envelope (protocol, id, status,
value-or-error, target identity, captured warnings). Two transports
share the one contract: a fresh process per item via 'processx' for
memory-bound work where process exit is the memory strategy, and a lazy
producer with bounded backpressure via 'mirai' daemons for work whose
items are generated on demand.

## See also

Useful links:

- <https://github.com/papadopoulos-lab/batchit>

- Report bugs at <https://github.com/papadopoulos-lab/batchit/issues>

## Author

**Maintainer**: Richard Aubrey White <hello@rwhite.no>
([ORCID](https://orcid.org/0000-0002-6747-1726))

Authors:

- Richard Aubrey White <hello@rwhite.no>
  ([ORCID](https://orcid.org/0000-0002-6747-1726))

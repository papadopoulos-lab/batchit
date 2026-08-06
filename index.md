What’s inside

01

### A fresh process per item

One function runs once per item, up to `n_workers` at a time. Collected
results keep the order of `items`, not the order the workers finished.
Three of the four dispatch functions start a brand-new R process per
item, because process exit is what reclaims memory. The streaming one
trades that for lazy item production.

02

### Declared outputs, committed atomically

Declare each item’s final output paths and batchit writes them: staged
beside their destinations, renamed into place, marker written last. A
failed or interrupted item never leaves a half-written file at a final
path. What the guarantee does *not* cover is stated just as precisely.

03

### Dispatch the code you tested

Name the target by package and symbol. Each worker then hashes what it
loaded, and refuses to run a definition that differs from the one you
dispatched. batchit checks every item’s arguments against the formals
twice: in the calling session, and again in the worker. A default must
be named too.

What’s inside

01

### A fresh process per item

One function runs once per item, up to `n_workers` at a time, and
collected results keep the order of `items` rather than the order the
workers finished. Three of the four dispatch functions start a brand-new
R process per item, because process exit is what reclaims memory; the
streaming one trades that for lazy item production.

02

### Declared outputs, committed atomically

Declare each item’s final output paths and batchit writes them: staged
beside their destinations, renamed into place, marker written last. A
failed or interrupted item never leaves a half-written file at a final
path. What the guarantee does *not* cover is stated just as precisely.

03

### Dispatch the code you tested

Name the target by package and symbol and each worker hashes what it
loaded, refusing to run a definition that differs from the one you
dispatched. Every item’s arguments are checked against the formals
twice, in the calling session and again in the worker, with defaults
required by name.

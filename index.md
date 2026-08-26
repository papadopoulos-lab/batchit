What’s inside

01

### A fresh process per item

One function runs once per item, up to `n_workers` at a time. Three of
the four dispatch functions start a brand-new R process per item,
because process exit is what reclaims memory.

02

### Declared outputs, committed atomically

Declare each item’s final output paths. batchit stages them beside their
destinations, renames them into place, and writes the marker last. A
failed or interrupted item never leaves a half-written file at a final
path.

03

### Or hand the work to a scheduler

[`slurm_it()`](https://papadopoulos-lab.github.io/batchit/reference/slurm_it.md)
describes one Slurm job.
[`slurm_write()`](https://papadopoulos-lab.github.io/batchit/reference/slurm_write.md)
turns a list of them into one bash file per job, plus a `submit.sh` that
chains them with `–dependency=afterok`. batchit submits nothing. You run
`submit.sh` yourself.

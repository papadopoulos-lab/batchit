---
title: batchit
---

<p class="rw-section">What's inside</p>

<div class="rw-cards">
<div class="rw-card"><div class="rw-card-num">01</div><h3>A fresh process per item</h3><p>One function runs once per item, up to <code>n_workers</code> at a time. Three of the four dispatch functions start a brand-new R process per item, because process exit is what reclaims memory.</p></div>
<div class="rw-card"><div class="rw-card-num">02</div><h3>Declared outputs, committed atomically</h3><p>Declare each item's final output paths. batchit stages them beside their destinations, renames them into place, and writes the marker last. A failed or interrupted item never leaves a half-written file at a final path.</p></div>
<div class="rw-card"><div class="rw-card-num">03</div><h3>Or hand the work to a scheduler</h3><p><code>slurm_it()</code> describes one Slurm job. <code>slurm_write()</code> turns a list of them into one bash file per job, plus a <code>submit.sh</code> that chains them with <code>--dependency=afterok</code>. batchit submits nothing. You run <code>submit.sh</code> yourself.</p></div>
</div>

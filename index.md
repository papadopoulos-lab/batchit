---
title: batchit
---

<p class="rw-section">What's inside</p>

<div class="rw-cards">
<div class="rw-card"><div class="rw-card-num">01</div><h3>A fresh process per item</h3><p>One function runs once per item, up to <code>n_workers</code> at a time. Collected results keep the order of <code>items</code>, not the order the workers finished. Three of the four dispatch functions start a brand-new R process per item, because process exit is what reclaims memory. The streaming one trades that for lazy item production.</p></div>
<div class="rw-card"><div class="rw-card-num">02</div><h3>Declared outputs, committed atomically</h3><p>Declare each item's final output paths and batchit writes them: staged beside their destinations, renamed into place, marker written last. A failed or interrupted item never leaves a half-written file at a final path. What the guarantee does <em>not</em> cover is stated just as precisely.</p></div>
<div class="rw-card"><div class="rw-card-num">03</div><h3>Dispatch the code you tested</h3><p>Name the target by package and symbol. Each worker then hashes what it loaded, and refuses to run a definition that differs from the one you dispatched. batchit checks every item's arguments against the formals twice: in the calling session, and again in the worker. A default must be named too.</p></div>
</div>

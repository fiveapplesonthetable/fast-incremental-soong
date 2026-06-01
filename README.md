# Warm-incremental Soong

Make AOSP's analysis phase incremental: edit one `Android.bp`, regenerate
`build.ninja` in seconds instead of re-analyzing the whole tree — **byte-identical
to a clean build**, measured on real AOSP.

> **Status (checkpoint `v0.8.1`):** warm `frameworks/base/Android.bp` rebuilds,
> regenerate+write, byte-identical to a cold resident rebuild (all 1067 ninja+mk
> shards), warm path, clean exit:
>
> | edit | regenerate+write | from |
> |---|--:|--:|
> | **add** a module | **~0.76 s** | ~24 s |
> | **remove** a module | **~0.80 s** | ~24 s |
> | **property edit** (worst case: `framework-minus-apex-defaults`) | **~1.64 s** | ~4.5 s |
>
> Add/remove are sub-second. The property edit shown is the *worst case* — editing
> the defaults for the entire framework jar — and its residual ~1.64 s is intrinsic:
> reparse the large `Android.bp` (~0.4 s) + **regenerate the framework jar's analysis**
> (the heavy `framework-minus-apex` modules, ~1.1 s) + rewrite the ~18 manifest shards
> that changed (~0.3 s). A leaf edit pays only the reparse + a tiny generate and is
> sub-second. The edit was also made *deterministically* byte-identical (it previously
> depended on a flaky re-parse hash to re-mutate `java_defaults` consumers; now a
> propagating-dependency-tag closure does it for sure).
>
> **Verified edit classes (corpus, `poc_fb_corpus.sh`):** property edit, `java_defaults`
> edit, direct module-property edit, add-module, remove-module are each byte-identical.
> **Known gap:** a *filegroup-srcs* edit (e.g. reordering `framework-non-updatable-sources`)
> is **not** byte-identical — its consumers regenerate via `interfaceChanged`, which is
> computed with a tolerant provider hash that misses func-valued/non-deterministic
> provider changes (the same unsoundness the `java_defaults` closure side-steps), so
> ~6 consumer shards stay stale. This is a pre-existing limitation of the warm path's
> generate-time propagation, not introduced by these caches; it needs the deterministic
> provider-propagation work (the redesign). Until then the warm path should not be
> trusted for filegroup-srcs edits. See `patches/SUMMARY.md` for the breakdown.

## What it does

A resident `soong_build` daemon keeps the resolved + mutated module graph in RAM.
On a warm `.bp` edit it reparses only the changed file, re-mutates only the
affected closure, regenerates only dirty modules, and rewrites only the manifest
shards that changed — instead of re-parsing 14k+ `Android.bp` files and
re-analyzing the whole module graph from scratch.

Every warm result is verified **byte-identical** to a cold rebuild of the same
tree (`cmp`, every ninja + `.mk` shard).

## How to enable it

It is a single environment variable on an otherwise-normal build:

```sh
# First build: cold. Starts the resident soong_build daemon and snapshots the graph.
SOONG_PERSISTENT_REUSE_GRAPH=true m nothing

#   …edit an Android.bp…

# Re-run the SAME command: warm. Reuses the resident graph, O(edit), byte-identical.
SOONG_PERSISTENT_REUSE_GRAPH=true m nothing
```

`m nothing` builds just the ninja manifest (the analysis phase this work makes
incremental); use any target you like. `SOONG_NINJA_SHARDS=N` (default 50/10)
controls manifest shard granularity. **With the variable unset (the default),
the build is byte-for-byte stock** — see "Will this work on my tree?".

## Result (real AOSP, `aosp_cf_x86_64_phone-trunk_staging-userdebug`, soong-only)

Measured on an edit to **`frameworks/base/Android.bp`** (the realistic worst case:
a large, central mega-`Android.bp`), build target `nothing` (analysis only):

| edit | reparse | what the warm rebuild does | byte-identical |
|---|--:|---|:--:|
| **property edit** (existing module) | 0.40 s | 13 modules in the edited closure regenerated; **singletons kept**; delta write skips 34/50 ninja + 50/50 incremental shards | yes |
| **add a module** | 0.40 s | graph reused; added module regenerated + whole-graph singletons re-run; delta write skips 47/50 ninja + 50/50 incremental shards | yes |
| **remove a module** | 0.40 s | removed module's shard force-rewritten; singletons re-run | yes |

"Byte-identical" means **warm-resident == cold-resident**: a warm rebuild produces
exactly the same `build.ninja` as a from-scratch (cold) resident build of the same
edited tree. That is the guarantee that proves the incremental analysis is exact.

The dominant warm cost on an **add/remove** is **singleton regeneration** (an add
or remove is a membership change, so whole-graph singletons such as the
module-info and phony aggregations re-run). A **property edit keeps singletons**
and is cheaper. The reparse itself is ~0.4 s (one file) versus a full-tree reparse
(~4–5 s), and the manifest write is O(edit) (only changed shards rewritten).

### Two subtle correctness mechanisms (so warm == cold holds for these too)

- **Order-only dedup is recomputed from immutable inputs every build**, and any
  *clean* module whose emitted order-only deps flip because a shared key crossed the
  dedup-vs-keep threshold (a dirty module added/dropped a use of it) is forced to be
  re-serialized — so the delta write never keeps a stale shard for it.
- **Singleton phony contributions are recomputed fresh every build**; the pure-add
  fold (which reuses the cached module phonies) is only taken when those singleton
  phonies are unchanged, otherwise the phony makefile is rebuilt fully. A singleton
  that aggregates over all modules can't silently go stale on an add.

## Will this work on my tree? (Pixel / vendor / Kati — read this)

**With `SOONG_PERSISTENT_REUSE_GRAPH` unset (default): yes, nothing changes.**
Every warm-specific behavior is gated behind that variable (`residentNinjaLayout()`
/ `keepPristineModules`). A normal build — including a Kati-enabled Pixel `m` — takes
the stock code path and produces a byte-identical manifest. The upstream Blueprint
unit tests pass unchanged, which is the evidence for this.

**With the variable on, on a config other than the one tested:** it is designed to
fail *safe*, not *wrong*. Anything the warm path can't represent incrementally (an
unsupported mutator, a transition, a structural change it can't prove neutral)
returns `ErrFallbackToFullBuild` and does a **full cold rebuild** — byte-identical
to stock. So the worst realistic outcome on an untested config is "this edit wasn't
fast," not "wrong ninja." Every fallback logs a greppable `WARM-FALLBACK: <reason>`
so you can see exactly which edit classes your tree doesn't yet handle incrementally.

**What was verified:** `aosp_cf_x86_64_phone`, **soong-only** (`m nothing`),
property-edit / add / remove on `frameworks/base/Android.bp`, byte-identical.

**What was NOT tested (real residual risk):**
- **Kati-enabled full `m`** (only soong-only `nothing` was measured). The warm path
  only regenerates soong's ninja; Kati is orthogonal, but unexercised here.
- **Vendor / proprietary modules, larger graphs, extra `PRODUCT_SOONG_NAMESPACES`** —
  may hit mutators/variants the warm path falls back on.

**To validate on your tree:** run a warm edit, then a `SOONG_PERSISTENT_REUSE_GRAPH=true`
cold rebuild of the same tree, and `cmp` the ninja + `.mk` shards (what the test
scripts do). If they match, that edit class is exact on your config.

## Diagnosing a failure (what to capture)

The logging is built so that a pasted log says *what* failed and *why*. Two
sources: the soong_ui build output, and the resident server log at
`out/soong/.soong_build_persistent.sock.log`.

- **"My edit was slow / didn't go warm."** `grep WARM-FALLBACK <build log>`. Each
  line names the stage and the exact cause, e.g.
  `WARM-FALLBACK: mutator "arch" creates variants (transition mutator): ... -> full cold rebuild`
  or `WARM-FALLBACK: incremental add fell back: <reason>`. That line tells you the
  precise edit class the warm path doesn't yet handle on your tree — enough to know
  whether it's a quick extension (teach that mutator) or a known limitation. Paste
  the `WARM-FALLBACK:` line(s).

- **"Warm produced the wrong ninja."** The build log alone won't show this (a warm
  build that *succeeds* with wrong output doesn't log anything special — that's why
  the byte-gate exists). Run the validate recipe above; if a shard differs, the
  script prints `DIFFERS: <shard>`. Paste that list plus the `diff` of one differing
  shard (warm copy vs the cold-resident `out/soong/<shard>`) — that pinpoints the
  module/rule that diverged and is enough to root-cause.

- **"It crashed."** The daemon prints a Go stack trace to the server log; paste it.

In all three cases the build is still *correct*: a fallback and a crash both end in
(or can be re-run as) a full cold rebuild; only a byte-divergence is a real bug, and
the byte-gate is what surfaces it.

## What's here

- **`EXPLAINER.md`** — a long-form walkthrough of the whole AOSP build system
  (Make → Kati → Ninja → Soong/Blueprint) and exactly how the incremental analysis
  works, where the time goes, what is gated, and what is left. Start here.
- **`patches/`** — the change, as `git am`-able commits against upstream:
  - `0001-build-soong.patch` (apply in `build/soong`, onto `f389fa2a2`)
  - `0002-build-blueprint.patch` (apply in `build/blueprint`, onto `c39c8a4`)
  - `SUMMARY.md` — one-page summary of the patch.

## How it works (one paragraph)

Graph residency (a persistent process) is what makes O(edit) possible — a batch
tool that exits every build has nothing in memory to skip *to*. On top of that:
changed-file-only reparse; incremental re-mutation of the affected closure;
content-addressed (hash-of-identity) shard assignment so adding/removing a module
leaves every other module in its shard and the manifest write stays O(edit);
single-use singletons reset before re-run on a membership change; and the largest
singleton output (the soong-only phony makefile) sharded so a warm edit rewrites
only the shards that changed. Every one of these is gated so a non-resident build
is byte-identical to upstream; the warm and cold *resident* manifests are
byte-identical to each other.

## Honest caveats

- Local / experimental. Not in upstream AOSP; not pushed there.
- Requires the resident daemon (`SOONG_PERSISTENT_REUSE_GRAPH=true`).
- Byte-identity verified for property edit / add / remove of a leaf-ish module on
  `frameworks/base/Android.bp`, soong-only, on `aosp_cf_x86_64_phone`. Not an
  exhaustive edit-class corpus, and not yet verified on Kati / vendor / Pixel.
- The full `m` wall is not single-digit yet: an add/remove is dominated by
  singleton regeneration, and the outer build still carries product-config
  (`dumpvars`) and a stock-ninja manifest reload. See `EXPLAINER.md` for the
  remaining floors and the proposed designs to remove them.

# Warm-incremental Soong

Make AOSP's analysis phase incremental: edit one `Android.bp`, regenerate
`build.ninja` in seconds instead of re-analyzing the whole tree — **byte-identical
to a clean build**, measured on real AOSP.

## Result (real AOSP, `aosp_cf_x86_64_phone-trunk_staging-userdebug`)

A resident `soong_build` daemon keeps the resolved+mutated graph in RAM. A warm
`.bp` edit reparses only the changed file, re-mutates only the affected closure,
regenerates only dirty modules, and rewrites only the manifest shards that changed.
Every warm result is verified byte-identical to a cold rebuild (`cmp`, all shards).

| edit | cold | warm | byte-identical |
|---|---:|---:|---|
| property edit (existing module) | 131 s analysis | **~4.4 s** | yes |
| add a module | (crash / full rebuild) | **warm, 1 shard** | yes |
| remove a module | full rebuild | **warm, 1 shard** | yes |

"Analysis" = producing the updated `build.ninja` (the part this work makes O(edit)).
The full `m` wall (~20 s for an edit) also carries product-config (`dumpvars`) and a
stock-ninja 5.6 GB manifest reload — separate floors, not yet removed.

## What's here

- **`EXPLAINER.md`** — a long-form walkthrough of the whole AOSP build system
  (Make → Ninja → Kati → Soong/Blueprint) and exactly how the incremental analysis
  works, where the time goes, and what's left. Start here.
- **`patches/`** — the change, as `git am`-able commits against upstream:
  - `0001-build-soong.patch` (apply in `build/soong`, onto `f389fa2a2`)
  - `0002-build-blueprint.patch` (apply in `build/blueprint`, onto `c39c8a4`)
  - `SUMMARY.md` — one-page summary of the patch.

## How it works (one paragraph)

Graph residency (a persistent process) is the thing that makes O(edit) possible — a
batch tool that exits every time has nothing in memory to skip *to*. On top of that:
changed-file-only reparse; incremental re-mutation of the affected closure;
content-addressed (hash-of-identity) shard assignment so adding/removing a module
leaves every other module in its shard and the manifest write stays O(edit);
single-use singletons reset before re-run on a membership change; and the largest
singleton output (`soong_phony_targets.mk`, 600 MB) sharded so a warm edit rewrites
only the shards that changed.

## Honest caveats

- Local / experimental work. Not in upstream AOSP; not pushed there.
- Requires the resident daemon (`SOONG_PERSISTENT_REUSE_GRAPH=true`).
- Byte-identity verified for property edits to existing modules plus add/remove of
  a leaf module; not an exhaustive edit-class corpus.
- The full `m` wall is not single-digit yet — that needs a resident ninja (avoid the
  5.6 GB reload), a dumpvars cache, and finishing incremental singleton emit
  (phony done; androidmk next). See `EXPLAINER.md`.

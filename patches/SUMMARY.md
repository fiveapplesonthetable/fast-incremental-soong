# Warm-incremental Soong — patch summary

Goal: edit an `Android.bp`, regenerate `build.ninja` in O(edit) instead of
re-analyzing the whole tree, **byte-identical to a clean build**. All numbers below
are measured on real AOSP (`aosp_cf_x86_64_phone-trunk_staging-userdebug`,
soong-only, `m nothing`), edit on **`frameworks/base/Android.bp`** (the realistic
worst case). Every warm result was verified `cmp`-identical to a cold resident
rebuild of the same edited tree (every ninja + `.mk` shard).

## Enabling

One environment variable on an otherwise-normal build:

```sh
SOONG_PERSISTENT_REUSE_GRAPH=true m nothing   # first build cold (starts daemon)
#   …edit an Android.bp…
SOONG_PERSISTENT_REUSE_GRAPH=true m nothing   # warm: O(edit), byte-identical
```

## The gating invariant (why this is mergeable and safe)

Every warm-specific manifest divergence (content-addressed shard assignment,
sharded incremental subninja, separate phonys subninja, order-only-dedup recompute)
is gated behind `residentNinjaLayout()` (the resident-mode flag). Therefore:

- **A non-resident / cold build is byte-identical to upstream Soong.** The upstream
  Blueprint unit tests pass unchanged. Applying the patch does not change a normal
  build (including a Kati-enabled Pixel `m`).
- **A warm resident rebuild is byte-identical to a cold resident rebuild** of the
  same edited tree. That is the guarantee that the incremental analysis is exact.
- The resident manifest layout differs from stock by design (content-addressed
  sharding is what makes the O(edit) delta write possible), so the byte-gate's
  ground truth is a *resident* cold build.

## Measured (frameworks/base/Android.bp, soong-only)

| edit | reparse | singletons | delta write | byte-identical |
|---|--:|---|---|:--:|
| property edit | 0.40 s | kept | 13 modules regenerated; 34/50 ninja + 50/50 incr shards skipped | yes |
| add a module | 0.49 s | re-run | 47/50 ninja + 50/50 incr shards skipped; phonys kept | yes |
| remove a module | 0.47 s | re-run | 47/50 ninja + 49/50 incr skipped; removed module's shard force-rewritten | yes |

Reparse is one changed file (~0.4 s) versus a full-tree reparse (~4–5 s at AOSP
scale). The manifest write is O(edit): only shards containing a changed module are
rewritten. On an **add/remove** the warm cost is dominated by **singleton
regeneration** (a membership change re-runs whole-graph aggregations like the
module-info and phony singletons); a **property edit keeps singletons** and is
cheaper.

Two subtle correctness mechanisms keep warm == cold for these too: (1) order-only
dedup is recomputed from immutable inputs every build, and a clean module whose
emitted order-only flips because a shared key crossed the dedup threshold is forced
to re-serialize (no stale shard); (2) singleton phony contributions are recomputed
fresh, and the pure-add phony fold is taken only when they are unchanged, else the
phony makefile is rebuilt fully.

## How it works

A resident `soong_build` server keeps the resolved+mutated Blueprint graph and
caches in RAM across builds. On a warm edit:
1. reparse ONLY the changed `.bp` files (not all 14k),
2. diff vs the resident baseline → changed / added / removed module sets,
3. re-mutate only the affected closure (skip the ~34 s whole-tree mutator pass),
4. regenerate only dirty modules + provider-interface-changed dependents,
5. delta-write: rewrite only the shards containing a changed module.

Anything the incremental path can't represent (an unsupported mutator, a structural
change it can't prove neutral, a changed product config) returns
`ErrFallbackToFullBuild` and does a full cold rebuild, logged `WARM-FALLBACK:
<reason>` — so the output is always correct. Requires the daemon: a batch/no-daemon
design cannot skip parse+mutate because it has nothing in memory to skip to.

## Patch contents

build/soong (base f389fa2a2):
  cmd/soong_build/persistent.go   resident server (client/server over unix sock)
  cmd/soong_build/main.go         runBuildReuse warm path + changed-file reparse + WARM-FALLBACK
  ui/build/{soong,ninja,ninja_resident,config}.go  soong_ui wiring
  android/{phony,singleton,singleton_module,namespace}.go  singleton/phony incremental support
  docs/*                          design + tutorial

build/blueprint (base c39c8a4):
  incremental_mutation.go         the engine: baselines, DiffParsedModules,
                                  ChangedBlueprintFiles, re-mutation strategies
  incremental_ninja.go            NEW FILE: the resident-mode *Context additions
                                  (graph residency, content-addressed shard layout,
                                  O(edit) delta write) — kept out of context.go so the
                                  feature is additive and merges cleanly
  context.go                      thin call-sites into incremental_ninja.go + the
                                  residentNinjaLayout() gate (stock path unchanged)
  incremental_mutation_test.go    byte-identical edit corpus
  ninja_defs.go, provider.go, singleton_ctx.go, name_interface.go, …  supporting

## Add/remove cost: where the ~24 s goes, and the incremental-singleton fold

A property edit keeps singletons and is cheap. An **add/remove** is a membership
change, so the whole-graph singletons re-run. Measured breakdown of an f/b add's
~24 s regen+write:

```
generateSingletonBuildActions  19.5 s   (the dominant cost)
  phony (serial)               11.5 s  -> 8.0 s with the per-module fold below
  parallel singleton batch     ~5.7 s   (59 singletons, run concurrently)
  soongonlyandroidmk (serial)   2.8 s
manifest write                  5.3 s
module generation              0.06 s
```

The **phony singleton now folds incrementally** (`android/phony.go`,
`moduleContrib` per-module contribution cache + `keyOwners` inverted index, fed by
new `VisitRegeneratedModuleProxies` / `IncrementalRemovedKeys` /
`IncrementalModuleKey` plumbing): a membership change re-derives only the phony keys
whose contributors actually changed, byte-identically. It drops phony 11.5 s → 8 s.

The residual 8 s is because an unrelated add still **regenerates**
`framework-minus-apex-install-dependencies` — its `CalculateHashTolerant` property
hash differs across the throwaway re-parse (a known re-parse non-determinism the
diff already partly guards), so it is flagged "changed" and its ~3000-key phony is
re-sorted. The real lever to make adds *fast* is therefore upstream of the
singleton: make the re-parse property hash deterministic / add a deep-equal
false-positive guard so an add is genuinely **pure**; the phony fold then collapses
to ms, and module generation drops too. The remaining singletons (`androidmk`, the
parallel batch) each need the same per-module fold to reach single-digit add.

## Not done yet / honest caveats

- An **add/remove** is dominated by singleton regeneration (~22–24 s) — see above.
  The phony fold is the first incremental singleton; the others are future work,
  and the highest-leverage fix is the pure-add diff guard.
- The full `m` wall still carries product-config (`dumpvars`, ~2.5 s) and a
  stock-`ninja` manifest reload, which are separate processes. A resident ninja
  (n2) and a dumpvars cache would remove them; the `ui/build/ninja_resident.go`
  here is unverified.
- Byte-identity verified for property edit / add / remove on
  `frameworks/base/Android.bp`, soong-only, on `aosp_cf_x86_64_phone`. **Not** an
  exhaustive edit-class corpus, and **not** yet verified on Kati / vendor / Pixel
  (with the env off, those builds are unaffected; with it on, unsupported cases
  fall back to a correct full rebuild — see the gating invariant).
- LOCAL, experimental work; NOT in upstream AOSP and NOT pushed anywhere.

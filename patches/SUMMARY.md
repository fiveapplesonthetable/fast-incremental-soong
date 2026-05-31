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
| add a module | 0.49 s | 65/66 probe-skipped | 47/50 ninja + 50/50 incr shards skipped; phonys kept | yes |
| remove a module | 0.47 s | re-run | 47/50 ninja + 49/50 incr skipped; removed module's shard force-rewritten | yes |

Reparse is one changed file (~0.4 s) versus a full-tree reparse (~4–5 s at AOSP
scale). The manifest write is O(edit): only shards containing a changed module are
rewritten. On an **add** the warm cost used to be dominated by **singleton
regeneration** (a membership change re-runs whole-graph aggregations); the
**contribution probe** now skips the singletons the added module doesn't surface,
dropping the f/b add's regenerate+write from 17.2 s to ~6.2 s (65 of 66 singletons
skipped, byte-identical). A **property edit keeps singletons** and is cheaper. A
**remove** does not yet probe-skip (a removal subtracts a contribution the probe
cannot observe) — see below.

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
  incremental_singleton_probe.go  NEW FILE: the singleton contribution probe (skip
                                  whole-graph singletons an add doesn't surface),
                                  the genuinely-changed probe set (tolerant
                                  provider-value hash), the probeContributor interface
  context.go                      thin call-sites into incremental_ninja.go + the
                                  residentNinjaLayout() gate + the singleton probe
                                  membership gate (stock path unchanged)
  incremental_mutation_test.go    byte-identical edit corpus
  ninja_defs.go, provider.go, singleton_ctx.go, name_interface.go, …  supporting

## Add/remove cost: where the ~24 s goes, and the incremental-singleton fold

A property edit keeps singletons and is cheap. An **add/remove** is a membership
change, so the whole-graph singletons re-run. A **singleton contribution probe** now
skips the ones the added module doesn't actually surface, and the manifest write was
made O(edit), dropping the f/b add regen+write from **17.2 s to ~6.2 s**,
byte-identical (467/467 shards). On the f/b `cc_defaults` add, **65 of 66 singletons
are skipped** -- testsuites (5.5 s), soongonlyandroidmk (2.9 s), all_teams,
artifact_path all skip; only `bootstrap` genuinely re-runs. Current breakdown:

```
singleton probe   ~2.5 s  throwaway singleton runs over {changed-set} (+ {empty-set}
                          only for the few that emit over the added module). NOT lock
                          contention: soong's OncePer is a lock-free sync.Map. The
                          floor is GC pressure from the per-run allocation (the same
                          thing that caps the real singleton pass at ~5x parallelism).
manifest write    ~2.4 s  the O(tree) shardModulesStable assignment (~0.7 s, inline
                          FNV) + sort (~0.2 s) + writing the 1-2 dirty shards. The
                          shard write and the order-only dedup are now O(edit) (the
                          dedup is cached across a no-op add).
bootstrap + misc  ~0.6 s
```

### The contribution probe

A whole-graph singleton's output is a per-module aggregation, so on a pure add
`S(old ∪ added) = S(old)` iff the added modules contribute nothing to `S`. The probe
decides that per singleton, soundly for additive singletons: run `S` twice in a
throwaway context that commits nothing -- once over the genuinely-changed modules,
once over the empty set -- and keep its resident build actions when the two
emitted-output hashes match. Comparing against the **empty-set baseline** (not "did
it emit anything") is what lets a singleton such as `testsuites`, which touches its
internal maps for every module but only emits per test suite, be skipped on the add
of a non-test module.

Two subtleties made it work:
- **Probe set = genuinely-changed modules**, keyed by a *tolerant* provider-value
  hash. The non-tolerant hash that flags a module "changed" includes the Go funcs
  carried by `Configurable`, so it differs run-to-run; a module like
  `framework-minus-apex-install-dependencies` is a re-parse-hash false positive that
  must drop out of the probe set, or it pins every singleton that reads it.
- **Side-effect-free probe.** The soong `singletonAdaptor` runs the inner singleton
  over the restricted set in a fresh `singletonContextAdaptor` whose buildParams/
  dists/phonies are never committed, and against a throwaway `singletonInfo` so
  `SetProvider` lands on a discard target.

The probe is gated behind `membershipChanged` (warm resident add/remove only), so
cold / non-resident / stock builds are byte-identical to upstream.

Caveat: the probe is exact for **additive** singletons. A *relational* singleton --
one whose per-module output depends on the presence of OTHER modules and is empty for
the added module in isolation -- could in principle change while the probe sees
nothing; none is known in the tree and the byte-gate polices it for every edit under
test.

The **phony singleton folds incrementally** (`android/phony.go`, `moduleContrib`
per-module contribution cache + `keyOwners` inverted index, fed by new
`VisitRegeneratedModuleProxies` / `IncrementalRemovedKeys` / `IncrementalModuleKey`
plumbing): a membership change re-derives only the phony keys whose contributors
actually changed, byte-identically. It drops phony from ~11.5 s to a 2.4 s residual.

That 2.4 s residual is because an unrelated add still **regenerates**
`framework-minus-apex-install-dependencies` — its `CalculateHashTolerant` property
hash differs across the throwaway re-parse (the `Configurable` `inner` pointer-chain
is rebuilt structurally-distinct, so the content hash differs even though the .bp
text is unchanged), so it is flagged "changed" and its ~3000-key phony is re-sorted.
The clean fix is a deterministic re-parse hash or a deep-equal false-positive guard
in `DiffParsedModules` so an add is genuinely **pure**; the phony fold then collapses
to ms.

The phony fold predates the probe and is now mostly subsumed by it (on the f/b add,
phony is one of the 65 probe-skipped singletons); it remains as the incremental path
for the rare singleton the probe can't skip.

### Why sub-second add/remove is NOT yet reached, and what is left

The singleton wall — the cost that made add/remove expensive — is gone: 65/66
singletons skip and the 11.3 s of re-aggregation collapses to a 4.3 s probe + ~1 s.
With the write then made O(edit) (below), the f/b add is **~6.2 s** byte-identical,
two near-equal costs left, each a further CL:

1. **Probe overhead ~3.3 s.** The probe is 132 throwaway singleton runs that serialise
   on soong's per-config `Once` lock (the same contention that caps the *real*
   singleton pass at ~5x parallelism — parallelising the probe loop alone did not
   help). Two levers: cache the empty-set baseline across builds (halves the run
   count) and reduce the `Once` contention (helps the real pass too).
2. **Write ~3.5 s.** The shard write is now O(edit) (below); what remains is the
   global `deduplicateOrderOnlyDeps` (~1.1 s, cacheable on a no-op add) and the
   single O(tree) `shardModulesStable` assignment pass (~1 s, cacheable across builds).

### The write made O(edit)

The delta write was already shard-skipping (only shards holding a changed module are
rewritten), but three things kept it O(tree) on an add. All now fixed, byte-identical:

- **Shard-dirtiness keys off the genuinely-changed set** (provider output actually
  changed, from the probe) rather than the full regenerated set, so the
  re-parse-hash false positive `framework-minus-apex` no longer forces its large
  shard to be rewritten.
- **Dirty shard indices come from that bounded changed set** (`dirtyShardSet`) instead
  of scanning every module's shard; `stableShardIndex` uses an inline allocation-free
  FNV-1a, so the 2x100k per-module shard assignment stops allocating a hasher per call.
- **The singletons subninja** (~40 % of the manifest) is hashed and left untouched when
  unchanged — the common case once the probe has kept all but a few singletons.

Plus **finer sharding** (`SOONG_NINJA_SHARDS=500`): a module's shard is now ~210
modules instead of ~2 100, so rewriting the one shard a 1-module add dirties costs
~10x less. Net: regenerate+write 9.8 s → ~7.4 s, 467/467 shards byte-identical.

So sub-second needs: cache the order-only dedup and the shard assignment on an
unchanged-contribution add, plus cut the probe's `Once` serialisation. Discrete,
byte-gated follow-ups.

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

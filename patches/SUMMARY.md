# Warm-incremental Soong — patch summary

Goal: edit an `Android.bp`, regenerate `build.ninja` in O(edit) instead of
re-analyzing the whole tree. All numbers below are **measured on real AOSP**
(`aosp_cf_x86_64_phone-trunk_staging-userdebug`), and every warm result was
verified **byte-identical** to a cold rebuild of the same edited tree (`cmp`,
403/403 manifest shards).

## Measured (real frameworks/base edit: services.core.unboosted)

| phase                         | cold    | warm (this patch) |
|-------------------------------|--------:|------------------:|
| reparse                       |   ~5 s  | **0.40 s**        |
| mutate + generate + write     | ~126 s  | **4.0 s**         |
| **soong analysis (ninja gen)**| **131 s** | **4.4 s  (~30x)** |
| total `m nothing` wall        | 136 s   | 17.8 s            |
| byte-identical to cold        |   —     | **yes**           |

Ninja *generation* (producing the updated build.ninja) is single-digit seconds.
The remaining wall (17.8 s) is NOT soong analysis anymore — it is dumpvars
(~2.5 s) and `ninja` reloading the 5.6 GB manifest cold (~5.1 s), which are
separate processes (see "Not done yet").

## How it works

A resident `soong_build` server (`SOONG_PERSISTENT_REUSE_GRAPH=true`) keeps the
resolved+mutated Blueprint graph and caches in RAM across builds. On a warm edit:
1. reparse ONLY the changed .bp files (not all 14k),
2. diff vs the resident baseline → dirty module set,
3. re-mutate only the affected closure (skip the ~34 s whole-tree mutator pass),
4. regenerate only dirty modules + provider-interface-changed dependents,
5. delta-write: rewrite only the ninja shards containing a changed module.

Requires the daemon — a batch/no-daemon design cannot skip parse+mutate because
it has nothing in memory to skip to.

## Patch contents

build/soong (10 files, +1560/-13), base f389fa2a2:
  cmd/soong_build/persistent.go   resident server (client/server over unix sock)
  cmd/soong_build/main.go         runBuildReuse warm path + changed-file reparse
  ui/build/{soong,ninja,ninja_resident,config}.go  soong_ui wiring
  android/singleton_module.go     graph-residency state reset
  docs/*                          design + tutorial

build/blueprint (23 files, +6262/-144), base c39c8a4:
  incremental_mutation.go         the engine: baselines, DiffParsedModules,
                                  ChangedBlueprintFiles, re-mutation strategies
  context.go                      delta + SHARDED ninja write, generate worklist
  incremental.go, metrics, etc.   supporting
  incr/ (~8 files)                SEPARATE experimental native-emitter prototype
                                  (bpgen-in-blueprint); tangential to warm soong.

## My fixes this session (~125 lines) that made the prior scaffolding actually work

The prior resident-server work was committed but had never run a real edit
end-to-end on AOSP. Testing it on real AOSP (not its synthetic tests) exposed:
- **nil-map crash**: BeginIncrementalBuild (which inits posShiftedModules) ran
  AFTER DiffParsedModules wrote it -> panic on the first line-shifting edit.
  Fixed by reordering. (main.go)
- **23 s write**: the 2.9 GB incremental-modules subninja was rewritten WHOLE on
  any edit. Sharded it like the main modules -> write became O(edit), 23 s -> 4 s.
  (context.go)
- **4.4 s reparse**: still parsed all 14k .bp to find the change. Added
  ChangedBlueprintFiles (hash on-disk vs snapshot) + parse only changed -> 0.4 s.
  (incremental_mutation.go + main.go)

## Not done yet / honest caveats

- "Single-digit" is ninja GENERATION (4.4 s). The full `m` wall (17.8 s) needs:
  resident ninja (n2) to avoid the 5.6 GB manifest reload (~5.1 s), and dumpvars
  caching (~2.5 s). The ui/build/ninja_resident.go in this patch is unverified.
- ADD/REMOVE a module falls back to a full ~136 s rebuild (whole-tree singleton
  aggregations are not incremental yet).
- Byte-identity verified for property edits to existing modules (a leaf cc_binary
  and frameworks/base services.core.unboosted). Not a full edit-class corpus.
- This is LOCAL, experimental work; NOT in upstream AOSP and NOT pushed anywhere.

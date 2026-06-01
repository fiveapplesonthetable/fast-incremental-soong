# Next project: the end-to-end warm-build wall (the ~24 s `m nothing`)

The soong **analysis** (regenerate+write) is now sub-second to ~1.6 s and byte-identical
(see README/SUMMARY). But a warm `m nothing` on `frameworks/base/Android.bp` still walls
at **~24 s**. None of that residual is the soong analysis this repo optimized — it is the
soong_ui *infrastructure* around it. A sub-second regen the user waits 24 s for is not
felt. Closing this gap is the highest-impact remaining work, and it is **its own project**
(separate from the analysis work, and partly outside the AOSP tree). This note scopes it.

## Where the ~24 s goes (one warm `m nothing`)

| phase | ~time | what it is | in-tree? |
|---|--:|---|---|
| Kati **dumpvars** | ~2.5 s | product-config: re-evaluates the product makefiles every build | yes (Go/Kati) |
| bootstrap.ninja regen + **glob** check | ~1–2 s | re-checks globs, regenerates the bootstrap manifest | yes (Go) |
| **soong_build** analysis | **~0.8–1.6 s** | the part this repo made O(edit) — DONE | yes (Go) |
| Kati **packaging** | ~0 s* | `initializing packaging system` / `writing packaging rules` — *but dist-set-gated: skipped on ordinary edits* (see below) | yes (Kati) |
| **ninja reload** | ~5 s | stock `ninja`/`n2` re-parses the 5.6 GB manifest into RAM to find nothing to do | **no** (Rust/C++ executor) |
| process spawn / IO / misc | ~rest | microfactory checks, env files, touches | yes |

The two dominant non-analysis costs are the **ninja reload (~5 s)** and the **soong_ui
floor: dumpvars (~2.5 s)**. The EXPLAINER (ch. 60–63) calls soong_ui-floor
caching the single highest-ROI fix.

## Kati packaging is dist-set-gated — it is *not* an always-on cost

An earlier draft listed Kati packaging as a fixed ~3–4 s tax on every warm build. That
is wrong, and the correction matters for prioritization. Measured on
`frameworks/base/Android.bp`, `aosp_cf_x86_64_phone-trunk_staging-userdebug`,
soong-only, resident soong_build (`SOONG_PERSISTENT_REUSE_GRAPH=true`):

| edit | wall | dist.mk | Kati packaging |
|---|--:|---|---|
| no-change `m nothing` (×4) | ~10–12 s | md5 stable | **never runs** |
| add a `cc_defaults` (×3, +revert ×3) | ~18 s add / ~13.5 s revert | md5 **unchanged** | **never runs** |

**Mechanism.** soong_ui runs `runKatiPackage(soongOnly=true)` over
`build/make/packaging/main_soong_only.mk` (`build/soong/ui/build/build.go:372`). Kati's
own ninja-stamp staleness check decides whether to re-run the packaging pass, and its
sole input trigger is **whether `out/soong/kati_packaging-*/dist.mk` changed**. That file
(`build/soong/android/androidmk.go:820–849`) is two sorted-unique lines —
`DIST_SRC_DST_PAIRS` + `DIST_GOAL_OUTPUT_PAIRS` — derived **only** from modules'
dist-for-goals contributions, and written through `writeValueIfChanged` (writes only when
the content actually differs, so mtime-only churn never triggers a regen).

**Consequence.** `dist.mk` changes — and packaging re-runs (~29 s when it does) — *only*
when the dist-for-goals **set** changes: a module that explicitly `dist:`s an artifact, or
one that joins a dist goal (e.g. a test entering `general-tests`). Adding/removing or
editing an ordinary module — defaults, library, binary, **even an installable one** —
does **not** change `dist.mk`, because *install ≠ dist*. So for the overwhelmingly common
warm edit, the packaging pass is skipped outright and the residual e2e cost is the ninja
reload + dumpvars, not packaging.

**Implication for the roadmap.** Incrementalizing the Kati packaging step (re-emit rules
only for the changed dist entries) is real work, but it is the **rarest** trigger and is
already gated correctly — when it fires it is doing legitimate work, not spinning on
spurious mtime churn. It is therefore lower-ROI than the two always-on costs below, and
should come after them (or be subsumed by completing the SOONG_ONLY migration so soong
emits packaging natively/incrementally rather than shelling out to Kati).

## Critical finding: the resident-ninja path is plumbed but non-functional

`build/soong/ui/build/ninja_resident.go` already implements the *soong side* of a resident
ninja: with `SOONG_USE_N2=true` + `SOONG_PERSISTENT_REUSE_GRAPH`, it spawns `n2 --serve
<sock>` and talks to a long-lived n2 that holds the parsed graph in RAM, so each build
re-reads only the top-level manifest + the one changed shard (splice) instead of the whole
5.6 GB.

**But the prebuilt n2 has no `--serve` mode** (real flags: `-C -f -d -t -j --frontend-file
-k -v`; the "resident" strings in the binary are jemalloc stats). And **n2's source is not
in the AOSP tree** (it's a prebuilt under `prebuilts/build-tools/*/bin/n2`; upstream is
`github.com/evmar/n2`, Rust). So today the resident path starts a server that never becomes
ready and, after a **4-minute** wait, falls back — i.e. enabling it makes a build ~8 min
*slower*, not faster. The ninja-reload lever is therefore **blocked on external Rust work**.

## The two pieces, scoped

### A. Resident ninja executor — kills the ~5 s reload (external Rust)
- Fetch n2 source; add a `--serve <unix-socket>` mode: load the manifest once at startup,
  then on each request re-stat the top-level manifest + subninjas, **splice** only the
  shard whose mtime changed (soong's delta write already leaves the rest mtime-unchanged),
  rebuild the requested targets, reply. Keep the graph + stat cache resident between
  requests.
- Build the patched n2; replace the prebuilt (or ship as an opt-in alt binary).
- The soong side is **already done** (`ninja_resident.go`); it just needs an n2 that
  answers `--serve`. Add a fast capability probe so a non-serve n2 falls back instantly
  instead of waiting 4 min (a ~10-line soong fix worth doing regardless).
- Estimate: **~1–2 weeks** (the splice + resident graph is the hard part; ch. 33).
- Risk: medium. Correctness is easy to gate — the resident n2's output must be byte/behavior
  identical to a cold n2 run of the same manifest (a `cmp`-style gate like the analysis one).

### B. soong_ui floor caching — kills the ~2.5 s dumpvars (in-tree Go)
- Hash the inputs to Kati dumpvars (the product-config makefiles + env); on a hit, skip the
  run and reuse the cached output. Worst-case failure is a cache miss → current behavior, so
  it's safe by construction. (Packaging is already self-gated on `dist.mk` and skips on
  ordinary edits — see the dist-set section above — so it is not part of this lever.)
- Contained to `build/soong/ui/build/`; no executor changes.
- Estimate: **~2–3 weeks** (dumpvars first — highest ROI, most contained; packaging next).
- Risk: medium — product-config correctness is subtle; needs a "same dumpvars output as a
  cold run" gate.

## Recommended order
1. The ~10-line soong fix so the broken resident path falls back instantly (stops the 8-min
   penalty when `SOONG_USE_N2` is set). Trivial, do first.
2. **B (soong_ui floor / dumpvars caching)** — in-tree, no external dep, biggest contained
   win. Lands a warm `m nothing` from ~24 s to ~10–12 s. (Kati packaging is NOT on this
   path — it already self-skips on ordinary edits.)
3. **A (resident n2 `--serve`)** — external Rust, removes the last big chunk (~5 s reload),
   getting the warm inner loop to "a couple of seconds" — analysis (sub-second) + spawn.

Neither requires touching the analysis work, which is complete and byte-verified.

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
| Kati **packaging** | ~3–4 s | `initializing packaging system` / `distdir.mk` / `writing packaging rules` | yes (Kati) |
| **ninja reload** | ~5 s | stock `ninja`/`n2` re-parses the 5.6 GB manifest into RAM to find nothing to do | **no** (Rust/C++ executor) |
| process spawn / IO / misc | ~rest | microfactory checks, env files, touches | yes |

The two dominant non-analysis costs are the **ninja reload (~5 s)** and the **soong_ui
floor: dumpvars + packaging (~6–7 s)**. The EXPLAINER (ch. 60–63) calls soong_ui-floor
caching the single highest-ROI fix.

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

### B. soong_ui floor caching — kills the ~6–7 s dumpvars + packaging (in-tree Go)
- Hash the inputs to Kati dumpvars (the product-config makefiles + env) and to the
  packaging pass; on a hit, skip the run and reuse the cached output. Worst-case failure is
  a cache miss → current behavior, so it's safe by construction.
- Contained to `build/soong/ui/build/`; no executor changes.
- Estimate: **~2–3 weeks** (dumpvars first — highest ROI, most contained; packaging next).
- Risk: medium — product-config correctness is subtle; needs a "same dumpvars output as a
  cold run" gate.

## Recommended order
1. The ~10-line soong fix so the broken resident path falls back instantly (stops the 8-min
   penalty when `SOONG_USE_N2` is set). Trivial, do first.
2. **B (soong_ui floor / dumpvars caching)** — in-tree, no external dep, biggest contained
   win. Lands a warm `m nothing` from ~24 s to ~10–12 s.
3. **A (resident n2 `--serve`)** — external Rust, removes the last big chunk (~5 s reload),
   getting the warm inner loop to "a couple of seconds" — analysis (sub-second) + spawn.

Neither requires touching the analysis work, which is complete and byte-verified.

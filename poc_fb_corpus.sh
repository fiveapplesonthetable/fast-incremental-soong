#!/bin/bash
# Correctness corpus: verify the warm property-edit path is byte-identical to a cold
# resident rebuild across DIFFERENT edit/propagation kinds on frameworks/base/Android.bp.
#   reorder  - reorder a filegroup's srcs (consumer reads the new order: provider propagation)
#   defaults2- add javacflags to a 2nd, chained java_defaults (defaults-consumer closure)
#   direct   - add javacflags directly to a java_library (base case, no propagation)
# For each: cold warm-up -> apply edit -> warm rebuild (snapshot) -> cold rebuild (truth)
# -> cmp every ninja+mk shard. Asserts ENGAGED (REUSING, not WARM-FALLBACK) and DIFF=0.
set -u
cd /home/zim/dev/aosp
export TARGET_PRODUCT=aosp_cf_x86_64_phone TARGET_RELEASE=trunk_staging TARGET_BUILD_VARIANT=userdebug
export SOONG_NINJA_SHARDS=${SOONG_NINJA_SHARDS:-500}
BP=frameworks/base/Android.bp
SOCK=out/soong/.soong_build_persistent.sock
GLOB='out/soong/build.aosp_cf_x86_64_phone.*.ninja'

apply_edit() {
  case "$1" in
    reorder)
      # Swap two adjacent filegroup srcs; the consumers compile them in order.
      python3 - "$BP" <<'PY'
import sys
p=sys.argv[1]; L=open(p).read().split('\n')
a=L.index('        ":framework-blobstore-sources",')
L[a],L[a+1]=L[a+1],L[a]
open(p,'w').write('\n'.join(L))
PY
      ;;
    defaults2)
      # Add a javacflag to a 2nd, chained java_defaults consumed by the framework.
      python3 - "$BP" <<'PY'
import sys,re
p=sys.argv[1]; s=open(p).read()
s=s.replace('    name: "framework-minus-apex-with-libs-defaults",\n    defaults: ["framework-minus-apex-defaults"],',
            '    name: "framework-minus-apex-with-libs-defaults",\n    defaults: ["framework-minus-apex-defaults"],\n    javacflags: ["-Apoc.libs.marker=1"],')
open(p,'w').write(s)
PY
      ;;
    direct)
      # Add a javacflag DIRECTLY to a java_library (not via defaults).
      python3 - "$BP" <<'PY'
import sys
p=sys.argv[1]; s=open(p).read()
s=s.replace('    name: "framework-minus-apex-intdefs",',
            '    name: "framework-minus-apex-intdefs",\n    javacflags: ["-Apoc.direct.marker=1"],',1)
open(p,'w').write(s)
PY
      ;;
  esac
}

gate() {
  local name="$1" snap="/mnt/agent/poc_corpus_$1"
  echo "######## EDIT: $name ########"; date +%T
  pkill -f 'soong_build.*--persistent' 2>/dev/null; sleep 2; rm -f "$SOCK" "$SOCK.log" out/.lock
  git -C frameworks/base checkout Android.bp 2>/dev/null
  SOONG_PERSISTENT_REUSE_GRAPH=true build/soong/soong_ui.bash --make-mode nothing >/tmp/poc_co_${name}_A.log 2>&1; echo "  A(cold warmup) exit=$?"
  local before=$(grep -c "poc\.\|framework-blobstore" "$BP")
  apply_edit "$name"
  echo "  edit applied (changed=$(! cmp -s <(git -C frameworks/base show HEAD:Android.bp) "$BP" && echo yes || echo NO-OP))"
  SOONG_PERSISTENT_REUSE_GRAPH=true build/soong/soong_ui.bash --make-mode nothing >/tmp/poc_co_${name}_C.log 2>&1; echo "  C(warm) exit=$?"
  grep -aiE "REUSING|WARM-FALLBACK|regenerate\+write took|changed,|added|removed" "$SOCK.log" 2>/dev/null | tail -3 | sed 's/^/    /'
  rm -rf "$snap"; mkdir -p "$snap"; cp $GLOB "$snap/" 2>/dev/null; cp out/soong/soong_phony_targets.*.mk "$snap/" 2>/dev/null
  pkill -f 'soong_build.*--persistent' 2>/dev/null; sleep 2; rm -f "$SOCK" "$SOCK.log"
  SOONG_PERSISTENT_REUSE_GRAPH=true build/soong/soong_ui.bash --make-mode nothing >/tmp/poc_co_${name}_D.log 2>&1; echo "  D(cold truth) exit=$?"
  local DIFF=0 TOTAL=0
  for f in "$snap"/*.ninja "$snap"/*.mk; do [ -e "$f" ]||{ echo "  NOSNAP"; break; }; b=$(basename "$f"); TOTAL=$((TOTAL+1)); cmp -s "$f" "out/soong/$b"||{ DIFF=$((DIFF+1)); echo "    DIFFERS: $b"; }; done
  local fb=""; grep -qa "WARM-FALLBACK" /tmp/poc_co_${name}_C.log 2>/dev/null && fb=" (WARM-FALLBACK!)"
  echo "  RESULT[$name]: shards=$TOTAL differing=$DIFF$fb"
  git -C frameworks/base checkout Android.bp 2>/dev/null
}

for e in reorder defaults2 direct; do gate "$e"; done
echo "######## CORPUS DONE ########"

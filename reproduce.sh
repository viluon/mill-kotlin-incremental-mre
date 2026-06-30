#!/usr/bin/env bash
# Reproduces a spurious Kotlin "Unresolved reference" produced by Mill's
# Build Tools API (BTAPI) incremental compilation when classes/ and inc-state/
# diverge.
#
# Divergence is created with REAL Mill operations only:
#   1. a successful compile (classes/ + inc-state/ consistent),
#   2. a second compile that is INTERRUPTED mid-flight (the workspace daemon is
#      SIGKILLed, modelling the daemon restart that a concurrent second Mill
#      invocation -- e.g. `just set-up-idea` running next to `just build` --
#      triggers). Kotlin's non-incremental compile deletes all class outputs
#      first, so the interruption leaves classes/ torn.
#   3. The prior successful build's inc-state/ is put back, modelling the
#      surviving concurrent daemon whose inc-state was never overwritten by the
#      killed run. inc-state/ now records every source as compiled, while
#      classes/ is missing outputs.
#
# A subsequent incremental compile of an edited consumer then trusts inc-state/,
# does not recompile the un-edited producer, and fails to resolve the producer's
# symbol whose .class is absent.
set -euo pipefail
cd "$(dirname "$0")"

MILL=./mill
DEST=out/foo/compile.dest
CLASSES=$DEST/classes
INC=$DEST/inc-state
BAK=$(mktemp -d)
trap 'git checkout -- foo/src/foo/Consumer1.kt foo/src/foo/Consumer2.kt 2>/dev/null || true; rm -rf "$BAK"' EXIT

daemon_pid() {
  for p in $(pgrep -f 'mill-daemon|MillDaemonMain' 2>/dev/null); do
    [ "$(readlink "/proc/$p/cwd" 2>/dev/null)" = "$PWD/out/mill-daemon/sandbox" ] && { echo "$p"; return; }
  done
}

echo "== 1. clean successful build (classes/ + inc-state/ consistent) =="
rm -rf out
$MILL foo.compile >/dev/null
S0=$(find "$CLASSES" -name '*.class' | wc -l)
echo "   classes: $S0"
cp -a "$INC" "$BAK/inc-state.ok"

echo "== 2. interrupt a rebuild mid-flight (SIGKILL daemon == daemon restart) =="
# Force the non-incremental path (delete-all-then-write) and re-run the task.
rm -f "$INC/shrunk-classpath-snapshot.bin"
echo '// edit to re-run the compile task' >> foo/src/foo/Consumer1.kt
attempt=0
while :; do
  attempt=$((attempt + 1))
  $MILL foo.compile >/dev/null 2>&1 &
  launcher=$!
  # The non-incremental compile deletes every class output first, then re-flushes
  # them. Wait for that delete-all window (ProducerKt.class gone while the daemon
  # is still running), then SIGKILL launcher+daemon to freeze classes/ torn.
  for _ in $(seq 1 300); do
    if [ ! -f "$CLASSES/foo/ProducerKt.class" ]; then
      kill -9 "$launcher" 2>/dev/null || true
      d=$(daemon_pid || true); [ -n "${d:-}" ] && kill -9 "$d" 2>/dev/null || true
      break
    fi
    kill -0 "$launcher" 2>/dev/null || break
    sleep 0.02
  done
  kill -9 "$launcher" 2>/dev/null || true
  wait "$launcher" 2>/dev/null || true
  d=$(daemon_pid || true); [ -n "${d:-}" ] && kill -9 "$d" 2>/dev/null || true
  sleep 0.3
  if [ ! -f "$CLASSES/foo/ProducerKt.class" ]; then
    echo "   torn after $attempt attempt(s): classes=$(find "$CLASSES" -name '*.class' | wc -l), ProducerKt.class MISSING"
    break
  fi
  [ "$attempt" -ge 40 ] && { echo "could not tear classes/"; exit 1; }
done

echo "== 3. restore prior build's inc-state (surviving concurrent daemon) =="
rm -rf "$INC"
cp -a "$BAK/inc-state.ok" "$INC"
# Consumer1 was only edited to re-run the torn build; put it back so it matches
# inc-state (clean) and the sole dirty file below is Consumer2.
git checkout -- foo/src/foo/Consumer1.kt 2>/dev/null || true

echo "== 4. incremental compile of an edited consumer (expected to FAIL) =="
echo 'fun extra() = bar' >> foo/src/foo/Consumer2.kt
$MILL foo.compile >"$BAK/out.log" 2>&1 || true
if grep -q "Unresolved reference" "$BAK/out.log"; then
  echo "   REPRODUCED: $(grep -m1 "Unresolved reference" "$BAK/out.log" | sed 's/.*\[error\] //')"
  echo "   (producer is clean in inc-state, but its .class is absent in classes/)"
else
  echo "   did not reproduce"; cat "$BAK/out.log"; exit 1
fi

echo "== 5. recovery: a clean build succeeds (proves stale state, not bad source) =="
git checkout -- foo/src/foo/Consumer1.kt foo/src/foo/Consumer2.kt 2>/dev/null || true
rm -rf out
$MILL foo.compile >/dev/null && echo "   clean build OK"

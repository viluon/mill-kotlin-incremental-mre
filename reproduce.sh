#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

dest=out/foo/compile.dest
classes=$dest/classes
inc_state=$dest/inc-state
producer_class=$classes/foo/ProducerKt.class
scratch=$(mktemp -d)
trap 'git checkout -- foo/src/foo 2>/dev/null || true; rm -rf "$scratch"' EXIT

daemon_pid() {
  for p in $(pgrep -f 'mill-daemon|MillDaemonMain' 2>/dev/null); do
    [ "$(readlink "/proc/$p/cwd" 2>/dev/null)" = "$PWD/out/mill-daemon/sandbox" ] && { echo "$p"; return; }
  done
}

kill_mill() {
  kill -9 "$1" 2>/dev/null || true
  wait "$1" 2>/dev/null || true
  local daemon
  daemon=$(daemon_pid || true)
  [ -n "$daemon" ] && kill -9 "$daemon" 2>/dev/null || true
}

kill_mill_once_classes_deleted() {
  ./mill foo.compile >/dev/null 2>&1 &
  local launcher=$!
  for _ in $(seq 300); do
    [ -f "$producer_class" ] && kill -0 "$launcher" 2>/dev/null || break
    sleep 0.02
  done
  kill_mill "$launcher"
  sleep 0.3
}

echo "== 1. clean build"
rm -rf out
./mill foo.compile >/dev/null
cp -a "$inc_state" "$scratch/inc-state"

echo "== 2. kill daemon during non-incremental rebuild"
for attempt in $(seq 40); do
  rm -f "$inc_state/shrunk-classpath-snapshot.bin"
  echo '//' >> foo/src/foo/Consumer1.kt
  kill_mill_once_classes_deleted
  [ -f "$producer_class" ] || break
done
[ -f "$producer_class" ] && { echo "classes/ never torn"; exit 1; }
echo "   torn after $attempt attempt(s), $(find "$classes" -name '*.class' | wc -l) classes left"

echo "== 3. restore inc-state from step 1"
rm -rf "$inc_state"
cp -a "$scratch/inc-state" "$inc_state"
git checkout -- foo/src/foo/Consumer1.kt

echo "== 4. incremental compile after editing Consumer2"
echo 'fun extra() = bar' >> foo/src/foo/Consumer2.kt
if ./mill foo.compile >"$scratch/log" 2>&1 || ! grep -q "Unresolved reference" "$scratch/log"; then
  echo "   did not reproduce"; cat "$scratch/log"; exit 1
fi
echo "   REPRODUCED: $(grep -m1 "Unresolved reference" "$scratch/log" | sed 's/.*\[error\] //')"

echo "== 5. clean build succeeds"
git checkout -- foo/src/foo
rm -rf out
./mill foo.compile >/dev/null && echo "   OK"

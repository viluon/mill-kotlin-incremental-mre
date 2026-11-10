> [!WARNING]
> MRE done by Copilot, Claude Opus 4.8.

# Spurious `Unresolved reference` after interrupted Kotlin compile

Mill's BTAPI incremental Kotlin compile trusts `inc-state/` even when `classes/` lost outputs to an interrupted compile.

## Repro

```sh
./reproduce.sh
```

```
Consumer2.kt:3:22 Unresolved reference 'bar'.
```

Fails on Mill 1.3.1 with Kotlin 2.4.21 and 2.5.0-Beta2. `bar` is a top-level `val` in `Producer.kt`; `rm -rf out` fixes the build.

The script:

1. compiles cleanly and backs up `inc-state/`,
2. SIGKILLs the daemon during a non-incremental rebuild, after it deleted `classes/` but before it rewrote them,
3. restores the backed-up `inc-state/`, as a surviving concurrent daemon would leave it,
4. edits `Consumer2.kt` and compiles incrementally.

In practice a second Mill invocation restarting the daemon mid-compile triggers it. The 200 consumers widen the kill window.

## Cause

Non-incremental compiles delete all of `classes/` first and write `inc-state/` last, non-atomically. The next incremental compile diffs sources against `inc-state/`, recompiles only the edited file and never checks that `Producer.kt`'s outputs exist.

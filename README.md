# Mill BTAPI incremental Kotlin compile gives spurious "Unresolved reference"

Mill's Kotlin Build Tools API (BTAPI) incremental compilation can report a bogus
`Unresolved reference` for a symbol that exists in the sources, when a compile is
interrupted mid-flight and a later compile reuses the torn output.

A clean rebuild (`rm -rf out`) compiles fine, proving the sources are correct and
the failure is stale incremental state, not bad code.

> [!WARNING]
> MRE done by Copilot, Claude Opus 4.8.

## Versions

- Mill `1.2.0-RC1-24-042146`
- Kotlin `2.3.21`
- `kotlincUseBtApi = true`, `kotlinUseEmbeddableCompiler = true`

## Repro

```
./reproduce.sh
```

Ends with:

```
Consumer2.kt:2:20 Unresolved reference 'bar'.
```

`bar` is a top-level `val` in `Producer.kt`, same package as the consumer, no
import needed. A clean rebuild then succeeds.

## What goes wrong

A BTAPI compile mutates `compile.dest` in place and non-atomically:

- the destination is `compile.dest/classes/`, the incremental state is
  `compile.dest/inc-state/`;
- a non-incremental compile **deletes every class output first**, then re-flushes
  the classfiles, and writes the `inc-state/` metadata **last**.

If the process dies during that window the `classes/` dir is left torn while a
previous successful build's `inc-state/` survives. `inc-state/` then records every
source as compiled even though outputs are missing. A later incremental compile
uses `SourcesChanges.ToBeCalculated`, diffs sources against `inc-state/`,
recompiles only the edited consumer, and never checks that the un-edited
producer's `.class` is actually present — so the consumer compiles against a
missing symbol.

In production this is triggered by a daemon restart: a second Mill invocation
(e.g. `just set-up-idea` started next to `just build`) makes the launcher stop the
daemon mid-compile.

## What `reproduce.sh` does

All steps use real Mill operations; the only thing staged is the interleaving that
a concurrent daemon would produce:

1. compile cleanly (`classes/` + `inc-state/` consistent), back up `inc-state/`;
2. force a non-incremental rebuild and stop the workspace daemon mid-flight
   (SIGKILL) — Kotlin's delete-all-first leaves `classes/` torn (producer `.class`
   gone);
3. restore the backed-up `inc-state/` — modelling the surviving concurrent daemon
   whose `inc-state/` the stopped run never overwrote;
4. edit one consumer and recompile incrementally → spurious `Unresolved reference`;
5. `rm -rf out` and rebuild → succeeds.

The ~200 trivial consumers only widen the interruption window in step 2.

## Expected

Incremental compilation should detect that a non-dirty source's output is missing
(or invalidate when `inc-state/` and `classes/` disagree) and recompile, instead
of emitting a spurious unresolved-reference error. More robustly, BTAPI output
should be written atomically so an interrupted compile cannot leave `classes/` and
`inc-state/` inconsistent.

## Files

- `build.mill` — `foo` KotlinModule, BTAPI incremental on
- `foo/src/foo/Producer.kt` — defines top-level `val bar`
- `foo/src/foo/Consumer*.kt` — reference `bar`
- `reproduce.sh` — deterministic reproduction
- `mill` — stock upstream launcher

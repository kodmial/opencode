# Low-Memory Coding Runtime

## Goal

Reduce measured memory pressure in the stripped headless coding runner so a real coding workload can complete reliably inside a 512 MiB, no-swap cgroup, and keep that profile honest and re-measurable.

Baseline evidence lives in Runtime Lab #126 / PR #129. The corrected stripped run peaked at `538173440` and `538189824` bytes against `memory.max=536870912` with `oom_kill=0` and `memory.events.max` at `2042`/`1952` — the system was in reclaim constantly but never killed. The `820383744`-byte unconstrained run is contaminated and is not a comparison point.

The target is a whole-service cgroup peak at or below 450 MiB with a correct completed workload and no OOM/restart. Agent-only RSS is not a sufficient claim.

## Approach

Disk-first. The transcript already has a durable store and a tool-output directory, so the work is moving bytes out of the resident heap rather than deleting capability:

1. Load only the context that is actually active. History that a compaction boundary already discarded is never hydrated, let alone sent to the model.
2. Do not materialize the whole provider catalog to use one provider.
3. Externalize large tool output earlier, and stop re-hydrating output that pruning has already cleared.
4. Keep compaction's own bookkeeping from allocating proportional to the transcript.

Provider functionality required by the selected coding model is unchanged. Correctness is verified by the existing suites plus new tests, not by weakening assertions.

## Measurement

Per-allocation-site numbers come from a script rather than from a hand-run. From `packages/opencode`:

```sh
bun run profile:catalog
```

It spawns one child process per mode so neither measurement inherits the other's heap growth, and reports both retained heap and materialized size. Current numbers on a 225-provider / 8,278-model models.dev payload:

| Variant                              | Providers | Materialized | Retained heap |
| ------------------------------------ | --------- | ------------ | ------------- |
| Eager full catalog (removed)         | 225       | 6.25 MiB     | 34.11 MiB     |
| Lazy single provider (current)       | 6         | 0.02 MiB     | under counter resolution |

The lazy view of one provider is small enough that its retained heap lands under the counter's resolution, which is why materialized size is the meaningful column here. A single 6.25 MiB allocation is not a service-fit claim: whole-service peak still needs a real 512 MiB no-swap run against a built artifact, which is Runtime Lab #130's job and is not claimed here.

## Changes

### Compaction-aware history loading

`MessageV2` gained a shared `compactionBoundary()` scanner over completed compaction parts. `streamActive()` pages newest-first and stops at the newest boundary, so `filterCompacted()` and the new `activeEffect()` agree by construction instead of by duplicated logic. `SessionPrompt.runLoop` now uses `activeEffect()`.

The practical effect is that pre-compaction history is not read out of SQLite and held in the heap on each provider turn.

### Lazy provider catalog

`Provider` used to run `mapValues(modelsDev, fromModelsDevProvider)` and then `mapValues(catalog, toPublicInfo)` at layer construction, converting every models.dev provider twice before any model was requested. Each provider is now converted on first use and memoized.

The raw and public views are deliberately separate caches. Initialization mutates the public one (model blacklists and whitelists, alpha/deprecated removal), and folding those mutations back into the catalog silently emptied `ModelNotFoundError` suggestions. `packages/opencode/test/provider/provider.test.ts` covers both halves of that contract.

Credential discovery reads env var names off the raw payload and never forces catalog materialization.

### Tool output externalization

`Truncate` reuses the existing tool-output directory and retention window. Low-memory runs (see below) cut the inline limit from `MAX_BYTES`/`MAX_LINES` to `LOW_MEMORY_MAX_BYTES`/`LOW_MEMORY_MAX_LINES`, so large results are written to disk and kept as a short preview plus a pointer.

`Truncate.output` also stops splitting the payload just to discover it fits. Counting separators first avoids duplicating every large tool result in the common case.

### Prune stops re-hydrating cleared output

Setting `part.state.time.compacted` left the payload in SQLite and in every later hydration, which is where the retained heap actually went. Prune now writes the full text to the tool-output directory once (when no `outputPath` was recorded already), then persists a placeholder inline. `MessageV2.COMPACTED_OUTPUT` is the single placeholder shared by model replay and compaction serialization, so a pruned part renders identically everywhere.

### Bounded compaction estimator

Tail selection only needs a size comparison against a token budget, but it built full model messages and then `JSON.stringify`-d the whole batch — a second and third copy of every retained string, at the moment memory is most constrained. It now walks the stored parts and sizes them directly, with a deliberately generous per-part overhead so a tail is never retained because the cheaper estimate undercounts.

### Low-memory runtime flag

`RuntimeFlags.lowMemory` is explicit via `OPENCODE_LOW_MEMORY` and defaults on for the stripped headless runner, which marks itself with `AGENT=1` and has no TUI to render a large inline preview. Interactive builds keep the existing limits, and `OPENCODE_LOW_MEMORY=0` forces them back on in a stripped run.

### CI-safe pre-push

`.husky/pre-push` now exits 0 with a message when `bun` is not on `PATH`. Automation pushes from runners that intentionally skip installing Bun, and a hook is not the place to fail a push over a missing dev dependency. The version check and `bun typecheck` still run when Bun is present.

## Validation

- `bun typecheck` in `packages/opencode` passes.
- `packages/opencode` full suite: 33 failures on this branch against 35 on a stashed baseline of the same tree. Both sets are subprocess spawn timeouts in this sandbox (ACP, `opencode serve`, read-only smoke, TUI thread, MCP add) unrelated to these changes; the branch set is a strict subset of the baseline set. Session suites are clean: 417 pass, 7 skip, 0 fail.
- `bun run profile:catalog` reports the table above.

## What Is Not Claimed

No whole-service 512 MiB qualification, no immutable artifact, and no service-fit statement. Those need a real no-swap cgroup run against a built Linux x64 coding artifact, coordinated with Runtime Lab #130.

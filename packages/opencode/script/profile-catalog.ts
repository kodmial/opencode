// Measures the heap cost of provider catalog materialization, which used to be
// the largest single allocation at coding-worker startup: every models.dev
// provider was converted with fromModelsDevProvider() and then a second time
// through toPublicInfo() before a single model was requested.
//
// A real coding worker holds credentials for one provider, so the number that
// matters is what the old eager path cost (whole catalog) against what the lazy
// path costs (one provider).
//
// Each mode runs in its own process so neither measurement inherits the other's
// heap growth. Run from packages/opencode:
//   bun run profile:catalog
//   MEASURE_PROVIDER=openai bun run profile:catalog
// Pass --expose-gc for retained-heap numbers:
//   bun --expose-gc run script/profile-catalog.ts
import path from "path"
import { mapValues } from "remeda"
import { Global } from "@opencode-ai/core/global"
import { Flag } from "@opencode-ai/core/flag/flag"
import type { Provider } from "@opencode-ai/core/models-dev"
import { fromModelsDevProvider, toPublicInfo } from "@/provider/provider"

const MODE = Bun.env.MEASURE_MODE ?? "compare"
const TARGET = Bun.env.MEASURE_PROVIDER ?? "anthropic"

const source = Flag.OPENCODE_MODELS_URL || "https://models.opencode.ai"
const file =
  Flag.OPENCODE_MODELS_PATH ??
  path.join(Global.Path.cache, source === "https://models.opencode.ai" ? "models.json" : `models-${source}.json`)
const raw = (await Bun.file(file).json()) as Record<string, Provider>

if (global.gc) global.gc()
const before = process.memoryUsage().heapUsed

// Old eager path: every provider converted, then every provider re-serialized
// and schema-checked through toPublicInfo.
const eager = MODE === "eager" ? mapValues(mapValues(raw, fromModelsDevProvider), toPublicInfo) : undefined
// New lazy path: only the provider this worker has credentials for.
const lazy = MODE === "lazy" ? toPublicInfo(fromModelsDevProvider(raw[TARGET]!)) : undefined

if (global.gc) global.gc()
const retained = (process.memoryUsage().heapUsed - before) / 1024

if (MODE === "compare") {
  const run = async (mode: string) => {
    const proc = Bun.spawn([process.execPath, "--expose-gc", "run", import.meta.path], {
      cwd: import.meta.dir + "/..",
      env: { ...Bun.env, MEASURE_MODE: mode, MEASURE_PROVIDER: TARGET },
      stdout: "pipe",
      stderr: "pipe",
    })
    const out = await new Response(proc.stdout).text()
    const err = await new Response(proc.stderr).text()
    if (!out.includes("RETAINED_KB")) throw new Error(`mode ${mode} failed:\n${out}\n${err}`)
    const field = (name: string) => Number(new RegExp(`^${name}[= ](.+)$`, "m").exec(out)![1])
    return { retainedKb: field("RETAINED_KB"), serializedKb: field("SERIALIZED_KB"), providers: field("providers") }
  }

  const providerIDs = Object.keys(raw)
  const rawModels = providerIDs.reduce((total, id) => total + Object.keys(raw[id]!.models).length, 0)
  const eager = await run("eager")
  const lazy = await run("lazy")
  const mib = (kb: number) => `${(kb / 1024).toFixed(2)} MiB (${kb.toFixed(1)} KiB)`

  console.log(`models.dev payload: ${providerIDs.length} providers, ${rawModels} models`)
  console.log(`measuring:          ${TARGET}`)
  console.log("")
  console.log(`                          providers  materialized   retained heap`)
  console.log(
    `eager full catalog (removed)  ${String(eager.providers).padStart(9)}  ${mib(eager.serializedKb).padStart(14)}  ${mib(eager.retainedKb).padStart(14)}`,
  )
  console.log(
    `lazy single provider (current) ${String(lazy.providers).padStart(9)}  ${mib(lazy.serializedKb).padStart(14)}  ${mib(lazy.retainedKb).padStart(14)}`,
  )
  console.log("")
  console.log(
    `avoided at startup: ${mib(eager.serializedKb - lazy.serializedKb)} of materialized catalog (${((1 - lazy.serializedKb / eager.serializedKb) * 100).toFixed(1)}% less)`,
  )
  console.log("")
  console.log("The lazy view of one provider is small enough that its retained heap lands under")
  console.log("the counter's resolution, so the materialized size is the meaningful column.")
  console.log("")
  console.log("This isolates one allocation site. Whole-service cgroup peak still requires a")
  console.log("real 512 MiB no-swap run against the built artifact; see perf/low-memory.md.")
} else {
  // Touch the result so it is not collectable across the second gc. The lazy
  // view of one provider is small enough to land under the heap counter's
  // resolution, so materialized size is the meaningful column.
  const materialized = MODE === "eager" ? eager! : lazy!
  console.log(`providers=${Object.keys(materialized).length}`)
  console.log(`SERIALIZED_KB ${(JSON.stringify(materialized).length / 1024).toFixed(1)}`)
  console.log(`RETAINED_KB ${retained.toFixed(3)}`)
}

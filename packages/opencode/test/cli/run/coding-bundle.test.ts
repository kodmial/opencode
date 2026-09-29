import { expect, test } from "bun:test"
import path from "node:path"

// Keep imports external to inspect the actual command's surviving edges,
// without loading a provider or requiring a terminal/native UI renderer.
async function bundle(coding: boolean) {
  const result = await Bun.build({
    entrypoints: [path.join(import.meta.dir, "../../../src/cli/cmd/run.ts")],
    target: "bun",
    format: "esm",
    external: ["*"],
    minify: { syntax: true },
    define: coding ? { "process.env.OPENCODE_CODING_ONLY": JSON.stringify("1") } : {},
  })
  expect(result.success).toBe(true)
  return result.outputs[0].text()
}

test("coding bundle removes both mini runtime imports and preserves the coding transport", async () => {
  const code = await bundle(true)
  expect(code).not.toContain('import("./run/runtime")')
  expect(code).toContain('import("@/server/server")')
  expect(code).toContain("Interactive mini mode is not available in the coding build")
})

test("ordinary bundle retains both interactive entry paths", async () => {
  const code = await bundle(false)
  expect(code.match(/import\("\.\/run\/runtime"\)/g)).toHaveLength(2)
})

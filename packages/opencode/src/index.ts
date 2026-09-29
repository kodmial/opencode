const defaults: Record<string, string> = {
  OPENCODE_CODING_ONLY: "1",
  OPENCODE_PURE: "1",
  OPENCODE_DISABLE_DEFAULT_PLUGINS: "1",
  OPENCODE_DISABLE_EXTERNAL_SKILLS: "1",
  OPENCODE_DISABLE_LSP_DOWNLOAD: "1",
  OPENCODE_DISABLE_EMBEDDED_WEB_UI: "1",
  OPENCODE_DISABLE_AUTOUPDATE: "1",
  OPENCODE_DISABLE_TERMINAL_TITLE: "1",
  OPENCODE_DISABLE_MODELS_FETCH: "1",
  OPENCODE_AUTO_SHARE: "0",
}

for (const [key, value] of Object.entries(defaults)) {
  if (process.env[key] === undefined) process.env[key] = value
}

// Set the low-memory profile before importing the OpenCode runtime graph.
// Several flags are captured at module initialization time, so doing this
// inside yargs middleware is too late.
await import("./coding-main")

#!/usr/bin/env bash
set -uo pipefail

OUT="${RUNNER_TEMP}/opencode-anonymous-zen-e2e"
mkdir -p "$OUT"

ISSUE_NUMBER="${ISSUE_NUMBER:?ISSUE_NUMBER is required}"
MODEL="${MODEL:?MODEL is required}"
SOURCE_SHA="${SOURCE_SHA:?SOURCE_SHA is required}"
ARTIFACT_ID="${ARTIFACT_ID:?ARTIFACT_ID is required}"
ARTIFACT_DIR="${ARTIFACT_DIR:?ARTIFACT_DIR is required}"

BIN="$ARTIFACT_DIR/opencode-coding-linux-x64"
CHECKSUM="$ARTIFACT_DIR/opencode-coding-linux-x64.sha256"
METADATA="$ARTIFACT_DIR/build-metadata.txt"
RUN_URL="https://github.com/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}"
TEST_COMMAND="python3 test_calc.py"

artifact_ok=false
binary_sha=""
version_out=""
minimal_exit=125
minimal_pass=false
minimal_response="not run"
coding_exit=125
coding_pass=false
file_edit=false
test_exit=125
runtime_invariants=fail
tools_observed="none"
notes=""

append_note() {
  if [[ -n "$notes" ]]; then notes+="; "; fi
  notes+="$1"
}

sanitize_tail() {
  local file="$1"
  if [[ ! -f "$file" ]]; then
    printf '%s' "missing output"
    return
  fi
  tail -c 1000 "$file" \
    | tr '\r\n' '  ' \
    | sed -E 's/(authorization|api[-_ ]?key|token|cookie)[=:][^ ]+/<redacted>/Ig' \
    | cut -c1-700
}

if [[ -x "$BIN" && -f "$CHECKSUM" && -f "$METADATA" ]]; then
  expected_sha="$(awk '{print $1}' "$CHECKSUM" | head -1)"
  binary_sha="$(sha256sum "$BIN" | awk '{print $1}')"
  meta_sha="$(awk -F= '$1=="source_sha" {print $2}' "$METADATA" | tail -1)"
  if [[ -n "$expected_sha" && "$binary_sha" == "$expected_sha" && "$meta_sha" == "$SOURCE_SHA" ]]; then
    artifact_ok=true
  else
    append_note "artifact identity mismatch: expected source=$SOURCE_SHA metadata=${meta_sha:-missing} bundled_sha=${expected_sha:-missing} actual_sha=${binary_sha:-missing}"
  fi
else
  append_note "artifact files missing or binary not executable"
fi

if [[ "$artifact_ok" == true ]]; then
  version_out="$($BIN --version 2>&1)"

  unset OPENCODE_API_KEY OPENAI_API_KEY ANTHROPIC_API_KEY
  export OPENCODE_PURE=1

  set +e
  timeout 180 "$BIN" run --model "$MODEL" "Reply with exactly: MUSE13_OK" >"$OUT/minimal.stdout" 2>"$OUT/minimal.stderr"
  minimal_exit=$?
  set -e
  if [[ "$minimal_exit" -eq 0 ]] && grep -Fq "MUSE13_OK" "$OUT/minimal.stdout"; then
    minimal_pass=true
  else
    append_note "minimal model request failed"
  fi
  minimal_response="$(sanitize_tail "$OUT/minimal.stdout")"
  if [[ "$minimal_response" == "missing output" || -z "$minimal_response" ]]; then
    minimal_response="$(sanitize_tail "$OUT/minimal.stderr")"
  fi

  REPO="$RUNNER_TEMP/muse13-repo"
  rm -rf "$REPO"
  mkdir -p "$REPO"
  cd "$REPO"
  git init -q
  git config user.name "E2E fixture"
  git config user.email "e2e@example.invalid"
  cat > calc.py <<'PY'
def add(a, b):
    return a - b
PY
  cat > test_calc.py <<'PY'
from calc import add

assert add(2, 3) == 5, f"expected 5, got {add(2, 3)}"
print("TEST_OK")
PY
  git add calc.py test_calc.py
  git commit -qm "fixture"

  PROMPT='Inspect this repository, find why the test fails, fix the implementation by editing the repository file through your normal tools, run python3 test_calc.py, and finish only when the test passes. Do not merely describe the fix.'

  set +e
  timeout 300 "$BIN" run --format json --model "$MODEL" "$PROMPT" >"$OUT/coding.stdout" 2>"$OUT/coding.stderr" &
  run_pid=$!

  (
    while kill -0 "$run_pid" 2>/dev/null; do
      queue="$run_pid"
      seen=""
      while [[ -n "$queue" ]]; do
        pid="${queue%% *}"
        queue="${queue#${pid}}"
        queue="${queue# }"
        [[ " $seen " == *" $pid "* ]] && continue
        seen+=" $pid"
        ps -o pid=,ppid=,rss=,comm=,args= -p "$pid" 2>/dev/null || true
        children="$(pgrep -P "$pid" 2>/dev/null | tr '\n' ' ' || true)"
        [[ -n "$children" ]] && queue+=" $children"
      done
      echo "---"
      sleep 0.25
    done
  ) >"$OUT/processes.log" &
  sampler_pid=$!

  wait "$run_pid"
  coding_exit=$?
  kill "$sampler_pid" 2>/dev/null || true
  wait "$sampler_pid" 2>/dev/null || true
  set -e

  git diff -- calc.py test_calc.py >"$OUT/repo.diff"
  if ! git diff --quiet -- calc.py test_calc.py; then
    file_edit=true
  else
    append_note "agent produced no repository edit"
  fi

  set +e
  python3 test_calc.py >"$OUT/test.stdout" 2>"$OUT/test.stderr"
  test_exit=$?
  set -e

  if [[ "$coding_exit" -eq 0 && "$file_edit" == true && "$test_exit" -eq 0 ]]; then
    coding_pass=true
  else
    append_note "coding loop did not complete successfully"
  fi

  tools_observed="$({
    grep -Eo '"tool"[[:space:]]*:[[:space:]]*"[^"]+"' "$OUT/coding.stdout" 2>/dev/null \
      | sed -E 's/.*"tool"[[:space:]]*:[[:space:]]*"([^"]+)"/\1/'
    grep -Eo '"name"[[:space:]]*:[[:space:]]*"(read|write|edit|apply_patch|bash|shell|grep|glob)"' "$OUT/coding.stdout" 2>/dev/null \
      | sed -E 's/.*"name"[[:space:]]*:[[:space:]]*"([^"]+)"/\1/'
  } | sort -u | paste -sd, -)"
  [[ -n "$tools_observed" ]] || tools_observed="not-extracted"

  if grep -Eiq '(opentui|parser\.worker|typescript-language-server|pyright-langserver|language-server|prettier.*--write|eslint.*--fix|@opencode-ai/plugin.*install)' "$OUT/processes.log"; then
    runtime_invariants=fail
    append_note "prohibited UI/LSP/formatter/plugin-install process signature observed"
  else
    runtime_invariants=pass
  fi
fi

result="FAIL"
if [[ "$artifact_ok" == true && "$minimal_pass" == true && "$coding_pass" == true && "$runtime_invariants" == pass ]]; then
  result="PASS"
elif [[ "$artifact_ok" == true && "$minimal_pass" == true ]]; then
  result="PARTIAL"
fi

jq -n \
  --arg RESULT "$result" \
  --arg ARTIFACT_ID "$ARTIFACT_ID" \
  --arg SOURCE_SHA "$SOURCE_SHA" \
  --arg BINARY_SHA256 "$binary_sha" \
  --arg MODEL "$MODEL" \
  --arg AUTH_MODE "anonymous/no API key" \
  --arg MINIMAL_REQUEST "$([[ "$minimal_pass" == true ]] && echo pass || echo fail)" \
  --arg MINIMAL_EXIT_CODE "$minimal_exit" \
  --arg MINIMAL_RESPONSE "$minimal_response" \
  --arg CODING_LOOP "$([[ "$coding_pass" == true ]] && echo pass || echo fail)" \
  --arg TOOLS_OBSERVED "$tools_observed" \
  --arg FILE_EDIT_CONFIRMED "$([[ "$file_edit" == true ]] && echo yes || echo no)" \
  --arg TEST_COMMAND "$TEST_COMMAND" \
  --arg TEST_EXIT_CODE "$test_exit" \
  --arg RUNTIME_INVARIANTS "$runtime_invariants" \
  --arg ACTIONS_RUN "$RUN_URL" \
  --arg NOTES "${notes:-none}" \
  --arg VERSION "$version_out" \
  '{RESULT:$RESULT,ARTIFACT_ID:$ARTIFACT_ID,SOURCE_SHA:$SOURCE_SHA,BINARY_SHA256:$BINARY_SHA256,MODEL:$MODEL,AUTH_MODE:$AUTH_MODE,MINIMAL_REQUEST:$MINIMAL_REQUEST,MINIMAL_EXIT_CODE:$MINIMAL_EXIT_CODE,MINIMAL_RESPONSE:$MINIMAL_RESPONSE,CODING_LOOP:$CODING_LOOP,TOOLS_OBSERVED:$TOOLS_OBSERVED,FILE_EDIT_CONFIRMED:$FILE_EDIT_CONFIRMED,TEST_COMMAND:$TEST_COMMAND,TEST_EXIT_CODE:$TEST_EXIT_CODE,RUNTIME_INVARIANTS:$RUNTIME_INVARIANTS,ACTIONS_RUN:$ACTIONS_RUN,NOTES:$NOTES,VERSION:$VERSION}' \
  >"$OUT/result.json"

printf 'result=%s\n' "$result" >> "$GITHUB_OUTPUT"
printf 'result_dir=%s\n' "$OUT" >> "$GITHUB_OUTPUT"

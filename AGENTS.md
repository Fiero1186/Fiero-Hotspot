# Agent Execution Guidelines

## 1. Zero Unsolicited Scaffolding (Strict)
- NEVER generate test harnesses, mock stubs, synthetic test suites, or driver scripts unless the user explicitly commands it in the prompt.
- Do not create scratch files, temporary shell scripts, `.test-*` directories, or sandbox harnesses.

## 2. In-Place Modifications
- Apply edits directly to target repository files.
- Do not create duplicate files (e.g., `script_under_test.sh` or `.bak` files).

## 3. Minimal Process Execution
- Do not spawn persistent background subshells or run synthetic system validation internally.
- Use `bash -n` only if a syntax sanity-check is needed; let the user test actual runtime behavior.
- Strictly adhere to a "No Scaffolding" policy. Keep reasoning loops focused strictly on direct code diffs.

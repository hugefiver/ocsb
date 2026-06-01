# Hermes Gateway Service Control Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add in-container `service gateway start|stop|restart|status` control for Hermes sandboxes.

**Architecture:** Add a Hermes-only `service` helper package installed in the sandbox. Both Hermes templates route their background daemon through the helper's `gateway supervise` mode, while users call `service gateway ...` inside the container. The helper stores pid/enabled state under `$HERMES_HOME` and restarts by launching `hermes gateway run --replace`.

**Tech Stack:** Nix flake packaging, Hermes Nix templates, shell helper, Bash regression tests, README docs.

---

### Task 1: Add Failing Source-Only Tests

**Files:**
- Modify: `tests/test_hermes_agent.sh`
- Inspect: `flake.nix`
- Inspect: `templates/hermes-agent.nix`
- Inspect: `templates/hermes-agent-nix-config.nix`

- [ ] **Step 1: Add source-only mode**

Add optional `--source-only` handling near the top of `tests/test_hermes_agent.sh` so source assertions can run without a built Hermes wrapper:

```bash
SOURCE_ONLY=0
if [[ "${1:-}" == "--source-only" ]]; then
  SOURCE_ONLY=1
  shift
fi

WRAPPER="${1:-}"
if [[ "$SOURCE_ONLY" != "1" ]]; then
  if [[ -z "$WRAPPER" ]]; then
    echo "Usage: $0 [--source-only] <path-to-ocsb-hermes-binary>" >&2
    exit 2
  fi
fi
```

- [ ] **Step 2: Add assertions for service helper wiring**

Read repository source files and assert these strings exist:

```bash
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FLAKE_TEXT="$(cat "$REPO_ROOT/flake.nix")"
HERMES_TEMPLATE_TEXT="$(cat "$REPO_ROOT/templates/hermes-agent.nix")"
HERMES_NIX_CONFIG_TEMPLATE_TEXT="$(cat "$REPO_ROOT/templates/hermes-agent-nix-config.nix")"

assert_contains "source: helper package defines service binary" "$FLAKE_TEXT" 'writeShellScriptBin "service"'
assert_contains "source: service command supports gateway start" "$FLAKE_TEXT" 'service gateway start|stop|restart|status'
assert_contains "source: restart uses upstream replace" "$FLAKE_TEXT" 'hermes gateway run --replace'
assert_contains "source: helper stores gateway state under HERMES_HOME" "$FLAKE_TEXT" '"$HERMES_HOME/service/gateway"'
assert_contains "template: daemon uses service gateway supervise" "$HERMES_TEMPLATE_TEXT" 'service gateway supervise'
assert_contains "template nix-config: daemon uses service gateway supervise" "$HERMES_NIX_CONFIG_TEMPLATE_TEXT" 'service gateway supervise'
assert_contains "template: installs Hermes service helper" "$HERMES_TEMPLATE_TEXT" 'hermesServicePackage'
assert_contains "template nix-config: installs Hermes service helper" "$HERMES_NIX_CONFIG_TEMPLATE_TEXT" 'hermesServicePackage'
```

- [ ] **Step 3: Skip runtime tests in source-only mode**

After source assertions, exit with the standard result summary when `SOURCE_ONLY=1`:

```bash
if [[ "$SOURCE_ONLY" == "1" ]]; then
  echo ""
  echo "=== hermes-agent source-only Results: $PASS passed, $FAIL failed ==="
  if [[ "$FAIL" -gt 0 ]]; then
    exit 1
  fi
  exit 0
fi
```

- [ ] **Step 4: Run RED test**

Run:

```bash
bash tests/test_hermes_agent.sh --source-only
```

Expected: FAIL because `flake.nix` does not define `writeShellScriptBin "service"`, and both templates still call `hermes gateway run --replace` directly.

### Task 2: Add Hermes Service Helper Package

**Files:**
- Modify: `flake.nix`

- [ ] **Step 1: Define `hermesServicePackage`**

Inside the package let-binding, add a `pkgs.writeShellScriptBin "service"` helper. It must parse exactly `service gateway start|stop|restart|status|supervise` and print usage for invalid commands.

- [ ] **Step 2: Implement state helpers**

The script must require `HERMES_HOME`, then use:

```bash
state_dir="$HERMES_HOME/service/gateway"
pid_file="$state_dir/pid"
enabled_file="$state_dir/enabled"
log_file="$HERMES_HOME/logs/gateway.log"
```

- [ ] **Step 3: Implement lifecycle commands**

`start` marks enabled, starts `hermes gateway run --replace` in the background when not already running, writes `$!` to `pid_file`, and logs to `log_file`.

`stop` removes enabled marker, kills live pid when present, and removes stale pid files.

`restart` runs stop with enabled disabled, then start; the start path must use `hermes gateway run --replace`.

`status` prints a single line containing `gateway`, `running` or `stopped`, and `enabled` or `disabled`.

`supervise` marks enabled, then runs `hermes gateway run --replace` in the foreground unless disabled; if disabled, it sleeps forever so the generic daemon supervisor does not spin.

### Task 3: Route Hermes Templates Through Helper

**Files:**
- Modify: `templates/hermes-agent.nix`
- Modify: `templates/hermes-agent-nix-config.nix`
- Modify: `flake.nix`

- [ ] **Step 1: Pass helper to both templates**

Change imports in `flake.nix` to inherit `hermesServicePackage` with `pkgs` and `hermesAgentPackage`.

- [ ] **Step 2: Extend template arguments**

Change both template function headers to accept `hermesServicePackage`.

- [ ] **Step 3: Install helper in both templates**

Add `hermesServicePackage` to each `packages` list.

- [ ] **Step 4: Replace daemon command**

In both templates, replace direct `hermes gateway run --replace > "$HERMES_HOME/logs/gateway.log" 2>&1` with:

```bash
exec service gateway supervise
```

Keep the `OCSB_HERMES_NO_GATEWAY=1` branch as `exec sleep infinity` and keep `restart = true` unchanged.

### Task 4: Document Commands

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Document in-container command surface**

Under Hermes Agent runtime docs, add:

```markdown
- 沙箱内提供 `service gateway start|stop|restart|status` 控制 Hermes gateway daemon；`restart` 会重新执行 `hermes gateway run --replace`。
- 状态保存在 `$HERMES_HOME/service/gateway/`，日志继续写 `$HERMES_HOME/logs/gateway.log`。
```

- [ ] **Step 2: Clarify wrapper flag relationship**

In the wrapper args section, document existing `--gateway`、`--replace`、`--no-gateway` and clarify the new `service gateway ...` command is for use inside the sandbox.

### Task 5: Verify

**Files:**
- Verify: `flake.nix`
- Verify: `templates/hermes-agent.nix`
- Verify: `templates/hermes-agent-nix-config.nix`
- Verify: `tests/test_hermes_agent.sh`
- Verify: `README.md`

- [ ] **Step 1: Run source-only Hermes tests**

Run:

```bash
bash tests/test_hermes_agent.sh --source-only
```

Expected: PASS.

- [ ] **Step 2: Run shell syntax check**

Run:

```bash
bash -n tests/test_hermes_agent.sh
```

Expected: PASS.

- [ ] **Step 3: Run lightweight Nix validation**

Run via the repo's Linux/Nix path if available:

```bash
nix flake check --no-build
```

Expected: PASS without locally compiling upstream Hermes.

- [ ] **Step 4: Run wrapper runtime test if wrapper exists**

If an already-built `ocsb-hermes` wrapper is available, run:

```bash
bash tests/test_hermes_agent.sh /path/to/ocsb-hermes
```

Expected: PASS. Do not locally build Hermes just to run this.

# OCSB Full Review Remediation Implementation Plan

> **For agentic workers:** Use the subagent-driven-development skill to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 修复 `master@a1968a5` 全仓审查确认的原始 18 项问题及最终复审新增的 4 项产品缺陷，并为每个场景保存精确、可归因的 RED/GREEN 证据。

**Architecture:** 先建立共享的私有 runtime/PID 身份原语和项目自有 mount-anchor helper，再按 backend、dual-layer、Hermes、Ironclaw、网络清理、架构输出和 CI 分域修复。最终复审 amendment 在既有实现上增加 receipt 的 retain-and-FD-retire 消费协议、由 held-state-FD cidfile 线性化的 immutable-ID OCI 事务、带 prepare/ready 与 generation/run-nonce decision CAS 的静态 sidecar gate、PATH-aware 原入口点恢复，以及同时覆盖 mutation-only 与 final helper 的继承 FD 身份交接；backend 和持久 OCI metadata 均不得接收 `/proc/*/fd/*`，所有数据库入口点副作用必须晚于已 fsync 的 commit decision 与 commit-ack 安全提交点。

**Tech Stack:** Nix flakes/module evaluation, C17/Linux syscalls (`openat2`, `unshare`, `mount`, `execve`), Nix-generated Bash, bubblewrap, Podman/systemd-nspawn adapters, `flock`, `/proc`, deterministic fake-runtime fixtures, GitHub Actions YAML.

**Global Constraints:**
- 基线固定为 `master@a1968a5`；实现开始时 working tree 只含已批准设计和本计划。
- 保持 bubblewrap 默认行为、非 bubblewrap v1 能力边界、Hermes/Ironclaw 持久化布局。
- 不改变 host network、direct workspace、host-daemon 或非 bubblewrap parity 的产品边界。
- 不重写 `mkSandbox`，不新增 runtime backend，不安装工具，不引入第三方依赖。
- 所有本地 Nix 操作由 `wsl.exe -d nixos -- bash -lc` 启动的 shell 执行。
- 本地不得构建 Hermes、Ironclaw、retained/arch external payload；只允许 flake eval/check、默认 ocsb、lightweight fixture/check。
- 默认 sidecar image 固定为 `docker.io/pgvector/pgvector:pg18@sha256:12a379b47ad65289572ea0756efc11b7c241a6662833e8af7038cd3b73d647e0`。
- 安全拒绝使用稳定前缀并包含失败对象，不输出 secret value。
- cleanup 在成功、失败、信号和 capability-skip 路径幂等；必须回收临时进程、文件、FIFO、mount namespace 和 fake OCI state。
- WSL launcher 测试使用 `env -u XDG_RUNTIME_DIR`，避免继承不可用的 `/run/user/1000`。
- Commit Guard 未授权 git 写入；本计划不包含 commit、push、tag 步骤。
- 最终复审 amendment 的本地证据根固定为 `/tmp/ocsb-remediation-2026-07-21-1000`，目录 mode `0700`，保留的日志和 manifest receipt mode `0444`。
- 最终复审 amendment 的 Nix fixture 必须从不含 `.git` 的完整 source snapshot 构建，以包含当前未跟踪的 Nix/C/fixture 文件；不得直接依赖 Git index 过滤。
- Podman sidecar 的每一次 OCI 调用都显式使用本地 `podman --remote=false`；Docker 继续受支持，但 native Podman 与 native Docker 生命周期证据必须来自两个独立 required CI job。
- Podman/Docker `create` 必须使用 held-state-dirfd 下由 `umask 077` 创建的唯一 `--cidfile`；任何 cleanup mutation 前都必须从该文件取得并验证 64-lower-hex ID 及 exact generation label。
- Sidecar gate 对含 `/` 的 `argv[0]` 使用 `execve`，对 bare `argv[0]` 按继承的 container `PATH` 确定性搜索且保持原 argv/envp；prepare 不能启动入口点，只有 mode-0600 `O_EXCL` generation/run-nonce decision CAS 的 commit winner 才能产生 commit-ack 并执行。
- `mkSandbox` 的 mutation-only helper 与 final mount-anchor helper 必须各自接收全部 inherited FD specs；两阶段均不得重新打开 public project/state/mount paths。
- Local RED/GREEN/contract commands must not pull or build external OCI images；the two clean native CI jobs alone explicitly pull the exact pinned pgvector digest before inspection/create and record provenance。
- 当前 native rootless Podman 与 local Docker lifecycle 证据尚不存在；在用户授权 push/workflow run 并取得两个 artifact 之前，最终验收只能报告 `native evidence pending`。

---

## Evidence and RED-Proof Protocol

不在仓库中创建或跟踪 RED/GREEN 日志。每次执行会话先建立私有临时证据目录：

```powershell
wsl.exe -d nixos -- bash -lc 'set -euo pipefail; E="${OCSB_REMEDIATION_EVIDENCE_DIR:-${TMPDIR:-/tmp}/ocsb-remediation-2026-07-21-$(id -u)}"; install -d -m 0700 "$E"; printf "%s\n" "$E"'
```

实现者在最终 handoff 报告该绝对路径。每个 Task 1–14 的 RED runner 必须遵守同一顺序：

1. `set -euo pipefail` 下完成 Nix build/eval、fixture 编译、目录创建和 barrier 初始化；任何 prerequisite 失败立即停止，不得生成 RED 结论。
2. 仅包围目标行为执行的最小区间使用 `set +e`，通过 `PIPESTATUS[0]` 捕获目标状态，然后立刻恢复 `set -e`。
3. 同时断言目标状态非零和该场景独有的 `FAIL[RED-...]` marker；其他 suite 失败、缺少 binary、fixture 编译失败或超时均不是有效 RED。
4. GREEN runner 断言场景独有的 `PASS[GREEN-...]` marker，并验证 cleanup receipt。
5. capability 不足只接受本计划列出的 `SKIP[CI-REQUIRED-...]` marker；CI 必须在有能力的 lane 补齐实际 GREEN，不能把普通错误分类为 SKIP。

## File Map

### 新建生产文件

- `pkgs/ocsb-mount-anchor.c` — 单一职责 C helper：建立私有 mount namespace，安全打开 source，创建 bind anchors，替换 argv placeholder，最终 `execve` backend。
- `pkgs/mount-anchor.nix` — 仅编译/安装 `ocsb-mount-anchor.c`，不引入仓库外依赖。
- `pkgs/ocsb-sidecar-gate.c` — 静态 gate：编码原 image argv/env、生成 stdin tar、验证真实 mount 身份、实现 prepare/ready + commit/abort decision CAS/acks，并以 `execve` 或确定性 PATH search 恢复原入口点。
- `pkgs/sidecar-gate.nix` — 使用 locked nixpkgs 的 `pkgsStatic` 构建 `ocsb-sidecar-gate`。
- `lib/runtime-process.nix` — 共享私有 runtime 目录、typed PID record、start-time/identity、full-line CAS helper。
- `lib/hermes-service.nix` — 提取 Hermes gateway service，并实现 reservation/claim/CAS 生命周期。
- `lib/ironclaw-master-key.nix` — 原子创建 Ironclaw master key。

### 修改生产文件

- `lib/mkSandbox.nix:39-52,54-69,83-128,243-310,313-520,552-727,973-1265,1271-1681` — helper closure/wiring、daemon、dual-layer、runtime/PID、mount manifest、ephemeral rootfs、slirp monitor。
- `scripts/hermes-wrapper.nix:1-16,211-396` — shared PID helper、persist/workspace identity、安全 `--replace`、caller-file/secret 拒绝。
- `scripts/ironclaw-wrapper.nix:15-19,289-456` — sidecar digest、persist lock、metadata labels/validation、并发初始化。
- `templates/ironclaw.nix:93-107` — 调用原子 key helper。
- `flake.nix:71-303,320-373,414-456` — Hermes service import、arch filtering、两个 dual-layer check outputs、仅供 backend integration CI 使用的 locked-nixpkgs `backend-test` dev shell（包含 Podman，不做 host 安装）。
- `.github/workflows/ci.yml:40-50,82-89,125-180` — core/fake/real-capability runtime gates。

### 新建测试文件

- `tests/test_mount_anchor.sh` — 三 backend deterministic post-open swap、nested symlink、remote/refusal 和 real-runtime secondary checks。
- `tests/fixtures/fake-anchor-runtime.c` — fork、关闭额外 FD、barrier 后交换原 source，并通过 backend argv source 读取 marker。
- `tests/test_dual_layer_host.sh` — 分别驱动默认 `/workspace` 和自定义 `/home/sandbox` fixtures。
- `tests/dual-layer-home-test.nix` — 自定义 sandboxDir 的独立 fixture。
- `tests/test_filtered_cleanup.sh` — deterministic fake monitor topology 和 real filtered secondary checks。
- `tests/fixtures/fake-filtered-bwrap.sh` — 写 info-fd、维持前台 PID/PGID、barrier 后退出成为待 reap 状态。
- `tests/fixtures/fake-slirp4netns.sh` — 记录 PPID/FD 状态，等待 monitor 信号并写退出 receipt。
- `tests/test_arch_outputs.sh` — aarch64/x86_64 attr assertions。
- `tests/test_failure_propagation.sh` — selective launcher exit `73` propagation。
- `tests/test_ci_runtime.sh` — CI command/skip contract。
- `tests/test_ironclaw_native_oci.sh` — 分离的 native rootless Podman 与 local Docker create/inspect/stop/restart/reuse 生命周期证明。

### 修改测试文件

- `tests/test_wrapper.sh:40-169,272-400` — focused `--case` mode、runtime clobber、路径拒绝、必需命令传播。
- `tests/test_backend.sh:43-179` — generic daemon、rootfs fake runtime、focused case selectors。
- `tests/test_git_worktree.sh:19-65` — nested symlink、真实退出码。
- `tests/test_btrfs.sh:44-85` — snapshot/snap-mount symlink、精确 capability SKIP、真实退出码。
- `tests/dual-layer-test.nix:5-12` 与 `tests/test_dual_layer.sh:47-165` — 默认目录 env 场景和 inner assertions。
- `tests/test_network.sh:29-85` — 显式公网 capability 结果。
- `tests/test_hermes_agent.sh:4-102,291-357` — fixture build modes、replace、caller secret、gateway barrier。
- `tests/test_ironclaw.sh:1-148,285-383` — lightweight wrapper、stateful fake OCI、deterministic lock barrier、key fixture。

### 不修改

- `README.md`、modules、`pkgs/ironclaw.nix`、`flake.lock`、`tests/net-test.nix`：本设计不改变公开 option、版本或依赖锁。
- 不创建 `docs/superpowers/evidence/`；临时日志和 manifest 全部位于 `$E`。

## Execution Order

Task 1 建立 PID 原语；Task 2 消费它修复 Hermes replace；Task 3 建立所有 backend 共同依赖的 mount anchor；Task 4–7 在前三项 GREEN 后执行；Task 8 消费 Task 1 的 record/CAS；Tasks 9–11 独立；Task 12 先消除假绿；Task 13 再验证 slirp-owning monitor；Task 14 接入 CI；Task 15 汇总原始 18 项验证。最终复审按依赖顺序执行：Task 16 先封闭 receipt 消费；Task 17 建立 gated OCI 生命周期；Task 18 复用 Task 3/16 的 helper 贯通 inherited-FD handoff；Task 19 最后接入分离 native CI、保留 artifacts，并生成独立于原始 18-row manifest 的复审 authority manifest。

### Task 1: Private Runtime Directory and Typed Process Records

**Covers:** runtime pidfile clobber（场景 2）。

**Files:**
- Create: `lib/runtime-process.nix`
- Modify: `lib/mkSandbox.nix:313-520,1271-1283,1524-1569,1652-1681`
- Modify: `tests/test_backend.sh:85-123`
- Modify: `tests/test_wrapper.sh:40-82`

**Interfaces:**
- Consumes: effective UID, canonical `STATE_BASE_DIR/WORKSPACE_NAME`, `/proc/$pid/{stat,status,comm,exe}`。
- Produces: `runtimeProcess.shellHelpers`; `ocsb_runtime_dir`, `ocsb_instance_digest`, `ocsb_process_record_path`, `ocsb_write_process_record`, `ocsb_validate_process_record`, `ocsb_remove_matching_process_record`; globals `OCSB_RECORD_PID/START/INSTANCE/LINE`。

- [ ] **Step 1: Add focused RED cases**

`tests/test_wrapper.sh "$OCSB_BIN" --case runtime-pidfile-clobber` creates mode-0700 controlled XDG dir, both legacy and typed pidfile symlinks pointing to a canary, then asserts launcher refuses and canary is unchanged. Baseline must print:

```text
FAIL[RED-runtime-pidfile-clobber]: launcher followed pidfile symlink and changed canary
```

`tests/test_backend.sh . --case process-record-schema` asserts strict four-field v1 schema, mode 0600, current UID, start-time equality, atomic rename and legacy rejection.

- [ ] **Step 2: Run exact RED**

```powershell
wsl.exe -d nixos -- bash -lc 'set -euo pipefail; cd /mnt/c/Users/hugefiver/source/ocsb; E="${OCSB_REMEDIATION_EVIDENCE_DIR:-${TMPDIR:-/tmp}/ocsb-remediation-2026-07-21-$(id -u)}"; install -d -m 0700 "$E"; OUT=$(nix build --no-link --print-out-paths .#packages.x86_64-linux.default); set +e; env -u XDG_RUNTIME_DIR bash tests/test_wrapper.sh "$OUT/bin/ocsb" --case runtime-pidfile-clobber 2>&1 | tee "$E/01-runtime-pidfile-red.log"; rc=${PIPESTATUS[0]}; set -e; test "$rc" -ne 0; grep -Fq "FAIL[RED-runtime-pidfile-clobber]: launcher followed pidfile symlink and changed canary" "$E/01-runtime-pidfile-red.log"'
```

- [ ] **Step 3: Implement strict shared helpers and reorder attach**

Record is exactly one mode-0600 regular file line:

```text
v1<TAB>PID<TAB>PROC_START_FIELD_22<TAB>64_LOWER_HEX_INSTANCE
```

Identity is SHA-256 of `role + NUL + canonical path`; filename is `process-$digest.pid`. XDG branch validates XDG parent then `$XDG_RUNTIME_DIR/ocsb`; fallback is `${TMPDIR:-/tmp}/ocsb-$(id -u)` and accepts only a current-UID safe parent or root-owned sticky temp parent. Final dir must be current UID, non-symlink, mode 0700. Write uses same-directory `mktemp`, `umask 077`, `chmod 0600`, `mv -T`; missing start time fails closed. Reader rejects symlink, non-regular, wrong owner/mode, malformed/legacy record, wrong instance, dead PID, or changed start time. Removal compares the full current line before unlinking.

Move option parsing and non-mutating state/instance calculation before attach. Both auto and explicit attach require the matching record; explicit PID can only equal recorded outer bwrap or its uniquely validated init child. Write immediately before bwrap exec and retain bounded startup retry.

- [ ] **Step 4: Run GREEN and integration**

```powershell
wsl.exe -d nixos -- bash -lc 'set -euo pipefail; cd /mnt/c/Users/hugefiver/source/ocsb; E="${OCSB_REMEDIATION_EVIDENCE_DIR:-${TMPDIR:-/tmp}/ocsb-remediation-2026-07-21-$(id -u)}"; OUT=$(nix build --no-link --print-out-paths .#packages.x86_64-linux.default); env -u XDG_RUNTIME_DIR bash tests/test_wrapper.sh "$OUT/bin/ocsb" --case runtime-pidfile-clobber 2>&1 | tee "$E/01-runtime-pidfile-green.log"; grep -Fq "PASS[GREEN-runtime-pidfile-clobber]: unsafe record rejected; canary unchanged" "$E/01-runtime-pidfile-green.log"; bash tests/test_backend.sh . --case process-record-schema | tee -a "$E/01-runtime-pidfile-green.log"'
```

Integration launches `runtime-one` and `runtime-two` concurrently and asserts distinct record names. Cleanup kills/waits both fixtures, removes controlled runtime files, verifies saved PIDs dead, then prints `CLEANUP PASS: runtime record fixtures`。

### Task 2: Hermes Replace Identity and Safe Termination

**Covers:** Hermes replace stale/cross-persist kill（场景 3）。

**Files:**
- Modify: `scripts/hermes-wrapper.nix:1-16,211-396`
- Modify: `tests/test_hermes_agent.sh:4-102,306-357`

**Interfaces:**
- Consumes: Task 1 helpers and canonical `$PERSIST_DIR/state/$HERMES_WORKSPACE_NAME`。
- Produces: `replace_running_sandbox RECORD INSTANCE`，只终止 exact bwrap PID/start/exe。

- [ ] **Step 1: Add fixture builder and RED identity cases**

`tests/test_hermes_agent.sh --build-lightweight-wrapper "$FIXTURE_DIR"` builds a fake inner launcher without upstream Hermes. Focused replace case creates legacy and typed records pointing to a live `sleep 60`, once with cross-persist digest and once with matching digest/non-bwrap executable. Baseline unique marker:

```text
FAIL[RED-hermes-replace-identity]: cross-persist or non-bwrap fixture was signaled
```

- [ ] **Step 2: Run exact RED**

```powershell
wsl.exe -d nixos -- bash -lc 'set -euo pipefail; cd /mnt/c/Users/hugefiver/source/ocsb; E="${OCSB_REMEDIATION_EVIDENCE_DIR:-${TMPDIR:-/tmp}/ocsb-remediation-2026-07-21-$(id -u)}"; install -d -m 0700 "$E"; F="$E/hermes-fixture"; LIGHT=$(bash tests/test_hermes_agent.sh --build-lightweight-wrapper "$F"); test -x "$LIGHT"; set +e; env -u XDG_RUNTIME_DIR bash tests/test_hermes_agent.sh --case replace-identity "$LIGHT" 2>&1 | tee "$E/02-hermes-replace-red.log"; rc=${PIPESTATUS[0]}; set -e; test "$rc" -ne 0; grep -Fq "FAIL[RED-hermes-replace-identity]: cross-persist or non-bwrap fixture was signaled" "$E/02-hermes-replace-red.log"'
```

- [ ] **Step 3: Canonicalize before replace and validate exact process**

Track last `-w|--workspace`, canonicalize persist before replace, derive same launcher digest, validate typed record, current UID, start time, `comm=bwrap`, and `/proc/$pid/exe == ${pkgs.bubblewrap}/bin/bwrap`. Recheck start immediately before signal and during wait. Missing/wrong/stale/non-bwrap record prints `ocsb-hermes: refusing --replace:` and returns nonzero. Five-second timeout refuses to launch the replacement.

- [ ] **Step 4: Run GREEN and integration**

```powershell
wsl.exe -d nixos -- bash -lc 'set -euo pipefail; cd /mnt/c/Users/hugefiver/source/ocsb; E="${OCSB_REMEDIATION_EVIDENCE_DIR:-${TMPDIR:-/tmp}/ocsb-remediation-2026-07-21-$(id -u)}"; install -d -m 0700 "$E"; F="$E/hermes-fixture"; LIGHT=$(bash tests/test_hermes_agent.sh --build-lightweight-wrapper "$F"); env -u XDG_RUNTIME_DIR bash tests/test_hermes_agent.sh --case replace-identity "$LIGHT" 2>&1 | tee "$E/02-hermes-replace-green.log"; grep -Fq "PASS[GREEN-hermes-replace-identity]: fixtures alive; replacement refused" "$E/02-hermes-replace-green.log"'
```

Fake launcher log must remain empty. Test kills/waits all saved PIDs, proves records removed only by full-line CAS, then prints `CLEANUP PASS: hermes replace fixtures`。

### Task 3: Project-Owned Mount Anchors for All Local Backends

**Covers:** nested workspace symlink（场景 1）和 workspace path TOCTOU（场景 4）。

**Files:**
- Create: `pkgs/ocsb-mount-anchor.c`
- Create: `pkgs/mount-anchor.nix`
- Create: `tests/test_mount_anchor.sh`
- Create: `tests/fixtures/fake-anchor-runtime.c`
- Modify: `lib/mkSandbox.nix:39-69,552-727,973-1104,1156-1218,1327-1397,1524-1647`
- Modify: `tests/test_wrapper.sh:110-121,272-325`
- Modify: `tests/test_git_worktree.sh:30-65`
- Modify: `tests/test_btrfs.sh:44-85`

**Interfaces:**
- Consumes: source specs `{ token, absolutePath, containmentRoot, expectedDev, expectedIno, expectedType, requiredness, dropArgvStart, dropArgvCount }` and backend argv containing exact `@OCSB_SOURCE_N@` placeholders。`requiredness` is `required` or `optional`; drop range identifies the complete contiguous backend argument group corresponding to one optional source.
- Produces: `ocsb-mount-anchor --backend TYPE --namespace STRATEGY --host-uid UID --host-gid GID --anchor-root VALIDATED_RUNTIME_DIR --source-spec ... --replace ARGV_INDEX:TOKEN ... -- BACKEND_ARGV`; private-namespace-only `$VALIDATED_RUNTIME_DIR/anchors/mount-$pid/N` bind mounts over an otherwise stable empty host directory; final backend `execve` with placeholders replaced by anchors or complete absent optional groups removed while preserving the launcher's original UID/GID contract。
- Produces: `ocsb-mount-anchor --mutation-only --namespace STRATEGY --host-uid UID --host-gid GID --anchor-root VALIDATED_RUNTIME_DIR --workspace-mutation-spec SPEC --receipt FILE`。`SPEC` is versioned and contains expected project dev/ino, relative `workspace.baseDir`, workspace name, requested action/strategy and existing cleanup strategy; it never contains an arbitrary command. The helper fixes project/base/workspace dirfds with `openat2`, performs every project-tree mutation relative to those dirfds, and atomically writes a dev/ino/type receipt. Final source registration is the authoritative public-path post-check and consumes that receipt instead of accepting a newly observed inode; a changed public path therefore refuses before backend execution.

Mutation input is one TAB-delimited, LF-terminated line with no TAB/newline in any field:

```text
v1<TAB>64hex-nonce<TAB>absolute-project-path<TAB>project-dev<TAB>project-ino<TAB>relative-base-dir<TAB>workspace-name<TAB>create|continue|overwrite<TAB>auto|direct|overlayfs|btrfs|git-worktree<TAB>none|direct|overlayfs|btrfs|git-worktree<TAB>bubblewrap|podman|systemd-nspawn<TAB>absolute-state-dir<LF>
```

The launcher captures project dev/ino before the current containment check, generates the nonce from 32 bytes of kernel randomness, and determines action/cleanup strategy only from the locked external state marker plus CLI flags. `relative-base-dir` is split component-by-component and rejects empty, `.`, `..`, symlink and non-directory components. Mutation success writes this exact single-line receipt schema:

```text
v1<TAB>64hex-nonce<TAB>project-dev<TAB>project-ino<TAB>base-dev<TAB>base-ino<TAB>workspace-dev<TAB>workspace-ino<TAB>resolved-strategy<TAB>bubblewrap|podman|systemd-nspawn<TAB>none|relative-strategy-child<TAB>strategy-dev-or-0<TAB>strategy-ino-or-0<TAB>none|directory|btrfs-subvolume|git-worktree<LF>
```

The receipt is written beside `$OVERLAY_STATE_DIR/.workspace-receipt` using same-directory `mktemp`, `umask 077`, mode `0600`, current-UID/non-symlink parent validation, `fsync`, and `renameat2`/`rename`; failure leaves no accepted receipt. Final mode adds `--workspace-receipt FILE --workspace-receipt-nonce 64HEX --workspace-project PATH --workspace-base REL --workspace-name NAME`. Before opening any ordinary source spec it validates owner/mode/type/one-line schema/nonce, then component-wise opens project, every base component, workspace and optional strategy child with `openat2 RESOLVE_BENEATH|RESOLVE_NO_SYMLINKS|RESOLVE_NO_MAGICLINKS`; every dev/ino/type must equal the receipt. No launcher-side re-stat can satisfy this check. Direct/overlay receipts still require project, base and workspace identities even though the backend workspace source is project root. Any mismatch removes only the exact nonce-matching receipt, refuses before backend exec, and never falls back to a pathname.

- [ ] **Step 1: Add deterministic baseline tests before helper implementation**

`tests/test_mount_anchor.sh --prepare "$FIXTURE_DIR"` fail-fast compiles `fake-anchor-runtime.c` and builds three lightweight launchers: bubblewrap uses an overridden fake bwrap package; Podman/nspawn use fake PATH runtimes. Fake runtime:

1. Parses bwrap `--bind/--ro-bind`, Podman `--volume`, or nspawn `--bind=` source argument.
2. Forks; child closes every FD greater than 2 using `close_range` with a `/proc/self/fd` loop fallback.
3. Child writes `FORKED_AND_FDS_CLOSED`, waits on a barrier; parent atomically renames original source and installs a symlink to victim, then releases child.
4. Child reads marker from received backend source and records the exact source string.

Baseline must produce all three exact markers when capability exists:

```text
FAIL[RED-mount-anchor-bubblewrap]: observed=victim
FAIL[RED-mount-anchor-podman]: observed=victim
FAIL[RED-mount-anchor-nspawn]: observed=victim
```

Nested git/btrfs/snap tests replace `worktree`, `snapshot`, and `snap-$hash` with symlinks and print `FAIL[RED-nested-workspace-symlink]: victim modified` if accepted. Add a compatibility case in which one declarative `--ro-bind-try` source and built-in `/etc/static/ssl` are absent: all three fake backends must still run and their logged argv must contain neither the optional token nor a partial bind/volume group. User namespace absence exits `77` with `SKIP[CI-REQUIRED-mount-anchor]: user namespace unavailable`; no other skip is allowed.

Add deterministic `workspace-mutation-parent-swap`. A fixture-only helper binary compiled with `OCSB_MOUNT_ANCHOR_TEST_HOOKS` exposes barrier FDs after project/base/workspace dirfds are fixed but before the first mutation; the production binary does not parse those options or read test-hook environment variables. The baseline launcher barrier is provided by an overridden exact-path `mkdir` wrapper immediately before the first project marker mutation. The coordinator renames `project/.ocsb` to `project/.ocsb-original`, installs a symlink to `victim`, and releases the barrier. Baseline must delete only the victim marker and print:

```text
FAIL[RED-workspace-mutation-parent-swap]: victim-marker=deleted original-marker=present
FAIL[RED-workspace-post-mutation-swap]: backend-observed=replacement
```

The compile-time test ABI has two independent FD pairs and is rejected as an unknown option by the production binary:

```text
mutation-only: --test-before-mutation-ready-fd N --test-before-mutation-release-fd N
final mode:    --test-before-receipt-open-ready-fd N --test-before-receipt-open-release-fd N
```

The first ready byte is written only after project/base/workspace FDs are fixed and before the first delete/create/git/btrfs operation; release requires exactly one byte. The second ready byte is written after the receipt file and nonce are validated but immediately before receipt-bound `openat2` begins; release again requires one byte. Neither pair is read from environment variables. All hook FDs are closed before Git, btrfs work, or backend exec.

The public `workspace-mutation-parent-swap` case is an aggregate runner that launches two isolated fixture subprocesses in order. Its first subprocess uses the first pair, swaps `.ocsb`, releases mutation, then invokes final mode without another swap. Its second subprocess is the same implementation exposed directly as `workspace-post-mutation-swap`: it performs a no-race mutation and receipt publish, invokes final mode with the second pair, swaps `.ocsb` after the second ready byte, then releases it. Both assert victim inode, mode and SHA256 unchanged and absence of a backend sentinel. The aggregate returns success only after both independent subprocesses and both distinct markers succeed; neither marker or barrier can satisfy the other. Calling `workspace-post-mutation-swap` directly reruns only the second proof.

- [ ] **Step 2: Run exact RED**

```powershell
wsl.exe -d nixos -- bash -lc 'set -euo pipefail; cd /mnt/c/Users/hugefiver/source/ocsb; E="${OCSB_REMEDIATION_EVIDENCE_DIR:-${TMPDIR:-/tmp}/ocsb-remediation-2026-07-21-$(id -u)}"; install -d -m 0700 "$E"; F="$E/mount-anchor-fixture"; bash tests/test_mount_anchor.sh --prepare "$F"; set +e; env -u XDG_RUNTIME_DIR bash tests/test_mount_anchor.sh --case deterministic-swap "$F" 2>&1 | tee "$E/03-mount-anchor-red.log"; rc1=${PIPESTATUS[0]}; env -u XDG_RUNTIME_DIR bash tests/test_mount_anchor.sh --case nested-symlink "$F" 2>&1 | tee "$E/03-nested-symlink-red.log"; rc2=${PIPESTATUS[0]}; set -e; if [[ "$rc1" -eq 77 ]]; then grep -Fq "SKIP[CI-REQUIRED-mount-anchor]: user namespace unavailable" "$E/03-mount-anchor-red.log"; else test "$rc1" -ne 0; grep -Fq "FAIL[RED-mount-anchor-bubblewrap]: observed=victim" "$E/03-mount-anchor-red.log"; grep -Fq "FAIL[RED-mount-anchor-podman]: observed=victim" "$E/03-mount-anchor-red.log"; grep -Fq "FAIL[RED-mount-anchor-nspawn]: observed=victim" "$E/03-mount-anchor-red.log"; fi; test "$rc2" -ne 0; grep -Fq "FAIL[RED-nested-workspace-symlink]: victim modified" "$E/03-nested-symlink-red.log"'
```

The same command runs nested path handling separately and requires `FAIL[RED-nested-workspace-symlink]: victim modified`; a mount-anchor harness error cannot satisfy it.

Then run the mutation baseline before implementing mutation-only mode and save it separately:

```powershell
wsl.exe -d nixos -- bash -lc 'set -euo pipefail; cd /mnt/c/Users/hugefiver/source/ocsb; E="${OCSB_REMEDIATION_EVIDENCE_DIR:-${TMPDIR:-/tmp}/ocsb-remediation-2026-07-21-$(id -u)}"; F="$E/mount-anchor-fixture"; set +e; env -u XDG_RUNTIME_DIR bash tests/test_mount_anchor.sh --case workspace-mutation-parent-swap "$F" --baseline 2>&1 | tee "$E/03-workspace-mutation-red.log"; rc=${PIPESTATUS[0]}; set -e; test "$rc" -ne 0; grep -Fq "FAIL[RED-workspace-mutation-parent-swap]: victim-marker=deleted original-marker=present" "$E/03-workspace-mutation-red.log"; grep -Fq "FAIL[RED-workspace-post-mutation-swap]: backend-observed=replacement" "$E/03-workspace-mutation-red.log"'
```

- [ ] **Step 3: Implement openat2 and private-anchor protocol**

`pkgs/mount-anchor.nix` compiles the C file with existing stdenv compiler and hardening flags. `mkSandbox` adds the resulting binary to closure roots and changes every declarative/runtime/workspace/git/overlay/snapshot source to a token plus source spec.

The helper performs this exact sequence:

1. Namespace acquisition before opening sources:
   - The launcher captures `HOST_UID=$(id -u)` and `HOST_GID=$(id -g)` before any namespace transition, uses those values in the already-generated bwrap/Podman/nspawn argv, and passes them explicitly to the helper. The helper must never recompute backend identity from its post-unshare `id` result.
   - bubblewrap: first `unshare(CLONE_NEWUSER)`, write `deny` to `setgroups`, then identity-map exactly `HOST_UID HOST_UID 1` and `HOST_GID HOST_GID 1`; assert `getuid()==HOST_UID` and `getgid()==HOST_GID`, then `unshare(CLONE_NEWNS)` and make `/` recursively private. This grants mount capability in the helper user namespace without changing the numeric UID/GID observed by the prebuilt bwrap argv. Failure prints `ocsb: mount anchoring unavailable for bubblewrap:` and refuses.
   - local rootless Podman: launcher rejects `--remote`, `-r`, `--url`, `--connection`, `CONTAINER_HOST`, and `CONTAINER_CONNECTION`; invokes `podman --remote=false unshare ocsb-mount-anchor --namespace current --host-uid "$HOST_UID" --host-gid "$HOST_GID" ...`. Helper verifies the Podman storage user namespace and `CAP_SYS_ADMIN`, creates only a new mount namespace, and execs the final `podman run` with the original generated `--userns=keep-id --user "$HOST_UID:$HOST_GID"` unchanged. Rootful Podman uses privileged mount-namespace strategy directly. Remote Podman always refuses because anchors cannot cross a remote service boundary.
   - systemd-nspawn: helper requires EUID 0 or effective `CAP_SYS_ADMIN` and successful `unshare(CLONE_NEWNS)`. If current behavior would rely on later polkit elevation, refuse with `ocsb: backend 'systemd-nspawn' cannot establish private mount anchors; run with mount-namespace privilege or use bubblewrap` rather than pathname fallback.
2. Open containment root with `O_PATH|O_DIRECTORY|O_CLOEXEC`. Split relative path into components and call `openat2` for each with `RESOLVE_NO_SYMLINKS|RESOLVE_NO_MAGICLINKS|RESOLVE_BENEATH`; final open uses `O_PATH|O_CLOEXEC`. `ENOSYS` or unsupported resolve flags fail closed with `ocsb: mount anchoring unavailable: openat2 RESOLVE_* unsupported`; no `realpath` fallback is allowed.
3. `fstat` final FD and compare expected dev, ino, file type and containment spec captured by launcher. Mismatch prints `ocsb: unsafe host path: identity changed:`.
4. Receive Task 1's already validated current-UID-owned mode-0700 runtime directory as `--anchor-root`. Before namespace entry, create only the stable host directory `$anchor_root/anchors` mode 0700 and require it to be empty, current-UID-owned and non-symlink. After entering the private mount namespace, mount a private mode-0700 `nodev,nosuid,noexec` tmpfs directly over `$anchor_root/anchors`; only inside that tmpfs create `mount-$pid/N`. For each opened source, use `fstat`: create the anchor with `mkdir(0700)` for `S_ISDIR`, create an empty regular anchor with `open(O_CREAT|O_EXCL,0600)` for `S_ISREG`, and reject every other file type unless a future explicit source kind is designed. Then bind `/proc/self/fd/$fd` onto the matching-type anchor and close the source FD. `/proc/self/fd` is used only for the helper-local bind mount and is never passed to a backend. When the exec'ed backend exits, destruction of the private mount namespace removes tmpfs and every per-run anchor automatically; no host `mount-$pid` path exists to clean.
5. `mkSandbox` emits one `--replace ARGV_INDEX:TOKEN` entry for every source occurrence. At that exact argv index, the helper requires the unique token to occur exactly once anywhere in the element, then replaces only that occurrence. This covers standalone bwrap sources, Podman `TOKEN:DEST[:MODE]`, nspawn `--bind-ro=TOKEN:DEST`, and `--directory=TOKEN` without parsing them heuristically. Reject out-of-range indexes, zero/multiple token occurrences, duplicate replacement declarations, and unreferenced source tokens.
6. Preserve `--bind-try`/`--ro-bind-try` semantics explicitly. `mkSandbox` carries optionality through `build_container_plan_from_bwrap_args` instead of pre-dropping paths with `[[ -e ]]`: bwrap marks a three-argv group (`FLAG TOKEN DEST`), Podman marks its two-argv group (`--volume TOKEN:DEST:MODE`), and nspawn marks its one-argv group (`--bind[-ro]=TOKEN:DEST`). The helper first validates every source against the original immutable argv and records either a concrete anchor replacement or an absent optional drop range. It then applies all present-source token replacements at their original `ARGV_INDEX` values. Only after every present token is replaced does it delete absent optional groups, in descending `dropArgvStart` order. If and only if `openat2` returns `ENOENT` for an `optional` source, the complete declared group is dropped; any other open error fails closed. Required sources always fail when absent. Drop ranges must be in-bounds and non-overlapping; a partial group or leftover source token is a hard error.
7. Before any host-side project mutation, invoke mutation-only mode. It opens and validates the original project root, then opens or creates every `workspace.baseDir` and workspace-name component with `openat2`/`mkdirat`; after a component is opened, later actions use its dirfd and never the public pathname. The action/strategy matrix is exhaustive:

   | Action | direct / overlayfs | btrfs | git-worktree |
   |---|---|---|---|
   | `create` | create/open base and workspace, no project-tree strategy child | create/open base and workspace, then create `snapshot` with `BTRFS_IOC_SNAP_CREATE_V2` using project/workspace FDs | create/open base and workspace, `fchdir(workspaceFd)`, scrub every `GIT_*`, run absolute `${pkgs.git}/bin/git worktree add --detach worktree HEAD`, then open/verify the new directory |
   | `continue` | require existing no-symlink base/workspace directories | additionally require `snapshot` to be an existing btrfs subvolume opened below workspace | additionally require `worktree` directory plus Git metadata belonging to the same repository; validation uses the absolute Git binary from `fchdir(workspaceFd)` and no caller `GIT_*` |
   | `overwrite` | preserve workspace root inode and clear children with same-filesystem, no-follow `openat2`/`unlinkat` recursion | first destroy only the opened `snapshot` child with `BTRFS_IOC_SNAP_DESTROY`, clear remaining children, then create the requested strategy as in `create` | from `fchdir(workspaceFd)`, remove only opened child via absolute `git worktree remove --force worktree`, run `git worktree prune`, clear remaining children, then create as above |

   State transitions are action-specific. `create` requires both locked external `.strategy` and `.backend` markers to be absent and performs only requested-strategy creation. `continue` requires the locked external backend marker to equal the requested backend and performs no cleanup, clear, create, probe or Git/Btrfs mutation: an explicit requested strategy must equal `.strategy`; requested `auto` resolves to the recorded `.strategy` only when it is `btrfs` or `overlayfs`; then the helper validates the corresponding existing project objects and writes a fresh nonce receipt. `overwrite` may consume `none` or the exact locked external existing strategy as cleanup strategy, applies that cleanup first, then creates the resolved requested strategy second. `none` cleanup performs no strategy command. For `create` and `overwrite`, requested `auto` is resolved by an FD-relative btrfs probe: create/delete a nonce-named subvolume through project FD ioctls; success resolves `btrfs`, expected unsupported-filesystem/permission results resolve `overlayfs`, and every partial probe is removed before returning. The resolved value and requested backend are stored in the receipt and are the only values the launcher may write to `.strategy`/`.backend`.

   Git commands inherit stdin/stdout/stderr but no lock/runtime/source FD except the workspace/project FDs intentionally used for `fchdir`; all caller `GIT_*` variables are removed. Normal execution records the public `$PROJECT_DIR/$baseDir/$workspace/worktree` path. If a Git command or mutation-only postcondition fails before receipt publication, that same mutation-only process still owns the fixed FDs and runs FD-relative `git worktree remove --force worktree` plus `prune` before returning nonzero; it never touches the replacement public path. Once mutation-only exits successfully, final receipt validation has no rollback authority: a mismatch only fail-closes before backend exec, removes the exact nonce-matching receipt, and leaves original project artifacts for a later explicit `--overwrite`. Btrfs operations use ioctls only, never `btrfs` or `rm` on a public pathname. No action may fall back to `$PROJECT_DIR/.ocsb/...` string operations.

   External `$OVERLAY_STATE_DIR` cleanup remains under the already validated current-UID mode-0700 state/runtime root and runs under FD 9 only after mutation helper success; failure may leave external cache state requiring retry but cannot mutate the project replacement. `.strategy`, `.backend` and receipt are published only after project mutation succeeds. Final source registration must consume the exact nonce receipt. Missing, malformed, stale or mismatched receipt is fatal.
8. `execve` backend directly; helper does not fork a supervisor, so controlling TTY, foreground process group, exit status and signals are preserved. Namespace and mounts disappear when backend exits.

- [ ] **Step 4: Prove post-open swap safety and FD independence**

GREEN fake runtime must fork, close extra FDs, swap original source after helper anchoring, and still print for each backend:

```text
PASS[GREEN-mount-anchor-bubblewrap]: observed=original source=private-runtime-anchor
PASS[GREEN-mount-anchor-podman]: observed=original source=private-runtime-anchor
PASS[GREEN-mount-anchor-nspawn]: observed=original source=private-runtime-anchor
PASS[GREEN-post-open-swap]: original pathname now victim; anchored marker still original
```

It additionally rejects any backend source containing `/proc/self/fd`. Fixtures include both a directory source and a regular-file source and require matching anchor types. The absent-optional case places an absent optional group before at least one required source in each backend argv, then requires `PASS[GREEN-optional-mount]: bubblewrap=omitted podman=omitted nspawn=omitted required=anchored`. This proves each fake backend executed, no partial group/token reached it, and the later required source still resolved to its private anchor despite deletion of an earlier group. Fake runtimes assert the final generated flags remain exactly: bwrap `--uid HOST_UID --gid HOST_GID`, Podman `--userns=keep-id --user HOST_UID:HOST_GID`, nspawn `--user=HOST_UID`, and emit `PASS[GREEN-id-semantics]: bwrap=HOST_UID podman=HOST_UID nspawn=HOST_UID`. Podman fake implements `--remote=false unshare` by entering its controlled user/mount namespace; nspawn case runs under a verified capable namespace. If that kernel capability is absent, exact CI-required marker is recorded and the capable CI lane must supply all post-open/identity GREEN markers; the no-namespace optional-source manifest/unit case still runs locally.

The mutation barrier repeats the parent swap after the helper has fixed its dirfds. It must clear the original workspace inode, leave victim inode/mode/SHA256 unchanged, refuse before backend execution when the public path no longer names the receipted inode, and print both:

```text
PASS[GREEN-workspace-mutation-parent-swap]: original-reset victim-unchanged backend-refused
PASS[GREEN-workspace-post-mutation-swap]: identity-mismatch victim-unchanged
```

- [ ] **Step 5: Run GREEN and real-runtime secondary checks**

```powershell
wsl.exe -d nixos -- bash -lc 'set -euo pipefail; cd /mnt/c/Users/hugefiver/source/ocsb; E="${OCSB_REMEDIATION_EVIDENCE_DIR:-${TMPDIR:-/tmp}/ocsb-remediation-2026-07-21-$(id -u)}"; install -d -m 0700 "$E"; F="$E/mount-anchor-fixture"; bash tests/test_mount_anchor.sh --prepare "$F"; set +e; env -u XDG_RUNTIME_DIR bash tests/test_mount_anchor.sh --case deterministic-swap "$F" 2>&1 | tee "$E/03-mount-anchor-green.log"; rc=${PIPESTATUS[0]}; set -e; if [[ "$rc" -eq 77 ]]; then grep -Fq "SKIP[CI-REQUIRED-mount-anchor]: user namespace unavailable" "$E/03-mount-anchor-green.log"; else test "$rc" -eq 0; grep -Fq "PASS[GREEN-post-open-swap]: original pathname now victim; anchored marker still original" "$E/03-mount-anchor-green.log"; grep -Fq "PASS[GREEN-anchor-types]: directory=directory regular=regular" "$E/03-mount-anchor-green.log"; grep -Fq "PASS[GREEN-id-semantics]:" "$E/03-mount-anchor-green.log"; fi; env -u XDG_RUNTIME_DIR bash tests/test_mount_anchor.sh --case optional-source-absent "$F" | tee -a "$E/03-mount-anchor-green.log"; grep -Fq "PASS[GREEN-optional-mount]: bubblewrap=omitted podman=omitted nspawn=omitted required=anchored" "$E/03-mount-anchor-green.log"; env -u XDG_RUNTIME_DIR bash tests/test_mount_anchor.sh --case nested-symlink "$F" | tee "$E/03-nested-symlink-green.log"; grep -Fq "PASS[GREEN-nested-workspace-symlink]: all nested symlinks refused; victims unchanged" "$E/03-nested-symlink-green.log"; env -u XDG_RUNTIME_DIR bash tests/test_mount_anchor.sh --case real-runtime-secondary "$F" | tee -a "$E/03-mount-anchor-green.log"; test -d "$F/runtime/anchors"; test -z "$(find "$F/runtime/anchors" -mindepth 1 -print -quit)"; printf "%s\n" "CLEANUP PASS: no host per-run mount anchors" | tee -a "$E/03-mount-anchor-green.log"'
```

Run the mutation GREEN independently and preserve its cleanup receipt:

```powershell
wsl.exe -d nixos -- bash -lc 'set -euo pipefail; cd /mnt/c/Users/hugefiver/source/ocsb; E="${OCSB_REMEDIATION_EVIDENCE_DIR:-${TMPDIR:-/tmp}/ocsb-remediation-2026-07-21-$(id -u)}"; F="$E/mount-anchor-fixture"; env -u XDG_RUNTIME_DIR bash tests/test_mount_anchor.sh --case workspace-mutation-parent-swap "$F" 2>&1 | tee "$E/03-workspace-mutation-green.log"; grep -Fq "PASS[GREEN-workspace-mutation-parent-swap]: original-reset victim-unchanged backend-refused" "$E/03-workspace-mutation-green.log"; grep -Fq "PASS[GREEN-workspace-post-mutation-swap]: identity-mismatch victim-unchanged" "$E/03-workspace-mutation-green.log"; grep -Fq "CLEANUP PASS: workspace mutation fixtures" "$E/03-workspace-mutation-green.log"'
```

Real bwrap is required when userns works and must prove payload UID/GID equal the baseline launcher contract. Missing local Podman prints `SKIP[CI-REQUIRED-real-podman-anchor]: podman unavailable`; remote mode must refuse, not skip. A dedicated native-Linux rootless Podman CI lane is required to prove nested `podman unshare` plus final `podman run --userns=keep-id --user HOST_UID:HOST_GID` succeeds, retains UID/GID, and reads the anchored original source; if this real lane fails, rootless Podman support is not considered GREEN. Nspawn without mount privilege prints `SKIP[CI-REQUIRED-real-nspawn-anchor]: CAP_SYS_ADMIN unavailable`; its capable lane must prove the original `--user=HOST_UID` remains effective. CI capable lanes replace skips with `PASS[GREEN-real-...]`. Victims stay unchanged, helper namespace disappears, all fake children are reaped, and the underlying `$anchor_root/anchors` directory contains no `mount-*` or other per-run entry after every success/failure case.

### Task 4: Ephemeral Podman and systemd-nspawn Rootfs

**Covers:** container rootfs persistence（场景 5）。

**Files:**
- Modify: `lib/mkSandbox.nix:552-594,1156-1218`
- Modify: `tests/test_backend.sh:151-179`

**Interfaces:**
- Consumes: workspace lock FD 9, canonical `OVERLAY_STATE_DIR`, explicit external mounts。
- Produces: rebuilt `$OVERLAY_STATE_DIR/rootfs` for every locked launch。

- [ ] **Step 1: Add deterministic RED fake backend case**

Fake Podman/nspawn write `rootfs/tmp/ocsb-sentinel` on run one and return `97` on run two if present. Focused case prints `FAIL[RED-container-rootfs-persistence]: podman=present nspawn=present` only when both persisted.

- [ ] **Step 2: Run exact RED**

```powershell
wsl.exe -d nixos -- bash -lc 'set -euo pipefail; cd /mnt/c/Users/hugefiver/source/ocsb; E="${OCSB_REMEDIATION_EVIDENCE_DIR:-${TMPDIR:-/tmp}/ocsb-remediation-2026-07-21-$(id -u)}"; install -d -m 0700 "$E"; bash tests/test_backend.sh . --prepare-rootfs-fixture "$E/rootfs-fixture"; set +e; env -u XDG_RUNTIME_DIR bash tests/test_backend.sh . --case rootfs-ephemeral "$E/rootfs-fixture" 2>&1 | tee "$E/04-rootfs-red.log"; rc=${PIPESTATUS[0]}; set -e; test "$rc" -ne 0; grep -Fq "FAIL[RED-container-rootfs-persistence]: podman=present nspawn=present" "$E/04-rootfs-red.log"'
```

- [ ] **Step 3: Rebuild safely under lock**

Verify rootfs is non-symlink exact child of state, chmod directories only, remove with `rm -rf --one-file-system`, recreate skeleton. Preserve only explicit mounts/state outside rootfs; never preserve `/tmp`, `/run`, or unmounted home.

```bash
[[ "$rootfs" == "$OVERLAY_STATE_DIR/rootfs" && ! -L "$rootfs" ]] || ocsb_die "unsafe container rootfs"
rm -rf --one-file-system -- "$rootfs"
install -d -m 0755 "$rootfs"/{dev,proc,run,sys,tmp,home/sandbox,nix/store,nix/var/nix}
chmod 1777 "$rootfs/tmp"
```

- [ ] **Step 4: GREEN/integration**

Run focused case and require `PASS[GREEN-container-rootfs-persistence]: podman=absent nspawn=absent`; also assert mounted workspace/data marker persists while rootfs-local home marker disappears. Fake state is removed.

```powershell
wsl.exe -d nixos -- bash -lc 'set -euo pipefail; cd /mnt/c/Users/hugefiver/source/ocsb; E="${OCSB_REMEDIATION_EVIDENCE_DIR:-${TMPDIR:-/tmp}/ocsb-remediation-2026-07-21-$(id -u)}"; install -d -m 0700 "$E"; bash tests/test_backend.sh . --prepare-rootfs-fixture "$E/rootfs-fixture"; env -u XDG_RUNTIME_DIR bash tests/test_backend.sh . --case rootfs-ephemeral "$E/rootfs-fixture" 2>&1 | tee "$E/04-rootfs-green.log"; grep -Fq "PASS[GREEN-container-rootfs-persistence]: podman=absent nspawn=absent" "$E/04-rootfs-green.log"; grep -Fq "CLEANUP PASS: rootfs fake runtime" "$E/04-rootfs-green.log"'
```

### Task 5: Independent Dual-Layer sandboxDir and Environment Scenarios

**Covers:** dual-layer sandboxDir（场景 6）和 dual-layer env（场景 7）。

**Files:**
- Modify: `lib/mkSandbox.nix:243-310`
- Modify: `flake.nix:424-440`
- Modify: `tests/dual-layer-test.nix:5-12`
- Create: `tests/dual-layer-home-test.nix`
- Create: `tests/test_dual_layer_host.sh`
- Modify: `tests/test_dual_layer.sh:47-165`

**Interfaces:**
- Consumes: configured `cfg.workspace.sandboxDir`, outer filtered environment。
- Produces: inner bind/chdir for configured directory and inherited env with explicit override set。

- [ ] **Step 1: Add two separate RED fixtures**

Default fixture keeps `/workspace`; host driver sets `FOO=bar` and inner test prints `FAIL[RED-dual-layer-env]: inner FOO is empty` on baseline. Separate home fixture sets `/home/sandbox`; host driver captures launcher failure before inner script and, only after confirming stderr references hard-coded `/workspace`, prints `FAIL[RED-dual-layer-sandboxdir]: inner wrapper required /workspace`.

- [ ] **Step 2: Run both exact RED proofs**

```powershell
wsl.exe -d nixos -- bash -lc 'set -euo pipefail; cd /mnt/c/Users/hugefiver/source/ocsb; E="${OCSB_REMEDIATION_EVIDENCE_DIR:-${TMPDIR:-/tmp}/ocsb-remediation-2026-07-21-$(id -u)}"; install -d -m 0700 "$E"; D=$(nix build --no-link --print-out-paths .#checks.x86_64-linux.dual-layer-default-test); H=$(nix build --no-link --print-out-paths .#checks.x86_64-linux.dual-layer-home-test); set +e; env -u XDG_RUNTIME_DIR bash tests/test_dual_layer_host.sh --case env "$D/bin/ocsb-dual-test" 2>&1 | tee "$E/05-dual-env-red.log"; rc1=${PIPESTATUS[0]}; env -u XDG_RUNTIME_DIR bash tests/test_dual_layer_host.sh --case sandbox-dir "$H/bin/ocsb-dual-home-test" 2>&1 | tee "$E/05-dual-dir-red.log"; rc2=${PIPESTATUS[0]}; set -e; test "$rc1" -ne 0; test "$rc2" -ne 0; grep -Fq "FAIL[RED-dual-layer-env]: inner FOO is empty" "$E/05-dual-env-red.log"; grep -Fq "FAIL[RED-dual-layer-sandboxdir]: inner wrapper required /workspace" "$E/05-dual-dir-red.log"'
```

- [ ] **Step 3: Parameterize and inherit**

Embed configured sandboxDir in inner bind/chdir. Keep `--clearenv`; enumerate outer env with `env -0`, forward every valid name except `HOME`, `PATH`, `TERM`, `SSL_CERT_FILE`, `SANDBOX`, `OCSB_DUAL_LAYER`, then append these fixed overrides last.

```bash
while IFS= read -r -d '' entry; do
  name=${entry%%=*}
  case "$name" in HOME|PATH|TERM|SSL_CERT_FILE|SANDBOX|OCSB_DUAL_LAYER) continue ;; esac
  INNER_ARGS+=(--setenv "$name" "${entry#*=}")
done < <(env -0)
INNER_ARGS+=(--bind "$WORKSPACE_SANDBOX_DIR" "$WORKSPACE_SANDBOX_DIR" --chdir "$WORKSPACE_SANDBOX_DIR")
```

- [ ] **Step 4: GREEN/integration**

Run both focused cases separately and require `PASS[GREEN-dual-layer-env]: FOO=bar` and `PASS[GREEN-dual-layer-sandboxdir]: pwd=/home/sandbox`. Existing inner no-network/store/tmp/write-through assertions remain GREEN; expected network nonzero is explicitly captured.

```powershell
wsl.exe -d nixos -- bash -lc 'set -euo pipefail; cd /mnt/c/Users/hugefiver/source/ocsb; E="${OCSB_REMEDIATION_EVIDENCE_DIR:-${TMPDIR:-/tmp}/ocsb-remediation-2026-07-21-$(id -u)}"; install -d -m 0700 "$E"; D=$(nix build --no-link --print-out-paths .#checks.x86_64-linux.dual-layer-default-test); H=$(nix build --no-link --print-out-paths .#checks.x86_64-linux.dual-layer-home-test); env -u XDG_RUNTIME_DIR bash tests/test_dual_layer_host.sh --case env "$D/bin/ocsb-dual-test" 2>&1 | tee "$E/05-dual-env-green.log"; env -u XDG_RUNTIME_DIR bash tests/test_dual_layer_host.sh --case sandbox-dir "$H/bin/ocsb-dual-home-test" 2>&1 | tee "$E/05-dual-dir-green.log"; grep -Fq "PASS[GREEN-dual-layer-env]: FOO=bar" "$E/05-dual-env-green.log"; grep -Fq "PASS[GREEN-dual-layer-sandboxdir]: pwd=/home/sandbox" "$E/05-dual-dir-green.log"'
```

### Task 6: Generic Daemon Without Hermes/pip Side Effects

**Covers:** generic daemon pip（场景 8）。

**Files:**
- Modify: `lib/mkSandbox.nix:83-128`
- Modify: `tests/test_backend.sh:43-97`

**Interfaces:**
- Consumes: only `cfg.app.daemon[].{command,restart}`。
- Produces: generic supervisor without Hermes env, venv, Python or network actions。

- [ ] **Step 1: RED fixture and exact runner**

Fail-fast fixture build creates one daemon marker and extracts referenced supervisor source. Focused test under unreachable proxy prints `FAIL[RED-generic-daemon-pip]: supervisor contains Hermes venv or pip` only if source strings are present and offline startup does not reach both markers.

```powershell
wsl.exe -d nixos -- bash -lc 'set -euo pipefail; cd /mnt/c/Users/hugefiver/source/ocsb; E="${OCSB_REMEDIATION_EVIDENCE_DIR:-${TMPDIR:-/tmp}/ocsb-remediation-2026-07-21-$(id -u)}"; install -d -m 0700 "$E"; B=$(bash tests/test_backend.sh . --prepare-daemon-fixture "$E/daemon-fixture"); test -x "$B"; set +e; env -u XDG_RUNTIME_DIR bash tests/test_backend.sh . --case generic-daemon "$B" 2>&1 | tee "$E/06-daemon-red.log"; rc=${PIPESTATUS[0]}; set -e; test "$rc" -ne 0; grep -Fq "FAIL[RED-generic-daemon-pip]: supervisor contains Hermes venv or pip" "$E/06-daemon-red.log"'
```

- [ ] **Step 2: Remove only generic coupling**

Delete generic `HERMES_HOME`, `TERMINAL_CWD`, `.hermes-venv`, pip upgrade and PYTHONPATH/PATH edits. Preserve daemon spawn/restart and foreground exec. Hermes template venv blocks remain unchanged.

```bash
for daemon_cmd in "${DAEMON_COMMANDS[@]}"; do
  supervise_daemon "$daemon_cmd" &
done
exec "${PAYLOAD_ARGV[@]}"
```

- [ ] **Step 3: GREEN/integration**

Focused test requires `PASS[GREEN-generic-daemon-pip]: source clean; offline daemon and foreground markers present`; Hermes source-only test still finds venv only in Hermes templates.

```powershell
wsl.exe -d nixos -- bash -lc 'set -euo pipefail; cd /mnt/c/Users/hugefiver/source/ocsb; E="${OCSB_REMEDIATION_EVIDENCE_DIR:-${TMPDIR:-/tmp}/ocsb-remediation-2026-07-21-$(id -u)}"; install -d -m 0700 "$E"; B=$(bash tests/test_backend.sh . --prepare-daemon-fixture "$E/daemon-fixture"); env -u XDG_RUNTIME_DIR bash tests/test_backend.sh . --case generic-daemon "$B" 2>&1 | tee "$E/06-daemon-green.log"; grep -Fq "PASS[GREEN-generic-daemon-pip]: source clean; offline daemon and foreground markers present" "$E/06-daemon-green.log"; bash tests/test_hermes_agent.sh --source-only'
```

### Task 7: Reject Caller API File plus Secret-Like --env

**Covers:** Hermes caller file + secret（场景 9）。

**Files:**
- Modify: `scripts/hermes-wrapper.nix:248-287,358-375`
- Modify: `tests/test_hermes_agent.sh:291-327`

**Interfaces:**
- Consumes: caller env file, collected secret names。
- Produces: nonzero refusal without changing file or invoking inner launcher。

- [ ] **Step 1: RED and exact runner**

Use Task 2 lightweight wrapper. Hash caller file, pass `--api-keys-env-file` plus `--env CUSTOM_PROVIDER_TOKEN`, and print `FAIL[RED-hermes-caller-file-secret]: combination launched and secret was omitted` only if baseline exits zero.

```powershell
wsl.exe -d nixos -- bash -lc 'set -euo pipefail; cd /mnt/c/Users/hugefiver/source/ocsb; E="${OCSB_REMEDIATION_EVIDENCE_DIR:-${TMPDIR:-/tmp}/ocsb-remediation-2026-07-21-$(id -u)}"; install -d -m 0700 "$E"; LIGHT=$(bash tests/test_hermes_agent.sh --build-lightweight-wrapper "$E/hermes-fixture"); set +e; bash tests/test_hermes_agent.sh --case caller-file-secret "$LIGHT" 2>&1 | tee "$E/07-hermes-secret-red.log"; rc=${PIPESTATUS[0]}; set -e; test "$rc" -ne 0; grep -Fq "FAIL[RED-hermes-caller-file-secret]: combination launched and secret was omitted" "$E/07-hermes-secret-red.log"'
```

- [ ] **Step 2: Implement refusal and GREEN**

After parsing and before file handling, reject nonempty caller file plus nonempty secret-name array. Diagnostic names only the variable and instructs merge into caller file. Non-secret `--env` remains accepted. GREEN requires `PASS[GREEN-hermes-caller-file-secret]: nonzero merge diagnostic; caller hash unchanged; launcher log empty`。

```bash
if [[ -n "$API_KEYS_ENV_FILE" && ${#SECRET_ENV_NAMES[@]} -gt 0 ]]; then
  printf "ocsb-hermes: --env %s is secret-like; merge it into --api-keys-env-file\n" "${SECRET_ENV_NAMES[0]}" >&2
  exit 2
fi
```

```powershell
wsl.exe -d nixos -- bash -lc 'set -euo pipefail; cd /mnt/c/Users/hugefiver/source/ocsb; E="${OCSB_REMEDIATION_EVIDENCE_DIR:-${TMPDIR:-/tmp}/ocsb-remediation-2026-07-21-$(id -u)}"; install -d -m 0700 "$E"; LIGHT=$(bash tests/test_hermes_agent.sh --build-lightweight-wrapper "$E/hermes-fixture"); bash tests/test_hermes_agent.sh --case caller-file-secret "$LIGHT" 2>&1 | tee "$E/07-hermes-secret-green.log"; grep -Fq "PASS[GREEN-hermes-caller-file-secret]: nonzero merge diagnostic; caller hash unchanged; launcher log empty" "$E/07-hermes-secret-green.log"'
```

### Task 8: Deadlock-Free Hermes Gateway Reservation Protocol

**Covers:** gateway race/PID（场景 10）。

**Files:**
- Create: `lib/hermes-service.nix`
- Modify: `flake.nix:76-303`
- Modify: `tests/test_hermes_agent.sh:65-102`

**Interfaces:**
- Consumes: Task 1 typed records/CAS, canonical `HERMES_HOME`, short-held runtime `gateway.lock`。
- Produces: atomic reservation `v1<TAB>candidate-pid<TAB>start<TAB>token<TAB>instance`; typed supervisor/child records; unchanged public `service gateway start|stop|restart|status|supervise` CLI。

- [ ] **Step 1: Build deterministic eight-caller barrier**

Fixture builder produces extracted service, fake `hermes`, and fake `nohup`. Eight start callers block on one start gate. Fake nohup logs the exact argv and blocks before executing `SERVICE_PATH gateway supervise --candidate-token TOKEN`（其中 `SERVICE_PATH` 是 `$0`；`gateway` 必须是第一个参数，不能多出 `service`）。Fixture 先断言 argv 形状，再参与并发计数。Baseline has no reservation and deterministically reaches:

```text
FAIL[RED-gateway-race]: spawn_count=8 reservation_hits=0
```

The test does not release fake nohup until all eight baseline spawn logs exist. Fixed test waits until one spawn plus seven `reservation already active` receipts, then releases the single candidate. A stale typed record points to live `sleep 60` with forged start; fixture must survive.

- [ ] **Step 2: Run exact RED**

```powershell
wsl.exe -d nixos -- bash -lc 'set -euo pipefail; cd /mnt/c/Users/hugefiver/source/ocsb; E="${OCSB_REMEDIATION_EVIDENCE_DIR:-${TMPDIR:-/tmp}/ocsb-remediation-2026-07-21-$(id -u)}"; install -d -m 0700 "$E"; S=$(bash tests/test_hermes_agent.sh --build-service-fixture "$E/gateway-fixture"); test -x "$S"; set +e; bash tests/test_hermes_agent.sh --case gateway-reservation "$S" 2>&1 | tee "$E/08-gateway-red.log"; rc=${PIPESTATUS[0]}; set -e; test "$rc" -ne 0; grep -Fq "FAIL[RED-gateway-race]: spawn_count=8 reservation_hits=0" "$E/08-gateway-red.log"'
```

- [ ] **Step 3: Implement short-lock reservation/claim**

No `sleep`, readiness poll, child wait, or process-exit wait occurs while lock is held.

`start` protocol:

1. Lock; validate supervisor and reservation. If valid supervisor, return already running. If valid reservation, increment observable reservation-hit receipt and return reserved.
2. With lock held, generate 128-bit token; start `nohup "$0" gateway supervise --candidate-token "$token" 9>&- &`. Read `$!` start time once without polling. Atomically write reservation bound to candidate PID/start/token/instance. If start time unavailable, unlock, terminate exact candidate outside lock, fail.
3. Unlock. The initiating caller may poll claim/readiness with bounded sleep outside lock.
4. Candidate has no inherited lock FD. It opens the lock anew, validates reservation equals its PID/start/token/instance, atomically writes supervisor record, full-line-CAS removes reservation, unlocks, then supervises.

```bash
flock 9
if validate_supervisor || validate_reservation; then
  flock -u 9
  return 0
fi
token=$(openssl rand -hex 16)
nohup "$0" gateway supervise --candidate-token "$token" 9>&- &
candidate=$!
start=$(proc_start_once "$candidate") || { flock -u 9; terminate_exact "$candidate" ""; return 1; }
write_reservation "$candidate" "$start" "$token" "$instance"
flock -u 9
wait_for_claim_outside_lock "$candidate" "$start" "$token"
```

Supervisor alone forks, owns, waits and reaps gateway child. Child record writes/removals use short lock and full-line CAS. `stop/restart` lock only to update marker and capture exact records; signal/wait outside; reacquire for CAS cleanup. `status` only reads under short lock. Stale reservation/records are removed without signaling unrelated PID; start time is rechecked before every signal.

- [ ] **Step 4: GREEN/integration**

Focused test requires `PASS[GREEN-gateway-race]: spawn_count=1 reservation_hits=7`, exact candidate argv `gateway supervise --candidate-token TOKEN`, one supervisor, one child, stale fixture alive, and no lock FD in candidate/child. Release barrier, stop service, wait/reap all fake processes, prove records absent, print `CLEANUP PASS: gateway fixtures`。

```powershell
wsl.exe -d nixos -- bash -lc 'set -euo pipefail; cd /mnt/c/Users/hugefiver/source/ocsb; E="${OCSB_REMEDIATION_EVIDENCE_DIR:-${TMPDIR:-/tmp}/ocsb-remediation-2026-07-21-$(id -u)}"; install -d -m 0700 "$E"; S=$(bash tests/test_hermes_agent.sh --build-service-fixture "$E/gateway-fixture"); bash tests/test_hermes_agent.sh --case gateway-reservation "$S" 2>&1 | tee "$E/08-gateway-green.log"; grep -Fq "PASS[GREEN-gateway-race]: spawn_count=1 reservation_hits=7" "$E/08-gateway-green.log"; grep -Fq "CLEANUP PASS: gateway fixtures" "$E/08-gateway-green.log"'
```

### Task 9: Ironclaw Sidecar Lock, Identity, Digest and Deterministic Concurrency

**Covers:** sidecar identity（场景 11）、sidecar concurrency（场景 12）、mutable image（场景 13）。

**Files:**
- Modify: `scripts/ironclaw-wrapper.nix:15-19,289-456`
- Modify: `tests/test_ironclaw.sh:1-148,285-383`

**Interfaces:**
- Consumes: canonical persist, `flock`, OCI inspect/run/start/exec。
- Produces: persist lock; owner/persist/image/volume/port labels; strict actual metadata checks; immutable default digest。

- [ ] **Step 1: Build lightweight wrapper and stateful fake OCI before RED**

Fixture builder creates fake inner launcher and fake OCI state. First caller reaches inspect-missing, writes `FIRST_INSPECT_READY`, and blocks. Test probes sidecar lock with nonblocking `flock`, then starts caller two. On baseline lock probe succeeds and caller two reaches `SECOND_INSPECT_READY`; release yields exactly two create attempts. On fixed code lock probe fails, caller two cannot reach inspect before release, then reuses caller-one metadata. This avoids timing-based sleeps.

Wrong-identity fixture returns deterministic image/volume/port mismatches and records whether start/exec was called.

- [ ] **Step 2: Run exact RED**

```powershell
wsl.exe -d nixos -- bash -lc 'set -euo pipefail; cd /mnt/c/Users/hugefiver/source/ocsb; E="${OCSB_REMEDIATION_EVIDENCE_DIR:-${TMPDIR:-/tmp}/ocsb-remediation-2026-07-21-$(id -u)}"; install -d -m 0700 "$E"; I=$(bash tests/test_ironclaw.sh --build-lightweight-wrapper "$E/ironclaw-fixture"); test -x "$I"; set +e; env -u XDG_RUNTIME_DIR bash tests/test_ironclaw.sh --case sidecar-security "$I" 2>&1 | tee "$E/09-sidecar-red.log"; rc=${PIPESTATUS[0]}; set -e; test "$rc" -ne 0; grep -Fq "FAIL[RED-sidecar-identity]: wrong image,volume,port reused" "$E/09-sidecar-red.log"; grep -Fq "FAIL[RED-sidecar-concurrency]: create_count=2 lock_probe=unlocked" "$E/09-sidecar-red.log"; grep -Fq "FAIL[RED-sidecar-image]: default is floating :pg18" "$E/09-sidecar-red.log"'
```

- [ ] **Step 3: Implement lock and metadata validation**

Acquire `$PERSIST_DIR/state/ironclaw-sidecar.lock` before password read/generation and hold across inspect/create/start/readiness/database/vector initialization. This lock intentionally covers the complete sidecar transaction; unlike gateway service it has no child supervisor that must reacquire the same lock. Close before sandbox exec.

Create labels `io.ocsb.owner`, `io.ocsb.persist-id`, `io.ocsb.image`, `io.ocsb.volume`, `io.ocsb.port`. On reuse compare labels plus `.Config.Image`, mount source/destination and `5432/tcp` HostIp/HostPort using OCI Go templates. Any mismatch fails before start/exec with `ocsb-ironclaw: sidecar identity mismatch:` and field names only. Set exact digest default and preserve override.

```bash
exec {sidecar_lock_fd}>"$PERSIST_DIR/state/ironclaw-sidecar.lock"
flock "$sidecar_lock_fd"
actual=$($OCI inspect --format '{{.Config.Image}}|{{index .Config.Labels "io.ocsb.persist-id"}}|{{range .Mounts}}{{.Source}}:{{.Destination}}{{end}}' "$DB_CONTAINER")
[[ "$actual" == "$expected" ]] || die "sidecar identity mismatch: image/labels/mount/port"
```

- [ ] **Step 4: GREEN/integration**

Require `PASS[GREEN-sidecar-identity]: mismatch refused before mutation`, `PASS[GREEN-sidecar-concurrency]: create_count=1 lock_probe=locked password_consistent`, and exact digest marker. Remove fake state/env temps, wait both callers, verify no lock holder, print `CLEANUP PASS: sidecar fake OCI fixtures`。

```powershell
wsl.exe -d nixos -- bash -lc 'set -euo pipefail; cd /mnt/c/Users/hugefiver/source/ocsb; E="${OCSB_REMEDIATION_EVIDENCE_DIR:-${TMPDIR:-/tmp}/ocsb-remediation-2026-07-21-$(id -u)}"; install -d -m 0700 "$E"; I=$(bash tests/test_ironclaw.sh --build-lightweight-wrapper "$E/ironclaw-fixture"); env -u XDG_RUNTIME_DIR bash tests/test_ironclaw.sh --case sidecar-security "$I" 2>&1 | tee "$E/09-sidecar-green.log"; grep -Fq "PASS[GREEN-sidecar-identity]: mismatch refused before mutation" "$E/09-sidecar-green.log"; grep -Fq "PASS[GREEN-sidecar-concurrency]: create_count=1 lock_probe=locked password_consistent" "$E/09-sidecar-green.log"; grep -Fq "PASS[GREEN-sidecar-image]: docker.io/pgvector/pgvector:pg18@sha256:12a379b47ad65289572ea0756efc11b7c241a6662833e8af7038cd3b73d647e0" "$E/09-sidecar-green.log"; grep -Fq "CLEANUP PASS: sidecar fake OCI fixtures" "$E/09-sidecar-green.log"'
```

### Task 10: Atomic Ironclaw Master-Key Creation

**Covers:** master key mode（场景 14）。

**Files:**
- Create: `lib/ironclaw-master-key.nix`
- Modify: `templates/ironclaw.nix:93-107`
- Modify: `tests/test_ironclaw.sh:129-214`

**Interfaces:**
- Consumes: key target and existing `pkgs.openssl`。
- Produces: atomic mode-0600 64-hex key。

- [ ] **Step 1: Behavior-preserving extraction, then RED**

First extract current direct-write/chmod block into helper without changing order and run `nix flake check --no-build` fail-fast. Then build helper with blocking fake openssl. While writer blocks, baseline-equivalent helper exposes final mode 0644 and prints `FAIL[RED-master-key-mode]: final file visible as mode 0644 during write`。

```powershell
wsl.exe -d nixos -- bash -lc 'set -euo pipefail; cd /mnt/c/Users/hugefiver/source/ocsb; E="${OCSB_REMEDIATION_EVIDENCE_DIR:-${TMPDIR:-/tmp}/ocsb-remediation-2026-07-21-$(id -u)}"; install -d -m 0700 "$E"; nix flake check --no-build; K=$(bash tests/test_ironclaw.sh --build-key-fixture "$E/key-fixture"); test -x "$K"; set +e; bash tests/test_ironclaw.sh --case master-key-window "$K" 2>&1 | tee "$E/10-key-red.log"; rc=${PIPESTATUS[0]}; set -e; test "$rc" -ne 0; grep -Fq "FAIL[RED-master-key-mode]: final file visible as mode 0644 during write" "$E/10-key-red.log"'
```

- [ ] **Step 2: Make creation private and atomic**

Set `umask 077` before `mktemp "$dir/.$base.XXXXXX"`; trap removes temp; openssl writes temp; chmod 0600; `mv -T` publishes; clear trap. Existing nonempty key remains unchanged.

```bash
umask 077
tmp=$(mktemp "$dir/.$base.XXXXXX")
trap 'rm -f -- "$tmp"' EXIT HUP INT TERM
openssl rand -hex 32 >"$tmp"
chmod 0600 "$tmp"
mv -T -- "$tmp" "$target"
trap - EXIT HUP INT TERM
```

- [ ] **Step 3: GREEN/integration**

Blocked writer must see final absent and one mode-600 temp; after release final mode 600, hash stable on rerun, no temp. Kill/wait writer on every path and print `CLEANUP PASS: master-key writer fixtures`。

```powershell
wsl.exe -d nixos -- bash -lc 'set -euo pipefail; cd /mnt/c/Users/hugefiver/source/ocsb; E="${OCSB_REMEDIATION_EVIDENCE_DIR:-${TMPDIR:-/tmp}/ocsb-remediation-2026-07-21-$(id -u)}"; install -d -m 0700 "$E"; K=$(bash tests/test_ironclaw.sh --build-key-fixture "$E/key-fixture"); bash tests/test_ironclaw.sh --case master-key-window "$K" 2>&1 | tee "$E/10-key-green.log"; grep -Fq "PASS[GREEN-master-key-mode]: publish atomic; temporary and final mode 0600" "$E/10-key-green.log"; grep -Fq "CLEANUP PASS: master-key writer fixtures" "$E/10-key-green.log"'
```

### Task 11: Architecture-Correct Ironclaw Outputs

**Covers:** aarch64 x86 variant（场景 15）。

**Files:**
- Modify: `flake.nix:56-62,320-372`
- Create: `tests/test_arch_outputs.sh`

**Interfaces:**
- Consumes: `system` and current version/arch matrix。
- Produces: `ironclawArchsFor system`，aarch64 baseline only，x86_64 baseline plus v3。

- [ ] **Step 1: Exact RED**

Prerequisite eval writes both attr arrays under `$E`; focused script prints `FAIL[RED-aarch64-x86-variant]: aarch64 exports ironclaw_x86_64_v3` only when offending attr exists.

```powershell
wsl.exe -d nixos -- bash -lc 'set -euo pipefail; cd /mnt/c/Users/hugefiver/source/ocsb; E="${OCSB_REMEDIATION_EVIDENCE_DIR:-${TMPDIR:-/tmp}/ocsb-remediation-2026-07-21-$(id -u)}"; install -d -m 0700 "$E"; nix eval --impure --json .#packages.aarch64-linux --apply builtins.attrNames > "$E/aarch64-attrs.json"; nix eval --impure --json .#packages.x86_64-linux --apply builtins.attrNames > "$E/x86-attrs.json"; set +e; bash tests/test_arch_outputs.sh "$E/aarch64-attrs.json" "$E/x86-attrs.json" 2>&1 | tee "$E/11-arch-red.log"; rc=${PIPESTATUS[0]}; set -e; test "$rc" -ne 0; grep -Fq "FAIL[RED-aarch64-x86-variant]: aarch64 exports ironclaw_x86_64_v3" "$E/11-arch-red.log"'
```

- [ ] **Step 2: Filter and GREEN**

`ironclawArchsFor` returns all archs only for x86_64, otherwise `builtins.head ironclawArchs`; both version and latest entries use it. GREEN requires aarch64 absence, x86 presence, and baseline aliases on both. No external package build.

```nix
ironclawArchsFor = system:
  if system == "x86_64-linux" then ironclawArchs else [ (builtins.head ironclawArchs) ];
```

```powershell
wsl.exe -d nixos -- bash -lc 'set -euo pipefail; cd /mnt/c/Users/hugefiver/source/ocsb; E="${OCSB_REMEDIATION_EVIDENCE_DIR:-${TMPDIR:-/tmp}/ocsb-remediation-2026-07-21-$(id -u)}"; install -d -m 0700 "$E"; nix eval --impure --json .#packages.aarch64-linux --apply builtins.attrNames > "$E/aarch64-attrs.json"; nix eval --impure --json .#packages.x86_64-linux --apply builtins.attrNames > "$E/x86-attrs.json"; bash tests/test_arch_outputs.sh "$E/aarch64-attrs.json" "$E/x86-attrs.json" 2>&1 | tee "$E/11-arch-green.log"; grep -Fq "PASS[GREEN-aarch64-x86-variant]: aarch64 baseline-only; x86_64 v3 present" "$E/11-arch-green.log"; nix flake check --no-build'
```

### Task 12: Make Strategy Tests Propagate Failures

**Covers:** swallowed test failure（场景 18）。

**Files:**
- Modify: `tests/test_wrapper.sh:124-169,367-387`
- Modify: `tests/test_git_worktree.sh:30-65`
- Modify: `tests/test_btrfs.sh:44-85`
- Modify: `tests/test_dual_layer.sh:61-159`
- Modify: `tests/test_network.sh:37-63`
- Create: `tests/test_failure_propagation.sh`

**Interfaces:**
- Consumes: real launcher and selective delegate returning 73 only for initial `strat-test` create。
- Produces: exact nested status 73; explicit expected-nonzero assertions。

- [ ] **Step 1: Exact RED**

Fixture creation is fail-fast. Harness prints exact observed mismatch:

```text
FAIL[RED-swallowed-test-failure]: expected=73 actual=0
```

Runner requires both status nonzero and this marker. It cannot pass on another wrapper suite failure.

```powershell
wsl.exe -d nixos -- bash -lc 'set -euo pipefail; cd /mnt/c/Users/hugefiver/source/ocsb; E="${OCSB_REMEDIATION_EVIDENCE_DIR:-${TMPDIR:-/tmp}/ocsb-remediation-2026-07-21-$(id -u)}"; install -d -m 0700 "$E"; OUT=$(nix build --no-link --print-out-paths .#packages.x86_64-linux.default); F=$(bash tests/test_failure_propagation.sh --prepare "$E/failure-fixture" "$OUT/bin/ocsb"); test -x "$F"; set +e; env -u XDG_RUNTIME_DIR bash tests/test_failure_propagation.sh --case strategy-create "$F" 2>&1 | tee "$E/12-failure-red.log"; rc=${PIPESTATUS[0]}; set -e; test "$rc" -ne 0; grep -Fq "FAIL[RED-swallowed-test-failure]: expected=73 actual=0" "$E/12-failure-red.log"'
```

- [ ] **Step 2: Remove swallowing and GREEN**

Remove `|| true` from positive launcher/$SHELL commands. Capture expected network/btrfs nonzero explicitly and assert status/output. Replace `grep -c ... || true` with `awk`. Keep best-effort only in cleanup/fallback whose final state is asserted. GREEN requires `PASS[GREEN-swallowed-test-failure]: exact status 73 propagated` plus full wrapper/git/btrfs suites.

```bash
set +e
"$OCSB" -w strat-test --overwrite -- "$SHELL" -c true
status=$?
set -e
[[ "$status" -eq 73 ]] || { printf 'expected=73 actual=%s\n' "$status" >&2; exit 1; }
```

```powershell
wsl.exe -d nixos -- bash -lc 'set -euo pipefail; cd /mnt/c/Users/hugefiver/source/ocsb; E="${OCSB_REMEDIATION_EVIDENCE_DIR:-${TMPDIR:-/tmp}/ocsb-remediation-2026-07-21-$(id -u)}"; install -d -m 0700 "$E"; OUT=$(nix build --no-link --print-out-paths .#packages.x86_64-linux.default); F=$(bash tests/test_failure_propagation.sh --prepare "$E/failure-fixture" "$OUT/bin/ocsb"); env -u XDG_RUNTIME_DIR bash tests/test_failure_propagation.sh --case strategy-create "$F" 2>&1 | tee "$E/12-failure-green.log"; grep -Fq "PASS[GREEN-swallowed-test-failure]: exact status 73 propagated" "$E/12-failure-green.log"; env -u XDG_RUNTIME_DIR bash tests/test_wrapper.sh "$OUT/bin/ocsb"; env -u XDG_RUNTIME_DIR bash tests/test_git_worktree.sh "$OUT/bin/ocsb"; env -u XDG_RUNTIME_DIR bash tests/test_btrfs.sh "$OUT/bin/ocsb"'
```

### Task 13: Slirp-Owning Monitor with Deterministic Zombie/Reap Proof

**Covers:** filtered FIFO cleanup（场景 17）。

**Files:**
- Modify: `lib/mkSandbox.nix:1221-1265`
- Create: `tests/test_filtered_cleanup.sh`
- Create: `tests/fixtures/fake-filtered-bwrap.sh`
- Create: `tests/fixtures/fake-slirp4netns.sh`
- Modify: `tests/test_network.sh:29-85`

**Interfaces:**
- Consumes: Task 1 start-time parser, launcher PID/start/PGID, workspace lock FD 9, info FIFO。
- Produces: monitor PID that owns FIFO reader and is direct parent/reaper of slirp; foreground bwrap remains launcher PID/start/process group。

- [ ] **Step 1: Prepare deterministic fake topology**

Build a lightweight filtered launcher with fake bwrap/slirp packages before target run. Monitor test uses two barriers: `MONITOR_READY` and `BWRAP_EXIT_ALLOWED`. Fake bwrap records PID/start/PGID, writes child-pid JSON, then exits only after release; caller intentionally delays `wait`, keeping bwrap in Z/X state. Fake slirp records PPID and checks parent has no FD pointing to workspace `.lock`.

Baseline exact markers:

```text
FAIL[RED-filtered-monitor-owner]: slirp parent is launcher, not monitor
FAIL[RED-filtered-zombie-cleanup]: FIFO/temp remain while bwrap state is Z
```

- [ ] **Step 2: Run exact RED**

```powershell
wsl.exe -d nixos -- bash -lc 'set -euo pipefail; cd /mnt/c/Users/hugefiver/source/ocsb; E="${OCSB_REMEDIATION_EVIDENCE_DIR:-${TMPDIR:-/tmp}/ocsb-remediation-2026-07-21-$(id -u)}"; install -d -m 0700 "$E"; N=$(bash tests/test_filtered_cleanup.sh --prepare "$E/filtered-fixture"); test -x "$N"; set +e; env -u XDG_RUNTIME_DIR bash tests/test_filtered_cleanup.sh --case monitor-topology "$N" 2>&1 | tee "$E/13-filtered-red.log"; rc=${PIPESTATUS[0]}; set -e; test "$rc" -ne 0; grep -Fq "FAIL[RED-filtered-monitor-owner]: slirp parent is launcher, not monitor" "$E/13-filtered-red.log"; grep -Fq "FAIL[RED-filtered-zombie-cleanup]: FIFO/temp remain while bwrap state is Z" "$E/13-filtered-red.log"'
```

- [ ] **Step 3: Implement owning monitor topology**

Launcher creates temp/FIFO and forks one monitor before exec. Monitor immediately closes FD 9 and all unrelated FDs, then writes readiness receipt; launcher refuses to exec bwrap until receipt confirms lock closure. Monitor opens/owns FIFO reader, reads child PID, forks slirp itself, records slirp PID/start, and remains its parent. Launcher records its own PID/start/PGID and `exec`s bwrap in foreground without fork, preserving same PID/start/process group and TTY.

Monitor polls launcher `/proc/$pid/stat`; mismatched start or state `Z`/`X` means bwrap lifetime ended. Before signaling slirp it verifies slirp start time; sends TERM, bounded wait, KILL only after a second start-time check, then `wait`s/reaps its child. It removes FIFO/control/temp paths idempotently after reaping. Signal traps use the same cleanup function. Monitor never signals bwrap and cannot retain FD 9.

```bash
filtered_monitor() {
  exec 9>&-
  printf 'MONITOR_READY\n' >"$ready_pipe"
  IFS= read -r child_json <"$info_fifo"
  slirp4netns --configure --mtu=65520 "$child_pid" tap0 &
  slirp_pid=$!
  slirp_start=$(proc_start_once "$slirp_pid") || exit 1
  wait_for_bwrap_dead_or_zombie "$launcher_pid" "$launcher_start"
  terminate_exact "$slirp_pid" "$slirp_start"
  wait "$slirp_pid"
  cleanup_filtered_paths
}
```

- [ ] **Step 4: GREEN and real secondary**

Deterministic case must prove monitor readiness precedes bwrap exec, slirp PPID equals monitor, lock FD absent, bwrap PID/start/PGID unchanged, Z-state recognized before caller `wait`, slirp `/proc` entry absent after monitor wait, and temp parent empty. Required marker: `PASS[GREEN-filtered-monitor]: owner=monitor fd9=closed zombie=recognized slirp=reaped temp=removed`。

Then build real net-test. Capable host runs twice and checks empty temp parent/second lock acquisition. Exact local lack marker is `SKIP[CI-REQUIRED-real-filtered-network]: userns or RTM_NEWADDR unavailable`; all other errors fail. Test prints `CLEANUP PASS: filtered network temp` only after saved PIDs are dead and paths absent.

```powershell
wsl.exe -d nixos -- bash -lc 'set -euo pipefail; cd /mnt/c/Users/hugefiver/source/ocsb; E="${OCSB_REMEDIATION_EVIDENCE_DIR:-${TMPDIR:-/tmp}/ocsb-remediation-2026-07-21-$(id -u)}"; install -d -m 0700 "$E"; N=$(bash tests/test_filtered_cleanup.sh --prepare "$E/filtered-fixture"); env -u XDG_RUNTIME_DIR bash tests/test_filtered_cleanup.sh --case monitor-topology "$N" 2>&1 | tee "$E/13-filtered-green.log"; grep -Fq "PASS[GREEN-filtered-monitor]: owner=monitor fd9=closed zombie=recognized slirp=reaped temp=removed" "$E/13-filtered-green.log"; NET=$(nix build --no-link --print-out-paths .#checks.x86_64-linux.net-test); env -u XDG_RUNTIME_DIR bash tests/test_filtered_cleanup.sh --case real-secondary "$NET/bin/ocsb-net-test" 2>&1 | tee -a "$E/13-filtered-green.log"; grep -Fq "CLEANUP PASS: filtered network temp" "$E/13-filtered-green.log"'
```

### Task 14: CI Runtime Gates and Capability-Based Results

**Covers:** CI runtime gate（场景 16）。

**Files:**
- Modify: `.github/workflows/ci.yml:40-50,82-89,145-180`
- Modify: `tests/test_hermes_agent.sh:90-102`
- Modify: `tests/test_ironclaw.sh:45-48`
- Create: `tests/test_ci_runtime.sh`

**Interfaces:**
- Consumes: default/net/dual outputs, fake anchor/monitor fixtures, local rootless Podman on a native Linux runner, built external wrappers only in dedicated CI jobs。
- Produces: core tests always run; capability skip is exact; no `GITHUB_ACTIONS` unconditional success; dedicated `podman-anchor-test` job cannot skip/fail-soft and emits `PASS[GREEN-real-rootless-podman-anchor]`。

- [ ] **Step 1: Exact RED contract**

`test_ci_runtime.sh` checks workflow contains wrapper/backend/binpath/git/btrfs, both dual fixtures, fake mount-anchor, fake filtered monitor, network, Hermes and Ironclaw invocations; checks `env -u XDG_RUNTIME_DIR`; rejects unconditional GitHub skips. It additionally requires a dedicated `podman-anchor-test` native-Linux job that enters `nix develop .#backend-test -c bash -c`（非 login shell）, runs `tests/test_mount_anchor.sh --case real-rootless-podman`, requires Podman rootless mode, captures `HOST_UID=$(id -u)` inside the run script, and asserts `command -v podman` matches `/nix/store/*/bin/podman`. The job contains no job-level `${{ }}` UID substitution, login shell, `continue-on-error`, `|| true`, capability skip, host package installation, or remote Podman path, and greps `PASS[GREEN-real-rootless-podman-anchor]: uid=$HOST_UID source=original`. Baseline prints `FAIL[RED-ci-runtime-gate]: core runtime commands missing and GITHUB_ACTIONS skip present`。

- [ ] **Step 2: Run exact RED**

```powershell
wsl.exe -d nixos -- bash -lc 'set -euo pipefail; cd /mnt/c/Users/hugefiver/source/ocsb; E="${OCSB_REMEDIATION_EVIDENCE_DIR:-${TMPDIR:-/tmp}/ocsb-remediation-2026-07-21-$(id -u)}"; install -d -m 0700 "$E"; set +e; bash tests/test_ci_runtime.sh 2>&1 | tee "$E/14-ci-red.log"; rc=${PIPESTATUS[0]}; set -e; test "$rc" -ne 0; grep -Fq "FAIL[RED-ci-runtime-gate]: core runtime commands missing and GITHUB_ACTIONS skip present" "$E/14-ci-red.log"'
```

- [ ] **Step 3: Wire CI without local external builds**

Use `--no-link --print-out-paths` to avoid result collisions. Build job runs default/core, deterministic mount-anchor, both dual fixtures, deterministic filtered monitor, arch/failure/CI tests, then real network/btrfs where capability exists. Fake tests may never skip. Remote Podman refusal remains a product PASS, not skip. Add `devShells.${system}.backend-test` using the already locked root `nixpkgs` with only `pkgs.podman` plus the existing default test tools; this is an ephemeral Nix test environment, not a host package installation or product runtime dependency. Add this separate required native-Linux lane using the same pinned checkout/Nix installer actions:

```yaml
- name: Run deterministic runtime suites
  run: |
    env -u XDG_RUNTIME_DIR bash tests/test_mount_anchor.sh --ci-fake
    env -u XDG_RUNTIME_DIR bash tests/test_filtered_cleanup.sh --ci-fake
    bash tests/test_ci_runtime.sh

podman-anchor-test:
  runs-on: ubuntu-latest
  needs: build
  steps:
    - uses: actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5
    - uses: DeterminateSystems/nix-installer-action@00199f951aeb9404028a6e4b95ad42546f73296a
    - name: Verify real rootless Podman mount anchoring
      run: |
        set -euo pipefail
        nix develop .#backend-test -c bash -c '
          set -euo pipefail
          PODMAN_BIN=$(command -v podman)
          case "$PODMAN_BIN" in /nix/store/*/bin/podman) ;; *) printf "unexpected podman: %s\n" "$PODMAN_BIN" >&2; exit 1 ;; esac
          LOG="$RUNNER_TEMP/14-real-podman-green.log"
          printf "PODMAN_BIN=%s\n" "$PODMAN_BIN" | tee "$LOG"
          test "$(podman info --format "{{.Host.Security.Rootless}}")" = true
          HOST_UID=$(id -u)
          OUT=$(nix build --no-link --print-out-paths .#packages.x86_64-linux.default)
          env -u XDG_RUNTIME_DIR bash tests/test_mount_anchor.sh \
            --case real-rootless-podman "$OUT/bin/ocsb" \
            | tee -a "$LOG"
          grep -Fq "PASS[GREEN-real-rootless-podman-anchor]: uid=$HOST_UID source=original" \
            "$LOG"
        '
```

Hermes job runs real test only after CI/Cachix build; Ironclaw test retains built-wrapper run. Their help/source/fake cases always run; real bwrap smoke skips only exact kernel denial. Remove all `GITHUB_ACTIONS` branches.

- [ ] **Step 4: GREEN**

Local command runs CI contract plus Hermes/Ironclaw lightweight fixtures and `nix flake check --no-build`; no external app output is built. Required local marker: `PASS[GREEN-ci-runtime-gate]: all runtime commands present; skips capability-based`。Final acceptance additionally requires the actual `podman-anchor-test` job log to be saved as `$E/14-real-podman-green.log` and contain `PASS[GREEN-real-rootless-podman-anchor]: uid=HOST_UID source=original`; a planned workflow command or local fake marker is not sufficient. Because Commit Guard prevents push without explicit permission, implementation may finish locally but must remain `CI evidence pending` until the user authorizes a push/run or supplies an equivalent native-Linux rootless Podman environment.

```powershell
wsl.exe -d nixos -- bash -lc 'set -euo pipefail; cd /mnt/c/Users/hugefiver/source/ocsb; E="${OCSB_REMEDIATION_EVIDENCE_DIR:-${TMPDIR:-/tmp}/ocsb-remediation-2026-07-21-$(id -u)}"; install -d -m 0700 "$E"; bash tests/test_ci_runtime.sh 2>&1 | tee "$E/14-ci-green.log"; grep -Fq "PASS[GREEN-ci-runtime-gate]: all runtime commands present; skips capability-based" "$E/14-ci-green.log"; bash tests/test_hermes_agent.sh --source-only; bash tests/test_ironclaw.sh --source-only; nix flake check --no-build'
```

### Task 15: Final Validation and Temporary Evidence Manifest

**Covers:** 全部 18 场景的集成验收。

**Files:**
- Verify: every production/test file in File Map
- Runtime artifact only: `$E/manifest.md` and `$E/*-{red,green}.log`（不加入仓库）

**Interfaces:**
- Consumes: Tasks 1–14 exact logs/markers。
- Produces: 18-row temporary manifest, final validation log, cleanup receipt, handoff evidence path。

- [ ] **Step 1: Run syntax/eval/default/lightweight gates**

```powershell
wsl.exe -d nixos -- bash -lc 'set -euo pipefail; cd /mnt/c/Users/hugefiver/source/ocsb; E="${OCSB_REMEDIATION_EVIDENCE_DIR:-${TMPDIR:-/tmp}/ocsb-remediation-2026-07-21-$(id -u)}"; install -d -m 0700 "$E"; { find tests -maxdepth 2 -type f -name "*.sh" -print0 | xargs -0 -n1 bash -n; nix flake check --no-build; DEFAULT_OUT=$(nix build --no-link --print-out-paths .#packages.x86_64-linux.default); env -u XDG_RUNTIME_DIR bash tests/test_wrapper.sh "$DEFAULT_OUT/bin/ocsb"; bash tests/test_backend.sh .; bash tests/test_binpath.sh .; env -u XDG_RUNTIME_DIR bash tests/test_git_worktree.sh "$DEFAULT_OUT/bin/ocsb"; env -u XDG_RUNTIME_DIR bash tests/test_btrfs.sh "$DEFAULT_OUT/bin/ocsb"; nix eval --impure --json .#packages.aarch64-linux --apply builtins.attrNames >"$E/aarch64-attrs.json"; nix eval --impure --json .#packages.x86_64-linux --apply builtins.attrNames >"$E/x86-attrs.json"; bash tests/test_arch_outputs.sh "$E/aarch64-attrs.json" "$E/x86-attrs.json"; F=$(bash tests/test_failure_propagation.sh --prepare "$E/failure-fixture" "$DEFAULT_OUT/bin/ocsb"); env -u XDG_RUNTIME_DIR bash tests/test_failure_propagation.sh --case strategy-create "$F"; bash tests/test_ci_runtime.sh; bash tests/test_hermes_agent.sh --source-only; bash tests/test_ironclaw.sh --source-only; } 2>&1 | tee "$E/15-final-validation.log"'
```

- [ ] **Step 2: Run mount-anchor, dual and filtered gates**

Prepare fixtures under `$E`, run deterministic fake cases first and require no skip. Run both dual outputs independently. Run real bwrap/network when capable; Podman/nspawn absence/privilege uses only named CI-required markers. A fake case skip is a final failure.

```powershell
wsl.exe -d nixos -- bash -lc 'set -euo pipefail; cd /mnt/c/Users/hugefiver/source/ocsb; E="${OCSB_REMEDIATION_EVIDENCE_DIR:-${TMPDIR:-/tmp}/ocsb-remediation-2026-07-21-$(id -u)}"; { F="$E/mount-anchor-fixture"; V="$E/15-mount-anchor-validation.log"; bash tests/test_mount_anchor.sh --prepare "$F"; env -u XDG_RUNTIME_DIR bash tests/test_mount_anchor.sh --case deterministic-swap "$F" 2>&1 | tee "$V"; ! rg -F "SKIP[CI-REQUIRED-mount-anchor]" "$V"; env -u XDG_RUNTIME_DIR bash tests/test_mount_anchor.sh --case optional-source-absent "$F" 2>&1 | tee -a "$V"; grep -Fq "PASS[GREEN-optional-mount]: bubblewrap=omitted podman=omitted nspawn=omitted required=anchored" "$V"; env -u XDG_RUNTIME_DIR bash tests/test_mount_anchor.sh --case nested-symlink "$F" 2>&1 | tee -a "$V"; env -u XDG_RUNTIME_DIR bash tests/test_mount_anchor.sh --case workspace-mutation-parent-swap "$F" 2>&1 | tee -a "$V"; grep -Fq "PASS[GREEN-workspace-mutation-parent-swap]: original-reset victim-unchanged backend-refused" "$V"; grep -Fq "PASS[GREEN-workspace-post-mutation-swap]: identity-mismatch victim-unchanged" "$V"; test -d "$F/runtime/anchors"; test -z "$(find "$F/runtime/anchors" -mindepth 1 -print -quit)"; printf "%s\n" "CLEANUP PASS: no host per-run mount anchors" | tee -a "$V"; D=$(nix build --no-link --print-out-paths .#checks.x86_64-linux.dual-layer-default-test); H=$(nix build --no-link --print-out-paths .#checks.x86_64-linux.dual-layer-home-test); env -u XDG_RUNTIME_DIR bash tests/test_dual_layer_host.sh --case env "$D/bin/ocsb-dual-test"; env -u XDG_RUNTIME_DIR bash tests/test_dual_layer_host.sh --case sandbox-dir "$H/bin/ocsb-dual-home-test"; N=$(bash tests/test_filtered_cleanup.sh --prepare "$E/filtered-fixture"); env -u XDG_RUNTIME_DIR bash tests/test_filtered_cleanup.sh --case monitor-topology "$N"; NET=$(nix build --no-link --print-out-paths .#checks.x86_64-linux.net-test); env -u XDG_RUNTIME_DIR bash tests/test_filtered_cleanup.sh --case real-secondary "$NET/bin/ocsb-net-test"; } 2>&1 | tee -a "$E/15-final-validation.log"'
```

Run the independent post-mutation/pre-final-open barrier as a separate process and require its marker in the same validation log:

```powershell
wsl.exe -d nixos -- bash -lc 'set -euo pipefail; cd /mnt/c/Users/hugefiver/source/ocsb; E="${OCSB_REMEDIATION_EVIDENCE_DIR:-${TMPDIR:-/tmp}/ocsb-remediation-2026-07-21-$(id -u)}"; env -u XDG_RUNTIME_DIR bash tests/test_mount_anchor.sh --case workspace-post-mutation-swap "$E/mount-anchor-fixture" 2>&1 | tee -a "$E/15-mount-anchor-validation.log"; grep -Fq "PASS[GREEN-workspace-post-mutation-swap]: identity-mismatch victim-unchanged" "$E/15-mount-anchor-validation.log"'
```

- [ ] **Step 3: Write temporary manifest with all 18 rows**

Manifest columns are `Scenario | Task | RED log | exact RED marker | GREEN log | exact GREEN marker | Environment`. Rows map:

| # | Scenario | Task |
|---:|---|---:|
| 1 | nested workspace symlink | 3 |
| 2 | runtime pidfile clobber | 1 |
| 3 | Hermes replace identity | 2 |
| 4 | workspace mount and mutation TOCTOU | 3 |
| 5 | container rootfs persistence | 4 |
| 6 | dual-layer sandboxDir | 5 |
| 7 | dual-layer env | 5 |
| 8 | generic daemon pip | 6 |
| 9 | Hermes caller file + secret | 7 |
| 10 | gateway race/PID | 8 |
| 11 | sidecar identity | 9 |
| 12 | sidecar concurrency | 9 |
| 13 | mutable sidecar image | 9 |
| 14 | master key mode | 10 |
| 15 | aarch64 x86 variant | 11 |
| 16 | CI runtime gate | 14 |
| 17 | filtered FIFO cleanup | 13 |
| 18 | swallowed test failure | 12 |

Each row references the exact marker asserted by its Task. `Environment` is `local-WSL`, `local-lightweight`, or `CI-required:<capability>`.

Scenario 4 keeps the existing post-open mount marker in the 18-row table for compatibility, but acceptance additionally requires nonempty `03-workspace-mutation-red.log` and `03-workspace-mutation-green.log` with both exact mutation GREEN markers and `CLEANUP PASS: workspace mutation fixtures`; these supplemental receipts cannot be replaced by the mount marker.

Write `$E/manifest.md` with one literal row for every scenario:

```powershell
wsl.exe -d nixos -- bash -lc 'set -euo pipefail; E="${OCSB_REMEDIATION_EVIDENCE_DIR:-${TMPDIR:-/tmp}/ocsb-remediation-2026-07-21-$(id -u)}"; M="$E/manifest.md"; printf "%s\n" "| Scenario | Task | RED log | exact RED marker | GREEN log | exact GREEN marker | Environment |" "|---|---:|---|---|---|---|---|" "| nested workspace symlink | 3 | 03-nested-symlink-red.log | FAIL[RED-nested-workspace-symlink]: victim modified | 03-nested-symlink-green.log | PASS[GREEN-nested-workspace-symlink]: all nested symlinks refused; victims unchanged | local-lightweight |" "| runtime pidfile clobber | 1 | 01-runtime-pidfile-red.log | FAIL[RED-runtime-pidfile-clobber]: launcher followed pidfile symlink and changed canary | 01-runtime-pidfile-green.log | PASS[GREEN-runtime-pidfile-clobber]: unsafe record rejected; canary unchanged | local-WSL |" "| Hermes replace identity | 2 | 02-hermes-replace-red.log | FAIL[RED-hermes-replace-identity]: cross-persist or non-bwrap fixture was signaled | 02-hermes-replace-green.log | PASS[GREEN-hermes-replace-identity]: fixtures alive; replacement refused | local-lightweight |" "| workspace post-open TOCTOU | 3 | 03-mount-anchor-red.log | FAIL[RED-mount-anchor-bubblewrap]: observed=victim | 03-mount-anchor-green.log | PASS[GREEN-post-open-swap]: original pathname now victim; anchored marker still original | local-lightweight |" "| container rootfs persistence | 4 | 04-rootfs-red.log | FAIL[RED-container-rootfs-persistence]: podman=present nspawn=present | 04-rootfs-green.log | PASS[GREEN-container-rootfs-persistence]: podman=absent nspawn=absent | local-lightweight |" "| dual-layer sandboxDir | 5 | 05-dual-dir-red.log | FAIL[RED-dual-layer-sandboxdir]: inner wrapper required /workspace | 05-dual-dir-green.log | PASS[GREEN-dual-layer-sandboxdir]: pwd=/home/sandbox | local-WSL |" "| dual-layer env | 5 | 05-dual-env-red.log | FAIL[RED-dual-layer-env]: inner FOO is empty | 05-dual-env-green.log | PASS[GREEN-dual-layer-env]: FOO=bar | local-WSL |" "| generic daemon pip | 6 | 06-daemon-red.log | FAIL[RED-generic-daemon-pip]: supervisor contains Hermes venv or pip | 06-daemon-green.log | PASS[GREEN-generic-daemon-pip]: source clean; offline daemon and foreground markers present | local-lightweight |" "| Hermes caller file + secret | 7 | 07-hermes-secret-red.log | FAIL[RED-hermes-caller-file-secret]: combination launched and secret was omitted | 07-hermes-secret-green.log | PASS[GREEN-hermes-caller-file-secret]: nonzero merge diagnostic; caller hash unchanged; launcher log empty | local-lightweight |" "| gateway race/PID | 8 | 08-gateway-red.log | FAIL[RED-gateway-race]: spawn_count=8 reservation_hits=0 | 08-gateway-green.log | PASS[GREEN-gateway-race]: spawn_count=1 reservation_hits=7 | local-lightweight |" "| sidecar identity | 9 | 09-sidecar-red.log | FAIL[RED-sidecar-identity]: wrong image,volume,port reused | 09-sidecar-green.log | PASS[GREEN-sidecar-identity]: mismatch refused before mutation | local-lightweight |" "| sidecar concurrency | 9 | 09-sidecar-red.log | FAIL[RED-sidecar-concurrency]: create_count=2 lock_probe=unlocked | 09-sidecar-green.log | PASS[GREEN-sidecar-concurrency]: create_count=1 lock_probe=locked password_consistent | local-lightweight |" "| mutable sidecar image | 9 | 09-sidecar-red.log | FAIL[RED-sidecar-image]: default is floating :pg18 | 09-sidecar-green.log | PASS[GREEN-sidecar-image]: docker.io/pgvector/pgvector:pg18@sha256:12a379b47ad65289572ea0756efc11b7c241a6662833e8af7038cd3b73d647e0 | local-lightweight |" "| master key mode | 10 | 10-key-red.log | FAIL[RED-master-key-mode]: final file visible as mode 0644 during write | 10-key-green.log | PASS[GREEN-master-key-mode]: publish atomic; temporary and final mode 0600 | local-lightweight |" "| aarch64 x86 variant | 11 | 11-arch-red.log | FAIL[RED-aarch64-x86-variant]: aarch64 exports ironclaw_x86_64_v3 | 11-arch-green.log | PASS[GREEN-aarch64-x86-variant]: aarch64 baseline-only; x86_64 v3 present | local-WSL |" "| CI runtime gate | 14 | 14-ci-red.log | FAIL[RED-ci-runtime-gate]: core runtime commands missing and GITHUB_ACTIONS skip present | 14-ci-green.log | PASS[GREEN-ci-runtime-gate]: all runtime commands present; skips capability-based | local-lightweight |" "| filtered FIFO cleanup | 13 | 13-filtered-red.log | FAIL[RED-filtered-zombie-cleanup]: FIFO/temp remain while bwrap state is Z | 13-filtered-green.log | PASS[GREEN-filtered-monitor]: owner=monitor fd9=closed zombie=recognized slirp=reaped temp=removed | local-lightweight |" "| swallowed test failure | 12 | 12-failure-red.log | FAIL[RED-swallowed-test-failure]: expected=73 actual=0 | 12-failure-green.log | PASS[GREEN-swallowed-test-failure]: exact status 73 propagated | local-lightweight |" >"$M"; test "$(awk -F"|" "NR>2 && NF==9 {n++} END {print n+0}" "$M")" -eq 18'
```

- [ ] **Step 4: Audit evidence and cleanup**

Audit requires each scenario exactly once; every referenced log nonempty; each exact marker present; no generic nonzero-only RED; deterministic gateway marker `8/0` and GREEN `1/7`; deterministic OCI RED `create_count=2` and GREEN `create_count=1`; dual scenarios in different logs; fake mount-anchor and fake monitor GREEN cannot be skipped. Mount-anchor evidence additionally requires directory/regular-file type preservation, original bwrap/Podman/nspawn UID flags, optional-group preservation, empty host anchor root, mutation parent-swap RED/GREEN receipts, and a nonempty real native-Linux rootless Podman CI log containing `PASS[GREEN-real-rootless-podman-anchor]`; no skip or fake substitute satisfies this final gate. Check all cleanup receipts and saved PID files report dead processes; controlled temp/fake OCI paths absent.

```powershell
wsl.exe -d nixos -- bash -lc 'set -euo pipefail; E="${OCSB_REMEDIATION_EVIDENCE_DIR:-${TMPDIR:-/tmp}/ocsb-remediation-2026-07-21-$(id -u)}"; M="$E/manifest.md"; test "$(awk -F"|" "NR>2 && NF==9 {n++} END {print n+0}" "$M")" -eq 18; test "$(awk -F"|" "NR>2 && NF==9 {gsub(/^ +| +$/,"",$2); print $2}" "$M" | sort -u | wc -l)" -eq 18; while IFS="|" read -r _ scenario task red red_marker green green_marker environment _; do red=${red# }; red=${red% }; green=${green# }; green=${green% }; red_marker=${red_marker# }; red_marker=${red_marker% }; green_marker=${green_marker# }; green_marker=${green_marker% }; test -s "$E/$red"; test -s "$E/$green"; grep -Fq "$red_marker" "$E/$red"; grep -Fq "$green_marker" "$E/$green"; done < <(tail -n +3 "$M"); grep -Fq "FAIL[RED-gateway-race]: spawn_count=8 reservation_hits=0" "$E/08-gateway-red.log"; grep -Fq "PASS[GREEN-gateway-race]: spawn_count=1 reservation_hits=7" "$E/08-gateway-green.log"; grep -Fq "FAIL[RED-sidecar-concurrency]: create_count=2 lock_probe=unlocked" "$E/09-sidecar-red.log"; grep -Fq "PASS[GREEN-sidecar-concurrency]: create_count=1 lock_probe=locked password_consistent" "$E/09-sidecar-green.log"; ! rg -F "SKIP[CI-REQUIRED-mount-anchor]" "$E/03-mount-anchor-green.log"; grep -Fq "PASS[GREEN-anchor-types]: directory=directory regular=regular" "$E/03-mount-anchor-green.log"; grep -Fq "PASS[GREEN-id-semantics]:" "$E/03-mount-anchor-green.log"; grep -Fq "PASS[GREEN-optional-mount]: bubblewrap=omitted podman=omitted nspawn=omitted required=anchored" "$E/03-mount-anchor-green.log"; grep -Fq "CLEANUP PASS: no host per-run mount anchors" "$E/03-mount-anchor-green.log"; test -s "$E/14-real-podman-green.log"; grep -Eq "^PODMAN_BIN=/nix/store/.*/bin/podman$" "$E/14-real-podman-green.log"; grep -Eq "^PASS\[GREEN-real-rootless-podman-anchor\]: uid=[0-9]+ source=original$" "$E/14-real-podman-green.log"; ! rg -F "SKIP[" "$E/14-real-podman-green.log"; grep -Fq "CLEANUP PASS: gateway fixtures" "$E/08-gateway-green.log"; grep -Fq "CLEANUP PASS: sidecar fake OCI fixtures" "$E/09-sidecar-green.log"; grep -Fq "CLEANUP PASS: filtered network temp" "$E/13-filtered-green.log"; printf "%s\n" "18 scenarios mapped; exact RED=18; exact GREEN=18; real rootless Podman PASS; deterministic barriers PASS; cleanup PASS" "EVIDENCE_DIR=$E"'
```

The same audit must run these supplemental mutation checks before printing the final receipt:

```powershell
wsl.exe -d nixos -- bash -lc 'set -euo pipefail; E="${OCSB_REMEDIATION_EVIDENCE_DIR:-${TMPDIR:-/tmp}/ocsb-remediation-2026-07-21-$(id -u)}"; test -s "$E/03-workspace-mutation-red.log"; test -s "$E/03-workspace-mutation-green.log"; grep -Fq "FAIL[RED-workspace-mutation-parent-swap]: victim-marker=deleted original-marker=present" "$E/03-workspace-mutation-red.log"; grep -Fq "FAIL[RED-workspace-post-mutation-swap]: backend-observed=replacement" "$E/03-workspace-mutation-red.log"; grep -Fq "PASS[GREEN-workspace-mutation-parent-swap]: original-reset victim-unchanged backend-refused" "$E/03-workspace-mutation-green.log"; grep -Fq "PASS[GREEN-workspace-post-mutation-swap]: identity-mismatch victim-unchanged" "$E/03-workspace-mutation-green.log"; grep -Fq "CLEANUP PASS: workspace mutation fixtures" "$E/03-workspace-mutation-green.log"'
```

Final output is:

```text
18 scenarios mapped; exact RED=18; exact GREEN=18; real rootless Podman PASS; deterministic barriers PASS; cleanup PASS
EVIDENCE_DIR=/tmp/ocsb-remediation-2026-07-21-1000
```

The numeric UID portion is produced by `id -u`; handoff reports the actual absolute path. Do not copy this evidence tree into the repository.

## Final Review Remediation Amendment

本 amendment 是 Tasks 1–15 之后的强制执行层。它不重写或删除 Task 15 的原始 18-row `$E/manifest.md`；Task 19 另建 `$E/final-review-remediation-manifest.md`，只对最终复审新增的四项缺陷行使 authority。所有命令固定使用 `E=/tmp/ocsb-remediation-2026-07-21-1000`，先从当前 working tree 创建无 `.git` snapshot，再从 snapshot 执行 Nix，确保未跟踪的 `pkgs/*.nix`、C source 和 fixtures 被纳入。任何 native OCI 结果在用户授权 push/workflow run 之前都必须保持 pending。

### Task 16: Race-Free Retained Receipt FD Retirement

**Covers:** receipt consume 在校验 predictable cleanup/quarantine 名称后按 pathname `unlinkat`，可能删除攻击者换入的对象；消费重试会再次操作已经变化的 namespace。

**Files:**
- Modify: `pkgs/ocsb-mount-anchor.c:145-161,194-238,882-1180,2650-2872,2937-3135,4375-4542`
- Modify: `tests/test_mount_anchor.sh:17-39,163-179,189-365,833-940,1740-1842`

**Interfaces:**
- Consumes: 已打开的 canonical receipt `.workspace-receipt-$nonce`、其 parent dirfd、`workspace_receipt_data.file_stat/line`、现有 `RENAME_EXCHANGE` 与 `RENAME_NOREPLACE`。
- Produces: `workspace_receipt_data.receipt_fd`（从 load 到 free 始终保持打开）与 `workspace_receipt_data.consume_attempted`；nonce-scoped names `.workspace-receipt-$nonce.guard.%02u` 和 `.workspace-receipt-$nonce.spent.%02u`（每类 00–99）；test-only ABI `--test-after-moved-guard-validation-{ready,release}-fd`、`--test-after-quarantined-receipt-validation-{ready,release}-fd`；成功时 canonical 缺失、exact receipt FD 被 `ftruncate(0)` + `fsync` retire、恰好保留两个 current-UID mode-0600 zero-length harmless artifacts。

- [ ] **Step 1: Add two independent post-validation swap RED tests**

`tests/test_mount_anchor.sh --case receipt-retain-retire FIXTURE` 依次启动三个隔离子场景：normal success、moved-guard post-validation swap、quarantined-receipt post-validation swap。两个 swap 各有独立 ready/release FIFO pair；ready byte 只能在对应 pathname 已经完成 dev/ino/mode 校验后写出。协调器把被校验名称 rename 到保存名，再把 mode-0600 replacement rename 到该名称；记录 replacement 的 `stat -c '%d:%i:%a:%s'` 与 SHA-256，release 后必须逐字节、逐 inode 相同。两个 barrier 不能共用 FD、marker 或 case directory。

先在测试中加入以下 exact RED 输出；当前实现缺少 post-validation ABI 或删除 replacement 时 aggregate case 必须非零：

```text
FAIL[RED-receipt-moved-guard-swap]: validated-name replacement was removed or changed
FAIL[RED-receipt-quarantine-swap]: validated-name replacement was removed or changed
FAIL[RED-receipt-retain-retire]: consume path pathname-unlinked a post-validation replacement
```

同时加入 slot-exhaustion control：预建同 nonce 的 100 个 guard slots，helper 必须不执行 backend、不得改变 canonical receipt。production binary 必须继续把四个新 test-only options 报为 `unknown option`；只有 `OCSB_MOUNT_ANCHOR_TEST_HOOKS` binary 接受完整 pair。

- [ ] **Step 2: Run exact Task 16 RED from a no-.git snapshot**

```powershell
wsl.exe -d nixos -- bash -lc 'set -euo pipefail; SRC=/mnt/c/Users/hugefiver/source/ocsb; E=/tmp/ocsb-remediation-2026-07-21-1000; SNAP="$E/16-red-source"; F="$E/16-red-fixture"; LOG="$E/16-receipt-retire-red.log"; cleanup(){ set +e; find "$F" "$SNAP" -type d -exec chmod u+w {} + 2>/dev/null; rm -rf -- "$F" "$SNAP"; }; trap cleanup EXIT HUP INT TERM; install -d -m 0700 "$E"; rm -rf -- "$SNAP" "$F"; install -d -m 0700 "$SNAP"; tar --exclude=./.git -C "$SRC" -cf - . | tar -C "$SNAP" -xf -; test ! -e "$SNAP/.git"; cd "$SNAP"; bash tests/test_mount_anchor.sh --prepare "$F" >/dev/null; set +e; env -u XDG_RUNTIME_DIR bash tests/test_mount_anchor.sh --case receipt-retain-retire "$F" 2>&1 | tee "$LOG"; rc=${PIPESTATUS[0]}; set -e; test "$rc" -ne 0; grep -Fq "FAIL[RED-receipt-moved-guard-swap]: validated-name replacement was removed or changed" "$LOG"; grep -Fq "FAIL[RED-receipt-quarantine-swap]: validated-name replacement was removed or changed" "$LOG"; grep -Fq "FAIL[RED-receipt-retain-retire]: consume path pathname-unlinked a post-validation replacement" "$LOG"; chmod 0444 "$LOG"'
```

Expected: command exits zero only after the target case itself exited nonzero and all three exact RED markers were captured in `$E/16-receipt-retire-red.log`; missing helper, fixture build failure, timeout, or unrelated stderr cannot satisfy RED。

- [ ] **Step 3: Implement retain-and-FD-retire with zero consume-path unlink**

Change `workspace_receipt_data` to own the exact file descriptor and one-shot state:

```c
struct workspace_receipt_data {
  char *line;
  char *fields_storage;
  char *fields[17];
  int parent_fd;
  int receipt_fd;
  bool consume_attempted;
  struct stat file_stat;
  dev_t project_dev;
  ino_t project_ino;
  dev_t base_dev;
  ino_t base_ino;
  dev_t workspace_dev;
  ino_t workspace_ino;
  dev_t child_dev;
  ino_t child_ino;
  enum workspace_strategy strategy;
  enum backend_type backend;
};
```

`load_workspace_receipt()` assigns `receipt->receipt_fd` and never closes it; `free_workspace_receipt()` closes `receipt_fd` and `parent_fd`. `consume_workspace_receipt()` uses this exact state machine:

```text
if consume_attempted: fail EALREADY
consume_attempted = true
validate parent fd and fstat(receipt_fd) against loaded file_stat
create one O_EXCL mode0600 guard slot; keep guard_fd open
RENAME_EXCHANGE(canonical, guard_name)
RENAME_NOREPLACE(canonical, spent_name)       # canonical becomes absent
fstatat(spent_name) == fstat(guard_fd)        # validate moved guard
TEST BARRIER: after-moved-guard-validation
fstatat(guard_name) == fstat(receipt_fd)
pread(receipt_fd) == loaded exact line         # validate quarantined receipt
TEST BARRIER: after-quarantined-receipt-validation
ftruncate(receipt_fd, 0)
fsync(receipt_fd)
fsync(parent_fd)
close guard_fd; leave guard_name and spent_name in place
```

`create_receipt_guard_slot()` 和 `consume_workspace_receipt()` 的完整调用路径中必须出现 **零个** `unlinkat`/`unlink`：guard 创建后的 chmod/fstat/close 失败也保留该 mode-0600 artifact 并 fail closed。`discard_nonce_matching_workspace_receipt()` 在 `consume_attempted=true` 时不得重试；`main` cleanup 只能 close/free。100 个同 nonce guard slots 或 100 个 spent slots 全部占用时返回固定前缀 `ocsb: workspace receipt: retained slot exhaustion:`，canonical 保持不变，backend 不执行。

Normal success 保留 exactly two zero-length artifacts。post-validation swap 不影响已经原子移除的 authorization：helper 只 retire held receipt FD，不再解析或删除两个 pathname；backend 明确继续执行，replacement 自身 inode/bytes 保持不变。测试 fixture 可在 helper/backend 全部退出后递归删除整个 private case directory；这就是唯一允许的 cleanup。产品 hot path 不回收 retained generation。需要回收历史 generation 时，必须先停止所有使用该 state directory 的 launcher，并离线删除整个 nonce generation；不得加入在线 pathname cleanup。随机 64-hex nonce 将 artifacts 限定为每次 generation 两个，slot 被预占则 fail closed 而非覆盖。

Compatibility behavior：receipt schema、canonical name、backend argv、successful backend exit semantics 均不变；旧版留下的 `.receipt-cleanup-*`/`.receipt-quarantine-*` 不被本 hot path 删除，只有离线整代清理；malformed/mismatched receipt 仍在 backend 前拒绝。

- [ ] **Step 4: Run Task 16 GREEN and prove cleanup/retention invariants**

GREEN aggregate 必须输出全部 exact markers：

```text
PASS[GREEN-receipt-moved-guard-swap]: replacement-inode-bytes-unchanged canonical-absent backend=executed
PASS[GREEN-receipt-quarantine-swap]: replacement-inode-bytes-unchanged canonical-absent backend=executed
PASS[GREEN-receipt-slot-exhaustion]: canonical-preserved backend-refused no-pathname-cleanup
PASS[GREEN-receipt-retain-retire]: receipt-fd-retired two-artifacts consume-once zero-unlink
CLEANUP PASS: receipt retain-retire fixtures offline-removed
```

```powershell
wsl.exe -d nixos -- bash -lc 'set -euo pipefail; SRC=/mnt/c/Users/hugefiver/source/ocsb; E=/tmp/ocsb-remediation-2026-07-21-1000; SNAP="$E/16-green-source"; F="$E/16-green-fixture"; LOG="$E/16-receipt-retire-green.log"; cleanup(){ set +e; find "$F" "$SNAP" -type d -exec chmod u+w {} + 2>/dev/null; rm -rf -- "$F" "$SNAP"; }; trap cleanup EXIT HUP INT TERM; install -d -m 0700 "$E"; rm -rf -- "$SNAP" "$F"; install -d -m 0700 "$SNAP"; tar --exclude=./.git -C "$SRC" -cf - . | tar -C "$SNAP" -xf -; test ! -e "$SNAP/.git"; cd "$SNAP"; bash tests/test_mount_anchor.sh --prepare "$F" >/dev/null; env -u XDG_RUNTIME_DIR bash tests/test_mount_anchor.sh --case receipt-retain-retire "$F" 2>&1 | tee "$LOG"; grep -Fq "PASS[GREEN-receipt-moved-guard-swap]: replacement-inode-bytes-unchanged canonical-absent backend=executed" "$LOG"; grep -Fq "PASS[GREEN-receipt-quarantine-swap]: replacement-inode-bytes-unchanged canonical-absent backend=executed" "$LOG"; grep -Fq "PASS[GREEN-receipt-slot-exhaustion]: canonical-preserved backend-refused no-pathname-cleanup" "$LOG"; grep -Fq "PASS[GREEN-receipt-retain-retire]: receipt-fd-retired two-artifacts consume-once zero-unlink" "$LOG"; grep -Fq "CLEANUP PASS: receipt retain-retire fixtures offline-removed" "$LOG"; sed -n "/static int create_receipt_guard_slot/,/static void discard_nonce_matching_workspace_receipt/p" pkgs/ocsb-mount-anchor.c | if grep -Eq "unlinkat\\(|unlink\\("; then exit 1; fi; chmod 0444 "$LOG"'
```

### Task 17: Durable Gated OCI Sidecar Lifecycle and Immutable-ID Rollback

**Covers:** persisted OCI volume source is `/proc/<wrapper-pid>/fd/N` and breaks restart/reuse；identity failure after create/start leaves a container or starts PostgreSQL/DB initialization before rollback。

**Files:**
- Create: `pkgs/ocsb-sidecar-gate.c`
- Create: `pkgs/sidecar-gate.nix`
- Modify: `scripts/ironclaw-wrapper.nix:1-22,371-903`
- Modify: `flake.nix:74-164`
- Modify: `tests/test_ironclaw.sh:18-403,519-696,857-1523,1831-1933`

**Interfaces:**
- Consumes: canonical public `$PERSIST_DIR/pgdata-sidecar`、held transaction state dirfd、pinned sidecar image config (`Entrypoint`/`Cmd`/container `Env`)、Podman/Docker `image inspect/create --cidfile/cp/start/inspect/exec/stop/rm`、Task 16 fail-closed cleanup discipline。
- Produces: wrapper function `{ pkgs, slug, persistSlug ? slug, ironclawSandboxBase, sidecarGate, sidecarTestHookMode ? "none" }`; static `${sidecarGate}/bin/ocsb-sidecar-gate`; labels `io.ocsb.protocol=sidecar-gate-v1` and `io.ocsb.generation=64hex`; held-state-FD mode-0600 `_SIDECAR_CIDFILE_REL`；immutable `_SIDECAR_CONTAINER_ID`; explicit `_SIDECAR_ORIGIN=absent|stopped|running`、`_SIDECAR_STARTED_BY_TRANSACTION`、`_SIDECAR_COMMIT_ATTEMPTED`、`_SIDECAR_GATE_RELEASED`; generation/run-nonce waiting、prepare、ready-ack、single `O_EXCL` commit-or-abort decision、matching commit/abort ack；PATH-aware original image invocation preserving exact argv/envp；OCI metadata whose PostgreSQL volume source is literally canonical public `$PERSIST_DIR/pgdata-sidecar` and never `/proc/*/fd/*`。

- [ ] **Step 1: Correct fake OCI persistence and add exact RED lifecycle cases**

In the stateful fake OCI, delete `readlink -f -- "${volume%:/var/lib/postgresql}"`; persist the exact supplied `--volume` source string. Extend it with `image inspect`, `create --cidfile`, stdin `cp`, immutable 64-lower-hex IDs, generation/protocol labels, stopped/running gate states, `stop`, and `rm -f`. Every mutating operation records `OP:ID`; name-based mutation is a test failure。The fake image config is exactly `Entrypoint=["docker-entrypoint.sh"]`, `Cmd=["postgres","-c","shared_preload_libraries=vector"]`, and includes `PATH=/usr/local/bin:/usr/bin:/bin` plus `OCSB_GATE_TEST_ENV=bare-value`; its bare executable records NUL-delimited argv and inherited env before remaining alive。The lightweight fixture exposes the static package at `$FIXTURE/ocsb-sidecar-gate` so GREEN can run `file` against the exact binary used by the wrapper。

Add aggregate `--case final-review-sidecar-gate` with deterministic durable-source、absent rollback、stopped rollback、running reuse、legacy refusal、bare entrypoint initial/restart, the existing cidfile-before-assignment barrier, and these three decision-linearization barriers：

1. Fixture-only wrapper options `--test-after-create-cidfile-ready-fd FD` and `--test-after-create-cidfile-release-fd FD` fire after fake runtime atomically wrote/fsynced the cidfile but before wrapper reads or assigns `_SIDECAR_CONTAINER_ID`。
2. Fixture-only wrapper options `--test-after-prepare-before-decision-ready-fd FD` and `--test-after-prepare-before-decision-release-fd FD` fire after `release --prepare` returned ready but before `_SIDECAR_COMMIT_ATTEMPTED=1`；signal must make cleanup win abort CAS, observe abort-ack, and perform the origin-specific rollback。
3. Test-gate-only PID1 options `--test-after-commit-decision-before-ack-ready-fd FD` and `--test-after-commit-decision-before-ack-release-fd FD` fire after commit decision file+parent fsync but before commit-ack creation；signal must observe commit decision and perform no stop/remove, then recovery must observe commit-ack after release。
4. Test-gate-only ack-client options `--test-after-commit-ack-before-return-ready-fd FD` and `--test-after-commit-ack-before-return-release-fd FD` fire after `ack --wait --decision commit` has validated the fsynced commit-ack but before that ack command returns；signal must perform no stop/remove while `_SIDECAR_GATE_RELEASED=0`。

`sidecarTestHookMode="none"` production wrappers reject all wrapper test options, and production `${sidecarGate}` rejects all PID1/ack-client test options。Every pair owns distinct FDs and case directories。`pkgs/sidecar-gate.nix` exposes `{ pkgs, testHooks ? false }`; only the lightweight fixture builds `testHooks=true` with `OCSB_SIDECAR_GATE_TEST_HOOKS`, while `flake.nix` passes the production gate and `sidecarTestHookMode="none"` to every shipped wrapper。

RED output is exact：

```text
FAIL[RED-sidecar-durable-source]: persisted OCI source contains /proc/fd
FAIL[RED-sidecar-rollback-absent]: pre-release failure left created container or DB side effects
FAIL[RED-sidecar-rollback-stopped]: pre-release failure left prior stopped container running
FAIL[RED-sidecar-cidfile-window]: interrupted create before assignment orphaned immutable container
FAIL[RED-sidecar-prepare-abort-window]: prepared generation did not win abort CAS and rollback
FAIL[RED-sidecar-commit-decision-window]: commit decision existed but cleanup stopped or removed before commit-ack
FAIL[RED-sidecar-commit-ack-window]: commit-ack existed but cleanup stopped or removed before parent flag
FAIL[RED-sidecar-bare-entrypoint]: bare image argv or inherited environment changed on initial start or stopped restart
FAIL[RED-sidecar-decision-linearization]: prepare, single decision CAS, or decision-bound ack contract missing
```

The absent identity case injects mounted-object mismatch after a validated cidfile ID；the stopped case blocks after `start ID` while gate is waiting and injects the same mismatch；the running case begins with a valid new-protocol running container；the legacy case reports `/proc/4242/fd/9` as mount source. The bare-entrypoint case checks initial start and a later stopped restart separately, requiring exact argv bytes (`argv[0]` remains `docker-entrypoint.sh`) and an exact SHA-256 over the inherited ordered envp vector plus the named safe env values。Deterministic assertions use operation logs and barriers, never elapsed re-stat timing。

- [ ] **Step 2: Run exact Task 17 RED from a no-.git snapshot**

```powershell
wsl.exe -d nixos -- bash -lc 'set -euo pipefail; SRC=/mnt/c/Users/hugefiver/source/ocsb; E=/tmp/ocsb-remediation-2026-07-21-1000; SNAP="$E/17-red-source"; F="$E/17-red-fixture"; LOG="$E/17-sidecar-gate-red.log"; cleanup(){ set +e; find "$F" "$SNAP" -type d -exec chmod u+w {} + 2>/dev/null; rm -rf -- "$F" "$SNAP"; }; trap cleanup EXIT HUP INT TERM; install -d -m 0700 "$E"; rm -rf -- "$SNAP" "$F"; install -d -m 0700 "$SNAP"; tar --exclude=./.git -C "$SRC" -cf - . | tar -C "$SNAP" -xf -; test ! -e "$SNAP/.git"; cd "$SNAP"; I=$(bash tests/test_ironclaw.sh --build-lightweight-wrapper "$F"); test -x "$I"; set +e; env -u XDG_RUNTIME_DIR bash tests/test_ironclaw.sh --case final-review-sidecar-gate "$I" 2>&1 | tee "$LOG"; rc=${PIPESTATUS[0]}; set -e; test "$rc" -ne 0; for marker in "FAIL[RED-sidecar-durable-source]: persisted OCI source contains /proc/fd" "FAIL[RED-sidecar-rollback-absent]: pre-release failure left created container or DB side effects" "FAIL[RED-sidecar-rollback-stopped]: pre-release failure left prior stopped container running" "FAIL[RED-sidecar-cidfile-window]: interrupted create before assignment orphaned immutable container" "FAIL[RED-sidecar-prepare-abort-window]: prepared generation did not win abort CAS and rollback" "FAIL[RED-sidecar-commit-decision-window]: commit decision existed but cleanup stopped or removed before commit-ack" "FAIL[RED-sidecar-commit-ack-window]: commit-ack existed but cleanup stopped or removed before parent flag" "FAIL[RED-sidecar-bare-entrypoint]: bare image argv or inherited environment changed on initial start or stopped restart" "FAIL[RED-sidecar-decision-linearization]: prepare, single decision CAS, or decision-bound ack contract missing"; do grep -Fq "$marker" "$LOG"; done; chmod 0444 "$LOG"'
```

- [ ] **Step 3: Build the static gate and encode the stopped-container protocol**

`pkgs/sidecar-gate.nix` uses `pkgs.pkgsStatic.stdenv.mkDerivation`, `-std=c17 -O2 -Wall -Wextra -Werror`, and installs one mode-0555 binary. `file $out/bin/ocsb-sidecar-gate` must report statically linked。No network or third-party source is introduced。

The gate has exactly these host/container modes：

```text
ocsb-sidecar-gate encode --config-fd FD --generation HEX64 --expected-dev DEC --expected-ino DEC --entrypoint-json JSON --cmd-json JSON --environment-json JSON
ocsb-sidecar-gate archive --config-fd FD
/ocsb-sidecar-gate/ocsb-sidecar-gate run --config /ocsb-sidecar-gate/config --generation HEX64
/ocsb-sidecar-gate/ocsb-sidecar-gate verify --config /ocsb-sidecar-gate/config --mount /var/lib/postgresql --generation HEX64
/ocsb-sidecar-gate/ocsb-sidecar-gate release --prepare --config /ocsb-sidecar-gate/config --generation HEX64
/ocsb-sidecar-gate/ocsb-sidecar-gate decision --query --config /ocsb-sidecar-gate/config --generation HEX64
/ocsb-sidecar-gate/ocsb-sidecar-gate decision --commit --config /ocsb-sidecar-gate/config --generation HEX64
/ocsb-sidecar-gate/ocsb-sidecar-gate decision --abort --config /ocsb-sidecar-gate/config --generation HEX64
/ocsb-sidecar-gate/ocsb-sidecar-gate ack --wait --decision commit --config /ocsb-sidecar-gate/config --generation HEX64
/ocsb-sidecar-gate/ocsb-sidecar-gate ack --wait --decision abort --config /ocsb-sidecar-gate/config --generation HEX64
ocsb-sidecar-gate decision --query --generation HEX64 --state-archive-fd FD
ocsb-sidecar-gate ack --query --decision commit --generation HEX64 --state-archive-fd FD
ocsb-sidecar-gate ack --query --decision abort --generation HEX64 --state-archive-fd FD
```

`encode` strictly parses JSON `null` or arrays of strings from image `.Config.Entrypoint`/`.Config.Cmd` and the exact post-create container `.Config.Env`; final argv is `Entrypoint ++ Cmd` when Entrypoint nonempty, otherwise Cmd，and empty argv is refused. It preserves every byte and order of argv/envp, rejects NUL, duplicate `PATH`, and malformed/non-string elements, and stores a SHA-256 of the ordered NUL-delimited envp without printing secret values。Config is binary：8-byte magic `OCSBSCG1`, 32 decoded generation bytes, big-endian uint64 dev/ino, argv vector, environment vector and their digests, each vector represented by big-endian uint32 count followed by big-endian uint32 length + non-NUL bytes。`archive` writes a POSIX ustar stream to stdout containing only `ocsb-sidecar-gate/ocsb-sidecar-gate` mode 0555（从 `/proc/self/exe` 在 helper 内部读取）和 `ocsb-sidecar-gate/config` mode 0600；OCI argv sees `cp - ID:/`, never a `/proc` source。

On every PID1 start, `run` validates config/generation and exact inherited envp digest, creates a fresh 64-lower-hex run nonce, writes/fsyncs immutable mode-0600 `waiting.<generation>.<run-nonce>`, then atomically publishes/fsyncs canonical mode-0600 `current.<generation>` containing that run nonce and config digest。Every host gate command first reads `current.<generation>` and then validates the matching immutable waiting record；multiple or mismatched current records fail closed。A stopped restart publishes a new current run nonce, so records from an older start cannot authorize it。PID1 first waits for matching `prepare`；after validating it, PID1 atomically writes/fsyncs `ready-ack.<generation>.<run-nonce>` and remains unable to execute image argv。It then reads exactly one `decision.<generation>.<run-nonce>` record：`commit` causes commit-ack and entrypoint execution；`abort` causes abort-ack and permanent no-exec for that run。

`release --prepare` reads verified current/waiting records, creates mode-0600 `prepare.<generation>.<run-nonce>` with `O_EXCL`, writes/fsyncs it and the parent, waits for matching ready-ack, and returns `PREPARED HEX64 RUNNONCE64`；`EEXIST` is accepted only after exact identity/content validation。It never creates a decision and cannot release the entrypoint。`decision --commit` and `decision --abort` both call the same `create_decision_cas()`：open `decision.<generation>.<run-nonce>` with `O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW`, mode 0600；write the exact generation/run nonce/config digest/decision；fsync file and parent。On `EEXIST`, reopen with `O_NOFOLLOW`, validate owner/mode/type/generation/run nonce/digest, and return the existing winner rather than overwrite it。Exact stdout is `DECISION commit HEX64 RUNNONCE64` or `DECISION abort HEX64 RUNNONCE64`; malformed state fails closed。Thus exactly one decision wins。

After PID1 reads a commit winner, it atomically writes/fsyncs mode-0600 `commit-ack.<generation>.<run-nonce>` and fsyncs the parent **immediately before** PATH-aware execution；the ack binds generation、run nonce、decision-record digest、argv digest、ordered envp digest and PATH/slash resolution mode。After an abort winner, it atomically writes/fsyncs `abort-ack.<generation>.<run-nonce>` with generation、run nonce and decision digest, fsyncs the parent, and exits without executing original argv。`ack --wait --decision commit` and `ack --wait --decision abort` each validate only the ack matching the immutable decision；the commit form returns only after commit-ack exists, and the abort form returns only after abort-ack exists。An ack without its matching immutable decision is invalid。

Entrypoint execution is exact and PATH-aware：if original `argv[0]` contains `/`, call `execve(argv[0], argv, envp)`；otherwise locate the single inherited `PATH`, split left-to-right on `:` with an empty component meaning `.`, and call `execve(candidate, original_argv, envp)` for each candidate while preserving bare `argv[0]`。Continue only for `ENOENT`/`ENOTDIR`, remember `EACCES`, and fail with `EACCES` if any candidate denied or `ENOENT` otherwise；missing `PATH` is rejected before commit。Do not call a shell, rewrite argv, sort/rebuild envp, or substitute a host PATH。

`verify` performs `openat2`/`fstat` on `/var/lib/postgresql`, compares config dev/ino to the wrapper-held original directory identity and requires PID1's verified waiting state；success prints only `MOUNT-VERIFIED HEX64 RUNNONCE64`。`decision --query` returns exactly `DECISION absent HEX64 RUNNONCE64`、`DECISION commit HEX64 RUNNONCE64` or `DECISION abort HEX64 RUNNONCE64` after validating current waiting/prepare/decision records；absence of commit-ack is never a decision。For a stopped container, read-only `OCI cp "ID:/ocsb-sidecar-gate" -` yields a ustar stream of the private state directory to the host `--state-archive-fd` forms, which reject extra links/special files and validate only exact generation/run-nonce records without starting the container。No mode prints argv/env/secret bytes。

- [ ] **Step 4: Linearize create/copy/start/verify/commit by cidfile and immutable ID**

Define `sidecar_oci()` so Podman always executes `podman --remote=false "$@"`; reject `CONTAINER_HOST`/`CONTAINER_CONNECTION` and remote options。Docker executes `docker "$@"` unchanged. Capture original image config with the runtime's actual `image inspect --format '{{json .Config.Entrypoint}}'` and `{{json .Config.Cmd}}`; after create, capture exact container `inspect --format '{{json .Config.Env}}'` for gate `encode`。Do not add fallback syntax: Task 19 native jobs are the authority that both adapters support each exact command、cidfile mode、stdin `cp`、outbound gate-state `cp` and stopped/running behavior。

Before `create`, make a unique mode-0700 transaction directory with `mkdirat(_SIDECAR_STATE_FD, ".sidecar-txn.$_SIDECAR_GENERATION.$_SIDECAR_TXN_NONCE")` and set `_SIDECAR_CIDFILE_REL` to its absent child `cid`。Run both Podman and Docker create under saved/restored `umask 077` with `--cidfile "/proc/self/fd/$_SIDECAR_STATE_FD/$_SIDECAR_CIDFILE_REL"`；this `/proc` path is a wrapper-local OCI-client output path only and is neither a volume source nor persisted OCI metadata。Runtime stdout is diagnostic only and never the ID authority。

For an absent container：

```text
_SIDECAR_GENERATION = 32 bytes kernel randomness -> 64 lower hex
_SIDECAR_TXN_NONCE = independent 32 bytes kernel randomness -> 64 lower hex
create --name "$DB_SIDECAR_CONTAINER"
       --cidfile "/proc/self/fd/$_SIDECAR_STATE_FD/$_SIDECAR_CIDFILE_REL"
       --label "io.ocsb.owner=ocsb-ironclaw"
       --label "io.ocsb.persist-id=$_SIDECAR_PERSIST_ID"
       --label "io.ocsb.image=$DB_SIDECAR_IMAGE"
       --label "io.ocsb.volume=$PERSIST_DIR/pgdata-sidecar"
       --label "io.ocsb.port=$DB_SIDECAR_PORT"
       --label "io.ocsb.protocol=sidecar-gate-v1"
       --label "io.ocsb.generation=$_SIDECAR_GENERATION"
       --env-file FILE
       --volume "$PERSIST_DIR/pgdata-sidecar:/var/lib/postgresql"
       --publish "127.0.0.1:PORT:5432"
       --entrypoint /ocsb-sidecar-gate/ocsb-sidecar-gate IMAGE
       run --config /ocsb-sidecar-gate/config --generation "$_SIDECAR_GENERATION"
TEST BARRIER: after-create-cidfile-before-assignment
openat(_SIDECAR_STATE_FD, _SIDECAR_CIDFILE_REL, O_RDONLY|O_NOFOLLOW)
require current uid, regular, nlink=1, mode0600, exactly one 64-lower-hex line
assign that line to _SIDECAR_CONTAINER_ID
inspect --format '{{.Id}}' "$_SIDECAR_CONTAINER_ID" == "$_SIDECAR_CONTAINER_ID"
inspect exact io.ocsb.generation label == "$_SIDECAR_GENERATION"
inspect container .Config.Env and gate encode config/argv/env through held config FD
ocsb-sidecar-gate archive --config-fd "$_SIDECAR_GATE_CONFIG_FD" | OCI cp - "$_SIDECAR_CONTAINER_ID:/"
start "$_SIDECAR_CONTAINER_ID"
_SIDECAR_STARTED_BY_TRANSACTION=1
exec "$_SIDECAR_CONTAINER_ID" /ocsb-sidecar-gate/ocsb-sidecar-gate verify --config /ocsb-sidecar-gate/config --mount /var/lib/postgresql --generation "$_SIDECAR_GENERATION"
exec "$_SIDECAR_CONTAINER_ID" /ocsb-sidecar-gate/ocsb-sidecar-gate release --prepare --config /ocsb-sidecar-gate/config --generation "$_SIDECAR_GENERATION"
TEST BARRIER: after-prepare-before-any-decision
_SIDECAR_COMMIT_ATTEMPTED=1  # set before spawning/invoking decision child
WINNER=$(exec "$_SIDECAR_CONTAINER_ID" /ocsb-sidecar-gate/ocsb-sidecar-gate decision --commit --config /ocsb-sidecar-gate/config --generation "$_SIDECAR_GENERATION")
require WINNER == "DECISION commit $_SIDECAR_GENERATION $_SIDECAR_RUN_NONCE"; if abort won, wait abort-ack and fail without DB initialization
exec "$_SIDECAR_CONTAINER_ID" /ocsb-sidecar-gate/ocsb-sidecar-gate ack --wait --decision commit --config /ocsb-sidecar-gate/config --generation "$_SIDECAR_GENERATION"
_SIDECAR_GATE_RELEASED=1  # immediately after commit-ack wait returns; no intervening inspect/status/readiness
```

The cidfile remains open/recoverable through held state FD until transaction classification completes。`recover_created_id()` is callable from signal/EXIT cleanup even when normal assignment never occurred；it accepts only the exact mode/owner/type/content above and then requires `inspect .Id` equality plus exact `io.ocsb.generation=$_SIDECAR_GENERATION` before **any** `stop`/`rm`。Invalid cidfile、missing container、ID mismatch、generation mismatch or inconclusive inspect is fail-closed and performs no OCI mutation；the private cidfile is retained for diagnostic recovery。A validated completed transaction unlinks the cidfile and removes its unique transaction directory through the held dirfd。

After existence discovery, immediately inspect and store `.Id`; all later inspect/start/exec/stop/rm operations use that immutable ID, never the public name。Existing `io.ocsb.protocol=sidecar-gate-v1` containers validate ID、generation、image、all labels、literal public mount source/destination、loopback port and mounted dev/ino, then are adopted by current generation/run state：

- verified waiting with no prepare/decision → run `release --prepare`, then decide；
- prepare + ready-ack with no decision → reuse the prepared run and decide；
- abort decision → require abort-ack and never treat that run as started DB；a later stopped restart creates a new run nonce；
- commit decision without commit-ack → classify post-commit immediately, never stop/remove, and wait/recover commit-ack without issuing abort；
- commit decision + commit-ack → reuse the same running immutable ID without start/prepare/decision；
- any mismatched run nonce、ack without decision、malformed/conflicting record or unavailable state → fail closed with no OCI mutation。

Existing valid stopped containers start gated by ID with a fresh run nonce and follow verify→prepare→decision。Any container missing protocol/generation labels is legacy and refused without mutation；a legacy mount source beginning `/proc/` gets diagnostic `ocsb-ironclaw: legacy sidecar source refused without mutation:` and is never started, stopped, removed, exec'd or renamed。

Signal/EXIT cleanup first recovers/validates immutable ID and exact generation label。A created-but-never-started container is provably pre-gate and follows the cidfile rollback row。Once start was issued, cleanup must obtain verified waiting/prepare state (calling `release --prepare` if waiting is valid but not prepared), then query the immutable decision record by ID；it must never infer from missing commit-ack。If decision is `commit`, classify post-commit and never stop/remove even before commit-ack。If decision is `abort`, wait for exact abort-ack before rollback。If decision is `absent`, invoke `decision --abort` CAS：abort winner requires abort-ack before rollback；commit winner is post-commit and forbids rollback。Unavailable/malformed state is ambiguous and fail-closes with no OCI mutation。

`_SIDECAR_COMMIT_ATTEMPTED=1` is set in the parent immediately before invoking the commit-decision child。Every signal/EXIT branch checks it, but even when false cleanup still queries/CASes the decision；when true, no branch may use a cached/missing prepare、decision or ack as negative evidence。Running gates use `sidecar_oci exec "$_SIDECAR_CONTAINER_ID" /ocsb-sidecar-gate/ocsb-sidecar-gate decision --query --config /ocsb-sidecar-gate/config --generation "$_SIDECAR_GENERATION"`；stopped state uses read-only `sidecar_oci cp "$_SIDECAR_CONTAINER_ID:/ocsb-sidecar-gate" - | ${sidecarGate}/bin/ocsb-sidecar-gate decision --query --generation "$_SIDECAR_GENERATION" --state-archive-fd 0` and the corresponding exact commit/abort ack query mode。

| Linearization window / origin | Required decision/ack classification | Cleanup action by validated immutable ID | Password/env handling | DB entrypoint side effects |
|---|---|---|---|---|
| `create` wrote cidfile, normal assignment not reached, start never issued | validated 64hex ID + exact generation label + inspected stopped state | `rm -f ID`; assert ID absent | remove password only if this transaction created it; remove config/env temps | impossible；PID1 never started |
| started/verified waiting, before prepare | establish prepare+ready, query absent, abort CAS wins, observe abort-ack | origin `absent`: `rm -f ID`; origin `stopped`: leave/confirm stopped | preserve existing password for stopped origin | impossible；abort forbids exec |
| after prepare+ready, before host commit attempt | query absent, abort CAS wins, observe abort-ack | same origin-specific rollback | same as above | impossible |
| parent set `commit_attempted=1`, commit and abort race | query/CAS returns exact winner | commit winner: no stop/remove；abort winner: wait abort-ack then origin rollback | preserve durable data for commit；abort follows origin | only commit winner may execute |
| commit decision fsynced, commit-ack not yet written | decision=commit；ack absence is irrelevant | classify post-commit；no stop/remove；recovery waits for commit-ack | preserve durable password/config | entrypoint not yet executed but rollback forbidden |
| commit-ack fsynced, ack client/parent flag not returned/set | decision=commit + commit-ack | classify post-commit；no stop/remove/restart | preserve durable password/config | allowed；commit point completed |
| `_SIDECAR_GATE_RELEASED=1` after ack wait | decision=commit + commit-ack already observed | no security rollback；report later operational errors | publish DB env only after readiness | allowed |
| decision/state query unavailable or malformed, ID/label validation fails | ambiguous/fail-closed | no OCI mutation；retain private recovery receipt | do not delete durable secrets | unknown；never risk rollback of commit winner |
| any legacy, including `/proc/4242/fd/9` | inspect-only legacy | no mutation | preserve existing files | no new side effect |

The prepare barrier must produce abort winner + abort-ack + rollback。The post-commit-decision/pre-ack barrier must preserve the container because decision=commit even though commit-ack is absent, then recovery must observe commit-ack。The post-commit-ack/pre-parent-flag barrier must likewise preserve it while `_SIDECAR_GATE_RELEASED=0`。`_SIDECAR_GATE_RELEASED=1` is set immediately after commit `ack --wait` returns zero, never after a later status/identity/readiness confirmation。The stored OCI volume and `io.ocsb.volume` label always use `_SIDECAR_VOLUME="$PERSIST_DIR/pgdata-sidecar"`; `_SIDECAR_DATA_FD_PATH` is allowed only for wrapper-local reads/stat and must never be interpolated into OCI argv or labels。

- [ ] **Step 5: Run Task 17 GREEN and assert rollback/compatibility**

Exact GREEN output：

```text
PASS[GREEN-sidecar-durable-source]: stored-public-source no-proc-metadata restart-config-stable
PASS[GREEN-sidecar-rollback-absent]: removed-by-id before-release no-db-side-effects
PASS[GREEN-sidecar-rollback-stopped]: stopped-by-id before-release no-db-side-effects
PASS[GREEN-sidecar-running-reuse]: verified-by-id reused no-create-start-stop-remove
PASS[GREEN-sidecar-legacy-proc-refusal]: no-mutation source-refused
PASS[GREEN-sidecar-cidfile-recovery]: create-interrupt recovered-validated-id removed-by-id before-assignment
PASS[GREEN-sidecar-prepare-abort-window]: prepared-no-decision abort-cas-won abort-ack rollback-by-origin
PASS[GREEN-sidecar-commit-decision-window]: commit-cas-won pre-ack no-stop-remove recovery-observed-commit-ack
PASS[GREEN-sidecar-commit-ack-window]: ack-before-parent-flag no-stop-remove parent-flag-was-zero
PASS[GREEN-sidecar-bare-entrypoint]: initial-and-stopped-restart argv=exact env=exact path-search
PASS[GREEN-sidecar-gate-protocol]: stopped-create cidfile copy verify prepare decision-cas ack path-aware-entrypoint-after-commit
PASS[GREEN-sidecar-decision-linearization]: prepare-ready single-winner abort-ack-or-commit-ack no-ack-negative
CLEANUP PASS: gated sidecar fake OCI containers processes fifos cidfiles outlinks mounts temps removed
```

```powershell
wsl.exe -d nixos -- bash -lc 'set -euo pipefail; SRC=/mnt/c/Users/hugefiver/source/ocsb; E=/tmp/ocsb-remediation-2026-07-21-1000; SNAP="$E/17-green-source"; F="$E/17-green-fixture"; LOG="$E/17-sidecar-gate-green.log"; cleanup(){ set +e; find "$F" "$SNAP" -type d -exec chmod u+w {} + 2>/dev/null; rm -rf -- "$F" "$SNAP"; }; trap cleanup EXIT HUP INT TERM; install -d -m 0700 "$E"; rm -rf -- "$SNAP" "$F"; install -d -m 0700 "$SNAP"; tar --exclude=./.git -C "$SRC" -cf - . | tar -C "$SNAP" -xf -; test ! -e "$SNAP/.git"; cd "$SNAP"; I=$(bash tests/test_ironclaw.sh --build-lightweight-wrapper "$F"); test -x "$I"; test -x "$F/ocsb-sidecar-gate"; file "$F/ocsb-sidecar-gate" | grep -Fq "statically linked"; env -u XDG_RUNTIME_DIR bash tests/test_ironclaw.sh --case final-review-sidecar-gate "$I" 2>&1 | tee "$LOG"; for marker in "PASS[GREEN-sidecar-durable-source]: stored-public-source no-proc-metadata restart-config-stable" "PASS[GREEN-sidecar-rollback-absent]: removed-by-id before-release no-db-side-effects" "PASS[GREEN-sidecar-rollback-stopped]: stopped-by-id before-release no-db-side-effects" "PASS[GREEN-sidecar-running-reuse]: verified-by-id reused no-create-start-stop-remove" "PASS[GREEN-sidecar-legacy-proc-refusal]: no-mutation source-refused" "PASS[GREEN-sidecar-cidfile-recovery]: create-interrupt recovered-validated-id removed-by-id before-assignment" "PASS[GREEN-sidecar-prepare-abort-window]: prepared-no-decision abort-cas-won abort-ack rollback-by-origin" "PASS[GREEN-sidecar-commit-decision-window]: commit-cas-won pre-ack no-stop-remove recovery-observed-commit-ack" "PASS[GREEN-sidecar-commit-ack-window]: ack-before-parent-flag no-stop-remove parent-flag-was-zero" "PASS[GREEN-sidecar-bare-entrypoint]: initial-and-stopped-restart argv=exact env=exact path-search" "PASS[GREEN-sidecar-gate-protocol]: stopped-create cidfile copy verify prepare decision-cas ack path-aware-entrypoint-after-commit" "PASS[GREEN-sidecar-decision-linearization]: prepare-ready single-winner abort-ack-or-commit-ack no-ack-negative" "CLEANUP PASS: gated sidecar fake OCI containers processes fifos cidfiles outlinks mounts temps removed"; do grep -Fq "$marker" "$LOG"; done; ! grep -Eq "persisted-(volume|label)=/proc/(self|[0-9]+)/fd/" "$LOG"; chmod 0444 "$LOG"'
```

该 Nix build 只编译 repository-owned static gate；不得构建 Hermes、Ironclaw、retained 或 arch external payload。

### Task 18: Inherited-FD Identity Handoff Through mkSandbox and Mount Anchor

**Covers:** wrapper 在关闭 anchored transaction FDs 后向 `mkSandbox` 重新传入 public home/data/state/DB-env paths，攻击者可在最后 handoff 窗口换入 replacement；cwd、state workspace 和 mount sources 随之重开错误 inode。

**Files:**
- Modify: `scripts/ironclaw-wrapper.nix:322-360,371-496,574-641,870-934`
- Modify: `lib/mkSandbox.nix:10-57,500-707,1270-1730,1732-1993,2068-2238`
- Modify: `pkgs/ocsb-mount-anchor.c:72-238,882-1180,2622-2872,3600-4027,4345-4542`
- Modify: `tests/test_ironclaw.sh:18-403,519-696,1049-1201,1294-1548`
- Modify: `tests/test_mount_anchor.sh:17-39,189-365,1018-1135,1740-1842`

**Interfaces:**
- Consumes: four independent wrapper handoff descriptors for original `home/` directory、`data/` directory、`state/` directory、exact `state/ironclaw-db.env` regular file；Task 3 private anchors；Task 16 held-FD receipt semantics。
- Produces: hidden repeated launcher option `--ocsb-internal-fd-root SPEC` where `SPEC` is exactly `v1<TAB>project|state-base|mount<TAB>absolute-display-path<TAB>fd<TAB>dev<TAB>ino<TAB>directory|regular`；mount-anchor option `--inherited-fd-spec SPEC` with the same schema；both `WORKSPACE_MUTATION_ARGS` and final `MOUNT_ANCHOR_ARGS` contain **all four** specs；display paths remain public for hashes、diagnostics、labels、`OCSB_STATE_DIR`，while mutation project-tree/public-identity/receipt/state access and final sources/anchors all derive from held FDs。No public help text documents this wrapper-internal ABI。

- [ ] **Step 1: Add independent mutation-helper and final-helper replacement RED barriers**

Extend the test-hook helper ABI with two disjoint ready/release pairs：`--test-before-inherited-mutation-open-{ready,release}-fd` and `--test-before-inherited-final-open-{ready,release}-fd`。Production helper rejects all four as unknown；only the `OCSB_MOUNT_ANCHOR_TEST_HOOKS` fixture accepts them。The first barrier fires in mutation-only mode after parsing/fstatting inherited specs but **before** opening project tree、public-path identity targets、state receipt parent or workspace state；the coordinator fingerprints and renames original public home/project、state、data and DB-env objects to saved names, then installs replacement-set-1。The second barrier fires in final-anchor mode before any source/derived-root open；the coordinator renames replacement-set-1 aside and installs replacement-set-2。Both replacement sets remain byte/inode-identical after helper/backend exit。

The mutation helper records that project workspace tree、public-path identity object、receipt parent and workspace state were all opened beneath original inherited project/state FDs。The generated fake backend forks, closes every FD except stdio, rejects any argv element matching `/proc/(self|[0-9]+)/fd/`, and reports original markers through cwd/workspace、data mount、state workspace and DB env mount from final private anchors。No barrier uses elapsed re-stat timing or shares FIFO FDs。

Current code must produce nonzero aggregate with：

```text
FAIL[RED-ironclaw-fd-handoff]: home,data,state,db-env reopened from replacement public paths
FAIL[RED-inherited-mutation-helper]: mutation helper reopened public project or state roots
FAIL[RED-inherited-final-helper]: final helper reopened public home,data,state,db-env roots
FAIL[RED-inherited-spec-forwarding]: mutation or final helper omitted the all-four inherited spec set
```

- [ ] **Step 2: Run exact Task 18 RED from a no-.git snapshot**

```powershell
wsl.exe -d nixos -- bash -lc 'set -euo pipefail; SRC=/mnt/c/Users/hugefiver/source/ocsb; E=/tmp/ocsb-remediation-2026-07-21-1000; SNAP="$E/18-red-source"; F="$E/18-red-fixture"; LOG="$E/18-inherited-fd-red.log"; cleanup(){ set +e; find "$F" "$SNAP" -type d -exec chmod u+w {} + 2>/dev/null; rm -rf -- "$F" "$SNAP"; }; trap cleanup EXIT HUP INT TERM; install -d -m 0700 "$E"; rm -rf -- "$SNAP" "$F"; install -d -m 0700 "$SNAP"; tar --exclude=./.git -C "$SRC" -cf - . | tar -C "$SNAP" -xf -; test ! -e "$SNAP/.git"; cd "$SNAP"; I=$(bash tests/test_ironclaw.sh --build-lightweight-wrapper "$F"); test -x "$I"; set +e; env -u XDG_RUNTIME_DIR bash tests/test_ironclaw.sh --case final-review-fd-handoff "$I" 2>&1 | tee "$LOG"; rc=${PIPESTATUS[0]}; set -e; test "$rc" -ne 0; for marker in "FAIL[RED-ironclaw-fd-handoff]: home,data,state,db-env reopened from replacement public paths" "FAIL[RED-inherited-mutation-helper]: mutation helper reopened public project or state roots" "FAIL[RED-inherited-final-helper]: final helper reopened public home,data,state,db-env roots" "FAIL[RED-inherited-spec-forwarding]: mutation or final helper omitted the all-four inherited spec set"; do grep -Fq "$marker" "$LOG"; done; chmod 0444 "$LOG"'
```

- [ ] **Step 3: Separate transaction descriptors from final handoff descriptors**

Do not repurpose `_SIDECAR_{PARENT,PERSIST,STATE,DATA}_FD`。After sidecar transaction and DB readiness succeed, open new `_HANDOFF_HOME_FD`、`_HANDOFF_DATA_FD`、`_HANDOFF_STATE_FD` and, after atomic DB-env publication through `$_HANDOFF_STATE_FD`, `_HANDOFF_DB_ENV_FD`。Capture each `fstat` dev/ino/type and require exact identity against the transaction-held inode where a transaction counterpart exists。`write_db_env_file` receives state dirfd access plus relative name `ironclaw-db.env`; after rename/fsync it opens that exact file with `O_NOFOLLOW`, mode 0600, and records its FD identity。

Before inner exec：close sidecar transaction/lock/config/password/runtime FDs；keep only the four handoff FDs and pass these concrete specs before public args：

```bash
FILTERED_ARGS=(
  --ocsb-internal-fd-root "$PROJECT_FD_SPEC"
  --ocsb-internal-fd-root "$STATE_FD_SPEC"
  --ocsb-internal-fd-root "$DATA_FD_SPEC"
  --ocsb-internal-fd-root "$DB_ENV_FD_SPEC"
  "${FILTERED_ARGS[@]}"
)
cd "/proc/self/fd/$_HANDOFF_HOME_FD"   # wrapper-local only; cwd becomes held inode
exec ${ironclawSandboxBase}/bin/ironclaw "${IRONCLAW_MOUNT_ARGS[@]}" "${FILTERED_ARGS[@]}"
```

The display strings inside specs are respectively `$PERSIST_DIR/home`、`$PERSIST_DIR/state`、`$PERSIST_DIR/data`、`$PERSIST_DIR/state/ironclaw-db.env`。`IRONCLAW_MOUNT_ARGS` and `OCSB_STATE_BASE_DIR` retain these public display paths；no `/proc` path is placed in a mount argument、state identity、process digest or OCI metadata。

- [ ] **Step 4: Make mkSandbox use display/access separation and forward roots**

Parser requirements：fd decimal and `>=3`；absolute display path without TAB/LF；project and state-base occur at most once；duplicate display roots or conflicting types fail；`fcntl(F_GETFD)` and `fstat` must match dev/ino/type before any state mutation。Public callers without internal specs follow existing behavior unchanged。

Use these generated variables：

```text
PROJECT_DIR                 = public display path used in instance hash/receipt fields
PROJECT_ACCESS_DIR          = /proc/self/fd/PROJECT_FD only inside launcher/helper setup
STATE_BASE_DIR              = public display path used in OCSB_STATE_DIR semantics
STATE_BASE_ACCESS_DIR       = /proc/self/fd/STATE_FD only inside launcher state operations
OVERLAY_STATE_DIR           = $STATE_BASE_DIR/$WORKSPACE_NAME (display)
OVERLAY_STATE_ACCESS_DIR    = $STATE_BASE_ACCESS_DIR/$WORKSPACE_NAME (all mkdir/lock/markers/temp access)
```

All state creation、`.lock`、`.strategy`、`.backend`、receipt publication/read and chroot/overlay derived host access use `OVERLAY_STATE_ACCESS_DIR`；diagnostics and schema fields use `OVERLAY_STATE_DIR`。Parse the launcher options once into `INHERITED_FD_ARGS`, with one `--inherited-fd-spec SPEC` pair for each of project、state、data and DB-env。Construct both call sites explicitly：

```bash
WORKSPACE_MUTATION_ARGS=(
  --mode workspace-mutation
  "${INHERITED_FD_ARGS[@]}"
  "${WORKSPACE_MUTATION_SOURCE_ARGS[@]}"
)
MOUNT_ANCHOR_ARGS=(
  --mode final-anchor
  "${INHERITED_FD_ARGS[@]}"
  "${FINAL_SOURCE_ARGS[@]}"
)
```

No branch may omit data/DB-env specs from mutation mode even when that mode does not consume those roots；the complete repeated interface is validated identically by both calls。Mutation-mode project tree、public-path identity validation、state receipt parent and workspace state all resolve from project/state inherited descriptors；they never `stat`/`open` `PROJECT_DIR`、`STATE_BASE_DIR` or `OVERLAY_STATE_DIR` public pathnames。Final `register_mount_anchor_source()` selects an exact regular root or the longest component-boundary directory display root and uses its recorded identity instead of statting the public path。

- [ ] **Step 5: Validate/open inherited roots in C and close them before backend**

Add：

```c
struct inherited_fd_spec {
  char *storage;
  enum inherited_role role; /* project, state-base, mount */
  char *display_path;
  int fd;
  dev_t expected_dev;
  ino_t expected_ino;
  enum source_type expected_type;
};
```

Immediately after CLI parse in **both** helper modes, `fstat` every inherited fd and compare exact dev/ino/type；project/state roles must be directories。For any requested display path below a directory root, strip only a whole-component prefix and open each remaining component with `openat2(RESOLVE_BENEATH|RESOLVE_NO_SYMLINKS|RESOLVE_NO_MAGICLINKS)` from a `dup` of the held root；an exact regular root has no descendants。

Mutation mode performs its test barrier, then `open_project_workspace_tree()`、public-path identity checks、`open_workspace_receipt_parent()` and workspace state access consume only inherited project/state roots；the source-spec display token is diagnostic/schema data and never an open target。It closes its child copies on every return while the launcher retains the original four FDs for final mode。Final mode performs its separate barrier, then `open_sources()` uses inherited/derived FDs for every project/data/state/DB-env source and never a public pathname。A barrier replacement therefore cannot influence either helper invocation。

After every private bind anchor has been created, close all source FDs、all inherited root FDs、receipt FD、test FDs and original cwd FD before `rewrite_and_exec_backend()`。Add a pre-exec descriptor audit in the test helper；the backend may receive only stdio and backend-required descriptors such as bwrap info-fd, never transaction/handoff/root descriptors。The rewritten backend argv must contain private runtime anchor paths and zero `/proc/*/fd/*` strings。

Compatibility behavior：public `--ro/--rw` syntax、state layout、`OCSB_STATE_DIR` value、workspace hash、Ironclaw persist paths and non-Ironclaw launchers stay unchanged；hidden specs are additive and fail closed if forged/stale/closed。Podman/nspawn still receive only Task 3 anchors, not inherited FDs。

- [ ] **Step 6: Run Task 18 GREEN and prove original inodes in both helper phases**

Exact GREEN output：

```text
PASS[GREEN-ironclaw-fd-handoff]: home=original data=original state=original db-env=original
PASS[GREEN-inherited-mutation-helper]: project-tree=original public-identity=original receipt-parent=original workspace-state=original replacement-set-1-unchanged
PASS[GREEN-inherited-final-helper]: home=original data=original state=original db-env=original replacement-set-2-unchanged
PASS[GREEN-inherited-spec-forwarding]: mutation=all-four final=all-four
PASS[GREEN-inherited-fd-backend-boundary]: all-handoff-fds-closed argv=no-proc private-anchors-only
CLEANUP PASS: inherited FD handoff processes fifos outlinks mounts fixtures removed
```

```powershell
wsl.exe -d nixos -- bash -lc 'set -euo pipefail; SRC=/mnt/c/Users/hugefiver/source/ocsb; E=/tmp/ocsb-remediation-2026-07-21-1000; SNAP="$E/18-green-source"; F="$E/18-green-fixture"; LOG="$E/18-inherited-fd-green.log"; cleanup(){ set +e; find "$F" "$SNAP" -type d -exec chmod u+w {} + 2>/dev/null; rm -rf -- "$F" "$SNAP"; }; trap cleanup EXIT HUP INT TERM; install -d -m 0700 "$E"; rm -rf -- "$SNAP" "$F"; install -d -m 0700 "$SNAP"; tar --exclude=./.git -C "$SRC" -cf - . | tar -C "$SNAP" -xf -; test ! -e "$SNAP/.git"; cd "$SNAP"; I=$(bash tests/test_ironclaw.sh --build-lightweight-wrapper "$F"); test -x "$I"; env -u XDG_RUNTIME_DIR bash tests/test_ironclaw.sh --case final-review-fd-handoff "$I" 2>&1 | tee "$LOG"; for marker in "PASS[GREEN-ironclaw-fd-handoff]: home=original data=original state=original db-env=original" "PASS[GREEN-inherited-mutation-helper]: project-tree=original public-identity=original receipt-parent=original workspace-state=original replacement-set-1-unchanged" "PASS[GREEN-inherited-final-helper]: home=original data=original state=original db-env=original replacement-set-2-unchanged" "PASS[GREEN-inherited-spec-forwarding]: mutation=all-four final=all-four" "PASS[GREEN-inherited-fd-backend-boundary]: all-handoff-fds-closed argv=no-proc private-anchors-only" "CLEANUP PASS: inherited FD handoff processes fifos outlinks mounts fixtures removed"; do grep -Fq "$marker" "$LOG"; done; chmod 0444 "$LOG"'
```

### Task 19: Separate Native OCI Lifecycle CI and Final Review Authority Manifest

**Covers:** fake-only sidecar proof cannot establish Docker/Podman restart semantics；required native jobs do not retain evidence；Task 15 manifest predates final-review defects。

**Files:**
- Create: `tests/test_ironclaw_native_oci.sh`
- Modify: `.github/workflows/ci.yml:43-60,108-132,236-271`
- Modify: `tests/test_ci_runtime.sh`
- Verify only: `$E/manifest.md`（Task 15 original 18 scenarios；must remain byte-identical）
- Runtime artifact only: `$E/final-review-remediation-manifest.md`、`$E/19-ci-authority-{red,green}.log`、`$E/19-native-{podman,docker}-sidecar-green.log`

**Interfaces:**
- Consumes: Tasks 16–18 RED/GREEN logs（including cidfile/prepare/decision-CAS/acks/PATH and dual-helper markers）；Task 14 pending rootless Podman anchor receipt；lightweight Ironclaw wrapper；native rootless Podman from locked `.#backend-test` dev shell；GitHub runner local Docker daemon；exact pinned image `docker.io/pgvector/pgvector:pg18@sha256:12a379b47ad65289572ea0756efc11b7c241a6662833e8af7038cd3b73d647e0`。
- Produces: two separate required jobs `podman-sidecar-lifecycle-test` and `docker-sidecar-lifecycle-test`；each native log begins with requested ref、runtime image ID and matching RepoDigest provenance；artifact names `final-review-podman-sidecar-${{ github.run_id }}-${{ github.run_attempt }}` and `final-review-docker-sidecar-${{ github.run_id }}-${{ github.run_attempt }}`；four-row `$E/final-review-remediation-manifest.md` that supplements but never overwrites the original 18-row manifest；receipt status remains pending until actual native logs arrive。

- [ ] **Step 1: Add native lifecycle harness and RED CI contract**

`tests/test_ironclaw_native_oci.sh` interface is exact：

```text
tests/test_ironclaw_native_oci.sh --runtime podman --wrapper ABSOLUTE_LIGHTWEIGHT_WRAPPER --log ABSOLUTE_LOG
tests/test_ironclaw_native_oci.sh --runtime docker --wrapper ABSOLUTE_LIGHTWEIGHT_WRAPPER --log ABSOLUTE_LOG
```

`--log` is append-only for this harness：it must already be a mode-0600 regular file containing the four `PINNED_IMAGE_*` provenance lines from the job；the harness validates them before any image inspect/create and appends lifecycle output without truncating the provenance header。

Each runtime gets a unique container name and private mode-0700 persist dir。The CI job, not the local harness, first explicitly pulls the exact digest and writes provenance to the final log；the harness refuses to run unless the log already contains matching `PINNED_IMAGE_REQUEST`、64-hex/sha256 `PINNED_IMAGE_ID` and `PINNED_IMAGE_REPODIGESTS` containing the exact digest。Before wrapper launch, the harness inspects that local image and requires exact bare `Entrypoint=["docker-entrypoint.sh"]` and nonempty `Cmd=["postgres"]`; it records the expected original argv vector and exact post-create ordered container Env digest without printing values。

The lifecycle sequence is exact and linear：wrapper create/prepare/commit to completion → wrapper exits → inspect immutable ID、literal public mount source、generation label、commit decision+commit-ack and original argv/env → stop that ID exactly once → invoke wrapper to restart the stopped gate with a fresh run nonce through verify→prepare→commit decision→commit-ack → inspect the **same ID** running → snapshot the runtime operation log → invoke wrapper again **without a second stop** → inspect the same ID still running and assert the operation-log suffix contains zero create/start/stop/rm and only read-only validation/reuse。This proves existing-running reuse rather than accidentally testing a second stopped restart。Initial start and the single stopped restart both exercise bare entrypoint + Cmd arguments and exact argv/environment。

Cleanup trap reads only a validated 64hex immutable ID, revalidates the exact generation label and decision state, removes by ID only for explicit end-of-test teardown after lifecycle assertions, waits/kills helper processes, unmounts nothing on host, removes persist/temp/FIFOs/cidfiles/outlinks, and emits cleanup only after `ps -a` proves name/ID absent。The harness also asserts both runtimes accept `create --cidfile` with a mode-0600 result、stdin `cp -`、outbound `cp "ID:/ocsb-sidecar-gate" -`, and that the initial and restarted commit decisions/acks carry distinct run nonces。

Podman case requires `command -v podman` under `/nix/store/`、`podman --remote=false info --format '{{.Host.Security.Rootless}}' == true` and rejects remote environment。Docker case requires `docker info` and a local unix endpoint from `docker context inspect`; TCP/SSH endpoints are rejected。Neither case may SKIP。Exact success markers are separate：

```text
PASS[GREEN-native-podman-sidecar-lifecycle]: pull-provenance create-exit-inspect-stop-once-restart-inspect-running-reuse-same-id no-second-stop prepare-decision-ack bare-entrypoint-argv-env
PASS[GREEN-native-docker-sidecar-lifecycle]: pull-provenance create-exit-inspect-stop-once-restart-inspect-running-reuse-same-id no-second-stop prepare-decision-ack bare-entrypoint-argv-env
CLEANUP PASS: native podman sidecar container processes persist cidfiles fifos outlinks mounts removed
CLEANUP PASS: native docker sidecar container processes persist cidfiles fifos outlinks mounts removed
```

Extend `tests/test_ci_runtime.sh --case final-review-contract` to require both jobs、literal `podman --remote=false pull docker.io/pgvector/pgvector:pg18@sha256:12a379b47ad65289572ea0756efc11b7c241a6662833e8af7038cd3b73d647e0` and `docker pull docker.io/pgvector/pgvector:pg18@sha256:12a379b47ad65289572ea0756efc11b7c241a6662833e8af7038cd3b73d647e0` before wrapper build/inspect/create、provenance fields、the stop-once/no-second-stop sequence、no matrix substitution、no `continue-on-error`/`|| true`/SKIP、exact cidfile/prepare/decision/ack/bare-entrypoint markers、and artifact upload with `if-no-files-found: error`。Before workflow changes it exits nonzero with：

```text
FAIL[RED-final-review-ci-authority]: separate native Podman/Docker jobs, retained artifacts, or authority contract missing
```

- [ ] **Step 2: Run exact Task 19 RED locally**

```powershell
wsl.exe -d nixos -- bash -lc 'set -euo pipefail; SRC=/mnt/c/Users/hugefiver/source/ocsb; E=/tmp/ocsb-remediation-2026-07-21-1000; SNAP="$E/19-red-source"; LOG="$E/19-ci-authority-red.log"; cleanup(){ set +e; find "$SNAP" -type d -exec chmod u+w {} + 2>/dev/null; rm -rf -- "$SNAP"; }; trap cleanup EXIT HUP INT TERM; install -d -m 0700 "$E"; rm -rf -- "$SNAP"; install -d -m 0700 "$SNAP"; tar --exclude=./.git -C "$SRC" -cf - . | tar -C "$SNAP" -xf -; test ! -e "$SNAP/.git"; cd "$SNAP"; set +e; bash tests/test_ci_runtime.sh --case final-review-contract 2>&1 | tee "$LOG"; rc=${PIPESTATUS[0]}; set -e; test "$rc" -ne 0; grep -Fq "FAIL[RED-final-review-ci-authority]: separate native Podman/Docker jobs, retained artifacts, or authority contract missing" "$LOG"; chmod 0444 "$LOG"'
```

- [ ] **Step 3: Add two required native jobs and retain artifacts**

Use pinned `actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02` with `retention-days: 14` and `if-no-files-found: error`。The required code shape is：

```yaml
podman-sidecar-lifecycle-test:
  runs-on: ubuntu-latest
  needs: build
  steps:
    - uses: actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5
    - uses: DeterminateSystems/nix-installer-action@00199f951aeb9404028a6e4b95ad42546f73296a
    - name: Native rootless Podman sidecar lifecycle
      run: |
        set -euo pipefail
        LOG="$RUNNER_TEMP/19-native-podman-sidecar-green.log"
        nix develop .#backend-test -c bash -c '
          set -euo pipefail
          umask 077
          test "$(podman --remote=false info --format "{{.Host.Security.Rootless}}")" = true
          IMAGE=docker.io/pgvector/pgvector:pg18@sha256:12a379b47ad65289572ea0756efc11b7c241a6662833e8af7038cd3b73d647e0
          podman --remote=false pull docker.io/pgvector/pgvector:pg18@sha256:12a379b47ad65289572ea0756efc11b7c241a6662833e8af7038cd3b73d647e0
          IMAGE_ID=$(podman --remote=false image inspect "$IMAGE" --format "{{.Id}}")
          REPODIGESTS=$(podman --remote=false image inspect "$IMAGE" --format "{{json .RepoDigests}}")
          test -n "$IMAGE_ID"
          printf "%s" "$REPODIGESTS" | grep -Fq "sha256:12a379b47ad65289572ea0756efc11b7c241a6662833e8af7038cd3b73d647e0"
          printf "%s\n" "PINNED_IMAGE_RUNTIME=podman" "PINNED_IMAGE_REQUEST=$IMAGE" "PINNED_IMAGE_ID=$IMAGE_ID" "PINNED_IMAGE_REPODIGESTS=$REPODIGESTS" > "$RUNNER_TEMP/19-native-podman-sidecar-green.log"
          WRAPPER=$(bash tests/test_ironclaw.sh --build-lightweight-wrapper "$RUNNER_TEMP/native-podman-wrapper")
          bash tests/test_ironclaw_native_oci.sh --runtime podman --wrapper "$WRAPPER" --log "$RUNNER_TEMP/19-native-podman-sidecar-green.log"
        '
        grep -Fq 'PASS[GREEN-native-podman-sidecar-lifecycle]: pull-provenance create-exit-inspect-stop-once-restart-inspect-running-reuse-same-id no-second-stop prepare-decision-ack bare-entrypoint-argv-env' "$LOG"
    - uses: actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02
      if: always()
      with:
        name: final-review-podman-sidecar-${{ github.run_id }}-${{ github.run_attempt }}
        path: ${{ runner.temp }}/19-native-podman-sidecar-green.log
        if-no-files-found: error
        retention-days: 14

docker-sidecar-lifecycle-test:
  runs-on: ubuntu-latest
  needs: build
  steps:
    - uses: actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5
    - uses: DeterminateSystems/nix-installer-action@00199f951aeb9404028a6e4b95ad42546f73296a
    - name: Native local Docker sidecar lifecycle
      run: |
        set -euo pipefail
        umask 077
        LOG="$RUNNER_TEMP/19-native-docker-sidecar-green.log"
        docker info >/dev/null
        ENDPOINT=$(docker context inspect --format '{{(index .Endpoints "docker").Host}}')
        case "$ENDPOINT" in unix://*) ;; *) printf 'non-local Docker endpoint: %s\n' "$ENDPOINT" >&2; exit 1 ;; esac
        IMAGE=docker.io/pgvector/pgvector:pg18@sha256:12a379b47ad65289572ea0756efc11b7c241a6662833e8af7038cd3b73d647e0
        docker pull docker.io/pgvector/pgvector:pg18@sha256:12a379b47ad65289572ea0756efc11b7c241a6662833e8af7038cd3b73d647e0
        IMAGE_ID=$(docker image inspect "$IMAGE" --format '{{.Id}}')
        REPODIGESTS=$(docker image inspect "$IMAGE" --format '{{json .RepoDigests}}')
        test -n "$IMAGE_ID"
        printf '%s' "$REPODIGESTS" | grep -Fq 'sha256:12a379b47ad65289572ea0756efc11b7c241a6662833e8af7038cd3b73d647e0'
        printf '%s\n' "PINNED_IMAGE_RUNTIME=docker" "PINNED_IMAGE_REQUEST=$IMAGE" "PINNED_IMAGE_ID=$IMAGE_ID" "PINNED_IMAGE_REPODIGESTS=$REPODIGESTS" > "$LOG"
        WRAPPER=$(bash tests/test_ironclaw.sh --build-lightweight-wrapper "$RUNNER_TEMP/native-docker-wrapper")
        bash tests/test_ironclaw_native_oci.sh --runtime docker --wrapper "$WRAPPER" --log "$LOG"
        grep -Fq 'PASS[GREEN-native-docker-sidecar-lifecycle]: pull-provenance create-exit-inspect-stop-once-restart-inspect-running-reuse-same-id no-second-stop prepare-decision-ack bare-entrypoint-argv-env' "$LOG"
    - uses: actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02
      if: always()
      with:
        name: final-review-docker-sidecar-${{ github.run_id }}-${{ github.run_attempt }}
        path: ${{ runner.temp }}/19-native-docker-sidecar-green.log
        if-no-files-found: error
        retention-days: 14
```

Add this exact final step to existing `podman-anchor-test`：

```yaml
- uses: actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02
  if: always()
  with:
    name: rootless-podman-anchor-${{ github.run_id }}-${{ github.run_attempt }}
    path: ${{ runner.temp }}/14-real-podman-green.log
    if-no-files-found: error
    retention-days: 14
```

These jobs begin with an explicit exact-digest pull and provenance receipt, then verify actual `create --cidfile` mode/content、stdin `cp -`、outbound decision/ack state `cp "ID:/ocsb-sidecar-gate" -`、stopped `start`、gate `verify`/`release --prepare`/`decision --commit`/`ack --wait --decision commit`、bare `docker-entrypoint.sh` PATH resolution with exact original argv/container env on initial and restarted runs、one-stop then running-reuse of the same ID with no second stop/mutation、Docker restart config retention and Podman rootless namespace behavior；implementation must change adapter syntax if either native job disproves it，not weaken assertions or substitute fake evidence。No local Task 17/19 command may execute either pull。

- [ ] **Step 4: Run local GREEN contract and write separate review authority manifest**

Local contract exact marker：

```text
PASS[GREEN-final-review-ci-authority]: separate native jobs artifact-retention authority-v2 contract present
```

```powershell
wsl.exe -d nixos -- bash -lc 'set -euo pipefail; SRC=/mnt/c/Users/hugefiver/source/ocsb; E=/tmp/ocsb-remediation-2026-07-21-1000; SNAP="$E/19-green-source"; LOG="$E/19-ci-authority-green.log"; A="$E/final-review-remediation-manifest.md"; cleanup(){ set +e; find "$SNAP" -type d -exec chmod u+w {} + 2>/dev/null; rm -rf -- "$SNAP"; }; trap cleanup EXIT HUP INT TERM; install -d -m 0700 "$E"; test -s "$E/manifest.md"; ORIGINAL_SHA=$(sha256sum "$E/manifest.md"); rm -rf -- "$SNAP"; install -d -m 0700 "$SNAP"; tar --exclude=./.git -C "$SRC" -cf - . | tar -C "$SNAP" -xf -; test ! -e "$SNAP/.git"; cd "$SNAP"; bash tests/test_ci_runtime.sh --case final-review-contract 2>&1 | tee "$LOG"; grep -Fq "PASS[GREEN-final-review-ci-authority]: separate native jobs artifact-retention authority-v2 contract present" "$LOG"; test -s "$E/16-receipt-retire-red.log"; test -s "$E/16-receipt-retire-green.log"; test -s "$E/17-sidecar-gate-red.log"; test -s "$E/17-sidecar-gate-green.log"; test -s "$E/18-inherited-fd-red.log"; test -s "$E/18-inherited-fd-green.log"; grep -Fq "FAIL[RED-sidecar-decision-linearization]: prepare, single decision CAS, or decision-bound ack contract missing" "$E/17-sidecar-gate-red.log"; grep -Fq "PASS[GREEN-sidecar-decision-linearization]: prepare-ready single-winner abort-ack-or-commit-ack no-ack-negative" "$E/17-sidecar-gate-green.log"; grep -Fq "FAIL[RED-inherited-spec-forwarding]: mutation or final helper omitted the all-four inherited spec set" "$E/18-inherited-fd-red.log"; grep -Fq "PASS[GREEN-inherited-spec-forwarding]: mutation=all-four final=all-four" "$E/18-inherited-fd-green.log"; printf "%s\n" "# Final Review Remediation Authority Manifest" "" "baseline=a1968a5" "supplements=$E/manifest.md" "original-manifest-sha256=${ORIGINAL_SHA%% *}" "authority-version=2" "" "| Defect | Task | RED log | exact RED marker | GREEN log | exact GREEN marker | Authority |" "|---|---:|---|---|---|---|---|" "| receipt pathname cleanup race | 16 | 16-receipt-retire-red.log | FAIL[RED-receipt-retain-retire]: consume path pathname-unlinked a post-validation replacement | 16-receipt-retire-green.log | PASS[GREEN-receipt-retain-retire]: receipt-fd-retired two-artifacts consume-once zero-unlink | local-deterministic |" "| persisted /proc sidecar source | 17 | 17-sidecar-gate-red.log | FAIL[RED-sidecar-durable-source]: persisted OCI source contains /proc/fd | 17-sidecar-gate-green.log | PASS[GREEN-sidecar-durable-source]: stored-public-source no-proc-metadata restart-config-stable | local-fake + native-pending |" "| pre-release OCI rollback | 17 | 17-sidecar-gate-red.log | FAIL[RED-sidecar-decision-linearization]: prepare, single decision CAS, or decision-bound ack contract missing | 17-sidecar-gate-green.log | PASS[GREEN-sidecar-decision-linearization]: prepare-ready single-winner abort-ack-or-commit-ack no-ack-negative | local-fake + native-pending |" "| wrapper-to-backend path reopen race | 18 | 18-inherited-fd-red.log | FAIL[RED-inherited-spec-forwarding]: mutation or final helper omitted the all-four inherited spec set | 18-inherited-fd-green.log | PASS[GREEN-inherited-spec-forwarding]: mutation=all-four final=all-four | local-deterministic |" "" "native-rootless-podman=PENDING_USER_AUTHORIZED_PUSH" "native-local-docker=PENDING_USER_AUTHORIZED_PUSH" "existing-rootless-podman-anchor=PENDING_USER_AUTHORIZED_PUSH" "final-acceptance=NATIVE_EVIDENCE_PENDING" > "$A"; test "$(awk -F"|" "NR>2 && NF==9 {n++} END {print n+0}" "$A")" -eq 4; test "$ORIGINAL_SHA" = "$(sha256sum "$E/manifest.md")"; chmod 0444 "$LOG" "$A"; test "$(stat -c %a "$LOG")" = 444; test "$(stat -c %a "$A")" = 444'
```

- [ ] **Step 5: Validate supplied native artifacts without claiming they exist now**

Only after a user-authorized push/workflow run, place the unmodified downloaded artifact logs at the exact `$E/19-native-*-sidecar-green.log` paths and run：

```powershell
wsl.exe -d nixos -- bash -lc 'set -euo pipefail; E=/tmp/ocsb-remediation-2026-07-21-1000; P="$E/19-native-podman-sidecar-green.log"; D="$E/19-native-docker-sidecar-green.log"; A14="$E/14-real-podman-green.log"; IMAGE=docker.io/pgvector/pgvector:pg18@sha256:12a379b47ad65289572ea0756efc11b7c241a6662833e8af7038cd3b73d647e0; test -s "$P"; test -s "$D"; test -s "$A14"; for L in "$P" "$D"; do grep -Fq "PINNED_IMAGE_REQUEST=$IMAGE" "$L"; grep -Eq "^PINNED_IMAGE_ID=(sha256:)?[0-9a-f]{64}$" "$L"; grep -Fq "sha256:12a379b47ad65289572ea0756efc11b7c241a6662833e8af7038cd3b73d647e0" "$L"; done; grep -Fq "PASS[GREEN-native-podman-sidecar-lifecycle]: pull-provenance create-exit-inspect-stop-once-restart-inspect-running-reuse-same-id no-second-stop prepare-decision-ack bare-entrypoint-argv-env" "$P"; grep -Fq "CLEANUP PASS: native podman sidecar container processes persist cidfiles fifos outlinks mounts removed" "$P"; grep -Fq "PASS[GREEN-native-docker-sidecar-lifecycle]: pull-provenance create-exit-inspect-stop-once-restart-inspect-running-reuse-same-id no-second-stop prepare-decision-ack bare-entrypoint-argv-env" "$D"; grep -Fq "CLEANUP PASS: native docker sidecar container processes persist cidfiles fifos outlinks mounts removed" "$D"; grep -Eq "^PASS\[GREEN-real-rootless-podman-anchor\]: uid=[0-9]+ source=original$" "$A14"; ! grep -Fq "SKIP[" "$P"; ! grep -Fq "SKIP[" "$D"; ! grep -Fq "SKIP[" "$A14"; chmod 0444 "$P" "$D" "$A14"; printf "%s\n" "FINAL REVIEW NATIVE EVIDENCE PASS: podman sidecar + docker sidecar + podman anchor"'
```

Before that command actually passes, Task 19 handoff must literally say：

```text
Final review local RED/GREEN complete; native rootless Podman, local Docker, and existing rootless Podman anchor evidence pending user-authorized push.
```

## Spec Coverage and Placeholder Self-Review

- Original authority preservation: Task 15 的 18-row `$E/manifest.md` 不被 amendment 改写；Task 19 用 SHA-256 证明 byte-identical，并另建四行 final-review manifest。
- Final-review defect coverage: receipt pathname unlink race → Task 16；durable public sidecar source 与 pre-release rollback → Task 17；wrapper/mkSandbox reopen race → Task 18；真实 restart/reuse 与 authority handoff → Task 19。
- Receipt invariants: loaded receipt FD 从 load 保持到 free；`consume_attempted` 禁止重试；canonical 通过 exchange/move 移除；consume call path 零 `unlinkat`/`unlink`；normal success 两个 mode-0600 zero-length retained artifacts；两组 post-validation replacement 均保持 inode/bytes。
- Sidecar invocation invariants: encoded argv/envp 保持 byte/order；slash argv0 使用 `execve`，bare argv0 只按 inherited container PATH 确定性搜索且保持 bare `argv[0]`；fake 与两个 native runtimes 都覆盖 `docker-entrypoint.sh` + nonempty Cmd 的 initial start/stopped restart，并由 ack digest 验证 exact argv/environment。
- Sidecar linearization invariants: OCI metadata 只存 canonical public data path；两 runtime 的 create 都使用 held-state-FD mode0600 unique cidfile；cleanup mutation 前验证 64hex ID + exact generation label。PID1 waiting → prepare/ready 仍不可执行；commit/abort 共用 mode0600 `O_EXCL` decision CAS 且返回 winner；commit winner 在 PATH exec 前 fsync commit-ack，abort winner fsync abort-ack 且永不 exec。Cleanup 对 absent decision 只能尝试 abort CAS，并仅在 abort-ack 后 rollback；commit decision 即使没有 commit-ack也禁止 rollback；`commit_attempted` 在启动 commit child 前设置。prepare-before-decision、commit-decision-before-ack、commit-ack-before-parent-flag 三个 barrier 均有独立 RED/GREEN，任何 commit-ack absence 都不作为稳定 negative。
- Handoff invariants: transaction 与 handoff FDs 分离；home/data/state/DB-env exact identities 进入 mount-anchor；`WORKSPACE_MUTATION_ARGS` 与 final `MOUNT_ANCHOR_ARGS` 都含 all-four specs；mutation project/public-identity/receipt/state 与 final anchors 各有独立 pre-open barrier，均观察 original inode；public display 与 FD access 分离；所有 inherited FDs 在 backend exec 前关闭。
- TDD/evidence integrity: Tasks 16–19 都有独有 RED/GREEN marker、固定 log path、无 `.git` snapshot、mode-0700 evidence root、mode-0444 receipts、显式 process/container/FIFO/cidfile/outlink cleanup；authority manifest 的 Task 17 row 使用 decision-CAS aggregate receipt，Task 18 row 使用 all-four-spec aggregate receipt。
- Native lifecycle/order: 每个 clean job 先显式 pull exact digest 并把 requested ref/image ID/RepoDigests 写入 artifact log；顺序固定为 create→wrapper exit→inspect→stop once→wrapper gated restart→inspect same ID running→wrapper reuse without second stop，并断言第二次调用无 create/start/stop/remove。
- Native acceptance: 当前没有 pull provenance 或 native lifecycle artifacts；CI YAML/本地 contract 不是 native evidence，最终验收保持 pending，不能输出无条件 PASS。
- Constraints: 未计划 git write、软件安装、本地 external OCI image pull/build 或本地 Hermes/Ironclaw external payload build；所有本地 Nix 命令经 WSL 执行。
- Placeholder scan: amendment 无未决实现标记、未命名函数/文件、跨任务省略说明或依赖人工确认的 acceptance step。

Formal plan-critic receipt status: waiting for receipt

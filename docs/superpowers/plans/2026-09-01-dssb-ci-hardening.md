# DSSB CI Hardening Implementation Plan

> **For agentic workers:** Use the subagent-driven-development skill to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 Programs backend-plan 在不依赖非特权 user namespace 的情况下确定性验证 Podman/systemd-nspawn 的 `/usr/bin` mount 与 PATH，同时补齐 DSSB wrapper 的 mount 参数转发和非 bubblewrap 默认 `direct` 策略。

**Architecture:** `tests/test_programs.sh` 只在 backend-plan fixture 中向 `mkSandbox` 注入测试专用 mount-anchor 适配器：workspace mutation 仍交给真实 helper，最终 backend argv 则按 `--source-spec`/`--replace` 协议恢复受控源路径并交给 fake backend，因此计划测试不再创建 user namespace。DSSB wrapper 继续使用两个 Bash argv 数组分隔 OCSB 与 DSH 参数，只新增两个单值 mount 选项以及 `backend`/`strategy` 显式性跟踪；通用 `mkSandbox`、backend 能力边界和 DSSB 模块默认值不变。文档和静态 CI 契约锁定这些边界，所有本地验证只构建 ocsb 与 fake fixtures。

**Tech Stack:** Nix flakes、Nix module system、Nixpkgs、Bash、bubblewrap、fake Podman/systemd-nspawn fixtures、GitHub Actions 静态契约、Markdown。

**Spec:** `docs/superpowers/specs/2026-09-01-dssb-ci-hardening-design.md`

**Global Constraints:**
- `tests/test_programs.sh` 的 validation 与 bubblewrap runtime fixture 继续使用真实 `ocsb-mount-anchor`；只有 backend-plan fixture 注入测试专用 `mountAnchorHelper`。
- 测试专用 helper 的 `--mutation-only` 调用必须委托真实 helper，保留 workspace 状态与 receipt 协议；最终 backend 调用只负责解析 helper 已定义的 `--source-spec`/`--replace` 格式、恢复受控源路径并执行 fake backend。
- mount-anchor 的 FD、identity、namespace 与交换攻击安全语义仍由 `tests/test_mount_anchor.sh` 负责；Programs backend-plan 只证明 Podman/systemd-nspawn 的唯一 `/usr/bin` 只读 mount 与固定 PATH 转换。
- `--overlay-mount` 与 `--snap-mount` 必须各消费一个值、保留 argv 边界，并且只在首个 DSH 参数之前作为 OCSB 参数转发。
- 默认或显式 `bubblewrap` 且用户未给 `--strategy` 时保持 DSSB 模块的 `auto`；显式 `podman`/`systemd-nspawn` 且用户未给策略时注入 `--strategy direct`；任何显式策略均不得被覆盖。
- 不修改通用 `lib/mkSandbox.nix` API，不修改 `dssb/module.nix` 的 `workspace.strategy = "auto"` 或 `network.enable = true`。
- 非 bubblewrap 的 overlayfs/`--overlay-mount`、systemd-nspawn filtered network 以及 `--snap-mount` 的 btrfs/backend 前置条件继续由 OCSB 原生逻辑 fail closed；不得伪造 backend 对等性。
- 不自动捕获 API key，不改变 `DSH_PERMISSION_MODE=danger-full-access`，不放宽 persist 目录 ownership/mode/symlink 校验。
- 本地不得构建官方 DSH、DSSB、Hermes Agent 或 Ironclaw payload；只允许 `nix flake check --no-build`、默认 ocsb build、source/static checks 和 fake fixture builds/tests。
- PowerShell 是宿主 shell；所有 Nix 操作以及会在内部调用 Nix 的 Linux fixture 命令都必须通过 `wsl -d nixos -- bash -lc '...'` 运行。
- 不安装任何软件；使用仓库与锁定 Nixpkgs 已提供的工具。
- 未获用户授权，不执行 `git add`、`git commit`、`git push`、`git tag`、rebase、reset 或其他 Git 写命令；本计划不含任何 Git 写步骤。

---

## File map（先锁定职责）

### Modify

- `tests/test_programs.sh:32-230,336-425` — 为 backend-plan 构建注入确定性 mount-anchor 适配器，设置必然失败的 `unshare` 哨兵，并保留 Podman/systemd-nspawn `/usr/bin` 与 PATH 断言。
- `dssb/wrapper.nix:6-11,13-31,82-127,129-175` — 跟踪最后一个 backend 与显式 strategy，转发 `--overlay-mount`/`--snap-mount`，按规则注入 `direct`。
- `tests/test_dssb.sh:16-18,236-290,679-844` — 扩展 wrapper NUL-argv、缺值、安全、默认策略和文档静态契约。
- `dssb/README.md:55-65` — 记录 mount flags、默认策略矩阵与 backend 能力边界。
- `README.md:193-231` — 在 DSSB 用户文档中同步 wrapper 参数与 backend 默认策略。
- `tests/test_ci_runtime.sh:5-14,138-159,262-295` — 锁定 ordinary build 中 backend-plan 的无 userns fixture 形态及其位于真实 bwrap capability probe 之前的执行顺序。

### Verify unchanged

- `lib/mkSandbox.nix` — 继续提供 `mountAnchorHelper ? null` 注入点、`--source-spec`/`--replace` 协议和 backend 原生错误，不做产品修改。
- `pkgs/mount-anchor.nix`、`pkgs/ocsb-mount-anchor.c`、`tests/test_mount_anchor.sh` — production helper 与安全测试保持不变。
- `dssb/module.nix` — `workspace.strategy = "auto"`、filtered network 和其他模块默认值保持不变。
- `.github/workflows/ci.yml` — 现有 ordinary build 已无条件运行 validation/backend-plan、source 与 lightweight wrapper fixture；不增加特权 runner，也不移动官方 payload 的专用 jobs。
- `dssb/package.nix`、`dssb/package-lock.json`、Hermes/Ironclaw package 与 wrapper 文件 — 本次不改版本、依赖、构建或运行时行为。

---

### Task 1: 将 Programs backend-plan 改为无 userns 的确定性计划测试

**Files:**
- Modify: `tests/test_programs.sh:32-230`
- Modify: `tests/test_programs.sh:336-425`
- Verify unchanged: `lib/mkSandbox.nix:10,32-35,873-945,1672-1682,1709-1734,2402-2417`
- Verify unchanged: `tests/test_mount_anchor.sh`

**Interfaces:**
- Consumes: `mkSandbox` 参数 `mountAnchorHelper ? null`；真实 `${mountAnchor}/bin/ocsb-mount-anchor` 的 `--mutation-only` 路径；最终 helper argv 的 `--source-spec <token\tpath\troot\tdev\tino\ttype\trequiredness\tdrop-start\tdrop-count>`、`--replace <payload-index>:<token>`、`-- <backend argv...>` 协议。
- Produces: 仅测试 fixture 可见的 Nix derivation `backendPlanMountAnchor`；`write_failing_unshare()` 哨兵；不调用 `unshare` 的 `run_backend_plan()`；稳定 receipt `PASS[GREEN-programs-backend-plan]: podman-and-nspawn-share-one-public-usr-bin-and-deterministic-path`。

**Recommended executor:** `complex`

- [ ] **Step 1: 先把 backend-plan 对 user namespace 的隐式依赖变成确定 RED**

  在 `write_fake_backend()` 后增加测试哨兵，并在 `backend_plan_case()` 创建 fake backend 后调用它：

  ```bash
  write_failing_unshare() {
    local path="$1"
    cat > "$path" <<'SCRIPT'
  #!/usr/bin/env bash
  set -euo pipefail
  echo 'FAIL[RED-programs-backend-plan-userns]: unshare must not be called' >&2
  exit 97
  SCRIPT
    chmod 0755 "$path"
  }

  # backend_plan_case(), immediately after write_fake_backend calls
  write_failing_unshare "$fake_bin/unshare"
  ```

  此时不要改 `run_backend_plan()` 的 nspawn 分支，也不要改 fake Podman 的 `--remote=false unshare` 行为。`run_backend_plan()` 已把 `fake_bin` 放在 PATH 最前面，所以旧实现一定命中退出 97 的哨兵。

- [ ] **Step 2: 运行 RED，证明失败来自 `unshare` 而不是 mount/PATH 断言**

  Run:

  ```powershell
  wsl -d nixos -- bash -lc 'cd /mnt/c/Users/hugefiver/source/ocsb && bash tests/test_programs.sh . --case backend-plan'
  ```

  Expected: exit 97 或由外层测试传播为 non-zero；stderr 包含 `FAIL[RED-programs-backend-plan-userns]: unshare must not be called`；不得先出现 `/usr/bin` mount 数量或 PATH regex 失败。

- [ ] **Step 3: 在 fixture Nix 中分离 production helper 与 backend-plan helper**

  将当前单个 `mkSandbox` binding 改成两个构造器；validation/runtime 保持使用默认 production helper，只有两个 backend-plan launcher 使用 Step 4 定义的完整 `backendPlanMountAnchor` binding：

  ```nix
  realMountAnchor = pkgs.callPackage (flakeDir + "/pkgs/mount-anchor.nix") { };

  mkSandbox = import (flakeDir + "/lib/mkSandbox.nix") {
    inherit pkgs lib;
  };

  mkBackendPlanSandbox = import (flakeDir + "/lib/mkSandbox.nix") {
    inherit pkgs lib;
    mountAnchorHelper = backendPlanMountAnchor;
  };
  ```

  `runtime` 和 `validation.*` 继续调用 `mkSandbox`；只把两个计划属性改为：

  ```nix
  backendPlanPodman = mkBackendPlanSandbox ((withName "programs-plan-podman") // {
    backend.type = "podman";
  });
  backendPlanNspawn = mkBackendPlanSandbox ((withName "programs-plan-nspawn") // {
    backend.type = "systemd-nspawn";
  });
  ```

- [ ] **Step 4: 实现只覆盖计划测试职责的 `backendPlanMountAnchor`**

  脚本必须完整解析已知 final-helper 参数，拒绝未知/畸形输入；`--mutation-only` 必须立即 `exec` production helper。对于 present source，用 source-spec 中的原始绝对路径替换 payload token；对于 `dev=0,ino=0,requiredness=optional` 的 absent source，按 `drop-start/drop-count` 删除对应 backend argv 项。不得执行 `mount`、`unshare` 或自行伪造 workspace receipt。

  ```nix
  backendPlanMountAnchor = pkgs.writeShellScriptBin "ocsb-mount-anchor" ''
    set -euo pipefail

    if [[ "''${1:-}" == "--mutation-only" ]]; then
      exec ${realMountAnchor}/bin/ocsb-mount-anchor "$@"
    fi

    source_specs=()
    replacements=()
    payload=()
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --source-spec)
          [[ $# -ge 2 ]] || { echo "backend-plan anchor: --source-spec requires a value" >&2; exit 2; }
          source_specs+=("$2")
          shift 2
          ;;
        --replace)
          [[ $# -ge 2 ]] || { echo "backend-plan anchor: --replace requires a value" >&2; exit 2; }
          replacements+=("$2")
          shift 2
          ;;
        --backend|--namespace|--host-uid|--host-gid|--anchor-root|--inherited-fd-spec|--workspace-receipt|--workspace-nonce|--workspace-project|--workspace-base|--workspace-name)
          [[ $# -ge 2 ]] || { echo "backend-plan anchor: $1 requires a value" >&2; exit 2; }
          shift 2
          ;;
        --)
          shift
          payload=("$@")
          break
          ;;
        *)
          echo "backend-plan anchor: unexpected option: $1" >&2
          exit 2
          ;;
      esac
    done

    [[ ''${#payload[@]} -gt 0 ]] || { echo "backend-plan anchor: backend payload is missing" >&2; exit 2; }
    [[ ''${#source_specs[@]} -eq ''${#replacements[@]} ]] || {
      echo "backend-plan anchor: source/replace count differs" >&2
      exit 2
    }

    declare -A drop_indices=()
    for ((spec_index = 0; spec_index < ''${#source_specs[@]}; spec_index++)); do
      spec="''${source_specs[$spec_index]}"
      replacement="''${replacements[$spec_index]}"
      extra=""
      IFS=$'\t' read -r token source containment device inode kind requiredness drop_start drop_count extra <<< "$spec"

      [[ -z "$extra" && "$token" =~ ^@OCSB_SOURCE_[0-9]+@$ &&
         "$source" == /* && "$containment" == /* &&
         "$device" =~ ^[0-9]+$ && "$inode" =~ ^[0-9]+$ &&
         "$kind" =~ ^(directory|regular)$ &&
         "$requiredness" =~ ^(required|optional)$ &&
         "$drop_start" =~ ^[0-9]+$ && "$drop_count" =~ ^[0-9]+$ ]] || {
        echo "backend-plan anchor: malformed source spec" >&2
        exit 2
      }

      replacement_index="''${replacement%%:*}"
      replacement_token="''${replacement#*:}"
      [[ "$replacement" == *:* && "$replacement_index" =~ ^[0-9]+$ &&
         "$replacement_token" == "$token" &&
         "$replacement_index" -lt ''${#payload[@]} &&
         "''${payload[$replacement_index]}" == *"$token"* ]] || {
        echo "backend-plan anchor: malformed replacement" >&2
        exit 2
      }

      if [[ "$device" == 0 || "$inode" == 0 ]]; then
        [[ "$device" == 0 && "$inode" == 0 && "$requiredness" == optional && "$drop_count" -gt 0 ]] || {
          echo "backend-plan anchor: required source is absent" >&2
          exit 2
        }
        [[ $((drop_start + drop_count)) -le ''${#payload[@]} ]] || {
          echo "backend-plan anchor: optional drop range is outside payload" >&2
          exit 2
        }
        for ((drop_index = drop_start; drop_index < drop_start + drop_count; drop_index++)); do
          drop_indices[$drop_index]=1
        done
      else
        payload[$replacement_index]="''${payload[$replacement_index]/$token/$source}"
      fi
    done

    final_payload=()
    for ((payload_index = 0; payload_index < ''${#payload[@]}; payload_index++)); do
      [[ -n "''${drop_indices[$payload_index]+x}" ]] && continue
      [[ "''${payload[$payload_index]}" != *@OCSB_SOURCE_*@* ]] || {
        echo "backend-plan anchor: unresolved source token" >&2
        exit 2
      }
      final_payload+=("''${payload[$payload_index]}")
    done
    exec "''${final_payload[@]}"
  '';
  ```

  该脚本刻意不复刻 production helper 的 identity/namespace 安全检查；那些检查属于未修改的 `tests/test_mount_anchor.sh`。这里的解析校验只防止 fixture 自身静默接受损坏的 launcher/helper ABI。

- [ ] **Step 5: 移除 fake backend 自身和 nspawn runner 对 `unshare` 的调用**

  fake Podman 仍识别 `--remote=false unshare`，但直接执行后面的测试 helper；最终 `--remote=false run ...` 仍写入计划文件：

  ```bash
  if [[ "${1:-}" == "--remote=false" && "${2:-}" == "unshare" ]]; then
    shift 2
    exec "$@"
  fi
  printf '%s\n' "$@" > "${OCSB_PROGRAMS_BACKEND_PLAN:?}"
  ```

  将 `run_backend_plan()` 收敛为同一个调用路径，删除 `backend == systemd-nspawn && uid != 0` 分支：

  ```bash
  output="$(
    cd "$project"
    PATH="$fake_bin:$PATH" OCSB_STATE_BASE_DIR="$state_base" OCSB_PROGRAMS_BACKEND_PLAN="$plan" \
      "$wrapper" --strategy direct --overwrite -- ignored 2>&1
  )"
  ```

  `fake_bin/unshare` 必须继续存在并保持退出 97；GREEN 因此证明整个 backend-plan 路径没有偷偷回退到宿主 `unshare`。

- [ ] **Step 6: 运行 focused GREEN，并确认原计划断言没有弱化**

  Run:

  ```powershell
  wsl -d nixos -- bash -lc 'cd /mnt/c/Users/hugefiver/source/ocsb && bash tests/test_programs.sh . --case validation && bash tests/test_programs.sh . --case backend-plan'
  ```

  Expected: exit 0；依次出现 `PASS[GREEN-programs-validation]` 与 `PASS[GREEN-programs-backend-plan]: podman-and-nspawn-share-one-public-usr-bin-and-deterministic-path`；输出不得包含 `FAIL[RED-programs-backend-plan-userns]`。现有断言仍要求 Podman 恰好一个 `:/usr/bin:ro`、nspawn 恰好一个 `--bind-ro=...:/usr/bin`，并分别匹配固定 PATH/`--setenv=PATH`。

---

### Task 2: 补齐 DSSB mount 参数路由与 backend 默认策略

**Files:**
- Modify: `tests/test_dssb.sh:679-844`
- Modify: `dssb/wrapper.nix:6-11,13-31,82-127,129-175`
- Verify unchanged: `dssb/module.nix:54-75`
- Verify unchanged: `lib/mkSandbox.nix` 的 runtime option 校验与 backend capability errors

**Interfaces:**
- Consumes: DSSB wrapper 的 `OCSB_ARGS[]`/`DSH_ARGS[]` 边界；OCSB runtime flags `--overlay-mount VALUE`、`--snap-mount VALUE`、`--backend VALUE`、`--strategy VALUE`；模块默认 `workspace.strategy = "auto"` 与 `backend.type = "bubblewrap"`。
- Produces: `HAS_EXPLICIT_STRATEGY : 0|1`、`SELECTED_BACKEND : string`（初始 `bubblewrap`，每个显式 `--backend` 更新）；首个 DSH 参数前原样转发的 mount argv；只对最后选中的显式 `podman`/`systemd-nspawn` 且无显式策略追加的 `--strategy direct`。

**Recommended executor:** `coding`

- [ ] **Step 1: 在 lightweight wrapper contract 中添加 mount argv 与策略矩阵 RED**

  扩展 `wrapper_contract_case()`，每个 case 使用独立的 mode 0700 log 与 fresh persist dir，并用现有 `assert_nul_argv()` 比较完整 argv。固定矩阵如下；每行的 `inner argv` 均以 wrapper 自动加入的 `--rw "$persist/home:/home/sandbox"` 开头：

  | Case | Wrapper input（`--persist-dir` 之后） | Expected inner argv（省略开头固定 `--rw` 两项） |
  |---|---|---|
  | mount routing | `--overlay-mount "$overlay_source:/workspace/overlay target" --snap-mount "$snap_source:/workspace/snapshot target" -- --mount-probe` | `--overlay-mount <完整单一值> --snap-mount <完整单一值> -- --mount-probe` |
  | DSH boundary | `profile --overlay-mount dsh-value` | `-- profile --overlay-mount dsh-value` |
  | implicit bubblewrap | `-- --implicit-bwrap` | `-- --implicit-bwrap`（没有 `--strategy`） |
  | explicit bubblewrap | `--backend bubblewrap -- --explicit-bwrap` | `--backend bubblewrap -- --explicit-bwrap` |
  | implicit Podman strategy | `--backend podman -- --podman-default` | `--backend podman --strategy direct -- --podman-default` |
  | implicit nspawn strategy | `--backend systemd-nspawn -- --nspawn-default` | `--backend systemd-nspawn --strategy direct -- --nspawn-default` |
  | explicit strategy preserved | `--backend podman --strategy git-worktree -- --explicit-strategy` | `--backend podman --strategy git-worktree -- --explicit-strategy`（没有额外 `direct`） |
  | last backend bubblewrap | `--backend podman --backend bubblewrap -- --last-bwrap` | 两个 backend 参数原序保留，且没有 `--strategy direct` |
  | last backend nspawn | `--backend bubblewrap --backend systemd-nspawn -- --last-nspawn` | 两个 backend 参数原序保留，然后追加 `--strategy direct` |

  mount case 使用含空格的两个值，以证明数组边界而不是字符串拼接：

  ```bash
  overlay_source="$TEST_TMP/overlay source"
  snap_source="$TEST_TMP/snapshot source"
  overlay_spec="$overlay_source:/workspace/overlay target"
  snap_spec="$snap_source:/workspace/snapshot target"
  ```

  `wrapper_safety_case()` 再增加 `--overlay-mount` 和 `--snap-mount` 缺值检查：两者必须 exit 2，输出分别包含 `dssb: --overlay-mount requires a value`、`dssb: --snap-mount requires a value`，且不得调用 fake inner。

  新增稳定 receipts：

  ```text
  PASS[GREEN-dssb-wrapper-mount-routing]: overlay snapshot and first-DSH-argument boundaries
  PASS[GREEN-dssb-wrapper-backend-strategy]: non-bwrap direct default explicit strategy and bubblewrap auto preserved
  ```

- [ ] **Step 2: 运行 wrapper RED，确认当前 parser 在首个新 OCSB flag 处错误分流**

  Run:

  ```powershell
  wsl -d nixos -- bash -lc 'cd /mnt/c/Users/hugefiver/source/ocsb && set -euo pipefail; fixture_dir="$(mktemp -d /tmp/dssb-ci-hardening-red.XXXXXX)"; cleanup() { case "$fixture_dir" in /tmp/dssb-ci-hardening-red.*) rm -rf -- "$fixture_dir" ;; *) printf "unsafe fixture path: %s\n" "$fixture_dir" >&2; return 1 ;; esac; }; trap cleanup EXIT; wrapper="$(bash tests/test_dssb.sh --build-lightweight-wrapper "$fixture_dir")"; bash tests/test_dssb.sh --case wrapper-contract "$wrapper"'
  ```

  Expected: non-zero；首个 mount routing 断言报告 `argv item 2 differs; expected <--overlay-mount> got <-->`（或同一 case 的等价 argv count mismatch）；这证明当前 wrapper 把未知 `--overlay-mount` 错当作首个 DSH 参数。不得因 official DSH build、网络下载或找不到 fixture binary 而失败。

- [ ] **Step 3: 在 wrapper parser 中跟踪显式 strategy 与最后 backend**

  在数组初始化旁增加：

  ```bash
  HAS_EXPLICIT_STRATEGY=0
  SELECTED_BACKEND="bubblewrap"
  ```

  拆分当前 `--strategy|--backend|--env|--ro|--rw)` case，保留统一缺值 exit 2，但为前两项更新状态：

  ```bash
  --strategy)
    [[ $# -ge 2 ]] || { echo "dssb: --strategy requires a value" >&2; exit 2; }
    HAS_EXPLICIT_STRATEGY=1
    OCSB_ARGS+=("$1" "$2")
    shift 2
    ;;
  --backend)
    [[ $# -ge 2 ]] || { echo "dssb: --backend requires a value" >&2; exit 2; }
    SELECTED_BACKEND="$2"
    OCSB_ARGS+=("$1" "$2")
    shift 2
    ;;
  --env|--ro|--rw|--overlay-mount|--snap-mount)
    [[ $# -ge 2 ]] || { echo "dssb: $1 requires a value" >&2; exit 2; }
    OCSB_ARGS+=("$1" "$2")
    shift 2
    ;;
  ```

  不在 wrapper 中校验 backend/strategy 枚举；未知值继续由 OCSB 的现有 parser fail closed。遇到首个未知参数或 `--` 后，剩余 argv 继续全部进入 `DSH_ARGS`，所以 DSH 自己的同名字符串不影响状态跟踪。

- [ ] **Step 4: 在 workspace action 自动选择之前追加非 bwrap 默认 strategy**

  参数解析完成、persist/state 检查之前加入：

  ```bash
  if [[ "$HAS_EXPLICIT_STRATEGY" -eq 0 ]]; then
    case "$SELECTED_BACKEND" in
      podman|systemd-nspawn)
        OCSB_ARGS+=(--strategy direct)
        ;;
    esac
  fi
  ```

  该位置使注入策略同时适用于正常模式与 `--shell`，并位于可能自动追加的 `--continue` 之前。重复 `--backend` 全部原样转发，但只由最后一个值决定是否注入；显式 `--strategy auto`、`overlayfs`、`btrfs`、`git-worktree` 或 `direct` 均设置 flag 并保持原样，后续不支持组合由 OCSB 报错。

- [ ] **Step 5: 同步 wrapper `--help`，不改变现有安全文案**

  在 mount 行中列出四类 mount：

  ```text
    --ro HOST:SANDBOX | --rw HOST:SANDBOX
    --overlay-mount HOST:SANDBOX
    --snap-mount HOST:SANDBOX
  ```

  help 不宣称这些 flag 在所有 backend 等价；能力边界由 Task 3 文档说明。不要改 `ensure_private_dir()`、`validate_workspace_name()`、secret 处理、cwd、state layout 或 shell/DSH 分隔逻辑。

- [ ] **Step 6: 构建 lightweight fixture 并运行 contract/safety GREEN**

  Run:

  ```powershell
  wsl -d nixos -- bash -lc 'cd /mnt/c/Users/hugefiver/source/ocsb && set -euo pipefail; fixture_dir="$(mktemp -d /tmp/dssb-ci-hardening-green.XXXXXX)"; cleanup() { case "$fixture_dir" in /tmp/dssb-ci-hardening-green.*) rm -rf -- "$fixture_dir" ;; *) printf "unsafe fixture path: %s\n" "$fixture_dir" >&2; return 1 ;; esac; }; trap cleanup EXIT; wrapper="$(bash tests/test_dssb.sh --build-lightweight-wrapper "$fixture_dir")"; bash tests/test_dssb.sh --case wrapper-contract "$wrapper"; DEEPSEEK_API_KEY=fixture-secret bash tests/test_dssb.sh --case wrapper-safety "$wrapper"'
  ```

  Expected: exit 0；出现两个新增 GREEN receipts 和既有 `PASS[GREEN-dssb-wrapper-cwd]`、`layout`、`argv`、`action`、`exit`、`safety` receipts；NUL argv 中 mount 的含空格值各占一个元素；secret fixture 仍找不到 `fixture-secret` 的落盘/argv 泄漏。

---

### Task 3: 同步 DSSB 文档与 CI 静态契约

**Files:**
- Modify: `tests/test_dssb.sh:236-290`
- Modify: `dssb/README.md:55-65`
- Modify: `README.md:193-231`
- Modify: `tests/test_ci_runtime.sh:5-14,138-159,262-295`
- Verify unchanged: `.github/workflows/ci.yml:41-60,129-165,560-630`

**Interfaces:**
- Consumes: Task 1 的 `backendPlanMountAnchor`、`write_failing_unshare()` 与 backend-plan GREEN receipt；Task 2 的 wrapper flags/default matrix；现有 ordinary `build` job 和独立 `dssb-build`/Hermes/Ironclaw jobs。
- Produces: 根 README 与 `dssb/README.md` 的用户可见能力边界；`verify_documentation_and_ci_source()` 的 literal contracts；`tests/test_ci_runtime.sh` 对 deterministic backend-plan source 和 CI 执行顺序的静态 gate。

**Recommended executor:** `documenting`

- [ ] **Step 1: 先扩展文档静态断言并运行 RED**

  在 `verify_documentation_and_ci_source()` 的 root README literals 中加入：

  ```bash
  '--overlay-mount HOST:SANDBOX'
  '--snap-mount HOST:SANDBOX'
  '显式选择 `podman` 或 `systemd-nspawn` 且未给 `--strategy` 时，wrapper 注入 `--strategy direct`'
  ```

  在 DSSB README literals 中加入：

  ```bash
  '`--overlay-mount HOST:SANDBOX`'
  '`--snap-mount HOST:SANDBOX`'
  '默认或显式 `bubblewrap` 仍保留模块的 `auto`'
  '显式策略始终原样保留'
  ```

  Run:

  ```powershell
  wsl -d nixos -- bash -lc 'cd /mnt/c/Users/hugefiver/source/ocsb && bash tests/test_dssb.sh --source-only'
  ```

  Expected: non-zero；`test_dssb` 报告 root `README.md` 缺少 `--overlay-mount HOST:SANDBOX`（即新增断言中的首个缺失 literal）；不得失败于 npm hash、lock metadata 或 official package build。

- [ ] **Step 2: 更新 `dssb/README.md` 的 wrapper flags 与策略边界**

  将 wrapper flags 列表明确写为：

  ```text
  - `--persist-dir DIR`、`-w/--workspace NAME`、`--strategy STRATEGY`、`--backend bubblewrap|podman|systemd-nspawn`
  - `--continue`、`--overwrite`、`--attach`/`--attach=PID`
  - `--env NAME[=VALUE]`、`--ro HOST:SANDBOX`、`--rw HOST:SANDBOX`
  - `--overlay-mount HOST:SANDBOX`、`--snap-mount HOST:SANDBOX`、`-s/--shell`、`--`
  ```

  随后加入含下列精确句子的段落，以满足静态契约并避免能力过度声明：

  ```text
  用户未给 `--strategy` 时，默认或显式 `bubblewrap` 仍保留模块的 `auto`；显式选择 `podman` 或 `systemd-nspawn` 时 wrapper 注入 `--strategy direct`。显式策略始终原样保留，不支持的 backend/strategy 组合继续由 OCSB fail closed。

  `--overlay-mount` 仍是 bubblewrap-only；`--snap-mount` 仍要求 btrfs subvolume source，并受所选 backend 的既有能力限制。systemd-nspawn 仍不支持 DSSB 默认 filtered network。
  ```

  不改 secret、persist、npm lifecycle 或默认 Web UI 的既有说明。

- [ ] **Step 3: 更新根 README 的 DSSB 使用说明**

  在 DSSB persist/workspace 段落之后增加 wrapper 参数与默认策略说明，必须包含下面两句：

  ```text
  DSSB wrapper 还转发 `--ro HOST:SANDBOX`、`--rw HOST:SANDBOX`、`--overlay-mount HOST:SANDBOX` 与 `--snap-mount HOST:SANDBOX`，并保留每个参数值的 argv 边界。

  默认或显式 bubblewrap 且未给策略时继续使用模块的 `auto`；显式选择 `podman` 或 `systemd-nspawn` 且未给 `--strategy` 时，wrapper 注入 `--strategy direct`；用户给出的显式策略不会被覆盖。
  ```

  紧接着重申 overlay mount 是 bubblewrap-only、snapshot 受 btrfs/backend 约束、systemd-nspawn filtered network 仍失败。不要把 Podman filtered network 描述成与 bwrap iptables 等价，也不要宣称本地测试覆盖真实 DSH API/profile/plugin 全流程。

- [ ] **Step 4: 在 `tests/test_ci_runtime.sh` 锁定 deterministic source 与执行顺序**

  在路径常量中增加：

  ```bash
  PROGRAMS_TEST="$SCRIPT_DIR/test_programs.sh"
  ```

  在 ordinary DSSB/programs invocation 检查后增加三个 source literals：

  ```bash
  require_literal "$PROGRAMS_TEST" 'mountAnchorHelper = backendPlanMountAnchor;' \
    'backend-plan fixture must inject its deterministic mount-anchor adapter' || true
  require_literal "$PROGRAMS_TEST" 'write_failing_unshare()' \
    'backend-plan fixture must fail if any path invokes unshare' || true
  require_literal "$PROGRAMS_TEST" 'exec ${realMountAnchor}/bin/ocsb-mount-anchor "$@"' \
    'backend-plan mutation-only path must delegate to the production helper' || true
  ```

  再用 workflow 行号锁定 backend-plan 在真实 bwrap capability probe 之前无条件运行：

  ```bash
  backend_plan_line="$(awk 'index($0, "bash tests/test_programs.sh . --case backend-plan") { print NR; exit }' "$WORKFLOW")"
  bwrap_probe_line="$(awk 'index($0, "- name: Probe real bwrap runtime capability") { print NR; exit }' "$WORKFLOW")"
  if [[ ! "$backend_plan_line" =~ ^[0-9]+$ || ! "$bwrap_probe_line" =~ ^[0-9]+$ ||
        "$backend_plan_line" -ge "$bwrap_probe_line" ]]; then
    fail 'deterministic backend-plan must run before the real bwrap capability probe'
  fi
  ```

  该静态 gate 不改变 `.github/workflows/ci.yml`：现有顺序已经满足要求。不要给 backend-plan 增加 capability skip、`continue-on-error`、`sudo` 或特权 runner。

- [ ] **Step 5: 运行 docs/source 与 CI static GREEN**

  Run:

  ```powershell
  wsl -d nixos -- bash -lc 'cd /mnt/c/Users/hugefiver/source/ocsb && bash tests/test_dssb.sh --source-only && bash tests/test_ci_runtime.sh'
  ```

  Expected: exit 0；包含 `PASS[GREEN-dssb-docs-ci-source]: README, subproject README, and CI literals are current`、`PASS[GREEN-ci-runtime-gate]: all runtime commands present; skips capability-based` 与 `CLEANUP PASS: ci runtime static contract creates no fixtures`。source-only 只校验官方 DSH source/lock/hash/derivation，不构建该 payload。

---

### Task 4: 完整允许范围内的回归验证与 cleanup receipt

**Files:**
- Verify: `tests/test_programs.sh`
- Verify: `dssb/wrapper.nix`
- Verify: `tests/test_dssb.sh`
- Verify: `dssb/README.md`
- Verify: `README.md`
- Verify: `tests/test_ci_runtime.sh`
- Verify unchanged: `lib/mkSandbox.nix`, `dssb/module.nix`, `.github/workflows/ci.yml`

**Interfaces:**
- Consumes: Tasks 1-3 的完整当前 revision 和所有 GREEN receipts。
- Produces: Bash syntax、Nix evaluation/default build、fake runtime/backend、static CI、mount-anchor boundary与工作树清洁证据；不产生 commit、tag、push、`result` symlink 或 official payload output。

**Recommended executor:** `normal-task`

- [ ] **Step 1: 运行修改 shell 文件的语法检查**

  Run:

  ```powershell
  wsl -d nixos -- bash -lc 'cd /mnt/c/Users/hugefiver/source/ocsb && bash -n tests/test_programs.sh tests/test_dssb.sh tests/test_ci_runtime.sh'
  ```

  Expected: exit 0，无 stdout/stderr。

- [ ] **Step 2: 重跑 Programs validation/backend-plan 与 production mount-anchor deterministic suite**

  Run:

  ```powershell
  wsl -d nixos -- bash -lc 'cd /mnt/c/Users/hugefiver/source/ocsb && set -euo pipefail; bash tests/test_programs.sh . --case validation; bash tests/test_programs.sh . --case backend-plan; env -u XDG_RUNTIME_DIR bash tests/test_programs.sh . --case runtime; env -u XDG_RUNTIME_DIR bash tests/test_mount_anchor.sh --ci-fake'
  ```

  Expected: Programs validation、backend-plan、runtime 三个 GREEN receipts；runtime 保持通过 production helper 与真实 bubblewrap，backend-plan 未输出 RED unshare 哨兵；mount-anchor `--ci-fake` 全部 required cases 通过且无 capability skip，从而证明计划适配器没有替代 production helper 的安全覆盖。

- [ ] **Step 3: 重跑 DSSB source/eval/lightweight wrapper fixtures**

  Run:

  ```powershell
  wsl -d nixos -- bash -lc 'cd /mnt/c/Users/hugefiver/source/ocsb && set -euo pipefail; bash tests/test_dssb.sh --source-only; bash tests/test_dssb.sh --case flake-outputs; bash tests/test_dssb.sh --case module-eval; fixture_dir="$(mktemp -d /tmp/dssb-ci-hardening-final-wrapper.XXXXXX)"; cleanup() { case "$fixture_dir" in /tmp/dssb-ci-hardening-final-wrapper.*) rm -rf -- "$fixture_dir" ;; *) printf "unsafe fixture path: %s\n" "$fixture_dir" >&2; return 1 ;; esac; }; trap cleanup EXIT; wrapper="$(bash tests/test_dssb.sh --build-lightweight-wrapper "$fixture_dir")"; bash tests/test_dssb.sh --case wrapper-contract "$wrapper"; DEEPSEEK_API_KEY=fixture-secret bash tests/test_dssb.sh --case wrapper-safety "$wrapper"'
  ```

  Expected: 所有 DSSB source/flake/module/wrapper GREEN receipts；fixture 只构建 fake inner wrapper；无 `dsh`/official `dssb` build。

- [ ] **Step 4: 运行 fake module bubblewrap 与 backend boundary fixture**

  Run:

  ```powershell
  wsl -d nixos -- bash -lc 'cd /mnt/c/Users/hugefiver/source/ocsb && set -euo pipefail; fixture_dir="$(mktemp -d /tmp/dssb-ci-hardening-final-module.XXXXXX)"; cleanup() { case "$fixture_dir" in /tmp/dssb-ci-hardening-final-module.*) rm -rf -- "$fixture_dir" ;; *) printf "unsafe fixture path: %s\n" "$fixture_dir" >&2; return 1 ;; esac; }; trap cleanup EXIT; sandbox="$(bash tests/test_dssb.sh --build-sandbox-fixture "$fixture_dir")"; env -u XDG_RUNTIME_DIR bash tests/test_dssb.sh --case module-bubblewrap "$sandbox"; bash tests/test_dssb.sh --case backend-boundaries "$sandbox"'
  ```

  Expected: `PASS[GREEN-dssb-module-bubblewrap]` 与 `PASS[GREEN-dssb-nspawn-filtered-rejection]`；如果本机 Podman 可用则还出现 `PASS[GREEN-dssb-podman]`，否则只允许现有 `SKIP[OPTIONAL-dssb-podman]: podman unavailable`。fixture 的 DSH、pnpm 与 peer 均为 fake/local derivations。

- [ ] **Step 5: 运行通用 backend 与 CI static contracts**

  Run:

  ```powershell
  wsl -d nixos -- bash -lc 'cd /mnt/c/Users/hugefiver/source/ocsb && set -euo pipefail; bash tests/test_backend.sh .; bash tests/test_ci_runtime.sh'
  ```

  Expected: backend summary 匹配 `=== backend Results: [0-9]+ passed, 0 failed ===`；CI static 输出两个 GREEN receipts 与 cleanup PASS。

- [ ] **Step 6: 运行允许的 Nix 全局 gate，只构建默认 ocsb**

  Run:

  ```powershell
  wsl -d nixos -- bash -lc 'cd /mnt/c/Users/hugefiver/source/ocsb && nix flake check --no-build "path:$PWD" && nix build --no-link "path:$PWD#packages.x86_64-linux.default"'
  ```

  Expected: 两条命令 exit 0；只 evaluate flake checks 并构建 `packages.x86_64-linux.default`。明确禁止把该命令替换为 `.#packages.x86_64-linux.dsh`、`.dssb`、Hermes 或 Ironclaw outputs。

- [ ] **Step 7: 检查 diff whitespace 与工作树副产物，不执行 Git 写操作**

  Run:

  ```powershell
  $env:GIT_MASTER = '1'; git diff --check; git status --short
  ```

  Expected: `git diff --check` exit 0；status 只包含本计划列出的六个实现修改文件，以及当前未跟踪的权威 spec/plan（若用户尚未自行纳入版本控制）；仓库内没有 `result`、`dssb/node_modules`、fixture temp、日志或 secret 文件。不得执行 `git add`/commit/push/tag。

---

## Spec coverage matrix

| Spec requirement | Implemented/proved by |
|---|---|
| backend-plan 不依赖非特权 user namespace | Task 1 RED 哨兵、测试 helper、统一 runner、GREEN |
| 保留 Podman/nspawn 唯一 `/usr/bin` mount 与固定 PATH | Task 1 Step 6 的现有精确 regex/count assertions |
| mutation 使用真实 helper，安全语义仍由 mount-anchor suite 覆盖 | Task 1 Steps 3-4；Task 4 Step 2 |
| wrapper 转发 overlay/snapshot mount 且保持 argv 边界 | Task 2 mount/DSH boundary matrix 与 NUL argv |
| 非 bwrap 默认 direct；bubblewrap/显式策略不变；最后 backend 生效 | Task 2 完整策略矩阵与 parser state |
| 原生 capability errors、secret、permission 与 persist safety 不变 | Global Constraints；Task 2 safety GREEN；Task 4 backend boundaries |
| README 与 CI 静态契约同步 | Task 3 source literals、deterministic source/order gate |
| 不构建官方 DSH/Hermes/Ironclaw，只跑允许 fixture/Nix gate | Global Constraints；Task 4 每条命令与预期输出 |
| 不安装软件、不执行 Git 写命令 | Global Constraints；Task 4 cleanup receipt |

## Explicit non-goals

- 不让 Podman/systemd-nspawn 支持 overlayfs workspace 或 `--overlay-mount`。
- 不让 systemd-nspawn 支持 DSSB 默认 filtered network，也不把 Podman 网络描述成 bwrap iptables 等价物。
- 不改变通用 OCSB backend 默认策略或 `mkSandbox` API。
- 不用 Programs backend-plan 代替 `tests/test_mount_anchor.sh` 的 FD/identity/namespace 安全测试。
- 不在本地构建或运行官方 DSH、DSSB、Hermes Agent、Ironclaw payload，也不宣称已验证真实 DSH API/profile/plugin 全流程。

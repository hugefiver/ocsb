# DSSB CI 与 OCSB 能力补齐设计

## 目标

修复提交 `52ac920` 后 GitHub Actions `build` job 在 `Programs validation and backend plan` 步骤失败的问题，并补齐 DSSB wrapper 中明确属于参数路由和 backend 默认策略的缺口。保留 OCSB 已声明的 backend 能力边界，不宣称三种 backend 完全对等。

## 已观察证据

- GitHub Actions run `33386522467` 中 `Check flake` 成功，随后 `Programs validation and backend plan` 失败，后续 DSSB job 因依赖关系被跳过。
- 本地 WSL 运行相同的 validation 与 backend-plan 命令均通过。
- `tests/test_programs.sh` 的 systemd-nspawn 计划检查在非 root 环境调用 `unshare --user --map-current-user --mount --keep-caps`，使本应只验证生成 argv 的测试依赖 runner 是否允许非特权 user namespace。
- 公开 Actions API 只返回失败步骤和退出码，详细 stderr 需要仓库管理员身份；因此修复以消除该测试不必要的宿主能力依赖并增加受控失败回归为准，而不把不可见 stderr 当作已观察事实。
- `dssb/wrapper.nix` 未转发 OCSB 已支持的 `--overlay-mount` 与 `--snap-mount`。
- DSSB 模块默认 `workspace.strategy = "auto"`；OCSB 在非 btrfs 上把 `auto` 解析为 `overlayfs`，而 Podman/systemd-nspawn v1 明确拒绝 overlayfs。显式选择非 bubblewrap backend 且未给策略时，当前 wrapper 因而通常不可用。

## 方案选择

### 采用：确定性 backend-plan 适配器

`tests/test_programs.sh` 为 backend-plan fixture 注入测试专用 `mountAnchorHelper`：

1. `--mutation-only` 调用继续委托真实 `ocsb-mount-anchor`，保留 workspace 状态协议验证。
2. 最终 backend 调用解析 helper 已验证格式的 `--source-spec` 与 `--replace`，用原始受控源路径替换计划 token 后执行 fake backend。
3. validation 与 bubblewrap runtime fixture 继续使用真实 helper。
4. mount-anchor 的 FD、identity 与 namespace 安全语义继续由 `tests/test_mount_anchor.sh` 验证；programs backend-plan 只负责 `/usr/bin` mount 与 PATH 转换。

不采用整体 skip，因为会丢失 Podman/systemd-nspawn 计划断言；不采用特权 runner，因为计划测试不应需要额外宿主权限。

## DSSB wrapper 行为

### 参数路由

将 `--overlay-mount` 和 `--snap-mount` 作为需要一个值的 OCSB 参数，与 `--ro`、`--rw` 一样原样保留 argv 边界并在首个 DSH 参数之前转发。帮助文本、README 和 wrapper fixture 同步更新。

### backend 默认策略

wrapper 记录用户是否显式提供 `--strategy` 以及最后选择的 `--backend`：

- 默认或显式 `bubblewrap` 且未给策略：保持模块的 `auto`。
- 显式 `podman` 或 `systemd-nspawn` 且未给策略：注入 `--strategy direct`，避免 `auto` 在普通非 btrfs 文件系统上解析为不支持的 overlayfs。
- 用户显式给出策略：不覆盖；不支持的组合继续由 OCSB fail closed。

该默认只影响 DSSB wrapper，不改变通用 `mkSandbox` API。systemd-nspawn 仍会因 DSSB 默认 filtered network 明确失败；需要 host/blocked network 的下游必须组合 `nixModules.dssb`，不在 runtime wrapper 中伪造网络开关。

## 安全与错误流

- 不自动捕获 API key；secret 仍只能通过显式 `--env` 或持久化 credentials 文件进入沙盒。
- 不改变 `DSH_PERMISSION_MODE=danger-full-access`：DSH 内层 sandbox 关闭，真实边界仍由 OCSB 外层提供。
- 不放宽现有目录 ownership/mode/symlink 校验。
- 非 bubblewrap 的 overlayfs、overlay mount 与 systemd-nspawn filtered network 继续产生 OCSB 原生错误。
- `--snap-mount` 是否可用仍由 btrfs source 和 backend 现有能力决定。

## 测试与验收

1. 在 PATH 中放置必然失败的 `unshare`，旧 backend-plan 必须失败，确定测试确实耦合该宿主能力。
2. 注入 plan helper 后，在同一失败 `unshare` 条件下 backend-plan 仍验证 Podman 与 systemd-nspawn 的唯一 `/usr/bin` 只读 mount 和固定 PATH，并成功结束。
3. DSSB wrapper fixture 验证 `--overlay-mount`、`--snap-mount` 的 argv 边界。
4. wrapper fixture 验证非 bubblewrap 未显式策略时注入 `direct`，显式策略不被覆盖，bubblewrap 仍使用 `auto`。
5. 运行 DSSB source、wrapper contract/safety、module/backend fixture；不在本地构建官方 DSH payload。
6. 运行 `nix flake check --no-build`、默认 ocsb build、相关 shell 回归测试和修改文件诊断。

## 兼容性结论边界

完成后可以证明 DSSB 复用 OCSB 的 workspace、持久状态、显式环境、普通/overlay/snapshot mount、closure-only store、filtered bubblewrap 网络与公共 backend 转换链。不能据此宣称 Podman 与 bubblewrap 网络语义相同、systemd-nspawn 支持 filtered network、非 bubblewrap 支持 overlayfs，或真实 DSH 的 API/profile/plugin 全流程已由本地测试覆盖。

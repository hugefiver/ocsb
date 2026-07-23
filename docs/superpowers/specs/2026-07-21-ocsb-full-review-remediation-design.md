# OCSB 全仓审查问题修复设计

## 目标

修复 `master@a1968a5` 全仓审查中确认的全部问题，并为每项问题保存修复前失败、修复后通过的测试证据。实现必须保持现有 bubblewrap 默认行为、非 bubblewrap v1 能力边界、Hermes/Ironclaw 持久化布局及外部应用本地不构建约束。

## 方案选择

采用按安全边界分域修复：先收紧宿主路径、runtime 目录、PID 身份和锁，再处理 backend、Hermes、Ironclaw、架构输出与 CI。相比逐文件补丁，该方案避免在 wrapper 中重复不一致的安全规则；相比重写 launcher，改动仍局限于已确认问题。

## 实施分域

### 1. 宿主路径与进程身份

- fallback runtime 目录使用当前 UID 专属路径，必须由当前用户拥有、非 symlink 且 mode 为 `0700`。
- pidfile 原子写入 PID、`/proc/<pid>/stat` start time 和实例标识；读取方必须逐项验证。
- workspace destructive operation 和 bind source 在使用点执行 no-follow/canonical containment 检查。项目树 mutation 必须先用 `openat2` 固定 project/base/workspace dirfd，再仅通过这些 dirfd 执行创建、清空、git-worktree 和 btrfs 操作；禁止在检查后重新解析 `$PROJECT_DIR/.ocsb/...` 字符串。mutation 完成后输出 dev/ino receipt，最终 mount anchor 必须消费该 receipt，公开路径在两阶段间被替换时安全拒绝且不启动 backend。
- btrfs `snapshot` 与 git-worktree `worktree` 在 `--continue` 时必须是非 symlink、canonical path 位于 workspace marker 下，并满足各自类型约束。

覆盖问题：共享 `/tmp/ocsb` 文件覆盖、Hermes `--replace` 误杀、nested symlink mount、workspace path TOCTOU。

### 2. Launcher 与 backend 运行时语义

- Podman/systemd-nspawn 的合成 rootfs 在每次受锁保护的启动前重建；不得让 `/tmp`、`/run` 或未显式持久化的 home 内容跨运行保留。
- dual-layer inner wrapper 使用配置的 `workspace.sandboxDir`，并继承 outer sandbox 已经筛选过的环境；只覆盖 inner layer 必须变化的变量。
- 通用 `app.daemon` supervisor 不再创建 Hermes venv 或联网升级 pip；Hermes 初始化继续由 Hermes template 自己负责。
- filtered-network 创建独立清理监护进程，在 bwrap/slirp 生命周期结束后删除 FIFO 和临时目录。

覆盖问题：container rootfs 持久化、dual-layer 自定义目录失败、dual-layer env 丢失、通用 daemon Hermes/pip 副作用、filtered FIFO 泄漏。

### 3. Hermes 生命周期与秘密交付

- wrapper `--replace` 只能终止 pidfile 中实例标识与当前 persist/state 相符、PID start time 相符且可确认属于 ocsb/bwrap 的进程。
- gateway service 的 start/stop/restart/status 使用 runtime lock 串行化，并为 supervisor/gateway pidfile保存及验证 start time。
- caller-provided API key 文件保持原样只读；若同时传入额外 secret-like `--env`，wrapper 明确拒绝并解释如何合并到 caller 文件，避免静默丢值或复制 caller secret。

覆盖问题：Hermes replace stale/cross-persist kill、gateway PID/并发竞态、caller env file 与 extra secret 丢值。

### 4. Ironclaw sidecar 与秘密创建

- 在读取/生成 sidecar 密码前获取 persist-scoped `flock`，锁覆盖 inspect/create/start/readiness/初始化。
- wrapper 创建 sidecar 时写入 owner、persist identity、image、volume 和 port labels；复用时验证 labels、实际 image、mount 和端口，不匹配则失败而不是静默复用。
- 默认 pgvector image 使用 immutable multi-architecture digest，同时保留显式 `--db-sidecar-image` override。
- `SECRETS_MASTER_KEY` 创建前设置 `umask 077`，采用临时文件加原子 rename，避免创建窗口中的宽权限。

覆盖问题：同名 sidecar 身份误信、并发初始化/password race、floating image tag、master key 创建权限窗口。

### 5. 架构输出与持续验证

- `_x86_64_v3` Ironclaw variants 仅在 `x86_64-linux` package set 中生成。
- CI 运行 core wrapper/backend/binpath/git-worktree 测试，并运行环境支持的 network、dual-layer、btrfs、Hermes、Ironclaw 测试。
- capability 不足必须输出明确 SKIP；不得因 `GITHUB_ACTIONS` 环境变量无条件成功跳过。
- 删除会吞掉被测命令失败的 `|| true`；需要接受非零退出的场景必须显式捕获并断言退出码和产物。

覆盖问题：aarch64 暴露 x86-v3 输出、CI runtime gate 形同虚设、测试假绿路径。

## RED/GREEN 场景矩阵

| 问题 | 修复前失败证据 | 修复后通过条件 |
|---|---|---|
| nested workspace symlink | 用 symlink 替换 `snapshot/worktree` 后 `--continue` 接受 | launcher 拒绝且目标未挂载/修改 |
| runtime pidfile clobber | 预置 fallback pidfile symlink 后目标被写入 | launcher 拒绝不安全目录/文件且目标不变 |
| Hermes replace 误杀 | stale/cross-persist pidfile 指向 live fixture process | fixture process 存活，wrapper拒绝替换 |
| workspace TOCTOU | 在校验和使用间替换 workspace path | anchored/no-follow 使用拒绝替换路径 |
| container rootfs persistence | 两次 prepare 间放置 sentinel | 第二次启动前 sentinel 不存在 |
| dual-layer sandboxDir | `/home/sandbox` variant inner shell失败 | inner shell在配置目录执行成功 |
| dual-layer env | outer `FOO=bar`，inner 为空 | inner 输出 `FOO=bar` |
| generic daemon pip | 非 Hermes daemon source 含/执行 Hermes venv 初始化 | 生成 supervisor 不含 Hermes/pip，离线 fixture启动 |
| Hermes caller file + secret | 组合参数静默启动但 secret缺失 | wrapper 明确非零拒绝并给出诊断 |
| gateway race/PID | 并发 start 或 stale PID 被接受 | lock 串行化，stale PID 被清除且仅一 supervisor |
| sidecar identity | fake OCI 返回同名错误 image/volume/port | wrapper 非零拒绝并指出 mismatch |
| sidecar concurrency | 两个 fixture 同时首次启动 | 仅一次 create，密码与 container metadata一致 |
| mutable sidecar image | 默认参数只含 `:pg18` | 默认值包含固定 `@sha256:` digest |
| master key mode | source/preExec 在重定向前未设私有 umask | test fixture观察创建瞬间 mode 为 `0600` |
| aarch64 x86 variant | attr 可求值且含 x86 flags | aarch64 package set 不再导出该 attr |
| CI runtime gate | workflow 未调用或测试无条件 skip | workflow/脚本断言证明行为测试会运行或 capability-skip |
| filtered FIFO cleanup | filtered run 后宿主残留 FIFO | bwrap退出后临时目录消失 |
| swallowed test failure | fake launcher 失败但策略测试继续 | 测试立即失败并保留诊断 |

## 错误处理

- 所有安全拒绝使用稳定、可断言的错误前缀，并包含失败对象，不输出 secret value。
- cleanup 在成功、失败和信号路径均幂等；不能以忽略错误掩盖正在使用的 sidecar 或 workspace。
- backend/runtime capability 不可用时，产品命令失败；测试环境 capability 不可用时明确 SKIP，两者不得混淆。

## 验证层级

1. 每项新回归测试先在原始实现或等价 pre-fix fixture 上产生预期失败。
2. 分域实现后运行对应 targeted tests。
3. 运行 `bash -n`、`nix flake check --no-build`、默认 ocsb build 和全部本地允许的 shell suites。
4. 对 dual-layer、filtered-network、PID/path 场景运行真实 launcher；对 OCI 使用可记录 argv/metadata 的 fake runtime。
5. 由独立 Oracle 和 reviewer 复核完整 working-tree diff、RED/GREEN 证据和未覆盖环境限制。

## 非目标

- 不改变 host network、direct workspace、host-daemon 或非 bubblewrap parity 的既有产品边界。
- 不重写 `mkSandbox`，不引入新的 runtime backend。
- 不在本地构建 Hermes、Ironclaw 或 retained/arch external payload。
- 不执行 git commit、push 或 tag；版本控制写入需要用户另行明确授权。

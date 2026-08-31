# DSSB 与沙盒内程序互调设计

## 目标

在仓库内新增可独立提取的 `dssb/` 第一方子项目，为 DeepSeek Harness（`dsh`）提供可复现的 Nix 包、ocsb 配置模块和持久化启动包装器。根 flake 必须以 `nixModules.dssb` 导出该模块，并提供 `packages.<system>.dsh` 与 `packages.<system>.dssb`。

同时扩展 ocsb 的声明式模块，使同一沙盒实例中的主程序、后台 daemon 和额外程序可以通过稳定命令名、普通 argv、stdin/stdout/stderr 与退出码互相调用。跨沙盒 RPC、服务发现、宿主 PATH 继承和 attach backend 抽象不属于本次范围。

## 上游与版本

- 官方上游：`https://github.com/deepseek-ai/deepseek-harness`
- 使用 npm 已发布包：`@deepseek-ai/dsh@0.1.1-rc.2`
- CLI：`dsh`，入口 `lib/bin.js`
- Node 约束：`^22.19.0 || >=24.0.0`
- npm tarball integrity：`sha512-UP1UIh6q3Gme/yXRn/QL2P8IsVlv8Shpg22TRJIZPsCRWLm4CBiA1MUvXmJAfsOEETBMLAl+xWPtFw6ICsN3wg==`

不使用未发布到 npm 的 `dsh-v0.1.2-alpha.1` 作为当前包版本。`dssb/package.json` 与 `dssb/package-lock.json` 固定完整 npm 依赖图；`dssb/package.nix` 使用 Nixpkgs 的 npm cache 构建接口并固定依赖 hash。构建结果仅暴露 `$out/bin/dsh`，不在运行时使用 `npx` 或访问 npm registry。

## 子项目边界

`dssb/` 是根仓库直接跟踪的普通目录，不创建嵌套 `.git`、`.gitmodules`、独立 lock 或不存在的 subtree remote。目录内聚合所有 DSH 专属内容：

```text
dssb/
├── README.md
├── default.nix          # 子项目组装入口
├── module.nix           # nixModules.dssb
├── package.nix          # @deepseek-ai/dsh 固定版本包
├── package.json
├── package-lock.json
└── wrapper.nix          # 持久化宿主包装器
```

通用 ocsb 能力继续位于根 `modules/` 与 `lib/`；DSH 特有逻辑不得进入 `lib/mkSandbox.nix`。

## 根 flake 公共接口

根 flake 新增：

```nix
nixModules.dssb = import ./dssb/module.nix;

packages.<system>.dsh = pkgs.callPackage ./dssb/package.nix { };
packages.<system>.dssb = pkgs.callPackage ./dssb/wrapper.nix {
  dssbSandboxBase = mkSandbox ({ ... }: {
    imports = [ self.nixModules.dssb ];
  });
};
```

`nixModules.dssb` 是 ocsb 配置模块，不冒充 NixOS 系统模块。典型消费方式：

```nix
(ocsb.lib.mkSandbox { inherit system; }) ({ ... }: {
  imports = [ ocsb.nixModules.dssb ];
})
```

模块定义 `dssb.package`，默认由当前 `pkgs` 构建 `dssb/package.nix`，测试或下游可覆盖为兼容包。模块还定义与通用 `programs` 同类型的 `dssb.extraPrograms` attrset，并把它合并到通用 `programs` 配置；这使下游无需复制完整 DSH 模板即可声明 DSH 可调用的工具。

## 通用 `programs` API

新增 `modules/programs.nix` 并由 `modules/default.nix` 导入。接口为：

```nix
programs.<command> = {
  package = <derivation>;
  binPath = "bin/<binary>";
};
```

规则：

1. `<command>` 必须匹配 shell 安全的命令名字符集，不能包含 `/`、空白或 `..`。
2. `binPath` 必须是非空相对路径，不能含 `..` 路径段。
3. 构建时校验 `${package}/${binPath}` 是可执行普通文件；缺失、目录或不可执行目标必须 fail closed。
4. 每个条目只在声明式命令目录中暴露一个以 `<command>` 命名的符号链接；不会隐式暴露该 package 的其他 binary。
5. 重复 command 由 Nix attrset 语义拒绝；与批量 `packages` 暴露出的同名文件发生冲突时构建失败，不允许静默覆盖。

沙盒 PATH 固定为：

```text
<app.binPath 所在目录>:/usr/bin:/home/sandbox/.nix-profile/bin:/nix/var/nix/profiles/default/bin
```

主程序仍具有最高优先级；声明式 `packages` 和 `programs` 位于可写 profile 之前，因此运行时安装的同名命令不能遮蔽声明式工具。该命令目录进入 closure-only store，并由 bubblewrap、Podman、systemd-nspawn 共用现有 backend 转换流程。

`app.daemon` 的语义保持“先 spawn、后启动前台程序”，不增加虚假的 readiness 保证。服务依赖仍必须通过程序自身的可观察健康检查等待。

## DSSB 模块

`dssb/module.nix` 设置：

- `app.name = "dssb"`
- `app.package = config.dssb.package`
- `app.binPath = "bin/dsh"`
- `workspace.strategy = "auto"`
- `workspace.baseDir = ".ocsb"`
- `workspace.name = "dssb"`
- `workspace.sandboxDir = "/workspace"`
- `network.enable = true`
- `env.DSH_HOME = "/home/sandbox/.dsh"`
- `env.DSH_PERMISSION_MODE = "danger-full-access"`，由外层 ocsb 承担真实文件与网络边界，避免 DSH 再嵌套不可靠的沙箱
- `env.DSH_TELEMETRY_DISABLED = "1"`
- DSH 所需的基础 shell 工具、通过 `programs.pnpm` 暴露的根 nixpkgs `pkgs.pnpm` 11.15（供 `dsh plugin` 使用），以及 `dssb.extraPrograms`。`pnpm` 因 `bin/pnpm -> ../libexec/...` 相对链接不进入批量 `packages`；它作为具名绝对 store target 暴露为 `/usr/bin/pnpm`，而不同的 `dssb.extraPrograms.pnpm` 定义会产生 module leaf conflict 并 fail closed。

模块不设置固定 profile，因而同一包装器支持：

```text
dssb --profile headless "task"
dssb web --no-open
dssb plugin --profile web add <package>
```

固定的 `0.1.1-rc.2` npm 发行版只随包提供 `web` 与 `headless` profile；设计不承诺该版本中尚未发布的 `acp`、`sdk` 或 `sdk-minimal` bundles。用户仍可通过 profile/plugin 机制创建自定义组合。`dssb web --no-open` 仅记录已打包 web profile 的进程调用，不承诺默认 `packages.dssb` 上的宿主可访问 Web UI：默认 filtered 网络不会把沙盒 loopback 或端口转发给宿主。

需要宿主浏览器访问时，下游可自行组合 `nixModules.dssb` 并显式使用 `network.enable = lib.mkForce null;` 选择 host network；这是放宽隔离的下游决定，而非 wrapper 新增的端口、跨实例 socket 或 runtime 网络 flag。

## 持久化包装器

`packages.dssb` 的 binary 名称为 `dssb`。默认持久化根为 `$HOME/.cache/ocsb/dssb`，可通过 `OCSB_DSSB_PERSIST_DIR` 或 `--persist-dir DIR` 覆盖。包装器创建 mode 0700 的：

```text
$PERSIST_DIR/home/
$PERSIST_DIR/state/
```

并执行：

- `OCSB_STATE_BASE_DIR=$PERSIST_DIR/state`
- 将 `$PERSIST_DIR/home` 读写挂载到 `/home/sandbox`
- 在沙盒中设置 `DSH_HOME=/home/sandbox/.dsh`
- 保持调用者 cwd 作为 `/workspace` 的来源，不切换到持久化目录
- 把 ocsb 控制参数与 DSH 参数分离；首个未知参数或 `--` 后参数均作为 DSH argv
- 支持 `--workspace`、`--strategy`、`--backend`、`--continue`、`--overwrite`、`--attach`、`--env`、`--ro`、`--rw` 和 `--shell`
- 若 workspace 状态已存在且调用者未显式指定 `--continue/--overwrite`，自动使用 `--continue`；首次运行不强加 `--continue`

`DEEPSEEK_API_KEY` 等密钥不写入 Nix store、命令默认值或持久化环境快照。用户通过 `--env DEEPSEEK_API_KEY` 显式转发，或写入 mode 0600 的 `$DSH_HOME/.credentials.yaml`。包装器不自动捕获模糊的 secret-like 环境变量。

## 错误处理与安全边界

- npm source 与 dependency hash 必须固定；离线构建不得访问网络。依赖安装脚本必须在 Nix 的离线 npm cache 上执行，以恢复并验证 `node-pty`/DSH subprocess 所需的 native helper；不能用全局 `--ignore-scripts` 产出表面可启动但功能残缺的包。
- 非法 `programs` 名称、绝对/穿越 `binPath`、缺失、目录或不可执行目标均在求值或构建阶段失败。
- 包装器保留参数边界，禁止用 `eval` 处理 DSH argv。
- 持久化路径规范化为绝对路径；相对路径和不安全的现有对象失败。
- `network.enable = true` 在 systemd-nspawn 上继续按现有契约明确失败，不降级到 host network；默认 wrapper 也不把 web profile 的沙盒 loopback/端口暴露给宿主。
- `programs` 不导入 host PATH，也不创建跨实例 socket、端口或注册表；仅下游显式 host-network override 可为其自担隔离放宽的宿主访问需求选择不同边界。

## 测试与验收

新增测试必须使用 fake DSH/fake peer，避免本地编译外部应用：

1. `nixModules.dssb` 可从根 flake 获取并用 fake `dssb.package` 求值、构建。
2. 根 flake 暴露 `packages.dsh` 与 `packages.dssb`。
3. 包装器保持调用 cwd，创建稳定持久化布局，正确挂载 home/state，并准确传递 DSH argv 与退出码。
4. 主程序可调用具名 peer；daemon 可调用 peer；peer 可调用主程序 package 中的 binary。
5. 可写 profile 中的同名 binary 不能遮蔽声明式 peer。
6. 无效命令名、无效 `binPath`、目录 target、缺失或不可执行 binary 均 fail closed。
7. 对 bubblewrap 做真实执行验证；对 Podman/systemd-nspawn 至少验证生成计划与现有能力边界不回归。有可用 Docker/Podman 时补充真实 backend 运行。
8. 运行 `nix flake check --no-build`、默认 ocsb build、相关 shell 回归测试和修改文件诊断。

本地不编译官方 DSH payload；官方 package 输出由 CI/Cachix 构建。若 CI 尚无相应 job，新增与 Hermes 类似的独立 dssb build job。

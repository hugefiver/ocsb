# DSSB（DeepSeek Harness sandbox）

此目录是 ocsb 根仓库中的第一方子项目，不是独立仓库：没有独立的 `flake.nix` 或 `flake.lock`，但有固定的 `package-lock.json`，用来锁定 `@deepseek-ai/dsh@0.1.1-rc.2` 的完整 npm 依赖图。

根 flake 提供两种不同消费面：`packages.<system>.dsh` 是未包装的官方 CLI，`packages.<system>.dssb` 是持久化 ocsb wrapper；模块则通过 `nixModules.dssb` 暴露给下游。

## 在下游 flake 中使用模块

```nix
(ocsb.lib.mkSandbox { inherit system; }) ({ pkgs, ... }: {
  imports = [ ocsb.nixModules.dssb ];

  dssb.extraPrograms.rg = {
    package = pkgs.ripgrep;
    binPath = "bin/rg";
  };
})
```

公开选项的类型为：

```text
dssb.package : package
dssb.extraPrograms : attrsOf { package; binPath; }
```

`dssb.package` 默认是当前根 nixpkgs 构建的 DSH package，也可由测试或下游以兼容 package 覆盖。每个 `dssb.extraPrograms` 条目都会合并到通用 `programs`，只以条目名在 `/usr/bin` 暴露一个可执行 regular file；无效名称、缺失/目录/不可执行 target，以及与既有命令的 collision 都 fail closed。

模块的基础 shell 工具走 `packages` 批量公开。`pnpm` 是例外：它来自根 `pkgs.pnpm` 11.15，但其 `bin/pnpm -> ../libexec/...` 是相对链接，模块因此用 `programs.pnpm` 将具名绝对 store target 暴露为 `/usr/bin/pnpm`，而不把 pnpm 放入 bulk `packages`。`dssb.extraPrograms.pnpm` 的不同定义会与该 module leaf conflict，并 fail closed。DSH plugin 调用的是这个声明式 pnpm，不使用 host PATH、corepack 或运行时下载。

## 运行与持久化

wrapper binary 是 `dssb`，可用 `nix run github:hugefiver/ocsb#dssb -- ...` 启动。固定发行版只记录以下三种调用面：

```bash
dssb --profile headless "task"
dssb web --no-open
export PLUGIN_PACKAGE='@scope/dsh-plugin-example'
dssb plugin --profile web add "$PLUGIN_PACKAGE"
```

`headless` 和 `web` 是 `0.1.1-rc.2` 随包发布的 profile；plugin/profile 机制可以组合自定义流程，但此文档不承诺未发布 bundle。

`dssb web --no-open` 是已打包 `web` profile 的进程调用，不是默认宿主可访问 Web surface。默认 `packages.dssb` 使用 filtered network，只在沙盒内启动该服务；不会自动转发端口，也不会把沙盒 loopback 暴露给宿主浏览器。需要宿主浏览器访问时，下游必须显式以 host network 组合模块，这会放宽隔离：

```nix
(ocsb.lib.mkSandbox { inherit system; }) ({ lib, ... }: {
  imports = [ ocsb.nixModules.dssb ];
  network.enable = lib.mkForce null;
})
```

这个下游覆盖不为默认 wrapper 新增端口转发、跨实例 socket 或 runtime 网络 flag。

wrapper flags：

- `--persist-dir DIR`、`-w/--workspace NAME`、`--strategy STRATEGY`、`--backend bubblewrap|podman|systemd-nspawn`
- `--continue`、`--overwrite`、`--attach`/`--attach=PID`
- `--env NAME[=VALUE]`、`--ro HOST:SANDBOX`、`--rw HOST:SANDBOX`、`-s/--shell`、`--`

默认 persist root 为 `~/.cache/ocsb/dssb`，其中 `home/` 与 `state/` 必须是当前用户拥有的 mode 0700 实体目录。`home/` 挂到 `/home/sandbox`，`OCSB_STATE_BASE_DIR` 固定为 `$PERSIST_DIR/state`；wrapper 保持 caller cwd，因此 caller project 仍映射到 `/workspace`。可使用 `OCSB_DSSB_PERSIST_DIR=/absolute/path` 或 `--persist-dir /absolute/path` 覆盖；相对路径、symlink 和不安全对象会被拒绝。

DSSB 默认使用 filtered bubblewrap 网络（`network.enable = true`）。`DSH_PERMISSION_MODE=danger-full-access` 仅禁用 DSH 的内部嵌套 sandbox，真实文件、身份与网络边界仍由 ocsb 负责。Podman 是现有 filtered backend 的映射，不与 bwrap iptables 声称完全等价；systemd-nspawn v1 的 filtered 网络会 fail closed。

不会自动捕获 secret-like 环境变量。需要临时传递 API key 时，显式使用 `dssb --env DEEPSEEK_API_KEY ...`；长期 credentials 建议放在 `$DSH_HOME/.credentials.yaml` 等 DSH 文件中，并保持 mode 0600。generic `--env` 仍可能对本机进程可见，不应把密钥写入 Nix source、默认参数或持久化 env snapshot。

## 更新 npm lock 与 hash

更新 `package.json` 后，在 OS temp 目录生成 lock：`npm install --package-lock-only --ignore-scripts`。这一步只生成 `package-lock.json`，不是 Nix package build，也不会验证 native lifecycle。审查并复制 lock 后，用根锁定 nixpkgs 的 `prefetch-npm-deps dssb/package-lock.json` 重新计算 `npmDepsHash`，再运行 `bash tests/test_dssb.sh --source-only` 校验版本、integrity、lock 与 hash。

真正的 Nix package build 不设置 package-level `npmFlags --ignore-scripts`，也不自定义 `configurePhase` 或手写 `npm install`/`npm ci`/`npm rebuild`。默认 `npmConfigHook` 在离线 cache 中完成一次 lifecycle rebuild；`postConfigure` 只进行 ESM `node-pty` native smoke 并写入 receipt marker。

本地不得构建官方 `dsh` 或 `dssb` payload：只运行 source/static tests、默认 ocsb build 和 fake fixtures。普通 CI 也只跑 source/fake gates；独立 `dssb-build` job 才构建官方 package 与 wrapper、检查 node-pty receipt、运行真实 wrapper smoke，并在有 token 时推送 Cachix。

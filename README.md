# ocsb

基于 [bubblewrap](https://github.com/containers/bubblewrap) 的 Nix 沙箱框架。原生支持 [OpenCode](https://github.com/opencode-ai/opencode) 与 [Ironclaw](https://github.com/nearai/ironclaw)，也可用同样的模型沙箱化任意可执行文件。

特性：closure-only `/nix/store`、可切换的网络隔离（host / 过滤 / 无网）、CoW workspace（overlayfs/btrfs/git-worktree/direct）、非 root 身份、capability 全 drop、声明式 Nix 模块。

## 系统要求

- Linux x86_64 / aarch64，启用 flakes 的 Nix
- btrfs workspace 需要根挂载带 `user_subvol_rm_allowed`（无此选项时自动降级 overlayfs）

## 内置 sandbox

| 命令 | 说明 |
|---|---|
| `nix run github:hugefiver/ocsb` | 默认：交互 bash + opencode 配置 |
| `nix run github:hugefiver/ocsb#ironclaw-sandbox` | Ironclaw 最新版（v0.26.0），自带 postgres18 + pgvector |
| `nix run github:hugefiver/ocsb#ironclaw-sandbox_v0_25_0` | Ironclaw v0.25.0 |
| `nix run github:hugefiver/ocsb#ironclaw-sandbox_v0_24_0` | Ironclaw v0.24.0 |
| `nix run github:hugefiver/ocsb#ironclaw-sandbox_x86_64_v3` | Ironclaw 最新版，x86-64-v3 优化（Haswell+） |

每个版本同时提供 `_x86_64_v3` 后缀的微架构变体（如 `ironclaw-sandbox_v0_25_0_x86_64_v3`），针对 2013+ Intel/AMD CPU 编译。无后缀变体使用 baseline x86-64-v1。

构建产物在 `./result/bin/`。

## 命令行用法

```bash
# 交互 shell
./result/bin/ocsb

# 命名 workspace（CoW 隔离）
./result/bin/ocsb -w my-feature

# 继续上次的 workspace
./result/bin/ocsb -w my-feature --continue

# 重置 workspace
./result/bin/ocsb -w my-feature --overwrite

# 指定 workspace 策略
./result/bin/ocsb -w my-feature --strategy git-worktree

# 临时 bind mount
./result/bin/ocsb --ro ~/data:/workspace/data --rw /tmp/out:/workspace/out

# 单目录 CoW（不影响 workspace 策略）
./result/bin/ocsb --overlay-mount /data/models:/workspace/models
./result/bin/ocsb --snap-mount /data/datasets:/workspace/datasets   # 源需为 btrfs subvol

# 直接跑命令
./result/bin/ocsb -- echo hi
```

## Workspace 策略

| 值 | 说明 |
|---|---|
| `auto`（默认） | 探测：能用 btrfs 就 btrfs，否则 overlayfs |
| `overlayfs` | overlay，upper 在 `~/.cache/ocsb/<hash>/<name>/upper` |
| `btrfs` | btrfs subvol snapshot；需 `user_subvol_rm_allowed` |
| `git-worktree` | detached worktree；需 git 仓库 |
| `direct` | 直接 bind 项目目录（无隔离） |

## 网络模式

| `network.enable` | 行为 |
|---|---|
| `null`（默认） | 共享宿主网络栈，不隔离 |
| `true` | slirp4netns NAT + iptables 屏蔽私网/链路本地；fail-closed |
| `false` | `--unshare-net`，无任何连通性 |

`network.enable = true` 兼容宿主侧 TUN 代理（Clash Verge Rev / Mihomo TUN）：流量经宿主路由表 → TUN 拦截，沙箱内无法直连 LAN，无法访问宿主 loopback 服务。

## 自定义 sandbox

```nix
{
  inputs.ocsb.url = "github:hugefiver/ocsb";
  outputs = { nixpkgs, ocsb, ... }: {
    packages.x86_64-linux.default =
      (ocsb.lib.mkSandbox { system = "x86_64-linux"; })
      ({ pkgs, ... }: {
        app.name = "my-sandbox";
        app.package = pkgs.opencode;       # null 则 = 交互 bash
        app.binPath = "bin/opencode";

        packages = with pkgs; [ git ripgrep fd jq curl ];
        mounts.ro = [ "~/.config/opencode" ];
        mounts.rw = [];

        workspace = { strategy = "auto"; baseDir = ".ocsb"; name = "_"; };

        network.enable = true;             # 过滤模式

        env = { EDITOR = "cat"; LANG = "C.UTF-8"; };
      });
  };
}
```

完整选项：见 `modules/{app,packages,env,mounts,workspace,network,experimental}.nix`。

要包装其他程序：复用 `templates/opencode.nix` 或 `templates/ironclaw.nix` 当作模板修改即可。

## Ironclaw 专用说明

每个版本独立 flake input + 独立持久化目录。

**持久化路径**（首次启动自动初始化 postgres + pgvector，在沙箱内 unix socket 上跑）：
- 最新版：`~/.cache/ocsb/ironclaw/<workspace>/`
- 老版本：`~/.cache/ocsb/ironclaw_v0_XX_X/<workspace>/`

覆盖：`OCSB_IRONCLAW_PERSIST_DIR=/path` 或 `--persist-dir /path`。

**沙箱内 nix**：`OCSB_IRONCLAW_NIX_MODE=` 选 `single-user`（默认，纯用户态）/ `isolated-store`（overlay 在 closure store 上）/ `portable`（stub，需自行加 nix-portable input）。

**升级到新 release**（保留最近 3 个版本）：
1. 在 `flake.nix` 把当前 `ironclaw-src` 改名为 `ironclaw-src-v0_XX_X`
2. 删掉最老的 `ironclaw-src-v0_YY_Y`
3. 新 `ironclaw-src.url = "github:nearai/ironclaw/ironclaw-vX.Y.Z"`
4. 改 `ironclawVersions` 列表
5. `nix flake update ironclaw-src` + `nix flake check --no-build`
6. 如新版引入新 git deps，按 nix 报的 hash 加进 `pkgs/ironclaw.nix` 的 `allOutputHashes`

## 二进制缓存（cachix）

我们的 CI 把构建产物 push 到 `https://hugefiver.cachix.org`，命中即秒拉，避免本机花一小时编 ironclaw。

**临时启用（单条命令）**：
```bash
nix build github:hugefiver/ocsb \
  --extra-substituters https://hugefiver.cachix.org \
  --extra-trusted-public-keys hugefiver.cachix.org-1:vFt540rDhQBn5n+NYG0OkBtae/Rj/Gk12DXUmBDeOM0=
```

**用户级（个人 nix）**，在 `~/.config/nix/nix.conf` 加：
```
extra-substituters = https://hugefiver.cachix.org
extra-trusted-public-keys = hugefiver.cachix.org-1:vFt540rDhQBn5n+NYG0OkBtae/Rj/Gk12DXUmBDeOM0=
```
要求当前用户在系统 `nix.settings.trusted-users` 里，否则 nix 会忽略 substituter。

**NixOS 系统级**：
```nix
nix.settings.extra-substituters = [ "https://hugefiver.cachix.org" ];
nix.settings.extra-trusted-public-keys = [
  "hugefiver.cachix.org-1:vFt540rDhQBn5n+NYG0OkBtae/Rj/Gk12DXUmBDeOM0="
];
```
`nixos-rebuild switch` 后立即生效，所有用户共享。

**一键工具**：`nix shell nixpkgs#cachix -c cachix use hugefiver`

## 测试

```bash
nix build .#packages.x86_64-linux.default
bash tests/test_wrapper.sh ./result/bin/ocsb
bash tests/test_binpath.sh .
bash tests/test_git_worktree.sh ./result/bin/ocsb
bash tests/test_btrfs.sh ./result/bin/ocsb     # 无权限自动 SKIP

nix build .#checks.x86_64-linux.net-test
nix build .#checks.x86_64-linux.dual-layer-test

nix build .#ironclaw-sandbox
bash tests/test_ironclaw.sh ./result/bin/ocsb-ironclaw
```

## License

[MIT](LICENSE)

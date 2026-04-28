# ocsb

基于 [bubblewrap](https://github.com/containers/bubblewrap) 的 Nix 沙箱框架。原生支持 [OpenCode](https://github.com/opencode-ai/opencode) 与 [Ironclaw](https://github.com/nearai/ironclaw)，也可用同样的模型沙箱化任意可执行文件。

特性：可写 chroot `/nix/store`、可选宿主 nix-daemon、closure-only `/nix/store`、可切换的网络隔离（host / 过滤 / 无网）、CoW workspace（overlayfs/btrfs/git-worktree/direct）、非 root 身份、capability 全 drop、声明式 Nix 模块。

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
| `overlayfs` | 用户 workspace overlay，upper/work 在 state dir 的 `overlay/workspace/` 下；适合用户拥有的项目文件 |
| `btrfs` | btrfs subvol snapshot；需 `user_subvol_rm_allowed` |
| `git-worktree` | detached worktree；需 git 仓库 |
| `direct` | 直接 bind 项目目录（无隔离） |

## State 布局

ocsb 的 workspace marker 仍在项目内的 `.ocsb/<workspace>/`，但 chroot/overlay/snapshot 等实现状态默认放在项目外：`~/.cache/ocsb/<project-hash>/<workspace>/`。可以用绝对路径环境变量 `OCSB_STATE_BASE_DIR=/path/to/state` 覆盖 state base；沙箱内会导出 `OCSB_STATE_DIR` 指向最终 workspace state 目录。

典型目录：

```text
$OCSB_STATE_DIR/
├── chroot/
│   ├── .source
│   └── merged/nix/{store,var/nix}/   # bind 到沙箱内 /nix
├── overlay/
│   ├── workspace/{upper,work}/       # workspace overlayfs
│   └── mounts/ovl-*/{upper,work}/    # --overlay-mount
└── snapshots/snap-*/                 # --snap-mount btrfs snapshot
```

`OCSB_STATE_BASE_DIR` 必须是绝对路径；相对路径会被拒绝，避免不同启动目录意外生成多份 state。`--overwrite` 会清理当前 workspace 的 chroot、overlay、snapshots，并兼容清理旧版根级 `upper/work`、`ovl-*`、`snap-*` 布局。手动清理旧 cache 时优先删具体旧 hash/workspace 目录；大型 chroot store 内含只读 Nix store 文件，清理脚本只 chmod 目录，不应对整棵 store 做递归 chmod。

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
- 最新版：`~/.cache/ocsb/ironclaw/`
- 老版本：`~/.cache/ocsb/ironclaw_v0_XX_X/`

Ironclaw 的 ocsb state 固定在 `$PERSIST_DIR/state/ironclaw/`，不再跟随启动目录生成 `~/.cache/ocsb/<project-hash>/ironclaw`。其中 `chroot/merged` 是 bind 到沙箱内 `/nix` 的合并后 chroot store；`overlay/` 只存 overlayfs 的 upper/work 等实现细节，不直接暴露进沙箱。

覆盖：`OCSB_IRONCLAW_PERSIST_DIR=/path` 或 `--persist-dir /path`。

**网络**：Ironclaw 默认共享宿主网络（`network.enable = null`）。原因是它的 postgres 初始化必须以非 root uid 运行，而当前 filtered/slirp4netns 模式需要沙盒内 uid 0 才能让宿主侧 slirp helper 进入网络 namespace。后续如果实现 multi-uid user namespace 映射，再恢复 filtered 网络隔离。

**沙箱内 nix**：默认 `nixStoreMode = "chroot"` —— 首次启动先尝试用 hard link 预填充闭包并注册 chroot store DB；如果 `/nix/store` 与 workspace 不在同一 filesystem、权限阻止硬链接，或 DB 注册失败，则自动 fallback 到 `nix copy`。最终 `$OCSB_STATE_DIR/chroot/merged/nix/store` 会 bind-mount 进沙箱，可在沙箱内 `nix profile add nixpkgs#foo`（cache.nixos.org 可用）。可改 `experimental.nixStoreMode = "host-daemon"`（只读绑定宿主 `/nix/store`，写入走宿主 nix-daemon socket，需要宿主 daemon 权限策略收紧）或 `"closure"`（只挂闭包 RO，最小面）。`/nix/store` 不再使用 overlayfs：宿主 store 是 root-owned lower，unprivileged user namespace 下 copy-up 会遇到 ownership/permission 问题；workspace 的 `overlayfs` 策略不受影响。

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

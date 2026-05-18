{ pkgs, lib }:
# Hermes Agent Nix 配置模块
# 可独立于 ocsb 复用 — 生成 init 脚本和 config.yaml。
# 用法：hermesInit = pkgs.callPackage ./lib/hermes-config.nix { ... }
{
  # Hermes 沙箱内工作目录，默认 /home/sandbox（sandbox 内 HOME 路径）
  messagingCwd ? "/home/sandbox",
  # 额外的 config.yaml 内容（追加到基础配置后）
  extraConfig ? "",
  # 是否预创建 Hermes 工作目录（cron/sessions/logs/memories/plugins）
  createDirs ? true,
}:

let
  inherit (lib) optionalString;

  configYaml = pkgs.writeText "hermes-config.yaml" ''
    messaging:
      cwd: ${messagingCwd}
    ${optionalString (extraConfig != "") extraConfig}
  '';
in
pkgs.writeShellScript "hermes-init" ''
  set -euo pipefail

  : ''${HERMES_HOME:?HERMES_HOME must be set}

  ${optionalString createDirs ''
    mkdir -p \
      "$HERMES_HOME/cron" \
      "$HERMES_HOME/sessions" \
      "$HERMES_HOME/logs" \
      "$HERMES_HOME/memories" \
      "$HERMES_HOME/plugins"
  ''}

  if [[ ! -f "$HERMES_HOME/config.yaml" ]]; then
    cp ${configYaml} "$HERMES_HOME/config.yaml"
  fi
''
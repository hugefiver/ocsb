#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DSSB_DIR="$REPO_ROOT/dssb"
PACKAGE_JSON="$DSSB_DIR/package.json"
PACKAGE_LOCK="$DSSB_DIR/package-lock.json"
PACKAGE_NIX="$DSSB_DIR/package.nix"
WRAPPER_NIX="$DSSB_DIR/wrapper.nix"
FLAKE_NIX="$REPO_ROOT/flake.nix"
WORKFLOW="$REPO_ROOT/.github/workflows/ci.yml"
README="$REPO_ROOT/README.md"
DSSB_README="$DSSB_DIR/README.md"
TEST_TMP=""

usage() {
  echo "Usage: $0 --source-only | --build-sandbox-fixture <empty-output-dir> | --build-lightweight-wrapper <empty-output-dir> | --case flake-outputs | --case module-eval | --case module-bubblewrap <fake-sandbox-binary> | --case wrapper-contract <fake-wrapper> | --case wrapper-safety <fake-wrapper> | --case real-wrapper <official-wrapper> | --case backend-boundaries <fake-sandbox-binary> | --case docker-bubblewrap <fake-sandbox-binary>" >&2
}

fail() {
  printf 'test_dssb: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  [[ -n "${TEST_TMP:-}" && "$TEST_TMP" == /tmp/dssb-source.* && -d "$TEST_TMP" ]] || return 0
  find "$TEST_TMP" -type d -exec chmod u+w {} + 2>/dev/null || true
  rm -rf -- "$TEST_TMP"
  [[ ! -e "$TEST_TMP" && ! -L "$TEST_TMP" ]] || {
    printf 'test_dssb: fail-closed cleanup left %s\n' "$TEST_TMP" >&2
    return 1
  }
}

make_test_tmp() {
  [[ -z "$TEST_TMP" ]] || return 0
  TEST_TMP="$(mktemp -d /tmp/dssb-source.XXXXXX)"
  [[ "$TEST_TMP" == /tmp/dssb-source.* && -d "$TEST_TMP" ]] || \
    fail "refusing unexpected temporary path: $TEST_TMP"
}
trap cleanup EXIT

require_file() {
  [[ -f "$1" ]] || fail "required source file is missing: $1"
}

assert_nul_argv() {
  local argv_file="$1"
  local item
  local -a actual=()
  local -a expected=("${@:2}")

  [[ -f "$argv_file" ]] || fail "missing NUL argv log: $argv_file"
  while IFS= read -r -d '' item; do
    actual+=("$item")
  done < "$argv_file"

  [[ "${#actual[@]}" -eq "${#expected[@]}" ]] || {
    printf 'test_dssb: argv count differs; expected %s got %s\n' "${#expected[@]}" "${#actual[@]}" >&2
    printf 'expected:' >&2
    printf ' <%s>' "${expected[@]}" >&2
    printf '\nactual:' >&2
    printf ' <%s>' "${actual[@]}" >&2
    printf '\n' >&2
    return 1
  }

  local index
  for ((index = 0; index < ${#expected[@]}; index++)); do
    [[ "${actual[$index]}" == "${expected[$index]}" ]] || {
      printf 'test_dssb: argv item %s differs; expected <%s> got <%s>\n' \
        "$index" "${expected[$index]}" "${actual[$index]}" >&2
      return 1
    }
  done
}

assert_file_line() {
  local file="$1"
  local expected="$2"
  grep -Fxq -- "$expected" "$file" || fail "missing line in $file: $expected"
}

capture_failure() {
  local output_file="$1"
  shift

  set +e
  "$@" >"$output_file" 2>&1
  CAPTURE_STATUS=$?
  set -e
  if [[ "$CAPTURE_STATUS" -eq 0 ]]; then
    fail "expected failure succeeded: $*"
  fi
}

require_package_source() {
  local pattern="$1"
  grep -Eq -- "$pattern" "$PACKAGE_NIX" || fail "package.nix is missing source contract: $pattern"
}

reject_package_source() {
  local pattern="$1"
  if grep -Eq -- "$pattern" "$PACKAGE_NIX"; then
    fail "package.nix violates source contract: $pattern"
  fi
}

require_flake_source() {
  local pattern="$1"
  grep -Eq -- "$pattern" "$FLAKE_NIX" || fail "flake.nix is missing source contract: $pattern"
}

require_literal() {
  local file="$1"
  local literal="$2"

  grep -Fq -- "$literal" "$file" || fail "missing required literal in $file: $literal"
}

reject_flake_source() {
  local pattern="$1"
  if grep -Eq -- "$pattern" "$FLAKE_NIX"; then
    fail "flake.nix violates source contract: $pattern"
  fi
}

verify_lock_metadata() {
  nix shell --inputs-from "$REPO_ROOT" nixpkgs#nodejs_22 -c node - \
    "$PACKAGE_JSON" "$PACKAGE_LOCK" <<'NODE'
import { readFileSync } from "node:fs";

const [manifestPath, lockPath] = process.argv.slice(2);
const manifest = JSON.parse(readFileSync(manifestPath, "utf8"));
const lock = JSON.parse(readFileSync(lockPath, "utf8"));
const expectedVersion = "0.1.1-rc.2";
const expectedIntegrity = "sha512-UP1UIh6q3Gme/yXRn/QL2P8IsVlv8Shpg22TRJIZPsCRWLm4CBiA1MUvXmJAfsOEETBMLAl+xWPtFw6ICsN3wg==";
const expectedNodeEngine = "^22.19.0 || >=24.0.0";

const assert = (condition, message) => {
  if (!condition) throw new Error(message);
};

assert(manifest.private === true, "package.json must be private");
assert(manifest.engines?.node === expectedNodeEngine, "package.json Node engine changed");
assert(manifest.dependencies?.["@deepseek-ai/dsh"] === expectedVersion, "package.json DSH dependency changed");
assert(lock.lockfileVersion === 3, "package-lock.json must use lockfileVersion 3");

const root = lock.packages?.[""];
const dsh = lock.packages?.["node_modules/@deepseek-ai/dsh"];
const subprocessLocal = lock.packages?.["node_modules/@deepseek-ai/dsh-subprocess-local"];
const nodePty = lock.packages?.["node_modules/node-pty"];

assert(root?.dependencies?.["@deepseek-ai/dsh"] === expectedVersion, "lock root DSH dependency changed");
assert(root?.engines?.node === expectedNodeEngine, "lock root Node engine changed");
assert(dsh?.version === expectedVersion, "DSH lock version changed");
assert(dsh?.integrity === expectedIntegrity, "DSH lock integrity changed");
assert(dsh?.bin?.dsh === "lib/bin.js", "DSH lock entrypoint changed");
assert(subprocessLocal?.hasInstallScript === true, "dsh-subprocess-local install hook is absent");
assert(nodePty?.version === "1.2.0-beta.15", "node-pty lock entry is absent or changed");
NODE
}

verify_package_source() {
  local expected_hash actual_hash drv_path
  local -a hashes

  require_package_source 'buildNpmPackage'
  require_package_source 'lib\.fileset\.toSource'
  require_package_source 'root[[:space:]]*=[[:space:]]*\./\.;'
  require_package_source 'fileset[[:space:]]*=[[:space:]]*lib\.fileset\.unions'
  require_package_source '\./package\.json'
  require_package_source '\./package-lock\.json'
  require_package_source 'nodejs[[:space:]]*=[[:space:]]*nodejs_22;'
  require_package_source 'dontNpmBuild[[:space:]]*=[[:space:]]*true;'
  require_package_source 'postConfigure[[:space:]]*='
  require_package_source 'import \* as nodePty from "node-pty";'
  require_package_source 'nodePty\.spawn\(process\.execPath'
  require_package_source 'DSSB_NODE_PTY_CHILD_OK'
  require_package_source 'DSSB_NODE_PTY_NATIVE_OK'
  require_package_source 'process\.stdout\.write\("DSSB_NODE_PTY_NATIVE_OK\\n"\)'
  require_package_source '\.dssb-node-pty-native-smoke'
  require_package_source 'printf.*DSSB_NODE_PTY_NATIVE_OK.*\.dssb-node-pty-native-smoke'
  require_package_source 'test "\$\(cat \.dssb-node-pty-native-smoke\)" = "DSSB_NODE_PTY_NATIVE_OK"'
  require_package_source 'makeWrapper'
  require_package_source 'makeWrapper[[:space:]]+.*"\$out/bin/dsh"'
  require_package_source '@deepseek-ai/dsh/lib/bin\.js'
  require_package_source 'nix-support/dssb-node-pty-native-smoke'

  reject_package_source '(^|[^[:alnum:]_])npx([^[:alnum:]_]|$)'
  reject_package_source '--ignore-scripts'
  reject_package_source 'npm_config_ignore_scripts'
  reject_package_source '^[[:space:]]*src[[:space:]]*=[[:space:]]*\./\.;'
  reject_package_source '^[[:space:]]*configurePhase[[:space:]]*='
  reject_package_source '(^|[[:space:];])npm[[:space:]]+(install|ci|rebuild)([[:space:]]|$)'

  mapfile -t hashes < <(sed -nE 's/^[[:space:]]*npmDepsHash[[:space:]]*=[[:space:]]*"([^"]+)";[[:space:]]*$/\1/p' "$PACKAGE_NIX")
  [[ "${#hashes[@]}" -eq 1 && "${hashes[0]}" =~ ^sha256-[A-Za-z0-9+/]+={0,2}$ ]] || \
    fail "package.nix must contain one literal SRI npmDepsHash"
  expected_hash="${hashes[0]}"

  actual_hash="$(nix shell --inputs-from "$REPO_ROOT" nixpkgs#prefetch-npm-deps -c \
    prefetch-npm-deps "$PACKAGE_LOCK")"
  [[ "$actual_hash" == "$expected_hash" ]] || \
    fail "npmDepsHash differs from the locked prefetch result"

  make_test_tmp
  cat > "$TEST_TMP/eval-dssb.nix" <<'NIX'
let
  repo = builtins.getEnv "OCSB_TEST_REPO_ROOT";
  repoPath = builtins.toPath repo;
  flake = builtins.getFlake ("path:" + repo);
  pkgs = import flake.inputs.nixpkgs { system = builtins.currentSystem; };
in
  (pkgs.callPackage (repoPath + "/dssb/package.nix") { }).drvPath
NIX
  drv_path="$(OCSB_TEST_REPO_ROOT="$REPO_ROOT" nix eval --raw --impure \
    --file "$TEST_TMP/eval-dssb.nix")"
  [[ "$drv_path" == *.drv ]] || fail "package derivation did not evaluate to a drvPath"
}

verify_flake_outputs_source() {
  require_file "$FLAKE_NIX"
  require_flake_source 'nixModules\.dssb[[:space:]]*=[[:space:]]*import[[:space:]]+\./dssb/module\.nix;'
  require_flake_source 'dssbProject[[:space:]]*=[[:space:]]*import[[:space:]]+\./dssb[[:space:]]*\{'
  require_flake_source 'dssbModule[[:space:]]*=[[:space:]]*self\.nixModules\.dssb;'
  require_flake_source 'dsh[[:space:]]*=[[:space:]]*dssbProject\.package;'
  require_flake_source 'dssb[[:space:]]*=[[:space:]]*dssbProject\.wrapper;'
  require_flake_source 'fakeDsh[[:space:]]*=[[:space:]]*pkgs\.writeShellScriptBin[[:space:]]+"dsh"'
  require_flake_source 'fakeDssbProject[[:space:]]*=[[:space:]]*import[[:space:]]+\./dssb[[:space:]]*\{'
  require_flake_source 'dshPackage[[:space:]]*=[[:space:]]*fakeDsh;'
  require_flake_source 'dssb-module-test[[:space:]]*=[[:space:]]*fakeDssbProject\.sandboxBase;'
  reject_flake_source 'dssb-module-test[[:space:]]*=[[:space:]]*self\.packages'
}

verify_documentation_and_ci_source() {
  require_file "$README"
  require_file "$DSSB_README"
  require_file "$WORKFLOW"

  for required in \
    'nix run github:hugefiver/ocsb#dssb' \
    'nix run github:hugefiver/ocsb#dsh' \
    '<app.binPath 所在目录>:/usr/bin:/home/sandbox/.nix-profile/bin:/nix/var/nix/profiles/default/bin' \
    'programs.rg = {' \
    'dssb --profile headless' \
    'dssb web --no-open' \
    '默认 `packages.dssb` 不提供宿主可访问的 Web UI' \
    'dssb plugin --profile web add' \
    '--env DEEPSEEK_API_KEY' \
    '~/.cache/ocsb/dssb/{home,state}' \
    '0.1.1-rc.2' \
    '不在本地构建官方 `dsh`/`dssb` payload'; do
    require_literal "$README" "$required"
  done

  for required in \
    '没有独立的 `flake.nix` 或 `flake.lock`' \
    '`package-lock.json`' \
    'dssb.package : package' \
    'dssb.extraPrograms : attrsOf { package; binPath; }' \
    'programs.pnpm' \
    'bin/pnpm -> ../libexec/' \
    'dssb.extraPrograms.pnpm' \
    'network.enable = lib.mkForce null;' \
    '不会自动转发端口' \
    'npm install --package-lock-only --ignore-scripts' \
    'npmConfigHook' \
    'postConfigure' \
    '本地不得构建官方 `dsh` 或 `dssb` payload'; do
    require_literal "$DSSB_README" "$required"
  done

  for required in \
    'DSSB source assertions' \
    'DSSB lightweight wrapper fixture' \
    'DSSB fake module bubblewrap fixture' \
    'dssb-build:' \
    '.#packages.x86_64-linux.dsh' \
    '.#packages.x86_64-linux.dssb' \
    '$DSH_OUT/nix-support/dssb-node-pty-native-smoke' \
    'DSSB_NODE_PTY_NATIVE_OK' \
    'bash tests/test_dssb.sh --case real-wrapper "$DSSB_OUT/bin/dssb"'; do
    require_literal "$WORKFLOW" "$required"
  done

  if grep -Eq -- '--profile (acp|sdk)|sdk-minimal' "$README" "$DSSB_README"; then
    fail "DSSB documentation advertises an unshipped profile bundle"
  fi
}

source_only_case() {
  require_file "$PACKAGE_JSON"
  require_file "$PACKAGE_LOCK"
  require_file "$PACKAGE_NIX"
  [[ ! -e "$DSSB_DIR/node_modules" ]] || fail "repository must not contain dssb/node_modules"
  verify_lock_metadata
  verify_package_source
  verify_flake_outputs_source
  verify_documentation_and_ci_source
  echo 'PASS[GREEN-dsh-package-source]: version integrity lock hash hook-lifecycle native-smoke entrypoint offline package contract'
  echo 'PASS[GREEN-dssb-flake-output-source]: module package wrapper and fake-only check contracts'
  echo 'PASS[GREEN-dssb-docs-ci-source]: README, subproject README, and CI literals are current'
}

flake_outputs_case() {
  local dsh_drv dssb_drv module_test_drv recursive_derivations fake_input_result

  make_test_tmp
  cat > "$TEST_TMP/flake-outputs.nix" <<'NIX'
let
  repo = builtins.getEnv "OCSB_TEST_REPO_ROOT";
  flake = builtins.getFlake ("path:" + repo);
  system = builtins.currentSystem;
  packages = flake.packages.${system};
  checks = flake.checks.${system};
in
assert builtins.isFunction flake.nixModules.dssb;
assert packages ? dsh;
assert packages ? dssb;
assert checks ? "dssb-module-test";
if builtins.getEnv "OCSB_DSSB_FLAKE_OUTPUT" == "dsh" then
  packages.dsh.drvPath
else if builtins.getEnv "OCSB_DSSB_FLAKE_OUTPUT" == "dssb" then
  packages.dssb.drvPath
else if builtins.getEnv "OCSB_DSSB_FLAKE_OUTPUT" == "dssb-module-test" then
  checks."dssb-module-test".drvPath
else
  throw "unknown OCSB_DSSB_FLAKE_OUTPUT"
NIX

  dsh_drv="$(OCSB_TEST_REPO_ROOT="$REPO_ROOT" OCSB_DSSB_FLAKE_OUTPUT=dsh \
    nix eval --raw --impure --file "$TEST_TMP/flake-outputs.nix")" || return 1
  dssb_drv="$(OCSB_TEST_REPO_ROOT="$REPO_ROOT" OCSB_DSSB_FLAKE_OUTPUT=dssb \
    nix eval --raw --impure --file "$TEST_TMP/flake-outputs.nix")" || return 1
  module_test_drv="$(OCSB_TEST_REPO_ROOT="$REPO_ROOT" OCSB_DSSB_FLAKE_OUTPUT=dssb-module-test \
    nix eval --raw --impure --file "$TEST_TMP/flake-outputs.nix")" || return 1
  [[ "$dsh_drv" == *.drv && "$dssb_drv" == *.drv && "$module_test_drv" == *.drv ]] || \
    fail "flake output derivation paths are malformed"

  recursive_derivations="$(nix derivation show --recursive "$module_test_drv")" || return 1
  printf '%s' "$recursive_derivations" > "$TEST_TMP/dssb-module-test-derivations.json"
  cat > "$TEST_TMP/assert-fake-dsh-input.nix" <<'NIX'
let
  shown = builtins.fromJSON (builtins.readFile ./dssb-module-test-derivations.json);
  derivations = if shown ? derivations then shown.derivations else shown;
  inputDrvs = builtins.concatLists (builtins.map
    (drv: let derivation = derivations.${drv}; in
      if derivation ? inputDrvs then
        builtins.attrNames derivation.inputDrvs
      else
        builtins.attrNames derivation.inputs.drvs)
    (builtins.attrNames derivations));
in
if builtins.any (inputDrv: builtins.match ".*-dsh\\.drv$" inputDrv != null) inputDrvs then
  "fake dsh"
else
  throw "dssb-module-test derivation input closure does not contain fake dsh"
NIX
  fake_input_result="$(nix eval --raw --impure --file "$TEST_TMP/assert-fake-dsh-input.nix")" || return 1
  [[ "$fake_input_result" == "fake dsh" ]] || fail "fake dsh input assertion returned: $fake_input_result"

  if printf '%s' "$recursive_derivations" | grep -Fq -- 'dsh-0.1.1-rc.2'; then
    fail "dssb-module-test derivation closure contains official dsh-0.1.1-rc.2"
  fi

  echo 'PASS[GREEN-dssb-flake-outputs]: module dsh dssb fake check'
}

module_eval_case() {
  local result bad_output bad_rc conflict_output conflict_rc

  make_test_tmp
  cat > "$TEST_TMP/module-eval.nix" <<'NIX'
let
  repo = builtins.getEnv "OCSB_TEST_REPO_ROOT";
  repoPath = builtins.toPath repo;
  flake = builtins.getFlake ("path:" + repo);
  pkgs = import flake.inputs.nixpkgs { system = builtins.currentSystem; };
  lib = pkgs.lib;
  mkSandbox = import (repoPath + "/lib/mkSandbox.nix") { inherit pkgs lib; };
  moduleResult = lib.evalModules {
    modules = [
      (repoPath + "/modules")
      (repoPath + "/dssb/module.nix")
    ];
    specialArgs = { inherit pkgs; };
  };
  extraProgramsResult = lib.evalModules {
    modules = [
      (repoPath + "/modules")
      (repoPath + "/dssb/module.nix")
      {
        dssb.extraPrograms.dssb-peer = {
          package = pkgs.hello;
          binPath = "bin/hello";
        };
      }
    ];
    specialArgs = { inherit pkgs; };
  };
  entry = import (repoPath + "/dssb/default.nix") {
    inherit pkgs mkSandbox;
    dshPackage = pkgs.hello;
  };
  cfg = moduleResult.config;
  pnpmMajorMinor = lib.versions.majorMinor pkgs.pnpm.version;
in
assert lib.types.package.check cfg.dssb.package;
assert lib.types.package.check extraProgramsResult.config.dssb.extraPrograms.dssb-peer.package;
assert extraProgramsResult.config.programs.dssb-peer.binPath == "bin/hello";
assert cfg.app.name == "dssb";
assert cfg.app.binPath == "bin/dsh";
assert cfg.workspace.strategy == "auto";
assert cfg.workspace.baseDir == ".ocsb";
assert cfg.workspace.name == "dssb";
assert cfg.workspace.sandboxDir == "/workspace";
assert cfg.network.enable;
assert cfg.env.DSH_HOME == "/home/sandbox/.dsh";
assert cfg.env.DSH_PERMISSION_MODE == "danger-full-access";
assert cfg.env.DSH_TELEMETRY_DISABLED == "1";
assert builtins.attrNames cfg.env == [ "DSH_HOME" "DSH_PERMISSION_MODE" "DSH_TELEMETRY_DISABLED" ];
assert cfg.programs.pnpm.package == pkgs.pnpm;
assert cfg.programs.pnpm.binPath == "bin/pnpm";
assert builtins.all (package: builtins.elem package cfg.packages) [
  pkgs.coreutils pkgs.findutils pkgs.gnugrep pkgs.gnused pkgs.gawk pkgs.git
  pkgs.curl pkgs.ripgrep pkgs.fd pkgs.jq pkgs.which
];
assert !(builtins.elem pkgs.pnpm cfg.packages);
assert pnpmMajorMinor == "11.15";
assert entry.package == pkgs.hello;
assert entry ? sandboxBase;
assert entry ? wrapper;
assert entry.sandboxBase.drvPath != "";
"pnpm=${pnpmMajorMinor}"
NIX

  cat > "$TEST_TMP/module-eval-invalid-extra-program.nix" <<'NIX'
let
  repo = builtins.getEnv "OCSB_TEST_REPO_ROOT";
  repoPath = builtins.toPath repo;
  flake = builtins.getFlake ("path:" + repo);
  pkgs = import flake.inputs.nixpkgs { system = builtins.currentSystem; };
  lib = pkgs.lib;
  evaluated = lib.evalModules {
    modules = [
      (repoPath + "/modules")
      (repoPath + "/dssb/module.nix")
      {
        dssb.extraPrograms."bad/name" = {
          package = pkgs.hello;
          binPath = "bin/hello";
        };
      }
    ];
    specialArgs = { inherit pkgs; };
  };
in
builtins.deepSeq evaluated.config.dssb.extraPrograms "unexpected success"
NIX

  cat > "$TEST_TMP/module-eval-extra-program-conflict.nix" <<'NIX'
let
  repo = builtins.getEnv "OCSB_TEST_REPO_ROOT";
  repoPath = builtins.toPath repo;
  flake = builtins.getFlake ("path:" + repo);
  pkgs = import flake.inputs.nixpkgs { system = builtins.currentSystem; };
  lib = pkgs.lib;
  evaluated = lib.evalModules {
    modules = [
      (repoPath + "/modules")
      (repoPath + "/dssb/module.nix")
      {
        dssb.extraPrograms.pnpm = {
          package = pkgs.hello;
          binPath = "bin/hello";
        };
      }
    ];
    specialArgs = { inherit pkgs; };
  };
in
builtins.deepSeq evaluated.config.programs "unexpected success"
NIX

  result="$(OCSB_TEST_REPO_ROOT="$REPO_ROOT" nix eval --raw --impure --file "$TEST_TMP/module-eval.nix")" || return 1
  [[ "$result" == "pnpm=11.15" ]] || fail "unexpected declarative pnpm version: $result"
  set +e
  bad_output="$(OCSB_TEST_REPO_ROOT="$REPO_ROOT" nix eval --raw --impure --file "$TEST_TMP/module-eval-invalid-extra-program.nix" 2>&1)"
  bad_rc=$?
  set -e
  [[ "$bad_rc" -ne 0 && "$bad_output" == *"dssb.extraPrograms command names"* ]] || {
    printf 'test_dssb: invalid dssb.extraPrograms command did not fail closed\n%s\n' "$bad_output" >&2
    return 1
  }
  set +e
  conflict_output="$(OCSB_TEST_REPO_ROOT="$REPO_ROOT" nix eval --raw --impure --file "$TEST_TMP/module-eval-extra-program-conflict.nix" 2>&1)"
  conflict_rc=$?
  set -e
  [[ "$conflict_rc" -ne 0 && "$conflict_output" == *"programs.pnpm.package"* ]] || {
    printf 'test_dssb: dssb.extraPrograms.pnpm did not conflict with programs.pnpm\n%s\n' "$conflict_output" >&2
    return 1
  }
  echo 'PASS[GREEN-dssb-module-eval]: defaults package type extraPrograms type pnpm=11.15'
  echo 'PASS[GREEN-dssb-module-invalid-extra-program]: dssb.extraPrograms command names fail closed'
  echo 'PASS[GREEN-dssb-module-extra-program-conflict]: dssb.extraPrograms.pnpm leaf conflict fails closed'
}

build_sandbox_fixture() {
  local fixture_dir="$1"
  local fixture_expr fixture_output fixture_store

  [[ -n "$fixture_dir" ]] || fail "fixture directory is required"
  if [[ -e "$fixture_dir" || -L "$fixture_dir" ]]; then
    [[ -d "$fixture_dir" && ! -L "$fixture_dir" ]] || fail "fixture directory must be a real directory: $fixture_dir"
    [[ -z "$(find "$fixture_dir" -mindepth 1 -maxdepth 1 -print -quit)" ]] || \
      fail "fixture directory must be empty: $fixture_dir"
  else
    install -d -m 0700 "$fixture_dir"
  fi

  fixture_expr="$fixture_dir/dssb-sandbox-fixture.nix"
  cat > "$fixture_expr" <<'NIX'
let
  repo = builtins.getEnv "OCSB_TEST_REPO_ROOT";
  repoPath = builtins.toPath repo;
  flake = builtins.getFlake ("path:" + repo);
  pkgs = import flake.inputs.nixpkgs { system = builtins.currentSystem; };
  lib = pkgs.lib;
  mkSandbox = import (repoPath + "/lib/mkSandbox.nix") { inherit pkgs lib; };
  fakeDsh = pkgs.writeShellScriptBin "dsh" ''
    set -euo pipefail

    printf 'DSH_HOME=%s\n' "''${DSH_HOME:?}"
    printf 'DSH_PERMISSION_MODE=%s\n' "''${DSH_PERMISSION_MODE:?}"
    printf 'DSH_TELEMETRY_DISABLED=%s\n' "''${DSH_TELEMETRY_DISABLED:?}"
    for argument in "$@"; do
      printf 'DSH_ARGV=%s\n' "$argument"
    done

    if ! pnpm_path="$(command -v pnpm)"; then
      printf 'pnpm is unavailable on PATH: %s\n' "$PATH" >&2
      exit 64
    fi
    [[ "$pnpm_path" == "/usr/bin/pnpm" ]] || {
      printf 'pnpm must resolve through declarative named program at /usr/bin/pnpm: %s\n' "$pnpm_path" >&2
      exit 65
    }
    printf 'PNPM_DECLARATIVE_OK=%s\n' "$pnpm_path"
    dssb-peer module-probe
  '';
  fakePeer = pkgs.writeShellScriptBin "dssb-peer" ''
    set -euo pipefail
    [[ "$#" -eq 1 && "$1" == "module-probe" ]] || {
      printf 'unexpected dssb-peer argv:' >&2
      printf ' %q' "$@" >&2
      printf '\n' >&2
      exit 66
    }
    printf 'DSSB_PEER_OK:%s\n' "$1"
  '';
in
mkSandbox {
  imports = [ (repoPath + "/dssb/module.nix") ];
  dssb.package = fakeDsh;
  dssb.extraPrograms.dssb-peer = {
    package = fakePeer;
    binPath = "bin/dssb-peer";
  };
  workspace.strategy = lib.mkForce "direct";
  experimental.nixStoreMode = "closure";
}
NIX

  fixture_output="$(OCSB_TEST_REPO_ROOT="$REPO_ROOT" nix build --no-link --print-out-paths --impure --file "$fixture_expr")" || return 1
  fixture_store="$(printf '%s\n' "$fixture_output" | awk '/^\/nix\/store\/[0-9a-z]{32}-[^[:space:]]+$/ { path = $0 } END { print path }')"
  [[ -n "$fixture_store" ]] || {
    printf 'test_dssb: fixture build did not print a store path\n%s\n' "$fixture_output" >&2
    return 1
  }
  while IFS= read -r fixture_line; do
    [[ "$fixture_line" == "$fixture_store" ]] || printf '%s\n' "$fixture_line" >&2
  done <<< "$fixture_output"
  [[ -x "$fixture_store/bin/dssb" ]] || fail "sandbox fixture did not produce dssb"
  ln -s "$fixture_store/bin/dssb" "$fixture_dir/dssb"
  : > "$fixture_dir/.dssb-sandbox-fixture"
  chmod 0600 "$fixture_dir/.dssb-sandbox-fixture"
  printf '%s\n' "$fixture_dir/dssb"
}

build_lightweight_wrapper() {
  local fixture_dir="$1"
  local fixture_expr fixture_output fixture_store

  [[ -n "$fixture_dir" ]] || fail "fixture directory is required"
  if [[ -e "$fixture_dir" || -L "$fixture_dir" ]]; then
    [[ -d "$fixture_dir" && ! -L "$fixture_dir" ]] || fail "fixture directory must be a real directory: $fixture_dir"
    [[ -z "$(find "$fixture_dir" -mindepth 1 -maxdepth 1 -print -quit)" ]] || \
      fail "fixture directory must be empty: $fixture_dir"
  else
    install -d -m 0700 "$fixture_dir"
  fi

  fixture_expr="$fixture_dir/dssb-wrapper-fixture.nix"
  cat > "$fixture_expr" <<'NIX'
let
  repo = builtins.getEnv "OCSB_TEST_REPO_ROOT";
  repoPath = builtins.toPath repo;
  flake = builtins.getFlake ("path:" + repo);
  pkgs = import flake.inputs.nixpkgs { system = builtins.currentSystem; };
  fakeInner = pkgs.writeShellScriptBin "dssb" ''
    set -euo pipefail

    : "''${DSSB_FAKE_LOG:?}"
    {
      printf 'PWD=%s\n' "$PWD"
      printf 'OCSB_STATE_BASE_DIR=%s\n' "''${OCSB_STATE_BASE_DIR:-}"
      printf 'OCSB_EXEC_OVERRIDE=%s\n' "''${OCSB_EXEC_OVERRIDE:-}"
    } > "$DSSB_FAKE_LOG/env"
    printf '%s\0' "$@" > "$DSSB_FAKE_LOG/argv.nul"
    exit "''${DSSB_FAKE_EXIT_CODE:-0}"
  '';
in
  pkgs.callPackage (repoPath + "/dssb/wrapper.nix") {
    dssbSandboxBase = fakeInner;
  }
NIX

  fixture_output="$(OCSB_TEST_REPO_ROOT="$REPO_ROOT" nix build --no-link --print-out-paths --impure --file "$fixture_expr")" || return 1
  fixture_store="$(printf '%s\n' "$fixture_output" | awk '/^\/nix\/store\/[0-9a-z]{32}-[^[:space:]]+$/ { path = $0 } END { print path }')"
  [[ -n "$fixture_store" ]] || {
    printf 'test_dssb: lightweight wrapper fixture build did not print a store path\n%s\n' "$fixture_output" >&2
    return 1
  }
  while IFS= read -r fixture_line; do
    [[ "$fixture_line" == "$fixture_store" ]] || printf '%s\n' "$fixture_line" >&2
  done <<< "$fixture_output"
  [[ -x "$fixture_store/bin/dssb" ]] || fail "lightweight wrapper fixture did not produce dssb"
  ln -s "$fixture_store/bin/dssb" "$fixture_dir/dssb"
  : > "$fixture_dir/.dssb-lightweight-wrapper"
  chmod 0600 "$fixture_dir/.dssb-lightweight-wrapper"
  printf '%s\n' "$fixture_dir/dssb"
}

module_bubblewrap_case() {
  local sandbox="$1"
  local project state_base runtime_dir stdout stderr

  [[ -x "$sandbox" ]] || fail "fake sandbox binary is not executable: $sandbox"
  make_test_tmp
  project="$TEST_TMP/module-project"
  state_base="$TEST_TMP/module-state"
  runtime_dir="$TEST_TMP/module-runtime"
  stdout="$TEST_TMP/module.stdout"
  stderr="$TEST_TMP/module.stderr"
  mkdir -p "$project" "$state_base"
  install -d -m 0700 "$runtime_dir"

  (
    cd "$project"
    XDG_RUNTIME_DIR="$runtime_dir" OCSB_STATE_BASE_DIR="$state_base" \
      "$sandbox" --overwrite -- module-probe 'value with spaces' >"$stdout" 2>"$stderr"
  ) || {
    cat "$stdout" "$stderr" >&2
    return 1
  }

  grep -Fxq 'DSH_HOME=/home/sandbox/.dsh' "$stdout"
  grep -Fxq 'DSH_PERMISSION_MODE=danger-full-access' "$stdout"
  grep -Fxq 'DSH_TELEMETRY_DISABLED=1' "$stdout"
  grep -Fxq 'DSH_ARGV=module-probe' "$stdout"
  grep -Fxq 'DSH_ARGV=value with spaces' "$stdout"
  grep -Fxq 'PNPM_DECLARATIVE_OK=/usr/bin/pnpm' "$stdout"
  grep -Fxq 'DSSB_PEER_OK:module-probe' "$stdout"
  cat "$stdout"
  echo 'PASS[GREEN-dssb-module-bubblewrap]: fake DSH env argv pnpm and extra program'
}

wrapper_contract_case() {
  local wrapper="$1"
  local caller persist log_first log_existing log_continue log_overwrite log_exit exit_rc

  [[ -x "$wrapper" ]] || fail "fake wrapper is not executable: $wrapper"
  make_test_tmp
  caller="$TEST_TMP/wrapper-caller"
  persist="$TEST_TMP/wrapper-persist"
  log_first="$TEST_TMP/wrapper-log-first"
  log_existing="$TEST_TMP/wrapper-log-existing"
  log_continue="$TEST_TMP/wrapper-log-continue"
  log_overwrite="$TEST_TMP/wrapper-log-overwrite"
  log_exit="$TEST_TMP/wrapper-log-exit"
  install -d -m 0700 "$caller" "$log_first" "$log_existing" "$log_continue" "$log_overwrite" "$log_exit"

  (
    cd "$caller"
    DSSB_FAKE_LOG="$log_first" "$wrapper" --persist-dir "$persist" --strategy direct \
      --profile headless 'task with spaces'
  )

  assert_file_line "$log_first/env" "PWD=$caller"
  assert_file_line "$log_first/env" "OCSB_STATE_BASE_DIR=$persist/state"
  assert_file_line "$log_first/env" 'OCSB_EXEC_OVERRIDE='
  assert_nul_argv "$log_first/argv.nul" \
    --rw "$persist/home:/home/sandbox" --strategy direct -- \
    --profile headless 'task with spaces'
  echo 'PASS[GREEN-dssb-wrapper-cwd]: caller cwd preserved'

  [[ "$(stat -c %a -- "$persist")" == 700 ]] || fail "persist directory is not mode 0700"
  [[ "$(stat -c %a -- "$persist/home")" == 700 ]] || fail "persistent home is not mode 0700"
  [[ "$(stat -c %a -- "$persist/state")" == 700 ]] || fail "persistent state is not mode 0700"
  echo 'PASS[GREEN-dssb-wrapper-layout]: private home and state'

  install -d -m 0700 "$persist/state/dssb"
  DSSB_FAKE_LOG="$log_existing" "$wrapper" --persist-dir "$persist" -- --existing-probe
  assert_nul_argv "$log_existing/argv.nul" \
    --rw "$persist/home:/home/sandbox" --continue -- --existing-probe

  DSSB_FAKE_LOG="$log_continue" "$wrapper" --persist-dir "$persist" --continue -- --continue-probe
  assert_nul_argv "$log_continue/argv.nul" \
    --rw "$persist/home:/home/sandbox" --continue -- --continue-probe

  DSSB_FAKE_LOG="$log_overwrite" "$wrapper" --persist-dir "$persist" --overwrite -- --overwrite-probe
  assert_nul_argv "$log_overwrite/argv.nul" \
    --rw "$persist/home:/home/sandbox" --overwrite -- --overwrite-probe
  echo 'PASS[GREEN-dssb-wrapper-argv]: control and DSH arrays preserved'
  echo 'PASS[GREEN-dssb-wrapper-action]: first run fresh existing run continue explicit action unique'

  set +e
  (
    cd "$caller"
    DSSB_FAKE_LOG="$log_exit" DSSB_FAKE_EXIT_CODE=37 "$wrapper" --persist-dir "$persist" -- --exit-probe
  )
  exit_rc=$?
  set -e
  [[ "$exit_rc" -eq 37 ]] || fail "wrapper did not propagate fake inner exit 37: $exit_rc"
  echo 'PASS[GREEN-dssb-wrapper-exit]: inner exit 37 propagated'
}

wrapper_safety_case() {
  local wrapper="$1"
  local caller output persist_target symlink_path file_path mode_path home_path state_path
  local workspace output_secret persist_secret log_secret persist_explicit log_explicit secret

  [[ -x "$wrapper" ]] || fail "fake wrapper is not executable: $wrapper"
  [[ "${DEEPSEEK_API_KEY:-}" == "fixture-secret" ]] || \
    fail "wrapper-safety requires DEEPSEEK_API_KEY=fixture-secret"
  make_test_tmp
  caller="$TEST_TMP/wrapper-safety-caller"
  install -d -m 0700 "$caller"

  output="$TEST_TMP/relative-cli.out"
  capture_failure "$output" "$wrapper" --persist-dir relative-cli -- --profile headless
  grep -Fq 'persist directory must be absolute' "$output" || fail "relative CLI persist error is unclear"
  [[ ! -e "$REPO_ROOT/relative-cli" && ! -L "$REPO_ROOT/relative-cli" ]] || \
    fail "relative CLI persist created a directory before rejection"

  output="$TEST_TMP/relative-env.out"
  capture_failure "$output" env OCSB_DSSB_PERSIST_DIR=relative-env "$wrapper" -- --profile headless
  grep -Fq 'persist directory must be absolute' "$output" || fail "relative env persist error is unclear"
  [[ ! -e "$REPO_ROOT/relative-env" && ! -L "$REPO_ROOT/relative-env" ]] || \
    fail "relative env persist created a directory before rejection"

  persist_target="$TEST_TMP/safe-persist-target"
  symlink_path="$TEST_TMP/persist-symlink"
  install -d -m 0700 "$persist_target"
  ln -s "$persist_target" "$symlink_path"
  output="$TEST_TMP/persist-symlink.out"
  capture_failure "$output" "$wrapper" --persist-dir "$symlink_path" -- --profile headless
  grep -Fq 'unsafe persistent path is not a real directory' "$output" || fail "persist symlink was not rejected"

  file_path="$TEST_TMP/persist-file"
  : > "$file_path"
  output="$TEST_TMP/persist-file.out"
  capture_failure "$output" "$wrapper" --persist-dir "$file_path" -- --profile headless
  grep -Fq 'unsafe persistent path is not a real directory' "$output" || fail "persist non-directory was not rejected"

  mode_path="$TEST_TMP/persist-mode"
  install -d -m 0755 "$mode_path"
  output="$TEST_TMP/persist-mode.out"
  capture_failure "$output" "$wrapper" --persist-dir "$mode_path" -- --profile headless
  grep -Fq 'current-UID mode 0700' "$output" || fail "persist mode was not rejected"
  [[ "$(stat -c %a -- "$mode_path")" == 755 ]] || fail "wrapper changed an unsafe persist mode"

  if [[ "$(id -u)" -eq 0 ]]; then
    local owner_path="$TEST_TMP/persist-owner"
    install -d -m 0700 "$owner_path"
    chown 65534:65534 "$owner_path"
    output="$TEST_TMP/persist-owner.out"
    capture_failure "$output" "$wrapper" --persist-dir "$owner_path" -- --profile headless
    grep -Fq 'current-UID mode 0700' "$output" || fail "foreign-owned persist directory was not rejected"
  fi

  home_path="$TEST_TMP/persist-home-symlink"
  install -d -m 0700 "$home_path" "$TEST_TMP/home-target"
  ln -s "$TEST_TMP/home-target" "$home_path/home"
  output="$TEST_TMP/home-symlink.out"
  capture_failure "$output" "$wrapper" --persist-dir "$home_path" -- --profile headless
  grep -Fq 'unsafe persistent path is not a real directory' "$output" || fail "persistent home symlink was not rejected"

  state_path="$TEST_TMP/persist-state-file"
  install -d -m 0700 "$state_path"
  : > "$state_path/state"
  output="$TEST_TMP/state-file.out"
  capture_failure "$output" "$wrapper" --persist-dir "$state_path" -- --profile headless
  grep -Fq 'unsafe persistent path is not a real directory' "$output" || fail "persistent state non-directory was not rejected"

  for workspace in '' '-leading' 'has/slash' 'has..dots'; do
    output="$TEST_TMP/workspace-${#workspace}.out"
    capture_failure "$output" "$wrapper" --persist-dir "$TEST_TMP/workspace-persist-${#workspace}" \
      --workspace "$workspace" -- --profile headless
    grep -Fq 'workspace name cannot' "$output" || fail "unsafe workspace was not rejected: $workspace"
  done

  output="$TEST_TMP/shell-args.out"
  capture_failure "$output" "$wrapper" --persist-dir "$TEST_TMP/shell-persist" --shell -- --profile headless
  [[ "$CAPTURE_STATUS" -eq 2 ]] || fail "shell with DSH args must exit 2, got $CAPTURE_STATUS"
  grep -Fq -- '--shell cannot be combined with DSH arguments' "$output" || fail "shell argument rejection is unclear"

  persist_secret="$TEST_TMP/persist-secret"
  log_secret="$TEST_TMP/log-secret"
  install -d -m 0700 "$log_secret"
  (
    cd "$caller"
    DSSB_FAKE_LOG="$log_secret" "$wrapper" --persist-dir "$persist_secret" -- --profile headless
  )
  assert_nul_argv "$log_secret/argv.nul" \
    --rw "$persist_secret/home:/home/sandbox" -- --profile headless

  persist_explicit="$TEST_TMP/persist-explicit-secret"
  log_explicit="$TEST_TMP/log-explicit-secret"
  install -d -m 0700 "$log_explicit"
  DSSB_FAKE_LOG="$log_explicit" "$wrapper" --persist-dir "$persist_explicit" \
    --env DEEPSEEK_API_KEY -- --profile headless
  assert_nul_argv "$log_explicit/argv.nul" \
    --rw "$persist_explicit/home:/home/sandbox" --env DEEPSEEK_API_KEY -- --profile headless

  secret="$DEEPSEEK_API_KEY"
  if grep -R --binary-files=text -F -- "$secret" \
      "$log_secret" "$persist_secret" "$log_explicit" "$persist_explicit" "$WRAPPER_NIX" >/dev/null; then
    fail "wrapper leaked the host DEEPSEEK_API_KEY into argv, persistence, or source"
  fi

  echo 'PASS[GREEN-dssb-wrapper-safety]: relative unsafe object secret and shell boundaries'
}

is_real_bwrap_capability_denial() {
  grep -Eq \
    'Creating new namespace failed: Operation not permitted|No permissions to create new namespace|RTM_NEWADDR.*Operation not permitted|setting up uid map: Permission denied|mount anchoring unavailable.*(Operation not permitted|Permission denied)' \
    <<<"$1"
}

real_wrapper_case() {
  local wrapper help_output caller persist runtime_output runtime_rc

  wrapper="$1"
  [[ -x "$wrapper" ]] || fail "official wrapper is not executable: $wrapper"
  make_test_tmp
  caller="$TEST_TMP/real-wrapper-caller"
  persist="$TEST_TMP/real-wrapper-persist"
  install -d -m 0700 "$caller"

  set +e
  help_output="$("$wrapper" --help 2>&1)"
  runtime_rc=$?
  set -e
  if [[ "$runtime_rc" -ne 0 ]]; then
    printf '%s\n' "$help_output" >&2
    return "$runtime_rc"
  fi

  set +e
  runtime_output="$(
    cd "$caller"
    "$wrapper" --persist-dir "$persist" --strategy direct --overwrite -- --help 2>&1
  )"
  runtime_rc=$?
  set -e
  printf '%s\n' "$runtime_output"
  if [[ "$runtime_rc" -ne 0 ]]; then
    if is_real_bwrap_capability_denial "$runtime_output"; then
      echo 'SKIP[CI-REQUIRED-dssb-real-bwrap]: userns or RTM_NEWADDR unavailable'
      return 0
    fi
    return "$runtime_rc"
  fi

  echo 'PASS[GREEN-dssb-real-wrapper]: official dsh --help exits through bubblewrap'
}

backend_boundaries_case() {
  local sandbox="$1"
  local project state output nspawn_rc podman_rc

  [[ -x "$sandbox" ]] || fail "fake sandbox binary is not executable: $sandbox"
  make_test_tmp
  project="$TEST_TMP/backend-project"
  state="$TEST_TMP/backend-state"
  install -d -m 0700 "$project" "$state"

  set +e
  output="$(
    cd "$project"
    OCSB_STATE_BASE_DIR="$state" "$sandbox" --backend systemd-nspawn --strategy direct --overwrite \
      -- --profile headless nspawn-probe 2>&1
  )"
  nspawn_rc=$?
  set -e
  [[ "$nspawn_rc" -ne 0 ]] || fail "systemd-nspawn filtered network unexpectedly succeeded"
  [[ "$output" == *'supports only host or blocked networking in v1'* ]] || {
    printf 'test_dssb: nspawn rejection did not happen before backend execution\n%s\n' "$output" >&2
    return 1
  }
  echo 'PASS[GREEN-dssb-nspawn-filtered-rejection]: filtered network rejected before host nspawn lookup'

  if ! command -v podman >/dev/null 2>&1 || ! podman info >/dev/null 2>&1; then
    echo 'SKIP[OPTIONAL-dssb-podman]: podman unavailable'
    return 0
  fi

  output="$(
    cd "$project"
    OCSB_STATE_BASE_DIR="$state" "$sandbox" --backend podman --strategy direct --overwrite \
      -- --profile headless podman-probe 2>&1
  )" || podman_rc=$?
  podman_rc="${podman_rc:-0}"
  [[ "$podman_rc" -eq 0 ]] || {
    printf 'test_dssb: podman runtime failed despite podman info succeeding\n%s\n' "$output" >&2
    return 1
  }
  [[ "$output" == *'DSH_ARGV=--profile'* && "$output" == *'DSH_ARGV=podman-probe'* ]] || {
    printf 'test_dssb: podman fake DSH did not receive its argv\n%s\n' "$output" >&2
    return 1
  }
  echo 'PASS[GREEN-dssb-podman]: fake DSH runs through podman backend'
}

docker_bubblewrap_case() {
  local sandbox="$1"
  local image project state output

  [[ -x "$sandbox" ]] || fail "fake sandbox binary is not executable: $sandbox"
  image="${OCSB_DSSB_DOCKER_IMAGE:-nixos/nix:latest}"
  if ! command -v docker >/dev/null 2>&1 || ! docker image inspect "$image" >/dev/null 2>&1; then
    echo 'SKIP[OPTIONAL-dssb-docker-bubblewrap]: docker or preloaded image unavailable'
    return 0
  fi

  make_test_tmp
  project="$TEST_TMP/docker-project"
  state="$TEST_TMP/docker-state"
  install -d -m 0700 "$project" "$state"
  output="$(docker run --rm --privileged --network host \
    --mount "type=bind,src=/nix/store,dst=/nix/store,readonly" \
    --mount "type=bind,src=$project,dst=$project" \
    --mount "type=bind,src=$state,dst=/dssb-state" \
    --workdir "$project" \
    --env OCSB_STATE_BASE_DIR=/dssb-state \
    --entrypoint "$(readlink -f -- "$sandbox")" \
    "$image" --strategy direct --overwrite -- --profile headless docker-probe 2>&1)" || {
      printf 'test_dssb: docker bubblewrap fixture failed\n%s\n' "$output" >&2
      return 1
    }
  [[ "$output" == *'DSH_ARGV=--profile'* && "$output" == *'DSH_ARGV=docker-probe'* ]] || {
    printf 'test_dssb: docker fake DSH did not receive its argv\n%s\n' "$output" >&2
    return 1
  }
  echo 'PASS[GREEN-dssb-docker-bubblewrap]: preloaded docker image runs fake DSH through bubblewrap'
}

case "${1:-}" in
  --source-only)
    [[ $# -eq 1 ]] || {
      usage
      exit 2
    }
    source_only_case
    ;;
  --build-sandbox-fixture)
    [[ $# -eq 2 ]] || {
      usage
      exit 2
    }
    build_sandbox_fixture "$2"
    ;;
  --build-lightweight-wrapper)
    [[ $# -eq 2 ]] || {
      usage
      exit 2
    }
    build_lightweight_wrapper "$2"
    ;;
  --case)
    [[ $# -ge 2 ]] || {
      usage
      exit 2
    }
    case "$2" in
      flake-outputs)
        [[ $# -eq 2 ]] || {
          usage
          exit 2
        }
        flake_outputs_case
        ;;
      module-eval)
        [[ $# -eq 2 ]] || {
          usage
          exit 2
        }
        module_eval_case
        ;;
      module-bubblewrap)
        [[ $# -eq 3 ]] || {
          usage
          exit 2
        }
        module_bubblewrap_case "$3"
        ;;
      wrapper-contract)
        [[ $# -eq 3 ]] || {
          usage
          exit 2
        }
        wrapper_contract_case "$3"
        ;;
      wrapper-safety)
        [[ $# -eq 3 ]] || {
          usage
          exit 2
        }
        wrapper_safety_case "$3"
        ;;
      real-wrapper)
        [[ $# -eq 3 ]] || {
          usage
          exit 2
        }
        real_wrapper_case "$3"
        ;;
      backend-boundaries)
        [[ $# -eq 3 ]] || {
          usage
          exit 2
        }
        backend_boundaries_case "$3"
        ;;
      docker-bubblewrap)
        [[ $# -eq 3 ]] || {
          usage
          exit 2
        }
        docker_bubblewrap_case "$3"
        ;;
      *)
        echo "test_dssb: unknown focused case: $2" >&2
        exit 2
        ;;
    esac
    ;;
  *)
    usage
    exit 2
    ;;
esac

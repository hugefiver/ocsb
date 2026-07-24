#!/usr/bin/env bash
# Static CI contract for runtime coverage and capability-based results.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
WORKFLOW="$REPO_ROOT/.github/workflows/ci.yml"
FLAKE="$REPO_ROOT/flake.nix"
HERMES_TEST="$SCRIPT_DIR/test_hermes_agent.sh"
IRONCLAW_TEST="$SCRIPT_DIR/test_ironclaw.sh"
MOUNT_TEST="$SCRIPT_DIR/test_mount_anchor.sh"
FILTERED_TEST="$SCRIPT_DIR/test_filtered_cleanup.sh"

FAILURES=0
CORE_RUNTIME_MISSING=0
GITHUB_SKIP_PRESENT=0

fail() {
  printf 'FAIL[ci-runtime-contract]: %s\n' "$1" >&2
  FAILURES=$((FAILURES + 1))
}

require_literal() {
  local file="$1"
  local literal="$2"
  local description="$3"

  if ! grep -Fq -- "$literal" "$file"; then
    fail "$description"
    return 1
  fi
}

require_workflow_runtime() {
  local literal="$1"
  local description="$2"

  if ! grep -Fq -- "$literal" "$WORKFLOW"; then
    CORE_RUNTIME_MISSING=1
    fail "$description"
  fi
}

require_build_runtime() {
  local literal="$1"
  local description="$2"

  if [[ -z "$BUILD_JOB" ]] || ! grep -Fq -- "$literal" <<<"$BUILD_JOB"; then
    CORE_RUNTIME_MISSING=1
    fail "$description"
  fi
}

[[ -r "$WORKFLOW" ]] || {
  echo "FAIL[ci-runtime-contract]: workflow is unreadable: $WORKFLOW" >&2
  exit 1
}

BUILD_JOB="$({
  awk '
    /^  build:/ { capture = 1 }
    capture && /^  [A-Za-z0-9_-]+:/ && $1 != "build:" { exit }
    capture { print }
  ' "$WORKFLOW"
})"

# Core and deterministic suites must be invoked by the ordinary build job.
require_workflow_runtime 'DEFAULT_OUT="$RUNNER_TEMP/ocsb-default"' \
  'default package out-link must be outside the repository'
require_workflow_runtime 'nix build --out-link "$DEFAULT_OUT" .#packages.x86_64-linux.default' \
  'default package must be built to a runner-temp out-link'
require_build_runtime 'Probe real bwrap runtime capability' \
  'ordinary build job must probe real bwrap runtime capability'
require_build_runtime 'BWRAP_RUNTIME_AVAILABLE=0' \
  'ordinary build job must record unavailable bwrap runtime capability'
require_build_runtime 'SKIP[CI-REQUIRED-wrapper-real-bwrap]: user namespace mapping unavailable' \
  'ordinary build job must emit exact wrapper bwrap capability skip marker'
require_workflow_runtime 'bash tests/test_wrapper.sh "$DEFAULT_OUT/bin/ocsb"' \
  'wrapper runtime suite is missing'
require_workflow_runtime 'bash tests/test_backend.sh .' \
  'backend runtime suite is missing'
require_workflow_runtime 'bash tests/test_binpath.sh .' \
  'binpath runtime suite is missing'
require_workflow_runtime 'env -u XDG_RUNTIME_DIR bash tests/test_git_worktree.sh "$DEFAULT_OUT/bin/ocsb"' \
  'git-worktree runtime suite must clear XDG_RUNTIME_DIR'
require_workflow_runtime 'env -u XDG_RUNTIME_DIR bash tests/test_btrfs.sh "$DEFAULT_OUT/bin/ocsb"' \
  'btrfs runtime suite must clear XDG_RUNTIME_DIR'
require_workflow_runtime 'nix build --out-link "$DUAL_OUT" .#checks.x86_64-linux.dual-layer-test' \
  'default dual-layer fixture build is missing'
require_workflow_runtime 'nix build --out-link "$DUAL_HOME_OUT" .#checks.x86_64-linux.dual-layer-home-test' \
  'home dual-layer fixture build is missing'
require_workflow_runtime 'DUAL_OUT="$RUNNER_TEMP/ocsb-dual-default"' \
  'default dual-layer out-link must be outside the repository'
require_workflow_runtime 'DUAL_HOME_OUT="$RUNNER_TEMP/ocsb-dual-home"' \
  'home dual-layer out-link must be outside the repository'
require_workflow_runtime 'env -u XDG_RUNTIME_DIR bash tests/test_dual_layer_host.sh green-env' \
  'dual-layer environment runtime case is missing'
require_workflow_runtime 'env -u XDG_RUNTIME_DIR bash tests/test_dual_layer_host.sh green-sandboxdir' \
  'dual-layer sandboxDir runtime case is missing'
require_workflow_runtime 'env -u XDG_RUNTIME_DIR bash tests/test_mount_anchor.sh --ci-fake' \
  'deterministic mount-anchor suite must run with XDG_RUNTIME_DIR cleared'
require_workflow_runtime 'env -u XDG_RUNTIME_DIR bash tests/test_filtered_cleanup.sh --ci-fake' \
  'deterministic filtered-monitor suite must run with XDG_RUNTIME_DIR cleared'
require_workflow_runtime 'nix build --out-link "$NET_OUT" .#checks.x86_64-linux.net-test' \
  'network fixture build is missing'
require_workflow_runtime 'NET_OUT="$RUNNER_TEMP/ocsb-net-test"' \
  'network fixture out-link must be outside the repository'
require_workflow_runtime 'env -u XDG_RUNTIME_DIR bash tests/test_filtered_cleanup.sh --case real-secondary' \
  'real network/cleanup suite must run with XDG_RUNTIME_DIR cleared'
require_workflow_runtime 'bash tests/test_arch_outputs.sh "$AARCH_JSON" "$X86_JSON"' \
  'architecture output contract is missing'
require_workflow_runtime 'bash tests/test_failure_propagation.sh --prepare' \
  'failure-propagation fixture preparation is missing'
require_workflow_runtime 'env -u XDG_RUNTIME_DIR bash tests/test_failure_propagation.sh --case strategy-create' \
  'failure-propagation runtime case must clear XDG_RUNTIME_DIR'
require_workflow_runtime 'bash tests/test_ci_runtime.sh' \
  'CI runtime contract is not self-invoked'

# Focused regressions must remain explicit in the ordinary build job; the broad
# suites above are not a substitute because they may intentionally select a
# different case set.
for required in \
  'bash tests/test_wrapper.sh "$DEFAULT_OUT/bin/ocsb" --case runtime-pidfile-clobber' \
  'bash tests/test_backend.sh . --case process-record-schema' \
  'bash tests/test_backend.sh . --case container-rootfs-persistence' \
  'bash tests/test_backend.sh . --case generic-daemon-pip'; do
  require_build_runtime "$required" "ordinary build job is missing focused runtime case: $required"
done

# External payloads are built only in their dedicated jobs. Source and fake
# paths must run unconditionally in the ordinary build job.
for required in \
  'bash tests/test_hermes_agent.sh --source-only' \
  'bash tests/test_hermes_agent.sh --build-lightweight-wrapper' \
   'bash tests/test_hermes_agent.sh --build-service-fixture' \
   'bash tests/test_hermes_agent.sh --case gateway-reservation' \
   'bash tests/test_hermes_agent.sh --case gateway-dead-candidate' \
  'bash tests/test_hermes_agent.sh --case replace-identity' \
  'bash tests/test_hermes_agent.sh --case caller-file-secret' \
  'bash tests/test_ironclaw.sh --source-only' \
  'bash tests/test_ironclaw.sh --build-lightweight-wrapper' \
  'bash tests/test_ironclaw.sh --build-key-fixture' \
  'bash tests/test_ironclaw.sh --case sidecar-security' \
  'bash tests/test_ironclaw.sh --case master-key-window'; do
  require_build_runtime "$required" "unconditional external wrapper source/lightweight path is missing: $required"
done

# Real built-wrapper paths stay in their dedicated conditional jobs.
require_workflow_runtime \
  'env -u XDG_RUNTIME_DIR bash tests/test_hermes_agent.sh "$HERMES_OUT/bin/ocsb-hermes"' \
  'dedicated Hermes built-wrapper path is missing'
require_workflow_runtime \
  'env -u XDG_RUNTIME_DIR bash tests/test_ironclaw.sh "$IRONCLAW_OUT/bin/ocsb-ironclaw"' \
  'dedicated Ironclaw built-wrapper path is missing'

# Every workflow Nix build must avoid mutable ./result collisions by using
# explicit out-links. The critical runner-temp variables are checked above for
# runtime paths that feed follow-up commands.
while IFS= read -r build_line; do
  if [[ "$build_line" != *'--out-link'* ]]; then
    fail "workflow nix build lacks --out-link: $build_line"
  fi
done < <(grep -E '^[[:space:]]*[^#]*nix build ' "$WORKFLOW" || true)

# Deterministic fixture entry points must exist and cannot be capability skips.
require_literal "$MOUNT_TEST" '--ci-fake)' 'mount-anchor --ci-fake entry point is missing' || true
require_literal "$FILTERED_TEST" '--ci-fake)' 'filtered-monitor --ci-fake entry point is missing' || true
CI_FAKE_CASE="$(sed -n '/^ci_fake_case()/,/^}/p' "$MOUNT_TEST")"
for required_case in \
  'deterministic_swap_case "$TEMP_FIXTURE" ""' \
   'optional_source_absent_case "$TEMP_FIXTURE"' \
   'nested_symlink_case "$TEMP_FIXTURE"' \
   'workspace_mutation_parent_swap_case "$TEMP_FIXTURE"' \
   'git_mid_command_swap_case "$TEMP_FIXTURE"' \
   'receipt_consume_cas_case "$TEMP_FIXTURE"' \
   'test_evidence_case "$TEMP_FIXTURE"'; do
  if [[ -z "$CI_FAKE_CASE" ]] || ! grep -Fq -- "$required_case" <<<"$CI_FAKE_CASE"; then
    fail "mount-anchor --ci-fake does not execute required case: $required_case"
  fi
done
if [[ -z "$CI_FAKE_CASE" ]] || ! grep -Fq -- 'CI_FAKE_MODE=1' <<<"$CI_FAKE_CASE"; then
  fail 'mount-anchor --ci-fake does not make missing fake-suite capabilities fatal'
fi
DETERMINISTIC_STEP="$({
  awk '
    /- name: Run deterministic runtime suites/ { capture = 1 }
    capture && /- name:/ && $0 !~ /Run deterministic runtime suites/ { exit }
    capture { print }
  ' "$WORKFLOW"
})"
if [[ -z "$DETERMINISTIC_STEP" ]] || \
    grep -Eq '\|\|[[:space:]]+true|continue-on-error:' <<<"$DETERMINISTIC_STEP"; then
  fail 'deterministic runtime suites are missing or contain a skip/fail-soft path'
fi
if [[ -z "$DETERMINISTIC_STEP" ]] || \
    ! grep -Fq 'SKIP[CI-REQUIRED-wrapper-real-bwrap]: user namespace mapping unavailable' <<<"$DETERMINISTIC_STEP"; then
  fail 'deterministic runtime suites must use the exact wrapper bwrap capability skip marker'
fi

# Unconditional GitHub Actions success paths are prohibited.
if grep -Eq 'GITHUB_ACTIONS' "$HERMES_TEST" "$IRONCLAW_TEST"; then
  GITHUB_SKIP_PRESENT=1
  fail 'GITHUB_ACTIONS-based wrapper success skip is present'
fi
require_literal "$HERMES_TEST" \
  'SKIP[CI-REQUIRED-hermes-real-bwrap]: userns or RTM_NEWADDR unavailable' \
  'Hermes real-bwrap capability skip marker is missing' || true
require_literal "$IRONCLAW_TEST" \
  'SKIP[CI-REQUIRED-ironclaw-real-bwrap]: userns or RTM_NEWADDR unavailable' \
  'Ironclaw real-bwrap capability skip marker is missing' || true

# The backend test shell must come from locked nixpkgs and add Podman only as a
# test dependency.
require_literal "$FLAKE" 'backend-test = pkgs.mkShell {' \
  'locked-nixpkgs backend-test dev shell is missing' || true
require_literal "$FLAKE" 'packages = defaultTestTools ++ [ pkgs.podman ];' \
  'backend-test dev shell does not add Podman to the existing test tools' || true
if [[ "$(grep -Fc -- 'pkgs.podman' "$FLAKE")" -ne 1 ]]; then
  fail 'Podman must appear exactly once as a backend-test-only dependency'
fi

PODMAN_JOB="$({
  awk '
    /^  podman-anchor-test:/ { capture = 1 }
    capture && /^  [A-Za-z0-9_-]+:/ && $1 != "podman-anchor-test:" { exit }
    capture { print }
  ' "$WORKFLOW"
})"

PODMAN_SIDECAR_JOB="$({
  awk '
    /^  podman-sidecar-lifecycle-test:/ { capture = 1 }
    capture && /^  [A-Za-z0-9_-]+:/ && $1 != "podman-sidecar-lifecycle-test:" { exit }
    capture { print }
  ' "$WORKFLOW"
})"

DOCKER_SIDECAR_JOB="$({
  awk '
    /^  docker-sidecar-lifecycle-test:/ { capture = 1 }
    capture && /^  [A-Za-z0-9_-]+:/ && $1 != "docker-sidecar-lifecycle-test:" { exit }
    capture { print }
  ' "$WORKFLOW"
})"

if [[ -z "$PODMAN_JOB" ]]; then
  fail 'required podman-anchor-test job is missing'
else
  for required in \
    'runs-on: ubuntu-latest' \
    'needs: build' \
    'actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5' \
    'DeterminateSystems/nix-installer-action@00199f951aeb9404028a6e4b95ad42546f73296a' \
    "nix develop .#backend-test -c bash -c '" \
    'PODMAN_BIN=$(command -v podman)' \
    'case "$PODMAN_BIN" in /nix/store/*/bin/podman)' \
    'PODMAN_ROOTLESS=$(podman --remote=false info --format "{{.Host.Security.Rootless}}" 2>&1)' \
    'printf "PODMAN_ROOTLESS=%s\n" "$PODMAN_ROOTLESS" | tee -a "$LOG"' \
    'HOST_UID=$(id -u)' \
    'LOG="$RUNNER_TEMP/14-real-podman-green.log"' \
    'printf "PODMAN_BIN=%s\n" "$PODMAN_BIN" | tee "$LOG"' \
    'OUT="$RUNNER_TEMP/ocsb-podman-anchor"' \
    'nix build --out-link "$OUT" .#packages.x86_64-linux.default' \
    'env -u XDG_RUNTIME_DIR bash tests/test_mount_anchor.sh' \
    '--case real-rootless-podman "$OUT/bin/ocsb"' \
    'grep -Fq "PASS[GREEN-real-rootless-podman-anchor]: uid=$HOST_UID source=original"' \
    '"$LOG"'; do
    if ! grep -Fq -- "$required" <<<"$PODMAN_JOB"; then
      fail "podman-anchor-test is missing: $required"
    fi
  done

  if grep -Eq 'bash -l(c|[[:space:]])|continue-on-error:|\|\|[[:space:]]+true|SKIP\[|sudo[[:space:]]|apt(-get)?[[:space:]]|dnf[[:space:]]|yum[[:space:]]|apk[[:space:]]|brew[[:space:]]|pip(x|3)?[[:space:]]+install|setup-podman|install[[:space:]]+podman|CONTAINER_HOST|PODMAN_HOST|--remote[[:space:]]|--remote=true' \
      <<<"$PODMAN_JOB"; then
    fail 'podman-anchor-test contains a prohibited fail-soft, login, host-install, skip, or remote-Podman path'
  fi
  if grep -Eq '\$\{\{[^}]*[Uu][Ii][Dd][^}]*\}\}' <<<"$PODMAN_JOB"; then
    fail 'podman-anchor-test substitutes a UID through a GitHub expression'
  fi
fi

if [[ -z "$PODMAN_SIDECAR_JOB" ]]; then
  fail 'required podman-sidecar-lifecycle-test job is missing'
else
  for required in \
    'runs-on: ubuntu-latest' \
    'needs: build' \
    'actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5' \
    'DeterminateSystems/nix-installer-action@00199f951aeb9404028a6e4b95ad42546f73296a' \
    "nix develop .#backend-test -c bash -c '" \
    'PODMAN_BIN=$(command -v podman)' \
    'case "$PODMAN_BIN" in /nix/store/*/bin/podman)' \
    'podman --remote=false pull "$IMAGE"' \
    'PINNED_IMAGE_RUNTIME=podman' \
    'PINNED_IMAGE_REQUEST=$IMAGE' \
    'PINNED_IMAGE_ID=$IMAGE_ID' \
    'PINNED_IMAGE_REPODIGESTS=$REPODIGESTS' \
    'bash tests/test_ironclaw.sh --build-lightweight-wrapper "$RUNNER_TEMP/native-podman-wrapper"' \
    'OCSB_NATIVE_PODMAN_REQUIRED=1 bash tests/test_ironclaw.sh --case native-sidecar-lifecycle podman "$WRAPPER"' \
    'PASS[GREEN-sidecar-native-podman-lifecycle]: pull-provenance create-exit-inspect-stop-once-restart-inspect-running-reuse-same-id no-second-stop prepare-decision-ack bare-entrypoint-argv-env' \
    'CLEANUP PASS: native podman sidecar container processes persist cidfiles fifos outlinks mounts removed' \
    'actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02' \
    'name: final-review-podman-sidecar-${{ github.run_id }}-${{ github.run_attempt }}' \
    'path: ${{ runner.temp }}/19-native-podman-sidecar-green.log' \
    'if-no-files-found: error'; do
    if ! grep -Fq -- "$required" <<<"$PODMAN_SIDECAR_JOB"; then
      fail "podman-sidecar-lifecycle-test is missing: $required"
    fi
  done
  if grep -Eq 'bash -l(c|[[:space:]])|continue-on-error:|\|\|[[:space:]]+true|SKIP\[|sudo[[:space:]]|apt(-get)?[[:space:]]|dnf[[:space:]]|yum[[:space:]]|apk[[:space:]]|brew[[:space:]]|pip(x|3)?[[:space:]]+install|setup-podman|install[[:space:]]+podman|CONTAINER_HOST|PODMAN_HOST' \
      <<<"$PODMAN_SIDECAR_JOB"; then
    fail 'podman-sidecar-lifecycle-test contains prohibited fail-soft, host-install, skip, or remote environment path'
  fi
fi

if [[ -z "$DOCKER_SIDECAR_JOB" ]]; then
  fail 'required docker-sidecar-lifecycle-test job is missing'
else
  for required in \
    'runs-on: ubuntu-latest' \
    'needs: build' \
    'actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5' \
    'DeterminateSystems/nix-installer-action@00199f951aeb9404028a6e4b95ad42546f73296a' \
    'DOCKER_BIN=$(command -v docker)' \
    'docker pull "$IMAGE"' \
    'PINNED_IMAGE_RUNTIME=docker' \
    'PINNED_IMAGE_REQUEST=$IMAGE' \
    'PINNED_IMAGE_ID=$IMAGE_ID' \
    'PINNED_IMAGE_REPODIGESTS=$REPODIGESTS' \
    'bash tests/test_ironclaw.sh --build-lightweight-wrapper "$RUNNER_TEMP/native-docker-wrapper"' \
    'OCSB_NATIVE_DOCKER_REQUIRED=1 bash tests/test_ironclaw.sh --case native-sidecar-lifecycle docker "$WRAPPER"' \
    'PASS[GREEN-sidecar-native-docker-lifecycle]: pull-provenance create-exit-inspect-stop-once-restart-inspect-running-reuse-same-id no-second-stop prepare-decision-ack bare-entrypoint-argv-env' \
    'CLEANUP PASS: native docker sidecar container processes persist cidfiles fifos outlinks mounts removed' \
    'actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02' \
    'name: final-review-docker-sidecar-${{ github.run_id }}-${{ github.run_attempt }}' \
    'path: ${{ runner.temp }}/19-native-docker-sidecar-green.log' \
    'if-no-files-found: error'; do
    if ! grep -Fq -- "$required" <<<"$DOCKER_SIDECAR_JOB"; then
      fail "docker-sidecar-lifecycle-test is missing: $required"
    fi
  done
  if grep -Eq 'bash -l(c|[[:space:]])|continue-on-error:|\|\|[[:space:]]+true|SKIP\[|sudo[[:space:]]|apt(-get)?[[:space:]]|dnf[[:space:]]|yum[[:space:]]|apk[[:space:]]|brew[[:space:]]|pip(x|3)?[[:space:]]+install|setup-docker|install[[:space:]]+docker|CONTAINER_HOST|DOCKER_HOST' \
      <<<"$DOCKER_SIDECAR_JOB"; then
    fail 'docker-sidecar-lifecycle-test contains prohibited fail-soft, host-install, skip, or remote Docker path'
  fi
fi

for required in \
  '--case native-sidecar-lifecycle' \
  'PASS[GREEN-sidecar-native-podman-lifecycle]: pull-provenance create-exit-inspect-stop-once-restart-inspect-running-reuse-same-id no-second-stop prepare-decision-ack bare-entrypoint-argv-env' \
  'PASS[GREEN-sidecar-native-docker-lifecycle]: pull-provenance create-exit-inspect-stop-once-restart-inspect-running-reuse-same-id no-second-stop prepare-decision-ack bare-entrypoint-argv-env'; do
  require_literal "$IRONCLAW_TEST" "$required" "native sidecar lifecycle harness is missing: $required" || true
done

if ! grep -Fq -- 'path: ${{ runner.temp }}/14-real-podman-green.log' <<<"$PODMAN_JOB"; then
  fail 'podman-anchor-test does not upload its native rootless evidence artifact'
fi

if [[ "$FAILURES" -ne 0 ]]; then
  if [[ "$CORE_RUNTIME_MISSING" -eq 1 && "$GITHUB_SKIP_PRESENT" -eq 1 ]]; then
    echo 'FAIL[RED-ci-runtime-gate]: core runtime commands missing and GITHUB_ACTIONS skip present' >&2
  fi
  if [[ -z "$PODMAN_SIDECAR_JOB" || -z "$DOCKER_SIDECAR_JOB" ]]; then
    echo 'FAIL[RED-final-review-ci-authority]: native sidecar jobs or artifact authority missing' >&2
  fi
  exit 1
fi

echo 'PASS[GREEN-ci-runtime-gate]: all runtime commands present; skips capability-based'
echo 'PASS[GREEN-final-review-ci-authority]: separate native jobs artifact-retention authority-v2 contract present'
echo 'CLEANUP PASS: ci runtime static contract creates no fixtures'

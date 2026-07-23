#!/usr/bin/env bash
# Verify Ironclaw output names match the supported CPU architecture matrix.
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <aarch64-attrs.json> <x86_64-attrs.json>" >&2
  exit 2
fi

AARCH_JSON="$1"
X86_JSON="$2"
RETAINED_VERSION_SLUGS=(v0_29_0 v0_28_2)
FAILURES=0

require_attr_array() {
  local json="$1"

  [[ -r "$json" ]] || {
    echo "FAIL[arch-outputs-input]: unreadable JSON: $json" >&2
    return 1
  }
  perl -MJSON::PP -e '
    local $/;
    my $attrs = eval { decode_json(<>) };
    exit !defined($attrs) || ref($attrs) ne "ARRAY" || grep { ref($_) ne "" } @{$attrs};
  ' < "$json"
}

has_attr() {
  local json="$1"
  local attr="$2"

  perl -MJSON::PP -e '
    local $/;
    my $wanted = shift @ARGV;
    my $attrs = decode_json(<>);
    exit !grep { $_ eq $wanted } @{$attrs};
  ' "$attr" < "$json"
}

has_x86_64_v3_attr() {
  local json="$1"

  perl -MJSON::PP -e '
    local $/;
    my $attrs = decode_json(<>);
    exit !grep { index($_, "_x86_64_v3") >= 0 } @{$attrs};
  ' < "$json"
}

fail() {
  echo "$1" >&2
  FAILURES=$((FAILURES + 1))
}

require_attr_array "$AARCH_JSON"
require_attr_array "$X86_JSON"

if has_x86_64_v3_attr "$AARCH_JSON"; then
  if has_attr "$AARCH_JSON" "ironclaw_x86_64_v3"; then
    fail "FAIL[RED-aarch64-x86-variant]: aarch64 exports ironclaw_x86_64_v3"
  else
    fail "FAIL[arch-outputs-aarch64]: aarch64 exports a versioned _x86_64_v3 Ironclaw attr"
  fi
fi

for json in "$AARCH_JSON" "$X86_JSON"; do
  for attr in ironclaw ironclaw-sandbox; do
    has_attr "$json" "$attr" || fail "FAIL[arch-outputs-baseline]: missing $attr in $json"
  done

  for slug in "${RETAINED_VERSION_SLUGS[@]}"; do
    for attr in "ironclaw_${slug}" "ironclaw-sandbox_${slug}"; do
      has_attr "$json" "$attr" || fail "FAIL[arch-outputs-baseline]: missing $attr in $json"
    done
  done
done

for attr in ironclaw_x86_64_v3 ironclaw-sandbox_x86_64_v3; do
  has_attr "$X86_JSON" "$attr" || fail "FAIL[arch-outputs-x86_64]: missing $attr"
done

for slug in "${RETAINED_VERSION_SLUGS[@]}"; do
  for attr in "ironclaw_${slug}_x86_64_v3" "ironclaw-sandbox_${slug}_x86_64_v3"; do
    has_attr "$X86_JSON" "$attr" || fail "FAIL[arch-outputs-x86_64]: missing $attr"
  done
done

if [[ "$FAILURES" -ne 0 ]]; then
  exit 1
fi

echo "PASS[GREEN-aarch64-x86-variant]: aarch64 baseline-only; x86_64 v3 present"

#!/usr/bin/env bash
# Podplane <https://podplane.dev>
# Copyright The Podplane Authors
# SPDX-License-Identifier: Apache-2.0

# Validate and cache a delivered tunnel configuration without publishing a Pod.
set -euo pipefail
umask 0077
export LC_ALL=C

if [ "$#" != 1 ]; then
  printf 'usage: %s <input-directory>\n' "${0##*/}" >&2
  exit 2
fi

SCRIPT_DIR="${SCRIPT_DIR:-$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)}"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../lib/helpers.sh"

# Persistent, root-only input and mount copies, shared with the renderer.
tunnel_dir="${PODPLANE_ROOT:-}/opt/podplane/tunnel"
# Agent-owned directory containing tunnel.env and its referenced files.
input_dir=$1
[[ "$input_dir" = /* ]] || fatal 'tunnel input directory must be absolute'
[ ! -L "$input_dir" ] || fatal 'unsafe tunnel receive directory'
mkdir -p "$tunnel_dir/generations"
chmod 0700 "$tunnel_dir" "$tunnel_dir/generations"
exec 9>"$tunnel_dir/render.lock"
flock 9
staging_dir=$(mktemp -d "$tunnel_dir/.receive.XXXXXX")
# Stage private input/ and read-only mount copies in files/ as one generation.
staged_generation_dir="$staging_dir/generation"
snapshot_dir="$staged_generation_dir/input"
trap 'rm -rf "$staging_dir"' EXIT
mkdir -p "$snapshot_dir" "$staged_generation_dir/files"

# Agent-owned paths are untrusted; never follow symlinks or source their content.
copy_input() {
  local source_file=$1 destination_file=$2
  if [ ! -f "$source_file" ] || [ -L "$source_file" ]; then
    fatal 'missing or unsafe tunnel input'
  fi
  dd if="$source_file" of="$destination_file" iflag=nofollow,nonblock status=none
}
# Pin the source directory so replacement cannot redirect subsequent reads.
original_working_dir=$PWD
CDPATH='' cd -- "$input_dir"
[ "$(pwd -P)" = "$input_dir" ] || fatal 'tunnel input directory must be normalized and not redirected'
copy_input ./tunnel.env "$snapshot_dir/tunnel.env"
# Reject controls, including NUL which Bash would otherwise silently discard.
cmp -s "$snapshot_dir/tunnel.env" <(tr -d '\000-\011\013-\037\177' <"$snapshot_dir/tunnel.env") ||
  fatal 'invalid control character in tunnel.env'
declare -A settings=()
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in ''|'#'*) continue ;; esac
  [[ "$line" == *=* ]] || fatal 'invalid tunnel.env line'
  key=${line%%=*}
  case "$key" in
    TUNNEL_ENABLED|TUNNEL_IMAGE|TUNNEL_ARGS|TUNNEL_FILES) ;;
    *) fatal 'unknown tunnel.env key' ;;
  esac
  [ -z "${settings[$key]+x}" ] || fatal 'duplicate tunnel.env key'
  settings[$key]=${line#*=}
done <"$snapshot_dir/tunnel.env"
case "${settings[TUNNEL_ENABLED]:-}" in
  true|false) ;;
  *) fatal 'TUNNEL_ENABLED must be true or false' ;;
esac

# Empty values mean empty lists; every nonempty pipe-delimited entry is literal.
for value in "${settings[TUNNEL_ARGS]:-}" "${settings[TUNNEL_FILES]:-}"; do
  case "$value" in
    '|'*|*'|'|*'||'*) fatal 'empty tunnel list entry' ;;
  esac
done
image=${settings[TUNNEL_IMAGE]:-}
if [ "${settings[TUNNEL_ENABLED]}" = true ] || [ -n "$image" ]; then
  [[ "$image" =~ ^([a-zA-Z0-9][a-zA-Z0-9.-]*\.[a-zA-Z0-9.-]+|localhost)(:[0-9]+)?/[a-zA-Z0-9._/-]+(:[a-zA-Z0-9._-]+)?@sha256:[a-f0-9]{64}$ ]] ||
    fatal 'TUNNEL_IMAGE must be fully qualified and SHA-256 pinned'
fi
IFS='|' read -r -a file_mappings <<<"${settings[TUNNEL_FILES]:-}"
declare -A mount_paths=()
for index in "${!file_mappings[@]}"; do
  mapping=${file_mappings[$index]}
  [[ "$mapping" == *:* ]] || fatal 'invalid tunnel file mapping'
  source_file=${mapping%%:*}
  mount_path=${mapping#*:}
  [[ "$source_file" =~ ^tunnel-[a-zA-Z0-9][a-zA-Z0-9._-]*\.(env|json|crt|pub|key)$ ]] ||
    fatal 'invalid received tunnel basename'
  [[ "$mount_path" = /* ]] || fatal 'tunnel mount path must be absolute'
  case "$mount_path/" in
    *'//'*|*'/./'*|*'/../'*) fatal 'tunnel mount path must be normalized' ;;
  esac
  [ -z "${mount_paths[$mount_path]+x}" ] || fatal 'duplicate tunnel mount path'
  mount_paths[$mount_path]=1
  if [ "${settings[TUNNEL_ENABLED]}" = true ]; then
    if [ ! -f "$snapshot_dir/$source_file" ]; then
      copy_input "./$source_file" "$snapshot_dir/$source_file"
    fi
    install -m 0644 "$snapshot_dir/$source_file" "$staged_generation_dir/files/file-$index"
  fi
done
CDPATH='' cd -- "$original_working_dir"

# Only VM-generated, quoted values may be sourced by the renderer.
for key in TUNNEL_ENABLED TUNNEL_IMAGE TUNNEL_ARGS TUNNEL_FILES; do
  printf '%s=%s\n' "$key" "$(quote_env_value "${settings[$key]:-}")"
done >"$snapshot_dir/runtime.env"
# generations/<content-hash>/ groups private input/ and read-only mount copies.
revision=$( (cd "$snapshot_dir"; sha256sum ./*) | sha256sum | awk '{print $1}')
generation_path="generations/$revision"
if [ ! -d "$tunnel_dir/$generation_path" ]; then
  mv "$staged_generation_dir" "$tunnel_dir/$generation_path"
fi
ln -s "$generation_path/input" "$staging_dir/current"
mv -Tf "$staging_dir/current" "$tunnel_dir/current"
# The renderer prunes old generations only after replacing the Pod manifest.
log 'accepted production tunnel input'

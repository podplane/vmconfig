#!/usr/bin/env bash
# Podplane <https://podplane.dev>
# Copyright The Podplane Authors
# SPDX-License-Identifier: Apache-2.0

# Configure the production tunnel Pod from the last accepted input.
set -euo pipefail
umask 0077
export LC_ALL=C

# VM path embedded in the Pod, unaffected by the optional test root.
vm_tunnel_dir=/opt/podplane/tunnel
# Persistent, root-only input and mount copies, accepted by update-tunnel.sh.
tunnel_dir="${PODPLANE_ROOT:-}$vm_tunnel_dir"
mkdir -p "$tunnel_dir"
chmod 0700 "$tunnel_dir"
# Serialize acceptance and rendering, including cleanup of old generations.
exec 9>"$tunnel_dir/render.lock"
flock 9
# Nothing has been accepted yet: there is no tunnel to configure.
if [ ! -e "$tunnel_dir/current" ]; then
  exit 0
fi

SCRIPT_DIR="${SCRIPT_DIR:-$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)}"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../helpers.sh"
# shellcheck source=/dev/null
source "${PODPLANE_ROOT:-}/opt/podplane/etc/user-data.env"
# shellcheck source=/dev/null
source "${PODPLANE_ROOT:-}/opt/podplane/etc/detected.env"
# shellcheck source=/dev/null
source "${PODPLANE_ROOT:-}/opt/podplane/etc/mutable.env"

# Only this VM-generated env file is safe to source, never delivered tunnel.env.
input_dir=$(CDPATH='' cd -- "$tunnel_dir/current" && pwd -P)
# shellcheck source=/dev/null
source "$input_dir/runtime.env"
# generations/<content-hash>/ keeps each Pod's mount copies immutable.
generation_dir=${input_dir%/input}
revision=${generation_dir##*/}
generation_path="generations/$revision"
# Kubelet's static Pod directory, separate from tunnel storage.
manifest_dir="${PODPLANE_ROOT:-}/etc/kubernetes/manifests"
manifest_file="$manifest_dir/podplane-tunnel.json"
mkdir -p "$manifest_dir"
chmod 0700 "$manifest_dir"
staged_manifest_file=
trap '[ -z "$staged_manifest_file" ] || rm -f "$staged_manifest_file"' EXIT

if [ "$TUNNEL_ENABLED" = false ]; then
  rm -f "$manifest_file"
else
  IFS='|' read -r -a args <<<"$TUNNEL_ARGS"
  IFS='|' read -r -a file_mappings <<<"$TUNNEL_FILES"
  image=$TUNNEL_IMAGE
  args_json=
  for arg in "${args[@]}"; do
    args_json+=${args_json:+,}$(json_string "$arg")
  done
  mounts_json=
  volumes_json=
  for index in "${!file_mappings[@]}"; do
    mapping=${file_mappings[$index]}
    mount_path=${mapping#*:}
    volume_name="file-$index"
    mounts_json+=${mounts_json:+,}"{\"name\":\"$volume_name\",\"mountPath\":$(json_string "$mount_path"),\"readOnly\":true}"
    volumes_json+=${volumes_json:+,}"{\"name\":\"$volume_name\",\"hostPath\":{\"path\":\"$vm_tunnel_dir/$generation_path/files/$volume_name\",\"type\":\"File\"}}"
  done
  if [ "${REGISTRY_ENABLED:-true}" = true ] && [ -n "${REGISTRY_HOSTNAME:-}" ]; then
    image="${REGISTRY_HOSTNAME}/mirror/$image"
  fi
  # The format is VM-owned; received values are JSON data, never instructions.
  pod_template=$(cat "$(dirname -- "${BASH_SOURCE[0]}")/../../share/tunnel-pod.json.tpl")
  # Hidden staging files are ignored by kubelet; rename within its filesystem.
  staged_manifest_file=$(mktemp "$manifest_dir/.podplane-tunnel.XXXXXX")
  # shellcheck disable=SC2059
  printf "$pod_template\n" \
    "$(json_string "$image")" "$args_json" "$mounts_json" "$volumes_json" >"$staged_manifest_file"
  if ! cmp -s "$staged_manifest_file" "$manifest_file"; then
    mv -f "$staged_manifest_file" "$manifest_file"
  fi
fi
# Only prune after publication succeeds: the old Pod may still need its files.
for directory in "$tunnel_dir/generations"/*; do
  [ -d "$directory" ] || continue
  if [ "${directory##*/}" != "$revision" ]; then rm -rf "$directory"; fi
done
log 'configured production tunnel Pod'

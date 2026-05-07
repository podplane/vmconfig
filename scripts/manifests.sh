#!/usr/bin/env bash
# Podplane <https://podplane.dev>
# Copyright 2026 Nadrama Pty Ltd
# SPDX-License-Identifier: Apache-2.0
#
# Render the exact manifest JSON staged for a vmconfig package as shell
# metadata consumed by install.sh.

set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: $0 <manifest.json> <manifest.sh>" >&2
  exit 2
fi

manifest="$1"
output="$2"

manifest_sha256=$(shasum -a 256 "$manifest" | awk '{print $1}')

jq -r --arg manifest_sha256 "$manifest_sha256" '
  def shell_quote: @sh;

  .vmconfig as $vm |
  [
    "#!/usr/bin/env bash",
    "# Generated from the package manifest JSON. Do not edit by hand.",
    "VMCONFIG_MANIFEST_JSON_SHA256=\($manifest_sha256)",
    "VMCONFIG_KIND=\($vm.kind | shell_quote)",
    "VMCONFIG_URL=\($vm.dependencies.vmconfig.url // "" | shell_quote)",
    "VMCONFIG_DIGEST=\($vm.dependencies.vmconfig.digest // "" | shell_quote)",
    "",
    "VMCONFIG_DEPENDENCIES_ALL=(",
    ($vm.dependencies | to_entries[] | "  \(([.key, .value.type, (.value.digest // "")] | @tsv) | shell_quote)"),
    ")",
    "",
    "VMCONFIG_DEPENDENCIES_DEB=(",
    ($vm.dependencies | to_entries[] | select(.value.type == "deb") | "  \(.key | shell_quote)"),
    ")",
    "",
    "VMCONFIG_DEPENDENCIES_TAR_GZ=(",
    ($vm.dependencies | to_entries[] | select(.value.type == "tar.gz") | "  \(.key | shell_quote)"),
    ")",
    "",
    "VMCONFIG_DEPENDENCIES_BINARY=(",
    ($vm.dependencies | to_entries[] | select(.value.type == "binary") | "  \(.key | shell_quote)"),
    ")"
  ] | .[]
' "$manifest" > "$output"

chmod 0644 "$output"

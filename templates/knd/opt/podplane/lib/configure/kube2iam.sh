#!/usr/bin/env bash
# Podplane <https://podplane.dev>
# Copyright 2026 Nadrama Pty Ltd
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

# Load helpers
SCRIPT_DIR="${SCRIPT_DIR:-$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)}"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../helpers.sh"

# Load env files
# shellcheck source=/dev/null
source "${PODPLANE_ROOT:-}/opt/podplane/etc/user-data.env"
# shellcheck source=/dev/null
source "${PODPLANE_ROOT:-}/opt/podplane/etc/detected.env"
# shellcheck source=/dev/null
source "${PODPLANE_ROOT:-}/opt/podplane/etc/mutable.env"

# Create kube2iam env file
mkdir -p "${PODPLANE_ROOT:-}/opt/env"
tmp="/opt/env/kube2iam.env.tmp"
cat > "${PODPLANE_ROOT:-}$tmp" <<EOF
AWS_REGION=$(quote_env_value "${PROVIDER_REGION:-}")
INSTANCE_IPV4=$(quote_env_value "${INSTANCE_IPV4:-}")
INSTANCE_ID=$(quote_env_value "${INSTANCE_ID:-}")
EOF
set_file_permissions 0640 root kube2iam "$tmp"
mv "${PODPLANE_ROOT:-}$tmp" "${PODPLANE_ROOT:-}/opt/env/kube2iam.env"
log "wrote /opt/env/kube2iam.env"

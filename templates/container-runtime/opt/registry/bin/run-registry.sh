#!/usr/bin/env bash
# Podplane <https://podplane.dev>
# Copyright The Podplane Authors
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

# log writes a timestamped registry lifecycle message.
log() { printf '[run-registry] %s\tts=%s\n' "$*" "$EPOCHREALTIME"; }

log "starting"
# shellcheck source=/dev/null
source /opt/env/registry.env
log "loaded /opt/env/registry.env"

export REGISTRY_LISTEN REGISTRY_PROVIDER REGISTRY_BUCKET
export REGISTRY_S3_ENDPOINT REGISTRY_S3_PATH_STYLE
export AWS_REGION AWS_USE_DUALSTACK_ENDPOINT
if [ -n "${AWS_PROFILE:-}" ]; then
  export AWS_PROFILE AWS_CONFIG_FILE
  unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
elif [ -n "${AWS_ACCESS_KEY_ID:-}" ]; then
  export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
fi

log "exec registry"
exec /usr/bin/registry

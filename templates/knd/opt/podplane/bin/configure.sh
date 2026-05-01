#!/usr/bin/env bash
# Podplane <https://podplane.dev>
# Copyright 2026 Nadrama Pty Ltd
# SPDX-License-Identifier: Apache-2.0
#
# configure.sh - configure the system on every boot.
#
# Invoked by user-data after install.sh has completed. Required to be
# idempotent and fault-tolerant: re-runs after partial completion (e.g. a
# kernel panic mid-run) must converge to the same end state.
#
# Instance kind is read from /opt/podplane/share/deps-installed.json
#
# Settings/variables can optionally be set via /opt/podplane/user-data.env
#
# TODO: This script is currently incomplete and largely a stub to test builds

set -euo pipefail

DEPS_MANIFEST="/opt/podplane/share/deps.json"
INSTALLED_MANIFEST="/opt/podplane/share/deps-installed.json"
PERMISSIONS_SCRIPT="/opt/podplane/bin/permissions.sh"

# functions ------------------------------------------------------------------

log()   { printf '[configure] %s\n' "$*"; }

fatal() { printf '[configure] FATAL: %s\n' "$*" >&2; exit 1; }

# preflight ------------------------------------------------------------------

# Check current user is root
[ "$(id -u)" = "0" ] || fatal "must be run as root"

# Error if deps manifest exists (installation is not complete)
if [ -f "$DEPS_MANIFEST" ]; then
  fatal "required deps manifest at ${DEPS_MANIFEST} missing."
fi

# Check deps were installed
[ -f "$INSTALLED_MANIFEST" ] || fatal "missing ${INSTALLED_MANIFEST} - has install.sh run?"

# Check required commands/tools are installed
command -v jq >/dev/null 2>&1 || fatal "required tool missing: jq"

# Determine instance kind from installed deps manifest
KIND=$(jq -r '.vmconfig.kind' "$INSTALLED_MANIFEST")
case "$KIND" in
  knd|knc) ;;
  *) fatal "unsupported vmconfig.kind in ${INSTALLED_MANIFEST}: '${KIND}'" ;;
esac

# permissions ----------------------------------------------------------------

if [ -x "$PERMISSIONS_SCRIPT" ]; then
  log "invoking ${PERMISSIONS_SCRIPT} ${KIND}"
  "$PERMISSIONS_SCRIPT" "$KIND"
else
  fatal "missing or non-executable: ${PERMISSIONS_SCRIPT}"
fi

log "configure.sh completed successfully."

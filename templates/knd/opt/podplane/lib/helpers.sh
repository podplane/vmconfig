#!/usr/bin/env bash
# Podplane <https://podplane.dev>
# Copyright The Podplane Authors
# SPDX-License-Identifier: Apache-2.0
#
# Shared helpers for vmconfig scripts.
#
# Set PODPLANE_ROOT to run a component script against a temporary filesystem
# root during tests; production leaves it unset so absolute paths are used.

# log prints a message prefixed with the calling script name.
log() {
  local source_index=$((${#BASH_SOURCE[@]} - 1))
  printf '[%s] %s\n' "$(basename "${BASH_SOURCE[$source_index]:-$0}" .sh)" "$*"
}

# fatal prints an error prefixed with the calling script name and exits.
fatal() {
  local source_index=$((${#BASH_SOURCE[@]} - 1))
  printf '[%s] FATAL: %s\n' "$(basename "${BASH_SOURCE[$source_index]:-$0}" .sh)" "$*" >&2
  exit 1
}

# quote_env_value quotes a value for writing to a shell env file.
quote_env_value() {
  local value="${1:-}"
  value=${value//\'/\'\\\'\'}
  printf "'%s'" "$value"
}

# json_string quotes a value for writing to a JSON file.
json_string() {
  local value="${1:-}"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  value="${value//$'\r'/\\r}"
  value="${value//$'\t'/\\t}"
  printf '"%s"' "$value"
}

# load_vmconfig_kind reads vmconfig.kind from a vmconfig manifest.
load_vmconfig_kind() {
  local manifest="${1:-${PODPLANE_ROOT:-}/opt/podplane/share/vmconfig-installed.json}"
  [ -f "$manifest" ] || fatal "missing ${manifest}"

  VMCONFIG_KIND=$(grep -m1 '"kind"' "$manifest" | sed -E 's/.*"kind"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')
  case "$VMCONFIG_KIND" in
    knd|knc) export VMCONFIG_KIND ;;
    *) fatal "unsupported vmconfig.kind in ${manifest}: '${VMCONFIG_KIND}'" ;;
  esac
}

# require_nonempty fails unless the named variable is set and non-empty.
require_nonempty() { # <var-name>
  local name="$1"
  local value="${!name:-}"
  [ -n "$value" ] || fatal "${name} is required"
}

# restart_service restarts a systemd service and logs the failure without
# exiting the caller. Used when restarting a batch of services where one
# failure should not block the rest of the batch.
restart_service() { # <service-name>
  local service="$1"
  log "restarting ${service}..."
  if ! systemctl restart "$service"; then
    log "failed to restart ${service}; continuing."
  fi
}

# check_tcp_connectivity fails unless a TCP connection can be opened.
check_tcp_connectivity() { # <name> <host:port>
  local name="$1" addr="$2" host port output

  if [[ "$addr" =~ ^\[([^]]+)\]:([0-9]+)$ ]]; then
    host="${BASH_REMATCH[1]}"
    port="${BASH_REMATCH[2]}"
  else
    host="${addr%:*}"
    port="${addr##*:}"
  fi

  if [ -z "$host" ] || [ -z "$port" ] || [ "$host" = "$addr" ] || [[ "$host" = *:* ]]; then
    fatal "${name} must be a host:port address for connectivity checks, got '${addr}'"
  fi

  command -v timeout >/dev/null 2>&1 || fatal "required tool missing: timeout"

  log "checking ${name} connectivity at ${addr}..."
  # shellcheck disable=SC2016 # $1/$2 are expanded inside the child bash process.
  if output=$(timeout 5s bash -c 'cat < /dev/null > "/dev/tcp/$1/$2"' bash "$host" "$port" 2>&1); then
    log "${name} connectivity check succeeded at ${addr}"
  else
    fatal "cannot connect to ${name} at ${addr}: ${output:-connection attempt failed}"
  fi
}

# derive_instance_provider_id derives the cloud provider ID for this VM.
derive_instance_provider_id() {
  cloud_init_query() {
    local value=""
    while [ "$#" -gt 0 ]; do
      value=$(cloud-init query "$1" 2>/dev/null || true)
      if [ -n "$value" ] && [ "$value" != "null" ]; then
        printf '%s\n' "$value"
        return 0
      fi
      shift
    done
    return 1
  }

  case "${PROVIDER_KIND:-}" in
    aws)
      local az id
      az=$(cloud_init_query v1.availability_zone v1.availability-zone) || fatal "cloud-init missing AWS availability zone"
      id=$(cloud_init_query v1.instance_id v1.instance-id) || fatal "cloud-init missing AWS instance ID"
      printf 'aws:///%s/%s\n' "$az" "$id"
      ;;
    google)
      local pid zone id
      pid=$(cloud_init_query v1.project_id v1.project-id) || fatal "cloud-init missing Google project ID"
      zone=$(cloud_init_query v1.zone) || fatal "cloud-init missing Google zone"
      id=$(cloud_init_query v1.instance_id v1.instance-id) || fatal "cloud-init missing Google instance ID"
      printf 'gce://%s/%s/%s\n' "$pid" "$zone" "$id"
      ;;
    *)
      cat "${PODPLANE_ROOT:-}/var/lib/cloud/data/instance-id"
      ;;
  esac
}

# derive_instance_fqdn derives a stable FQDN for a hostname.
derive_instance_fqdn() { # <hostname>
  local hostname="$1"
  local fqdn
  fqdn=$(hostname -f)
  if [ "$hostname" = "$fqdn" ]; then
    local search_domain=""
    search_domain=$(awk '/^search / {print $2; exit}' "${PODPLANE_ROOT:-}/etc/resolv.conf" || true)
    if [ -n "$search_domain" ] && [ "$search_domain" != "." ]; then
      fqdn="${hostname}.${search_domain}"
    fi
  fi
  if [[ "$fqdn" != *"."* ]]; then
    fqdn="${fqdn}.localdomain"
  fi
  printf '%s\n' "$fqdn"
}

# set_file_permissions sets mode and, outside PODPLANE_ROOT tests, owner/group.
set_file_permissions() { # <mode> <user> <group> <path>
  local mode="$1" user="$2" group="$3" path="${PODPLANE_ROOT:-}$4"
  chmod "$mode" "$path"
  if [ -z "${PODPLANE_ROOT:-}" ]; then
    chown "$user":"$group" "$path"
  fi
}

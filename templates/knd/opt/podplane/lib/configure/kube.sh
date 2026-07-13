#!/usr/bin/env bash
# Podplane <https://podplane.dev>
# Copyright The Podplane Authors
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
case "$VMCONFIG_KIND" in
  knd|knc) ;;
  *) fatal "VMCONFIG_KIND must be one of: knd, knc" ;;
esac

# Set vars
KUBE_CLUSTER_CIDR="${KUBE_CLUSTER_CIDR:-100.64.0.0/10,fd64::/48}"
KUBE_NODE_CIDR_MASK_SIZE_IPV4="${KUBE_NODE_CIDR_MASK_SIZE_IPV4:-24}"
KUBE_NODE_CIDR_MASK_SIZE_IPV6="${KUBE_NODE_CIDR_MASK_SIZE_IPV6:-64}"
for name in KUBE_NODE_CIDR_MASK_SIZE_IPV4 KUBE_NODE_CIDR_MASK_SIZE_IPV6; do
  case "${!name}" in
    ''|*[!0-9]*) fatal "$name must be numeric" ;;
  esac
done
KUBE_SERVICE_CLUSTER_IP_RANGE="${KUBE_SERVICE_CLUSTER_IP_RANGE:-198.18.0.0/15,fdc6::/108}"
KUBE_CLUSTER_DNS="${KUBE_CLUSTER_DNS:-198.19.255.254,fdc6::ffff}"
IFS=, read -r -a kube_cluster_dns <<< "$KUBE_CLUSTER_DNS"
[ "${#kube_cluster_dns[@]}" -gt 0 ] || fatal "KUBE_CLUSTER_DNS must be a comma-separated IP list"
for address in "${kube_cluster_dns[@]}"; do
  if [[ "$address" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    IFS=. read -r -a octets <<< "$address"
    for octet in "${octets[@]}"; do
      ((10#$octet <= 255)) || fatal "KUBE_CLUSTER_DNS must be a comma-separated IP list"
    done
  elif [[ "$address" =~ ^[0-9A-Fa-f:]+$ && "$address" == *:* && "$address" != ":" && "$address" != *:::* ]]; then
    :
  else
    fatal "KUBE_CLUSTER_DNS must be a comma-separated IP list"
  fi
done
OIDC_SIGNING_ALGS="${OIDC_SIGNING_ALGS:-RS256}"
OIDC_CA_FILE=""
if [ -n "${OIDC_CA_CERT:-}" ]; then
  OIDC_CA_FILE="/opt/crt/oidc-ca.pem"
  mkdir -p "${PODPLANE_ROOT:-}/opt/crt"
  printf '%s' "$OIDC_CA_CERT" | base64 -d > "${PODPLANE_ROOT:-}$OIDC_CA_FILE"
  set_file_permissions 0640 root podplane "$OIDC_CA_FILE"
fi

# Keep kubelet DNS aligned with the configured service networks.
cluster_dns_yaml=""
for address in "${kube_cluster_dns[@]}"; do
  [ -z "$cluster_dns_yaml" ] || cluster_dns_yaml+=", "
  cluster_dns_yaml+="\"$address\""
done
sed -E -i "s#^clusterDNS:.*#clusterDNS: [$cluster_dns_yaml]#" "${PODPLANE_ROOT:-}/opt/kubelet/etc/kubelet.yaml"

# Create kubelet env file
mkdir -p "${PODPLANE_ROOT:-}/opt/env"
tmp="/opt/env/kubelet.env.tmp"
cat > "${PODPLANE_ROOT:-}$tmp" <<EOF
PROVIDER_INSTANCE_TYPE=$(quote_env_value "${PROVIDER_INSTANCE_TYPE:-}")
PROVIDER_REGION=$(quote_env_value "${PROVIDER_REGION:-}")
PROVIDER_ZONE=$(quote_env_value "${PROVIDER_ZONE:-}")
INSTANCE_IPV4=$(quote_env_value "${INSTANCE_IPV4:-}")
INSTANCE_IPV6=$(quote_env_value "${INSTANCE_IPV6:-}")
INSTANCE_ID=$(quote_env_value "${INSTANCE_ID:-}")
INSTANCE_PROVIDER_ID=$(quote_env_value "${INSTANCE_PROVIDER_ID:-}")
EOF
set_file_permissions 0600 root root "$tmp"
mv "${PODPLANE_ROOT:-}$tmp" "${PODPLANE_ROOT:-}/opt/env/kubelet.env"
log "wrote /opt/env/kubelet.env"

# Create kube-apiserver env file (for control plane nodes only)
if [ "$VMCONFIG_KIND" = "knc" ]; then
  tmp="/opt/env/kube-apiserver.env.tmp"
  cat > "${PODPLANE_ROOT:-}$tmp" <<EOF
KUBE_LOG_LEVEL=$(quote_env_value "${KUBE_LOG_LEVEL:-2}")
KUBE_API_PUBLIC_HOSTNAME=$(quote_env_value "${KUBE_API_PUBLIC_HOSTNAME:-}")
KUBE_SERVICE_ACCOUNT_ISSUER=$(quote_env_value "${KUBE_SERVICE_ACCOUNT_ISSUER:-}")
KUBE_API_ETCD_SERVERS=$(quote_env_value "${KUBE_API_ETCD_SERVERS:-}")
KUBE_SERVICE_CLUSTER_IP_RANGE=$(quote_env_value "$KUBE_SERVICE_CLUSTER_IP_RANGE")
OIDC_ISSUER=$(quote_env_value "${OIDC_ISSUER:-}")
OIDC_SIGNING_ALGS=$(quote_env_value "$OIDC_SIGNING_ALGS")
CLUSTER_ID=$(quote_env_value "${CLUSTER_ID:-}")
OIDC_CA_FILE=$(quote_env_value "${OIDC_CA_FILE:-}")
EOF
  set_file_permissions 0640 root kube-apiserver "$tmp"
  mv "${PODPLANE_ROOT:-}$tmp" "${PODPLANE_ROOT:-}/opt/env/kube-apiserver.env"
  log "wrote /opt/env/kube-apiserver.env"

  tmp="/opt/env/kube-controller-manager.env.tmp"
  cat > "${PODPLANE_ROOT:-}$tmp" <<EOF
KUBE_LOG_LEVEL=$(quote_env_value "${KUBE_LOG_LEVEL:-2}")
KUBE_CLUSTER_CIDR=$(quote_env_value "$KUBE_CLUSTER_CIDR")
KUBE_NODE_CIDR_MASK_SIZE_IPV4=$(quote_env_value "$KUBE_NODE_CIDR_MASK_SIZE_IPV4")
KUBE_NODE_CIDR_MASK_SIZE_IPV6=$(quote_env_value "$KUBE_NODE_CIDR_MASK_SIZE_IPV6")
KUBE_SERVICE_CLUSTER_IP_RANGE=$(quote_env_value "$KUBE_SERVICE_CLUSTER_IP_RANGE")
EOF
  set_file_permissions 0640 root kube-controller-manager "$tmp"
  mv "${PODPLANE_ROOT:-}$tmp" "${PODPLANE_ROOT:-}/opt/env/kube-controller-manager.env"
  log "wrote /opt/env/kube-controller-manager.env"
fi

# Configure kubelet user namespaces.
mkdir -p "${PODPLANE_ROOT:-}/etc"
log "ensuring subuid/subgid user namespaces are correct..."
echo "kubelet:65536:7208960" > "${PODPLANE_ROOT:-}/etc/subuid"
echo "kubelet:65536:7208960" > "${PODPLANE_ROOT:-}/etc/subgid"

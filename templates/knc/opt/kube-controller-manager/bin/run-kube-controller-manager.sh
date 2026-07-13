#!/usr/bin/env bash
# Podplane <https://podplane.dev>
# Copyright The Podplane Authors
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

# shellcheck source=/dev/null
source /opt/env/kube-controller-manager.env

args=(
  "--v=${KUBE_LOG_LEVEL}"
  "--kubeconfig=/opt/kube-controller-manager/etc/kubeconfig"
  "--bind-address=0.0.0.0"
  "--cluster-name=kubernetes"
  "--root-ca-file=/opt/crt/ca.crt"
  "--client-ca-file=/opt/crt/ca.crt"
  "--cluster-cidr=${KUBE_CLUSTER_CIDR}"
  "--allocate-node-cidrs=true"
  "--service-cluster-ip-range=${KUBE_SERVICE_CLUSTER_IP_RANGE}"
  "--use-service-account-credentials=true"
  "--tls-min-version=VersionTLS13"
  "--tls-cipher-suites=TLS_AES_256_GCM_SHA384"
)

IFS=, read -r -a cluster_cidrs <<< "$KUBE_CLUSTER_CIDR"
has_ipv4=false
has_ipv6=false
for cidr in "${cluster_cidrs[@]}"; do
  if [[ "$cidr" == *:* ]]; then
    has_ipv6=true
  else
    has_ipv4=true
  fi
done
if [ "$has_ipv4" = true ]; then
  args+=("--node-cidr-mask-size-ipv4=${KUBE_NODE_CIDR_MASK_SIZE_IPV4}")
fi
if [ "$has_ipv6" = true ]; then
  args+=("--node-cidr-mask-size-ipv6=${KUBE_NODE_CIDR_MASK_SIZE_IPV6}")
fi

exec /usr/bin/kube-controller-manager "${args[@]}"

#!/usr/bin/env bash
set -e

log() { printf '[run-kubelet] %s\tts=%s\n' "$*" "$EPOCHREALTIME"; }

log "starting"

# shellcheck source=/dev/null
source /opt/env/kubelet.env
log "loaded /opt/env/kubelet.env"

labels=()
if [[ -n "${PROVIDER_INSTANCE_TYPE}" ]]; then
    labels+=("node.kubernetes.io/instance-type=${PROVIDER_INSTANCE_TYPE}")
fi
if [[ -n "${PROVIDER_REGION}" ]]; then
    labels+=("topology.kubernetes.io/region=${PROVIDER_REGION}")
fi
if [[ -n "${PROVIDER_ZONE}" ]]; then
    labels+=("topology.kubernetes.io/zone=${PROVIDER_ZONE}")
fi

args=(
    '--config=/opt/kubelet/etc/kubelet.yaml'
    '--kubeconfig=/opt/kubelet/etc/kubeconfig'
    "--node-ip=${INSTANCE_IPV4},${INSTANCE_IPV6}"
    "--hostname-override=${INSTANCE_ID}"
)
if [[ ${#labels[@]} -gt 0 ]]; then
    IFS=',' args+=("--node-labels=${labels[*]}")
fi
if [[ -n "${INSTANCE_PROVIDER_ID}" ]]; then
    args+=("--provider-id=${INSTANCE_PROVIDER_ID}")
fi

log "exec kubelet"
exec /usr/bin/kubelet "${args[@]}"

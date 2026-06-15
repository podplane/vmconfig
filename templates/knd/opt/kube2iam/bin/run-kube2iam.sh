#!/usr/bin/env bash
set -e

log() { printf '[run-kube2iam] %s\tts=%s\n' "$*" "$EPOCHREALTIME"; }

log "starting"

# shellcheck source=/dev/null
source /opt/env/kube2iam.env
log "loaded /opt/env/kube2iam.env"

export AWS_REGION

args=(
    "--app-port=8181"
    "--auto-discover-base-arn=true"
    "--host-interface=lxc+"
    "--host-ip=${INSTANCE_IPV4}"
    "--iptables=true"
    "--log-level=info"
    "--metrics-port=8182"
    "--namespace-restrictions=true"
    "--node=${INSTANCE_ID}"
    "--use-regional-sts-endpoint=true"
    "--kubeconfig=/opt/kube2iam/etc/kubeconfig"
)

log "exec kube2iam"
exec /opt/kube2iam/bin/kube2iam "${args[@]}"

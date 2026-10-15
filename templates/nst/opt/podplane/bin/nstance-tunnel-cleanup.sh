#!/usr/bin/env bash
# Podplane <https://podplane.dev>
# Copyright The Podplane Authors
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail

# The nst kubelet is stopped before supervisor teardown/restart. Remove only
# supervisor-owned intent and CRI sandboxes, including containers left by SIGKILL.
rm -f /etc/kubernetes/manifests/nstance-tunnel-*.json
cri=(/usr/local/bin/crictl --runtime-endpoint=unix:///run/containerd/containerd.sock --timeout=30s)
pods=$("${cri[@]}" pods --namespace kube-system --name '^nstance-tunnel-' -q)
for pod in $pods; do
  "${cri[@]}" stopp "$pod"
  "${cri[@]}" rmp "$pod"
done

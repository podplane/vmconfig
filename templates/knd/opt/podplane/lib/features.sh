#!/usr/bin/env bash
# Podplane <https://podplane.dev>
# Copyright 2026 Nadrama Pty Ltd
# SPDX-License-Identifier: Apache-2.0

# fluent_bit_enabled returns true when fluent-bit should collect and upload logs.
fluent_bit_enabled() {
  [ "${TELEMETRY_ENABLED:-false}" = true ]
}

# zot_enabled returns true when the local registry service should run.
zot_enabled() {
  [ "${REGISTRY_ENABLED:-true}" = true ]
}

# netsy_enabled returns true on control-plane nodes that run Netsy.
netsy_enabled() {
  [ "${VMCONFIG_KIND:-}" = "knc" ]
}

# kube_apiserver_enabled returns true on control-plane nodes.
kube_apiserver_enabled() {
  [ "${VMCONFIG_KIND:-}" = "knc" ]
}

# kube_controller_manager_enabled returns true on control-plane nodes.
kube_controller_manager_enabled() {
  [ "${VMCONFIG_KIND:-}" = "knc" ]
}

# kube_scheduler_enabled returns true on control-plane nodes.
kube_scheduler_enabled() {
  [ "${VMCONFIG_KIND:-}" = "knc" ]
}

# kube2iam_enabled returns true on AWS nodes.
kube2iam_enabled() {
  [ "${PROVIDER_KIND:-}" = "aws" ]
}

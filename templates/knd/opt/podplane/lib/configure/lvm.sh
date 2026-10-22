#!/usr/bin/env bash
# Podplane <https://podplane.dev>
# Copyright The Podplane Authors
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

mkdir -p "${PODPLANE_ROOT:-}/etc/modules-load.d"
printf 'dm_mod\n' > "${PODPLANE_ROOT:-}/etc/modules-load.d/podplane-lvm.conf"

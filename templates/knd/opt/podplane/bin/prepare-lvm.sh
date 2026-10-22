#!/usr/bin/env bash
# Podplane <https://podplane.dev>
# Copyright The Podplane Authors
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

# This script is boot-only. The CSI container has independent LVM locks.
# Treat activating/deactivating and failed state queries conservatively too.
kubelet_state=$(systemctl show --property=ActiveState --value kubelet.service)
case "$kubelet_state" in
  inactive|failed) ;;
  *) echo 'refusing host LVM commands while kubelet is running or transitioning' >&2; exit 1 ;;
esac
disk=/dev/disk/by-id/virtio-podplane-data
modprobe dm_mod

# Probe all signatures, including ambiguous/corrupt media. Only an explicit
# no-signature result (2) is safe to initialize; never force or wipe a PV.
signature=''
status=0
signature=$(blkid -p -s TYPE -s PTTYPE -o value "$disk") || status=$?
case "$status:$signature" in
  0:LVM2_member|2:) ;;
  *) echo 'refusing data disk with unknown or non-LVM signature' >&2; exit 1 ;;
esac

if [ "$signature" != LVM2_member ]; then
  pvcreate "$disk"
fi
vg=$(pvs --noheadings -o vg_name "$disk")
vg=${vg//[[:space:]]/}
case "$vg" in
  podplane) ;;
  '')
    if vgs podplane >/dev/null 2>&1; then
      echo 'podplane VG exists on another disk; refusing to modify it' >&2
      exit 1
    fi
    vgcreate podplane "$disk"
    ;;
  *) echo "data disk belongs to unexpected VG: $vg" >&2; exit 1 ;;
esac
pvresize "$disk"
vgchange -ay podplane

#!/usr/bin/env bash
# Podplane <https://podplane.dev>
# Copyright The Podplane Authors
# SPDX-License-Identifier: Apache-2.0
#
# install.sh - installs the artifacts in /opt/podplane/artifacts/ after
# verifying them against the /opt/podplane/share/vmconfig-manifest.json file.
#
# Idempotent and image-bake friendly: re-runs are no-ops upon first
# successful completion, where /opt/podplane/share/vmconfig-manifest.json is
# renamed to vmconfig-installed.json and /opt/podplane/artifacts is removed.
#
# This script does NOT require the /opt/podplane/etc/user-data.env file
# used by the configure.sh script.
#
# Flow:
#   1. (preflight) checks
#   2. (install artifacts) if /opt/podplane/share/vmconfig-manifest.json exists:
#        a. verify /opt/podplane/share/vmconfig-manifest.sh matches it, then source it
#        b. verify every artifact against its digest (except vmconfig)
#        c. when the manifest includes a published vmconfig package, tar --diff
#           the vmconfig tarball against / (catches partial extraction; runs
#           BEFORE permissions.sh so chmod/chown drift can't false-positive)
#        d. install non-`vmconfig` artifacts in safe order:
#           i.)  debs first (uidmap provides getsubids needed by kubelet),
#           ii.) then tar.gz extracts, then plain binaries
#        e. mv vmconfig-manifest.json -> vmconfig-installed.json (in /opt/podplane/share/)
#   3. (cleanup) if /opt/podplane/artifacts exists: rm -rf /opt/podplane/artifacts
#   4. (permissions) invoke /opt/podplane/bin/permissions.sh "$kind"

set -euo pipefail

PODPLANE_DIR="/opt/podplane"
ARTIFACTS_DIR="${PODPLANE_DIR}/artifacts"
SHARE_DIR="${PODPLANE_DIR}/share"
VMCONFIG_MANIFEST_JSON="${SHARE_DIR}/vmconfig-manifest.json"
VMCONFIG_MANIFEST_SH="${SHARE_DIR}/vmconfig-manifest.sh"
INSTALLED_VMCONFIG_MANIFEST="${SHARE_DIR}/vmconfig-installed.json"
PERMISSIONS_SCRIPT="${PODPLANE_DIR}/bin/permissions.sh"
HELPERS_SCRIPT="${PODPLANE_DIR}/lib/helpers.sh"

# functions ------------------------------------------------------------------

log()   { printf '[install] %s\n' "$*"; }
fatal() { printf '[install] FATAL: %s\n' "$*" >&2; exit 1; }
cleanup_artifacts_dir_if_exists() {
  if [ -d "$ARTIFACTS_DIR" ]; then
    log "removing ${ARTIFACTS_DIR}"
    rm -rf "$ARTIFACTS_DIR"
  fi
}

# shellcheck source=/dev/null
source "$HELPERS_SCRIPT"

# 1. preflight ---------------------------------------------------------------

[ "$(id -u)" = "0" ] || fatal "must be run as root"

# Exit early if vmconfig is already installed
if [ -f "$INSTALLED_VMCONFIG_MANIFEST" ]; then
  log "manifest at ${INSTALLED_VMCONFIG_MANIFEST} confirms vmconfig installation is complete."
  cleanup_artifacts_dir_if_exists
  exit 0
fi

# Error if vmconfig manifest does not exist
if [ ! -f "$VMCONFIG_MANIFEST_JSON" ]; then
  fatal "required vmconfig manifest at ${VMCONFIG_MANIFEST_JSON} missing."
fi

# Check kind
load_vmconfig_kind "$VMCONFIG_MANIFEST_JSON"

# Check artifacts dir
[ -d "$ARTIFACTS_DIR" ] || fatal "${ARTIFACTS_DIR} missing"

# Check generated install metadata
[ -f "$VMCONFIG_MANIFEST_SH" ] || fatal "required vmconfig manifest metadata at ${VMCONFIG_MANIFEST_SH} missing."

# Required tools used below
for tool in sha256sum sha512sum tar dpkg install sed awk; do
  command -v "$tool" >/dev/null 2>&1 || fatal "required tool missing: ${tool}"
done

# Detect drift between manifest JSON and shell script
expected_manifest_sha256=$(sed -n -E 's/^VMCONFIG_MANIFEST_JSON_SHA256=([0-9a-f]{64})$/\1/p' "$VMCONFIG_MANIFEST_SH")
[ -n "$expected_manifest_sha256" ] || fatal "missing VMCONFIG_MANIFEST_JSON_SHA256 in ${VMCONFIG_MANIFEST_SH}"
actual_manifest_sha256=$(sha256sum "$VMCONFIG_MANIFEST_JSON" | awk '{print $1}')
if [ "$actual_manifest_sha256" != "$expected_manifest_sha256" ]; then
  fatal "${VMCONFIG_MANIFEST_JSON} does not match ${VMCONFIG_MANIFEST_SH}"
fi

# Load manifest shell script
declare -a VMCONFIG_DEPENDENCIES_ALL=() VMCONFIG_DEPENDENCIES_DEB=() VMCONFIG_DEPENDENCIES_TAR_GZ=() VMCONFIG_DEPENDENCIES_BINARY=()
# shellcheck source=/dev/null
source "$VMCONFIG_MANIFEST_SH"

# 2. install -----------------------------------------------------------------

log "installing vmconfig artifacts for instance kind=${VMCONFIG_KIND}"

# Verify every dep's digest up front, so we fail before any partial
# installation. Local filename is <key>.<ext>, with <ext> derived from
# .type (binary = no extension). `sha*sum -c` reads "<hex>  <path>".
log "verifying artifact checksums..."
for dep in "${VMCONFIG_DEPENDENCIES_ALL[@]}"; do
  IFS=$'\t' read -r name type digest <<< "$dep"
  # vmconfig is verified by tar --diff below, not by checksum here.
  [ "$name" = "vmconfig" ] && continue
  case "$type" in
    binary) src="${ARTIFACTS_DIR}/${name}" ;;
    deb)    src="${ARTIFACTS_DIR}/${name}.deb" ;;
    tar.gz) src="${ARTIFACTS_DIR}/${name}.tar.gz" ;;
    *)      fatal "${name}: unsupported type '${type}'" ;;
  esac
  [ -n "$digest" ] || fatal "${name}: empty digest in manifest"
  case "$digest" in
    sha256:*) echo "${digest#sha256:}  ${src}" | sha256sum -c --quiet ;;
    sha512:*) echo "${digest#sha512:}  ${src}" | sha512sum -c --quiet ;;
    *)        fatal "${name}: unsupported digest algorithm in ${digest}" ;;
  esac || fatal "${name}: digest verification failed"
done

# tar --diff the vmconfig tarball when the manifest includes a published
# package (catches partial / truncated extracts). Local development manifests
# use an unreleased vmconfig stub with no URL or digest; those are synced into
# the VM rather than staged as /opt/podplane/artifacts/vmconfig.tar.gz.
# Must run BEFORE permissions.sh so mode/owner drift doesn't false-positive.
if [ -z "$VMCONFIG_URL" ] && [ -z "$VMCONFIG_DIGEST" ]; then
  log "skipping vmconfig tarball verification for local development manifest"
else
  log "verifying vmconfig tarball extraction..."
  tar --diff -zf "${ARTIFACTS_DIR}/vmconfig.tar.gz" -C / \
    || fatal "vmconfig.tar.gz contents do not match filesystem"
fi

# Install order:
#   1. debs    - uidmap provides /usr/bin/getsubids that kubelet checks
#                at startup; libsubid5/libpq5 are runtime libs.
#   2. tar.gz  - containerd/crictl to /usr/local/bin per
#                upstream docs; cni-plugins to /opt/cni/bin per CRI.
#   3. binary  - kubelet/kube-*/zot to /usr/bin; runc to
#                /usr/local/sbin per upstream containerd docs.
#
# policy-rc.d blocks dpkg postinst from starting services; configure.sh
# owns service lifecycle. The trap guarantees cleanup on failure.

log "installing debs..."
# Batch into a single `dpkg -i` so dpkg resolves inter-deb deps for us
# (e.g. uidmap depends on libsubid5)
if [ "${#VMCONFIG_DEPENDENCIES_DEB[@]}" -gt 0 ]; then
  debs=()
  for name in "${VMCONFIG_DEPENDENCIES_DEB[@]}"; do
    debs+=("${ARTIFACTS_DIR}/${name}.deb")
  done
  # temporarily modify policy-rc.d to block dpkg postinst from starting services
  policy_rc="/usr/sbin/policy-rc.d"
  policy_rc_backup="${policy_rc}.podplane-bak"
  restore_policy_rc() {
    rm -f "$policy_rc"
    if [ -e "$policy_rc_backup" ]; then
      mv "$policy_rc_backup" "$policy_rc"
    fi
  }
  if [ -e "$policy_rc" ]; then
    mv "$policy_rc" "$policy_rc_backup"
  fi
  trap restore_policy_rc EXIT
  printf '#!/bin/sh\nexit 101\n' > "$policy_rc"
  chmod 0755 "$policy_rc"
  # install all debs via dpkg
  DEBIAN_FRONTEND=noninteractive dpkg -i "${debs[@]}"
  # restore original policy-rd.d
  restore_policy_rc
  trap - EXIT
fi

log "extracting tarballs..."
for name in "${VMCONFIG_DEPENDENCIES_TAR_GZ[@]}"; do
  # vmconfig is already extracted to / by user-data; tar --diff above
  # has confirmed it. Skip here so we don't clobber it.
  [ "$name" = "vmconfig" ] && continue
  src="${ARTIFACTS_DIR}/${name}.tar.gz"
  case "$name" in
    containerd)  tar -xzf "$src" -C /usr/local bin/containerd bin/containerd-shim-runc-v2 bin/ctr ;;
    crictl)      tar -xzf "$src" -C /usr/local/bin crictl ;;
    netsy)       mkdir -p /opt/netsy/bin && tar -xzf "$src" -C /opt/netsy/bin netsy ;;
    nstance-agent) mkdir -p /opt/nstance-agent/bin && tar -xzf "$src" -C /opt/nstance-agent/bin nstance-agent ;;
    cni-plugins) mkdir -p /opt/cni/bin && tar -xzf "$src" -C /opt/cni/bin ;;
    *)           fatal "no extract rule for tarball ${name}" ;;
  esac
done

log "installing binaries..."
for name in "${VMCONFIG_DEPENDENCIES_BINARY[@]}"; do
  case "$name" in
    runc) dest=/usr/local/sbin ;;
    *) dest=/usr/bin ;;
  esac
  mkdir -p "$dest"
  install -m0755 -o root -g root "${ARTIFACTS_DIR}/${name}" "${dest}/${name}"
done

# Rename the vmconfig manifest to vmconfig-installed.json to prevent
# re-installation. The configure.sh script also depends on vmconfig-installed.json.
# `touch` first so the audit mtime = install completion time.
touch "$VMCONFIG_MANIFEST_JSON"
mv "$VMCONFIG_MANIFEST_JSON" "$INSTALLED_VMCONFIG_MANIFEST"
log "recorded install in ${INSTALLED_VMCONFIG_MANIFEST}"

# 3. cleanup -----------------------------------------------------------------

cleanup_artifacts_dir_if_exists

# 4. enforce permissions -----------------------------------------------------

[ -x "$PERMISSIONS_SCRIPT" ] || fatal "missing or non-executable: ${PERMISSIONS_SCRIPT}"
"$PERMISSIONS_SCRIPT" "$VMCONFIG_KIND"

log "install.sh completed successfully."

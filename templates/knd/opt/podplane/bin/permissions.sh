#!/usr/bin/env bash
# Podplane <https://podplane.dev>
# Copyright The Podplane Authors
# SPDX-License-Identifier: Apache-2.0
#
# permissions.sh - ensure all required users, groups, directories and file
# permissions are correct.
#
# Invoked by both install.sh and configure.sh so machine images can be
# locked-down but running VMs can also mitigate drift on each boot.
#
# Idempotent: every operation is safe to re-run.
#
# Usage: permissions.sh <kind>

set -euo pipefail
IFS=$'\n\t'

SERVICE_USER_DEFAULT_SHELL="/usr/sbin/nologin"
LOGIN_USER_DEFAULT_SHELL="/bin/bash"
LOCK_FILE="/var/lock/podplane-permissions.lock"
USER_DATA_ENV="/opt/podplane/etc/user-data.env"

# functions ------------------------------------------------------------------

log()   { printf '[permissions] %s\n' "$*"; }

fatal() { printf '[permissions] FATAL: %s\n' "$*" >&2; exit 1; }

user_in_group() { # <username> <group>
  # returns 0 iff user is a member of group.
  local username="$1" group="$2"
  id -nG "$username" 2>/dev/null | tr ' ' '\n' | grep -Fxq "$group"
}

ensure_user_and_groups() { # <username> <primary group> <extra groups>
  local username="$1"
  local primary_group="$2"
  shift 2
  local extra_groups=("$@")
  if ! getent group "$primary_group" >/dev/null; then
    groupadd "$primary_group"
  fi
  if ! id "$username" >/dev/null 2>&1; then
    if [ "$username" = "kubelet" ]; then
      # kubelet is created as a regular (non-system) user with a home directory
      # because some kubelet credential plugins / kubeconfig flows assume $HOME
      # exists and is writeable. The login shell is still nologin so it cannot
      # be used interactively.
      useradd -g "$primary_group" -m -s "$SERVICE_USER_DEFAULT_SHELL" "$username"
    else
      useradd -r -g "$primary_group" -m -s "$SERVICE_USER_DEFAULT_SHELL" "$username"
    fi
  elif [ "$(getent passwd "$username" | cut -d: -f7)" != "$SERVICE_USER_DEFAULT_SHELL" ]; then
    usermod -s "$SERVICE_USER_DEFAULT_SHELL" "$username"
  fi
  # ensure each declared extra group exists.
  local grp
  for grp in ${extra_groups[@]+"${extra_groups[@]}"}; do
    if ! getent group "$grp" >/dev/null; then
      groupadd "$grp"
    fi
  done
  # replace (not append) the user's secondary group membership with exactly
  # the declared extras. this drops any stale memberships from previous
  # spec versions on subsequent runs.
  local groups_csv=""
  if [ "${#extra_groups[@]}" -gt 0 ]; then
    groups_csv=$(IFS=,; printf '%s' "${extra_groups[*]}")
  fi
  usermod -G "$groups_csv" "$username"
}

ensure_login_user_and_groups() { # <username> <primary group> <extra groups>
  local username="$1"
  local primary_group="$2"
  shift 2
  local extra_groups=("$@")
  if ! getent group "$primary_group" >/dev/null; then
    groupadd "$primary_group"
  fi
  if ! id "$username" >/dev/null 2>&1; then
    useradd -g "$primary_group" -m -s "$LOGIN_USER_DEFAULT_SHELL" "$username"
  else
    if [ "$(getent passwd "$username" | cut -d: -f6)" != "/home/${username}" ]; then
      usermod -d "/home/${username}" -m "$username"
    fi
    if [ "$(getent passwd "$username" | cut -d: -f7)" != "$LOGIN_USER_DEFAULT_SHELL" ]; then
      usermod -s "$LOGIN_USER_DEFAULT_SHELL" "$username"
    fi
  fi
  local grp
  for grp in ${extra_groups[@]+"${extra_groups[@]}"}; do
    if ! getent group "$grp" >/dev/null; then
      groupadd "$grp"
    fi
  done
  local groups_csv=""
  if [ "${#extra_groups[@]}" -gt 0 ]; then
    groups_csv=$(IFS=,; printf '%s' "${extra_groups[*]}")
  fi
  usermod -G "$groups_csv" "$username"
}

ensure_permissions() {
  local mode="$1" user="$2" group="$3" path="$4"

  # Validate referenced user/group exist before chowning so typos in the
  # spec fail loudly instead of silently chowning to a numeric id.
  getent passwd "$user"  >/dev/null || fatal "user '$user' does not exist (path: $path)"
  getent group  "$group" >/dev/null || fatal "group '$group' does not exist (path: $path)"

  # Refuse to operate on symlinks - chmod/chown would silently follow them
  # and modify the target instead of the link itself.
  if [ -L "$path" ]; then
    fatal "$path is a symlink, refusing to manage permissions"
  fi

  # If the path exists but is not a directory we should fail rather than
  # have mkdir -p succeed-silently and then chmod a regular file.
  if [ -e "$path" ] && [ ! -d "$path" ]; then
    fatal "$path exists but is not a directory"
  fi

  mkdir -p "$path"
  chmod "$mode" "$path"
  chown "$user":"$group" "$path"
}

ensure_executable() {
  local path="$1"
  if [ -e "$path" ]; then
    chmod +x "$path"
  fi
}

# preflight -----------------------------------------------------------------

# Check current user is root
[ "$(id -u)" = "0" ] || fatal "must be run as root"

# Acquire an exclusive lock so concurrent invocations (e.g. install.sh racing
# against configure.sh) do not collide on useradd/groupadd/usermod calls.
exec 9>"$LOCK_FILE"
flock -n 9 || fatal "another permissions.sh is already running (lock: $LOCK_FILE)"

# Determine instance kind
[ "$#" -ge 1 ] || fatal "usage: $0 <kind>"
VMCONFIG_KIND="$1"
case "$VMCONFIG_KIND" in
  knd|knc) ;;
  *) fatal "unsupported kind argument: '${VMCONFIG_KIND}'" ;;
esac

if [ -f "$USER_DATA_ENV" ]; then
  # shellcheck source=/dev/null
  source "$USER_DATA_ENV"
fi

# users and groups ----------------------------------------------------------
log "configuring users and groups..."

# format:                USER                    PRIMARY GROUP           ADDITIONAL GROUPS
ensure_user_and_groups   podplane                podplane
ensure_user_and_groups   nstance-agent           nstance-agent           podplane
ensure_user_and_groups   fluent-bit              fluent-bit              podplane systemd-journal
ensure_user_and_groups   kube2iam                kube2iam                podplane
ensure_user_and_groups   containerd              containerd              podplane
ensure_user_and_groups   kubelet                 kubelet                 podplane containerd
ensure_user_and_groups   zot                     zot                     podplane
if [ -n "${SSH_AUTHORIZED_KEY:-}" ]; then
  ensure_login_user_and_groups admin admin
fi
if [ "$VMCONFIG_KIND" = "knc" ]; then
  ensure_user_and_groups netsy                   netsy                   podplane
  ensure_user_and_groups kube-apiserver          kube-apiserver          podplane
  ensure_user_and_groups kube-scheduler          kube-scheduler          podplane
  ensure_user_and_groups kube-controller-manager kube-controller-manager podplane
fi
log "done."

# directories and permissions -----------------------------------------------
log "configuring required user/group ownership and permissions..."

# format:            MODE USER                    GROUP                   PATH
#      rwx/---/--- = 0700
#      rwx/--x/--- = 0710
#      rwx/r-x/--- = 0750
#      rwx/r-x/r-x = 0755
ensure_permissions   0755 root                    root                    "/etc"
ensure_permissions   0755 root                    root                    "/etc/containerd"
ensure_permissions   0755 root                    root                    "/etc/containerd/certs.d"
ensure_permissions   0750 root                    podplane                "/opt"
ensure_permissions   0750 root                    podplane                "/opt/podplane"
ensure_permissions   0755 root                    root                    "/opt/podplane/bin"
ensure_permissions   0700 root                    root                    "/opt/podplane/etc"
ensure_permissions   0755 root                    root                    "/opt/podplane/lib"
ensure_permissions   0755 root                    root                    "/opt/podplane/lib/configure"
ensure_permissions   0755 root                    root                    "/opt/podplane/share"
ensure_permissions   0700 root                    root                    "/opt/bin"
ensure_permissions   0750 root                    podplane                "/opt/crt"
ensure_permissions   0750 root                    podplane                "/opt/pub"
ensure_permissions   0710 root                    podplane                "/opt/key"
ensure_permissions   0750 root                    podplane                "/opt/env"
ensure_permissions   0700 root                    root                    "/opt/versions"
ensure_permissions   0700 nstance-agent           nstance-agent           "/opt/nstance-agent"
ensure_permissions   0700 nstance-agent           nstance-agent           "/opt/nstance-agent/identity"
ensure_permissions   0700 nstance-agent           nstance-agent           "/opt/nstance-agent/keys"
ensure_permissions   0700 nstance-agent           nstance-agent           "/opt/nstance-agent/recv"
ensure_permissions   0700 fluent-bit              fluent-bit              "/opt/fluent-bit"
ensure_permissions   0700 fluent-bit              fluent-bit              "/var/lib/fluent-bit"
ensure_permissions   0700 kube2iam                kube2iam                "/opt/kube2iam"
ensure_permissions   0750 root                    kube2iam                "/opt/key/kube2iam"
ensure_permissions   0700 root                    root                    "/opt/cni"
ensure_permissions   0700 kubelet                 kubelet                 "/opt/kubelet"
ensure_permissions   0750 root                    kubelet                 "/opt/key/kubelet"
ensure_permissions   0750 root                    containerd              "/opt/key/containerd"
ensure_permissions   0750 kubelet                 kubelet                 "/var/lib/kubelet"
ensure_permissions   0750 kubelet                 kubelet                 "/var/log/containers"
ensure_permissions   0750 kubelet                 kubelet                 "/var/log/pods"
ensure_permissions   0700 zot                     zot                     "/opt/zot"
ensure_permissions   0700 zot                     zot                     "/opt/zot/etc"
ensure_permissions   0700 zot                     zot                     "/opt/zot/storage"
ensure_permissions   0750 root                    zot                     "/opt/key/registry"
if [ "$VMCONFIG_KIND" = "knc" ]; then
  ensure_permissions 0700 netsy                   netsy                   "/opt/data"
  ensure_permissions 0700 netsy                   netsy                   "/opt/netsy"
  ensure_permissions 0750 root                    netsy                   "/opt/netsy/etc"
  ensure_permissions 0750 root                    netsy                   "/opt/key/netsy"
  ensure_permissions 0700 kube-apiserver          kube-apiserver          "/opt/kube-apiserver"
  ensure_permissions 0750 root                    kube-apiserver          "/opt/key/kube-apiserver"
  ensure_permissions 0700 kube-scheduler          kube-scheduler          "/opt/kube-scheduler"
  ensure_permissions 0750 root                    kube-scheduler          "/opt/key/kube-scheduler"
  ensure_permissions 0700 kube-controller-manager kube-controller-manager "/opt/kube-controller-manager"
  ensure_permissions 0750 root                    kube-controller-manager "/opt/key/kube-controller-manager"
fi

# binary executables ----------------------------------------------------
log "configuring binary executable permissions..."

# Podplane scripts (always)
ensure_executable "/opt/podplane/bin/install.sh"
ensure_executable "/opt/podplane/bin/permissions.sh"
ensure_executable "/opt/podplane/bin/bootstrap.sh"
ensure_executable "/opt/podplane/bin/configure.sh"
ensure_executable "/opt/podplane/bin/restart.sh"
ensure_executable "/opt/podplane/bin/update-mutable-env.sh"
ensure_executable "/opt/podplane/bin/nstance-recv-watch.sh"
ensure_executable "/opt/podplane/lib/configure/hosts.sh"
ensure_executable "/opt/podplane/lib/configure/nstance-agent.sh"
ensure_executable "/opt/podplane/lib/configure/fluent-bit.sh"
ensure_executable "/opt/podplane/lib/configure/containerd.sh"
ensure_executable "/opt/podplane/lib/configure/zot.sh"
ensure_executable "/opt/podplane/lib/configure/kube2iam.sh"
ensure_executable "/opt/podplane/lib/configure/kube.sh"
ensure_executable "/opt/podplane/lib/configure/netsy.sh"

# nstance-agent
ensure_executable "/opt/nstance-agent/bin/nstance-agent"
ensure_executable "/opt/nstance-agent/bin/run-nstance-agent.sh"

# Node-base binaries
ensure_executable "/opt/netsy/bin/netsy"
ensure_executable "/opt/netsy/bin/run-netsy.sh"
ensure_executable "/opt/fluent-bit/bin/fluent-bit"
ensure_executable "/opt/fluent-bit/bin/run-fluent-bit.sh"
ensure_executable "/opt/kube2iam/bin/run-kube2iam.sh"
ensure_executable "/opt/kube2iam/bin/kube2iam"
ensure_executable "/usr/bin/getsubids"
ensure_executable "/usr/local/bin/containerd"
ensure_executable "/usr/local/bin/containerd-shim-runc-v2"
ensure_executable "/usr/local/bin/crictl"
ensure_executable "/usr/local/bin/ctr"
ensure_executable "/usr/local/sbin/runc"
ensure_executable "/opt/kubelet/bin/run-kubelet.sh"
ensure_executable "/usr/bin/kubelet"
ensure_executable "/usr/bin/zot"
ensure_executable "/opt/zot/bin/run-zot.sh"
if [ -d /opt/cni/bin ]; then
  for f in /opt/cni/bin/*; do
    [ -e "$f" ] && chmod +x "$f"
  done
fi
if [ "$VMCONFIG_KIND" = "knc" ]; then
  ensure_executable "/opt/kube-apiserver/bin/run-kube-apiserver.sh"
  ensure_executable "/usr/bin/kube-apiserver"
  ensure_executable "/usr/bin/kube-scheduler"
  ensure_executable "/usr/bin/kube-controller-manager"
fi

# special cases -------------------------------------------------------------
log "configuring special case permissions..."

# fluent-bit needs to read syslog-owned logs (e.g. /var/log/cloud-init.log).
# Add fluent-bit to the syslog group so it can read those files via group
# perms. This survives logrotate, since rotated files are re-created as
# syslog:syslog 0640 and the group bit is sufficient for read access.
if id fluent-bit >/dev/null 2>&1 && getent group syslog >/dev/null; then
  if ! user_in_group fluent-bit syslog; then
    log "adding fluent-bit user to syslog group..."
    usermod -aG syslog fluent-bit
  fi
fi

# shared libs that some tooling needs to read
ARCH_TRIPLET="$(uname -m)-linux-gnu"
for lib in "/usr/lib/${ARCH_TRIPLET}/libpq.so.5" "/usr/lib/${ARCH_TRIPLET}/libsubid.so.5"; do
  [ -e "$lib" ] && chmod 0755 "$lib"
done

if [ -n "${SSH_AUTHORIZED_KEY:-}" ]; then
  log "configuring admin sudo permissions..."
  mkdir -p /etc/sudoers.d
  echo "admin ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/admin
  chmod 0440 /etc/sudoers.d/admin
else
  rm -f /etc/sudoers.d/admin
fi

log "successfully configured all users, groups, and directory/file ownership/permissions."

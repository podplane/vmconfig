#!/usr/bin/env bash
# Podplane <https://podplane.dev>
# Copyright The Podplane Authors
# SPDX-License-Identifier: Apache-2.0
# Loads and configures the eBPF program that counts active production connections.

set -euo pipefail

BPF_FS="${BPF_FS:-/sys/fs/bpf}"
PIN_DIR="${PIN_DIR:-${BPF_FS}/nstance/counters}"
PORTS_FILE="${PORTS_FILE:-/etc/nstance-counters/production-ports}"
OBJECT="${OBJECT:-/opt/nstance-counters/lib/active-connections.bpf.o}"
BPFTOOL="${BPFTOOL:-bpftool}"

disable() {
	if [[ -e "${PIN_DIR}/sockops-link" ]]; then
		rm -f "${PIN_DIR}/sockops-link"
	fi
	rm -rf "${PIN_DIR}"
}

if [[ "${1:-}" == "--disable" ]]; then
	disable
	exit 0
fi

ports=()
if [[ -f "${PORTS_FILE}" ]]; then
	while IFS= read -r token; do
		[[ -z "${token}" || "${token}" == \#* ]] && continue
		if [[ ! "${token}" =~ ^[0-9]+$ ]] || ((10#${token} < 1 || 10#${token} > 65535)); then
			echo "invalid production port: ${token}" >&2
			exit 1
		fi
		ports+=("$((10#${token}))")
	done < <(awk '{ sub(/#.*/, ""); gsub(/[,[:space:]]+/, "\n"); print }' "${PORTS_FILE}" | sort -nu)
fi

# No configured production listener means collection is disabled, not an
# all-port counter. This is deliberately fail-closed for connection monitoring.
if ((${#ports[@]} == 0)); then
	if [[ "${NSTANCE_COUNTERS_PLAN:-0}" == 1 ]]; then
		echo disabled
		exit 0
	fi
	disable
	exit 0
fi

if [[ "${NSTANCE_COUNTERS_PLAN:-0}" == 1 ]]; then
	printf 'enabled ports='
	(IFS=,; echo "${ports[*]}")
	exit 0
fi

if ! mountpoint -q "${BPF_FS}"; then
	mount -t bpf bpf "${BPF_FS}"
fi
disable
mkdir -p "${PIN_DIR}/links" "${PIN_DIR}/maps"

"${BPFTOOL}" prog loadall "${OBJECT}" "${PIN_DIR}/links" \
	pinmaps "${PIN_DIR}/maps" autoattach

for port in "${ports[@]}"; do
	read -r -a key_bytes <<< "$(printf '%08x' "${port}" | sed -E 's/(..)(..)(..)(..)/0x\4 0x\3 0x\2 0x\1/')"
	"${BPFTOOL}" map update pinned "${PIN_DIR}/maps/production_ports" key hex "${key_bytes[@]}" value hex 01
	"${BPFTOOL}" map update pinned "${PIN_DIR}/maps/active_connections" key hex "${key_bytes[@]}" \
		value hex 00 00 00 00 00 00 00 00
done

# The agent can traverse only this namespace and open only the counter map.
# It cannot mutate the loader's port allowlist or replace pinned programs/links.
chown -R root:root "${BPF_FS}/nstance"
chmod 0710 "${BPF_FS}/nstance" "${PIN_DIR}" "${PIN_DIR}/links" "${PIN_DIR}/maps"
chgrp nstance-agent "${BPF_FS}/nstance" "${PIN_DIR}" "${PIN_DIR}/links" "${PIN_DIR}/maps"
chmod 0440 "${PIN_DIR}/links/count_active_connections" "${PIN_DIR}/maps/active_connections"
chgrp nstance-agent "${PIN_DIR}/links/count_active_connections" "${PIN_DIR}/maps/active_connections"
chmod 0600 "${PIN_DIR}/maps/production_ports"

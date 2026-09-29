#!/usr/bin/env bash
# Podplane <https://podplane.dev>
# Copyright The Podplane Authors
# SPDX-License-Identifier: Apache-2.0
# Tests validation and planning for the Nstance active connection counter loader.

set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
loader="${root}/templates/knd/opt/nstance-counters/bin/load.sh"
program="${root}/templates/knd/opt/nstance-counters/src/active-connections.bpf.c"
object="${root}/templates/knd/opt/nstance-counters/lib/active-connections.bpf.o"
tmp=$(mktemp -d)
trap 'rm -rf "${tmp}"' EXIT

[[ -s "${object}" ]] || { echo "packaged eBPF object is missing" >&2; exit 1; }

touch "${tmp}/ports"
output=$(NSTANCE_COUNTERS_PLAN=1 PORTS_FILE="${tmp}/ports" "${loader}")
[[ "${output}" == disabled ]] || { echo "empty ports unexpectedly enabled counters: ${output}" >&2; exit 1; }

printf '# production only\n8443, 443\n8443\n' > "${tmp}/ports"
output=$(NSTANCE_COUNTERS_PLAN=1 PORTS_FILE="${tmp}/ports" "${loader}")
[[ "${output}" == 'enabled ports=443,8443' ]] || { echo "wrong port filter: ${output}" >&2; exit 1; }

printf '443\n0\n' > "${tmp}/ports"
if NSTANCE_COUNTERS_PLAN=1 PORTS_FILE="${tmp}/ports" "${loader}" >/dev/null 2>&1; then
	echo "invalid port enabled counters" >&2
	exit 1
fi

grep -Fq 'SEC("tracepoint/sock/inet_sock_set_state")' "${program}"
allow_line=$(grep -n 'bpf_map_lookup_elem(&production_ports' "${program}" | cut -d: -f1)
count_line=$(grep -n 'bpf_map_lookup_elem(&active_connections' "${program}" | head -1 | cut -d: -f1)
[[ -n "${allow_line}" && -n "${count_line}" && "${allow_line}" -lt "${count_line}" ]] || {
	echo "counter program does not filter production ports before counting" >&2
	exit 1
}

echo "Nstance counter tests passed"

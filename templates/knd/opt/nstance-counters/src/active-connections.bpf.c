// Podplane <https://podplane.dev>
// Copyright The Podplane Authors
// SPDX-License-Identifier: Apache-2.0

// This object intentionally uses only stable tracepoint fields and BPF helper
// declarations. Build it with clang -target bpf; no vendored headers are needed.

#define SEC(name) __attribute__((section(name), used))
#define __uint(name, value) int (*name)[value]
#define __type(name, value) value *name
#define BPF_MAP_TYPE_HASH 1
#define TCP_ESTABLISHED 1

typedef unsigned char __u8;
typedef unsigned short __u16;
typedef unsigned int __u32;
typedef unsigned long long __u64;

struct inet_sock_set_state {
	__u64 unused;
	const void *skaddr;
	int oldstate;
	int newstate;
	__u16 sport;
	__u16 dport;
};

struct {
	__uint(type, BPF_MAP_TYPE_HASH);
	__uint(max_entries, 65536);
	__type(key, __u32);
	__type(value, __u8);
} production_ports SEC(".maps");

struct {
	__uint(type, BPF_MAP_TYPE_HASH);
	__uint(max_entries, 65536);
	__type(key, __u32);
	__type(value, __u64);
} active_connections SEC(".maps");

static void *(*bpf_map_lookup_elem)(void *map, const void *key) = (void *)1;

SEC("tracepoint/sock/inet_sock_set_state")
int count_active_connections(struct inet_sock_set_state *event)
{
	__u32 port = event->sport;
	__u8 *enabled = bpf_map_lookup_elem(&production_ports, &port);
	__u64 *count;

	if (!enabled)
		return 0;
	count = bpf_map_lookup_elem(&active_connections, &port);
	if (!count)
		return 0;
	if (event->oldstate != TCP_ESTABLISHED &&
	    event->newstate == TCP_ESTABLISHED) {
		__sync_fetch_and_add(count, 1);
	} else if (event->oldstate == TCP_ESTABLISHED &&
		   event->newstate != TCP_ESTABLISHED) {
		int attempt;

#pragma unroll
		for (attempt = 0; attempt < 8; attempt++) {
			__u64 current = *count;

			if (current == 0 ||
			    __sync_val_compare_and_swap(count, current, current - 1) == current)
				break;
		}
	}
	return 0;
}

char LICENSE[] SEC("license") = "GPL";

// Podplane <https://podplane.dev>
// Copyright The Podplane Authors
// SPDX-License-Identifier: Apache-2.0

package main

import (
	"os"
	"os/exec"
	"strings"
	"testing"
)

// TestLVMPreparationRefusesUnsafeState checks the guards, not LVM itself.
func TestLVMPreparationRefusesUnsafeState(t *testing.T) {
	for _, tc := range []struct {
		name, state, signature, status, want string
	}{
		{"running kubelet", "active", "", "2", "kubelet is running"},
		{"starting kubelet", "activating", "", "2", "kubelet is running"},
		{"filesystem", "inactive", "ext4", "0", "non-LVM signature"},
		{"partition table", "inactive", "gpt", "0", "non-LVM signature"},
		{"ambiguous signatures", "inactive", "", "8", "non-LVM signature"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			cmd := exec.Command("bash", "-c", `
systemctl() { printf '%s\n' "$TEST_STATE"; }
modprobe() { :; }
blkid() { printf '%s' "$TEST_SIGNATURE"; return "$TEST_STATUS"; }
pvcreate() { echo 'unexpected LVM command'; exit 99; }
pvs() { pvcreate; }
vgs() { pvcreate; }
vgcreate() { pvcreate; }
pvresize() { pvcreate; }
vgchange() { pvcreate; }
source ../../templates/knd/opt/podplane/bin/prepare-lvm.sh
`)
			cmd.Env = append(os.Environ(), "TEST_STATE="+tc.state, "TEST_SIGNATURE="+tc.signature, "TEST_STATUS="+tc.status)
			out, err := cmd.CombinedOutput()
			if err == nil || !strings.Contains(string(out), tc.want) || strings.Contains(string(out), "unexpected LVM command") {
				t.Fatalf("expected safe refusal: %v\n%s", err, out)
			}
		})
	}
}

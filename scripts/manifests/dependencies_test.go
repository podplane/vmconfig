// Podplane <https://podplane.dev>
// Copyright The Podplane Authors
// SPDX-License-Identifier: Apache-2.0

package main

import (
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

// TestInstallPlanProviders verifies provider selection covers both verification
// and every install format, while provider-neutral dependencies always remain.
func TestInstallPlanProviders(t *testing.T) {
	dir := t.TempDir()
	manifest, plan := filepath.Join(dir, "manifest.json"), filepath.Join(dir, "manifest.sh")
	fixture := `{"vmconfig":{"kind":"knd","dependencies":{
		"common":{"type":"binary","digest":"sha256:common"},
		"deb":{"type":"deb","digest":"sha256:deb","providers":["aws"]},
		"gzip":{"type":"tar.gz","digest":"sha256:gzip","providers":["aws"]},
		"zstd":{"type":"tar.zstd","digest":"sha256:zstd","providers":["aws"]},
		"binary":{"type":"binary","digest":"sha256:binary","providers":["aws","google"]}
	}}}`
	if err := os.WriteFile(manifest, []byte(fixture), 0o600); err != nil {
		t.Fatal(err)
	}
	if out, err := exec.Command("bash", "../manifests.sh", manifest, plan).CombinedOutput(); err != nil {
		t.Fatalf("render install plan: %v\n%s", err, out)
	}
	for _, test := range []struct {
		provider, want string
	}{
		{"aws", "common deb gzip zstd binary \ndeb\ngzip\nzstd\ncommon binary\n"},
		{"google", "common binary \n\n\n\ncommon binary\n"},
		{"local", "common \n\n\n\ncommon\n"},
		{"proxmox", "common \n\n\n\ncommon\n"},
		{"", "common \n\n\n\ncommon\n"},
	} {
		t.Run("provider="+test.provider, func(t *testing.T) {
			cmd := exec.Command("bash", "-c", `
set -euo pipefail
PROVIDER_KIND="$2"
source "$1"
for dep in "${VMCONFIG_DEPENDENCIES_ALL[@]}"; do
  IFS=$'\t' read -r name type digest <<< "$dep"
  printf '%s ' "$name"
done
printf '\n%s\n%s\n%s\n%s\n' "${VMCONFIG_DEPENDENCIES_DEB[*]}" "${VMCONFIG_DEPENDENCIES_TAR_GZ[*]}" "${VMCONFIG_DEPENDENCIES_TAR_ZSTD[*]}" "${VMCONFIG_DEPENDENCIES_BINARY[*]}"
`, "bash", plan, test.provider)
			out, err := cmd.CombinedOutput()
			if err != nil || string(out) != test.want {
				t.Fatalf("install plan: %v\ngot  %q\nwant %q", err, out, test.want)
			}
		})
	}
}

// TestValidateDependencyGraph permits cycles only within a single deb batch
// and rejects invalid references and kind coverage.
func TestValidateDependencyGraph(t *testing.T) {
	tests := []struct {
		name string
		deps map[string]DownloadGroup
		want string
	}{
		{
			name: "missing",
			deps: map[string]DownloadGroup{"a": {Files: []FileEntry{{Name: "a", Kind: []string{KindKnd}, Requires: []string{"b"}}}}},
			want: "unknown dependency",
		},
		{
			name: "kind mismatch",
			deps: map[string]DownloadGroup{
				"a": {Files: []FileEntry{{Name: "a", Kind: []string{KindKnd}, Requires: []string{"b"}}}},
				"b": {Files: []FileEntry{{Name: "b", Kind: []string{KindNat}}}},
			},
			want: "does not support that kind",
		},
		{
			name: "cycle",
			deps: map[string]DownloadGroup{
				"a": {Files: []FileEntry{{Name: "a", Kind: []string{KindKnd}, Requires: []string{"b"}}}},
				"b": {Files: []FileEntry{{Name: "b", Kind: []string{KindKnd}, Requires: []string{"a"}}}},
			},
			want: "dependency cycle",
		},
		{
			name: "deb batch cycle",
			deps: map[string]DownloadGroup{
				"a": {Type: DepTypeDeb, Files: []FileEntry{{Name: "a", Kind: []string{KindKnd}, Providers: []string{"local"}, Requires: []string{"b"}}}},
				"b": {Type: DepTypeDeb, Files: []FileEntry{{Name: "b", Kind: []string{KindKnd}, Providers: []string{"local"}, Requires: []string{"a"}}}},
			},
		},
		{
			name: "mixed package cycle",
			deps: map[string]DownloadGroup{
				"a": {Type: DepTypeDeb, Files: []FileEntry{{Name: "a", Kind: []string{KindKnd}, Providers: []string{"local"}, Requires: []string{"b"}}}},
				"b": {Type: DepTypeBinary, Files: []FileEntry{{Name: "b", Kind: []string{KindKnd}, Providers: []string{"local"}, Requires: []string{"c"}}}},
				"c": {Type: DepTypeDeb, Files: []FileEntry{{Name: "c", Kind: []string{KindKnd}, Providers: []string{"local"}, Requires: []string{"a"}}}},
			},
			want: "dependency cycle",
		},
		{
			name: "different provider cycle",
			deps: map[string]DownloadGroup{
				"a": {Type: DepTypeDeb, Files: []FileEntry{{Name: "a", Kind: []string{KindKnd}, Providers: []string{"local"}, Requires: []string{"b"}}}},
				"b": {Type: DepTypeDeb, Files: []FileEntry{{Name: "b", Kind: []string{KindKnd}, Providers: []string{"aws"}, Requires: []string{"a"}}}},
			},
			want: "dependency cycle",
		},
		{
			name: "overlapping cycles with different providers",
			deps: map[string]DownloadGroup{
				"a": {Type: DepTypeDeb, Files: []FileEntry{{Name: "a", Kind: []string{KindKnd}, Providers: []string{"local"}, Requires: []string{"b"}}}},
				"b": {Type: DepTypeDeb, Files: []FileEntry{{Name: "b", Kind: []string{KindKnd}, Providers: []string{"local"}, Requires: []string{"a", "c"}}}},
				"c": {Type: DepTypeDeb, Files: []FileEntry{{Name: "c", Kind: []string{KindKnd}, Providers: []string{"aws"}, Requires: []string{"a"}}}},
			},
			want: "dependency cycle",
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			original := sources.Dependencies
			sources.Dependencies = test.deps
			defer func() { sources.Dependencies = original }()
			err := validateDependencyGraph()
			if test.want == "" {
				if err != nil {
					t.Fatalf("validateDependencyGraph() error = %v, want a valid deb batch", err)
				}
				return
			}
			if err == nil || !strings.Contains(err.Error(), test.want) {
				t.Fatalf("validateDependencyGraph() error = %v, want containing %q", err, test.want)
			}
		})
	}
}

// TestExtractAptDependencyNames verifies direct, alternative, qualified, and
// folded Debian dependency fields are normalized to package names.
func TestExtractAptDependencyNames(t *testing.T) {
	packages := "Package: other\nDepends: ignored\n\n" +
		"Package: example\nPre-Depends: init-system-helpers (>= 1.0)\n" +
		"Depends: libfoo:any (>= 2), libbar | libbaz,\n libqux (= 3)\n\n"
	got, err := extractAptDependencyNames(packages, "example")
	if err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"init-system-helpers", "libfoo", "libbar", "libbaz", "libqux"} {
		if !got[name] {
			t.Errorf("missing dependency %q", name)
		}
	}
	if got["ignored"] {
		t.Error("included dependency from another package")
	}
}

// TestRenderDependenciesDoc verifies the generated reference includes direct
// edges and remains deterministic.
func TestRenderDependenciesDoc(t *testing.T) {
	first, err := renderDependenciesDoc()
	if err != nil {
		t.Fatal(err)
	}
	second, err := renderDependenciesDoc()
	if err != nil {
		t.Fatal(err)
	}
	if first != second {
		t.Fatal("renderDependenciesDoc() is not deterministic")
	}
	if !strings.Contains(first, "| `bpftool` |") ||
		!strings.Contains(first, "`libcap2`, `libelf1t64`, `zlib1g`") {
		t.Fatal("renderDependenciesDoc() omitted the bpftool dependency chain")
	}
	for _, supportingPackage := range []string{"libcap2", "libelf1t64", "libpq5", "libsubid5", "uidmap", "zlib1g"} {
		if strings.Contains(first, "\n| `"+supportingPackage+"` |") {
			t.Errorf("renderDependenciesDoc() rendered supporting package %q as a separate row", supportingPackage)
		}
	}
	if !strings.Contains(first, "`containerd`, `libsubid5`, `runc`, `uidmap`") {
		t.Fatal("renderDependenciesDoc() omitted the kubelet dependency chain")
	}
	if !strings.Contains(first, "__WARNING__: This file is generated by scripts/manifests - do not edit it directly.") ||
		!strings.Contains(first, "## knd - Kubernetes Data-Plane Nodes") {
		t.Fatal("renderDependenciesDoc() omitted its warning or descriptive headings")
	}
	committed, err := os.ReadFile("../../docs/dependencies.md")
	if err != nil {
		t.Fatal(err)
	}
	if first != string(committed) {
		t.Fatal("docs/dependencies.md is stale; run make dependencies")
	}
}

// TestImagesOnlyScope exercises the updater entry point without any upstream
// network access, proving unrelated pins and NAT manifests are preserved.
func TestImagesOnlyScope(t *testing.T) {
	originalSources := sources
	originalDir, originalDoc := *manifestsDir, *dependenciesDoc
	originalImages, originalDeps, originalGroup := *imagesOnly, *dependenciesOnly, *dependencyGroup
	t.Cleanup(func() {
		sources = originalSources
		*manifestsDir, *dependenciesDoc = originalDir, originalDoc
		*imagesOnly, *dependenciesOnly, *dependencyGroup = originalImages, originalDeps, originalGroup
	})
	*manifestsDir = t.TempDir()
	*dependenciesDoc = filepath.Join(*manifestsDir, "dependencies.md")
	*imagesOnly, *dependenciesOnly, *dependencyGroup = true, false, ""
	sources.Images = []ImageSource{{Name: "test", Image: "example/test@sha256:test"}}
	bin := t.TempDir()
	if err := os.WriteFile(filepath.Join(bin, "crane"), []byte("#!/bin/sh\nprintf '%s' '{\"config\":{\"size\":10},\"layers\":[{\"size\":20}]}'\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", bin)
	before := map[string][]byte{}
	for _, kind := range allKinds {
		for _, arch := range Archs {
			m := &Manifest{VMConfig: ManifestVMConfig{
				Version: "keep", Kind: kind,
				OS:           ManifestOS{Name: sources.OS.Name, Arch: arch, Image: &OsImage{Version: "keep", Digest: "sha512:keep", Size: 123}},
				Dependencies: map[string]*DependencyOutput{"user-dependency": {Version: "keep", Size: 456}},
				Images:       []ImageOutput{{Image: "example/keep:1", Digest: "sha256:keep", Size: 789}},
			}}
			if err := writeManifest(kind, arch, m); err != nil {
				t.Fatal(err)
			}
			body, err := os.ReadFile(manifestPath(kind, arch))
			if err != nil {
				t.Fatal(err)
			}
			before[manifestPath(kind, arch)] = body
		}
	}
	if err := run(); err != nil {
		t.Fatal(err)
	}
	for _, kind := range allKinds {
		for _, arch := range Archs {
			m, err := readManifest(kind, arch)
			if err != nil {
				t.Fatal(err)
			}
			if kind != KindNat {
				if len(m.VMConfig.Images) != 2 || m.VMConfig.Images[1].Image != sources.Images[0].Image || m.VMConfig.Images[1].Size <= 30 {
					t.Fatalf("%s/%s: missing resolved image: %+v", kind, arch, m.VMConfig.Images)
				}
				// Remove only the new entry; everything else must round-trip unchanged.
				m.VMConfig.Images = m.VMConfig.Images[:1]
				if err := writeManifest(kind, arch, m); err != nil {
					t.Fatal(err)
				}
			}
			body, err := os.ReadFile(manifestPath(kind, arch))
			if err != nil || !bytes.Equal(body, before[manifestPath(kind, arch)]) {
				t.Fatalf("%s/%s: changed unrelated inventory (read error: %v)", kind, arch, err)
			}
		}
	}
	if _, err := os.Stat(*dependenciesDoc); !os.IsNotExist(err) {
		t.Fatalf("images-only wrote dependency documentation: %v", err)
	}
	if !reflect.DeepEqual(sources.Dependencies, originalSources.Dependencies) {
		t.Fatal("images-only changed the dependency catalogue")
	}
}

// TestLVMInstallProviders checks local-only selection in the shipped manifests.
func TestLVMInstallProviders(t *testing.T) {
	for _, kind := range kubernetesNodeKinds {
		for _, arch := range Archs {
			plan := filepath.Join(t.TempDir(), "plan.sh")
			manifest := "../../manifests/" + kind + ".debian-13." + arch + ".json"
			if out, err := exec.Command("bash", "../manifests.sh", manifest, plan).CombinedOutput(); err != nil {
				t.Fatalf("render: %v %s", err, out)
			}
			for _, provider := range []string{"local", "aws", "google", "proxmox"} {
				out, err := exec.Command("bash", "-c", `PROVIDER_KIND="$2"; source "$1"; printf '%s\n' "${VMCONFIG_DEPENDENCIES_ALL[@]}" "${VMCONFIG_DEPENDENCIES_DEB[@]}"`, "bash", plan, provider).CombinedOutput()
				if err != nil {
					t.Fatal(err)
				}
				for _, name := range []string{"lvm2", "dmeventd", "liblvm2cmd2.03", "libdevmapper-event1.02.1"} {
					if strings.Contains(string(out), name) != (provider == "local") {
						t.Fatalf("%s/%s/%s: incorrect selection of %s", kind, arch, provider, name)
					}
				}
			}
		}
	}
}

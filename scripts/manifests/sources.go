// Podplane <https://podplane.dev>
// Copyright The Podplane Authors
// SPDX-License-Identifier: Apache-2.0
//
// Blueprint of upstream sources for the vmconfig manifest. The exported
// `sources` value has two fields whose shape mirrors the output manifest:
//
//	sources.OS           ↔ deps: vmconfig.os           (Debian cloud image)
//	sources.Dependencies ↔ deps: vmconfig.dependencies (binaries, .debs, tarballs)
//
// Each dependency entry describes:
//   - where to look up the latest version (GitHub repo or apt Packages),
//   - where the binary/.deb/tarball lives (FileURL with $ARCH/$VERSION/$FILE),
//   - how to find its content hash (HashURL + sha256 sidecar, or apt InRelease
//     -> Packages walk verified against a committed signing key in trust/),
//   - which kinds of node it's needed on (knc, knd, or both),
//   - and what artifact type it is (binary, deb, tar.gz).
//
// main.go consumes `sources` and writes the resolved manifests to
// vmconfig/manifests/<kind>.<os>.<arch>.json (one file per kind, OS, and arch).
//
// Upstream signing coverage (last updated August 2026):
//   - kubernetes  : per-binary cosign .sig/.cert on dl.k8s.io
//   - containerd  : sigstore bundle  *-attestation.intoto.jsonl
//   - runc        : GPG .asc per-file, maintainer keys — NO cosign artifacts.
//     Falls back to TLS+sha256sum until upstream adopts cosign or
//     we add the maintainer keys to vmconfig/trust/.
//   - gvisor: SHA-512 sidecars on Google Cloud Storage; no signatures.
//     TLS+sha512 only.
//   - registry: SHA-512 release checksums sidecar. The checksum file has a
//     cosign bundle, but the archives do not have per-artifact signatures.
//   - nstance: signed SHA-512 release checksums (GitHub Actions OIDC).
//   - kube2iam: signed SHA-512 checksums from podplane/kube2iam-binaries.
//   - netsy: release checksum sidecars.
//   - cri-tools, cni-plugins: no consistent upstream signature scheme.
//     TLS-only where release artifacts are available.
//   - debian cloud image: no detached signature published by Debian Cloud Team.
//     TLS-only via cloud.debian.org HTTPS.

package main

const (
	debianRelease     = "trixie" // Debian 13 (OS image + apt sources)
	joolKernelRelease = "6.12.107+deb13"
	joolVersion       = "4.1.15"
)

// debianPackage returns a verified Debian package dependency.
func debianPackage(name, pool string, kinds []string, providers []string, requires ...string) DownloadGroup {
	return DownloadGroup{
		FileURL: "https://deb.debian.org/debian/" + pool + "/$FILE_$VERSION_$ARCH.deb",
		Apt: &AptSource{
			BaseURL:      "https://deb.debian.org/debian/dists/" + debianRelease,
			PackagesPath: "main/binary-$ARCH/Packages.gz",
			Trust:        "debian-archive",
			PoolPath:     pool,
			PackageName:  name,
		},
		HashAlg: "sha256",
		Type:    DepTypeDeb,
		Files:   []FileEntry{{Name: name, Kind: kinds, Providers: providers, Requires: requires}},
	}
}

// localLVM bundles the verified host tools only on local Kubernetes nodes.
func localLVM(name string, requires ...string) DownloadGroup {
	group := debianPackage(name, "pool/main/l/lvm2", kubernetesNodeKinds, []string{"local"}, requires...)
	group.Apt.VersionEpochPrefix = "2:"
	return group
}

// sources is the single blueprint consumed by main.go.
var sources = Sources{
	OS: OsSource{
		Release:       debianRelease,
		Name:          "debian-13",
		BaseURL:       "https://cloud.debian.org/images/cloud/" + debianRelease,
		ImageBasename: "debian-13-genericcloud",
	},
	Dependencies: map[string]DownloadGroup{
		"lvm2":                     localLVM("lvm2", "dmeventd", "libdevmapper-event1.02.1"),
		"dmeventd":                 localLVM("dmeventd", "liblvm2cmd2.03", "libdevmapper-event1.02.1"),
		"liblvm2cmd2.03":           localLVM("liblvm2cmd2.03", "dmeventd", "libdevmapper-event1.02.1"),
		"libdevmapper-event1.02.1": localLVM("libdevmapper-event1.02.1"),
		"jool-modules": {
			Version:      joolVersion,
			FileURL:      "https://github.com/podplane/jool-builds/releases/download/jool-4.1.15-kernel-6.12.107%2Bdeb13/jool-4.1.15-6.12.107%2Bdeb13-$ARCH.tar.gz",
			HashURL:      "https://github.com/podplane/jool-builds/releases/download/jool-4.1.15-kernel-6.12.107%2Bdeb13/SHA256SUMS",
			HashFilename: "jool-4.1.15-6.12.107+deb13-$ARCH.tar.gz",
			HashAlg:      "sha256",
			Type:         DepTypeTarGz,
			CosignBundle: &CosignBundle{
				BundleURL:     "https://github.com/podplane/jool-builds/releases/download/jool-4.1.15-kernel-6.12.107%2Bdeb13/jool-4.1.15-6.12.107%2Bdeb13-$ARCH.sigstore.json",
				ExpectIssuer:  "https://token.actions.githubusercontent.com",
				ExpectSubject: "https://github.com/podplane/jool-builds/.github/workflows/build.yaml@refs/heads/main",
			},
			Files: []FileEntry{{Name: "jool-modules", Kind: []string{KindNat}}},
		},
		"jool-tools":       debianPackage("jool-tools", "pool/main/j/jool", []string{KindNat}, nil, "libnl-3-200", "libnl-genl-3-200"),
		"libedit2":         debianPackage("libedit2", "pool/main/libe/libedit", []string{KindNat}, nil),
		"libjansson4":      debianPackage("libjansson4", "pool/main/j/jansson", []string{KindNat}, nil),
		"libmnl0":          debianPackage("libmnl0", "pool/main/libm/libmnl", []string{KindNat}, nil),
		"libnftables1":     debianPackage("libnftables1", "pool/main/n/nftables", []string{KindNat}, nil, "libjansson4", "libmnl0", "libnftnl11", "libxtables12"),
		"libnftnl11":       debianPackage("libnftnl11", "pool/main/libn/libnftnl", []string{KindNat}, nil, "libmnl0"),
		"libnl-3-200":      debianPackage("libnl-3-200", "pool/main/libn/libnl3", []string{KindNat}, nil),
		"libnl-genl-3-200": debianPackage("libnl-genl-3-200", "pool/main/libn/libnl3", []string{KindNat}, nil, "libnl-3-200"),
		"libxtables12":     debianPackage("libxtables12", "pool/main/i/iptables", []string{KindNat}, nil),
		"nftables":         debianPackage("nftables", "pool/main/n/nftables", []string{KindNat}, nil, "libedit2", "libnftables1"),
		"libcap2":          debianPackage("libcap2", "pool/main/libc/libcap2", kubernetesNodeKinds, nil),
		"libelf1t64":       debianPackage("libelf1t64", "pool/main/e/elfutils", kubernetesNodeKinds, nil, "zlib1g"),
		"zlib1g":           debianPackage("zlib1g", "pool/main/z/zlib", kubernetesNodeKinds, nil),
		"kubernetes": {
			Repo:    "kubernetes/kubernetes",
			FileURL: "https://dl.k8s.io/release/v$VERSION/bin/linux/$ARCH/$FILE",
			HashURL: "https://dl.k8s.io/release/v$VERSION/bin/linux/$ARCH/$FILE.sha256",
			HashAlg: "sha256",
			Type:    DepTypeBinary,
			CosignSigCert: &CosignSigCert{
				SigURL:       "https://dl.k8s.io/release/v$VERSION/bin/linux/$ARCH/$FILE.sig",
				CertURL:      "https://dl.k8s.io/release/v$VERSION/bin/linux/$ARCH/$FILE.cert",
				ExpectIssuer: "https://accounts.google.com",
				// Subject is `krel-staging@…` (NOT `krel-trust@…`, despite some
				// out-of-date docs); confirmed against v1.32.x and v1.36.0
				// release artifacts, including v1.37.0, August 2026.
				ExpectSubject: "krel-staging@k8s-releng-prod.iam.gserviceaccount.com",
			},
			Files: []FileEntry{
				{Name: "kube-apiserver", Kind: []string{KindKnc}},
				{Name: "kube-controller-manager", Kind: []string{KindKnc}},
				{Name: "kube-scheduler", Kind: []string{KindKnc}},
				{Name: "kubelet", Kind: []string{KindKnc, KindKnd, KindNst}, Requires: []string{"containerd", "uidmap"}},
				{Name: "kubectl", Kind: []string{KindKnc}},
			},
		},
		"runc": {
			Repo:    "opencontainers/runc",
			FileURL: "https://github.com/opencontainers/runc/releases/download/v$VERSION/$FILE.$ARCH",
			HashURL: "https://github.com/opencontainers/runc/releases/download/v$VERSION/runc.sha256sum",
			// runc.sha256sum lists every release artifact (runc.amd64,
			// runc.amd64.asc, runc.arm64, …); pick the line whose filename
			// column equals "runc.<arch>".
			HashFilename: "$FILE.$ARCH",
			HashAlg:      "sha256",
			Type:         DepTypeBinary,
			Files:        []FileEntry{{Name: "runc", Kind: containerRuntimeKinds}},
		},
		"gvisor": {
			// The complete release payload: runsc, its containerd shim, and the
			// gvisor-bin sidecars runsc requires beside it. Kubernetes nodes only;
			// nst keeps runc for its trusted host-integrated static Pods.
			Repo:      "google/gvisor",
			TagPrefix: "release-",
			FileURL:   "https://storage.googleapis.com/gvisor/releases/release/$VERSION/$MACHINE/gvisor.tar.zstd",
			HashURL:   "https://storage.googleapis.com/gvisor/releases/release/$VERSION/$MACHINE/gvisor.tar.zstd.sha512",
			HashAlg:   "sha512",
			Type:      DepTypeTarZstd,
			Files:     []FileEntry{{Name: "gvisor", Kind: kubernetesNodeKinds, Requires: []string{"containerd"}}},
		},
		"containerd": {
			Repo:    "containerd/containerd",
			FileURL: "https://github.com/containerd/containerd/releases/download/v$VERSION/containerd-$VERSION-linux-$ARCH.tar.gz",
			HashURL: "https://github.com/containerd/containerd/releases/download/v$VERSION/containerd-$VERSION-linux-$ARCH.tar.gz.sha256sum",
			HashAlg: "sha256",
			Type:    DepTypeTarGz,
			CosignBundle: &CosignBundle{
				BundleURL:     "https://github.com/containerd/containerd/releases/download/v$VERSION/containerd-$VERSION-attestation.intoto.jsonl",
				ExpectIssuer:  "https://token.actions.githubusercontent.com",
				ExpectSubject: "https://github.com/containerd/containerd/.github/workflows/release.yml@refs/tags/v$VERSION",
			},
			Files: []FileEntry{{Name: "containerd", Kind: containerRuntimeKinds, Requires: []string{"runc"}}},
		},
		"cri-tools": {
			Repo:    "kubernetes-sigs/cri-tools",
			FileURL: "https://github.com/kubernetes-sigs/cri-tools/releases/download/v$VERSION/$FILE-v$VERSION-linux-$ARCH.tar.gz",
			HashURL: "https://github.com/kubernetes-sigs/cri-tools/releases/download/v$VERSION/$FILE-v$VERSION-linux-$ARCH.tar.gz.sha256",
			HashAlg: "sha256",
			Type:    DepTypeTarGz,
			Files:   []FileEntry{{Name: "crictl", Kind: containerRuntimeKinds}},
		},
		"cni-plugins": {
			Repo:    "containernetworking/plugins",
			FileURL: "https://github.com/containernetworking/plugins/releases/download/v$VERSION/$FILE-linux-$ARCH-v$VERSION.tgz",
			HashURL: "https://github.com/containernetworking/plugins/releases/download/v$VERSION/$FILE-linux-$ARCH-v$VERSION.tgz.sha256",
			HashAlg: "sha256",
			Type:    DepTypeTarGz,
			Files:   []FileEntry{{Name: "cni-plugins", Kind: kubernetesNodeKinds}},
		},
		"libpq5": {
			// libpq5: runtime dependency for fluent-bit. Debian trixie ships
			// postgresql-17 as the default.
			FileURL: "https://deb.debian.org/debian/pool/main/p/postgresql-17/libpq5_$VERSION_$ARCH.deb",
			Apt: &AptSource{
				BaseURL:      "https://deb.debian.org/debian/dists/" + debianRelease,
				PackagesPath: "main/binary-$ARCH/Packages.gz",
				Trust:        "debian-archive",
				PoolPath:     "pool/main/p/postgresql-17",
				PackageName:  "libpq5",
			},
			HashAlg: "sha256",
			Type:    DepTypeDeb,
			Files:   []FileEntry{{Name: "libpq5", Kind: allKinds}},
		},
		"uidmap": {
			// uidmap: runtime dependency for kubelet (getsubids).
			FileURL: "https://deb.debian.org/debian/pool/main/s/shadow/uidmap_$VERSION_$ARCH.deb",
			Apt: &AptSource{
				BaseURL:            "https://deb.debian.org/debian/dists/" + debianRelease,
				PackagesPath:       "main/binary-$ARCH/Packages.gz",
				Trust:              "debian-archive",
				PoolPath:           "pool/main/s/shadow",
				PackageName:        "uidmap",
				VersionEpochPrefix: "1:",
			},
			HashAlg: "sha256",
			Type:    DepTypeDeb,
			Files:   []FileEntry{{Name: "uidmap", Kind: containerRuntimeKinds, Requires: []string{"libsubid5"}}},
		},
		"libsubid5": {
			// libsubid5: runtime dependency for kubelet (getsubids). Debian
			// trixie ships libsubid5 (Ubuntu noble shipped libsubid4).
			FileURL: "https://deb.debian.org/debian/pool/main/s/shadow/libsubid5_$VERSION_$ARCH.deb",
			Apt: &AptSource{
				BaseURL:            "https://deb.debian.org/debian/dists/" + debianRelease,
				PackagesPath:       "main/binary-$ARCH/Packages.gz",
				Trust:              "debian-archive",
				PoolPath:           "pool/main/s/shadow",
				PackageName:        "libsubid5",
				VersionEpochPrefix: "1:",
			},
			HashAlg: "sha256",
			Type:    DepTypeDeb,
			Files:   []FileEntry{{Name: "libsubid5", Kind: containerRuntimeKinds}},
		},
		"fluent-bit": {
			Repo:    "fluent/fluent-bit",
			FileURL: "https://packages.fluentbit.io/debian/" + debianRelease + "/pool/main/f/fluent-bit/fluent-bit_$VERSION_$ARCH.deb",
			Apt: &AptSource{
				BaseURL:      "https://packages.fluentbit.io/debian/" + debianRelease + "/dists/" + debianRelease,
				PackagesPath: "main/binary-$ARCH/Packages",
				Trust:        "fluentbit",
				PoolPath:     "pool/main/f/fluent-bit",
				PackageName:  "fluent-bit",
			},
			HashAlg: "sha256",
			Type:    DepTypeDeb,
			Files:   []FileEntry{{Name: "fluent-bit", Kind: allKinds, Requires: []string{"libpq5"}}},
		},
		"kube2iam": {
			Repo:         "podplane/kube2iam-binaries",
			FileURL:      "https://github.com/podplane/kube2iam-binaries/releases/download/$VERSION/kube2iam_$VERSION_linux_$ARCH.tar.gz",
			HashURL:      "https://github.com/podplane/kube2iam-binaries/releases/download/$VERSION/kube2iam_$VERSION_checksums.txt",
			HashFilename: "kube2iam_$VERSION_linux_$ARCH.tar.gz",
			HashAlg:      "sha512",
			Type:         DepTypeTarGz,
			HashCosignBundle: &CosignBundle{
				BundleURL:     "https://github.com/podplane/kube2iam-binaries/releases/download/$VERSION/kube2iam_$VERSION_checksums.txt.bundle",
				ExpectIssuer:  "https://token.actions.githubusercontent.com",
				ExpectSubject: "https://github.com/podplane/kube2iam-binaries/.github/workflows/release.yml@refs/heads/main",
			},
			Files: []FileEntry{{Name: "kube2iam", Kind: kubernetesNodeKinds, Providers: []string{"aws"}}},
		},
		"netsy": {
			Repo:         "netsy-dev/netsy",
			FileURL:      "https://github.com/netsy-dev/netsy/releases/download/v$VERSION/$FILE_$VERSION_linux_$ARCH.tar.gz",
			HashURL:      "https://github.com/netsy-dev/netsy/releases/download/v$VERSION/netsy_$VERSION_checksums.txt",
			HashFilename: "$FILE_$VERSION_linux_$ARCH.tar.gz",
			HashAlg:      "sha512",
			Type:         DepTypeTarGz,
			Files:        []FileEntry{{Name: "netsy", Kind: []string{KindKnc}}},
		},
		"nstance": {
			Repo:         "nstance-dev/nstance",
			FileURL:      "https://github.com/nstance-dev/nstance/releases/download/v$VERSION/$FILE_$VERSION_linux_$ARCH.tar.gz",
			HashURL:      "https://github.com/nstance-dev/nstance/releases/download/v$VERSION/nstance_$VERSION_checksums.txt",
			HashFilename: "$FILE_$VERSION_linux_$ARCH.tar.gz",
			HashAlg:      "sha512",
			Type:         DepTypeTarGz,
			HashCosignBundle: &CosignBundle{
				BundleURL:     "https://github.com/nstance-dev/nstance/releases/download/v$VERSION/nstance_$VERSION_checksums.txt.bundle",
				ExpectIssuer:  "https://token.actions.githubusercontent.com",
				ExpectSubject: "https://github.com/nstance-dev/nstance/.github/workflows/release.yml@refs/tags/v$VERSION",
			},
			Files: []FileEntry{
				{Name: "nstance-agent", Kind: nstanceAgentKinds},
				{Name: "nstance-server", Kind: []string{KindNst}},
			},
		},
		"bpftool": {
			FileURL: "https://deb.debian.org/debian/pool/main/l/linux/bpftool_$VERSION_$ARCH.deb",
			Apt: &AptSource{
				BaseURL:      "https://deb.debian.org/debian/dists/" + debianRelease,
				PackagesPath: "main/binary-$ARCH/Packages.gz",
				Trust:        "debian-archive",
				PoolPath:     "pool/main/l/linux",
				PackageName:  "bpftool",
			},
			HashAlg: "sha256",
			Type:    DepTypeDeb,
			Files: []FileEntry{{
				Name: "bpftool", Kind: kubernetesNodeKinds, Requires: []string{"libcap2", "libelf1t64", "zlib1g"},
			}},
		},
		"registry": {
			Repo:         "podplane/registry",
			FileURL:      "https://github.com/podplane/registry/releases/download/v$VERSION/$FILE_$VERSION_linux_$ARCH.tar.gz",
			HashURL:      "https://github.com/podplane/registry/releases/download/v$VERSION/registry_$VERSION_checksums.txt",
			HashFilename: "$FILE_$VERSION_linux_$ARCH.tar.gz",
			HashAlg:      "sha512",
			Type:         DepTypeTarGz,
			Files:        []FileEntry{{Name: "registry", Kind: containerRuntimeKinds}},
		},
	},
	Images: []ImageSource{
		{Name: "cloudflared", Image: "cloudflare/cloudflared:2026.10.0@sha256:9b49eed8f62806d5d45ddf59ecefb5710429598ea6d3fcccd2af938f621b2b07"},
		// note: the pause image may change with each containerd version
		// e.g. https://github.com/containerd/containerd/blob/v2.3.1/internal/cri/config/config.go#L76
		{Name: "pod-sandbox", Image: "registry.k8s.io/pause:3.10.2"},
	},
}

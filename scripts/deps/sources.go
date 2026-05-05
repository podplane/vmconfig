// Podplane <https://podplane.dev>
// Copyright 2026 Nadrama Pty Ltd
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
// vmconfig/deps/<kind>.<os>.<arch>.json (one file per kind, OS, and arch).
//
// Upstream signing coverage (last updated April 2026):
//   - kubernetes  : per-binary cosign .sig/.cert on dl.k8s.io
//   - containerd  : sigstore bundle  *-attestation.intoto.jsonl
//   - runc        : GPG .asc per-file, maintainer keys — NO cosign artifacts.
//     Falls back to TLS+sha256sum until upstream adopts cosign or
//     we add the maintainer keys to vmconfig/trust/.
//   - registry (distribution/distribution): ships unsigned `*.provenance.json`
//     (plain in-toto Statement, no signature material) — NO cosign artifacts.
//     TLS-only.
//   - cri-tools, cni-plugins: no consistent upstream signature scheme. TLS-only.
//   - debian cloud image: no detached signature published by Debian Cloud Team.
//     TLS-only via cloud.debian.org HTTPS.

package main

const debianRelease = "trixie" // Debian 13 (OS image + apt sources)

// sources is the single blueprint consumed by main.go.
var sources = Sources{
	OS: OsSource{
		Release:       debianRelease,
		Name:          "debian-13",
		BaseURL:       "https://cloud.debian.org/images/cloud/" + debianRelease,
		ImageBasename: "debian-13-genericcloud",
	},
	Dependencies: map[string]DownloadGroup{
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
				// release artifacts, April 2026.
				ExpectSubject: "krel-staging@k8s-releng-prod.iam.gserviceaccount.com",
			},
			Files: []FileEntry{
				{Name: "kube-apiserver", Kind: []string{KindKnc}},
				{Name: "kube-controller-manager", Kind: []string{KindKnc}},
				{Name: "kube-scheduler", Kind: []string{KindKnc}},
				{Name: "kubelet", Kind: []string{KindKnc, KindKnd}},
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
			Files:        []FileEntry{{Name: "runc", Kind: allKinds}},
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
			Files: []FileEntry{{Name: "containerd", Kind: allKinds}},
		},
		"cri-tools": {
			Repo:    "kubernetes-sigs/cri-tools",
			FileURL: "https://github.com/kubernetes-sigs/cri-tools/releases/download/v$VERSION/$FILE-v$VERSION-linux-$ARCH.tar.gz",
			HashURL: "https://github.com/kubernetes-sigs/cri-tools/releases/download/v$VERSION/$FILE-v$VERSION-linux-$ARCH.tar.gz.sha256",
			HashAlg: "sha256",
			Type:    DepTypeTarGz,
			Files:   []FileEntry{{Name: "crictl", Kind: allKinds}},
		},
		"cni-plugins": {
			Repo:    "containernetworking/plugins",
			FileURL: "https://github.com/containernetworking/plugins/releases/download/v$VERSION/$FILE-linux-$ARCH-v$VERSION.tgz",
			HashURL: "https://github.com/containernetworking/plugins/releases/download/v$VERSION/$FILE-linux-$ARCH-v$VERSION.tgz.sha256",
			HashAlg: "sha256",
			Type:    DepTypeTarGz,
			Files:   []FileEntry{{Name: "cni-plugins", Kind: allKinds}},
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
			Files:   []FileEntry{{Name: "uidmap", Kind: allKinds}},
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
			Files:   []FileEntry{{Name: "libsubid5", Kind: allKinds}},
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
			Files:   []FileEntry{{Name: "fluent-bit", Kind: allKinds}},
		},
		// "registry" is the OCI/Docker registry binary published by the
		// CNCF distribution/distribution project. We expose it under its
		// upstream artifact name ("registry"); the word "distribution"
		// appears only where the upstream repo path forces it.
		"registry": {
			Repo:    "distribution/distribution",
			FileURL: "https://github.com/distribution/distribution/releases/download/v$VERSION/$FILE_$VERSION_linux_$ARCH.tar.gz",
			HashURL: "https://github.com/distribution/distribution/releases/download/v$VERSION/$FILE_$VERSION_linux_$ARCH.tar.gz.sha256",
			HashAlg: "sha256",
			Type:    DepTypeTarGz,
			Files:   []FileEntry{{Name: "registry", Kind: []string{KindKnc}}},
		},
	},
}

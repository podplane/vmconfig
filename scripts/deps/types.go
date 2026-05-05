// Podplane <https://podplane.dev>
// Copyright 2026 Nadrama Pty Ltd
// SPDX-License-Identifier: Apache-2.0
//
// Domain types shared between sources.go and main.go.

package main

// ----- enums -----

const (
	ArchAmd64 = "amd64"
	ArchArm64 = "arm64"
)

var Archs = []string{ArchAmd64, ArchArm64}

const (
	KindKnc = "knc"
	KindKnd = "knd"
)

var allKinds = []string{KindKnc, KindKnd}

// DepType is the kind of artifact pointed at by a manifest entry.
type DepType string

const (
	DepTypeBinary DepType = "binary"
	DepTypeDeb    DepType = "deb"
	DepTypeTarGz  DepType = "tar.gz"
	DepTypeQcow2  DepType = "qcow2"
)

// ----- catalogue (input) -----

// FileEntry is one binary/.deb/tarball that a DownloadGroup produces.
type FileEntry struct {
	Name string
	Kind []string
}

// AptSource describes how to fetch and verify an apt Packages index, and how
// to locate the per-package version + sha256 within that verified payload.
//
// The Packages index is fetched via a verified chain:
//
//	InRelease (GPG-signed)  ->  expected SHA256 of Packages(.gz)  ->  Packages
//
// The verified Packages contents then provide both the package version and
// the .deb digest used in the manifest.
//
// PoolPath/PackageName/VersionEpochPrefix used to live as closure factories
// in TypeScript (createAptHashPreprocess, createAptVersionFromHash). They are
// pure data so we encode them directly here; the engine does the lookups.
type AptSource struct {
	// dists/<suite>/ base URL, e.g. "https://deb.debian.org/debian/dists/trixie".
	BaseURL string
	// Path within dists/<suite>/ that points to the Packages file. May contain
	// $ARCH. Both compressed (.gz) and uncompressed forms are supported; the
	// form is auto-detected by extension.
	PackagesPath string
	// Trust keyring filename (without extension) under vmconfig/trust/. The
	// InRelease file at <BaseURL>/InRelease must verify against this keyring.
	Trust string
	// Pool path within the apt repo, e.g. "pool/main/p/postgresql-17". Used
	// to construct the expected `Filename:` line in the Packages index.
	PoolPath string
	// Package name as it appears on the `Package:` and `Filename:` lines.
	PackageName string
	// Optional epoch prefix (e.g. "1:") to strip from `Version:` values
	// before they appear in the manifest and in the .deb filename.
	VersionEpochPrefix string
}

// CosignSigCert is the per-artifact `.sig` + `.cert` cosign verification
// layout (e.g. kubernetes on dl.k8s.io). All URL templates may use $ARCH,
// $VERSION (no leading "v"), and $FILE.
type CosignSigCert struct {
	SigURL               string
	CertURL              string
	ExpectIssuer         string
	ExpectSubject        string
	ExpectSubjectIsRegex bool
}

// CosignBundle is the sigstore bundle (`.sigstore.json` /
// `*-attestation.intoto.jsonl`) cosign verification layout, where one
// envelope signs every asset in the release (e.g. containerd's release
// attestation).
type CosignBundle struct {
	BundleURL            string
	ExpectIssuer         string
	ExpectSubject        string
	ExpectSubjectIsRegex bool
}

// DownloadGroup is one entry under sources.Dependencies.
//
// Mutually exclusive fields:
//   - Repo  vs  (Apt + an apt-derived version): version source.
//   - HashURL  vs  Apt: digest source.
//   - CosignSigCert  vs  CosignBundle: cosign verification layout.
type DownloadGroup struct {
	// GitHub repo for "latest release" version lookup.
	Repo string
	// URL templates. Vars: $ARCH, $VERSION (without leading "v"), $FILE.
	FileURL string
	// Direct hash URL for non-apt groups (GitHub-released tarballs, sha256
	// sidecars). Mutually exclusive with Apt.
	HashURL string
	// Optional. For multi-line sha256sum-style files, the expected filename
	// (column 2) of the line whose hash we want. Template; supports
	// $ARCH / $VERSION / $FILE. When unset, the file is assumed to contain
	// a single hash line.
	HashFilename string
	// Hash algorithm — currently always "sha256" for dependencies.
	HashAlg string
	Type    DepType
	// Apt source for verified-walk groups (libpq5, uidmap, libsubid5,
	// fluent-bit). Mutually exclusive with HashURL.
	Apt *AptSource
	// Optional cosign keyless verification. Set at most one of these two.
	CosignSigCert *CosignSigCert
	CosignBundle  *CosignBundle
	Files         []FileEntry
}

// OsSource describes the OS image source. main.go uses this to compute the
// JSON sidecar URL (for version discovery), the versioned qcow2 URL, and the
// SHA512SUMS URL.
type OsSource struct {
	// Distribution release codename, e.g. "trixie".
	Release string
	// Manifest field: vmconfig.os.name, e.g. "debian-13".
	Name string
	// Base URL for the cloud image tree, e.g.
	// "https://cloud.debian.org/images/cloud/trixie".
	BaseURL string
	// Image filename stem (no arch, no version), e.g. "debian-13-nocloud".
	ImageBasename string
}

// Sources is the top-level blueprint. Field order mirrors the output manifest
// (`vmconfig.os` then `vmconfig.dependencies`) so the input/output
// relationship is easy to follow.
type Sources struct {
	OS           OsSource
	Dependencies map[string]DownloadGroup
}

// ----- manifest (output) -----

// BootFile describes the location and integrity of a boot artifact (kernel
// or initrd) within the OS image's filesystem.
type BootFile struct {
	Partition int    `json:"partition"`
	Path      string `json:"path"`
	Digest    string `json:"digest"`
}

// Boot holds direct-boot metadata extracted from the OS image. The CLI uses
// this to launch QEMU with -kernel/-initrd/-append, bypassing firmware/GRUB.
type Boot struct {
	Cmdline string   `json:"cmdline"`
	Kernel  BootFile `json:"kernel"`
	Initrd  BootFile `json:"initrd"`
}

// OsImage is the resolved OS image entry written to vmconfig.os.image.
type OsImage struct {
	Version string  `json:"version"`
	URL     string  `json:"url"`
	Type    DepType `json:"type"`
	// OCI-style digest: "<algo>:<hex>", e.g. "sha512:fa527f8a…".
	Digest string `json:"digest"`
}

// DependencyOutput is one resolved entry under vmconfig.dependencies.
//
// Per-dep `kind` is intentionally absent from the output schema: each
// per-kind, per-arch manifest already targets a single kind, so the
// dependency list itself is implicitly scoped. The input catalogue
// (FileEntry.Kind in sources.go) still carries kind metadata so a single
// catalogue can drive both kinds' manifests, but it is filtered out before
// being written to disk.
type DependencyOutput struct {
	Version string  `json:"version"`
	URL     string  `json:"url"`
	Type    DepType `json:"type"`
	// OCI-style digest: "<algo>:<hex>", e.g. "sha256:f622843…".
	Digest string `json:"digest"`
}

// ManifestOS is the `vmconfig.os` object.
type ManifestOS struct {
	Name  string   `json:"name"`
	Arch  string   `json:"arch"`
	Image *OsImage `json:"image,omitempty"`
	Boot  *Boot    `json:"boot,omitempty"`
}

// ManifestVMConfig is the `vmconfig` object.
//
// Kind is a single string (knc | knd) since each manifest is scoped to
// one kind, OS, and arch; install.sh reads it via `jq -r '.vmconfig.kind'`.
type ManifestVMConfig struct {
	Version      string                       `json:"version"`
	Kind         string                       `json:"kind"`
	OS           ManifestOS                   `json:"os"`
	Dependencies map[string]*DependencyOutput `json:"dependencies"`
}

// Manifest is the on-disk schema for vmconfig/deps/<os>.<arch>.json.
type Manifest struct {
	VMConfig ManifestVMConfig `json:"vmconfig"`
}

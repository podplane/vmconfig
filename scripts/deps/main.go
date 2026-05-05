// Podplane <https://podplane.dev>
// Copyright 2026 Nadrama Pty Ltd
// SPDX-License-Identifier: Apache-2.0
//
// Generates vmconfig dependency manifests at
// vmconfig/deps/<kind>.<os>.<arch>.json.
//
// One file is produced per VM kind and CPU architecture. Each
// manifest lists the OS image and every binary/package vmconfig needs for
// that kind, with a fully-resolved URL and content hash per dependency.
// The Podplane CLI consumes these manifests to populate its local package
// cache and serve packages to VMs, and also to build out the cloud-init
// user-data scripts generated during cluster creation.
//
// The script is incremental and idempotent:
//  1. For each (kind, arch), a base manifest (with empty `dependencies` and
//     no `os.image`) is written if no file exists yet.
//  2. The OS image and each dependency is then resolved one at a time. After
//     every successful resolution, the manifest file is rewritten with the
//     new entry appended.
//
// If the script fails mid-run, simply re-run it: only missing entries are
// fetched. To force a full refresh delete the manifest files; to refresh
// specific entries delete them from the JSON and re-run.

package main

import (
	"bytes"
	"compress/gzip"
	"crypto/sha256"
	"crypto/sha512"
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"hash"
	"io"
	"log"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/diskfs/go-diskfs"
)

var (
	depsDir  = flag.String("deps-dir", "./deps", "Directory holding the manifest files (vmconfig/deps).")
	trustDir = flag.String("trust-dir", "./trust", "Directory holding the committed signing keys (vmconfig/trust).")
	cacheDir = flag.String("cache-dir", "./cache", "Directory for cached large downloads.")
)

// ----- generic helpers -----

func fetchText(url string) (string, error) {
	res, err := http.Get(url)
	if err != nil {
		return "", err
	}
	defer res.Body.Close()
	if res.StatusCode != 200 {
		return "", fmt.Errorf("failed to fetch %s: %s", url, res.Status)
	}
	body, err := io.ReadAll(res.Body)
	if err != nil {
		return "", fmt.Errorf("read %s: %w", url, err)
	}
	return string(body), nil
}

// fetchTextMaybeGzipped fetches a URL, verifies its sha256 against expected,
// and gunzips if it ends in ".gz". Used for the apt Packages walk so the same
// helper handles both compressed and uncompressed forms.
func fetchTextMaybeGzipped(url, expectedSha256 string, gzipped bool) (string, error) {
	res, err := http.Get(url)
	if err != nil {
		return "", err
	}
	defer res.Body.Close()
	if res.StatusCode != 200 {
		return "", fmt.Errorf("failed to fetch %s: %s", url, res.Status)
	}
	raw, err := io.ReadAll(res.Body)
	if err != nil {
		return "", fmt.Errorf("read %s: %w", url, err)
	}
	if got := sha256Hex(raw); got != expectedSha256 {
		return "", fmt.Errorf("packages sha256 mismatch for %s: expected %s, got %s",
			url, expectedSha256, got)
	}
	if gzipped {
		gr, err := gzip.NewReader(bytes.NewReader(raw))
		if err != nil {
			return "", fmt.Errorf("gunzip %s: %w", url, err)
		}
		defer gr.Close()
		out, err := io.ReadAll(gr)
		if err != nil {
			return "", fmt.Errorf("gunzip read %s: %w", url, err)
		}
		return string(out), nil
	}
	return string(raw), nil
}

// Streaming download. For artifacts > progressThreshold bytes we read the
// response body and print a progress line at most once every
// progressIntervalMs, so large downloads (kubernetes binaries are 50–90 MB
// each) don't appear stalled to the user or to wrappers like `make` that
// watch stdout for activity.
const (
	progressThreshold  = 1 << 20 // 1 MiB
	progressIntervalMs = 5_000 * time.Millisecond
)

// progressReader wraps an io.Reader and logs cumulative progress every
// progressIntervalMs while bytes flow through it. Total may be zero, in which
// case progress is logged in MiB only.
type progressReader struct {
	r        io.Reader
	total    int64
	received int64
	label    string
	start    time.Time
	lastLog  time.Time
}

func (p *progressReader) Read(buf []byte) (int, error) {
	n, err := p.r.Read(buf)
	p.received += int64(n)
	now := time.Now()
	if now.Sub(p.lastLog) >= progressIntervalMs {
		recvMb := float64(p.received) / 1024 / 1024
		elapsed := now.Sub(p.start).Seconds()
		if p.total > 0 {
			totalMb := float64(p.total) / 1024 / 1024
			pct := float64(p.received) / float64(p.total) * 100
			fmt.Printf("      %s: %.1f/%.1f MiB (%.0f%%) — %.0fs\n",
				p.label, recvMb, totalMb, pct, elapsed)
		} else {
			fmt.Printf("      %s: %.1f MiB — %.0fs\n", p.label, recvMb, elapsed)
		}
		p.lastLog = now
	}
	return n, err
}

func renderTemplate(tmpl string, arch, version, file string) string {
	r := strings.NewReplacer(
		"$ARCH", arch,
		"$VERSION", strings.TrimPrefix(version, "v"),
		"$FILE", file,
	)
	return r.Replace(tmpl)
}

func sha256Hex(data []byte) string {
	sum := sha256.Sum256(data)
	return hex.EncodeToString(sum[:])
}

func digestHash(algo string) (hash.Hash, error) {
	switch algo {
	case "sha256":
		return sha256.New(), nil
	case "sha512":
		return sha512.New(), nil
	default:
		return nil, fmt.Errorf("unsupported digest algorithm %q", algo)
	}
}

func splitDigest(digest string) (algo, hexDigest string, err error) {
	algo, hexDigest, ok := strings.Cut(strings.ToLower(strings.TrimSpace(digest)), ":")
	if !ok || algo == "" || hexDigest == "" {
		return "", "", fmt.Errorf("invalid digest %q; expected <algo>:<hex>", digest)
	}
	if _, err := digestHash(algo); err != nil {
		return "", "", err
	}
	return algo, hexDigest, nil
}

func fileDigest(path, expectedDigest string) (string, error) {
	algo, _, err := splitDigest(expectedDigest)
	if err != nil {
		return "", err
	}
	h, err := digestHash(algo)
	if err != nil {
		return "", err
	}
	f, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer f.Close()
	if _, err := io.Copy(h, f); err != nil {
		return "", fmt.Errorf("hash %s: %w", path, err)
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

func cachedDownload(urlString, label, arch, name, expectedDigest string) (string, error) {
	algo, hexDigest, err := splitDigest(expectedDigest)
	if err != nil {
		return "", err
	}
	ext := cacheFileExt(urlString)
	dir := filepath.Join(*cacheDir, arch, name)
	cachePath := filepath.Join(dir, fmt.Sprintf("%s-%s%s", algo, hexDigest, ext))

	if got, err := fileDigest(cachePath, expectedDigest); err == nil {
		if got == hexDigest {
			fmt.Printf("[%s]   using cached %s: %s\n", arch, name, cachePath)
			return cachePath, nil
		}
		fmt.Printf("[%s]   replacing cached %s: digest mismatch\n", arch, name)
		if err := os.Remove(cachePath); err != nil {
			return "", fmt.Errorf("remove invalid cache file %s: %w", cachePath, err)
		}
	} else if !os.IsNotExist(err) {
		return "", err
	}

	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", err
	}
	tmp, err := os.CreateTemp(dir, ".download-*")
	if err != nil {
		return "", err
	}
	tmpPath := tmp.Name()
	defer os.Remove(tmpPath)

	res, err := http.Get(urlString)
	if err != nil {
		tmp.Close()
		return "", err
	}
	defer res.Body.Close()
	if res.StatusCode != 200 {
		tmp.Close()
		return "", fmt.Errorf("failed to fetch %s: %s", urlString, res.Status)
	}

	h, err := digestHash(algo)
	if err != nil {
		tmp.Close()
		return "", err
	}
	r := io.Reader(res.Body)
	if res.ContentLength <= 0 || res.ContentLength >= progressThreshold {
		r = &progressReader{
			r:       res.Body,
			total:   res.ContentLength,
			label:   label,
			start:   time.Now(),
			lastLog: time.Now(),
		}
	}
	if _, err := io.Copy(io.MultiWriter(tmp, h), r); err != nil {
		tmp.Close()
		return "", fmt.Errorf("download %s: %w", urlString, err)
	}
	if err := tmp.Close(); err != nil {
		return "", err
	}

	got := hex.EncodeToString(h.Sum(nil))
	if got != hexDigest {
		return "", fmt.Errorf("download digest mismatch for %s: expected %s, got %s", urlString, hexDigest, got)
	}
	if err := os.Rename(tmpPath, cachePath); err != nil {
		return "", err
	}
	return cachePath, nil
}

func cacheFileExt(urlString string) string {
	name := urlString
	if u, err := url.Parse(urlString); err == nil {
		name = path.Base(u.Path)
	} else {
		name = strings.Split(name, "?")[0]
		name = strings.TrimRight(name, "/")
		name = name[strings.LastIndex(name, "/")+1:]
	}
	for _, ext := range []string{".tar.gz", ".qcow2", ".tgz", ".deb", ".zip", ".gz"} {
		if strings.HasSuffix(name, ext) {
			return ext
		}
	}
	return filepath.Ext(name)
}

var installHints = map[string]string{
	"gpg":      "macOS: `brew install gnupg`  •  Debian/Ubuntu: `apt install gnupg`",
	"cosign":   "macOS: `brew install cosign`  •  Debian/Ubuntu: see https://docs.sigstore.dev/cosign/system_config/installation/",
	"qemu-img": "macOS: `brew install qemu`  •  Debian/Ubuntu: `apt install qemu-utils`",
}

func requireCommands(cmds ...string) error {
	var missing []string
	for _, c := range cmds {
		if _, err := exec.LookPath(c); err != nil {
			missing = append(missing, c)
		}
	}
	if len(missing) == 0 {
		return nil
	}
	var hints []string
	for _, c := range missing {
		hint := installHints[c]
		if hint == "" {
			hint = "install via package manager"
		}
		hints = append(hints, fmt.Sprintf("  - %s: %s", c, hint))
	}
	return fmt.Errorf("required commands not found in PATH: %s\n%s",
		strings.Join(missing, ", "), strings.Join(hints, "\n"))
}

// ----- OS image (Debian 13 nocloud qcow2) -----

func fetchOsImage(arch string) (*OsImage, error) {
	// The `latest/` directory holds unversioned symlinks to the current build
	// — useful for discovery but unsuitable as a stable manifest URL because
	// the file (and its hash) changes when Debian publishes a new build. We
	// use `latest/<arch>.json` only to learn the current version, then anchor
	// the manifest to the immutable, versioned URL under `<version>/`.
	infoURL := fmt.Sprintf("%s/latest/%s-%s.json",
		sources.OS.BaseURL, sources.OS.ImageBasename, arch)
	body, err := fetchText(infoURL)
	if err != nil {
		return nil, err
	}
	var parsed struct {
		Items []struct {
			Data struct {
				Info struct {
					Version string `json:"version"`
				} `json:"info"`
			} `json:"data"`
		} `json:"items"`
	}
	if err := json.Unmarshal([]byte(body), &parsed); err != nil {
		return nil, fmt.Errorf("parse %s: %w", infoURL, err)
	}
	if len(parsed.Items) == 0 || parsed.Items[0].Data.Info.Version == "" {
		return nil, fmt.Errorf("could not extract version from %s", infoURL)
	}
	version := parsed.Items[0].Data.Info.Version

	filename := fmt.Sprintf("%s-%s-%s.qcow2", sources.OS.ImageBasename, arch, version)
	fileURL := fmt.Sprintf("%s/%s/%s", sources.OS.BaseURL, version, filename)
	hashURL := fmt.Sprintf("%s/%s/SHA512SUMS", sources.OS.BaseURL, version)

	// SHA512SUMS lines are "<hash>  <filename>".
	sums, err := fetchText(hashURL)
	if err != nil {
		return nil, err
	}
	var hash string
	for _, line := range strings.Split(sums, "\n") {
		if strings.HasSuffix(strings.TrimSpace(line), "  "+filename) {
			parts := strings.Fields(line)
			if len(parts) >= 1 {
				hash = parts[0]
				break
			}
		}
	}
	if hash == "" {
		return nil, fmt.Errorf("could not find %s in %s", filename, hashURL)
	}

	return &OsImage{
		Version: version,
		URL:     fileURL,
		Type:    DepTypeQcow2,
		Digest:  "sha512:" + hash,
	}, nil
}

// ----- GitHub repo "latest release" version -----

func fetchRepoVersion(name, repo string) (string, error) {
	if repo == "" {
		return "", fmt.Errorf("no GitHub repo configured for %s", name)
	}
	body, err := fetchText("https://api.github.com/repos/" + repo + "/releases/latest")
	if err != nil {
		return "", fmt.Errorf("unable to fetch latest version for %s: %w", name, err)
	}
	var data struct {
		TagName string `json:"tag_name"`
	}
	if err := json.Unmarshal([]byte(body), &data); err != nil {
		return "", fmt.Errorf("parse latest release for %s: %w", name, err)
	}
	if data.TagName == "" {
		return "", fmt.Errorf("unable to find latest version for %s", name)
	}
	return data.TagName, nil
}

// ----- apt InRelease verified fetch -----
//
// For an `apt` group:
//  1. Fetch <BaseURL>/InRelease  (clearsigned).
//  2. Verify with `gpg` against trust/<Trust>.asc, using a throwaway
//     --homedir so the user's ~/.gnupg is never touched.
//  3. Find the SHA256 of <PackagesPath> inside the verified InRelease body.
//  4. Fetch <BaseURL>/<PackagesPath>; verify its sha256 matches step 3.
//  5. Decompress if .gz; return contents.
//
// The verified Packages contents feed both the version lookup and the per-
// package sha256 lookup.

func gpgVerify(inRelease, trustName string) (string, error) {
	ascPath := filepath.Join(*trustDir, trustName+".asc")
	if _, err := os.Stat(ascPath); err != nil {
		return "", fmt.Errorf("trust key not found: %s. Run scripts/trust first.", ascPath)
	}
	tmpDir, err := os.MkdirTemp("", "vmconfig-trust-")
	if err != nil {
		return "", err
	}
	defer os.RemoveAll(tmpDir)

	sigPath := filepath.Join(tmpDir, "InRelease")
	if err := os.WriteFile(sigPath, []byte(inRelease), 0o600); err != nil {
		return "", err
	}

	// Import the committed ASCII-armored key into a throwaway homedir so the
	// user's ~/.gnupg is never touched and the imported key can't outlive
	// this verification.
	importCmd := exec.Command("gpg", "--homedir", tmpDir, "--quiet", "--import", ascPath)
	var importErr bytes.Buffer
	importCmd.Stderr = &importErr
	if err := importCmd.Run(); err != nil {
		return "", fmt.Errorf("gpg --import %s failed: %v\n%s", ascPath, err, importErr.String())
	}

	// --decrypt so gpg writes the cryptographically verified plaintext to
	// stdout. --status-fd 2 sends machine-readable status to stderr, leaving
	// stdout for plaintext. Apply apt's policy: at least one GOODSIG against
	// our key and no BADSIG. Multi-signed InRelease files (key rotation
	// overlap) include signatures from keys we don't have; those produce
	// NO_PUBKEY/ERRSIG which we ignore.
	verifyCmd := exec.Command("gpg", "--homedir", tmpDir, "--status-fd", "2", "--decrypt", sigPath)
	var verifyOut, verifyStatus bytes.Buffer
	verifyCmd.Stdout = &verifyOut
	verifyCmd.Stderr = &verifyStatus
	_ = verifyCmd.Run() // exit code ignored; we judge via GOODSIG/BADSIG counts

	var goodSigs, badSigs int
	for _, line := range strings.Split(verifyStatus.String(), "\n") {
		switch {
		case strings.HasPrefix(line, "[GNUPG:] GOODSIG "):
			goodSigs++
		case strings.HasPrefix(line, "[GNUPG:] BADSIG "):
			badSigs++
		}
	}
	if badSigs > 0 || goodSigs == 0 {
		return "", fmt.Errorf("gpg signature verification failed against %s.asc (good=%d, bad=%d):\n%s",
			trustName, goodSigs, badSigs, verifyStatus.String())
	}
	return verifyOut.String(), nil
}

// findPackagesSha256InRelease walks the SHA256: block of an InRelease file
// looking for the line that names <packagesRelPath>.
func findPackagesSha256InRelease(inRelease, packagesRelPath string) (string, error) {
	// InRelease has a "SHA256:" block followed by indented lines of
	// "<hex>  <size>  <relative-path>". The block ends at the next
	// non-indented line.
	inSha256 := false
	for _, raw := range strings.Split(inRelease, "\n") {
		if !inSha256 {
			if strings.HasPrefix(raw, "SHA256:") {
				inSha256 = true
			}
			continue
		}
		if !strings.HasPrefix(raw, " ") && !strings.HasPrefix(raw, "\t") {
			break // end of block
		}
		parts := strings.Fields(strings.TrimSpace(raw))
		if len(parts) >= 3 && parts[2] == packagesRelPath {
			return parts[0], nil
		}
	}
	return "", fmt.Errorf("could not find %s in InRelease SHA256 block", packagesRelPath)
}

func fetchVerifiedAptPackages(groupName string, group DownloadGroup, arch string) (string, error) {
	if group.Apt == nil {
		return "", fmt.Errorf("group %s has no apt source", groupName)
	}
	inReleaseURL := group.Apt.BaseURL + "/InRelease"
	packagesRelPath := renderTemplate(group.Apt.PackagesPath, arch, "", "")
	packagesURL := group.Apt.BaseURL + "/" + packagesRelPath

	// 1+2. Fetch InRelease, verify and extract its plaintext.
	inReleaseRaw, err := fetchText(inReleaseURL)
	if err != nil {
		return "", err
	}
	verifiedInRelease, err := gpgVerify(inReleaseRaw, group.Apt.Trust)
	if err != nil {
		return "", err
	}

	// 3. Pull expected sha256 of Packages from the verified plaintext.
	expectedHash, err := findPackagesSha256InRelease(verifiedInRelease, packagesRelPath)
	if err != nil {
		return "", err
	}

	// 4+5. Fetch Packages, verify its hash, decompress if .gz.
	return fetchTextMaybeGzipped(packagesURL, expectedHash, strings.HasSuffix(packagesRelPath, ".gz"))
}

// extractAptVersion finds the `Version:` line for AptSource.PackageName
// inside an already-verified Packages payload, optionally stripping the
// configured epoch prefix.
func extractAptVersion(packages string, apt *AptSource, arch string) (string, error) {
	inBlock := false
	for _, line := range strings.Split(packages, "\n") {
		if strings.HasPrefix(line, "Package: ") {
			inBlock = strings.TrimSpace(strings.TrimPrefix(line, "Package: ")) == apt.PackageName
			continue
		}
		if inBlock && strings.HasPrefix(line, "Version: ") {
			v := strings.TrimSpace(strings.TrimPrefix(line, "Version: "))
			if apt.VersionEpochPrefix != "" {
				v = strings.TrimPrefix(v, apt.VersionEpochPrefix)
			}
			return v, nil
		}
	}
	return "", fmt.Errorf("could not find %s version in %s packages file",
		apt.PackageName, arch)
}

// extractAptHash walks the Packages payload to the `Filename:` line for the
// (PoolPath, PackageName, version, arch) tuple, then returns the SHA256 in
// the same package block.
func extractAptHash(packages string, apt *AptSource, version, arch string) (string, error) {
	versionStripped := strings.TrimPrefix(version, "v")
	filenameLine := fmt.Sprintf("Filename: %s/%s_%s_%s.deb",
		apt.PoolPath, apt.PackageName, versionStripped, arch)
	seenFilename := false
	for _, line := range strings.Split(packages, "\n") {
		if !seenFilename {
			if strings.HasPrefix(line, filenameLine) {
				seenFilename = true
			}
			continue
		}
		// Apt Packages files separate package blocks with a blank line, and
		// each block starts with `Package: `. Either marker means we've left
		// the block we matched on without finding its SHA256.
		if strings.TrimSpace(line) == "" || strings.HasPrefix(line, "Package: ") {
			return "", fmt.Errorf("did not find SHA256 before end of block for %s in Packages file",
				apt.PackageName)
		}
		if strings.HasPrefix(line, "SHA256:") {
			return strings.TrimSpace(strings.TrimPrefix(line, "SHA256:")), nil
		}
	}
	return "", fmt.Errorf("could not find filename %q in %s Packages file",
		filenameLine, apt.PackageName)
}

// ----- cosign keyless verification -----
//
// For groups whose upstream publishes sigstore artifacts, we go beyond the
// sha256 sidecar check by:
//  1. Downloading the artifact bytes (e.g. the kubelet binary or the
//     containerd tarball).
//  2. Cross-checking sha256(bytes) against the (already-fetched) sidecar
//     digest — this is the bridge between the cheap sidecar flow and what
//     cosign actually signs (the artifact contents).
//  3. Running `cosign verify-blob` against either:
//     - per-artifact `.sig` + `.cert` (kubernetes), or
//     - a release-wide sigstore bundle `.intoto.jsonl` (containerd).
//     The expected OIDC issuer + subject identity come from the source
//     config (CosignSigCert / CosignBundle).
//
// cosign manages its own Sigstore TUF root via tuf-repo-cdn.sigstore.dev, so
// no new files in vmconfig/trust/ are needed.

// cosignBundleCache caches sigstore bundle bodies per URL — for containerd
// the same bundle covers every artifact in a release, so we only fetch it
// once per run.
var cosignBundleCache = map[string]string{}

type cosignCtx struct{ arch, version, file string }

func (c cosignCtx) render(tmpl string) string {
	return renderTemplate(tmpl, c.arch, c.version, c.file)
}

func cosignVerifyBlob(artifactPath string, group DownloadGroup, ctx cosignCtx) error {
	tmpDir, err := os.MkdirTemp("", "vmconfig-cosign-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(tmpDir)

	// Build the args common to both cosign layouts. The two layouts diverge
	// only in how they supply the signature material (--bundle vs
	// --signature/--certificate).
	var (
		expectIssuer, rawSubject string
		isRegex                  bool
	)
	args := []string{"verify-blob"}

	switch {
	case group.CosignBundle != nil:
		expectIssuer = group.CosignBundle.ExpectIssuer
		rawSubject = group.CosignBundle.ExpectSubject
		isRegex = group.CosignBundle.ExpectSubjectIsRegex

		bundleURL := ctx.render(group.CosignBundle.BundleURL)
		body, ok := cosignBundleCache[bundleURL]
		if !ok {
			body, err = fetchText(bundleURL)
			if err != nil {
				return err
			}
			cosignBundleCache[bundleURL] = body
		}
		bundlePath := filepath.Join(tmpDir, "bundle.json")
		if err := os.WriteFile(bundlePath, []byte(body), 0o600); err != nil {
			return err
		}
		args = append(args, "--bundle", bundlePath, "--new-bundle-format")

	case group.CosignSigCert != nil:
		expectIssuer = group.CosignSigCert.ExpectIssuer
		rawSubject = group.CosignSigCert.ExpectSubject
		isRegex = group.CosignSigCert.ExpectSubjectIsRegex

		sigURL := ctx.render(group.CosignSigCert.SigURL)
		certURL := ctx.render(group.CosignSigCert.CertURL)
		sig, err := fetchText(sigURL)
		if err != nil {
			return err
		}
		cert, err := fetchText(certURL)
		if err != nil {
			return err
		}
		sigPath := filepath.Join(tmpDir, "sig")
		certPath := filepath.Join(tmpDir, "cert")
		if err := os.WriteFile(sigPath, []byte(sig), 0o600); err != nil {
			return err
		}
		if err := os.WriteFile(certPath, []byte(cert), 0o600); err != nil {
			return err
		}
		args = append(args, "--signature", sigPath, "--certificate", certPath)

	default:
		return fmt.Errorf("cosign policy requires either CosignSigCert or CosignBundle")
	}

	subject := renderTemplate(rawSubject, ctx.arch, ctx.version, ctx.file)
	args = append(args, "--certificate-oidc-issuer", expectIssuer)
	if isRegex {
		args = append(args, "--certificate-identity-regexp", subject)
	} else {
		args = append(args, "--certificate-identity", subject)
	}
	args = append(args, artifactPath)

	cmd := exec.Command("cosign", args...)
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	runErr := cmd.Run()
	combined := stdout.String() + stderr.String()
	if runErr != nil || !strings.Contains(combined, "Verified OK") {
		regexNote := ""
		if isRegex {
			regexNote = " (regex)"
		}
		return fmt.Errorf(
			"cosign verify-blob failed for %s\n"+
				"  expected issuer : %s\n"+
				"  expected subject: %s%s\n"+
				"  args: cosign %s\n"+
				"  err: %v\n"+
				"  stdout:\n%s\n  stderr:\n%s",
			artifactPath, expectIssuer, subject, regexNote,
			strings.Join(args, " "), runErr, stdout.String(), stderr.String())
	}
	return nil
}

// ----- file-hash dispatch -----

func fetchFileHash(
	groupName string,
	group DownloadGroup,
	arch, version, file, aptPackages string,
) (string, error) {
	// Apt: pull digest from the verified Packages contents (already fetched
	// once per arch by the caller).
	if group.Apt != nil {
		if aptPackages == "" {
			return "", fmt.Errorf("%s: apt group requires pre-fetched packages payload", groupName)
		}
		return extractAptHash(aptPackages, group.Apt, version, arch)
	}
	// Direct hash URL (GitHub releases, sha256 sidecars).
	if group.HashURL == "" {
		return "", fmt.Errorf("%s: no HashURL or apt source configured", groupName)
	}
	hashURL := renderTemplate(group.HashURL, arch, version, file)
	data, err := fetchText(hashURL)
	if err != nil {
		return "", err
	}
	// Multi-line sha256sum file: pick the line whose column-2 filename
	// matches the rendered HashFilename template, then return its hash.
	if group.HashFilename != "" {
		want := renderTemplate(group.HashFilename, arch, version, file)
		for _, line := range strings.Split(data, "\n") {
			fields := strings.Fields(line)
			if len(fields) >= 2 && fields[1] == want {
				return fields[0], nil
			}
		}
		return "", fmt.Errorf("%s: no line with filename %q in %s",
			groupName, want, hashURL)
	}
	// Single-hash sidecar: lines are "<hash>  <filename>" — keep just the hash.
	parts := strings.Fields(strings.TrimSpace(data))
	if len(parts) >= 2 {
		return parts[0], nil
	}
	return strings.TrimSpace(data), nil
}

// ----- manifest I/O -----

func manifestPath(kind, arch string) string {
	// Per kind/OS/arch layout: `deps/<kind>.<os-name>.<arch>.json`.
	// kind goes first so the published artifact filenames sort kind-grouped.
	return filepath.Join(*depsDir, fmt.Sprintf("%s.%s.%s.json", kind, sources.OS.Name, arch))
}

func readManifest(kind, arch string) (*Manifest, error) {
	body, err := os.ReadFile(manifestPath(kind, arch))
	if err != nil {
		return nil, err
	}
	var m Manifest
	if err := json.Unmarshal(body, &m); err != nil {
		return nil, fmt.Errorf("parse manifest %s: %w", manifestPath(kind, arch), err)
	}
	if m.VMConfig.Dependencies == nil {
		m.VMConfig.Dependencies = map[string]*DependencyOutput{}
	}
	return &m, nil
}

func writeManifest(kind, arch string, manifest *Manifest) error {
	// encoding/json sorts map keys alphabetically, so dependency ordering is
	// deterministic without any explicit sort here.
	body, err := json.MarshalIndent(manifest, "", "  ")
	if err != nil {
		return err
	}
	body = append(body, '\n')
	return os.WriteFile(manifestPath(kind, arch), body, 0o644)
}

func ensureBaseFile(kind, arch string) error {
	path := manifestPath(kind, arch)
	if _, err := os.Stat(path); err == nil {
		return nil
	}
	base := &Manifest{
		VMConfig: ManifestVMConfig{
			// Placeholder: the build/publish pipeline substitutes the git
			// tag here before the manifest ships. "dev" is the conventional
			// unreleased marker and degrades gracefully if a non-substituted
			// manifest is ever used.
			Version:      "dev",
			Kind:         kind,
			OS:           ManifestOS{Name: sources.OS.Name, Arch: arch},
			Dependencies: map[string]*DependencyOutput{},
		},
	}
	if err := writeManifest(kind, arch, base); err != nil {
		return err
	}
	fmt.Printf("[%s/%s] wrote base %s\n", kind, arch, path)
	return nil
}

// ----- main flow -----

// ----- OS boot metadata (qcow2/ext4 extraction) -----

// processOsBoot inspects the OS qcow2 image to extract boot metadata
// (kernel path, initrd path, cmdline, digests). It reuses a verified cached
// qcow2 image, converts it to raw with qemu-img, and uses go-diskfs for
// partition/filesystem access.
//
// The extracted metadata is written into the manifest's os.boot field.
func processOsBoot() error {
	for _, arch := range Archs {
		// Check if any manifest for this arch is missing boot metadata.
		needArch := false
		for _, kind := range allKinds {
			m, err := readManifest(kind, arch)
			if err != nil {
				return err
			}
			if m.VMConfig.OS.Image != nil && m.VMConfig.OS.Boot == nil {
				needArch = true
				break
			}
		}
		if !needArch {
			continue
		}

		// Read image URL from any manifest (same for all kinds).
		m, err := readManifest(allKinds[0], arch)
		if err != nil {
			return err
		}
		if m.VMConfig.OS.Image == nil {
			continue
		}
		imageURL := m.VMConfig.OS.Image.URL
		imagePath, err := cachedDownload(
			imageURL,
			fmt.Sprintf("os-image/%s", arch),
			arch,
			"os-image",
			m.VMConfig.OS.Image.Digest,
		)
		if err != nil {
			return fmt.Errorf("cache OS image for boot inspection: %w", err)
		}

		boot, err := extractBootMetadata(imagePath, arch)
		if err != nil {
			return fmt.Errorf("extract boot metadata for %s: %w", arch, err)
		}

		// Write boot metadata into all kind manifests for this arch.
		for _, kind := range allKinds {
			m, err := readManifest(kind, arch)
			if err != nil {
				return err
			}
			if m.VMConfig.OS.Boot != nil {
				continue
			}
			m.VMConfig.OS.Boot = boot
			if err := writeManifest(kind, arch, m); err != nil {
				return err
			}
			fmt.Printf("[%s/%s]   + os.boot (kernel=%s)\n", kind, arch, boot.Kernel.Path)
		}
	}
	return nil
}

// extractBootMetadata converts a qcow2 image to raw using qemu-img, then
// opens it with go-diskfs to locate grub.cfg, parse the default boot entry,
// and hash the kernel/initrd files.
func extractBootMetadata(imagePath, arch string) (*Boot, error) {
	// Convert qcow2 to raw for go-diskfs (which requires a raw disk image).
	rawPath := imagePath + ".raw"
	fmt.Printf("  converting qcow2 → raw...\n")
	cmd := exec.Command("qemu-img", "convert", "-f", "qcow2", "-O", "raw", imagePath, rawPath)
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		return nil, fmt.Errorf("qemu-img convert: %v\n%s", err, stderr.String())
	}
	defer os.Remove(rawPath)

	// Open the raw disk image.
	disk, err := diskfs.Open(rawPath, diskfs.WithSectorSize(512))
	if err != nil {
		return nil, fmt.Errorf("open disk: %w", err)
	}

	// Get the partition table.
	pt, err := disk.GetPartitionTable()
	if err != nil {
		return nil, fmt.Errorf("read partition table: %w", err)
	}
	partitions := pt.GetPartitions()
	if len(partitions) == 0 {
		return nil, fmt.Errorf("no partitions found")
	}

	// Debian nocloud images have partition 1 as the root ext4 filesystem.
	const rootPartNum = 1
	fs, err := disk.GetFilesystem(rootPartNum)
	if err != nil {
		return nil, fmt.Errorf("get filesystem on partition %d: %w", rootPartNum, err)
	}

	// Read grub.cfg.
	fmt.Printf("  reading /boot/grub/grub.cfg...\n")
	grubFile, err := fs.OpenFile("/boot/grub/grub.cfg", os.O_RDONLY)
	if err != nil {
		return nil, fmt.Errorf("open grub.cfg: %w", err)
	}
	grubData, err := io.ReadAll(grubFile)
	if err != nil {
		return nil, fmt.Errorf("read grub.cfg: %w", err)
	}

	// Parse the default boot entry.
	kernel, initrd, cmdline, err := parseGrubCfg(string(grubData))
	if err != nil {
		return nil, err
	}

	// Read and hash the kernel.
	fmt.Printf("  hashing kernel: %s\n", kernel)
	kernelFile, err := fs.OpenFile(kernel, os.O_RDONLY)
	if err != nil {
		return nil, fmt.Errorf("open kernel %s: %w", kernel, err)
	}
	kernelData, err := io.ReadAll(kernelFile)
	if err != nil {
		return nil, fmt.Errorf("read kernel %s: %w", kernel, err)
	}

	// Read and hash the initrd.
	fmt.Printf("  hashing initrd: %s\n", initrd)
	initrdFile, err := fs.OpenFile(initrd, os.O_RDONLY)
	if err != nil {
		return nil, fmt.Errorf("open initrd %s: %w", initrd, err)
	}
	initrdData, err := io.ReadAll(initrdFile)
	if err != nil {
		return nil, fmt.Errorf("read initrd %s: %w", initrd, err)
	}

	return &Boot{
		Cmdline: cmdline,
		Kernel: BootFile{
			Partition: rootPartNum,
			Path:      kernel,
			Digest:    "sha256:" + sha256Hex(kernelData),
		},
		Initrd: BootFile{
			Partition: rootPartNum,
			Path:      initrd,
			Digest:    "sha256:" + sha256Hex(initrdData),
		},
	}, nil
}

// parseGrubCfg extracts the kernel path, initrd path, and linux cmdline from
// the first menuentry in a grub.cfg file.
func parseGrubCfg(cfg string) (kernel, initrd, cmdline string, err error) {
	lines := strings.Split(cfg, "\n")
	inEntry := false
	for _, line := range lines {
		trimmed := strings.TrimSpace(line)
		if strings.HasPrefix(trimmed, "menuentry ") {
			inEntry = true
			continue
		}
		if !inEntry {
			continue
		}
		if strings.HasPrefix(trimmed, "linux") && !strings.HasPrefix(trimmed, "linuxefi") {
			parts := strings.Fields(trimmed)
			if len(parts) >= 2 {
				kernel = parts[1]
				cmdline = strings.Join(parts[2:], " ")
			}
		} else if strings.HasPrefix(trimmed, "initrd") {
			parts := strings.Fields(trimmed)
			if len(parts) >= 2 {
				initrd = parts[1]
			}
		}
		// Once we have both, stop at first entry.
		if kernel != "" && initrd != "" {
			break
		}
	}
	if kernel == "" || initrd == "" {
		return "", "", "", fmt.Errorf("could not find kernel/initrd in grub.cfg")
	}
	return kernel, initrd, cmdline, nil
}

func processOsImage() error {
	// The OS image is identical across kinds for a given arch, so we resolve
	// it once per arch and write it into every per-kind, per-arch manifest.
	resolved := map[string]*OsImage{}
	for _, arch := range Archs {
		needArch := false
		for _, kind := range allKinds {
			m, err := readManifest(kind, arch)
			if err != nil {
				return err
			}
			if m.VMConfig.OS.Image == nil {
				needArch = true
				break
			}
		}
		if !needArch {
			continue
		}
		fmt.Printf("[%s] resolving os.image...\n", arch)
		img, err := fetchOsImage(arch)
		if err != nil {
			return err
		}
		resolved[arch] = img
	}
	for _, arch := range Archs {
		img, ok := resolved[arch]
		if !ok {
			continue
		}
		for _, kind := range allKinds {
			m, err := readManifest(kind, arch)
			if err != nil {
				return err
			}
			if m.VMConfig.OS.Image != nil {
				continue
			}
			m.VMConfig.OS.Image = img
			if err := writeManifest(kind, arch, m); err != nil {
				return err
			}
			fmt.Printf("[%s/%s]   + os.image (%s)\n", kind, arch, img.Version)
		}
	}
	return nil
}

// processVMConfigStubs ensures a stub entry for the vmconfig package itself
// exists in every per-kind, per-arch manifest. Each manifest is scoped to a
// single kind, so the entry is keyed simply as "vmconfig" (no kind suffix).
//
// Version, URL, and digest are intentionally placeholders; the release
// pipeline substitutes them at publish time. install.sh must always verify
// the tarball via `tar --diff` against the extracted filesystem and fail
// loudly, so an un-substituted stub can never be mistaken for a release
// artifact.
//
// At release time the GH Action substitutes:
//
//	version: <git tag without leading "v">                 (e.g. "1.0.0")
//	url:     https://github.com/podplane/vmconfig/releases/download/
//	         v<VERSION>/vmconfig_<VERSION>_<KIND>_<OS>_<ARCH>.tar.gz
//	         (e.g. .../v1.0.0/vmconfig_1.0.0_knc_debian-13_amd64.tar.gz)
//	digest:  "sha256:<hex>" of the published tarball
//
// The top-level vmconfig.version field is also bumped to the same value.
func processVMConfigStubs() error {
	for _, kind := range allKinds {
		for _, arch := range Archs {
			m, err := readManifest(kind, arch)
			if err != nil {
				return err
			}
			if _, ok := m.VMConfig.Dependencies["vmconfig"]; ok {
				continue
			}
			m.VMConfig.Dependencies["vmconfig"] = &DependencyOutput{
				Version: "dev",
				URL:     "",
				Type:    DepTypeTarGz,
				Digest:  "",
			}
			if err := writeManifest(kind, arch, m); err != nil {
				return err
			}
			fmt.Printf("[%s/%s]   + vmconfig (stub)\n", kind, arch)
		}
	}
	return nil
}

// fileAppliesToKind reports whether a FileEntry from the input catalogue
// should land in the manifest for the given kind. An empty Kind list is
// treated as "applies to all kinds" so sources.go authors can omit it.
func fileAppliesToKind(file FileEntry, kind string) bool {
	if len(file.Kind) == 0 {
		return true
	}
	for _, k := range file.Kind {
		if k == kind {
			return true
		}
	}
	return false
}

func processGroup(groupName string, group DownloadGroup) error {
	// For each kind/arch pair, figure out which files in this group are
	// still missing from the manifest. We key the missing map on (kind,
	// arch) so the resolution loop below can broadcast a single resolved
	// entry into every kind/arch cell that needs it.
	type ka struct{ kind, arch string }
	manifests := map[ka]*Manifest{}
	for _, kind := range allKinds {
		for _, arch := range Archs {
			m, err := readManifest(kind, arch)
			if err != nil {
				return err
			}
			manifests[ka{kind, arch}] = m
		}
	}

	// archHasMissing[arch] = true if any (kind, arch) cell still needs an
	// entry from this group. Drives whether we bother fetching version /
	// apt packages / cosign material for that arch.
	archHasMissing := map[string]bool{}
	// archFiles[arch] = files relevant to this arch (any kind needs them).
	// Apt packages payload is per-arch, version may be per-arch — so the
	// fetch loop is keyed on arch first, kind second.
	archFiles := map[string][]FileEntry{}
	for _, arch := range Archs {
		seen := map[string]bool{}
		for _, file := range group.Files {
			for _, kind := range allKinds {
				if !fileAppliesToKind(file, kind) {
					continue
				}
				if _, ok := manifests[ka{kind, arch}].VMConfig.Dependencies[file.Name]; ok {
					continue
				}
				archHasMissing[arch] = true
				if !seen[file.Name] {
					seen[file.Name] = true
					archFiles[arch] = append(archFiles[arch], file)
				}
			}
		}
	}
	allDone := true
	for _, arch := range Archs {
		if archHasMissing[arch] {
			allDone = false
			break
		}
	}
	if allDone {
		return nil
	}

	// Resolve version. For GitHub-released groups the version is the same
	// across archs and we fetch it once; for apt groups the version is
	// per-arch (read from the per-arch Packages file).
	var sharedVersion string
	if group.Repo != "" && group.Apt == nil {
		v, err := fetchRepoVersion(groupName, group.Repo)
		if err != nil {
			return err
		}
		sharedVersion = v
		fmt.Printf("[%s] version=%s\n", groupName, sharedVersion)
	}

	for _, arch := range Archs {
		archMissing := archFiles[arch]
		if len(archMissing) == 0 {
			continue
		}

		// For apt groups, fetch and verify the Packages payload exactly once
		// per arch. The same string feeds both the version lookup and every
		// file's hash lookup below, so we keep the data flow explicit
		// instead of hiding it behind a module-level cache.
		var aptPackages string
		if group.Apt != nil {
			pkgs, err := fetchVerifiedAptPackages(groupName, group, arch)
			if err != nil {
				return err
			}
			aptPackages = pkgs
		}

		var version string
		switch {
		case sharedVersion != "":
			version = sharedVersion
		case group.Apt != nil:
			v, err := extractAptVersion(aptPackages, group.Apt, arch)
			if err != nil {
				return err
			}
			version = v
			fmt.Printf("[%s:%s] version=%s\n", arch, groupName, version)
		default:
			return fmt.Errorf("%s: no version source (need Repo or Apt)", groupName)
		}

		for _, file := range archMissing {
			url := renderTemplate(group.FileURL, arch, version, file.Name)
			hash, err := fetchFileHash(groupName, group, arch, version, file.Name, aptPackages)
			if err != nil {
				return err
			}

			// For cosign-protected groups, download the artifact bytes,
			// confirm sha256 matches the sidecar, and run cosign verify-blob.
			// cosign signs the artifact contents, not the sidecar, so the
			// bytes have to flow through this process at least once.
			// We verify ONCE per (arch, file) and broadcast the resolved
			// entry to every kind that needs it; the artifact itself is
			// kind-independent.
			if group.CosignSigCert != nil || group.CosignBundle != nil {
				fmt.Printf("[%s]   fetching %s for verification...\n", arch, file.Name)
				artifactPath, err := cachedDownload(
					url,
					fmt.Sprintf("%s/%s", arch, file.Name),
					arch,
					file.Name,
					group.HashAlg+":"+hash,
				)
				if err != nil {
					return err
				}
				fmt.Printf("[%s]   verifying cosign signature for %s...\n", arch, file.Name)
				if err := cosignVerifyBlob(artifactPath, group, cosignCtx{
					arch: arch, version: version, file: file.Name,
				}); err != nil {
					return err
				}
			}

			for _, kind := range allKinds {
				if !fileAppliesToKind(file, kind) {
					continue
				}
				m := manifests[ka{kind, arch}]
				if _, ok := m.VMConfig.Dependencies[file.Name]; ok {
					continue
				}
				m.VMConfig.Dependencies[file.Name] = &DependencyOutput{
					Version: strings.TrimPrefix(version, "v"),
					URL:     url,
					Type:    group.Type,
					Digest:  group.HashAlg + ":" + hash,
				}
				if err := writeManifest(kind, arch, m); err != nil {
					return err
				}
				fmt.Printf("[%s/%s]   + %s (%s)\n", kind, arch, file.Name, version)
			}
		}
	}
	return nil
}

func run() error {
	flag.Parse()

	// Three external verifiers/tools are needed:
	//   - gpg      : verifies apt InRelease signatures against trust/*.asc
	//                using a throwaway --homedir per verification (no side
	//                effects on the user's ~/.gnupg).
	//   - cosign   : verifies sigstore-signed GitHub release artifacts (e.g.
	//                kubernetes binaries on dl.k8s.io and the containerd
	//                release attestation bundle). Uses cosign's own
	//                TUF-managed root.
	//   - qemu-img : converts qcow2 OS images to raw for boot metadata
	//                extraction (kernel/initrd/cmdline).
	// Fail fast with platform-specific install hints if any is missing.
	if err := requireCommands("gpg", "cosign", "qemu-img"); err != nil {
		return err
	}
	if err := os.MkdirAll(*depsDir, 0o755); err != nil {
		return err
	}

	// Phase 1: bootstrap base manifest files (one per kind/arch pair).
	for _, kind := range allKinds {
		for _, arch := range Archs {
			if err := ensureBaseFile(kind, arch); err != nil {
				return err
			}
		}
	}

	// Phase 2: OS image.
	if err := processOsImage(); err != nil {
		return err
	}

	// Phase 2b: OS boot metadata (kernel/initrd/cmdline for direct boot).
	if err := processOsBoot(); err != nil {
		return err
	}

	// Phase 3: vmconfig package stubs (one per VM kind). These are
	// placeholders filled in by the release pipeline; they are written here
	// so the manifest schema is complete from the moment a base file is
	// created.
	if err := processVMConfigStubs(); err != nil {
		return err
	}

	// Phase 4: dependencies, group by group, alphabetically for deterministic
	// console output.
	groupNames := make([]string, 0, len(sources.Dependencies))
	for name := range sources.Dependencies {
		groupNames = append(groupNames, name)
	}
	sort.Strings(groupNames)
	for _, name := range groupNames {
		if err := processGroup(name, sources.Dependencies[name]); err != nil {
			return err
		}
	}

	fmt.Println("Done.")
	return nil
}

func main() {
	if err := run(); err != nil {
		log.SetFlags(0)
		log.Fatal(err)
	}
}

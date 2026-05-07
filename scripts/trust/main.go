// Podplane <https://podplane.dev>
// Copyright 2026 Nadrama Pty Ltd
// SPDX-License-Identifier: Apache-2.0
//
// Updates committed upstream signing keys in vmconfig/trust/.
//
// Run this script only when an upstream rotates their signing key. The
// ASCII-armored .asc files written here are committed to the repository and
// consumed by scripts/manifests (which dearmors them at runtime in the OS temp
// dir) to verify upstream signatures (e.g. apt InRelease) at manifest-
// generation time.
//
// Pinning the keys in-repo means a vmconfig version tag captures exactly
// which upstream signing identities we trusted at that point.
//
// Reviewing a `trust/*.asc` diff:
//   - The .asc itself is a base64-armored OpenPGP key block. A small content
//     change (subkey rotation, expiry update) re-encodes most of the bytes,
//     so the diff is not informatively readable on its own.
//   - DO NOT trust any in-repo summary of the key — it could be forged or
//     desynchronized from the .asc. The only meaningful check is to compare
//     the committed key against the upstream-published key over an
//     authenticated channel:
//
//     diff <(curl -s <upstream-url>) trust/<name>.asc
//
//     The upstream URLs for each key are listed in this script's `keys` table.
//   - As an aid, this script prints the parsed key info (`gpg --show-keys`)
//     to stdout when run; rerun locally and compare against the upstream
//     publication if you want a parsed view.

package main

import (
	"bytes"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

var trustDir = flag.String("trust-dir", "./trust", "Directory holding the committed signing keys (vmconfig/trust).")

// KeySpec describes one trust file we maintain in vmconfig/trust/.
type KeySpec struct {
	// Output filename (without extension) under vmconfig/trust/.
	Name string
	// Human description recorded for operator reference.
	Description string
	// ASCII-armored public key URLs. All fetched keys are concatenated into
	// a single keyring file.
	Sources []string
}

var keys = []KeySpec{
	{
		Name:        "debian-archive",
		Description: "Debian Archive Automatic Signing Keys (trixie / Debian 13). Signs deb.debian.org InRelease files.",
		Sources: []string{
			"https://ftp-master.debian.org/keys/archive-key-13.asc",
			"https://ftp-master.debian.org/keys/archive-key-13-security.asc",
		},
	},
	{
		Name:        "fluentbit",
		Description: "Fluent Bit packaging signing key. Signs packages.fluentbit.io InRelease files.",
		Sources:     []string{"https://packages.fluentbit.io/fluentbit.key"},
	},
}

func fetchAscii(url string) (string, error) {
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

// gpgRun pipes `armored` to `gpg <args...>` on stdin and returns its stdout.
func gpgRun(armored string, args ...string) (string, error) {
	cmd := exec.Command("gpg", args...)
	cmd.Stdin = strings.NewReader(armored)
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		return "", fmt.Errorf("gpg %s failed: %v\n%s", strings.Join(args, " "), err, stderr.String())
	}
	return stdout.String(), nil
}

// showKeys returns the human-readable `gpg --show-keys` output for `armored`.
// --show-keys parses keys without importing into the user's keyring.
// --with-fingerprint includes the full fingerprint of every key.
func showKeys(armored string) (string, error) {
	return gpgRun(armored, "--show-keys", "--with-fingerprint")
}

// parseFingerprints parses the primary-key fingerprints out of
// `gpg --show-keys --with-colons`. Colon output is the stable, parseable
// format. Each public key starts with a `pub:` line and is immediately
// followed by an `fpr:` line; field 10 of that `fpr:` line is the full
// fingerprint. Subkey `fpr:` lines (which follow `sub:`) are intentionally
// ignored — we only highlight primary-key changes.
func parseFingerprints(armored string) ([]string, error) {
	out, err := gpgRun(armored, "--show-keys", "--with-colons")
	if err != nil {
		return nil, err
	}
	var fprs []string
	expectingPubFpr := false
	for _, line := range strings.Split(out, "\n") {
		switch {
		case strings.HasPrefix(line, "pub:"):
			expectingPubFpr = true
		case expectingPubFpr && strings.HasPrefix(line, "fpr:"):
			fields := strings.Split(line, ":")
			if len(fields) >= 10 && fields[9] != "" {
				fprs = append(fprs, fields[9])
			}
			expectingPubFpr = false
		case strings.HasPrefix(line, "sub:"),
			strings.HasPrefix(line, "uid:"),
			strings.HasPrefix(line, "uat:"):
			expectingPubFpr = false
		}
	}
	return fprs, nil
}

func diffFprs(oldFprs, newFprs []string) (added, removed []string) {
	oldSet := map[string]struct{}{}
	for _, f := range oldFprs {
		oldSet[f] = struct{}{}
	}
	newSet := map[string]struct{}{}
	for _, f := range newFprs {
		newSet[f] = struct{}{}
	}
	for _, f := range oldFprs {
		if _, ok := newSet[f]; !ok {
			removed = append(removed, f)
		}
	}
	for _, f := range newFprs {
		if _, ok := oldSet[f]; !ok {
			added = append(added, f)
		}
	}
	return
}

func processKey(spec KeySpec) error {
	fmt.Printf("\n=== %s ===\n", spec.Name)
	fmt.Println(spec.Description)

	// Capture the fingerprints currently committed (if any) before we
	// overwrite the file, so a key rotation is visible in the script output
	// rather than hidden inside an opaque .asc diff.
	ascPath := filepath.Join(*trustDir, spec.Name+".asc")
	var previousAsc string
	if data, err := os.ReadFile(ascPath); err == nil {
		previousAsc = string(data)
	} else if !os.IsNotExist(err) {
		return err
	}
	var oldFprs []string
	if previousAsc != "" {
		var err error
		oldFprs, err = parseFingerprints(previousAsc)
		if err != nil {
			return err
		}
	}

	// Fetch each armored source and concatenate. Multiple PGP blocks in the
	// same file are valid and parsed independently by GPG.
	var blocks []string
	for _, url := range spec.Sources {
		fmt.Printf("  fetch %s\n", url)
		armored, err := fetchAscii(url)
		if err != nil {
			return err
		}
		blocks = append(blocks, strings.TrimRight(armored, "\n")+"\n")
	}
	combined := strings.Join(blocks, "")
	newFprs, err := parseFingerprints(combined)
	if err != nil {
		return err
	}

	// Diff old vs new primary-key fingerprints. Anything in `removed` is a
	// key we used to trust and no longer do; anything in `added` is a brand-
	// new key we are about to trust. Both deserve operator scrutiny against
	// the upstream-published key over an authenticated channel.
	added, removed := diffFprs(oldFprs, newFprs)
	switch {
	case len(oldFprs) == 0:
		fmt.Println("  fingerprints (initial import):")
		for _, f := range newFprs {
			fmt.Printf("    + %s\n", f)
		}
	case len(added) == 0 && len(removed) == 0:
		fmt.Printf("  fingerprints unchanged (%d key(s))\n", len(newFprs))
	default:
		fmt.Println("  fingerprint changes — REVIEW BEFORE COMMITTING:")
		for _, f := range removed {
			fmt.Printf("    - %s  (removed)\n", f)
		}
		for _, f := range added {
			fmt.Printf("    + %s  (added)\n", f)
		}
	}

	if err := os.WriteFile(ascPath, []byte(combined), 0o644); err != nil {
		return err
	}
	fmt.Printf("  wrote %s\n", ascPath)

	// Print parsed key info to stdout for the operator's runtime inspection.
	// This output is intentionally NOT committed — see the script header for
	// why a committed summary file would be a security trap.
	parsed, err := showKeys(combined)
	if err != nil {
		return err
	}
	for _, line := range strings.Split(parsed, "\n") {
		fmt.Println("    " + line)
	}
	return nil
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
	return fmt.Errorf(
		"required commands not found in PATH: %s. Install them (e.g. via your package manager) and retry.",
		strings.Join(missing, ", "))
}

func run() error {
	flag.Parse()
	if err := requireCommands("gpg"); err != nil {
		return err
	}
	if err := os.MkdirAll(*trustDir, 0o755); err != nil {
		return err
	}
	for _, spec := range keys {
		if err := processKey(spec); err != nil {
			return err
		}
	}
	fmt.Println("\nDone. Review trust/*.asc against upstream URLs (see header comment) and commit.")
	return nil
}

func main() {
	if err := run(); err != nil {
		log.SetFlags(0)
		log.Fatal(err)
	}
}

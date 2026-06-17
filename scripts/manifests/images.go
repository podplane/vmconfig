// Podplane <https://podplane.dev>
// Copyright The Podplane Authors
// SPDX-License-Identifier: Apache-2.0

package main

import (
	"encoding/json"
	"fmt"
	"regexp"
	"sort"
	"strings"
)

var containerdDefaultSandboxImageRE = regexp.MustCompile(`(?m)^\s*DefaultSandboxImage\s*=\s*"([^"]+)"`)

type imageIndex struct {
	Manifests []struct {
		Digest   string `json:"digest"`
		Platform struct {
			OS           string `json:"os"`
			Architecture string `json:"architecture"`
			Variant      string `json:"variant"`
		} `json:"platform"`
	} `json:"manifests"`
}

// splitImageRef separates a container image reference into repository, tag, and
// digest parts without applying registry normalization.
func splitImageRef(value string) (repo string, tag string, digest string) {
	if before, after, ok := strings.Cut(value, "@"); ok {
		value = before
		digest = after
	}
	lastSlash := strings.LastIndex(value, "/")
	lastColon := strings.LastIndex(value, ":")
	if lastColon > lastSlash {
		tag = value[lastColon+1:]
		value = value[:lastColon]
	}
	return value, tag, digest
}

// containerManifestSize returns the manifest JSON size plus config and layer
// blob sizes for one platform-specific container image manifest.
func containerManifestSize(body []byte) (int64, error) {
	var manifest struct {
		Config *struct {
			Size int64 `json:"size"`
		} `json:"config"`
		Layers []struct {
			Size int64 `json:"size"`
		} `json:"layers"`
	}
	if err := json.Unmarshal(body, &manifest); err != nil {
		return 0, err
	}
	size := int64(len(body))
	if manifest.Config != nil {
		size += manifest.Config.Size
	}
	for _, layer := range manifest.Layers {
		size += layer.Size
	}
	return size, nil
}

// resolveRuntimeImage resolves a vmconfig runtime image to the platform-specific
// digest and size for arch.
func resolveRuntimeImage(source ImageSource, arch string) (ImageOutput, error) {
	repo, tag, digest := splitImageRef(source.Image)
	resolvedImage := repo + "@" + digest
	if digest == "" {
		if tag == "" {
			tag = "latest"
		}
		resolvedDigest, err := commandOutput("crane", "digest", repo+":"+tag)
		if err != nil {
			return ImageOutput{}, fmt.Errorf("resolve digest for %s: %w", source.Image, err)
		}
		digest = strings.TrimSpace(resolvedDigest)
		resolvedImage = repo + "@" + digest
	}
	body, err := commandOutput("crane", "manifest", resolvedImage)
	if err != nil {
		return ImageOutput{}, fmt.Errorf("inspect manifest for %s: %w", resolvedImage, err)
	}
	var index imageIndex
	if err := json.Unmarshal([]byte(body), &index); err != nil {
		return ImageOutput{}, fmt.Errorf("parse manifest for %s: %w", resolvedImage, err)
	}
	if len(index.Manifests) == 0 {
		size, err := containerManifestSize([]byte(body))
		if err != nil {
			return ImageOutput{}, fmt.Errorf("calculate image size for %s: %w", resolvedImage, err)
		}
		return ImageOutput{Image: source.Image, Digest: digest, Size: size}, nil
	}
	for _, child := range index.Manifests {
		if child.Platform.OS == "" || child.Platform.Architecture == "" || child.Platform.OS == "unknown" || child.Platform.Architecture == "unknown" {
			continue
		}
		platform := child.Platform.OS + "/" + child.Platform.Architecture
		if child.Platform.Variant != "" {
			platform += "/" + child.Platform.Variant
		}
		if platform != "linux/"+arch && !strings.HasPrefix(platform, "linux/"+arch+"/") {
			continue
		}
		childRef := repo + "@" + child.Digest
		childBody, err := commandOutput("crane", "manifest", childRef)
		if err != nil {
			return ImageOutput{}, fmt.Errorf("inspect child manifest %s: %w", childRef, err)
		}
		size, err := containerManifestSize([]byte(childBody))
		if err != nil {
			return ImageOutput{}, fmt.Errorf("calculate image size for %s: %w", childRef, err)
		}
		return ImageOutput{Image: source.Image, Digest: child.Digest, Size: size, Platform: platform, Index: digest}, nil
	}
	return ImageOutput{}, fmt.Errorf("%s has no linux/%s platform", source.Image, arch)
}

// verifyContainerdSandboxImage checks that vmconfig's configured pod sandbox
// image matches the default compiled into the resolved containerd release.
func verifyContainerdSandboxImage(version string) error {
	version = strings.TrimPrefix(version, "v")
	url := fmt.Sprintf("https://raw.githubusercontent.com/containerd/containerd/v%s/internal/cri/config/config.go", version)
	body, err := fetchText(url)
	if err != nil {
		return fmt.Errorf("fetch containerd default sandbox image for v%s: %w", version, err)
	}
	matches := containerdDefaultSandboxImageRE.FindStringSubmatch(body)
	if len(matches) != 2 {
		return fmt.Errorf("containerd v%s config.go did not define DefaultSandboxImage", version)
	}
	defaultSandboxImage := matches[1]
	matched := 0
	for _, image := range sources.Images {
		if image.Image == defaultSandboxImage {
			matched++
		}
	}
	if matched != 1 {
		return fmt.Errorf("containerd v%s DefaultSandboxImage is %q, but sources.Images contains %d matching entries", version, defaultSandboxImage, matched)
	}
	fmt.Printf("[containerd] verified DefaultSandboxImage=%s\n", defaultSandboxImage)
	return nil
}

// processImages resolves and writes vmconfig runtime container images into each
// per-kind, per-arch manifest.
func processImages() error {
	for _, arch := range Archs {
		for _, image := range sources.Images {
			needImage := false
			for _, kind := range allKinds {
				m, err := readManifest(kind, arch)
				if err != nil {
					return err
				}
				found := false
				for _, current := range m.VMConfig.Images {
					if current.Image == image.Image && current.Size > 0 {
						found = true
						break
					}
				}
				if !found {
					needImage = true
					break
				}
			}
			if !needImage {
				continue
			}
			fmt.Printf("[%s] resolving image %s (%s)...\n", arch, image.Name, image.Image)
			resolved, err := resolveRuntimeImage(image, arch)
			if err != nil {
				return err
			}
			for _, kind := range allKinds {
				m, err := readManifest(kind, arch)
				if err != nil {
					return err
				}
				replaced := false
				for i := range m.VMConfig.Images {
					if m.VMConfig.Images[i].Image == resolved.Image {
						m.VMConfig.Images[i] = resolved
						replaced = true
						break
					}
				}
				if !replaced {
					m.VMConfig.Images = append(m.VMConfig.Images, resolved)
					sort.Slice(m.VMConfig.Images, func(i, j int) bool {
						return m.VMConfig.Images[i].Image < m.VMConfig.Images[j].Image
					})
				}
				if err := writeManifest(kind, arch, m); err != nil {
					return err
				}
				fmt.Printf("[%s/%s]   + image %s\n", kind, arch, image.Name)
			}
		}
	}
	return nil
}

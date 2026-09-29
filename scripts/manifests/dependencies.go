// Podplane <https://podplane.dev>
// Copyright The Podplane Authors
// SPDX-License-Identifier: Apache-2.0

package main

import (
	"fmt"
	"net/url"
	"os"
	"slices"
	"sort"
	"strings"
)

// dependencyEntry joins one output artifact to its download source.
type dependencyEntry struct {
	File      FileEntry
	GroupName string
	Group     DownloadGroup
}

// dependencyCatalogue indexes every output artifact by name.
func dependencyCatalogue() (map[string]dependencyEntry, error) {
	entries := make(map[string]dependencyEntry)
	for groupName, group := range sources.Dependencies {
		for _, file := range group.Files {
			if _, ok := entries[file.Name]; ok {
				return nil, fmt.Errorf("dependency %q is declared more than once", file.Name)
			}
			entries[file.Name] = dependencyEntry{File: file, GroupName: groupName, Group: group}
		}
	}
	return entries, nil
}

// validateDependencyGraph checks references, kind coverage, duplicate edges,
// and cycles in the source dependency graph.
func validateDependencyGraph() error {
	entries, err := dependencyCatalogue()
	if err != nil {
		return err
	}
	for name, entry := range entries {
		seen := make(map[string]bool)
		for _, required := range entry.File.Requires {
			if seen[required] {
				return fmt.Errorf("dependency %q requires %q more than once", name, required)
			}
			seen[required] = true
			target, ok := entries[required]
			if !ok {
				return fmt.Errorf("dependency %q requires unknown dependency %q", name, required)
			}
			for _, kind := range entry.File.Kind {
				if !slices.Contains(target.File.Kind, kind) {
					return fmt.Errorf("dependency %q requires %q for kind %s, but %q does not support that kind", name, required, kind, required)
				}
			}
		}
	}

	state := make(map[string]uint8)
	var visit func(string, []string) error
	visit = func(name string, path []string) error {
		switch state[name] {
		case 1:
			return fmt.Errorf("dependency cycle: %s", strings.Join(append(path, name), " -> "))
		case 2:
			return nil
		}
		state[name] = 1
		for _, required := range entries[name].File.Requires {
			if err := visit(required, append(path, name)); err != nil {
				return err
			}
		}
		state[name] = 2
		return nil
	}
	for name := range entries {
		if err := visit(name, nil); err != nil {
			return err
		}
	}
	return nil
}

// extractAptDependencyNames returns direct Depends and Pre-Depends package
// names from the first matching stanza in a Debian Packages payload.
func extractAptDependencyNames(packages, packageName string) (map[string]bool, error) {
	for _, stanza := range strings.Split(packages, "\n\n") {
		fields := make(map[string]string)
		var current string
		for _, line := range strings.Split(stanza, "\n") {
			if strings.HasPrefix(line, " ") && current != "" {
				fields[current] += " " + strings.TrimSpace(line)
				continue
			}
			key, value, ok := strings.Cut(line, ":")
			if !ok {
				continue
			}
			current = key
			fields[key] = strings.TrimSpace(value)
		}
		if fields["Package"] != packageName {
			continue
		}
		dependencies := make(map[string]bool)
		for _, field := range []string{"Pre-Depends", "Depends"} {
			for _, clause := range strings.Split(fields[field], ",") {
				for _, alternative := range strings.Split(clause, "|") {
					parts := strings.Fields(alternative)
					if len(parts) == 0 {
						continue
					}
					name, _, _ := strings.Cut(parts[0], ":")
					dependencies[name] = true
				}
			}
		}
		return dependencies, nil
	}
	return nil, fmt.Errorf("could not find %s dependencies in Packages file", packageName)
}

// verifyAptRequirements checks declared edges from APT packages against
// the Depends metadata covered by the repository's trusted InRelease files.
func verifyAptRequirements() error {
	entries, err := dependencyCatalogue()
	if err != nil {
		return err
	}
	cache := make(map[string]string)
	for groupName, group := range sources.Dependencies {
		if group.Apt == nil {
			continue
		}
		for _, file := range group.Files {
			for _, arch := range Archs {
				key := strings.Join([]string{group.Apt.BaseURL, group.Apt.PackagesPath, group.Apt.Trust, arch}, "\x00")
				packages, ok := cache[key]
				if !ok {
					var err error
					packages, err = fetchVerifiedAptPackages(groupName, group, arch)
					if err != nil {
						return err
					}
					cache[key] = packages
				}
				dependencies, err := extractAptDependencyNames(packages, group.Apt.PackageName)
				if err != nil {
					return err
				}
				declared := make(map[string]bool, len(file.Requires))
				for _, required := range file.Requires {
					declared[required] = true
					if !dependencies[required] {
						return fmt.Errorf("%s/%s: signed package metadata does not list declared requirement %q", file.Name, arch, required)
					}
				}
				for required := range dependencies {
					target, ok := entries[required]
					if !ok {
						continue
					}
					coversKinds := true
					for _, kind := range file.Kind {
						if !slices.Contains(target.File.Kind, kind) {
							coversKinds = false
							break
						}
					}
					if coversKinds && !declared[required] {
						return fmt.Errorf("%s/%s: signed package metadata contains undeclared bundled requirement %q", file.Name, arch, required)
					}
				}
			}
		}
	}
	return nil
}

// dependencySourceLink returns a concise Markdown link to an artifact's
// authoritative package repository or source repository.
func dependencySourceLink(entry dependencyEntry) string {
	var label, rawURL string
	switch {
	case entry.Group.Apt != nil:
		rawURL = entry.Group.Apt.BaseURL
		parsed, err := url.Parse(rawURL)
		if err == nil {
			label = parsed.Host
		}
	case entry.Group.Repo != "":
		label = entry.Group.Repo
		rawURL = "https://github.com/" + entry.Group.Repo
	default:
		rawURL = entry.Group.FileURL
	}
	parsed, err := url.Parse(rawURL)
	if err == nil && parsed.Host == "github.com" {
		parts := strings.Split(strings.Trim(parsed.Path, "/"), "/")
		if len(parts) >= 2 {
			label = parts[0] + "/" + parts[1]
			rawURL = "https://github.com/" + parts[0] + "/" + parts[1]
		}
	}
	if label == "" {
		label = entry.GroupName
	}
	return fmt.Sprintf("[%s](%s)", label, rawURL)
}

// renderDependenciesDoc renders the developer-facing dependency graph.
func renderDependenciesDoc() (string, error) {
	entries, err := dependencyCatalogue()
	if err != nil {
		return "", err
	}
	kindNames := map[string]string{
		KindKnc: "Kubernetes Control-Plane Nodes",
		KindKnd: "Kubernetes Data-Plane Nodes",
		KindNst: "Nstance Server Nodes",
		KindNat: "NAT Nodes",
	}
	var out strings.Builder
	out.WriteString("# VM dependency graph\n\n")
	out.WriteString("__WARNING__: This file is generated by scripts/manifests - do not edit it directly.\n\n")
	out.WriteString("This file shows which dependencies vmconfig bundles for each type of VM, where they come from, and which other bundled packages they need. Supporting Debian packages are listed with the tool that needs them rather than as separate rows. Software already provided by the base OS is not listed.\n\n")
	for kindIndex, kind := range allKinds {
		out.WriteString("## " + kind + " - " + kindNames[kind] + "\n\n")
		out.WriteString("| Dependency | Source | Requires |\n")
		out.WriteString("| --- | --- | --- |\n")
		supportingPackages := make(map[string]bool)
		for _, entry := range entries {
			if !slices.Contains(entry.File.Kind, kind) {
				continue
			}
			for _, required := range entry.File.Requires {
				if entries[required].Group.Apt != nil {
					supportingPackages[required] = true
				}
			}
		}
		names := make([]string, 0)
		for name, entry := range entries {
			if slices.Contains(entry.File.Kind, kind) && !supportingPackages[name] {
				names = append(names, name)
			}
		}
		sort.Strings(names)
		for _, name := range names {
			entry := entries[name]
			requiredSet := make(map[string]bool)
			var collectRequirements func(string)
			collectRequirements = func(required string) {
				if requiredSet[required] {
					return
				}
				requiredSet[required] = true
				for _, transitive := range entries[required].File.Requires {
					collectRequirements(transitive)
				}
			}
			for _, required := range entry.File.Requires {
				collectRequirements(required)
			}
			requires := make([]string, 0, len(requiredSet))
			for required := range requiredSet {
				requires = append(requires, required)
			}
			sort.Strings(requires)
			required := "—"
			if len(requires) > 0 {
				for i := range requires {
					requires[i] = "`" + requires[i] + "`"
				}
				required = strings.Join(requires, ", ")
			}
			fmt.Fprintf(&out, "| `%s` | %s | %s |\n", name, dependencySourceLink(entry), required)
		}
		if kindIndex < len(allKinds)-1 {
			out.WriteString("\n")
		}
	}
	return out.String(), nil
}

// writeDependenciesDoc writes the generated dependency reference.
func writeDependenciesDoc(filename string) error {
	body, err := renderDependenciesDoc()
	if err != nil {
		return err
	}
	return os.WriteFile(filename, []byte(body), 0o644)
}

# Podplane VM Configuration

Podplane `vmconfig` is a minimal configuration system for the [Podplane](https://podplane.dev) Kubernetes distribution & PaaS, designed for Debian-based Linux VMs, written in Bash.

## How It Works

The published packages vary the VM configuration based on the desired VM "kind":

- `knd` creates a Kubernetes Data Plane / Worker node, which runs kubelet, containerd, and supporting services.

- `knc` creates a Kubernetes Control Plane node, which is essentially a base of `knd` + adds [netsy](https://netsy.dev) (as an etcd alternative), kube-apiserver, kube-scheduler, kube-controller-manager, etc.

The VM cloud-init user-data script is responsible for downloading and verifying all dependencies required for its nominated VM kind, and invoking the `vmconfig` package's `install.sh` then `configure.sh` entrypoints.

The full list of dependencies per VM kind, OS, and architecture is published as a `deps.json` manifest inside each tarball.

## Requirements

VMs are responsible for:
  1. Placing all dependencies into `/opt/podplane/deps/` using the `<key>.<ext>` naming convention (e.g. `vmconfig.tar.gz`, `containerd.tar.gz`, `fluent-bit.deb`, `kubelet`, `runc`)
  2. Extracting `/opt/podplane/deps/vmconfig.tar.gz` to `/` (paths inside the tarball are relative to the system root, so this also lands `/opt/podplane/share/deps.json`)
  3. Invoking `/opt/podplane/bin/install.sh` (verifies + installs deps, can be used for preparing machine images)
  4. (Optional) Writing any vmconfig runtime settings/environment variables to `/opt/podplane/user-data.env`
  5. Invoking `/opt/podplane/bin/configure.sh` (idempotent per-boot configuration)

Note that the outcome of 1, 2, & 3 can be bundled into a machine image (e.g. an AMI on AWS).

The VM kind (`knd` or `knc`) is read from `vmconfig.kind` in `/opt/podplane/share/deps.json` (and after install, from `/opt/podplane/share/deps-installed.json`).

`install.sh` and `configure.sh` are designed to be idempotent. They handle checking all dependencies, installing them, and configuring the system before services start.

## Development

All dev workflows are defined in the [Makefile](./Makefile) - run `make help` for the full list, but key workflows includes:

- __update-trust__:
    Refreshes `trust/*.asc`: GPG keys used to verify upstream apt repositories. Committed to the repo so every dependency manifest update run anchors to an auditable copy.

- __update-deps__:
    Refreshes `deps/<kind>.<os-name>.<arch>.json` dependency manifests (e.g. `deps/knd.debian-13.amd64.json`): one manifest per kind, OS, and arch listing every dependency's URL, version, and content hash/digest. Each entry is resolved through a verified chain (see *Dependency Trust* below). Incremental - delete an entry or the whole file to scope the refresh.

## Dependency Trust

Per-source verification chain used by `update-deps`:

- __Debian apt__:
    `gpg` verifies `InRelease` against `trust/debian-archive.asc` -> SHA256 of `Packages` -> `.deb` digest.

- __Fluent Bit apt__:
    same flow as Debian apt, except using `trust/fluentbit.asc`.

- __Kubernetes binaries (dl.k8s.io)__:
    `.sha256` sidecar and per-binary cosign keyless

- __containerd tarballs__:
    `.sha256sum` sidecar and the release-wide sigstore bundle `*-attestation.intoto.jsonl` (GitHub Actions OIDC)

- __runc, registry, cri-tools, cni-plugins, Debian OS image__:
    TLS + sidecar checksum only - upstream does not publish cosign material we can verify

## Learn More

Learn more about Podplane at the official project website: [podplane.dev](https://podplane.dev)

For more information about `vmconfig` specifically, please read the documentation at: [podplane.dev/docs/vmconfig](https://podplane.dev/docs/vmconfig)

## License

Podplane is licensed under the Apache License, Version 2.0.
Copyright 2026 Nadrama Pty Ltd.

See the [LICENSE](./LICENSE) file for details.

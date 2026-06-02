# Podplane vmconfig - Agent Guide

This repository contains Podplane's VM configuration package for Debian-based
VMs. It builds root-relative filesystem trees and reproducible tarballs for the
Podplane VM kinds:

- `knd` - Kubernetes data/worker node configuration.
- `knc` - Kubernetes control plane node configuration; overlays `knd` and adds
  control-plane services such as netsy and Kubernetes control plane components.

## Commands

Prefer Makefile targets over raw commands.

- **Setup**: `make setup` - verify required host tools and install the
  pre-commit and commit-msg hooks.
- **Lint**: `make lint` - run `shellcheck` over scripts and template shell
  files.
- **Precommit**: `make precommit` - run the fast local checks.
- **Test**: `make test` - run Go tests for repository tooling.
- **Package**: `make package` - build all `knd`/`knc` amd64/arm64 tarballs
  under `dist/`.
- **CI**: `make ci` - run precommit checks, Go tests, and package all artifacts.
- **Install smoke test**: `make test-install` - run container-based install.sh
  smoke tests for the host architecture. This uses Docker and downloads VM
  dependency artifacts into `temp/deps-cache/`.
- **Update dependency manifests**: `make update-manifests` - refresh
  `manifests/<kind>.<os>.<arch>.json` through the repository's trust checks.
- **Update trust roots**: `make update-trust` - refresh `trust/*.asc` keyrings.
- **Local VM sync**: `make knd-sync`, `make knc-sync`, `make knd-watch`,
  `make knc-watch` - build and sync local template changes into a Podplane CLI
  local VM.
- **Clean**: `make clean` - remove `temp/` and `dist/`.

Dependencies: Go, GNU tar (`tar` on Linux, `gtar` on macOS), `rsync`,
`shellcheck`, `jq`, `shasum`, and Docker/Podman for `make test-install`.

## Safety

- Before editing, check `git status --short` and do not overwrite or revert
  other people's changes.
- Commits require a Developer Certificate of Origin sign-off (`git commit -s`);
  `make setup` installs the `commit-msg` hook that enforces this locally.
- Do not run VM-mutating local sync/watch targets (`knd-sync`, `knc-sync`,
  `knd-watch`, `knc-watch`) without explicit user approval.
- Do not run `make test-install` unless Docker/Podman use and dependency downloads are
  appropriate for the task.
- Do not update dependency manifests or trust roots unless the task explicitly
  asks for that refresh.

## Conventions

- Keep shell scripts in strict mode (`set -euo pipefail`) unless a local script
  has a documented reason not to.
- Keep paths in package templates system-root-relative; package tarballs extract
  into `/` on the target VM.
- `templates/knc` overlays `templates/knd`; shared behavior belongs in `knd`
  unless it is control-plane-only.
- Release artifacts are reproducible tarballs built by the Makefile with stable
  ownership, ordering, mtimes, and gzip headers.
- Generated/transient outputs live under `dist/`, `temp/`, or `cache/` and
  should not be committed.

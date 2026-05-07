# Podplane <https://podplane.dev>
# Copyright 2026 Nadrama Pty Ltd
# SPDX-License-Identifier: Apache-2.0
#
# Developer entry points for vmconfig. Each target shells into the matching
# script under ./scripts/ and tees its output to ./temp/<target>.log so the
# console stays uncluttered while a full transcript is available for review.
# The temp/ directory is git-ignored and reset at the start of each run.

# Use bash with strict pipe handling so a failure inside `tee` (or the script
# being teed) propagates as a non-zero make exit.
SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c

TEMP_DIR := temp
DIST_DIR := dist
OS_NAME  := debian-13
# PODPLANE_CLI ?= podplane
PODPLANE_CLI ?= go -C $(CURDIR)/../podplane run .

# Version baked into local package artifacts. The release pipeline overrides
# this on the command line (e.g. `make package-knc VERSION=1.0.0`); local
# dev builds keep the conventional "dev" marker, same as manifest stubs.
VERSION ?= dev

# GNU tar is required for --owner/--group/--mtime/--sort (reproducible
# tarballs). macOS ships BSD tar; install gtar via Homebrew. Linux ships
# GNU tar as the default `tar`. The setup target verifies the chosen
# binary at build time.
ifeq ($(shell uname -s),Darwin)
TAR := gtar
else
TAR := tar
endif

# Reproducible tarballs: stable file ordering, neutralized ownership, fixed
# mtime, and `gzip -n` to strip gzip's embedded filename + mtime from header.
TAR_FLAGS   := --owner=0 --group=0 --sort=name --mtime='UTC 2020-01-01' \
               --exclude='.DS_Store' --use-compress-program='gzip -n'
RSYNC_FLAGS := -a

# Host architecture, normalised to the same {amd64,arm64} vocabulary used by
# the package targets. Used by the test-install targets below to pick the
# matching manifest and pre-built package tarball for the local docker
# engine's native platform.
HOST_ARCH := $(shell uname -m | sed -e 's/x86_64/amd64/' -e 's/aarch64/arm64/')

.PHONY: help setup lint precommit update-manifests update-trust \
        build build-knd build-knc \
        package package-knd package-knc \
        package-knd-amd64 package-knd-arm64 package-knc-amd64 package-knc-arm64 \
        test-install test-install-knd test-install-knc \
        local-sync knd-sync knc-sync \
        local-watch knd-watch knc-watch \
        clean

help: ## Show this help message
	@printf "Usage: make <target>\n\nTargets:\n"
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / { printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2 }' $(MAKEFILE_LIST)
	@printf "\nLogs:    %s/<target>.log (recreated each run)\n" "$(TEMP_DIR)"

setup: ## Verify required tools (gtar, rsync, shellcheck) and install git hooks
	@command -v $(TAR) >/dev/null 2>&1 || { \
	  echo "Error: '$(TAR)' not found in PATH"; \
	  echo "  macOS:         brew install gnu-tar (provides 'gtar')"; \
	  echo "  Debian/Ubuntu: GNU tar should already be the default 'tar'?"; \
	  exit 1; \
	}
	@$(TAR) --version 2>/dev/null | head -1 | grep -q GNU || { \
	  echo "Error: '$(TAR)' is not GNU tar"; \
	  exit 1; \
	}
	@command -v rsync >/dev/null 2>&1 || { \
	  echo "Error: 'rsync' not found in PATH"; \
	  echo "  macOS:         preinstalled, or 'brew install rsync'"; \
	  echo "  Debian/Ubuntu: 'apt install rsync'"; \
	  exit 1; \
	}
	@command -v shellcheck >/dev/null 2>&1 || { \
	  echo "Error: 'shellcheck' not found in PATH"; \
	  echo "  macOS:         brew install shellcheck"; \
	  echo "  Debian/Ubuntu: apt install shellcheck"; \
	  exit 1; \
	}
	@command -v jq >/dev/null 2>&1 || { \
	  echo "Error: 'jq' not found in PATH"; \
	  echo "  macOS:         brew install jq"; \
	  echo "  Debian/Ubuntu: apt install jq"; \
	  exit 1; \
	}
	@command -v shasum >/dev/null 2>&1 || { \
	  echo "Error: 'shasum' not found in PATH"; \
	  echo "  macOS:         preinstalled"; \
	  echo "  Debian/Ubuntu: apt install perl"; \
	  exit 1; \
	}
	@echo "All required tools present."
	@if [ -d .git ]; then \
	  cp scripts/git-hooks/pre-commit .git/hooks/pre-commit; \
	  chmod +x .git/hooks/pre-commit; \
	  echo "Git hooks installed."; \
	else \
	  echo "Skipping git hook install (.git not found)."; \
	fi

lint: ## Run shellcheck on all shell scripts under templates/ and scripts/
	@echo "Running shellcheck..."
	@shellcheck $$(find templates scripts -name '*.sh' -type f)

precommit: ## Run all pre-commit checks (lint)
	@$(MAKE) lint

update-manifests: ## Refresh manifests/<kind>.<os>.<arch>.json (verified via gpg + cosign)
	@mkdir -p $(TEMP_DIR)
	@rm -f $(TEMP_DIR)/update-manifests.log
	go run ./scripts/manifests --manifests-dir=./manifests --trust-dir=./trust 2>&1 | tee $(TEMP_DIR)/update-manifests.log

update-trust: ## Refresh vmconfig/trust/*.asc keyring files
	@mkdir -p $(TEMP_DIR)
	@rm -f $(TEMP_DIR)/update-trust.log
	go run ./scripts/trust --trust-dir=./trust 2>&1 | tee $(TEMP_DIR)/update-trust.log

# ---------------------------------------------------------------------------
# Build targets
# ---------------------------------------------------------------------------
#
# Each build target produces ./dist/<kind>/, a tree whose paths are
# system-root-relative (e.g. opt/podplane/bin/install.sh). The build is
# deliberately arch-agnostic: the only arch-varying file is the dependency
# manifest, and that gets injected at packaging time via tar --transform
# (see the package targets below). An empty opt/podplane/share/ is
# created during build so the tarball carries a proper directory entry
# for the manifest's parent.
#
# knc inherits knd's tree via overlay rsync (knd/ first, then knc/), so
# any file present in templates/knc/ overrides its knd counterpart.

build: build-knd build-knc ## Build both kind trees under ./dist/

build-knd: setup ## Build ./dist/knd from ./templates/knd
	@mkdir -p $(DIST_DIR)
	rm -rf $(DIST_DIR)/knd
	mkdir -p $(DIST_DIR)/knd
	rsync $(RSYNC_FLAGS) templates/knd/ $(DIST_DIR)/knd/
	mkdir -p $(DIST_DIR)/knd/opt/podplane/share
	# note: install.sh file perms check and tar diff depend on this
	chmod 0755 $(DIST_DIR)/knd/opt/podplane/bin/*.sh

build-knc: setup ## Build ./dist/knc from ./templates/{knd,knc} (knc overlays knd)
	@mkdir -p $(DIST_DIR)
	rm -rf $(DIST_DIR)/knc
	mkdir -p $(DIST_DIR)/knc
	rsync $(RSYNC_FLAGS) templates/knd/ $(DIST_DIR)/knc/
	mkdir -p templates/knc
	rsync $(RSYNC_FLAGS) templates/knc/ $(DIST_DIR)/knc/
	mkdir -p $(DIST_DIR)/knc/opt/podplane/share
	# note: install.sh file perms check and tar diff depend on this
	chmod 0755 $(DIST_DIR)/knc/opt/podplane/bin/*.sh

# ---------------------------------------------------------------------------
# Package targets
# ---------------------------------------------------------------------------
#
# One reproducible tarball per kind/arch, named
# vmconfig_<VERSION>_<kind>_<os>_<arch>.tar.gz
#
# Each package recipe tars three sources together:
#   1. dist/<kind>/                                  - the arch-agnostic build tree
#   2. dist/manifests/<kind>.<os>.<arch>.json        - the arch-specific dependency manifest,
#                                                      staged from manifests/ with $(VERSION)
#                                                      baked in
#   3. dist/manifests/<kind>.<os>.<arch>.sh          - shell vars generated from the dependency
# 													   manifest (above)
#
# The second and third sources are renamed in-archive to
# - /opt/podplane/share/vmconfig-manifest.json
# - /opt/podplane/share/vmconfig-manifest.sh
# via --transform, so the tarball ships exactly one manifest/install plan pair
# regardless of which arch was injected.

package: package-knd package-knc

package-knd: package-knd-amd64 package-knd-arm64 ## Package both knd arch tarballs

package-knc: package-knc-amd64 package-knc-arm64 ## Package both knc arch tarballs

package-knd-amd64: setup build-knd ## Package -> vmconfig_<VER>_knd_<os>_amd64.tar.gz
	@mkdir -p $(DIST_DIR)/manifests
	jq --arg v "$(VERSION)" '.vmconfig.version = $$v | .vmconfig.dependencies.vmconfig.version = $$v' \
	  manifests/knd.$(OS_NAME).amd64.json > $(DIST_DIR)/manifests/knd.$(OS_NAME).amd64.json
	scripts/manifests.sh \
	  $(DIST_DIR)/manifests/knd.$(OS_NAME).amd64.json \
	  $(DIST_DIR)/manifests/knd.$(OS_NAME).amd64.sh
	$(TAR) $(TAR_FLAGS) \
	  --transform 's|^knd\.$(OS_NAME)\.amd64\.json$$|./opt/podplane/share/vmconfig-manifest.json|' \
	  --transform 's|^knd\.$(OS_NAME)\.amd64\.sh$$|./opt/podplane/share/vmconfig-manifest.sh|' \
	  -cf $(DIST_DIR)/vmconfig_$(VERSION)_knd_$(OS_NAME)_amd64.tar.gz \
	  -C $(DIST_DIR)/knd . \
	  -C $(CURDIR)/$(DIST_DIR)/manifests knd.$(OS_NAME).amd64.json knd.$(OS_NAME).amd64.sh
	@echo "Wrote $(DIST_DIR)/vmconfig_$(VERSION)_knd_$(OS_NAME)_amd64.tar.gz"

package-knd-arm64: setup build-knd ## Package -> vmconfig_<VER>_knd_<os>_arm64.tar.gz
	@mkdir -p $(DIST_DIR)/manifests
	jq --arg v "$(VERSION)" '.vmconfig.version = $$v | .vmconfig.dependencies.vmconfig.version = $$v' \
	  manifests/knd.$(OS_NAME).arm64.json > $(DIST_DIR)/manifests/knd.$(OS_NAME).arm64.json
	scripts/manifests.sh \
	  $(DIST_DIR)/manifests/knd.$(OS_NAME).arm64.json \
	  $(DIST_DIR)/manifests/knd.$(OS_NAME).arm64.sh
	$(TAR) $(TAR_FLAGS) \
	  --transform 's|^knd\.$(OS_NAME)\.arm64\.json$$|./opt/podplane/share/vmconfig-manifest.json|' \
	  --transform 's|^knd\.$(OS_NAME)\.arm64\.sh$$|./opt/podplane/share/vmconfig-manifest.sh|' \
	  -cf $(DIST_DIR)/vmconfig_$(VERSION)_knd_$(OS_NAME)_arm64.tar.gz \
	  -C $(DIST_DIR)/knd . \
	  -C $(CURDIR)/$(DIST_DIR)/manifests knd.$(OS_NAME).arm64.json knd.$(OS_NAME).arm64.sh
	@echo "Wrote $(DIST_DIR)/vmconfig_$(VERSION)_knd_$(OS_NAME)_arm64.tar.gz"

package-knc-amd64: setup build-knc ## Package -> vmconfig_<VER>_knc_<os>_amd64.tar.gz
	@mkdir -p $(DIST_DIR)/manifests
	jq --arg v "$(VERSION)" '.vmconfig.version = $$v | .vmconfig.dependencies.vmconfig.version = $$v' \
	  manifests/knc.$(OS_NAME).amd64.json > $(DIST_DIR)/manifests/knc.$(OS_NAME).amd64.json
	scripts/manifests.sh \
	  $(DIST_DIR)/manifests/knc.$(OS_NAME).amd64.json \
	  $(DIST_DIR)/manifests/knc.$(OS_NAME).amd64.sh
	$(TAR) $(TAR_FLAGS) \
	  --transform 's|^knc\.$(OS_NAME)\.amd64\.json$$|./opt/podplane/share/vmconfig-manifest.json|' \
	  --transform 's|^knc\.$(OS_NAME)\.amd64\.sh$$|./opt/podplane/share/vmconfig-manifest.sh|' \
	  -cf $(DIST_DIR)/vmconfig_$(VERSION)_knc_$(OS_NAME)_amd64.tar.gz \
	  -C $(DIST_DIR)/knc . \
	  -C $(CURDIR)/$(DIST_DIR)/manifests knc.$(OS_NAME).amd64.json knc.$(OS_NAME).amd64.sh
	@echo "Wrote $(DIST_DIR)/vmconfig_$(VERSION)_knc_$(OS_NAME)_amd64.tar.gz"

package-knc-arm64: setup build-knc ## Package -> vmconfig_<VER>_knc_<os>_arm64.tar.gz
	@mkdir -p $(DIST_DIR)/manifests
	jq --arg v "$(VERSION)" '.vmconfig.version = $$v | .vmconfig.dependencies.vmconfig.version = $$v' \
	  manifests/knc.$(OS_NAME).arm64.json > $(DIST_DIR)/manifests/knc.$(OS_NAME).arm64.json
	scripts/manifests.sh \
	  $(DIST_DIR)/manifests/knc.$(OS_NAME).arm64.json \
	  $(DIST_DIR)/manifests/knc.$(OS_NAME).arm64.sh
	$(TAR) $(TAR_FLAGS) \
	  --transform 's|^knc\.$(OS_NAME)\.arm64\.json$$|./opt/podplane/share/vmconfig-manifest.json|' \
	  --transform 's|^knc\.$(OS_NAME)\.arm64\.sh$$|./opt/podplane/share/vmconfig-manifest.sh|' \
	  -cf $(DIST_DIR)/vmconfig_$(VERSION)_knc_$(OS_NAME)_arm64.tar.gz \
	  -C $(DIST_DIR)/knc . \
	  -C $(CURDIR)/$(DIST_DIR)/manifests knc.$(OS_NAME).arm64.json knc.$(OS_NAME).arm64.sh
	@echo "Wrote $(DIST_DIR)/vmconfig_$(VERSION)_knc_$(OS_NAME)_arm64.tar.gz"

# ---------------------------------------------------------------------------
# Test targets
# ---------------------------------------------------------------------------
#
# Container-based smoke test for /opt/podplane/bin/install.sh (which itself
# transitively exercises permissions.sh). Runs the script inside a vanilla
# debian:13-slim container against the locally-built package tarball and a
# host-side cache of the dep artifacts. configure.sh is intentionally NOT
# tested here — it requires systemd / Docker-in-Docker and belongs in a
# separate VM-level harness (we use our Podplane CLI for that!)
#
# The host-side dep cache lives at temp/deps-cache/<kind>/<os>/<arch>/ and
# is mounted read-only into the container at /var/cache/vmconfig-deps. The
# container entrypoint copies it into /opt/podplane/artifacts so install.sh's
# rm -rf at the end cannot touch the host cache.

test-install: test-install-knd test-install-knc ## Run install.sh test for both kinds

test-install-knd: package-knd-$(HOST_ARCH) ## Run install.sh in a debian container for knd
	@mkdir -p $(TEMP_DIR)
	@rm -f $(TEMP_DIR)/test-install-knd.log
	scripts/test-install/run.sh knd 2>&1 | tee $(TEMP_DIR)/test-install-knd.log

test-install-knc: package-knc-$(HOST_ARCH) ## Run install.sh in a debian container for knc
	@mkdir -p $(TEMP_DIR)
	@rm -f $(TEMP_DIR)/test-install-knc.log
	scripts/test-install/run.sh knc 2>&1 | tee $(TEMP_DIR)/test-install-knc.log

clean: ## Remove the temp/ and dist/ directories
	rm -rf $(TEMP_DIR) $(DIST_DIR)

# ---------------------------------------------------------------------------
# Dev targets
# ---------------------------------------------------------------------------

# Sync templates to Podplane CLI local VM.
local-sync: ## Build and sync INSTANCE_KIND={knd,knc} into the local VM
	@[ "$(INSTANCE_KIND)" = "knd" ] || [ "$(INSTANCE_KIND)" = "knc" ] || { \
	  echo "INSTANCE_KIND must be knd or knc" >&2; \
	  exit 1; \
	}
	$(MAKE) build-$(INSTANCE_KIND)
	@mkdir -p $(DIST_DIR)/manifests $(DIST_DIR)/$(INSTANCE_KIND)/opt/podplane/share
	jq --arg v "$(VERSION)" '.vmconfig.version = $$v | .vmconfig.dependencies.vmconfig.version = $$v' \
	  manifests/$(INSTANCE_KIND).$(OS_NAME).$(HOST_ARCH).json > $(DIST_DIR)/manifests/$(INSTANCE_KIND).$(OS_NAME).$(HOST_ARCH).json
	scripts/manifests.sh \
	  $(DIST_DIR)/manifests/$(INSTANCE_KIND).$(OS_NAME).$(HOST_ARCH).json \
	  $(DIST_DIR)/manifests/$(INSTANCE_KIND).$(OS_NAME).$(HOST_ARCH).sh
	cp $(DIST_DIR)/manifests/$(INSTANCE_KIND).$(OS_NAME).$(HOST_ARCH).json \
	  $(DIST_DIR)/$(INSTANCE_KIND)/opt/podplane/share/vmconfig-manifest.json
	cp $(DIST_DIR)/manifests/$(INSTANCE_KIND).$(OS_NAME).$(HOST_ARCH).sh \
	  $(DIST_DIR)/$(INSTANCE_KIND)/opt/podplane/share/vmconfig-manifest.sh
	$(PODPLANE_CLI) local sync --chown=root:root \
	  --exclude=/opt/podplane/share/vmconfig-manifest.json \
	  --exclude=/opt/podplane/share/vmconfig-manifest.sh \
	  $(CURDIR)/$(DIST_DIR)/$(INSTANCE_KIND)/ /
	@if ! $(PODPLANE_CLI) local shell "test -f /opt/podplane/share/vmconfig-installed.json" >/dev/null 2>&1; then \
	  $(PODPLANE_CLI) local sync --chown=root:root $(CURDIR)/$(DIST_DIR)/$(INSTANCE_KIND)/opt/podplane/share/ /opt/podplane/share/ && \
	  $(PODPLANE_CLI) local shell "sudo bash /var/lib/cloud/instance/scripts/part-001"; \
	else \
	  $(PODPLANE_CLI) local shell "sudo rm -f /opt/podplane/share/vmconfig-manifest.json /opt/podplane/share/vmconfig-manifest.sh"; \
	  $(PODPLANE_CLI) local shell "sudo /opt/podplane/bin/configure.sh && sudo /opt/podplane/bin/restart.sh"; \
	fi

knd-sync: ## Build and sync knd into the local VM
	$(MAKE) local-sync INSTANCE_KIND=knd

knc-sync: ## Build and sync knc into the local VM
	$(MAKE) local-sync INSTANCE_KIND=knc

local-watch: ## Watch templates and sync/apply INSTANCE_KIND={knd,knc} on change
	@[ "$(INSTANCE_KIND)" = "knd" ] || [ "$(INSTANCE_KIND)" = "knc" ] || { \
	  echo "INSTANCE_KIND must be knd or knc" >&2; \
	  exit 1; \
	}
	@command -v watchexec >/dev/null 2>&1 || { \
	  echo "Error: 'watchexec' not found in PATH" >&2; \
	  echo "  macOS:         brew install watchexec" >&2; \
	  echo "  Debian/Ubuntu: install watchexec from your package manager" >&2; \
	  exit 1; \
	}
	watchexec --shell=bash --watch templates --watch manifests --watch scripts --watch Makefile --exts sh,json --on-busy-update queue -- \
	  '$(MAKE) local-sync INSTANCE_KIND=$(INSTANCE_KIND)'

knd-watch: ## Watch templates and sync/apply knd on change
	$(MAKE) local-watch INSTANCE_KIND=knd

knc-watch: ## Watch templates and sync/apply knc on change
	$(MAKE) local-watch INSTANCE_KIND=knc

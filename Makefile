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

# Version baked into local package artifacts. The release pipeline overrides
# this on the command line (e.g. `make package-knc VERSION=1.0.0`); local
# dev builds keep the conventional "dev" marker, same as deps manifest stubs.
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

.PHONY: help setup lint precommit update-deps update-trust \
        build build-knd build-knc \
        package package-knd package-knc \
        package-knd-amd64 package-knd-arm64 package-knc-amd64 package-knc-arm64 \
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

update-deps: ## Refresh vmconfig/deps/<kind>.<os>.<arch>.json (verified via gpg + cosign)
	@mkdir -p $(TEMP_DIR)
	@rm -f $(TEMP_DIR)/update-deps.log
	go run ./scripts/deps --deps-dir=./deps --trust-dir=./trust 2>&1 | tee $(TEMP_DIR)/update-deps.log

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
# deliberately arch-agnostic: the only arch-varying file is the deps
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

build-knc: setup ## Build ./dist/knc from ./templates/{knd,knc} (knc overlays knd)
	@mkdir -p $(DIST_DIR)
	rm -rf $(DIST_DIR)/knc
	mkdir -p $(DIST_DIR)/knc
	rsync $(RSYNC_FLAGS) templates/knd/ $(DIST_DIR)/knc/
	rsync $(RSYNC_FLAGS) templates/knc/ $(DIST_DIR)/knc/
	mkdir -p $(DIST_DIR)/knc/opt/podplane/share

# ---------------------------------------------------------------------------
# Package targets
# ---------------------------------------------------------------------------
#
# One reproducible tarball per kind/arch, named
# vmconfig_<VERSION>_<kind>_<os>_<arch>.tar.gz
#
# Each package recipe tars two sources together:
#   1. dist/<kind>/                       - the arch-agnostic build tree
#   2. dist/deps/<kind>.<os>.<arch>.json  - the arch-specific deps manifest,
#                                           staged from deps/ with $(VERSION)
#                                           baked in
#
# The second source is renamed in-archive to /opt/podplane/share/deps.json
# via --transform, so the tarball ships exactly one deps.json regardless
# of which arch's manifest was injected.

package: package-knd package-knc

package-knd: package-knd-amd64 package-knd-arm64 ## Package both knd arch tarballs

package-knc: package-knc-amd64 package-knc-arm64 ## Package both knc arch tarballs

package-knd-amd64: setup build-knd ## Package -> vmconfig_<VER>_knd_<os>_amd64.tar.gz
	@mkdir -p $(DIST_DIR)/deps
	jq --arg v "$(VERSION)" '.vmconfig.version = $$v | .vmconfig.dependencies.vmconfig.version = $$v' \
	  deps/knd.$(OS_NAME).amd64.json > $(DIST_DIR)/deps/knd.$(OS_NAME).amd64.json
	$(TAR) $(TAR_FLAGS) \
	  --transform 's|^knd\.$(OS_NAME)\.amd64\.json$$|./opt/podplane/share/deps.json|' \
	  -cf $(DIST_DIR)/vmconfig_$(VERSION)_knd_$(OS_NAME)_amd64.tar.gz \
	  -C $(DIST_DIR)/knd . \
	  -C $(CURDIR)/$(DIST_DIR)/deps knd.$(OS_NAME).amd64.json
	@echo "Wrote $(DIST_DIR)/vmconfig_$(VERSION)_knd_$(OS_NAME)_amd64.tar.gz"

package-knd-arm64: setup build-knd ## Package -> vmconfig_<VER>_knd_<os>_arm64.tar.gz
	@mkdir -p $(DIST_DIR)/deps
	jq --arg v "$(VERSION)" '.vmconfig.version = $$v | .vmconfig.dependencies.vmconfig.version = $$v' \
	  deps/knd.$(OS_NAME).arm64.json > $(DIST_DIR)/deps/knd.$(OS_NAME).arm64.json
	$(TAR) $(TAR_FLAGS) \
	  --transform 's|^knd\.$(OS_NAME)\.arm64\.json$$|./opt/podplane/share/deps.json|' \
	  -cf $(DIST_DIR)/vmconfig_$(VERSION)_knd_$(OS_NAME)_arm64.tar.gz \
	  -C $(DIST_DIR)/knd . \
	  -C $(CURDIR)/$(DIST_DIR)/deps knd.$(OS_NAME).arm64.json
	@echo "Wrote $(DIST_DIR)/vmconfig_$(VERSION)_knd_$(OS_NAME)_arm64.tar.gz"

package-knc-amd64: setup build-knc ## Package -> vmconfig_<VER>_knc_<os>_amd64.tar.gz
	@mkdir -p $(DIST_DIR)/deps
	jq --arg v "$(VERSION)" '.vmconfig.version = $$v | .vmconfig.dependencies.vmconfig.version = $$v' \
	  deps/knc.$(OS_NAME).amd64.json > $(DIST_DIR)/deps/knc.$(OS_NAME).amd64.json
	$(TAR) $(TAR_FLAGS) \
	  --transform 's|^knc\.$(OS_NAME)\.amd64\.json$$|./opt/podplane/share/deps.json|' \
	  -cf $(DIST_DIR)/vmconfig_$(VERSION)_knc_$(OS_NAME)_amd64.tar.gz \
	  -C $(DIST_DIR)/knc . \
	  -C $(CURDIR)/$(DIST_DIR)/deps knc.$(OS_NAME).amd64.json
	@echo "Wrote $(DIST_DIR)/vmconfig_$(VERSION)_knc_$(OS_NAME)_amd64.tar.gz"

package-knc-arm64: setup build-knc ## Package -> vmconfig_<VER>_knc_<os>_arm64.tar.gz
	@mkdir -p $(DIST_DIR)/deps
	jq --arg v "$(VERSION)" '.vmconfig.version = $$v | .vmconfig.dependencies.vmconfig.version = $$v' \
	  deps/knc.$(OS_NAME).arm64.json > $(DIST_DIR)/deps/knc.$(OS_NAME).arm64.json
	$(TAR) $(TAR_FLAGS) \
	  --transform 's|^knc\.$(OS_NAME)\.arm64\.json$$|./opt/podplane/share/deps.json|' \
	  -cf $(DIST_DIR)/vmconfig_$(VERSION)_knc_$(OS_NAME)_arm64.tar.gz \
	  -C $(DIST_DIR)/knc . \
	  -C $(CURDIR)/$(DIST_DIR)/deps knc.$(OS_NAME).arm64.json
	@echo "Wrote $(DIST_DIR)/vmconfig_$(VERSION)_knc_$(OS_NAME)_arm64.tar.gz"

clean: ## Remove the temp/ and dist/ directories
	rm -rf $(TEMP_DIR) $(DIST_DIR)

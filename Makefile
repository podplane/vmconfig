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

.PHONY: help update-deps update-trust clean

help: ## Show this help message
	@printf "Usage: make <target>\n\nTargets:\n"
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / { printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2 }' $(MAKEFILE_LIST)
	@printf "\nLogs:    %s/<target>.log (recreated each run)\n" "$(TEMP_DIR)"

setup: ## Verify required runtime tools are installed (gtar, rsync)
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
	@echo "All required tools present."

update-deps: ## Refresh vmconfig/deps/<kind>.<os>.<arch>.json (verified via gpg + cosign)
	@mkdir -p $(TEMP_DIR)
	@rm -f $(TEMP_DIR)/update-deps.log
	go run ./scripts/deps --deps-dir=./deps --trust-dir=./trust 2>&1 | tee $(TEMP_DIR)/update-deps.log

update-trust: ## Refresh vmconfig/trust/*.asc keyring files
	@mkdir -p $(TEMP_DIR)
	@rm -f $(TEMP_DIR)/update-trust.log
	go run ./scripts/trust --trust-dir=./trust 2>&1 | tee $(TEMP_DIR)/update-trust.log

clean: ## Remove the temp/ log directory
	rm -rf $(TEMP_DIR)

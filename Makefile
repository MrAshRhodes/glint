# Glint - build, run and package. `make help` lists the targets.
#
# Variables (override on the command line, e.g. `make app CONFIG=debug`):
#   VERSION      app/release version         (default: contents of the VERSION file)
#   CONFIG       release | debug for app/universal/run/install   (default: release)
#   INSTALL_DIR  where `make install` copies Glint.app           (default: /Applications)
#
# SwiftPM is run through Scripts/swiftw.sh, which adds what a Command Line Tools-only
# machine needs. The SWIFTW_* environment variables it reads are documented there.

SHELL := /bin/bash
.DEFAULT_GOAL := help

VERSION ?= $(strip $(shell cat VERSION 2>/dev/null))
CONFIG ?= release
INSTALL_DIR ?= /Applications

SWIFTW := Scripts/swiftw.sh
APP := dist/Glint.app
ZIP := dist/Glint-$(VERSION).zip
VERSION_ARG := $(if $(VERSION),--version $(VERSION),)

.PHONY: help build release test app universal run zip dmg install icon tap prepare-release clean

help: ## Show this help
	@echo "Usage: make <target> [VERSION=x.y.z] [CONFIG=release|debug] [INSTALL_DIR=/Applications]"
	@echo
	@awk 'BEGIN {FS = ":.*## "} /^[a-zA-Z_-]+:.*## / {printf "  %-16s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

build: ## Debug build of every target
	$(SWIFTW) build

release: ## Optimized build of every target
	$(SWIFTW) build -c release

test: ## Run the test suite (Swift Testing)
	$(SWIFTW) test

app: ## Assemble dist/Glint.app for this Mac and sign it ad-hoc
	Scripts/build_app.sh $(VERSION_ARG) --configuration $(CONFIG)

universal: ## Assemble a universal (arm64 + x86_64) dist/Glint.app
	Scripts/build_app.sh --universal $(VERSION_ARG) --configuration $(CONFIG)

run: app ## Build dist/Glint.app and open it
	open $(APP)

zip: ## Universal build packaged as dist/Glint-<version>.zip (+ .sha256 and glint.rb)
	Scripts/package_release.sh $(VERSION_ARG) --formats zip

dmg: ## Universal build packaged as dist/Glint-<version>.dmg (+ .sha256)
	Scripts/package_release.sh $(VERSION_ARG) --formats dmg

install: app ## Build, then copy Glint.app into INSTALL_DIR
	@if pgrep -x Glint >/dev/null; then echo "error: Glint is running; quit it before installing" >&2; exit 1; fi
	mkdir -p "$(INSTALL_DIR)"
	rm -rf "$(INSTALL_DIR)/Glint.app"
	ditto $(APP) "$(INSTALL_DIR)/Glint.app"
	@echo "Installed $(INSTALL_DIR)/Glint.app"

icon: ## Regenerate Resources/AppIcon.icns and docs/assets/icon-1024.png
	$(SWIFTW) Scripts/make_icon.swift

$(ZIP):
	Scripts/package_release.sh $(VERSION_ARG) --formats zip

tap: $(ZIP) ## Render the Homebrew cask to dist/glint.rb (publish it with Scripts/update_tap.sh)
	Scripts/render_cask.sh $(VERSION_ARG) --zip $(ZIP) --output dist/glint.rb

prepare-release: ## Set VERSION and move Unreleased changelog entries under it (VERSION=x.y.z)
	@if [[ "$(origin VERSION)" == file ]]; then echo "error: pass the new version, e.g. make prepare-release VERSION=1.2.3" >&2; exit 1; fi
	node .github/scripts/changelog.cjs release "$(VERSION)"
	printf '%s\n' "$(VERSION)" > VERSION

clean: ## Remove .build and dist
	rm -rf .build dist

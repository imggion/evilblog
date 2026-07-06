.PHONY: debug release build-all deploy docker-build up test serve run session-secret clean help

BUILD_ALL_OPTIMIZE ?= ReleaseSmall
BUILD_ALL_VERSION ?= $(shell git describe --tags --match 'v[0-9]*' --dirty 2>/dev/null || printf 'v0.0.0-dev')
DIST_DIR ?= dist
ENV_FILE ?= .env.prod
VERSION ?=
RELEASE_TITLE ?= evilblog $(BUILD_ALL_VERSION)
RELEASE_NOTES ?= Release $(BUILD_ALL_VERSION)
IMAGE_TAG ?= $(shell git describe --tags --match 'v[0-9]*' --dirty 2>/dev/null || git rev-parse --short HEAD 2>/dev/null || printf 'local')
DOCKER_IMAGE_TAG = $(if $(VERSION),$(VERSION),$(IMAGE_TAG))

debug:
	zig build -Doptimize=Debug

release:
	zig build -Doptimize=ReleaseFast

build-all:
	rm -rf "$(DIST_DIR)"
	mkdir -p "$(DIST_DIR)/tmp"
	zig build -Doptimize=$(BUILD_ALL_OPTIMIZE) -Dtarget=x86_64-linux-musl "-Dversion=$(BUILD_ALL_VERSION)" --prefix "$(DIST_DIR)/tmp/linux-x86_64"
	cp "$(DIST_DIR)/tmp/linux-x86_64/bin/evilblog" "$(DIST_DIR)/evilblog-$(BUILD_ALL_VERSION)-linux-x86_64"
	zig build -Doptimize=$(BUILD_ALL_OPTIMIZE) -Dtarget=aarch64-linux-musl "-Dversion=$(BUILD_ALL_VERSION)" --prefix "$(DIST_DIR)/tmp/linux-aarch64"
	cp "$(DIST_DIR)/tmp/linux-aarch64/bin/evilblog" "$(DIST_DIR)/evilblog-$(BUILD_ALL_VERSION)-linux-aarch64"
	zig build -Doptimize=$(BUILD_ALL_OPTIMIZE) -Dtarget=arm-linux-musleabihf "-Dversion=$(BUILD_ALL_VERSION)" --prefix "$(DIST_DIR)/tmp/linux-armv7"
	cp "$(DIST_DIR)/tmp/linux-armv7/bin/evilblog" "$(DIST_DIR)/evilblog-$(BUILD_ALL_VERSION)-linux-armv7"
	zig build -Doptimize=$(BUILD_ALL_OPTIMIZE) -Dtarget=x86_64-windows-gnu "-Dversion=$(BUILD_ALL_VERSION)" --prefix "$(DIST_DIR)/tmp/windows-x86_64"
	cp "$(DIST_DIR)/tmp/windows-x86_64/bin/evilblog.exe" "$(DIST_DIR)/evilblog-$(BUILD_ALL_VERSION)-windows-x86_64.exe"
	zig build -Doptimize=$(BUILD_ALL_OPTIMIZE) -Dtarget=x86-windows-gnu "-Dversion=$(BUILD_ALL_VERSION)" --prefix "$(DIST_DIR)/tmp/windows-x86"
	cp "$(DIST_DIR)/tmp/windows-x86/bin/evilblog.exe" "$(DIST_DIR)/evilblog-$(BUILD_ALL_VERSION)-windows-x86.exe"
	rm -rf "$(DIST_DIR)/tmp"

deploy:
	@test -z "$$(git status --porcelain)" || (echo "Refusing deploy with uncommitted changes."; exit 1)
	@command -v gh >/dev/null || (echo "gh CLI is required."; exit 1)
	@gh auth status >/dev/null 2>&1 || (echo "gh auth status failed; run gh auth login."; exit 1)
	@HEAD_TAG=$$(git tag --points-at HEAD | head -n1); \
		if [ -n "$$HEAD_TAG" ]; then echo "HEAD already tagged as $$HEAD_TAG; nothing to deploy."; exit 1; fi
	@DEPLOY_TAG=$$(git describe --tags --match 'v[0-9]*' --abbrev=0 2>/dev/null | sed 's/^v//' | awk -F. '{printf "v%d.%d.%d", $$1, $$2, $$3+1}'); \
		echo "Tagging $$DEPLOY_TAG at HEAD"; \
		git tag "$$DEPLOY_TAG" && git push origin "$$DEPLOY_TAG"; \
		$(MAKE) build-all BUILD_ALL_VERSION="$$DEPLOY_TAG"; \
		cd "$(DIST_DIR)" && set -- evilblog-"$$DEPLOY_TAG"-*; test -e "$$1" || (echo "No release assets found in $(DIST_DIR)."; exit 1); \
		gh release create "$$DEPLOY_TAG" "$$@" --title "evilblog $$DEPLOY_TAG" --notes "Release $$DEPLOY_TAG" --target "$$(git rev-parse HEAD)"

docker-build:
	@test -n "$(VERSION)" || (echo "VERSION is required, example: make docker-build VERSION=1.2.3"; exit 1)
	docker build . -t "evilblog:$(VERSION)" --build-arg "VERSION=$(VERSION)"

up:
	@test -f "$(ENV_FILE)" || (echo "$(ENV_FILE) missing, copy .env.prod.example"; exit 1)
	EVILBLOG_ENV_FILE="$(ENV_FILE)" IMAGE_TAG="$(DOCKER_IMAGE_TAG)" VERSION="$(VERSION)" docker compose --env-file "$(ENV_FILE)" up --build -d

test:
	zig build test

serve:
	zig build run

run: serve

session-secret:
	openssl rand -hex 32

clean:
	rm -rf zig-out zig-cache .zig-cache

help:
	@echo "Available commands:"
	@echo "  make debug    Build in Debug mode"
	@echo "  make release  Build in ReleaseFast mode"
	@echo "  make build-all  Build versioned ReleaseSmall binaries for Linux and Windows into dist/"
	@echo "  make deploy   Build all release binaries and create the GitHub release"
	@echo "  make docker-build VERSION=1.2.3  Build Docker image evilblog:VERSION"
	@echo "  make up       Start Docker Compose with Redis"
	@echo "  make test     Run tests"
	@echo "  make serve    Start the webserver"
	@echo "  make run      Alias for serve"
	@echo "  make session-secret  Generate a SESSION_SECRET"
	@echo "  make clean    Remove Zig build artifacts"

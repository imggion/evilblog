.PHONY: debug release build-all docker-build up test serve run session-secret clean help

BUILD_ALL_OPTIMIZE ?= ReleaseSmall
BUILD_ALL_VERSION ?= $(shell git describe --tags --match 'v[0-9]*' --dirty 2>/dev/null || printf 'v0.0.0-dev')
DIST_DIR ?= dist
ENV_FILE ?= .env.prod
VERSION ?=
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

docker-build:
	@test -n "$(VERSION)" || (echo "VERSION is required, example: make docker-build VERSION=1.2.3"; exit 1)
	docker build . -t "evilblog:$(VERSION)" --build-arg "VERSION=$(VERSION)"

up:
	@test -f "$(ENV_FILE)" || (echo "$(ENV_FILE) missing, copy .env.prod.example"; exit 1)
	EVILBLOG_ENV_FILE="$(ENV_FILE)" IMAGE_TAG="$(DOCKER_IMAGE_TAG)" VERSION="$(VERSION)" docker compose --env-file "$(ENV_FILE)" up --build

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
	@echo "  make docker-build VERSION=1.2.3  Build Docker image evilblog:VERSION"
	@echo "  make up       Start Docker Compose with Redis"
	@echo "  make test     Run tests"
	@echo "  make serve    Start the webserver"
	@echo "  make run      Alias for serve"
	@echo "  make session-secret  Generate a SESSION_SECRET"
	@echo "  make clean    Remove Zig build artifacts"

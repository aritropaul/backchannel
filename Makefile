# WA: native macOS WhatsApp client.
#   make          build core + app (Release) into build/WA.app
#   make run      build and launch
#   make core     just the Go c-archive

SDK      := $(shell xcrun --sdk macosx --show-sdk-path)
GO       ?= $(shell command -v go || echo /opt/homebrew/bin/go)
CORE_SRC := $(wildcard core/*.go) core/go.mod core/go.sum Makefile
APP      := build/WA.app
CONFIG   ?= Release

.PHONY: all core app run clean project

all: app

# The archive links against the system libsqlite3 (-tags libsqlite3, SDK headers
# first) so Go and Swift share one SQLite in-process; two copies touching the
# same database file can corrupt it.
build/libwacore.a: $(CORE_SRC)
	@mkdir -p build
	cd core && CGO_ENABLED=1 MACOSX_DEPLOYMENT_TARGET=26.0 \
		CGO_CFLAGS="-I$(SDK)/usr/include -mmacosx-version-min=26.0 -O2" \
		CGO_LDFLAGS="-mmacosx-version-min=26.0" \
		$(GO) build -tags "libsqlite3 sqlite_omit_load_extension" -trimpath -buildmode=c-archive -o ../build/libwacore.a .

core: build/libwacore.a

app/WA.xcodeproj: app/project.yml
	cd app && xcodegen generate --quiet

project: app/WA.xcodeproj

app: core app/WA.xcodeproj
	xcodebuild -project app/WA.xcodeproj -scheme WA -configuration $(CONFIG) \
		-derivedDataPath build/dd -quiet build
	@rm -rf $(APP) && cp -R build/dd/Build/Products/$(CONFIG)/WA.app $(APP)
	@echo "built $(APP)"

run: app
	open $(APP)

clean:
	rm -rf build app/WA.xcodeproj

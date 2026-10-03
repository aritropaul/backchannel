# Backchannel: a native Mac app for WhatsApp (unofficial).
#   make          build core + app (Release) into build/Backchannel.app
#   make dmg      the app in a disk image, build/Backchannel-<version>.dmg
#   make run      build and launch
#   make core     just the Go c-archive

SDK      := $(shell xcrun --sdk macosx --show-sdk-path)
GO       ?= $(shell command -v go || echo /opt/homebrew/bin/go)
CORE_SRC := $(wildcard core/*.go) core/go.mod core/go.sum Makefile
APP      := build/Backchannel.app
CONFIG   ?= Release
LSREG    := /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

.PHONY: all core app run clean project dmg site

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

app/Backchannel.xcodeproj: app/project.yml
	cd app && xcodegen generate --quiet

project: app/Backchannel.xcodeproj

app: core app/Backchannel.xcodeproj
	xcodebuild -project app/Backchannel.xcodeproj -scheme Backchannel -configuration $(CONFIG) \
		-derivedDataPath build/dd -quiet build
	@# One app on disk: move Xcode's product out rather than copying it (a second copy
	@# shows up in Spotlight and Launchpad and can be launched by bundle ID).
	@rm -rf $(APP) && mv build/dd/Build/Products/$(CONFIG)/Backchannel.app $(APP)
	@# xcodebuild registers its product with LaunchServices; point that at the moved copy.
	@$(LSREG) -u $(CURDIR)/build/dd/Build/Products/$(CONFIG)/Backchannel.app 2>/dev/null || true
	@$(LSREG) -f $(CURDIR)/$(APP)
	@echo "built $(APP)"

run: app
	open $(APP)

dmg: app
	tools/make_dmg.sh $(APP)

# The static site in site/ links the DMG next to index.html.
site: dmg
	cp build/Backchannel-*.dmg site/

clean:
	rm -rf build app/Backchannel.xcodeproj app/WA.xcodeproj

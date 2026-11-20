# Juice build targets.
#
#   make            release .app bundle, same as `make app`
#   make install    build, copy to /Applications and launch
#   make test       SwiftPM tests
#   make probe      print one reading per device as JSON (uses the staged bundle)
#   make clean      remove all build output

EXEC   := Juice
CONFIG := release

# Build output lives under ~/Library/Caches so no sync engine adds extended attributes that
# codesign refuses.
STAGE    := $(HOME)/Library/Caches/JuiceBuild
SCRATCH  := $(STAGE)/scratch
APPNAME  := Juice.app
BUNDLE   := $(STAGE)/$(APPNAME)
CONTENTS := $(BUNDLE)/Contents

# Prefer a Developer ID, then Apple Development, then ad-hoc. The Bluetooth grant is keyed on
# a stable signature; an ad-hoc one changes every build and asks again.
find-identity = $(shell security find-identity -v -p codesigning 2>/dev/null \
                  | grep "$(1)" | head -1 | sed -E 's/.*"(.*)".*/\1/')
SIGN_ID := $(or $(call find-identity,Developer ID Application),$(call find-identity,Apple Development),-)

.PHONY: all build test app run install probe clean

all: app

build:
	swift build -c $(CONFIG) --scratch-path "$(SCRATCH)"

test:
	swift test --scratch-path "$(SCRATCH)"

app: build
	@rm -rf "$(BUNDLE)"
	@mkdir -p "$(CONTENTS)/MacOS" "$(CONTENTS)/Resources"
	@cp "$$(swift build -c $(CONFIG) --scratch-path "$(SCRATCH)" --show-bin-path)/$(EXEC)" "$(CONTENTS)/MacOS/$(EXEC)"
	@cp Resources/Info.plist "$(CONTENTS)/Info.plist"
	@printf 'APPL????' > "$(CONTENTS)/PkgInfo"
	@xattr -cr "$(BUNDLE)"
	@codesign --force --sign "$(SIGN_ID)" \
		--entitlements Resources/$(EXEC).entitlements \
		--options runtime \
		--timestamp=none \
		"$(BUNDLE)"
	@echo "built $(BUNDLE)  [signed: $(SIGN_ID)]"

run: app
	@pkill -x $(EXEC) 2>/dev/null || true
	@open "$(BUNDLE)"

install: app
	@pkill -x $(EXEC) 2>/dev/null || true
	@rm -rf "/Applications/$(APPNAME)"
	@cp -R "$(BUNDLE)" "/Applications/$(APPNAME)"
	@open "/Applications/$(APPNAME)"
	@echo "installed to /Applications/$(APPNAME)"

probe: app
	@"$(CONTENTS)/MacOS/$(EXEC)" --probe

clean:
	@rm -rf .build "$(STAGE)"

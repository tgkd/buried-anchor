-include local.mk

IDENTITY ?=
CONFIG ?= debug
TIMESTAMP ?= none
BUNDLE_ID := com.buriedanchor.mixer
APP_DIR ?= .build
APP := $(APP_DIR)/BuriedAnchor.app

.PHONY: build bundle sign run stop prod prod-run install logs identities reset-tcc clean distclean

build:
	swift build -c $(CONFIG)

bundle: build
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS
	cp "$$(swift build -c $(CONFIG) --show-bin-path)/BuriedAnchor" $(APP)/Contents/MacOS/BuriedAnchor
	cp Resources/Info.plist $(APP)/Contents/Info.plist
	plutil -insert BuriedAnchorRevision -string "$$(git describe --always --dirty 2>/dev/null || echo unknown)" $(APP)/Contents/Info.plist
	plutil -insert BuriedAnchorBuildDate -string "$$(date -u +%Y-%m-%dT%H:%M:%SZ)" $(APP)/Contents/Info.plist

sign: bundle
	@test -n "$(IDENTITY)" || { \
	  echo "IDENTITY is not set."; \
	  echo "Run 'make identities', then: echo 'IDENTITY=<hash>' > local.mk"; \
	  echo "Do not ad-hoc sign — see README, it breaks the TCC grant on every rebuild."; \
	  exit 1; }
	codesign --force --sign $(IDENTITY) --options runtime --timestamp=$(TIMESTAMP) $(APP)
	@codesign --verify --strict --verbose=2 $(APP) 2>&1 | tail -2
	@codesign -dv $(APP) 2>&1 | grep -E 'Identifier|TeamIdentifier|flags'

run: sign
	@pkill -x BuriedAnchor 2>/dev/null || true
	open -a "$(CURDIR)/$(APP)"
	@echo "launched via LaunchServices; never run the inner binary directly or TCC denies silently"

prod:
	$(MAKE) CONFIG=release APP_DIR=dist TIMESTAMP=none sign
	@echo "release bundle at dist/BuriedAnchor.app"

prod-run: prod
	@pkill -x BuriedAnchor 2>/dev/null || true
	open -a "$(CURDIR)/dist/BuriedAnchor.app"
	@echo "launched via LaunchServices; never run the inner binary directly or TCC denies silently"

install: prod
	@pkill -x BuriedAnchor 2>/dev/null || true
	rm -rf /Applications/BuriedAnchor.app
	cp -R dist/BuriedAnchor.app /Applications/BuriedAnchor.app
	@echo "installed to /Applications/BuriedAnchor.app"

stop:
	@pkill -x BuriedAnchor 2>/dev/null || true

logs:
	log stream --predicate 'subsystem == "$(BUNDLE_ID)"' --style compact --level debug

identities:
	security find-identity -v -p codesigning

reset-tcc:
	tccutil reset SystemAudioCaptureRequests $(BUNDLE_ID)

clean:
	rm -rf .build

distclean: clean
	rm -rf dist

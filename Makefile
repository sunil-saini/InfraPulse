SHELL := /bin/bash

APP_NAME := InfraPulse
RELEASE_REPO ?= sunil-saini/homebrew-tools
APP_RELEASE_REPO ?= sunil-saini/InfraPulse
TAP_DIR ?= /private/tmp/homebrew-tools
CASK_FILE := $(TAP_DIR)/Casks/infrapulse.rb
VERSION := $(shell /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)
ZIP := .build/$(APP_NAME)-$(VERSION).zip
DEBUG_APP := .build/$(APP_NAME)-debug.app
DEBUG_LOG := /private/tmp/infrapulse-debug.log

PROFILE ?=

.PHONY: build run stop package check bump-version require-clean \
        release publish publish-artifact tap-checkout sync-tap install

build:
	swift build -c debug

stop:
	@/bin/launchctl bootout gui/$$(id -u)/com.infrapulse >/dev/null 2>&1 || true
	@# LaunchServices registers the installed app as application.com.infrapulse.*,
	@# not under the label above, so a bootout alone leaves it running.
	@/usr/bin/pkill -x $(APP_NAME) >/dev/null 2>&1 || true
	@sleep 1
	@if /usr/bin/pgrep -x $(APP_NAME) >/dev/null 2>&1; then \
		echo "Warning: an InfraPulse process survived stop:"; \
		/bin/ps -ax -o pid,comm | grep '[M]acOS/InfraPulse'; \
	fi

run: stop
	swift build -c debug
	@rm -rf $(DEBUG_APP)
	@mkdir -p $(DEBUG_APP)/Contents/MacOS $(DEBUG_APP)/Contents/Resources
	@cp .build/debug/$(APP_NAME) $(DEBUG_APP)/Contents/MacOS/$(APP_NAME)
	@cp -R .build/debug/$(APP_NAME)_$(APP_NAME).bundle $(DEBUG_APP)/Contents/Resources/
	@cp Info.plist $(DEBUG_APP)/Contents/Info.plist
	@# Without a distinct identity the local build and an installed release look
	@# identical in the menu bar. MenuContent renders "dev" bare, with no "v".
	@/usr/libexec/PlistBuddy \
		-c 'Set :CFBundleIdentifier com.infrapulse.debug' \
		-c 'Set :CFBundleDisplayName InfraPulse Debug' \
		-c 'Set :CFBundleShortVersionString dev' \
		$(DEBUG_APP)/Contents/Info.plist
	@chmod +x $(DEBUG_APP)/Contents/MacOS/$(APP_NAME)
	@/usr/bin/codesign --force --deep --sign - $(DEBUG_APP)
	@nohup $(DEBUG_APP)/Contents/MacOS/$(APP_NAME) $(PROFILE) >$(DEBUG_LOG) 2>&1 </dev/null &
	@sleep 2
	@echo "Running local debug build (shown as dev)$(if $(PROFILE), with profile $(PROFILE))"
	@echo "Live InfraPulse processes:"
	@/bin/ps -ax -o pid,comm | grep '[M]acOS/InfraPulse' | sed 's|^|  |'

package:
	./package-app.sh

check: package
	@unzip -t "$(ZIP)" >/dev/null
	@echo "Package verified: $(ZIP)"
	@echo "SHA256: $$(shasum -a 256 "$(ZIP)" | awk '{print $$1}')"

bump-version:
	@current="$$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)"; \
	IFS=. read -r major minor patch <<< "$$current"; \
	next="$$major.$$minor.$$((patch + 1))"; \
	/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $$next" Info.plist; \
	echo "Version: $$current -> $$next"

require-clean:
	@test -z "$$(git status --porcelain)" || (echo "Working tree is not clean; commit or stash changes before release."; exit 1)
	@# A rejected push would leave a release no commit on origin corresponds to,
	@# so prove it will fast-forward before anything is published.
	@git fetch -q origin main
	@git merge-base --is-ancestor origin/main HEAD || \
		(echo "Local main is behind origin/main; pull before releasing."; exit 1)

release: require-clean
	@set -e; \
	$(MAKE) --no-print-directory bump-version; \
	next="$$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)"; \
	trap 'status=$$?; if [ $$status -ne 0 ]; then git checkout -- Info.plist; fi; exit $$status' EXIT; \
	$(MAKE) check VERSION=$$next; \
	git add Info.plist; \
	git commit -m "Release $(APP_NAME) $$next"; \
	git push origin main; \
	trap - EXIT; \
	$(MAKE) publish-artifact VERSION=$$next || { \
		echo "Release commit is pushed but publishing failed."; \
		echo "Retry with: make publish-artifact VERSION=$$next"; \
		exit 1; \
	}; \
	echo "Released $(APP_NAME) $$next"

publish: release

# Each repo is pushed before its release, so --target names the commit that
# actually carries the version rather than the default branch head.
publish-artifact: check sync-tap
	@set -e; \
	SHA256=$$(shasum -a 256 "$(ZIP)" | awk '{print $$1}'); \
	for repo in "$(APP_RELEASE_REPO)" "$(RELEASE_REPO)"; do \
		if gh release view "v$(VERSION)" --repo "$$repo" >/dev/null 2>&1; then \
			echo "Release v$(VERSION) already exists on $$repo."; \
			echo "Overwriting it would republish a version number with different bits; bump instead."; \
			exit 1; \
		fi; \
	done; \
	cp cask/infrapulse.rb "$(CASK_FILE)"; \
	perl -0pi -e 's/__VERSION__/$(VERSION)/g; s/__SHA256__/'"$$SHA256"'/g' "$(CASK_FILE)"; \
	gh release create "v$(VERSION)" "$(ZIP)" --repo "$(APP_RELEASE_REPO)" \
		--target "$$(git rev-parse HEAD)" --title "v$(VERSION)" --generate-notes; \
	git -C "$(TAP_DIR)" add "$(CASK_FILE)"; \
	git -C "$(TAP_DIR)" commit -m "Release $(APP_NAME) $(VERSION)"; \
	git -C "$(TAP_DIR)" push origin main; \
	gh release create "v$(VERSION)" "$(ZIP)" --repo "$(RELEASE_REPO)" \
		--target "$$(git -C "$(TAP_DIR)" rev-parse HEAD)" \
		--title "$(APP_NAME) $(VERSION)" --notes "Internal $(APP_NAME) release $(VERSION)."; \
	echo "Released $(APP_NAME) $(VERSION)"

tap-checkout:
	@# TAP_DIR defaults under /private/tmp, which macOS prunes, so the checkout
	@# goes missing between releases. Clone it back rather than failing.
	@if [ ! -d "$(TAP_DIR)/.git" ]; then \
		echo "Tap checkout missing; cloning $(RELEASE_REPO) into $(TAP_DIR)"; \
		rm -rf "$(TAP_DIR)"; \
		gh repo clone "$(RELEASE_REPO)" "$(TAP_DIR)"; \
	fi

sync-tap: tap-checkout
	git -C "$(TAP_DIR)" pull --ff-only

install: sync-tap
	brew reinstall --cask sunil-saini/tools/infrapulse

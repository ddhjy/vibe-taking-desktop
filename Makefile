APP_NAME := VibeTaking
PROJECT_DIR := VibeTaking
PROJECT_FILE := $(PROJECT_DIR)/VibeTaking.xcodeproj
SCHEME := $(APP_NAME)
CONFIGURATION := Release
INFO_PLIST := $(PROJECT_DIR)/VibeTaking/Resources/Info.plist
ENTITLEMENTS_FILE := $(PROJECT_DIR)/VibeTaking/Resources/VibeTaking.entitlements

DERIVED_DATA := build/derived
BUILD_APP_PATH := $(DERIVED_DATA)/Build/Products/$(CONFIGURATION)/$(APP_NAME).app
RELEASE_DIR := dist/release
RELEASE_APP := $(RELEASE_DIR)/$(APP_NAME).app
APPLICATIONS_DIR ?= /Applications
INSTALL_APP := $(APPLICATIONS_DIR)/$(APP_NAME).app
APP_BUNDLE_ID := $(shell /usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$(INFO_PLIST)" 2>/dev/null || echo com.vibetaking.app)
VERSION := $(shell /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$(INFO_PLIST)" 2>/dev/null || echo 1.0.0)
RELEASE_ZIP := $(RELEASE_DIR)/$(APP_NAME)-$(VERSION).zip

.PHONY: help build release release-app release-zip install clean

help:
	@echo "Targets:"
	@echo "  make build        Build $(APP_NAME) with Release configuration"
	@echo "  make release      Build and package release app + zip"
	@echo "  make release-app  Copy built .app to $(RELEASE_DIR)"
	@echo "  make release-zip  Create zip package from $(RELEASE_APP)"
	@echo "  make install      Build latest app, reinstall to $(APPLICATIONS_DIR), and open it"
	@echo "  make clean        Remove local build/package outputs"

build:
	xcodebuild \
		-project "$(PROJECT_FILE)" \
		-scheme "$(SCHEME)" \
		-configuration "$(CONFIGURATION)" \
		-derivedDataPath "$(DERIVED_DATA)" \
		build

release: build release-app release-zip
	@echo "Release artifacts:"
	@echo "  $(RELEASE_APP)"
	@echo "  $(RELEASE_ZIP)"

release-app:
	mkdir -p "$(RELEASE_DIR)"
	rm -rf "$(RELEASE_APP)"
	cp -R "$(BUILD_APP_PATH)" "$(RELEASE_APP)"

release-zip:
	rm -f "$(RELEASE_ZIP)"
	ditto -c -k --sequesterRsrc --keepParent "$(RELEASE_APP)" "$(RELEASE_ZIP)"

install: build release-app
	@echo "Stopping running $(APP_NAME) ..."
	@osascript -e 'tell application "$(APP_NAME)" to quit' >/dev/null 2>&1 || true
	@sleep 1
	@if pgrep -f "/$(APP_NAME).app/Contents/MacOS/$(APP_NAME)" >/dev/null 2>&1; then \
		pkill -f "/$(APP_NAME).app/Contents/MacOS/$(APP_NAME)" >/dev/null 2>&1 || true; \
	fi
	@echo "Re-signing $(RELEASE_APP) with stable app identity ..."
	codesign --force --sign - \
		--entitlements "$(ENTITLEMENTS_FILE)" \
		-r='designated => identifier "$(APP_BUNDLE_ID)"' \
		"$(RELEASE_APP)"
	codesign --verify --deep --strict --verbose=2 "$(RELEASE_APP)"
	@echo "Reinstalling to $(INSTALL_APP) ..."
	rm -rf "$(INSTALL_APP)"
	cp -R "$(RELEASE_APP)" "$(INSTALL_APP)"
	@echo "Opening $(INSTALL_APP) ..."
	open "$(INSTALL_APP)"

clean:
	rm -rf "$(DERIVED_DATA)" "$(RELEASE_DIR)"

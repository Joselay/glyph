APP_NAME := Glyph
APP_BUNDLE_ID := com.menglay.glyph
CONFIGURATION := release
BUILD_ROOT := .build/glyph-app
APP_DIR := $(BUILD_ROOT)/$(APP_NAME).app
EXECUTABLE := .build/$(CONFIGURATION)/$(APP_NAME)
APP_ICON := $(BUILD_ROOT)/AppIcon.icns
SIGN_IDENTITY ?= Glyph Local Code Signing

.PHONY: app build icon run install stop spec test clean

app: build icon
	rm -rf "$(APP_DIR)"
	mkdir -p "$(APP_DIR)/Contents/MacOS" "$(APP_DIR)/Contents/Resources"
	cp "$(EXECUTABLE)" "$(APP_DIR)/Contents/MacOS/$(APP_NAME)"
	cp Resources/Info.plist "$(APP_DIR)/Contents/Info.plist"
	cp "$(APP_ICON)" "$(APP_DIR)/Contents/Resources/AppIcon.icns"
	chmod +x "$(APP_DIR)/Contents/MacOS/$(APP_NAME)"
	strip -x "$(APP_DIR)/Contents/MacOS/$(APP_NAME)" 2>/dev/null || true
	if security find-identity -v -p codesigning | grep -q '"$(SIGN_IDENTITY)"'; then \
		codesign --force --deep --sign "$(SIGN_IDENTITY)" "$(APP_DIR)" >/dev/null; \
	else \
		codesign --force --deep --sign - "$(APP_DIR)" >/dev/null; \
	fi
	@echo "$(APP_DIR)"

build:
	swift build -c $(CONFIGURATION) --product $(APP_NAME)

icon:
	swift Scripts/generate_app_icon.swift "$(BUILD_ROOT)"

run: stop app
	open "$(APP_DIR)"

install: stop app
	rm -rf "/Applications/$(APP_NAME).app"
	ditto "$(APP_DIR)" "/Applications/$(APP_NAME).app"
	rm -rf "$(APP_DIR)"
	open "/Applications/$(APP_NAME).app"

stop:
	@if pgrep -x "$(APP_NAME)" >/dev/null; then \
		osascript -e 'tell application id "$(APP_BUNDLE_ID)" to quit' >/dev/null 2>&1 || true; \
		for _ in 1 2 3 4 5 6 7 8 9 10; do \
			if ! pgrep -x "$(APP_NAME)" >/dev/null; then \
				exit 0; \
			fi; \
			sleep 0.2; \
		done; \
		pkill -x "$(APP_NAME)" || true; \
	fi

spec:
	swift run GlyphSpec

test: spec

clean:
	rm -rf .build build

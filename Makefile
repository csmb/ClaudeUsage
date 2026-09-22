BUILD_DIR := $(shell xcodebuild -project ClaudeUsage.xcodeproj -scheme ClaudeUsage -showBuildSettings 2>/dev/null | grep -m1 'BUILT_PRODUCTS_DIR' | awk '{print $$NF}')
APP_NAME := Claude Usage.app

# Unit tests run inside the app, but the app is hardened and self-signed (no
# Team ID), so library validation refuses to load the test bundle into it.
# Tests therefore build their own non-hardened copy in a separate DerivedData,
# leaving the app you run and install untouched.
TEST_DERIVED_DATA := $(HOME)/Library/Developer/Xcode/DerivedData/ClaudeUsage-unittests

.PHONY: build install test clean

build:
	xcodebuild -project ClaudeUsage.xcodeproj -scheme ClaudeUsage -configuration Debug build

test:
	xcodebuild test -project ClaudeUsage.xcodeproj -scheme ClaudeUsage -destination 'platform=macOS' \
		-only-testing:ClaudeUsageTests -derivedDataPath "$(TEST_DERIVED_DATA)" ENABLE_HARDENED_RUNTIME=NO

install: build
	@echo "Installing to /Applications..."
	@rm -rf "/Applications/$(APP_NAME)"
	@cp -R "$(BUILD_DIR)/$(APP_NAME)" "/Applications/$(APP_NAME)"
	@echo "Done. Restart the app to pick up changes."

clean:
	xcodebuild -project ClaudeUsage.xcodeproj -scheme ClaudeUsage clean

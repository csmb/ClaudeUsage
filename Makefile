BUILD_DIR := $(shell xcodebuild -project ClaudeUsage.xcodeproj -scheme ClaudeUsage -showBuildSettings 2>/dev/null | grep -m1 'BUILT_PRODUCTS_DIR' | awk '{print $$NF}')
APP_NAME := Claude Usage.app

.PHONY: build install clean

build:
	xcodebuild -project ClaudeUsage.xcodeproj -scheme ClaudeUsage -configuration Debug build

install: build
	@echo "Installing to /Applications..."
	@rm -rf "/Applications/$(APP_NAME)"
	@cp -R "$(BUILD_DIR)/$(APP_NAME)" "/Applications/$(APP_NAME)"
	@echo "Done. Restart the app to pick up changes."

clean:
	xcodebuild -project ClaudeUsage.xcodeproj -scheme ClaudeUsage clean

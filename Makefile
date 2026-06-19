APP_NAME    := URLHandler
EXEC        := urlhandler
BUNDLE_ID   := com.alexspeller.urlhandler
CONFIG      := release
BUILD_DIR   := build
APP         := $(BUILD_DIR)/$(APP_NAME).app
PREFIX      ?= /Applications
INSTALLED   := $(PREFIX)/$(APP_NAME).app
LSREGISTER  := /System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister
BIN_PATH     = $(shell swift build -c $(CONFIG) --show-bin-path)

.PHONY: build test app install set-default login-item restart-agent clean help

help:
	@echo "Targets:"
	@echo "  build         swift build -c $(CONFIG)"
	@echo "  test          run the self-test suite"
	@echo "  app           assemble + ad-hoc sign $(APP)"
	@echo "  install       install to $(INSTALLED) and register with LaunchServices"
	@echo "  set-default   register the installed app as default http/https handler (shows a macOS prompt)"
	@echo "  login-item    register the installed app to launch at login"
	@echo "  restart-agent relaunch the installed agent"
	@echo "  clean         remove build artifacts"

build:
	swift build -c $(CONFIG)

test:
	swift run urlhandler-selftest

app: build
	@rm -rf "$(APP)"
	@mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources"
	@cp "$(BIN_PATH)/$(EXEC)" "$(APP)/Contents/MacOS/$(EXEC)"
	@cp Resources/Info.plist "$(APP)/Contents/Info.plist"
	@codesign --force --sign - "$(APP)"
	@echo "Built $(APP)"

install: app
	@rm -rf "$(INSTALLED)"
	@cp -R "$(APP)" "$(INSTALLED)"
	@codesign --force --sign - "$(INSTALLED)"
	@"$(LSREGISTER)" -f "$(INSTALLED)"
	@echo "Installed $(INSTALLED) and registered with LaunchServices."
	@echo "Next: 'make set-default' to make it your browser, 'make login-item' to launch at login."

set-default:
	@"$(INSTALLED)/Contents/MacOS/$(EXEC)" set-default

login-item:
	@"$(INSTALLED)/Contents/MacOS/$(EXEC)" login-item

restart-agent:
	@-pkill -f "$(INSTALLED)/Contents/MacOS/$(EXEC)" 2>/dev/null || true
	@open "$(INSTALLED)"
	@echo "Relaunched agent."

clean:
	rm -rf .build "$(BUILD_DIR)"

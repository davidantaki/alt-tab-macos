.DEFAULT_GOAL := build

DERIVED_DATA ?= DerivedData
INSTALL_DIR ?= /Applications
CODE_SIGN_IDENTITY ?= -
MACOSX_DEPLOYMENT_TARGET ?= 12.0

.PHONY: build install check-xcode

check-xcode:
	@xcodebuild -version >/dev/null || { echo "Install full Xcode and select it with: sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer" >&2; exit 1; }
	@xcodebuild -checkFirstLaunchStatus || { echo "Finish Xcode setup with: sudo xcodebuild -runFirstLaunch" >&2; exit 1; }

build: check-xcode
	xcodebuild -workspace alt-tab-macos.xcworkspace -scheme Debug \
		-configuration Debug -derivedDataPath "$(DERIVED_DATA)" \
		CODE_SIGN_IDENTITY="$(CODE_SIGN_IDENTITY)" \
		MACOSX_DEPLOYMENT_TARGET="$(MACOSX_DEPLOYMENT_TARGET)" \
		SWIFT_TREAT_WARNINGS_AS_ERRORS=NO \
		OTHER_CODE_SIGN_FLAGS=--timestamp=none build
	# Re-sign embedded frameworks after the Sparkle helper signing phase.
	codesign --force --deep --sign "$(CODE_SIGN_IDENTITY)" --timestamp=none \
		"$(DERIVED_DATA)/Build/Products/Debug/DavidAltTab.app"
	codesign --verify --deep --strict "$(DERIVED_DATA)/Build/Products/Debug/DavidAltTab.app"

install: build
	python3 scripts/install_app.py "$(DERIVED_DATA)/Build/Products/Debug/DavidAltTab.app" "$(INSTALL_DIR)"

.DEFAULT_GOAL := ios-build

# Optional overrides: DEVICE (name or identifier), PROFILE, TEAM, BUNDLE_ID.
BUILD_DIR ?= $(CURDIR)/build/ios
APP := $(BUILD_DIR)/products/Debug-iphoneos/Racing.app

.PHONY: iphone ios-build ios-simulator ios-devices
iphone: ios-build
	@python3 Tools/deploy-ios.py iphone "$(APP)"

ios-build: IOS_SDK = iphoneos
ios-simulator: IOS_SDK = iphonesimulator
ios-build ios-simulator:
	@xcodebuild -project Racing.xcodeproj -scheme Racing -configuration Debug \
		-sdk $(IOS_SDK) -derivedDataPath "$(BUILD_DIR)/DerivedData" \
		SYMROOT="$(BUILD_DIR)/products" OBJROOT="$(BUILD_DIR)/intermediates" \
		CODE_SIGNING_ALLOWED=NO ENABLE_DEBUG_DYLIB=NO SWIFT_OPTIMIZATION_LEVEL=-O build

ios-devices:
	@xcrun devicectl list devices --timeout 15

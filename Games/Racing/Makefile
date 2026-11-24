.DEFAULT_GOAL := ios-build
.DELETE_ON_ERROR:

PYTHON ?= python3
BUILD_DIR ?= $(CURDIR)/build/ios
IOS_MIN := 16.0
IOS_ARCH = $(if $(filter iphoneos,$(IOS_SDK)),arm64,$(shell uname -m))
SWIFT_OPTIMIZATION ?= -O
IOS_OUT = $(BUILD_DIR)/$(IOS_SDK)-$(IOS_ARCH)
IOS_APP = $(IOS_OUT)/Racing.app
IOS_TARGET = $(IOS_ARCH)-apple-ios$(IOS_MIN)$(if $(filter iphonesimulator,$(IOS_SDK)),-simulator)
SHARED_NET := ../../Sources/Net/PacketCore
SWIFT_SOURCES := $(sort $(shell find Sources/Racing -type f -name '*.swift'))
SWIFT_HEADERS := $(wildcard $(SHARED_NET)/*)

.PHONY: ios-build ios-simulator iphone ipad ios-devices ios-app FORCE
ios-build:
	@$(MAKE) ios-app IOS_SDK=iphoneos

ios-simulator:
	@$(MAKE) ios-app IOS_SDK=iphonesimulator

# These opt-in targets sign a copy and install it to a paired device.
# Normal builds stay unsigned and never invoke signing or publication.
iphone ipad: ios-build
	@$(PYTHON) Tools/deploy-ios.py "$@" "$(BUILD_DIR)/iphoneos-arm64/Racing.app"

ios-devices:
	@xcrun devicectl list devices --timeout 15

ifeq ($(filter ios-app,$(MAKECMDGOALS)),ios-app)
ifeq ($(filter $(IOS_SDK),iphoneos iphonesimulator),)
$(error ios-app requires IOS_SDK=iphoneos or iphonesimulator)
endif

# Build identity catches removed sources and tools changing after an SDK update.
$(IOS_OUT)/swift-inputs: FORCE
	@mkdir -p "$(@D)"
	@{ xcrun --sdk "$(IOS_SDK)" --show-sdk-path && \
	    xcrun --sdk "$(IOS_SDK)" swiftc --version && \
	    printf '%s\n' "$(IOS_TARGET)" "$(SWIFT_OPTIMIZATION)" $(SWIFT_SOURCES); } > "$@.tmp"
	@if cmp -s "$@.tmp" "$@"; then rm "$@.tmp"; else mv "$@.tmp" "$@"; fi

$(IOS_OUT)/Racing: $(SWIFT_SOURCES) $(SWIFT_HEADERS) $(IOS_OUT)/swift-inputs Makefile
	@printf '  Compiling Racing (%s)\n' "$(IOS_TARGET)"
	@# One whole-module object stays beside the executable, so dsymutil can read its
	@# debug information when an archive is made.
	@sdk_path=$$(xcrun --sdk "$(IOS_SDK)" --show-sdk-path) && \
	xcrun --sdk "$(IOS_SDK)" swiftc -sdk "$$sdk_path" -target "$(IOS_TARGET)" \
		-parse-as-library -swift-version 5 -module-name Racing $(SWIFT_OPTIMIZATION) -g \
		-whole-module-optimization -c -I "$(SHARED_NET)" -o "$@.o" $(SWIFT_SOURCES) && \
	xcrun --sdk "$(IOS_SDK)" swiftc -sdk "$$sdk_path" -target "$(IOS_TARGET)" -g "$@.o" -o "$@.tmp"
	@mv "$@.tmp" "$@"

ios-app: $(IOS_OUT)/Racing
	@$(PYTHON) Tools/package-ios.py "$(IOS_SDK)" "$(IOS_MIN)" "$<" "$(IOS_APP)"
endif

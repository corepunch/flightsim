# Compile one game (GAME, default KestrelFrontier) into the mobile executable: iOS
# apps cannot load a dylib at runtime. The Mac loads each game's module from
# PlugIns and uses the same SceneKit assets baked by the Mac tools.
IOS_PLATFORM ?= iphonesimulator
IOS_MIN := 16.0
IOS_ARCH := $(if $(filter iphoneos,$(IOS_PLATFORM)),arm64,$(shell uname -m))
IOS_BUILD := build/iOS/$(IOS_PLATFORM)-$(IOS_ARCH)
IOS_CC := xcrun --sdk $(IOS_PLATFORM) clang
IOS_SYSROOT := $(shell xcrun --sdk $(IOS_PLATFORM) --show-sdk-path)
IOS_DEPLOY := $(if $(filter iphoneos,$(IOS_PLATFORM)),-miphoneos-version-min=,-mios-simulator-version-min=)$(IOS_MIN)
IOS_FLAGS := -isysroot "$(IOS_SYSROOT)" -arch $(IOS_ARCH) $(IOS_DEPLOY) -fobjc-arc -O2 -Wall -Wno-unused-function -Wno-deprecated-declarations
IOS_FRAMEWORKS := UIKit SceneKit SpriteKit Metal CoreGraphics QuartzCore ImageIO GameController AVFoundation
IOS_ENGINE_SOURCES := $(filter-out %/FXRecorder.m %/Input.m %/GameView.m %/main.m,$(ENGINE_SOURCES))
IOS_ENGINE_OBJECTS := $(addprefix $(IOS_BUILD)/engine/,$(addsuffix .o,$(IOS_ENGINE_SOURCES)))
IOS_GAME_OBJECTS := $(addprefix $(IOS_BUILD)/game/,$(addsuffix .o,$(filter-out $(SHARED),$(call game_sources,$(call game_module_of,$(GAME))))))

.PHONY: ios
ios: $(IOS_BUILD)/KestrelFrontier

$(IOS_BUILD)/KestrelFrontier: $(IOS_ENGINE_OBJECTS) $(IOS_GAME_OBJECTS) Makefile Tools/iOS.mk
	@printf '  Linking %s (%s)\n' '$(@F)' '$(IOS_PLATFORM)'
	@$(IOS_CC) $(IOS_FLAGS) $(IOS_ENGINE_OBJECTS) $(IOS_GAME_OBJECTS) $(addprefix -framework ,$(IOS_FRAMEWORKS)) -o "$@"

$(IOS_BUILD)/engine/%.m.o: %.m Makefile Tools/iOS.mk
	@mkdir -p "$(@D)"
	@$(IOS_CC) $(IOS_FLAGS) $(ENGINE_FLAGS) -include Sources/Engine/Prefix.h -MMD -MP -c "$<" -o "$@"

$(IOS_BUILD)/engine/%.c.o: %.c Makefile Tools/iOS.mk
	@mkdir -p "$(@D)"
	@$(IOS_CC) $(IOS_FLAGS) -MMD -MP -c "$<" -o "$@"

$(IOS_BUILD)/game/%.m.o: %.m Makefile Tools/iOS.mk
	@mkdir -p "$(@D)"
	@$(IOS_CC) $(IOS_FLAGS) $(call game_flags,$(call game_module_of,$(GAME))) -include Games/$(call game_module_of,$(GAME))/Game/Prefix.h -MMD -MP -c "$<" -o "$@"

-include $(addsuffix .d,$(basename $(IOS_ENGINE_OBJECTS) $(IOS_GAME_OBJECTS)))

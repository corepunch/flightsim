# Native build rules. build.sh packages and signs these outputs.
.DEFAULT_GOAL := all
.DELETE_ON_ERROR:

NATIVE := build/Native
TOOLCHAIN := $(NATIVE)/toolchain
COMMON_FLAGS := -fobjc-arc -O2 -g -Wall -Wno-unused-function -mmacosx-version-min=13.0
SHARED := $(wildcard Sources/Shared/*.m Sources/Shared/*.c)
ENGINE_DIRS := $(wildcard Sources/Engine/*/)
ENGINE_SOURCES := $(SHARED) $(wildcard Sources/Engine/*/*.m)
GAME_SOURCES := $(SHARED) $(wildcard Sources/Game/*.m)
ENGINE_OBJECTS := $(addprefix $(NATIVE)/engine/,$(addsuffix .o,$(ENGINE_SOURCES)))
GAME_OBJECTS := $(addprefix $(NATIVE)/game/,$(addsuffix .o,$(GAME_SOURCES)))
ENGINE_FLAGS := -ISources/Shared $(addprefix -I,$(ENGINE_DIRS))
GAME_FLAGS := -ISources/Shared -ISources/Game -fvisibility=hidden
ENGINE_PCH := $(NATIVE)/engine.pch
GAME_PCH := $(NATIVE)/game.pch
ENGINE_FRAMEWORKS := Cocoa SceneKit SpriteKit Metal CoreGraphics QuartzCore IOKit Carbon ImageIO AVFoundation CoreMedia CoreVideo

.PHONY: all FORCE
all: $(ENGINE_PCH) $(GAME_PCH) $(NATIVE)/SpaceFight $(NATIVE)/game.dylib

# Reuse objects only while the selected compiler and SDK match.
$(TOOLCHAIN): FORCE
	@mkdir -p "$(@D)"
	@{ clang --version && xcrun --show-sdk-path; } > "$@.tmp"
	@if cmp -s "$@.tmp" "$@"; then rm "$@.tmp"; else mv "$@.tmp" "$@"; fi

# Source directories also trigger relinking when a file or directory is removed.
$(NATIVE)/SpaceFight: $(ENGINE_OBJECTS) Sources/Shared Sources/Engine $(ENGINE_DIRS) Makefile
	@printf '  Linking %s\n' '$(@F)'
	@clang $(COMMON_FLAGS) $(ENGINE_OBJECTS) $(addprefix -framework ,$(ENGINE_FRAMEWORKS)) -o "$@.tmp"
	@mv "$@.tmp" "$@"

# The server loads this module at runtime. Only GetGameAPI is exported.
$(NATIVE)/game.dylib: $(GAME_OBJECTS) Sources/Shared Sources/Game Makefile
	@printf '  Linking %s\n' '$(@F)'
	@clang $(COMMON_FLAGS) -dynamiclib $(GAME_OBJECTS) -framework Foundation -install_name @rpath/game.dylib -o "$@.tmp"
	@mv "$@.tmp" "$@"

define compile
	@printf '  Compiling %s (%s)\n' '$<' '$(1)'
	@mkdir -p "$(@D)"
	@clang $(COMMON_FLAGS) $(2) -MMD -MP -MT "$@" -MF "$(basename $@).d.tmp" -c "$<" -o "$@.tmp"
	@mv "$(basename $@).d.tmp" "$(basename $@).d"
	@mv "$@.tmp" "$@"
endef

$(ENGINE_PCH): Sources/Engine/Prefix.h Makefile $(TOOLCHAIN)
	$(call compile,engine prefix,$(ENGINE_FLAGS) -x objective-c-header)

$(GAME_PCH): Sources/Game/Prefix.h Makefile $(TOOLCHAIN)
	$(call compile,game prefix,$(GAME_FLAGS) -x objective-c-header)

$(NATIVE)/engine/%.m.o: %.m $(ENGINE_PCH) Makefile $(TOOLCHAIN)
	$(call compile,engine,$(ENGINE_FLAGS) -include-pch $(ENGINE_PCH))

$(NATIVE)/game/%.m.o: %.m $(GAME_PCH) Makefile $(TOOLCHAIN)
	$(call compile,game,$(GAME_FLAGS) -include-pch $(GAME_PCH))

$(NATIVE)/engine/%.c.o: %.c Makefile $(TOOLCHAIN)
	$(call compile,engine,$(ENGINE_FLAGS))

$(NATIVE)/game/%.c.o: %.c Makefile $(TOOLCHAIN)
	$(call compile,game,$(GAME_FLAGS))

-include $(addsuffix .d,$(basename $(ENGINE_OBJECTS) $(GAME_OBJECTS) $(ENGINE_PCH) $(GAME_PCH)))

.PHONY: iphone ipad ios-devices
iphone ipad:
	@./build.sh "$@"

ios-devices:
	@xcrun devicectl list devices --timeout 15

ifneq ($(filter ios,$(MAKECMDGOALS)),)
include Tools/iOS.mk
endif

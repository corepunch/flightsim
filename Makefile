# Native build rules. build.sh packages and signs these outputs.
.DEFAULT_GOAL := all
.DELETE_ON_ERROR:

NATIVE := build/Native
TOOLCHAIN := $(NATIVE)/toolchain
COMMON_FLAGS := -fobjc-arc -O2 -g -Wall -Wno-unused-function -mmacosx-version-min=13.0
SHARED := $(wildcard Sources/Shared/*.m Sources/Shared/*.c)
ENGINE_DIRS := $(filter-out Sources/Shared/,$(wildcard Sources/*/))
# Sources/Mission is the engine's mission runtime for game modules: it
# links into every game module and not into the engine binary, so its
# classes exist once per process.
MISSION_SOURCES := $(wildcard Sources/Mission/*.m)
ENGINE_SOURCES := $(SHARED) $(filter-out Sources/Shared/% $(MISSION_SOURCES),$(wildcard Sources/*/*.m))
ENGINE_OBJECTS := $(addprefix $(NATIVE)/engine/,$(addsuffix .o,$(ENGINE_SOURCES)))
ENGINE_FLAGS := -ISources/Shared $(addprefix -I,$(ENGINE_DIRS))
ENGINE_PCH := $(NATIVE)/engine.pch
ENGINE_FRAMEWORKS := Cocoa SceneKit SpriteKit Metal CoreGraphics CoreText QuartzCore IOKit Carbon ImageIO AVFoundation CoreMedia CoreVideo

# Every folder in Games/ with a Game/ module is a game. Its module builds as
# build/Native/<name>.dylib; everything else in the folder is its data
# (Tools/bundle-resources.sh). GAME is the one the iOS app links in.
GAMES := $(notdir $(patsubst %/Game/,%,$(wildcard Games/*/Game/)))
GAME ?= KestrelFrontier
# The module a game runs: its own Game/, else its base's (game.json "base").
game_module_of = $(if $(wildcard Games/$(1)/Game/),$(1),$(shell plutil -extract base raw -o - Games/$(1)/game.json 2>/dev/null))
game_sources = $(SHARED) $(MISSION_SOURCES) $(wildcard Games/$(1)/Game/*.m)
game_objects = $(addprefix $(NATIVE)/games/$(1)/,$(addsuffix .o,$(call game_sources,$(1))))
game_flags = -ISources/Shared -ISources/Mission -IGames/$(1)/Game -fvisibility=hidden
GAME_MODULES := $(addprefix $(NATIVE)/,$(addsuffix .dylib,$(GAMES)))
GAME_PCHS := $(addprefix $(NATIVE)/games/,$(addsuffix .pch,$(GAMES)))

.PHONY: all FORCE
all: $(ENGINE_PCH) $(GAME_PCHS) $(NATIVE)/KestrelFrontier $(GAME_MODULES)

# Reuse objects only while the selected compiler and SDK match.
$(TOOLCHAIN): FORCE
	@mkdir -p "$(@D)"
	@{ clang --version && xcrun --show-sdk-path; } > "$@.tmp"
	@if cmp -s "$@.tmp" "$@"; then rm "$@.tmp"; else mv "$@.tmp" "$@"; fi

# Source directories also trigger relinking when a file or directory is removed.
$(NATIVE)/KestrelFrontier: $(ENGINE_OBJECTS) Sources Sources/Shared $(ENGINE_DIRS) Makefile
	@printf '  Linking %s\n' '$(@F)'
	@clang $(COMMON_FLAGS) $(ENGINE_OBJECTS) $(addprefix -framework ,$(ENGINE_FRAMEWORKS)) -o "$@.tmp"
	@mv "$@.tmp" "$@"

define compile
	@printf '  Compiling %s (%s)\n' '$<' '$(1)'
	@mkdir -p "$(@D)"
	@clang $(COMMON_FLAGS) $(2) -MMD -MP -MT "$@" -MF "$(basename $@).d.tmp" -c "$<" -o "$@.tmp"
	@mv "$(basename $@).d.tmp" "$(basename $@).d"
	@mv "$@.tmp" "$@"
endef

$(ENGINE_PCH): Sources/Prefix.h Makefile $(TOOLCHAIN)
	$(call compile,engine prefix,$(ENGINE_FLAGS) -x objective-c-header)

$(NATIVE)/engine/%.m.o: %.m $(ENGINE_PCH) Makefile $(TOOLCHAIN)
	$(call compile,engine,$(ENGINE_FLAGS) -include-pch $(ENGINE_PCH))

$(NATIVE)/engine/%.c.o: %.c Makefile $(TOOLCHAIN)
	$(call compile,engine,$(ENGINE_FLAGS))

-include $(addsuffix .d,$(basename $(ENGINE_OBJECTS) $(ENGINE_PCH)))

# The server loads a game's module at runtime (Server/GameLoader.m). Only
# GetGameAPI is exported.
define game_module
$(NATIVE)/$(1).dylib: $(call game_objects,$(1)) Sources/Shared Sources/Mission Games/$(1)/Game Makefile
	@printf '  Linking %s\n' '$(1).dylib'
	@clang $(COMMON_FLAGS) -dynamiclib $(call game_objects,$(1)) -framework Foundation -install_name @rpath/$(1).dylib -o "$$@.tmp"
	@mv "$$@.tmp" "$$@"

$(NATIVE)/games/$(1).pch: Games/$(1)/Game/Prefix.h Makefile $(TOOLCHAIN)
	$$(call compile,$(1) prefix,$(call game_flags,$(1)) -x objective-c-header)

$(NATIVE)/games/$(1)/%.m.o: %.m $(NATIVE)/games/$(1).pch Makefile $(TOOLCHAIN)
	$$(call compile,$(1),$(call game_flags,$(1)) -include-pch $(NATIVE)/games/$(1).pch)

$(NATIVE)/games/$(1)/%.c.o: %.c Makefile $(TOOLCHAIN)
	$$(call compile,$(1),$(call game_flags,$(1)))

-include $(addsuffix .d,$(basename $(call game_objects,$(1)) $(NATIVE)/games/$(1).pch))
endef
$(foreach game,$(GAMES),$(eval $(call game_module,$(game))))

# Renders the procedural landscape to PNGs without starting the game (Tools/TerrainPreview.m).
TERRAIN_PREVIEW_SOURCES := Tools/TerrainPreview.m Sources/Render/Terrain.m Sources/Render/Post.m
build/tools/TerrainPreview: $(TERRAIN_PREVIEW_SOURCES) Sources/Render/Render.h Sources/Shared/Shared.h Makefile
	@printf '  Linking %s\n' '$(@F)'
	@mkdir -p "$(@D)"
	@clang $(COMMON_FLAGS) $(ENGINE_FLAGS) $(TERRAIN_PREVIEW_SOURCES) \
		-framework Cocoa -framework SceneKit -framework SpriteKit -framework Metal -framework QuartzCore -o "$@"


.PHONY: iphone ipad ios-devices
iphone ipad:
	@./build.sh "$@"

ios-devices:
	@xcrun devicectl list devices --timeout 15

ifneq ($(filter ios,$(MAKECMDGOALS)),)
include Tools/iOS.mk
endif

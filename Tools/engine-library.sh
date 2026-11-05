# Sourced by the GUI checks. Builds the engine, minus its entry point, as
# build/Native/libengine.a and sets:
#   engine_cflags  compiler flags with every engine module on the include path
#   engine_libs    the archive and the frameworks it needs
# A check compiles only its own file and links the archive, so it never lists
# engine sources and picks up new files on its own.
make -s build/Native/libengine.a
engine_cflags=(-fobjc-arc -Wall -mmacosx-version-min=13.0 -ISources/Shared ${(@)$(print -l Sources/Engine/*(/) | sed 's/^/-I/')})
engine_libs=(build/Native/libengine.a -ObjC ${(@)$(make -s engine-frameworks | tr ' ' '\n' | sed 's/^/-framework\n/')})

# link_check_resources <bundle Resources directory>
# Gives a check's bundle the app's resource layout without copying it: the
# engine's own folders at the top level and Games/<name>/ for every game
# (Sources/Shared/FileSystem.h). A game's Models are the baked .scn files in
# build/ModelCache/<name>/Models when a build has made them.
link_check_resources() {
    local resources=$1 directory game entry
    mkdir -p "$resources/Games"
    for directory in Audio Fonts Shaders Particles Strings UI; do
        ln -s "$PWD/Resources/$directory" "$resources/$directory"
    done
    for game in Games/*(N/); do
        mkdir -p "$resources/$game"
        for entry in $game/*(N); do
            case ${entry:t} in Game|Models) continue ;; esac
            ln -s "$PWD/$entry" "$resources/$entry"
        done
        if [[ -d build/ModelCache/${game:t}/Models ]]; then
            ln -s "$PWD/build/ModelCache/${game:t}/Models" "$resources/$game/Models"
        fi
    done
}

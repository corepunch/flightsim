# Sourced by the GUI checks. Builds the engine, minus its entry point, as
# build/Native/libengine.a and sets:
#   engine_cflags  compiler flags with every engine module on the include path
#   engine_libs    the archive and the frameworks it needs
# A check compiles only its own file and links the archive, so it never lists
# engine sources and picks up new files on its own.
make -s build/Native/libengine.a
engine_cflags=(-fobjc-arc -Wall -mmacosx-version-min=13.0 -ISources/Shared ${(@)$(print -l Sources/Engine/*(/) | sed 's/^/-I/')})
engine_libs=(build/Native/libengine.a -ObjC ${(@)$(make -s engine-frameworks | tr ' ' '\n' | sed 's/^/-framework\n/')})

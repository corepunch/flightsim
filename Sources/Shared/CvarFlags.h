// Console variable flags, shared by the engine's Cvar class and the game
// module (which reaches cvars through GameImport). After Quake 2's CVAR_*.
#pragma once

enum {
    CVAR_ARCHIVE = 1 << 0,      // saved to the user's defaults and restored at launch
    CVAR_LATCH   = 1 << 1,      // a new value waits until the next level spawn
    CVAR_CHEAT   = 1 << 2,      // can only be changed while sv_cheats is 1
    CVAR_NOSET   = 1 << 3,      // can only be set from the command line (+set)
};

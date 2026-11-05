// The boundary between the engine and the game module, in the style of
// Quake 2's game_import_t / game_export_t. The engine hands the game a table
// of services (GameImport); the game hands back its entry points
// (GameExport). Only plain C crosses it, so the game can live in its own
// dylib and be rebuilt or swapped without touching the engine.
#pragma once
#include "Protocol.h"
#include "CvarFlags.h"

#define GAME_API_VERSION 2

typedef struct {
    float radius;
    int numParts;
    struct { uint8_t kind; simd_float3 center; } parts[MAX_PARTS];   // SubsystemKind, model space
} GameModelInfo;

typedef struct {
    simd_float3 point;          // world
    int part;                   // subsystem index, -1 for the hull
} GameTrace;

typedef struct {
    int apiVersion;

    void (*print)(const char *text);

    // Registers a model / string configstring and returns its index (relative
    // to CS_MODELS / CS_STRINGS). Registering a model also loads its
    // collision mesh on the server. Index 0 is "none".
    int (*modelIndex)(const char *name);
    int (*stringIndex)(const char *text);
    void (*configString)(int index, const char *value);
    // Radius and subsystems of a registered model (capitals only).
    const GameModelInfo *(*modelInfo)(int model);

    // Segment test against a model placed in the world. Parts set in
    // deadParts are ignored. Returns true on a hit.
    bool (*trace)(int model, simd_float3 origin, simd_quatf orientation, float scale, uint64_t deadParts,
                  simd_float3 from, simd_float3 to, GameTrace *out);

    // Temp entity, sent to every client with the next snapshot.
    void (*event)(const GameEvent *event);
    // Reliable command to one client, or every client with -1.
    void (*command)(int client, int type, const char *a, const char *b, const char *c);

    // Console variables (engine-owned; see Engine/Common/Cvar.h). Register
    // in init with CVAR_* flags, then read at use: values can change at any
    // time. cvarString's result is valid until the cvar changes.
    void (*cvarRegister)(const char *name, const char *value, int flags, const char *help);
    const char *(*cvarString)(const char *name);
    float (*cvarValue)(const char *name);
    void (*cvarSet)(const char *name, const char *value);
} GameImport;

typedef struct {
    int apiVersion;

    void (*init)(void);
    void (*shutdown)(void);

    // Clears the world and builds a campaign mission. May be slow (collision
    // meshes); the server calls it off the render thread.
    void (*spawnMission)(int missionIndex);

    bool (*clientConnect)(int client, const char *name);
    void (*clientBegin)(int client);        // spawns the player's ship
    void (*clientDisconnect)(int client);
    // Runs one user command: flight, guns, torpedoes, targeting. Called as
    // commands arrive, between ticks.
    void (*clientThink)(int client, const UserCmd *cmd);

    void (*runFrame)(void);                 // one tick of TICK_DT

    // State after the last tick. The pointers stay valid until the next call.
    int (*entities)(const EntityState **out);
    const PlayerState *(*playerState)(int client);
} GameExport;

typedef GameExport *(*GetGameAPIFunc)(const GameImport *import);
// The one symbol the game dylib exports.
__attribute__((visibility("default"))) GameExport *GetGameAPI(const GameImport *import);

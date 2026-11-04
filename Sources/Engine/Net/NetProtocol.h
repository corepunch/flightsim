// The wire format between server and client: message ids, and how entity
// states (delta-compressed against a frame the client has), player states,
// events and user commands are written.
#import <Foundation/Foundation.h>
#import "NetMsg.h"
#include "Protocol.h"

#define PORT_SERVER 27910
#define NET_TIMEOUT 10.0                // seconds without a packet before giving up
#define UPDATE_BACKUP 32                // frames of entity history kept for deltas

// Server to client.
enum {
    svc_nop = 1,
    svc_disconnect,         // string reason
    svc_gamestate,          // u32 spawn count; then configstrings, then svc_gamestate_done
    svc_configstring,       // u16 index, string
    svc_gamestate_done,     // u32 spawn count
    svc_command,            // u8 type, string a, b, c
    svc_frame,              // see WriteFrame
};

// Client to server.
enum {
    clc_nop = 1,
    clc_move,               // u32 delta frame (last frame received), u8 count, commands
    clc_stringcmd,          // string: "begin <spawncount>", "disconnect"
};

// Rounds every field to what goes over the wire, so the server diffs (and
// stores) exactly what the client will decode.
void QuantizeEntity(EntityState *e);
// Writes `to` as a change from `from` (NULL: a new entity). Writes nothing
// when nothing changed and `force` is NO.
void WriteDeltaEntity(MsgWriter *w, const EntityState *from, const EntityState *to, BOOL force);
// Writes the entity list `to` against baseline `from` (sorted by number).
void WritePacketEntities(MsgWriter *w, const EntityState *from, NSUInteger fromCount, const EntityState *to, NSUInteger toCount);
// Reads an entity list against baseline `from`; appends the result to `out`.
BOOL ReadPacketEntities(MsgReader *r, const EntityState *from, NSUInteger fromCount, NSMutableData *out);

void WritePlayerState(MsgWriter *w, const PlayerState *ps);
void ReadPlayerState(MsgReader *r, PlayerState *ps);

void WriteEvents(MsgWriter *w, const GameEvent *events, NSUInteger count);
NSData *ReadEvents(MsgReader *r);

// Stick axes go over the wire as 16-bit values; the client quantizes
// before using a command so its prediction runs on what the server runs.
void QuantizeUserCmd(UserCmd *c);
void WriteUserCmd(MsgWriter *w, const UserCmd *c);
void ReadUserCmd(MsgReader *r, UserCmd *c);

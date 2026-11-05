#pragma once

#import <Foundation/Foundation.h>
#import <simd/simd.h>
#import "Shared.h"

// MARK: - Story

// The story front end's data: who is in the cast, which rooms scenes are
// played in, the campaign's missions with their briefings and debriefs, and
// how a briefing breaks into pages. Nothing here names a character, a room
// or an asset; it all comes from the game's data, read once into the
// immutable classes below:
//
//   Story/characters.json  { "player": "<id>",
//                            "characters": { "<id>": { "name": "…", "portrait": "<art>", "faces": "left"|"right" } } }
//   Story/rooms.json       { "rooms": { "<id>": { "image": "<art>", "size": [w, h],
//                                                 "board": { "bottom": y, "height": h },
//                                                 "bezel": [[x, y], …] } } }
//   Campaign/campaign.json { "storyDefaults": { "officer": "<id>", "room": "<id>",
//                                               "briefingPages": ["dialogue", "situation", …] },
//                            "missions": [ { "level": "<name>", "briefing": { … }, "debrief": { … } } ] }
//
// Room coordinates are source-image pixels with y down. Foundation only, so
// the unit checks build it headless. Thread-safe; the files load once.
// Classes are fine here: only the engine links this folder.

#pragma mark - Lines and steps

// Something said on screen: a briefing or debrief dialogue line, or the
// officer's commentary on a page.
//   { "speaker": "Lt. Cmdr Daro Okafor", "portrait": "Okafor", "text": "…", "channel": "…",
//     "listener": "<portrait>", "expression": "wary", "listenerExpression": "worried" }
@interface StoryLine : NSObject
@property (nonatomic, readonly) NSString *speaker, *portrait, *text;
@property (nonatomic, readonly) NSString *channel;                       // nil: the page kind's
@property (nonatomic, readonly) NSString *listener, *expression, *listenerExpression;
+ (instancetype)lineWithJSON:(NSDictionary *)json;
+ (instancetype)lineBy:(NSString *)speaker portrait:(NSString *)portrait text:(NSString *)text;
@end

// A place on the tactical map: a contact's id, or a point in the level's x/z
// plane (metres; -Z is up on the map).
//   "corvette"  or  [1200, -3400]
@interface BriefingPlace : NSObject
@property (nonatomic, readonly) NSString *identifier;                    // nil for a point
@property (nonatomic, readonly) simd_float2 position;                    // x, z; meaningful for a point
+ (instancetype)placeWithJSON:(id)json;                                  // nil when malformed
@end

// Where the map looks. A missing part keeps the map's fit-everything default.
//   { "center": "<id>" | [x, z], "span": metres }
@interface BriefingCamera : NSObject
@property (nonatomic, readonly) BriefingPlace *center;                   // nil: the middle of the action
@property (nonatomic, readonly) float span;                              // metres across the map's shorter side; 0: fit
@end

// Free text pinned to the map.
//   { "text": "…", "at": "<id>" | [x, z] }
@interface BriefingLabel : NSObject
@property (nonatomic, readonly) NSString *text;
@property (nonatomic, readonly) BriefingPlace *at;
@end

// A cue on the tactical map, or a target schematic.
//   { "caption": "…", "show": ["corvette", "escorts"], "route": ["start", "n1"],
//     "focus": "corvette", "schematic": "Engine",
//     "camera": { "center": "corvette", "span": 2500 },
//     "labels": [ { "text": "Kill zone", "at": [1200, -3400] } ] }
@interface BriefingStep : NSObject
@property (nonatomic, readonly) NSString *caption, *focus;
@property (nonatomic, readonly) NSString *schematic;                     // a subsystem kind, or nil for the map
@property (nonatomic, readonly) NSArray<NSString *> *show, *route;
@property (nonatomic, readonly) BriefingCamera *camera;                  // nil: the default fit
@property (nonatomic, readonly) NSArray<BriefingLabel *> *labels;        // text is plain or L10nExpand markup
+ (instancetype)stepWithJSON:(NSDictionary *)json;
// The map lit on one thing and focused on it.
+ (instancetype)stepFocusing:(NSString *)identifier;
@end

#pragma mark - Campaign

// The scene a briefing opens with.
//   { "room": "<id>", "cast": ["<id>", …], "focus": "<map id>", "lines": [StoryLine] }
@interface BriefingScene : NSObject
@property (nonatomic, readonly) NSString *room, *focus;
@property (nonatomic, readonly) NSArray<NSString *> *cast;
@property (nonatomic, readonly) NSArray<StoryLine *> *lines;
@end

//   { "location", "stardate", "speaker", "officer", "pages": [kinds],
//     "text": [paragraphs], "intel": [lines], "steps": [BriefingStep], "dialogue": BriefingScene }
@interface MissionBriefing : NSObject
@property (nonatomic, readonly) NSString *location, *stardate;
@property (nonatomic, readonly) NSString *speaker;                       // the officer's title line
@property (nonatomic, readonly) NSString *officer;                       // a cast id
@property (nonatomic, readonly) NSArray<NSString *> *pageKinds;          // nil: the campaign's default order
@property (nonatomic, readonly) NSArray<NSString *> *text, *intel;
@property (nonatomic, readonly) NSArray<BriefingStep *> *steps;
@property (nonatomic, readonly) BriefingScene *dialogue;                 // nil when there is none
@end

//   { "win": "…", "lose": "…", "room": "<id>", "dialogue": [StoryLine] }
@interface MissionDebrief : NSObject
@property (nonatomic, readonly) NSString *win, *lose, *room;
@property (nonatomic, readonly) NSArray<StoryLine *> *dialogue;
@end

// A campaign entry with the level it flies.
@interface CampaignMission : NSObject
@property (nonatomic, readonly) NSUInteger index;
@property (nonatomic, readonly) NSString *levelName, *title;
@property (nonatomic, readonly) const LevelDef *level;                   // cached for the process
@property (nonatomic, readonly) MissionBriefing *briefing;
@property (nonatomic, readonly) MissionDebrief *debrief;
// Rooms with the campaign's defaults applied.
@property (nonatomic, readonly) NSString *briefingRoom, *debriefRoom;
@end

//   "storyDefaults": { "officer": "<id>", "room": "<id>", "briefingPages": [kinds] }
@interface StoryDefaults : NSObject
@property (nonatomic, readonly) NSString *officer, *room;
@property (nonatomic, readonly) NSArray<NSString *> *briefingPages;
@end

// The campaign's missions in order. Entries whose level is missing are
// left out with a log line.
NSArray<CampaignMission *> *CampaignMissions(void);
CampaignMission *CampaignMissionAt(NSUInteger index);       // nil past the end
// The level a campaign mission flies, and back. NSNotFound for a level the
// campaign does not use.
NSString *CampaignLevelName(NSUInteger index);
NSUInteger CampaignIndexOfLevel(NSString *level);
StoryDefaults *CampaignStoryDefaults(void);

#pragma mark - Cast and rooms

@interface StoryCharacter : NSObject
@property (nonatomic, readonly) NSString *identifier, *name, *portrait;
@property (nonatomic, readonly) BOOL facesRight;                         // as the portrait art is drawn
@end

@interface StoryRoom : NSObject
@property (nonatomic, readonly) NSString *identifier, *image;
@property (nonatomic, readonly) simd_float2 size;                        // source pixels; 0 when unknown
@property (nonatomic, readonly) BOOL hasBoard;
@property (nonatomic, readonly) float boardBottom, boardHeight;          // source pixels, y down
@property (nonatomic, readonly) NSUInteger bezelCount;                   // corners of the wall monitor
- (simd_float2)bezelPoint:(NSUInteger)index;
@end

// The character the player flies as. Their portrait stands on the right.
NSString *StoryPlayer(void);
StoryCharacter *StoryCharacterNamed(NSString *identifier);   // nil if not in the cast
// Whether the portrait art looks to the right as drawn. Unknown art does.
BOOL StoryPortraitFacesRight(NSString *portrait);
StoryRoom *StoryRoomNamed(NSString *identifier);             // nil if there is no such room

#pragma mark - Briefing pages

// A page of the briefing screen: a line, plus what the monitor shows.
@interface BriefingPage : StoryLine
@property (nonatomic, readonly) BOOL dialogue;                           // a line of the opening scene
@property (nonatomic, readonly) BriefingStep *step;                      // a map cue or a schematic
@property (nonatomic, readonly) NSArray<NSString *> *readout;            // a list on the monitor
+ (instancetype)dialogueLine:(StoryLine *)line channel:(NSString *)channel;
+ (instancetype)pageBy:(StoryLine *)officer text:(NSString *)text channel:(NSString *)channel
                  step:(BriefingStep *)step readout:(NSArray<NSString *> *)readout;
@end

// Briefing text marks keywords with asterisks: "Destroy the *corvette Vesk*."
// Returns the text without the marks and the character ranges (NSValue of
// NSRange, UTF-16) that were marked. A lone asterisk, or "**", reads as one.
NSString *StoryPlainText(NSString *marked, NSArray<NSValue *> **highlights);

// `officer` is the character giving the briefing: speaker and portrait, no text.
typedef NSArray<BriefingPage *> *(^BriefingPageKind)(CampaignMission *mission, StoryLine *officer);

// Page kinds by name. The engine registers dialogue, situation, tactical,
// objectives and intel; a game may add its own (or replace one) before the
// first briefing is shown.
void StoryRegisterBriefingPages(NSString *kind, BriefingPageKind build);
// The mission's pages, in the order its briefing (or storyDefaults) lists the
// kinds. Unknown kinds are skipped with a log line; the level validator
// rejects them.
NSArray<BriefingPage *> *StoryBriefingPages(CampaignMission *mission);
NSArray<BriefingPage *> *StoryBriefingPagesOfKinds(CampaignMission *mission, NSArray<NSString *> *kinds);
// Names of the registered kinds, for validation.
NSArray<NSString *> *StoryBriefingPageKinds(void);

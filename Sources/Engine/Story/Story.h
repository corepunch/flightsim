#import <Foundation/Foundation.h>

// The story front end's data: who is in the cast, which rooms scenes are
// played in, and how a mission's briefing breaks into pages. Nothing here
// names a character, a room or an asset; it all comes from the game's data:
//
//   Story/characters.json  { "player": "<id>",
//                            "characters": { "<id>": { "name": "…", "portrait": "<art>", "faces": "left"|"right" } } }
//   Story/rooms.json       { "rooms": { "<id>": { "image": "<art>", "size": [w, h],
//                                                 "board": { "bottom": y, "height": h },
//                                                 "bezel": [[x, y], …] } } }
//   Campaign/campaign.json "storyDefaults": { "officer": "<id>", "room": "<id>",
//                                             "briefingPages": ["dialogue", "situation", …] }
//
// Room coordinates are source-image pixels with y down. Foundation only, so
// the unit checks build it headless. Thread-safe; the files load once.

#pragma mark - Campaign

// Campaign/campaign.json in the game folder: the campaign's name, story,
// storyDefaults and, in order, its missions. A mission entry names a level
// and carries the briefing and debrief:
//   { "level": "<name>", "briefing": { … }, "debrief": { … } }
NSDictionary *CampaignData(void);
// The campaign's missions in order, each the level (Levels/<name>.json)
// merged with its campaign entry, so briefing code reads one dictionary.
NSArray<NSDictionary *> *CampaignMissions(void);
NSDictionary *CampaignMission(NSUInteger index);
// The level a campaign mission flies, and back. NSNotFound for a level the
// campaign does not use.
NSString *CampaignLevelName(NSUInteger index);
NSUInteger CampaignIndexOfLevel(NSString *level);

#pragma mark - Cast and rooms

// The character the player flies as. Their portrait stands on the right.
NSString *StoryPlayer(void);
// A cast entry, or nil.
NSDictionary *StoryCharacter(NSString *identifier);
// Whether the portrait art looks to the right as drawn. Unknown art does.
BOOL StoryPortraitFacesRight(NSString *portrait);
// A room entry, or nil.
NSDictionary *StoryRoom(NSString *identifier);
// The room a mission's briefing and debrief are played in.
NSString *StoryBriefingRoom(NSDictionary *mission);
NSString *StoryDebriefRoom(NSDictionary *mission);

#pragma mark - Briefing pages

// A page is a dictionary the briefing screen draws:
//   speaker, portrait, text, channel   always
//   dialogue = YES, listener, expression, listenerExpression   a dialogue line
//   tactical = <step>                  a map cue or a schematic
//   readout  = [lines]                 a list on the monitor
// `officer` is { "speaker": …, "portrait": … }, the character giving the briefing.
typedef NSArray<NSDictionary *> *(^BriefingPageKind)(NSDictionary *mission, NSDictionary *officer);

// Page kinds by name. The engine registers dialogue, situation, tactical,
// objectives and intel; a game may add its own (or replace one) before the
// first briefing is shown.
void StoryRegisterBriefingPages(NSString *kind, BriefingPageKind build);
// The mission's pages, in the order storyDefaults.briefingPages (or the
// mission's own briefing.pages) lists the kinds. Unknown kinds are skipped
// with a log line; the level validator rejects them.
NSArray<NSDictionary *> *StoryBriefingPages(NSDictionary *mission);
// Names of the registered kinds, for validation.
NSArray<NSString *> *StoryBriefingPageKinds(void);

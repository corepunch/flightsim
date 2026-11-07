# The Quiet Engine

A Kestrel Frontier campaign in four acts. Lancer's first watch exposes a leaked convoy schedule. The people rescued on that watch and the missions that follow bring back the manifests, testimony and recordings that lead Bastion to the Hammer of Skarn.

| Act | Missions | What Lancer uncovers |
| --- | --- | --- |
| Strange Orders | 1–5 | Captain Sen's convoy has been compromised. Relay K-7 and the Vesk recorder tie the attack to a Concord seal and a depot at Tarn. |
| The People We Save | 6–10 | An intercepted distress call leads to the Ondine. Juno's cargo log, the Halcyon survey and Rhea Sol's signed orders connect the attackers to the Directorate. |
| The Machine at Corvid | 11–15 | Tannhal's receiver and Lancer's recon show what Hale traded to Admiral Korr. The colonies evacuate. When a destroyer approaches the Directorate's decoy anchorage, Hale's office is exposed as the leak, and Bastion's marines capture the destroyer Gorran and her log. |
| The Quiet Engine | 16–20 | Gorran's log leads to the Thal and Kesh Ardan. Hale, arrested, gives up the stealth courier's route, and Lancer cuts Korr's remote firing signal. With the spare coils destroyed and Gorran's guns on Bastion's flank, Lancer stops the Hammer, and the Strix aces that guard it, before it can fire through Halden. |

## Cast

| Character | Portrait | Part in the campaign |
| --- | --- | --- |
| Lancer 1 | `Lancer1` | Player character and lead Executioner pilot |
| Lancer 2 | `Lancer2` | Lancer 1's wingman from the first patrol, killed defending Bastion in Iron Wall |
| Lancer 3 | `Lancer3` | Joins the relief flight for CNS Kestrel |
| Lancer 4 | `Lancer4` | Flies cover on the attack at Hammerfall |
| Lancer 5 | `Lancer5` | Escorts tanker Corla during refuelling at Brenn depot |
| Lancer 6 | `Lancer6` | Escorts the evacuation liner Aurora Star to Halden Gate |
| Commander Ilse Varn | `Varn` | Bastion's commander and Lancer's commanding officer |
| Lt. Cmdr Daro Okafor | `Okafor` | Intelligence officer who traces the Concord seal |
| Captain Elara Sen | `MiraCaptain` | Freighter captain and witness to the first leak |
| Chief Engineer Mae Orin | `Orin` | Keeps Bastion in the fight and reads the fleet's engineering records |
| Dr. Sera Imani | `Imani` | Rescue physician who identifies the gate weapon |
| Juno Vale | `Juno` | Ondine technician who preserves the original cargo manifest |
| Captain Rhea Sol | `Rhea` | Kestrel's commander who brings back the false evacuation order |
| Captain Lusk | `Lusk` | Aurora Star's captain, responsible for six thousand evacuees |
| Kesh Ardan | `Kesh` | Imprisoned Skarn engineer who designed the firing circuit |
| Director Soren Hale | `Hale` | Concord official who traded the gate experiment to Korr |
| Admiral Korr | `Korr` | Skarn commander who takes control of the Hammer |

## Briefings and debriefs

Mission events and tactical orders live in `Games/KestrelFrontier/Levels/` and `Games/KestrelFrontier/Campaign/campaign.json`. Each briefing opens with illustrated dialogue and follows with situation, flight plan, objectives and loadout. The debrief shows objective results first. A successful sortie leads into its epilogue and then the next mission. A failed sortie can be retried from the results.

The cast speaks from the left. Lancer 1 stays on the right and has a reply in every briefing and in debriefs where he has something to add. The character he addresses stays in view during his reply. The desktop and tablet layouts flank the painted Bastion monitor, while compact phone layouts anchor the characters at the bottom edge.

Dialogue beats can set `expression` for the speaker and `listenerExpression` for the other portrait. An expression such as `grieving` loads `Games/KestrelFrontier/Briefing/Expressions/Lancer1-grieving.png` for Lancer 1. Each variant shares the base portrait's canvas, facing direction and waistline so it can switch in place. A beat uses the base art by default.

Lancer 1 and the supporting cast use variants with arm gestures. The earlier face-only passes are saved under `Games/KestrelFrontier/Art/Briefing/ExpressionArchive` for reuse. The game bundles the active sprites from `Games/KestrelFrontier/Briefing/Expressions`.

Iron Wall's `casualty` records a scripted loss. The radio call goes out once, when Lancer 2 falls in combat or when the Iron Vow loses its shields. Hammerfall's flight roster reflects the loss.

The ten cyan hull/red subsystem views in the tactical pages come from the shipped OBJ meshes. Regenerate those PNGs with `python3 Games/KestrelFrontier/Art/build_schematics.py` and Pillow after changing the source mesh or schematic cue. Building the app uses the checked-in PNGs.

The campaign contains 221 conversation beats across twenty briefings and twenty successful epilogues. Failure results do not play the successful epilogue or introduce its witnesses. Story dialogue remains English, as in the existing campaign; translated flight radio and interface catalogs are unchanged.

## Evidence and character continuity

| Missions | Evidence established | Consequence and returning character |
| --- | --- | --- |
| 1–3 | Scout recorder has the convoy schedule; Sen preserves her log; K-7 records a valid command seal. A valid seal alone does not identify its user. | Escort Mira and Tobin before investigating. Sen brings the relay timing to the next briefing. |
| 4–5 | Vesk's service recorder names Tarn; container scans expose false manifests and military payment. The actual shipment is still uncertain. | Sen names Ondine's engineer Juno, who keeps duplicate loading sheets. |
| 6–8 | Corla relays Ondine's distress burst. Five rescued pods include Juno and her original log. Halcyon's survey matches the equipment serials. | Juno returns after treatment; the survivors' names on the reverse of her sheet matter again at mission 15. |
| 9–11 | Three offices receive different decoy anchorages. Sol preserves the false evacuation order. Juno finds Tannhal's receiver. | Sol offers Kestrel's help once repaired. Juno helps evacuate her former workplace rather than remaining only a witness. |
| 12–13 | Hale claims a listening post. His shared maintenance link proves cooperation; Lancer's images establish the weapon. | Raw images, original orders and serial numbers reach Fleet Command. Evacuation begins only after the recon. |
| 14–16 | Copies leave with the refugees. Gorran approaches the Directorate's decoy; her captured log identifies Thal and the missing crews. | Sen receives refugees. Sol returns with Kestrel to tow the barge. Juno identifies her crew; Kesh first speaks over Thal's service transmitter. |
| 17–18 | Arrested Hale supplies the courier route; Kesh supplies its wake and firing-circuit knowledge. Imani verifies the carrier trace. | Destroying the courier forces local firing; destroying the spare coils prevents another charge. Neither action stops the current charge. |
| 19–20 | Korr's motive and threat are public. Two dies during Iron Wall; Gorran's guns and the repaired Kestrel protect the surviving fleet. | Two never appears alive in Hammerfall. The final assault still requires shields, engines and reactor. Survivors receive a homecoming rather than another immediate sortie. |

Personal exchanges address the player through Lancer's role: Sen asks for clear escort calls, Imani asks for a voice at each rescue, and Juno asks for people to return rather than another recorder. Lancer can reply while the addressed character stays visible. The coffee promise begins on the first patrol, returns with Two during later operations, and ends with his mug on the way home.

Hale's Directorate appearances, Korr's open-channel threats and Kesh's first call carry explicit channel labels. The large portraits represent the conversation partners; these scenes do not imply the antagonists or the prisoner are physically aboard Bastion.

`Games/KestrelFrontier/Story/continuity.json` is an authoring constraint file consumed by the validator, not a runtime unlock system. It names first speaking scenes, required later returns and Two's last speaking window. Both speakers and visible listeners count as appearances; dialogue may still mention absent people. Update these constraints when deliberately changing an introduction, rescue or death. They check chronology and presence, not whether a sentence is true.

## Validation

Run `python3 -I Tools/validate_story.py` for cast, portrait files, mission references, tactical cues and continuity. Run `python3 -I Tools/test_story_continuity.py` for premature witness, resurrection and missing-return rejection checks. CI runs these plus the existing all-mission GUI/dialogue suites and a native iOS simulator build.

The presentation remains the existing shared conversation stage: large illustrated characters, a stable caption area, inward-facing player/listener pairs and touch-safe navigation. Dialogue is split into short beats rather than shrinking the characters. The added Gorran gun-mount schematic uses the shipped Destroyer OBJ, with the blue hull preserved and red mounts called out for boarding cover.

A macOS render at phone/tablet dimensions and a simulator compilation do not establish native touch behavior. Before release, inspect the longer conversations on actual iPhone, iPad and Mac, particularly Lifeline's rescue epilogue, the Hale link, Iron Wall's loss and Hammerfall's homecoming. Check caption scrolling, channel labels, previous/continue actions and safe areas. Run `./build.sh` and `./build.sh ios-simulator` on macOS for native builds.

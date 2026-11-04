# The Quiet Engine

A Kestrel Frontier campaign in four acts. Lancer's first watch exposes a leaked convoy schedule. The people rescued on that watch and the missions that follow bring back the manifests, testimony and recordings that lead Bastion to the Hammer of Skarn.

| Act | Missions | What Lancer uncovers |
| --- | --- | --- |
| Strange Orders | 1–5 | Captain Sen's convoy has been compromised. Relay K-7 and the Vesk recorder tie the attack to a Concord seal and a depot at Tarn. |
| The People We Save | 6–10 | An intercepted distress call leads to the Ondine. Juno's cargo log, the Halcyon survey and Rhea Sol's signed orders connect the attackers to the Directorate. |
| The Machine at Corvid | 11–15 | Tannhal's receiver and Lancer's recon show what Hale traded to Admiral Korr. The colonies evacuate while Bastion comes under direct attack. |
| The Quiet Engine | 16–20 | The Thal rescue brings in Kesh Ardan. Lancer cuts Korr's remote firing signal, destroys her spare coils and stops the Hammer before it can fire through Halden. |

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

Mission events and tactical orders live in `Resources/Missions/missions.json`. Each briefing opens with illustrated dialogue and follows with situation, flight plan, objectives and loadout. The debrief shows objective results first. A successful sortie leads into its epilogue and then the next mission. A failed sortie can be retried from the results.

The cast speaks from the left. Lancer 1 stays on the right and has a reply in every briefing and in debriefs where he has something to add. The character he addresses stays in view during his reply. The desktop and tablet layouts flank the painted Bastion monitor, while compact phone layouts anchor the characters at the bottom edge.

Dialogue beats can set `expression` for the speaker and `listenerExpression` for the other portrait. An expression such as `grieving` loads `Resources/Briefing/Expressions/Lancer1-grieving.png` for Lancer 1. Each variant shares the base portrait's canvas, facing direction and waistline so it can switch in place. A beat uses the base art by default.

Lancer 1 and the supporting cast use variants with arm gestures. The earlier face-only passes are saved under `Art/Briefing/ExpressionArchive` for reuse. The game bundles the active sprites from `Resources/Briefing/Expressions`.

Iron Wall's `casualty` records a scripted loss. The radio call goes out once, when Lancer 2 falls in combat or when the Iron Vow loses its shields. Hammerfall's flight roster reflects the loss.

The cyan hulls and red subsystems in the tactical pages come from the shipped OBJ meshes. Regenerate those PNGs with `python3 Art/build_schematics.py` and Pillow after changing the source mesh or schematic cue. Building the app uses the checked-in PNGs.

Run `python3 Tools/validate_story.py` to check the cast, portrait files, mission references and tactical cues. Run `./build.sh` to build the macOS game.

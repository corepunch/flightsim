# The Quiet Engine — narrative and briefing specification

## Story
A routine Kestrel picket patrol exposes reconnaissance of civilian navigation buoys. The new Lancer pilot escorts Captain Elara Sen's two freighters and discovers Skarn raiders knew the departure schedule. Elara survives to testify at the next briefing. Relay K-7 logs carry a valid Concord seal ordering its own silence. Commander Ilse Varn and intelligence officer Daro Okafor start questioning the orders coming from home.

The Ondine rescue brings technician Juno Vale and physician Sera Imani aboard Bastion. They identify gate-calibration equipment hidden among cargo, while engineer Mae Orin notices the enemy knows the fleet's old charts. Frigate captain Rhea Sol survives an attempt to destroy evidence. The investigation finds the Skarn shipyard in Corvid and its unfinished dreadnought, the Hammer of Skarn.

The architects are Directorate officer Soren Hale and Skarn Admiral Korr: Hale manufactured border emergencies to justify transferring forbidden resonance technology to the Skarn. Korr intends to use the completed weapon to collapse the Halden gate and cut off every frontier colony. Civilian evacuation forces the crew to choose between immediate safety and stopping the weapon. Rescued prisoner Kesh Ardan reveals its activation cipher. The people Lancer saved earlier come back to help the final assault, culminating in Hammerfall.

## Four acts
1. **Strange Orders** (1–5): routine patrol, convoy rescue, forged relay command, hidden Skarn supply lines.
2. **The People We Save** (6–10): defend fuel, recover Ondine pods, protect scientists, discover leaked charts, rescue frigate witnesses.
3. **The Machine at Corvid** (11–15): defend civilians, identify conspiracy, learn what Hammer really is, evacuate colonies, save Bastion.
4. **The Quiet Engine** (16–20): free defectors, break firing-cipher link, destroy spare coils, hold last line, defeat Hammer.

## Presentation constraints
- **Large portraits**, not communicator thumbnails. Characters belong on either side of the Bastion tactical display during briefings.
- Dialogue data is defined per mission under `briefing.dialogue.lines`; the active speaker takes visual priority.
- The tactical map uses existing entity positions, routes, objectives and wave ids; no mission scripting changes are necessary to show the story.
- `debrief.dialogue` adds post-mission personal conversations after objective results. These can reveal a saved person's name and motives before the next mission.
- Do not use a 3D briefing room. Keep the generated Bastion background and SpriteKit layer.
- Existing portrait PNGs: Varn, Okafor, MiraCaptain. Unillustrated roles: Orin, Imani, Juno, Rhea, Lusk, Kesh. Temporary letter placeholders are deliberately visible and must be replaced with full-height transparent PNG artwork before release.
- Schematics can eventually be created by rendering the actual ship models with cyan-blue wire or edge treatment and red critical systems; do not claim the current tactical map is already a 3D schematic.
- **Platform reality:** `build.sh` currently builds a macOS Cocoa app. iPhone and iPad ports require a separate UIKit app target and touch / safe-area integration; they are not shipped by this narrative PR.

## Asset briefs
- **Varn:** authoritative veteran commander, practical Concord duty uniform; recurring moral centre.
- **Okafor:** meticulous intelligence officer; calculating but protective of witnesses.
- **Elara Sen:** civilian freighter captain, repaired flight jacket, resilient, a little irreverent.
- **Mae Orin:** ship engineer, worn industrial uniform, grease-scarred hands.
- **Sera Imani:** scientist and doctor, composed, emergency medical jacket.
- **Juno Vale:** rescued civilian technician, tired but defiant, practical workwear.
- **Rhea Sol:** frigate captain, worn Concord bridge uniform, battle-damaged shoulder.
- **Captain Lusk:** civilian liner captain, dignified and frightened for passengers.
- **Kesh Ardan:** Skarn defector, understated military prisoner uniform, not a monster.
- **Soren Hale:** polished Concord Directorate officer, ultimately antagonist in transmissions.
- **Admiral Korr:** Skarn commander, not merely a faceless raider; final antagonist.

Every asset: full height with transparent background, standing three-quarter view, lower body can crop behind caption, consistent painterly realistic lighting, no typography.

## Validation
Run `python3 Tools/validate_story.py` from the repository root. Mac builds should be checked with `./build.sh`, followed by manual 16:9, 4:3, iPhone portrait/landscape and iPad safe-area tests once mobile targets exist.

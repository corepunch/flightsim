Kestrel Frontier: reusable radio prototype, 2026-11-06

30 original English lines, with no spoken callsigns, ship names or character names.
Billy performs the urgent fighter calls and banter; Mark performs distress,
readiness and praise; Clint performs contacts and loss reports. Distress prompts
ask for shouting. Performance and playback level are separate: radio defaults to
0.32 volume while the existing music continues at its normal level.

The first two campaign missions exercise the whole bank through random text
alternatives: hostile arrivals, first hostile hit on a surviving wingman or
freighter, enemy-wave completion, readiness and wingman loss. Each event fires
once. The server picks the alternative, so all players get the same caption.
Captions use game string keys; the recording is selected by key independently
of the displayed speaker. A missing recording leaves the normal caption.

The radio channel allows one active and one waiting transmission, with a 1.25 s
gap after speech and a 6 s expiry for waiting chatter. Leaving flight, muting or
losing app focus clears it. s_radioVolume controls only voices; 0 disables them.

The processed deliveries are mono 22.05 kHz PCM WAVs. build_radio.py uses a
650–2200 Hz receiver band, transmitter saturation, coarse quantization, audible
high-frequency hiss, random crackle and opening/closing squelch. It uses only
Python's standard library and macOS afconvert. From the repository root:

  python3 Games/KestrelFrontier/Art/Radio/build_radio.py

manifest.json records the exact scripts, delivery tags, voices, model, speed,
generation date and Runway task IDs. Masters/ holds the final unprocessed MP3s.
Runway also retains the generated tasks in the connected Igor workspace.
Earlier named/softer trials remain locally in Trials/ with their provenance.
They are not part of the committed bank or app.

Research references (original dialogue, not recordings copied from these):
Runway speech and performance controls:
https://help.runwayml.com/hc/en-us/articles/23859696734611-Generating-speech-from-text
Military brevity reference; a useful guide to short, event-driven exchanges:
https://www.alssa.mil/Portals/9/Documents/mttps/brevity_2025.pdf
US Air Force terminology and defensive break calls:
https://www.afjag.af.mil/Portals/77/documents/AFD-081204-037.pdf

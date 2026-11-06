# TODO

## Networking

- **Lag compensation.** At high ping your bolts are judged against where
  targets are on the server, not where you saw them. That only matters
  online; on a LAN the delay is about 100 ms.
- **Ramming capital ships isn't predicted.** The bounce shows up as a
  correction that fades in about a tenth of a second.
- **No in-game box for typing an address.** Direct IP is only `--connect` on
  the command line.
- **Co-op rules are basic.** Extra players spawn beside the first, nobody
  respawns, and the mission fails when every player is down. This remains
  available through a dedicated campaign server; the LAN menu hosts dogfights.
- **Device release validation.** Play a complete LAN match between physical
  iPhone/iPad peers, including permission denial/retry and background/resume.
  Measure campaign difficulty and frame pacing on a phone; scripted mission
  flow checks cover the objective logic, not touch combat or player learning.
- **EOS (Epic Online Services).** Not started: Connect login, Lobbies for
  matchmaking, and a P2P `NetTransport` under the existing netchan.

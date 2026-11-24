# Arcline migration

Arcline source, assets, launch configuration and build tools come from
[`corepunch/racing@88f8b616`](https://github.com/corepunch/racing/tree/88f8b616870a53e6cebd3441803dca1c47b80d2b).
Use the original repository or the separate history-preserving Git bundle to
recover the complete Racing main history. In the history-preserving import
the second parent is the original Racing commit; squashing or rebasing that
import discards this ancestry.

This is the public source baseline, not a statement about which exact source
produced a particular distributed binary. The original build settings retain
the display name `Arcline`, iOS app identifier `com.corepunch.arcline`,
the existing Catalyst override, iOS minimum OS, Info.plist version/build,
game data, and Bonjour service. There is no release or storefront change.

## Boundary

| Shared now | Game-specific |
| --- | --- |
| `Sources/Net/PacketCore`: the Quake-style 30-bit sequence and ack envelope, its reliable and fragment flags, and the connectionless marker. Used by both native channels. | FlightSim's transport and fragmented authoritative snapshots, and Racing's Network.framework socket layer and relayed car poses. Their payloads, protocol versions, lobby discovery and sessions are **not** interchangeable. |
| Repository, root build entry points and portable wire-envelope checks. | Racing's SceneKit vehicle suspension, tire/brake and ground interaction, and FlightSim's deterministic flight update, prediction and game module API. |
| No shared UI views yet. | Racing's UIKit menus, garage, showroom and HUD stay visually intact. FlightSim's SpriteKit layouts and existing themes stay intact. |

Neither tree uses SyncKit. A shared SceneKit renderer is not a shared
simulation: FlightSim keeps deterministic flight state outside SceneKit, and
Racing uses local SceneKit car physics. Combining them should mean putting
separate vehicle models behind shared interfaces, not sending car controls
through the flight model or replacing one existing payload with the other.

The imported Racing target is intentionally not a FlightSim `GameAPI` module.
`GAME=Racing ./build.sh` is not supported. The regular flight app does not
copy or present the standalone racing app or its assets. The racing app can
build and ship in the same repository without changing the flight bundle.

## Next seams

1. Keep the common packet envelope stable. Factor sequence/reliability state,
   clock and link interfaces only after host + two-client tests cover loss,
   reconnect and duplicate traffic for both protocols. The message serializers,
   replication models and fragmentation remain separate until then.
2. Introduce a semantic UI contract with separately branded values for primary
   action, focus, disabled state and panel surfaces. Pilot one control in
   Racing's main menu and one in FlightSim's menu. Preserve the racing colors,
   typography, spacing and showroom; compare the two renderers separately
   before sharing any screen layout.
3. Put the model-specific flight and vehicle simulation behind a control/tick/
   pose boundary. Do not make collision or visual behavior a property of a
   shared packet. Benchmark and compare local driving before changing the
   ownership of car motion online.

## Verification before retiring Racing

- Build the Racing simulator and device app in Xcode, and FlightSim's unchanged
  macOS/iOS targets. Inspect both app bundles: own resources, original identifier,
  signing and no files from the other game.
- On iPhone and iPad compare startup, controller display, menus, garage, HUD,
  local races and existing player data with the standalone app. Check a LAN
  race with a host and two peers, reconnection and lap results. Exercise both
  a stale car pose and its return.
- Check for work that exists only on other branches or local checkouts and
  reconcile the live support/privacy site and its Apple-facing URLs. Those
  deployments are independent from the imported main branch. Only consider
  archiving the old repository after its replacement and dependencies are
  verified. Do not delete or redirect anything as part of this import.

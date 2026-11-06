Run `./Tools/run-network-checks.sh` on macOS with Xcode's command-line tools.
A missing baked model cache is built automatically for the campaign checks.
The CI network-checks job runs the same command and retains results.log.
The normal build, unit, campaign and six GUI suites remain separate CI jobs.

The executable links the production Server, Client, NetChannel, codecs, flight
model, definitions and complete game module. Its GameLoaderOpen shim selects the
statically linked module. A presentation spy replaces ClientView; empty fixture
missions need no capital geometry, renderer, window or GPU. SceneKit is linked
for the server's production ModelInfo dependency, but no scene is created.
Fixtures copy resources into a fresh temporary directory and give two ships
intentionally different speed, turning, weapon speed, lifespan and cadence.
Production resources are never edited. Artifacts remain under build/.

| Coverage | Transport / oracle |
| --- | --- |
| Two distinct players, both visible to each other | Encoded packets through production client/server |
| Connect, gamestate, begin, snapshots, reconnect, explicit disconnect | Deterministic in-memory datagrams |
| Full movement parameter agreement | Exact server player-state parameters versus selected JSON |
| Pending-input prediction | Compare prediction before delivery with subsequent server state (2 mm tolerance), lossless cases |
| Primary weapons | Predicted shots and authoritative bolt events, lifespan, relative projectile speed and cadence bounds |
| Latency and packet loss | 100 ms each way, every 11th datagram dropped, plus 45 ticks of total blackout |
| History recovery | Blackout exceeds 32-frame history; assert resumed snapshots and eventual convergence |
| Protocol versions | Previous and future versions, absent and nonnumeric versions rejected without allocating slots |
| Game-data rejection | Incompatible CS_GAME blocks begin, invokes disconnect callback and releases slot |
| Definition changes | Fresh-process identity probes change movement, projectile speed, cadence and remove a ship; restored data matches |
| Timeout | Advance virtual time beyond NET_TIMEOUT without peer traffic |
| Socket smoke | Production UDPTransport, ephemeral IPv4 localhost ports, server and two clients in one process |

The virtual clock replaces CACurrentMediaTime only in the regression executable.
Transport scheduling is deterministic; it does not depend on sleeps or wall time.
Loss applies to handshake, reliable fragments, commands and snapshots alike.
The burst exceeds input redundancy too, so instantaneous zero correction is not
expected under loss; final convergence is checked after delivery recovers.
The UDP smoke has no injected delay/loss. It is a real kernel socket test, not
LAN, separate-process or device testing.

Compatibility change: protocol **6** distinguishes competitive matches through
CS_MODE. Earlier front ends could record a dogfight as a campaign victory, so
both sides reject older protocol versions. Game API **4** adds typed deathmatch
rules to the level contract. Rebuild the engine and modules together. CS_GAME contains
the game/data version plus SHA-256 over sorted, length-delimited ship filenames
and exact JSON bytes. Both game module and client calculate it from their own
bundle. Active clients also reject changes to this configstring.
Whitespace-only changes intentionally require matching bundles. Cache lifetime
matches the process-lifetime definition cache; replacing resources requires a
restart. This is compatibility detection, not authentication or anti-cheat.

Remaining coverage and compatibility limits:

- All peers share a process and definition cache in integration scenarios. Fresh
  process digest probes detect changed files, but do not replace separate app
  bundles connecting over a real network.
- No physical macOS/iOS peers, Wi-Fi jitter, NAT, MTU/path issues,
  endian/architecture combinations, background/resume or app lifecycle coverage.
- The identity covers ship JSON only. Capital collision meshes, missions,
  projectile visuals and other game data still depend on a manually maintained
  game/data version. A matching hash cannot establish equal executable logic.
- Loss models are fixed patterns, not a broad fuzz campaign; no deliberate
  reordering, duplication or hostile-packet testing is included.
- Empty missions exercise flight and primary weapons without combat collisions,
  damage, secondary weapon targeting, mission transitions or late-join combat.
  Those behaviors can still correct prediction or expose replication defects.
- Weapon cadence/energy prediction may differ transiently after input loss;
  authoritative damage and ammo remain server controlled. This suite checks
  weapon activity and projectile parameters, not perfect effect deduplication.

## LAN matches and campaign flow

The same executable now also checks an eight-player dogfight: each pilot is
hostile to every other pilot, targeting includes human opponents, primary
weapons damage another player, missiles carry the shooter's team, deaths
increment once, respawns preserve score, and frag/time limits end the match.
A rematch resets scores; a solo host waits without consuming the match clock.
A missing host times out during connection attempts as well as after joining.

A real Bonjour smoke publishes an ephemeral UDP port, resolves the declared
`_kestrel._udp` service and queries its game information. The random port is
outside the browser's legacy port scan. It also verifies that private sessions
ignore remote discovery and that closing a public session sends a disconnect.
This checks local mDNS and UDP on one Mac, not discovery between devices.
iOS uses Bonjour plus UDP unicast and declares the service in Info.plist;
it does not send the broadcast packets that require Apple's multicast entitlement.

Separate processes then load the production resources and baked subsystem
geometry for Kestrel Frontier and Ember Reach. `Tools/CampaignChecks.h` advances
the real mission runner, arrivals, escort paths and boarding AI. A scripted
pilot supplies perfect interactions: it moves directly to navigation/scan/collect
targets, destroys required targets and disables the requested subsystem parts.
Each mission must reach success and, on a fresh run, fail after player death.
Combat and ordinary flight are deliberately omitted from this flow check;
it cannot establish human completion times or casual touch-control difficulty.
Campaign logs are retained beside `results.log` and uploaded by CI.

For an optional separate-process test against a running app, use the campaign
resource tree printed by the suite:

```sh
build/network-checks.<run>/campaign/NetworkChecks --peer 127.0.0.1:27910
```

Create a game in the app first. Select its actual port if a simulator or another
app instance holds 27910. The peer announces connection, automatically enters
when the host starts, receives snapshots and flies for up to three minutes.

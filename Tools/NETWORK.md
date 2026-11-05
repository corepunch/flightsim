Run `./Tools/run-network-checks.sh` on macOS with Xcode's command-line tools.
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
| Primary weapons | Predicted shots and authoritative bolt events, lifespan and relative projectile speed |
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

Compatibility change: protocol **4** now requires validation of the existing
CS_GAME configstring before beginning. Version 3 clients never checked it, so
keeping version 3 would permit old clients to silently bypass the new check.
Version 4 servers reject them at connect; version 4 clients are rejected by
version 3 servers. Packet layout otherwise remains unchanged. CS_GAME contains
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
- No physical macOS/iOS peers, LAN discovery, Wi-Fi jitter, NAT, MTU/path issues,
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

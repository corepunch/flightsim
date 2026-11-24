# Host-authoritative Arcline LAN prototype

This branch adds the host authority boundary and an Apple SceneKit stepping probe.
It does **not** change the existing v3 application, the shipping LAN mode, or offline
physics. It does not use a second car-physics model.

## Boundary now implemented

- An established peer sends only steering, throttle, brake, and handbrake with a
  version, race ID and increasing input sequence. The transport supplies the peer's
  identity. The fixed-length packet has no position, velocity, progress, timestamp,
  target car, finish or award fields. Protocol version 4 is reserved for this mode;
  never negotiate v3 into an authoritative race.
- The host samples controls at 60 logical ticks/s. Inputs outside control bounds are
  clamped. Duplicates, old-race inputs and unknown peers are ignored. Missing
  inputs become neutral after 15 ticks, and a disconnected driver cannot finish.
- A trusted simulation caller must submit one complete post-physics set of car
  samples for each tick. Invalid input is not a substitute for physics. A malformed
  host observation rejects the whole tick, not part of it. The resulting state
  carries the applied sequence and server-derived finish tick. This uses measured
  continuous track progress, not an input packet or a client finish time.
- The portable boundary can be run with `sh Tools/authority-test.sh`. It tests rejection
  and observable state at both halves of a tick, not a duplicate simulation. The
  Apple-only `sh Tools/authority-scenekit-probe.sh` uses a real
  `SCNPhysicsVehicle` in an offscreen `SCNRenderer`, checks the actual delegate ordering,
  uses the C boundary for control and pose submission, and verifies the vehicle
  moves. The probe has not been executed in Linux.

## Planned production connection, in order

1. **Prove native stepping, then use the exact game scene.** In the probe, exercise
   `SCNRenderer.update(atTime:)` at monotonically scheduled 60 Hz. Apple's
   [fixed physics step](https://developer.apple.com/documentation/scenekit/scnphysicsworld/timestep)
   does not guarantee one delegate pair per physics tick on an arbitrary
   render-bound `SCNView`. If update-only does not run the physics callback, test
   the Metal `SCNRenderer.render(atTime:viewport:commandBuffer:passDescriptor:)` path
   offscreen. Do not attach a visible view to the simulation scene to drive a second
   clock. Confirm on Apple hardware, including bounded catch-up and timing under
   load; stop the race explicitly if the host suspends or cannot keep its clock.
2. **Keep the same track and car dynamics.** Build a host simulation scene with every
   human and bot as a dynamic `Car` with existing wheel/force/ground behavior. Feed
   existing `Car.step` from the pre-physics control frame and derive aim/assist per
   human setting, not only car index zero. Compute fresh track progress and
   read corrected poses after `Car.enforceGround`, in the post-physics delegate.
   Today `Car.step` calls `sense` before forces, and `Car.netState` mixes cached position
   with current orientation; split the sensing/control calls or expose a coherent
   same-tick post-physics sample for the host only. Preserve the current offline
   `GameScene` path and compare handling with recorded inputs under the same elapsed
   time. Keep human and bot cars in the same SceneKit collision world.
3. **Wire v4 exclusivity.** Pass bounded latest-input messages and barriers for peer
   joins/disconnects from the existing network queue to the simulation owner; never
   read or write SceneKit objects on the network queue. Replace v3 gameplay handlers
   for owner state and finish rather than leaving them as fallback. Send complete
   same-tick snapshots at 30 Hz and publish reliable final standings from host ticks
   (same-tick ties use car ID), existing DNF grace and phase logic. Include the
   race ID in every state/result, reject stale IDs and older ticks, and do not
   present unaccepted versions as joinable. Keep on-air v3 out of any v4 room.
4. **Present a host or guest snapshot.** Use the existing interpolation/render path
   for every guest car, including the guest's own (no dynamic collider/vehicle
   on guests), local camera/HUD and sequenced input. The host can render its trusted
   state without a network round trip. Showing the car from snapshots adds input
   latency for guests; prediction and reconciliation should be separate work.
5. **Before enabling v4:** test a full Mac/iPhone or two-iPhone race with a deliberate
   input delay/drop, bot and two humans, blocked legacy joins, disconnect and
   reconnect between races, preserved offline steering/braking, simultaneous
   finish, and shared results. Add SceneKit visual/handling parity measurements.
   Do not let unverified LAN results adjust persistent career balances.

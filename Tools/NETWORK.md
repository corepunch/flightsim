# LAN Multiplayer

The host advertises `_kestrel._udp` through Bonjour; gameplay uses IPv4 UDP
unicast. Discovery queries every resolved IPv4 address and keeps the first
responding route for each host. Socket, permission, search, resolution and
unreachable-host errors remain separate diagnostics.

Both apps declare `NSLocalNetworkUsageDescription` and `_kestrel._udp` in
`NSBonjourServices`. Declared Bonjour and UDP unicast do not require the iOS
multicast entitlement. See [Apple's local-network privacy guidance](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy).

The host can edit arena, ship, pilot capacity, kill limit, duration and respawn
delay in the waiting room. Guests receive the roster and rules; ongoing matches
accept new pilots without resetting scores or the clock. These settings are the
archived `g_lan*` cvars described in [CONSOLE.md](../CONSOLE.md).

For a manual device check, build the Mac app with `./build.sh` and install the
phone app with `./build.sh iphone`. Use the same reachable Wi-Fi, allow Local
Network access, create a game on one peer and join from the other. Verify motion,
firing, late joining and leaving; then reverse host direction. A simulator can
exercise the interface but cannot validate iOS local-network permission behavior.
A connected USB device may also offer a link-local network route, so check logs
when specifically testing Wi-Fi.

`+lan_host`, `+lan_browse` and `+lan_start` open the corresponding development
flows. `+connect <host-ip>:<port>` bypasses discovery for a direct connection check.
Keep the host app foregrounded. The LAN and flight screens prevent auto-lock.

Automated checks are limited to the headless unit suite with a 10-second total
budget: `./Tools/run-unit-checks.sh`. Network stress, rendered catalogues and
campaign-playthrough harnesses are not part of CI.

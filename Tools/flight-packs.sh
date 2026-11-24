# Flight packs have an engine module or its game.json manifest. Standalone
# projects in Games (such as Racing) intentionally use neither convention.
is_flight_pack() {
    [[ -d "$1/Game" || -f "$1/game.json" ]]
}

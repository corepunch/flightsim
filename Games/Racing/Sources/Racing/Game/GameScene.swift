import SceneKit
import simd

/// Someone on the grid besides the player.
struct Entrant {
    var name: String
    var design: CarDesign
}

/// A networked race. Entries are in grid order of car id; the first is the player's own car.
struct OnlineRace {
    struct Entry {
        var id: UInt8
        var name: String
        var design: CarDesign
        /// Driven on another device (true) or here, by the player or as one of the host's bots.
        var remote: Bool
    }
    let client: RaceClient
    let entries: [Entry]
}

struct RaceConfig {
    var definition: TrackDefinition
    var player: CarDesign
    var playerName = "YOU"
    var rivals: [Entrant]
    var laps = 3
    var isStreetRace = false
    /// Driver assist: slows the car for corners it is too fast for and leans it away from
    /// a barrier at the last moment (`Car.guardSteer`). It never steers along the road.
    var assist = true
    /// 0 easy, 1 normal, 2 hard.
    var difficulty = 1
    /// Set for a networked race: who is on the grid, and the connection.
    var online: OnlineRace?

    /// A quick race in one of the stock cars against the rest of the roster.
    init(definition: TrackDefinition, carIndex: Int = 0) {
        self.definition = definition
        let roster = CarRoster.all
        let chosen = min(max(carIndex, 0), roster.count - 1)
        player = roster[chosen]
        rivals = roster.indices.filter { $0 != chosen }.map { Entrant(name: roster[$0].name, design: roster[$0]) }
    }

    init(definition: TrackDefinition, player: CarDesign, rivals: [Entrant]) {
        self.definition = definition
        self.player = player
        self.rivals = rivals
    }
}

struct RaceStanding {
    var name: String
    var color: SIMD3<Float>
    var isPlayer: Bool
    /// Finish time, or nil if still racing when the player finished.
    var time: Float?
}

struct RaceResult {
    var position: Int
    var time: Float
    var bestLap: Float?
    var isRecord: Bool
    var standings: [RaceStanding]
}

enum RaceEvent {
    /// 3, 2, 1, then 0 for GO.
    case countdown(Int)
    case collision(Float)
    case hardLanding(Float)
    case boost
    case lap(time: Float, best: Bool, lapsLeft: Int)
    case finished(RaceResult)
}

/// What the HUD shows, copied out once a frame.
struct HUDState {
    var speedKMH: Float = 0
    var engineRunning = false
    var skidding: Float = 0
    var lap = 1
    var laps = 3
    var position = 1
    var count = 1
    var raceTime: Float = 0
    var lapTime: Float = 0
    var bestLap: Float?
    var boosting = false
    var racing = false
    /// Minimap dots in 0...1, player last.
    var dots: [(position: SIMD2<Float>, color: SIMD3<Float>, isPlayer: Bool)] = []
}

/// Best laps per circuit, kept in user defaults.
enum Records {
    static func bestLap(for definition: TrackDefinition) -> Float? {
        let value = UserDefaults.standard.float(forKey: "bestLap.\(definition.seed)")
        return value > 0 ? value : nil
    }

    static func setBestLap(_ time: Float, for definition: TrackDefinition) {
        UserDefaults.standard.set(time, forKey: "bestLap.\(definition.seed)")
    }
}

/// Owns the scene, the cars, the camera and the race itself. The per-frame loop
/// runs from SceneKit's render callback.
final class GameScene: NSObject, SCNSceneRendererDelegate, SCNPhysicsContactDelegate {

    let scene = SCNScene()
    let track: TrackPath
    let config: RaceConfig

    private(set) var cars: [Car] = []
    private var contactShadows: [SCNNode] = []
    private var names: [String] = []
    /// Online only: each car's id, and whether another device drives it.
    private var carIDs: [UInt8] = []
    private var remote: [Bool] = []
    private var lastTick = 0
    private var player: Car { cars[0] }
    private var lapsDone: [Int] = []
    private var laneTimers: [Float] = []
    private var boostSections: [Bool] = []
    private var rng = SplitMix64(seed: 4242)

    private(set) var cameraNode: SCNNode!
    private var camera: SCNCamera!
    private var cameraForward: SIMD3<Float>?
    private var cameraLead: Float = 0
    private var cameraFOV: Float = 90

    // --- Inputs (set by GameViewController) ---
    private var driverInput = CarInput(throttle: 0)
    var controls: CarInput {
        get {
            lock.lock(); defer { lock.unlock() }
            return driverInput
        }
        set {
            lock.lock(); defer { lock.unlock() }
            driverInput = newValue
        }
    }

    /// Demo for the track recorder: the player's car glides round the lap, no race.
    var autoDrive = false {
        didSet {
            guard autoDrive else { return }
            phase = .racing
            player.setDemo(true)
            for rival in cars.dropFirst() { rival.node.isHidden = true }
        }
    }
    private var demoDistance: Float = 0
    private var demoSpeed: Float = 30
    /// Debug stand-ins for the player, with telemetry printed every two seconds (`-driver <name>`).
    enum DebugDriver: String {
        /// The rival driver drives the player's car.
        case rival
        /// Nobody touches the screen: shows what the car and the assist do on their own.
        case handsOff = "handsoff"
        /// A casual thumb: steers a quarter of a second late and never brakes.
        case casual
    }
    var debugDriver: DebugDriver?
    private var steerHistory: [Float] = []
    private var telemetryTime: Float = 0
    private var telemetryHits = 0
    private var telemetryScrape: Float = 0

    private enum Phase { case countdown(Float), racing, finished }
    private var phase = Phase.countdown(3.6)
    private var raceTime: Float = 0
    private var lastTime: TimeInterval?
    private var didProbePhysics = false
    private var groundIssues: [Int: String] = [:]

    // --- Shared with the main thread ---
    private let lock = NSLock()
    private var hudState = HUDState()
    private var events: [RaceEvent] = []

    var hud: HUDState {
        lock.lock(); defer { lock.unlock() }
        return hudState
    }

    /// Hands over everything that happened since the last call.
    func drainEvents() -> [RaceEvent] {
        lock.lock(); defer { lock.unlock() }
        let out = events
        events.removeAll()
        return out
    }

    private func emit(_ event: RaceEvent) {
        lock.lock(); events.append(event); lock.unlock()
    }

    // MARK: - Init

    init(config: RaceConfig) {
        self.config = config
        track = TrackPath(definition: config.definition)
        super.init()
        // Commit the background-built scene and starting grid before the view starts rendering.
        SCNTransaction.begin()
        SCNTransaction.disableActions = true
        buildScene()
        restart()
        SCNTransaction.commit()
        SCNTransaction.flush()
    }

    /// Used by the track recorder.
    convenience init(definition: TrackDefinition = TrackLibrary.all[0], audio: Bool = true) {
        self.init(config: RaceConfig(definition: definition))
    }

    private func buildScene() {
        let circuitTheme = track.definition.theme
        let theme = config.isStreetRace ? circuitTheme.streetNight : circuitTheme
        let sky = ProceduralTextures.sky(theme: theme, seed: track.definition.seed)
        scene.background.contents = sky
        scene.lightingEnvironment.contents = sky
        scene.lightingEnvironment.intensity = theme.environment * 0.5
        scene.fogStartDistance = theme.fogStart
        scene.fogEndDistance = theme.fogEnd
        scene.fogDensityExponent = 1.4
        scene.fogColor = Self.color(theme.skyHorizon)

        addLighting(theme)

        // Everything below is generated from the track's master curve.
        scene.rootNode.addChildNode(TrackMeshBuilder.buildTrackNode(path: track))
        scene.rootNode.addChildNode(CityScenery.build(path: track))
        boostSections = TrackSections.plan(path: track).map { $0.deck == .boost }

        // The player's car first, then the rivals.
        if let online = config.online {
            cars = online.entries.map { Car(design: $0.design) }
            names = online.entries.map(\.name)
            carIDs = online.entries.map(\.id)
            remote = online.entries.map(\.remote)
        } else {
            cars = [Car(design: config.player)] + config.rivals.map { Car(design: $0.design) }
            names = [config.playerName] + config.rivals.map(\.name)
            remote = cars.map { _ in false }
        }
        for (i, car) in cars.enumerated() {
            scene.rootNode.addChildNode(car.node)
            car.install(in: scene.physicsWorld)
            if remote[i] { car.setRemote() }
        }
        player.node.physicsBody?.contactTestBitMask = PhysicsCategory.car | PhysicsCategory.track
        scene.physicsWorld.contactDelegate = self
        if config.isStreetRace {
            contactShadows = cars.map { car in
                car.installHeadlights()
                let shadow = Self.makeContactShadow(for: car.design)
                scene.rootNode.addChildNode(shadow)
                return shadow
            }
        }

        setupCamera()
    }

    /// Puts everyone back on the grid and starts the countdown.
    func restart() {
        lock.lock(); events.removeAll(); lock.unlock()
        let count = cars.count
        let lanes: [Float] = [-3, 3, -1.2, 1.2, 0, -2]
        let basePace: Float = [0.9, 0.95, 1.0][min(max(config.difficulty, 0), 2)]
        // Online, everyone works out the same grid from the car ids.
        let gridOrder = carIDs.isEmpty ? [] : carIDs.sorted()
        for (i, car) in cars.enumerated() {
            // Rivals fill the front of the grid; the player starts at the back.
            var slot = i == 0 ? count - 1 : i - 1
            if !gridOrder.isEmpty { slot = gridOrder.firstIndex(of: carIDs[i]) ?? i }
            car.place(progress: -(10 + 7 * Float(slot)), lateral: slot % 2 == 0 ? -3.2 : 3.2, on: track)
            car.lane = i == 0 ? 0 : lanes[(i - 1) % lanes.count]
            car.pace = i == 0 ? 1 : basePace - 0.012 * Float(i - 1)
            car.skill = i == 0 ? 1 : [0.6, 0.78, 1.0][min(max(config.difficulty, 0), 2)]
        }
        lapsDone = Array(repeating: 0, count: count)
        laneTimers = (0..<count).map { 3 + Float($0) * 1.7 }
        raceTime = 0
        steerHistory.removeAll()
        cameraForward = nil
        cameraLead = 0
        lastTick = 0
        phase = autoDrive ? .racing : .countdown(3.6)
        didProbePhysics = false
        groundIssues.removeAll()
        publishHUD()
    }

    private static func color(_ c: SIMD3<Float>) -> UIColor {
        UIColor(red: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), alpha: 1)
    }

    private func addLighting(_ theme: TrackTheme) {
        let sunLight         = SCNLight()
        sunLight.type        = .directional
        sunLight.color       = Self.color(theme.sunColor)
        sunLight.intensity   = theme.sunIntensity
        sunLight.castsShadow = true
        sunLight.shadowMode  = .forward
        sunLight.shadowSampleCount = config.isStreetRace ? 8 : 1
        sunLight.shadowRadius = config.isStreetRace ? 2 : 0
        sunLight.shadowMapSize = CGSize(width: 2048, height: 2048)
        sunLight.shadowCascadeCount = 4
        sunLight.shadowCascadeSplittingFactor = 0.8
        sunLight.automaticallyAdjustsShadowProjection = true
        sunLight.maximumShadowDistance = config.isStreetRace ? 110 : 200
        sunLight.shadowColor = UIColor(white: 0, alpha: config.isStreetRace ? 0.85 : 0.5)
        let sunNode          = SCNNode()
        sunNode.light        = sunLight
        sunNode.eulerAngles  = SCNVector3(theme.sunAngles.x, theme.sunAngles.y, 0)
        scene.rootNode.addChildNode(sunNode)

        let ambLight         = SCNLight()
        ambLight.type        = .ambient
        ambLight.color       = Self.color(simd_mix(theme.skyHorizon, SIMD3(repeating: 1), SIMD3(repeating: 0.4)))
        ambLight.intensity   = theme.ambient * 0.5
        let ambNode          = SCNNode()
        ambNode.light        = ambLight
        scene.rootNode.addChildNode(ambNode)
    }

    /// Freezes the game while the app is inactive or the race is paused.
    func setActive(_ active: Bool) {
        scene.isPaused = !active
        lastTime = nil
    }

    private func setupCamera() {
        camera               = SCNCamera()
        camera.projectionDirection = .horizontal
        camera.fieldOfView   = CGFloat(cameraFOV)
        camera.zFar          = 2400
        camera.zNear         = 0.5
        // HDR is only on for the bloom around the generated emissive markings.
        camera.wantsHDR = true
        camera.wantsExposureAdaptation = false
        camera.motionBlurIntensity = 0
        camera.bloomIntensity = 0.7
        // Neon (emission 1.5+) clears this; car bodies don't emit, so lit paint stays under it.
        camera.bloomThreshold = 1.0
        camera.bloomBlurRadius = 12

        cameraNode           = SCNNode()
        cameraNode.camera    = camera
        scene.rootNode.addChildNode(cameraNode)
    }

    // MARK: - Frame update (SCNSceneRendererDelegate)

    func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        guard let last = lastTime else {
            lastTime = time
            updateCamera(dt: 0)
            return
        }
        let dt = min(Float(time - last), 1.0 / 30.0)
        lastTime = time
        guard dt > 0 else { return }

        if let online = config.online {
            updateOnline(online.client, dt: dt)
            updateCamera(dt: dt)
            publishHUD()
            return
        }

        if autoDrive {
            updateDemo(dt: dt)
            updateCamera(dt: dt)
            publishHUD()
            return
        }

        switch phase {
        case .countdown(let left):
            let now = left - dt
            for car in cars { car.step(dt: dt, input: CarInput(), track: track, hold: true) }
            if Int(ceil(now)) != Int(ceil(left)), now > 0, now <= 3 { emit(.countdown(Int(ceil(now)))) }
            if now <= 0 {
                phase = .racing
                emit(.countdown(0))
            } else {
                phase = .countdown(now)
            }
        case .racing, .finished:
            raceTime += dt
            stepCars(dt: dt)
        }

        updateCamera(dt: dt)
        publishHUD()
        if debugDriver != nil { printTelemetry(dt: dt) }
    }

    func renderer(_ renderer: SCNSceneRenderer, didSimulatePhysicsAtTime time: TimeInterval) {
        if !autoDrive {
            for (i, car) in cars.enumerated() where !remote[i] {
                let position = RacePhysicsDiagnostics.enabled ? car.node.presentation.simdWorldPosition : .zero
                let velocity = RacePhysicsDiagnostics.enabled ? car.node.physicsBody?.velocity : nil
                let lift = car.enforceGround(on: track)
                if RacePhysicsDiagnostics.enabled {
                    probeGround(car: car, index: i, position: position, velocity: velocity, lift: lift)
                }
            }
            didProbePhysics = true
        }
        for (car, shadow) in zip(cars, contactShadows) {
            let pose = car.node.presentation
            let position = pose.simdWorldPosition
            // The physics pose is a frame ahead of the car's last measured track distance.
            let nearby = track.frame(at: car.s)
            let frame = track.frame(at: car.s + simd_dot(position - nearby.position, nearby.forward))
            let offset = position - frame.position
            let height = simd_dot(offset, frame.up)
            let lateral = simd_dot(offset, frame.right)
            let contact = min(1, max(0, (1.7 - height) / 1.1))
            let offDeck = height < -0.5 || abs(lateral) > frame.halfWidth + 0.4
            shadow.isHidden = car.node.isHidden || offDeck || contact == 0
            guard !shadow.isHidden else { continue }

            let nose = pose.simdWorldOrientation.act(SIMD3<Float>(0, 0, -1))
            let heading = atan2(simd_dot(nose, frame.right), simd_dot(nose, frame.forward))
            let deck = simd_quatf(simd_float3x3(columns: (frame.right, frame.up, -frame.forward)))
            shadow.simdOrientation = deck * simd_quatf(angle: -heading, axis: SIMD3(0, 1, 0))
            shadow.simdPosition = position - frame.up * (height - 0.045)
            shadow.opacity = CGFloat(contact)
        }
    }

    /// Compare the analytic surface with a deck ray in the live physics world.
    private func probeGround(car: Car, index: Int, position: SIMD3<Float>, velocity: SCNVector3?, lift: Float) {
        let surface = track.ground(at: position, near: car.s)
        let frame = track.frame(at: car.s)
        let height = simd_dot(position - frame.position, frame.up)
        let issue: String?
        if lift > 0.1 {
            issue = "ground lift"
        } else if surface == nil, height < 0.3 {
            issue = "ground lookup missed"
        } else {
            issue = nil
        }
        let previous = groundIssues[index]
        groundIssues[index] = issue
        guard !didProbePhysics || (issue != nil && issue != previous) else { return }

        let deckY = surface.map { position.y - $0.clearance / $0.normal.y } ?? frame.position.y
        let hit = scene.physicsWorld.rayTestWithSegment(
            from: SCNVector3(position.x, deckY + 2, position.z),
            to: SCNVector3(position.x, deckY - 2, position.z),
            options: [.collisionBitMask: NSNumber(value: PhysicsCategory.track)]
        ).contains { $0.node.name == "trackMesh" }
        let id = carIDs.isEmpty ? index : Int(carIDs[index])
        let mode = config.online.map { $0.client.isHost ? "host" : "guest" } ?? "local"
        let status = issue ?? "first physics frame"
        print("[race-physics] \(mode) track=\(track.definition.name) seed=\(track.definition.seed) car=\(id) \(status) rayHit=\(hit) deck=\(surface != nil) pos=\(position) s=\(car.s) lift=\(lift) velocity=\(velocity ?? SCNVector3Zero)")
    }

    // MARK: - Online

    /// The race clock is the server's: the countdown and every lap time are measured against
    /// it, so all devices agree. Local cars (the player, the host's bots) are simulated here and
    /// sent out; the others are posed from interpolated snapshots.
    private func updateOnline(_ client: RaceClient, dt: Float) {
        let now = client.serverTime
        switch client.phase {
        case .lobby, .loading:
            for (i, car) in cars.enumerated() where !remote[i] { car.step(dt: dt, input: CarInput(), track: track, hold: true) }
        case .countdown(let start):
            let left = start - now
            for (i, car) in cars.enumerated() where !remote[i] { car.step(dt: dt, input: CarInput(), track: track, hold: true) }
            let tick = Int(ceil(left))
            if tick != lastTick, tick > 0, tick <= 3 { emit(.countdown(tick)) }
            lastTick = tick
        case .racing(let start):
            if case .countdown = phase {
                phase = .racing
                emit(.countdown(0))
            }
            raceTime = Float(now - start)
            stepCars(dt: dt)
        case .results:
            raceTime += dt
            stepCars(dt: dt)
        }

        let samples = client.remoteSamples()
        let finished = client.finishTimes
        for (i, car) in cars.enumerated() where remote[i] {
            let id = carIDs[i]
            if let sample = samples[id] {
                let firstPose = car.node.isHidden
                car.applyRemote(sample, track: track, dt: dt)
                if RacePhysicsDiagnostics.enabled, firstPose {
                    print("[race-physics] remote active car=\(id) pos=\(car.worldPosition)")
                }
            } else if !car.node.isHidden {
                // Roster/phase changes clear the buffer. Packet gaps can
                // retain a visible pose, but stale poses cannot collide.
                car.setRemote()
                if RacePhysicsDiagnostics.enabled {
                    print("[race-physics] remote inactive car=\(id)")
                }
            }
            car.finishTime = finished[id]
        }
        var mine: [UInt8: NetCarState] = [:]
        for (i, car) in cars.enumerated() where !remote[i] { mine[carIDs[i]] = car.netState }
        client.send(states: mine)
    }

    // MARK: - Demo

    /// The track recorder's drive-through: along the centre line, slowing for corners.
    private func updateDemo(dt: Float) {
        var tightest: Float = 0
        for k in stride(from: Float(0), to: 200, by: 4) { tightest = max(tightest, abs(track.frame(at: demoDistance + k).curvature)) }
        let target = min(player.design.spec.topSpeed, (34 / max(tightest, 1e-4)).squareRoot())
        demoSpeed += max(-34 * dt, min(16 * dt, target - demoSpeed))
        demoDistance += demoSpeed * dt
        player.glide(to: demoDistance, speed: demoSpeed, track: track)
    }

    // MARK: - Race

    func physicsWorld(_ world: SCNPhysicsWorld, didBegin contact: SCNPhysicsContact) {
        guard case .racing = phase, !autoDrive, player.finishTime == nil else { return }
        guard contact.nodeA === player.node || contact.nodeB === player.node else { return }
        let impact = Float(contact.collisionImpulse / Car.mass)
        guard impact > 1 else { return }
        let other = contact.nodeA === player.node ? contact.nodeB : contact.nodeA
        if other.physicsBody?.categoryBitMask == PhysicsCategory.track {
            // The track is one collider. Only its side faces count as barrier hits.
            let normal = contact.contactNormal
            let across = simd_dot(SIMD3(normal.x, normal.y, normal.z), track.frame(at: player.s).right)
            guard abs(across) > 0.7 else { return }
        }
        emit(.collision(impact))
    }

    private func stepCars(dt: Float) {
        let length = track.totalLength
        let playerFinished = player.finishTime != nil

        for (i, car) in cars.enumerated() {
            if remote[i] { continue }
            let human = i == 0 && debugDriver != .rival && !playerFinished
            if human {
                var input = controls
                if debugDriver == .handsOff { input = CarInput() }
                if debugDriver == .casual {
                    steerHistory.append(RivalDriver.input(for: car, track: track).steer)
                    if steerHistory.count > 15 { steerHistory.removeFirst() }
                    input = CarInput(steer: steerHistory[0], brake: 0, throttle: 1)
                }
                // The assist also lifts and brakes for corners that are too tight for this speed.
                // It leaves the steering alone.
                if config.assist && !input.handbrake {
                    let limit = RivalDriver.cornerSpeed(for: car, track: track, grip: 62)
                    if car.speed > limit { input.throttle = 0 }
                    if car.speed > limit + 5 { input.brake = max(input.brake, 0.7) }
                }
                car.step(dt: dt, input: input, track: track,
                          wallGuard: config.assist ? 1 : 0)
            } else {
                updateRival(i, dt: dt)
                car.step(dt: dt, input: RivalDriver.input(for: car, track: track), track: track)
            }

            // Boost pads cover the middle of the deck.
            let section = Int(car.s / track.step) / TrackPath.sectionSamples
            if boostSections[section % boostSections.count], abs(car.d) < 0.44 * track.frame(at: car.s).halfWidth {
                car.giveBoost()
            }

            if i == 0, !playerFinished {
                if car.pendingHit > 0 { emit(.collision(car.pendingHit)); spark(at: car); telemetryHits += 1 }
                if car.landingSpeed > 0 { emit(.hardLanding(car.landingSpeed)) }
                if car.pendingBoost { emit(.boost) }
                if car.scraping { telemetryScrape += dt }
            }
            car.pendingHit = 0
            car.pendingBoost = false

            // Laps.
            let done = Int((car.progress / length).rounded(.down))
            if done > lapsDone[i], car.finishTime == nil {
                lapsDone[i] = done
                let lapTime = raceTime - car.lapStart
                car.lapStart = raceTime
                car.lastLap = lapTime
                let best = car.bestLap.map { lapTime < $0 } ?? true
                if best { car.bestLap = lapTime }
                // A finished car cruises its lap of honour.
                if done >= config.laps {
                    car.finishTime = raceTime
                    car.pace = 0.55
                    config.online?.client.reportFinish(carID: carIDs[i], time: raceTime)
                }
                if i == 0 {
                    emit(.lap(time: lapTime, best: best, lapsLeft: config.laps - done))
                    if car.finishTime != nil { finishRace() }
                }
            }
        }
    }

    /// Lane choice, traffic and a little rubber band for rival `i`.
    private func updateRival(_ i: Int, dt: Float) {
        let car = cars[i]
        let length = track.totalLength
        laneTimers[i] -= dt
        if laneTimers[i] <= 0 {
            laneTimers[i] = rng.float(4...9)
            car.lane = rng.float(-3.5...3.5)
        }
        // Pull out from behind a slower car.
        var wanted: Float = 0
        for other in cars where other !== car {
            var gap = other.s - car.s
            if gap < -length / 2 { gap += length }
            if gap > 0, gap < 34, abs(other.d - car.d) < 3.4, other.speed < car.speed + 2 {
                wanted = other.d > car.d ? -3.4 : 3.4
            }
        }
        car.avoid += (wanted - car.avoid) * min(1, 2.5 * dt)

        guard i != 0, car.finishTime == nil else { return }
        // Rubber band: rivals far ahead ease off a little, rivals far behind push.
        let basePace: Float = [0.9, 0.95, 1.0][min(max(config.difficulty, 0), 2)] - 0.012 * Float(i - 1)
        let lead = car.progress - player.progress
        let band = max(-0.035, min(0.035, -lead / 4000))
        car.pace += (basePace + band - car.pace) * min(1, dt)
    }

    /// Finishers by time, then everyone else by distance covered.
    private func ranking() -> [Car] {
        cars.sorted { a, b in
            switch (a.finishTime, b.finishTime) {
            case let (x?, y?): return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.progress > b.progress
            }
        }
    }

    private func finishRace() {
        phase = .finished
        let order = ranking()
        let position = (order.firstIndex { $0 === player } ?? 0) + 1
        var record = false
        if debugDriver == nil, let best = player.bestLap {
            let previous = Records.bestLap(for: config.definition)
            if previous.map({ best < $0 }) ?? true {
                Records.setBestLap(best, for: config.definition)
                record = true
            }
        }
        let standings = order.map { car in
            RaceStanding(name: names[cars.firstIndex { $0 === car } ?? 0], color: car.design.primary,
                         isPlayer: car === player, time: car.finishTime)
        }
        emit(.finished(RaceResult(position: position, time: raceTime, bestLap: player.bestLap,
                                  isRecord: record, standings: standings)))
    }

    private func publishHUD() {
        var state = HUDState()
        let order = ranking()
        state.speedKMH = player.speed * 3.6
        state.engineRunning = player.finishTime == nil
        let slipSpeed = abs(player.lateralSpeed - player.speed * sin(player.heading))
        state.skidding = state.engineRunning ? min(1, max(player.lockedWheelSkid, (slipSpeed - 3) / 10)) : 0
        state.laps = config.laps
        state.lap = min(config.laps, max(1, lapsDone.first.map { $0 + 1 } ?? 1))
        state.position = (order.firstIndex { $0 === player } ?? 0) + 1
        state.count = cars.count
        state.raceTime = player.finishTime ?? raceTime
        state.lapTime = raceTime - player.lapStart
        state.bestLap = player.bestLap
        state.boosting = player.boost > 0
        if case .racing = phase { state.racing = true }
        state.dots = cars.reversed().map {
            (track.minimapPosition(for: $0.worldPosition), $0.design.primary, $0 === player)
        }
        lock.lock(); hudState = state; lock.unlock()
    }

    // MARK: - Effects

    private static let contactShadowMaterial: SCNMaterial = {
        let size = CGSize(width: 64, height: 64)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let colors = [UIColor(white: 0, alpha: 0.94), UIColor(white: 0, alpha: 0.72), UIColor.clear]
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                      colors: colors.map(\.cgColor) as CFArray, locations: [0, 0.64, 1])!
            let centre = CGPoint(x: size.width / 2, y: size.height / 2)
            ctx.cgContext.drawRadialGradient(gradient, startCenter: centre, startRadius: 0,
                                             endCenter: centre, endRadius: size.width / 2, options: [])
        }
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = image
        material.writesToDepthBuffer = false
        return material
    }()

    /// The soft shadow close to the deck is still visible under tunnel lighting.
    private static func makeContactShadow(for design: CarDesign) -> SCNNode {
        let plane = SCNPlane(width: CGFloat(design.halfWidth * 2 + 0.55),
                             height: CGFloat(design.frontCollisionExtent + design.rearCollisionExtent + 0.8))
        plane.firstMaterial = contactShadowMaterial
        let footprint = SCNNode(geometry: plane)
        footprint.castsShadow = false
        footprint.eulerAngles.x = -.pi / 2
        footprint.position.z = (design.rearCollisionExtent - design.frontCollisionExtent) / 2
        let shadow = SCNNode()
        shadow.isHidden = true
        shadow.addChildNode(footprint)
        return shadow
    }

    private static let sparkImage: UIImage = {
        UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { ctx in
            UIColor.white.setFill()
            ctx.cgContext.fillEllipse(in: CGRect(x: 0, y: 0, width: 8, height: 8))
        }
    }()

    private func spark(at car: Car) {
        let system = SCNParticleSystem()
        system.particleImage = Self.sparkImage
        system.birthRate = 220
        system.emissionDuration = 0.08
        system.loops = false
        system.particleLifeSpan = 0.3
        system.particleVelocity = 9
        system.particleVelocityVariation = 8
        system.spreadingAngle = 70
        system.particleSize = 0.03
        system.particleSizeVariation = 0.015
        system.particleColor = UIColor(red: 1, green: 0.7, blue: 0.25, alpha: 1)
        system.blendMode = .additive
        system.isAffectedByGravity = true
        system.isLightingEnabled = false
        let frame = track.frame(at: car.s)
        let emitter = SCNNode()
        emitter.simdPosition = car.worldPosition + frame.right * (car.d > 0 ? car.design.halfWidth : -car.design.halfWidth)
        emitter.addParticleSystem(system)
        scene.rootNode.addChildNode(emitter)
        emitter.runAction(.sequence([.wait(duration: 1), .removeFromParentNode()]))
    }

    // MARK: - Camera

    private func updateCamera(dt: Float) {
        let car = player
        let frame = track.frame(at: car.s)
        // Look into the turn: the view swings ahead of the car by an angle that grows with
        // how hard it is turning, so the road it is turning into comes on screen.
        let lead = max(-0.5, min(0.5, car.yawRate * 0.5))
        cameraLead += (lead - cameraLead) * min(1, 3 * dt)
        let aim = simd_quatf(angle: cameraLead, axis: SIMD3<Float>(0, 1, 0)).act(car.worldForward)
        var forward = cameraForward ?? car.worldForward
        forward = simd_normalize(forward + (aim - forward) * min(1, 6.5 * dt))
        cameraForward = forward
        // Lean with the banking, but not all the way.
        let up = simd_normalize(simd_mix(SIMD3<Float>(0, 1, 0), frame.up, SIMD3(repeating: 0.65)))

        let boosting: Float = car.boost > 0 ? 1 : 0
        let behind: Float = 9.5
        let above: Float = 3.7
        // Mostly level, so a climb does not drop the camera on to the deck.
        let level = simd_normalize(SIMD3<Float>(forward.x, forward.y * 0.4, forward.z))
        var position = car.worldPosition - level * behind + up * above
        // Never dip under the deck behind a crest.
        let back = track.frame(at: car.s - behind)
        position.y = max(position.y, back.position.y + 1.6)
        cameraNode.simdPosition = position
        cameraNode.simdLook(at: car.worldPosition + forward * 14 + up * 0.8, up: up, localFront: SIMD3<Float>(0, 0, -1))

        let fov = 90 + min(car.speed, 120) * 0.14 + boosting * 6
        cameraFOV += (fov - cameraFOV) * (dt > 0 ? min(1, 4 * dt) : 1)
        camera.fieldOfView = CGFloat(cameraFOV)
    }

    // MARK: - Telemetry (debug)

    private func printTelemetry(dt: Float) {
        telemetryTime += dt
        guard telemetryTime > 2 else { return }
        telemetryTime = 0
        let order = ranking()
        let line = order.map { car -> String in
            String(format: "%@%@ %.0fm %.0fkm/h", car === player ? "*" : "", car.design.name, car.progress, car.speed * 3.6)
        }.joined(separator: " | ")
        print(String(format: "[race] t=%.0fs P%d %.0fm %.0fkm/h lap=%d last=%.1fs hits=%d scrape=%.0fs pads=%d len=%.0fm :: %@",
                     raceTime, (order.firstIndex { $0 === player } ?? 0) + 1, player.progress, player.speed * 3.6,
                     lapsDone[0] + 1, player.lastLap ?? 0, telemetryHits, telemetryScrape,
                     boostSections.filter { $0 }.count, track.totalLength, line))
    }
}

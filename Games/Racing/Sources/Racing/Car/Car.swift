import SceneKit
import simd

enum RacePhysicsDiagnostics {
    static let enabled = UserDefaults.standard.bool(forKey: "racePhysics")
}

enum PhysicsCategory {
    static let car: Int = 1 << 0
    static let track: Int = 1 << 1
}

struct CarInput {
    /// −1 (left) ... 1 (right).
    var steer: Float = 0
    /// 0 ... 1. Held at a standstill it selects reverse.
    var brake: Float = 0
    var throttle: Float = 1
    var handbrake = false
}

/// Wheel suspension can absorb a landing before the chassis ever hits the deck.
private struct LandingDetector {
    private var airborne = false
    private var previousDescent: Float = 0

    mutating func update(height: Float, normalSpeed: Float) -> Float {
        let descent = max(0, -normalSpeed)
        defer { previousDescent = descent }
        if height > CarMesh.axleHeight + 0.5 { airborne = true }
        guard airborne, height <= CarMesh.axleHeight + 0.12 else { return 0 }
        airborne = false
        let impact = max(previousDescent, descent)
        return impact >= 4 ? impact : 0
    }
}

/// One racer, player or rival: a SceneKit physics vehicle (rigid chassis, four sprung,
/// driven wheels) built from a `CarDesign`. Power, grip and downforce are tuned for
/// speed, not realism. Alongside the physics it keeps track of where the car is in the
/// circuit's own frame (distance round the lap, offset from the centre line), which is
/// what the race, the rival driver and the assist work from.
final class Car {
    let design: CarDesign
    let node: SCNNode
    private let model: CarModel
    private var vehicle: SCNPhysicsVehicle?
    private weak var world: SCNPhysicsWorld?
    private var isDemo = false

    static let mass: CGFloat = 1_900
    private static let suspensionTravel: Float = 0.20
    private static let chassisCenterHeight: Float = 0.5
    private static let chassisHalfHeight: Float = 0.3
    /// Full pedal deceleration on level ground, in m/s².
    private let brakeDeceleration: CGFloat = 11
    /// Aerodynamic grip in N per (m/s)², pressing the car into the road.
    private let downforce: Float = 3.2
    static let boostTime: Float = 2.2

    // --- Where the car is on the circuit (refreshed every frame from the physics) ---
    /// Distance round the lap in metres, wrapped.
    private(set) var s: Float = 0
    /// Total distance since the start line; negative on the grid.
    private(set) var progress: Float = 0
    /// Lateral offset from the centre line in metres, positive to the right.
    private(set) var d: Float = 0
    private(set) var speed: Float = 0
    /// Nose angle relative to the road, positive pointing right.
    private(set) var heading: Float = 0
    /// World yaw of the nose.
    private(set) var yaw: Float = 0
    /// Speed across the road in m/s, positive to the right.
    private(set) var lateralSpeed: Float = 0
    /// Rate of turn in rad/s, positive turning left.
    private(set) var yawRate: Float = 0
    private(set) var worldPosition = SIMD3<Float>.zero
    /// Direction the car is moving in (its nose when nearly stopped), for the camera.
    private(set) var worldForward = SIMD3<Float>(0, 0, -1)
    /// 1 when the car sits flat on the road, negative when it is on its roof.
    private(set) var upright: Float = 1

    /// Seconds of boost left.
    private(set) var boost: Float = 0
    private(set) var scraping = false
    /// Strongest barrier hit (m/s into the wall) since last read.
    var pendingHit: Float = 0
    private(set) var landingSpeed: Float = 0
    var pendingBoost = false

    // --- Race bookkeeping (owned by GameScene) ---
    var finishTime: Float?
    var lapStart: Float = 0
    var bestLap: Float?
    var lastLap: Float?

    // --- Rival driver ---
    /// Preferred lateral offset, and a pace factor on top speed.
    var lane: Float = 0
    var pace: Float = 1
    /// How much of the car's cornering grip the rival driver dares to use, 0...1.
    var skill: Float = 1
    var avoid: Float = 0

    private var sampleIndex = 0
    private var reversing = false
    private var rearSlip: Float = 0
    private(set) var lockedWheelSkid: Float = 0
    private var smoothSteer: Float = 0
    private var exhaust: Float = 0
    private var stuckTime: Float = 0
    private var flippedTime: Float = 0
    private var wrongWayTime: Float = 0
    private var stallTime: Float = 0
    private var stallMark: Float = 0
    private var wallImpactSeverity: Float = 0
    private var landing = LandingDetector()

    private var collisionHalfWidth: Float { design.halfWidth + 0.15 }

    init(design: CarDesign) {
        self.design = design
        model = CarMesh.build(design)
        node = model.node
    }

    private static let headlightColor = UIColor(red: 0.84, green: 0.93, blue: 1, alpha: 1)

    /// The steeper rays are dimmer to balance how quickly light falls off along the deck.
    private static let headlightPattern = ProceduralTextures.image(width: 128, height: 128) { u, v in
        let spread = 1 - smoothstep(0.14, 0.29, abs(u - 0.5))
        let elevation = abs(v - 0.5)
        let cutoff = 1 - smoothstep(0.31, 0.49, elevation)
        let transmission = cutoff / (1 + pow(elevation / 0.026, 2.55))
        // Encode the transmission in the image's sRGB colour space.
        return SIMD3(repeating: pow(spread * transmission, 1 / 2.2))
    }

    private static let headlightLens: SCNMaterial = {
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = UIColor.black
        material.emission.contents = headlightColor
        material.emission.intensity = 2
        return material
    }()

    func installHeadlights() {
        guard !model.headlightMounts.isEmpty else { return }
        var beamOrigin = SIMD3<Float>.zero
        for mount in model.headlightMounts {
            let lens = SCNBox(width: CGFloat(mount.size.x * 0.88), height: CGFloat(mount.size.y * 0.76),
                              length: 0.015, chamferRadius: 0.006)
            lens.firstMaterial = Self.headlightLens
            let fixture = SCNNode(geometry: lens)
            fixture.simdPosition = mount.centre - SIMD3(0, 0, mount.size.z / 2 + 0.009)
            fixture.castsShadow = false
            node.addChildNode(fixture)
            beamOrigin += fixture.simdPosition
        }

        // Both lenses share one beam so their light blends from the nose onward.
        let light = SCNLight()
        light.type = .spot
        light.color = Self.headlightColor
        light.intensity = 13200
        light.spotInnerAngle = 66
        light.spotOuterAngle = 86
        light.attenuationStartDistance = 3
        light.attenuationEndDistance = 95
        light.attenuationFalloffExponent = 0.85
        light.categoryBitMask = TrackMeshBuilder.headlightReceiverMask
        light.gobo?.contents = Self.headlightPattern
        let projector = SCNNode()
        projector.light = light
        projector.simdPosition = beamOrigin / Float(model.headlightMounts.count)
        node.addChildNode(projector)
    }

    // MARK: - Physics set-up

    func install(in world: SCNPhysicsWorld) {
        self.world = world
        // A box over the whole car, a little wider than the tyres so they stay off the barriers,
        // and clear of the road so only the wheels touch it.
        let box = SCNBox(width: CGFloat(collisionHalfWidth * 2), height: CGFloat(2 * Self.chassisHalfHeight),
                         length: CGFloat(design.frontCollisionExtent + design.rearCollisionExtent),
                         chamferRadius: 0.12)
        let midpoint = (design.rearCollisionExtent - design.frontCollisionExtent) / 2
        let shape = SCNPhysicsShape(shapes: [SCNPhysicsShape(geometry: box, options: nil)],
                                    transforms: [NSValue(scnMatrix4: SCNMatrix4MakeTranslation(0, Self.chassisCenterHeight, midpoint))])
        let body = SCNPhysicsBody(type: .dynamic, shape: shape)
        body.mass = Self.mass
        body.centerOfMassOffset = SCNVector3(0, -0.35, 0)
        body.categoryBitMask = PhysicsCategory.car
        body.collisionBitMask = PhysicsCategory.track | PhysicsCategory.car
        // Armour is slippery bodywork: it glances off a barrier instead of grinding along it.
        body.friction = CGFloat(0.35 - 0.27 * design.spec.armor)
        body.restitution = 0
        body.damping = 0.02
        body.angularDamping = 0.7
        body.continuousCollisionDetectionThreshold = 0.4
        node.physicsBody = body

        let wheels = zip(model.wheels, model.radii).map { wheelNode, radius -> SCNPhysicsVehicleWheel in
            let wheel = SCNPhysicsVehicleWheel(node: wheelNode)
            wheel.connectionPosition = SCNVector3(wheelNode.position.x, wheelNode.position.y + 0.28, wheelNode.position.z)
            wheel.axle = SCNVector3(-1, 0, 0)
            wheel.steeringAxis = SCNVector3(0, -1, 0)
            wheel.radius = CGFloat(radius)
            wheel.suspensionRestLength = 0.28
            wheel.maximumSuspensionTravel = CGFloat(Self.suspensionTravel * 100) // centimetres
            wheel.suspensionStiffness = 55
            wheel.suspensionCompression = 6.5
            wheel.suspensionDamping = 8
            wheel.maximumSuspensionForce = 40_000
            wheel.frictionSlip = CGFloat(design.spec.grip)
            return wheel
        }
        let vehicle = SCNPhysicsVehicle(chassisBody: body, wheels: wheels)
        self.vehicle = vehicle
        world.addBehavior(vehicle)
    }

    /// Demo mode takes the car off the physics so it can be moved along the lap directly.
    func setDemo(_ enabled: Bool) {
        guard isDemo != enabled, let vehicle = vehicle, let body = node.physicsBody, let world = world else { return }
        isDemo = enabled
        if enabled {
            world.removeBehavior(vehicle)
            body.type = .kinematic
        } else {
            body.type = .dynamic
            body.resetTransform()
            world.addBehavior(vehicle)
        }
    }

    // MARK: - Online

    /// A remote car stays hidden and non-colliding until a network pose is available.
    func setRemote() {
        setDemo(true)
        node.isHidden = true
        setRemoteCollision(false)
    }

    private func setRemoteCollision(_ enabled: Bool) {
        let category = enabled ? PhysicsCategory.car : 0
        let mask = enabled ? PhysicsCategory.track | PhysicsCategory.car : 0
        if let body = node.physicsBody, body.categoryBitMask != category || body.collisionBitMask != mask {
            body.categoryBitMask = category
            body.collisionBitMask = mask
        }
    }

    func applyRemote(_ sample: RemoteCarSample, track: TrackPath, dt: Float) {
        let state = sample.state
        progress = state.progress
        s = Self.wrap(state.progress, track.totalLength)
        worldPosition = state.position
        if let floor = groundCorrection(at: worldPosition, orientation: state.orientation, track: track) {
            worldPosition.y += floor.lift
        }
        node.simdPosition = worldPosition
        node.simdOrientation = state.orientation
        setRemoteCollision(sample.allowsCollision)
        if node.isHidden { node.isHidden = false }
        speed = simd_length(state.velocity)
        let forward = state.orientation.act(SIMD3<Float>(0, 0, -1))
        worldForward = speed > 6 ? state.velocity / speed : forward
        yaw = atan2(forward.x, -forward.z)
        boost = state.boosting ? Self.boostTime : 0
        // No physics turns the wheels, so roll them by hand.
        let roll = simd_dot(state.velocity, forward) * dt
        for (wheel, radius) in zip(model.wheels, model.radii) { wheel.simdEulerAngles.x -= roll / radius }
        let exhaustTarget = min(1, speed / design.spec.topSpeed) + (state.boosting ? 0.6 : 0)
        exhaust += (exhaustTarget - exhaust) * min(1, 2.5 * dt)
        CarMesh.setThrust(exhaust, on: node)
    }

    /// This car's pose for the other players.
    var netState: NetCarState {
        let v = node.physicsBody?.velocity ?? SCNVector3Zero
        return NetCarState(position: worldPosition, orientation: node.presentation.simdWorldOrientation,
                           velocity: SIMD3(Float(v.x), Float(v.y), Float(v.z)), progress: progress,
                           steer: smoothSteer, boosting: boost > 0)
    }

    // MARK: - Placement

    /// Puts the car on the grid: at rest, facing down the road, race state cleared.
    func place(progress: Float, lateral: Float, on track: TrackPath) {
        self.progress = progress
        boost = 0
        pendingBoost = false
        finishTime = nil; lapStart = 0; bestLap = nil; lastLap = nil; avoid = 0
        teleport(to: Self.wrap(progress, track.totalLength), lateral: lateral, track: track)
    }

    /// Sets the car down on the road at a point of the lap, stationary.
    private func teleport(to distance: Float, lateral: Float, track: TrackPath) {
        s = distance
        d = lateral
        sampleIndex = Int(distance / track.step) % track.stepCount
        let frame = track.frame(at: distance)
        speed = 0; heading = 0; lateralSpeed = 0
        reversing = false; scraping = false; smoothSteer = 0; yawRate = 0
        rearSlip = 0
        lockedWheelSkid = 0
        for wheel in vehicle?.wheels.dropFirst(2) ?? [] { wheel.frictionSlip = CGFloat(design.spec.grip) }
        wallImpactSeverity = 0
        landing = LandingDetector()
        landingSpeed = 0
        pendingHit = 0
        stuckTime = 0; flippedTime = 0; wrongWayTime = 0; stallTime = 0; stallMark = progress
        setPose(frame, lateral: lateral, lift: 0.6)
        node.physicsBody?.velocity = SCNVector3Zero
        node.physicsBody?.angularVelocity = SCNVector4Zero
        node.physicsBody?.resetTransform()
    }

    private func setPose(_ frame: PathSample, lateral: Float, lift: Float) {
        worldPosition = frame.position + frame.right * lateral + frame.up * lift
        worldForward = frame.forward
        yaw = atan2(frame.forward.x, -frame.forward.z)
        node.simdPosition = worldPosition
        node.simdOrientation = simd_quatf(simd_float3x3(columns: (frame.right, frame.up, -frame.forward)))
    }

    /// Demo: glides along the centre line at `speed`, off the physics.
    func glide(to distance: Float, speed: Float, track: TrackPath) {
        s = Self.wrap(distance, track.totalLength)
        self.speed = speed
        setPose(track.frame(at: s), lateral: 0, lift: CarMesh.axleHeight - 0.1)
        for wheel in model.wheels { wheel.simdEulerAngles.x -= speed / 0.45 / 60 }
        CarMesh.setThrust(speed / design.spec.topSpeed, on: node)
    }

    private static func wrap(_ x: Float, _ length: Float) -> Float {
        let r = x.truncatingRemainder(dividingBy: length)
        return r < 0 ? r + length : r
    }

    func giveBoost() {
        if boost < Self.boostTime * 0.5 { pendingBoost = true }
        boost = Self.boostTime
    }

    // MARK: - Per frame

    private func groundCorrection(at position: SIMD3<Float>, orientation: simd_quatf,
                                  track: TrackPath) -> (lift: Float, normal: SIMD3<Float>)? {
        guard let ground = track.ground(at: position, near: s) else { return nil }
        // Allow full spring compression. If the car tips, also support the lowest
        // corner of its oriented chassis so the nose, flank or roof cannot sink in.
        let up = orientation.inverse.act(ground.normal)
        let boxClearance = abs(up.x) * collisionHalfWidth
            + max(up.z * design.frontCollisionExtent, -up.z * design.rearCollisionExtent)
            + abs(up.y) * Self.chassisHalfHeight - up.y * Self.chassisCenterHeight
        let minimum = max(CarMesh.axleHeight - Self.suspensionTravel, boxClearance)
        guard ground.clearance < minimum else { return nil }
        return ((minimum - ground.clearance) / ground.normal.y, ground.normal)
    }

    /// Enforce the road surface after SceneKit advances the wheels and chassis, before rendering.
    func enforceGround(on track: TrackPath) -> Float {
        guard let body = node.physicsBody, body.type == .dynamic else { return 0 }
        let pose = node.presentation
        guard let floor = groundCorrection(at: pose.simdWorldPosition, orientation: pose.simdWorldOrientation,
                                           track: track) else { return 0 }
        var transform = pose.simdWorldTransform
        transform.columns.3.y += floor.lift
        let v = body.velocity
        let velocity = SIMD3(v.x, v.y, v.z)
        let sliding = velocity - floor.normal * min(0, simd_dot(velocity, floor.normal))
        let spin = body.angularVelocity
        node.simdWorldTransform = transform
        body.resetTransform()
        body.velocity = SCNVector3(sliding.x, sliding.y, sliding.z)
        body.angularVelocity = spin
        return floor.lift
    }

    /// Reads the simulated pose, then sets wheel forces for the next physics step.
    /// `hold` keeps the car on its brakes (the grid). `wallGuard` (0...1) is the pilot
    /// assist: see `guardSteer`.
    func step(dt: Float, input: CarInput, track: TrackPath, hold: Bool = false, wallGuard: Float = 0) {
        guard let vehicle, let world, let body = node.physicsBody else { return }
        let previousLateralSpeed = lateralSpeed
        let frame = sense(track: track, body: body)
        boost = max(0, boost - dt)
        wallImpactSeverity = max(0, wallImpactSeverity - dt * 3)

        let wallSide: Float = d > 0 ? 1 : -1
        let wallGap = wallLimit(frame, side: wallSide) - abs(d)
        let impactSpeed = max(previousLateralSpeed * wallSide, lateralSpeed * wallSide)
        let glancing = abs(sin(heading)) < 0.22 && impactSpeed < 8 && wallImpactSeverity < 0.15
        // A small release margin keeps contact stable across joins in the barrier mesh.
        let contactGap: Float = glancing ? 0.26 : 0.08
        let touching = wallGap <= contactGap + (scraping ? 0.10 : 0)
        if !hold, touching, !scraping, impactSpeed > 2 { pendingHit = max(pendingHit, impactSpeed) }
        scraping = touching

        if !hold, recoverIfNeeded(dt: dt, input: input, frame: frame, track: track) { return }

        let height = simd_dot(worldPosition - frame.position, frame.up)
        let v = body.velocity
        if !hold, abs(d) < frame.halfWidth + TrackMeshBuilder.barrierOffset {
            landingSpeed = landing.update(height: height, normalSpeed: simd_dot(SIMD3(v.x, v.y, v.z), frame.up))
        } else {
            landing = LandingDetector()
            landingSpeed = 0
        }

        let spec = design.spec
        let boosting = boost > 0
        let top = spec.topSpeed * pace * (boosting ? 1.22 : 1)

        let handbrake = input.handbrake && !hold
        let wantsReverse = input.brake > 0.9 && !hold && !handbrake
        if speed < 0.5 { reversing = wantsReverse }
        // Thrust fades towards top speed; reverse is deliberately weak.
        let fade = CGFloat(max(0, 1 - pow(speed / top, 2)))
        var drive: CGFloat
        var braking: CGFloat
        if hold {
            drive = 0
            braking = 1
        } else if reversing && !handbrake {
            drive = wantsReverse ? CGFloat(input.brake) * 0.25 : 0
            braking = wantsReverse ? 0 : 1
        } else {
            drive = input.brake > 0 || handbrake ? 0 : -CGFloat(input.throttle) * fade * (boosting ? 1.9 : 1)
            braking = CGFloat(input.brake)
        }

        // The rear tyres break loose under the lever and take a moment to regain grip.
        let slipTarget = handbrake ? smoothstep(1, 6, speed) : 0
        let previousSlip = rearSlip
        rearSlip += min(8 * dt, max(-2.5 * dt, slipTarget - rearSlip))
        if rearSlip != previousSlip {
            // Longer wheelbases resist rotation and need less rear grip to start a slide.
            let lockedGrip = mix(0.40, 0.275, smoothstep(1, 1.8, design.axle))
            let grip = CGFloat(mix(spec.grip, lockedGrip, rearSlip))
            for wheel in vehicle.wheels.dropFirst(2) { wheel.frictionSlip = grip }
        }
        lockedWheelSkid = handbrake && height < CarMesh.axleHeight + 0.35 && upright > 0.5
            ? rearSlip * smoothstep(1, 14, speed) : 0

        // Steering lock shrinks with speed so the car stays controllable flat out.
        var steer = max(-1, min(1, input.steer))
        if wallGuard > 0 { steer = max(-1, min(1, steer + guardSteer(frame: frame) * wallGuard)) }
        // The wheel also takes a moment to follow the thumb, which keeps the car from twitching.
        smoothSteer += max(-5 * dt, min(5 * dt, steer - smoothSteer))
        let speedFactor = max(0.08, 1 / (1 + speed / 12))
        let steering = CGFloat(-smoothSteer * spec.steeringLock * speedFactor)

        let transform = node.presentation.simdWorldTransform
        let up = SIMD3<Float>(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z)
        let push = -up * (downforce * speed * speed)
        body.applyForce(SCNVector3(push.x, push.y, push.z), asImpulse: false)
        // Righting moment: proportional to the tilt away from the road normal.
        let tilt = simd_cross(up, frame.up)
        let amount = simd_length(tilt)
        if amount > 1e-4 {
            let axis = tilt / amount
            let rightingTorque: Float = scraping ? 105_000 : 42_000
            body.applyTorque(SCNVector4(axis.x, axis.y, axis.z, amount * rightingTorque), asImpulse: false)
        }
        stabilise(body: body, up: up, transform: transform, steering: Float(steering))
        // Barriers deflect: while the bodywork is on a wall with the nose pointing into it,
        // the wall turns the car back along the road instead of stopping it dead.
        if scraping, !hold {
            let into = max(0, min(0.7, heading * wallSide))
            if into > 0.01 {
                let axis = up * wallSide
                body.applyTorque(SCNVector4(axis.x, axis.y, axis.z, into * 60_000), asImpulse: false)
            }
            let originalVelocity = SIMD3(Float(v.x), Float(v.y), Float(v.z))
            var velocity = originalVelocity
            if glancing {
                // Take out the motion into the barrier before the chassis catches on a triangle edge.
                let outwardLimit = max(-0.9, (wallGap - 0.18) * 8)
                let outward = simd_dot(velocity, frame.right) * wallSide
                velocity -= frame.right * (max(0, outward - outwardLimit) * wallSide)
            }
            // Keep the small suspension bounce, but stop a wheel riding up the wall.
            let lift = simd_dot(velocity, frame.up)
            let liftLimit = max(0, (0.9 - height) * 6)
            if lift > liftLimit {
                velocity -= frame.up * (lift - liftLimit)
            }
            if velocity != originalVelocity { body.velocity = SCNVector3(velocity.x, velocity.y, velocity.z) }
            // Even a parallel scrape must overcome full throttle at racing speed.
            // Armour softens the drag, and its speed dependence lets a slow car pull away.
            wallImpactSeverity = max(wallImpactSeverity, smoothstep(3.5, 19, impactSpeed))
            let drag = Float(Self.mass) * mix(0.8, 1.4, wallImpactSeverity) * (1 - 0.2 * spec.armor)
            let alongWall = simd_dot(velocity, frame.forward)
            let friction = -frame.forward * (alongWall * drag)
            body.applyForce(SCNVector3(friction.x, friction.y, friction.z), asImpulse: false)
        }

        let engineForce = Self.mass * CGFloat(spec.thrust)
        // The vehicle solver caps each wheel's braking impulse per physics tick.
        let brakeImpulse = Self.mass * brakeDeceleration * CGFloat(world.timeStep)
        for index in 0..<4 {
            let front = index < 2
            let serviceBrake = braking * (front ? 0.3 : 0.2)
            let rearBrake: CGFloat = handbrake && !front ? 0.35 : 0
            vehicle.setSteeringAngle(front ? steering : 0, forWheelAt: index)
            vehicle.applyEngineForce(engineForce * drive / 4, forWheelAt: index)
            vehicle.applyBrakingForce(brakeImpulse * max(serviceBrake, rearBrake), forWheelAt: index)
        }
        // Exhaust grows with speed, not with the throttle, so it swells and dies away gradually.
        let exhaustTarget = min(1, speed / spec.topSpeed) + (boosting ? 0.6 : 0)
        exhaust += (exhaustTarget - exhaust) * min(1, 2.5 * dt)
        CarMesh.setThrust(exhaust, on: node)
        CarMesh.setBrake(handbrake ? 1 : Float(braking), on: node)
    }

    /// Chassis stability, part of how the car handles rather than an assist: damps pitch
    /// and roll so it cannot tip over, trims yaw beyond what the steering asks for so it
    /// does not spin, and bleeds off sideways slide.
    private func stabilise(body: SCNPhysicsBody, up: SIMD3<Float>, transform: simd_float4x4, steering: Float) {
        guard upright > 0.5 else { return }
        let av = body.angularVelocity
        let omega = SIMD3<Float>(Float(av.x), Float(av.y), Float(av.z)) * Float(av.w)
        let yawRate = simd_dot(omega, up)
        let tumble = omega - up * yawRate
        let tumbleRate = simd_length(tumble)
        if tumbleRate > 1e-3 {
            let axis = -tumble / tumbleRate
            body.applyTorque(SCNVector4(axis.x, axis.y, axis.z, tumbleRate * 9_000), asImpulse: false)
        }
        // Expected yaw rate for this steering angle on this wheelbase, plus a little slack.
        let expected = speed * abs(tan(steering)) / (design.axle * 2)
        let excess = abs(yawRate) - expected - 0.15
        if excess > 0 {
            let axis = up * (yawRate > 0 ? -1 : 1)
            body.applyTorque(SCNVector4(axis.x, axis.y, axis.z, excess * 7_000 * (1 - 0.8 * rearSlip)), asImpulse: false)
        }
        guard speed > 3 else { return }
        let right = SIMD3<Float>(transform.columns.0.x, transform.columns.0.y, transform.columns.0.z)
        let v = body.velocity
        let sideways = simd_dot(SIMD3<Float>(Float(v.x), Float(v.y), Float(v.z)), right)
        let grip = -right * sideways * Float(Self.mass) * (1.6 - 1.4 * rearSlip)
        body.applyForce(SCNVector3(grip.x, grip.y, grip.z), asImpulse: false)
    }

    /// The optional pilot assist. It never steers along the road: it only looks at how
    /// fast the car is closing on a barrier and, in the last half second before contact,
    /// adds at most a third of a lock away from it. Enough to turn a crash into a graze,
    /// not enough to take a corner.
    private func guardSteer(frame: PathSample) -> Float {
        guard abs(lateralSpeed) > 1.5, abs(heading) < 1.2 else { return 0 }
        let side: Float = lateralSpeed > 0 ? 1 : -1
        let room = max(0, wallLimit(frame, side: side) - d * side)
        let timeToWall = room / abs(lateralSpeed)
        let window: Float = 0.55
        guard timeToWall < window else { return 0 }
        return -side * (1 - timeToWall / window) * 0.34
    }

    /// Offset from the centre line at which the bodywork meets the barrier.
    private func wallLimit(_ frame: PathSample, side: Float) -> Float {
        let towardWall = sin(heading) * side
        let overhang = towardWall >= 0 ? design.frontCollisionExtent : design.rearCollisionExtent
        let reach = collisionHalfWidth * abs(cos(heading)) + overhang * abs(towardWall)
        return frame.halfWidth + TrackMeshBuilder.barrierOffset - reach - 0.05
    }

    /// Reads the pose SceneKit simulated and works out where that is on the circuit.
    private func sense(track: TrackPath, body: SCNPhysicsBody) -> PathSample {
        let transform = node.presentation.simdWorldTransform
        worldPosition = SIMD3(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
        let forward = -SIMD3<Float>(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z)
        let up = SIMD3<Float>(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z)
        let v = body.velocity
        let velocity = SIMD3<Float>(Float(v.x), Float(v.y), Float(v.z))
        speed = simd_length(velocity)
        yaw = atan2(forward.x, -forward.z)
        let spin = body.angularVelocity
        yawRate = simd_dot(SIMD3<Float>(Float(spin.x), Float(spin.y), Float(spin.z)) * Float(spin.w), up)
        worldForward = speed > 6 && simd_dot(velocity, forward) > 0 ? velocity / speed : forward

        // Nearest sample, searched around the last one so a nearby stretch of road is never mistaken for this one.
        var best = sampleIndex, bestDistance = Float.greatestFiniteMagnitude
        for offset in -24...64 {
            let i = ((sampleIndex + offset) % track.stepCount + track.stepCount) % track.stepCount
            let p = track.samples[i].position
            let distance = simd_length_squared(SIMD2(worldPosition.x - p.x, worldPosition.z - p.z))
            if distance < bestDistance { bestDistance = distance; best = i }
        }
        sampleIndex = best
        let nearest = track.samples[best]
        let along = simd_dot(worldPosition - nearest.position, nearest.forward)
        let distance = Self.wrap(Float(best) * track.step + along, track.totalLength)
        var delta = distance - s
        if delta > track.totalLength / 2 { delta -= track.totalLength }
        if delta < -track.totalLength / 2 { delta += track.totalLength }
        progress += delta
        s = distance

        let frame = track.frame(at: s)
        d = simd_dot(worldPosition - frame.position, frame.right)
        heading = atan2(simd_dot(forward, frame.right), simd_dot(forward, frame.forward))
        upright = simd_dot(up, frame.up)

        lateralSpeed = simd_dot(velocity, frame.right)
        return frame
    }

    /// Puts the car back on the road when it has fallen off, rolled over, wedged itself
    /// against something or ended up pointing the wrong way. Returns true if it did.
    private func recoverIfNeeded(dt: Float, input: CarInput, frame: PathSample, track: TrackPath) -> Bool {
        flippedTime = upright < 0.3 ? flippedTime + dt : 0
        let tryingToDrive = input.throttle > 0.5 && input.brake < 0.05 && !input.handbrake
        stuckTime = speed < 1.5 && tryingToDrive ? stuckTime + dt : 0
        wrongWayTime = abs(heading) > 2 ? wrongWayTime + dt : 0
        // Trying to drive but getting nowhere: nose against a barrier, creeping along it.
        var stalled = false
        if tryingToDrive {
            stallTime += dt
            if stallTime > 2.5 {
                stalled = progress - stallMark < 12
                stallTime = 0
                stallMark = progress
            }
        } else {
            stallTime = 0
            stallMark = progress
        }
        let fallen = simd_dot(worldPosition - frame.position, frame.up) < -0.5
        guard fallen || stalled || flippedTime > 1 || stuckTime > 1.5 || wrongWayTime > 2 else { return false }
        if fallen, RacePhysicsDiagnostics.enabled {
            let surface = track.ground(at: worldPosition, near: s)
            print("[race-physics] fallen pos=\(worldPosition) s=\(s) lateral=\(d) deck=\(surface != nil) velocity=\(node.physicsBody?.velocity ?? SCNVector3Zero)")
        }
        let room = frame.halfWidth - design.halfWidth - 1.5
        teleport(to: s, lateral: max(-room, min(room, d)), track: track)
        return true
    }
}

/// The rival driver. It drives the same physics car as the player through `CarInput`:
/// aims at a point ahead on its lane and brakes for corners it cannot take flat.
enum RivalDriver {
    /// The speed the tightest corner within braking distance can be taken at, for a
    /// cornering budget of `grip` m/s².
    static func cornerSpeed(for car: Car, track: TrackPath, grip: Float) -> Float {
        var tightest: Float = 0
        let reach = 30 + car.speed * 2.2
        var distance: Float = 0
        while distance < reach {
            tightest = max(tightest, abs(track.frame(at: car.s + distance).curvature))
            distance += 4
        }
        return (grip / max(tightest, 1e-4)).squareRoot()
    }

    static func input(for car: Car, track: TrackPath) -> CarInput {
        let spec = car.design.spec
        let look = 14 + car.speed * 0.45
        let ahead = track.frame(at: car.s + look)
        let limit = ahead.halfWidth - car.design.halfWidth - 2.2
        // Drift towards the inside of whatever is coming.
        let apex = track.frame(at: car.s + look * 2).curvature
        let targetD = max(-limit, min(limit, car.lane + car.avoid + max(-2.5, min(2.5, apex * 300))))
        let to = ahead.position + ahead.right * targetD - car.worldPosition
        let bearing = atan2(to.x, -to.z)
        let steer = max(-1, min(1, remainder(bearing - car.yaw, 2 * .pi) * 3))

        let target = min(spec.topSpeed * car.pace * 1.3,
                         cornerSpeed(for: car, track: track, grip: (72 + 16 * spec.ratings[2]) * car.skill))
        return CarInput(steer: steer, brake: car.speed > target + 4 ? 0.8 : 0, throttle: car.speed < target ? 1 : 0)
    }
}

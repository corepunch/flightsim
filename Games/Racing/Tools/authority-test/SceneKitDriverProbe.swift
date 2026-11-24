// Native feasibility check only: a virtual-time SceneKit renderer with a real
// SCNPhysicsVehicle and the portable authority boundary, no visible SCNView.
import Foundation
import Metal
import SceneKit
import simd

private final class Probe: NSObject, SCNSceneRendererDelegate {
    var authority = ArcAuthority()
    var frames = [ArcControlFrame](repeating: ArcControlFrame(), count: Int(ARC_AUTHORITY_MAX_CARS))
    var snapshot = ArcRaceSnapshot()
    var before = 0
    var after = 0
    var previous: SIMD3<Float>?
    let car: SCNNode
    let vehicle: SCNPhysicsVehicle

    init(car: SCNNode, vehicle: SCNPhysicsVehicle) {
        self.car = car
        self.vehicle = vehicle
        super.init()
        var seat = ArcRaceSeat(car_id: 1, peer_id: 1, is_bot: false)
        precondition(arc_authority_start(&authority, 1, 100, 1, &seat, 1))
    }

    func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        before += 1
        var packet = [UInt8](repeating: 0, count: Int(ARC_AUTHORITY_INPUT_BYTES))
        let throttle: Float = before > 60 ? 1 : 0
        let input = ArcControls(steer: 0, throttle: throttle, brake: 0, handbrake: false)
        precondition(arc_authority_encode_input(&packet, 1, UInt32(before), input))
        precondition(arc_authority_receive(&authority, 1, packet, packet.count))
        precondition(arc_authority_begin_tick(&authority, &frames))
        for wheel in 0..<4 {
            vehicle.applyEngineForce(CGFloat(frames[0].controls.throttle) * 800, forWheelAt: wheel)
        }
    }

    func renderer(_ renderer: SCNSceneRenderer, didSimulatePhysicsAtTime time: TimeInterval) {
        after += 1
        let node = car.presentation
        let p = node.simdWorldPosition
        let q = node.simdWorldOrientation.vector
        if after == 60 { previous = p }
        var pose = ArcHostPose()
        pose.car_id = 1
        pose.position = (p.x, p.y, p.z)
        pose.orientation = (q.x, q.y, q.z, q.w)
        pose.progress = -p.z
        precondition(arc_authority_end_tick(&authority, &pose, 1, &snapshot))
    }
}

@main
private enum Main {
    static func main() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("SceneKit driver probe needs an Apple Metal device")
        }
        let renderer = SCNRenderer(device: device, options: nil)
        let scene = SCNScene()
        scene.physicsWorld.timeStep = 1.0 / Double(ARC_AUTHORITY_HZ)
        SCNTransaction.begin()
        let ground = SCNNode(geometry: SCNBox(width: 80, height: 1, length: 100, chamferRadius: 0))
        ground.simdPosition = SIMD3(0, -0.5, 0)
        ground.physicsBody = SCNPhysicsBody(type: .static, shape: nil)
        scene.rootNode.addChildNode(ground)
        let car = SCNNode(geometry: SCNBox(width: 1.6, height: 0.4, length: 3, chamferRadius: 0))
        car.simdPosition = SIMD3(0, 0.85, 0)
        let body = SCNPhysicsBody(type: .dynamic, shape: nil)
        body.mass = 900
        car.physicsBody = body
        scene.rootNode.addChildNode(car)
        let wheels = [(Float(-0.85), Float(-1)), (0.85, -1), (-0.85, 1), (0.85, 1)].map { x, z in
            let n = SCNNode()
            n.simdPosition = SIMD3(x, -0.15, z)
            car.addChildNode(n)
            let w = SCNPhysicsVehicleWheel(node: n)
            w.radius = 0.35
            w.suspensionRestLength = 0.35
            return w
        }
        let vehicle = SCNPhysicsVehicle(chassisBody: body, wheels: wheels)
        scene.physicsWorld.addBehavior(vehicle)
        renderer.scene = scene
        SCNTransaction.commit()
        SCNTransaction.flush()
        let probe = Probe(car: car, vehicle: vehicle)
        renderer.delegate = probe
        renderer.isPlaying = true
        for frame in 0..<180 {
            renderer.update(atTime: 1 + Double(frame) / Double(ARC_AUTHORITY_HZ))
        }
        precondition(probe.before == 180 && probe.after == 180, "missing/extra callbacks")
        precondition(probe.snapshot.tick == 180 && probe.snapshot.race_id == 1, "lost authority tick")
        let finish = car.presentation.simdWorldPosition
        guard let baseline = probe.previous else { fatalError("missing baseline") }
        let distance = simd_length(SIMD2(finish.x - baseline.x, finish.z - baseline.z))
        precondition(distance > 0.5 && finish.y > -0.5, "vehicle did not drive on the ground")
        print("SceneKit host driver feasibility passed: \(distance)m driven without SCNView")
    }
}

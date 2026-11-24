import UIKit
import SceneKit
import AVFoundation

/// Offline renderer: drives each track in demo mode and encodes an H.264 movie.
/// Launch with `-recordVideos <dir>` (optional `-recordSeconds 40 -recordTracks 0,2`).
enum TrackVideoRecorder {

    static func runFromLaunchArguments() -> Bool {
        let defaults = UserDefaults.standard
        guard let dir = defaults.string(forKey: "recordVideos") else { return false }
        let seconds = defaults.double(forKey: "recordSeconds") > 0 ? defaults.double(forKey: "recordSeconds") : 40
        let only = defaults.string(forKey: "recordTracks")?.split(separator: ",").compactMap { Int($0) }
        let stillsOnly = defaults.bool(forKey: "recordStillsOnly")
        Thread.detachNewThread {
            let out = URL(fileURLWithPath: dir, isDirectory: true)
            try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            for (i, def) in TrackLibrary.all.enumerated() where only?.contains(i) ?? true {
                autoreleasepool {
                    do {
                        try record(def, index: i, dir: out, seconds: stillsOnly ? 0 : seconds)
                    } catch {
                        print("[record] \(def.name) failed: \(error)")
                    }
                }
            }
            print("[record] done")
            DispatchQueue.main.async { exit(0) }
        }
        return true
    }

    private static func slug(_ name: String) -> String {
        name.lowercased().replacingOccurrences(of: " ", with: "-")
    }

    static func record(_ def: TrackDefinition, index: Int, dir: URL, seconds: Double,
                       size: CGSize = CGSize(width: 1280, height: 720), fps: Int32 = 30) throws {
        let start = Date()
        let game = GameScene(definition: def, audio: false)
        game.autoDrive = true
        print(String(format: "[record] %@ built in %.2fs (lap %.0f m)", def.name,
                     Date().timeIntervalSince(start), game.track.totalLength))

        let renderer = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
        renderer.scene = game.scene
        let base = "\(index + 1)-\(slug(def.name))"

        // Top-down overview for checking the layout.
        let overview = SCNNode()
        let cam = SCNCamera()
        cam.usesOrthographicProjection = true
        let extent = game.track.boundsMax - game.track.boundsMin
        cam.orthographicScale = Double(max(extent.x, extent.y) * 0.6)
        cam.zFar = 3000
        overview.camera = cam
        let mid = (game.track.boundsMax + game.track.boundsMin) / 2
        overview.simdPosition = SIMD3(mid.x, 1200, mid.y)
        overview.simdEulerAngles = SIMD3(-.pi / 2, 0, 0)
        game.scene.rootNode.addChildNode(overview)
        renderer.pointOfView = overview
        let fog = game.scene.fogEndDistance
        game.scene.fogEndDistance = 0
        let map = renderer.snapshot(atTime: 0, with: CGSize(width: 1200, height: 1200), antialiasingMode: .multisampling4X)
        game.scene.fogEndDistance = fog
        try map.pngData()?.write(to: dir.appendingPathComponent("\(base)-overview.png"))
        overview.removeFromParentNode()

        // Start/finish shot from just behind the grid.
        let startCam = SCNNode()
        startCam.camera = SCNCamera()
        startCam.camera?.fieldOfView = 70
        startCam.camera?.zFar = 900
        let behind = game.track.sample(at: -Int(32 / (game.track.totalLength / Float(game.track.stepCount))))
        startCam.simdPosition = behind.position + behind.right * 3 + SIMD3(0, 4.5, 0)
        startCam.simdLook(at: game.track.samples[0].position + SIMD3(0, 4, 0))
        game.scene.rootNode.addChildNode(startCam)
        renderer.pointOfView = startCam
        let startShot = renderer.snapshot(atTime: 0, with: size, antialiasingMode: .multisampling4X)
        try startShot.pngData()?.write(to: dir.appendingPathComponent("\(base)-start.png"))
        startCam.removeFromParentNode()

        renderer.pointOfView = game.cameraNode
        game.renderer(renderer, updateAtTime: 0)

        let frameCount = Int(seconds * Double(fps))
        let stillEvery = max(1, frameCount / 6)
        var writer: AVAssetWriter?
        var input: AVAssetWriterInput?
        var adaptor: AVAssetWriterInputPixelBufferAdaptor?
        if frameCount > 0 {
            let url = dir.appendingPathComponent("\(base).mp4")
            try? FileManager.default.removeItem(at: url)
            let w = try AVAssetWriter(outputURL: url, fileType: .mp4)
            let i = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: Int(size.width),
                AVVideoHeightKey: Int(size.height),
                AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 14_000_000],
            ])
            i.expectsMediaDataInRealTime = false
            let a = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: i, sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height),
            ])
            w.add(i)
            w.startWriting()
            w.startSession(atSourceTime: .zero)
            writer = w; input = i; adaptor = a
        }

        let stillTimes: [Double] = frameCount == 0 ? [2, 9, 16, 23, 30, 37] : []
        var t: Double = 0
        let renderStart = Date()
        if frameCount == 0 {
            // Stills only: simulate forward and grab frames at fixed times.
            var k = 0
            for target in stillTimes {
                while t < target {
                    t += 1.0 / Double(fps)
                    game.renderer(renderer, updateAtTime: t)
                }
                let image = renderer.snapshot(atTime: t, with: size, antialiasingMode: .multisampling4X)
                try image.pngData()?.write(to: dir.appendingPathComponent("\(base)-still\(k).png"))
                k += 1
            }
            return
        }

        for f in 0..<frameCount {
            t = Double(f + 1) / Double(fps)
            game.renderer(renderer, updateAtTime: t)
            let image = renderer.snapshot(atTime: t, with: size, antialiasingMode: .multisampling4X)
            if f % stillEvery == stillEvery / 2 {
                try image.pngData()?.write(to: dir.appendingPathComponent("\(base)-still\(f / stillEvery).png"))
            }
            guard let input, let adaptor, let pool = adaptor.pixelBufferPool, let cg = image.cgImage else { continue }
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.002) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let pb = buffer else { continue }
            CVPixelBufferLockBaseAddress(pb, [])
            let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb),
                                width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                    | CGBitmapInfo.byteOrder32Little.rawValue)
            ctx?.draw(cg, in: CGRect(origin: .zero, size: size))
            CVPixelBufferUnlockBaseAddress(pb, [])
            adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(f), timescale: fps))
            if f % 150 == 0 {
                print(String(format: "[record] %@ frame %d/%d (%.1f fps)", def.name, f, frameCount,
                             Double(f + 1) / Date().timeIntervalSince(renderStart)))
            }
        }

        input?.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer?.finishWriting { done.signal() }
        done.wait()
        if let error = writer?.error { throw error }
        print("[record] wrote \(base).mp4")
    }
}

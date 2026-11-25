import AVFoundation
import Darwin
import Foundation

private let frameRate: Int32 = 30

private struct TrailerError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

private enum Format: String {
    case iphone, ipad, mac, header, search, draft

    var size: (width: Int, height: Int) {
        switch self {
        case .iphone: (1920, 886)
        case .ipad: (1600, 1200)
        case .mac: (1920, 1080)
        case .header: (3840, 1646)
        case .search: (1920, 1280)
        case .draft: (960, 444)
        }
    }

    var bitRate: Int {
        switch self {
        case .header: 26_000_000
        case .draft: 4_000_000
        default: 11_000_000
        }
    }

    var profile: String {
        switch self {
        case .header, .search: AVVideoProfileLevelH264HighAutoLevel
        default: AVVideoProfileLevelH264High40
        }
    }
}

// Positions and orientations describe the shot at Scene.time. The game
// renderer advances the motion and renders its own ships, cockpit and effects.
private struct Scene: Encodable {
    var skySeed = 4
    var time: Double
    var cockpit = false
    var objective: String? = nil
    var objects: [Ship]
    var missiles: [Missile]? = nil
    var bolts: [Bolt]? = nil
    var explosions: [Explosion]? = nil
}

private struct Ship: Encodable {
    var model = "ship:executioner"
    var position: [Double]
    var velocity: [Double]? = nil
    var facing: [Double]? = nil
    var angularVelocity: [Double]? = nil
    var bank: Double? = nil
    var throttle: Double? = nil
    var boost: Bool? = nil
    var scale: Double? = nil
    var label: String? = nil
    var until: Double? = nil
}

private struct Missile: Encodable {
    var launch: [Double]
    var bend: [Double]? = nil
    var approach: [Double]
    var target: [Double]
    var start: Double
    var duration: Double
    var fromPlayer = false
}

private struct Bolt: Encodable {
    var from: [Double]
    var velocity: [Double]
    var start: Double
    var life: Double
    var friendly = false
}

private struct Explosion: Encodable {
    var model: String
    var position: [Double]
    var velocity: [Double]? = nil
    var time: Double
    var scale: Double
}

private struct Cue {
    let audio: String
    let time: Double
    let gain: Float

    init(_ audio: String, _ time: Double, _ gain: Float) {
        self.audio = audio
        self.time = time
        self.gain = gain
    }
}

private struct Shot {
    enum Source { case preset(String), staged(Scene) }

    let name: String
    let source: Source
    let firstFrame: Int
    let count: Int
    var cues: [Cue] = []
}

private func trailerShots() -> [Shot] {
    let formation = Scene(
        time: 2,
        objects: [
            Ship(position: [0, 0, 0], velocity: [-53, 2, -69], facing: [-0.62, 0.035, -0.78],
                 angularVelocity: [0.015, 0.035, 0.16], bank: -0.18, throttle: 0.87, boost: true),
            Ship(position: [-28, 8, -23], velocity: [-57, 2, -74], facing: [-0.62, 0.04, -0.78],
                 bank: -0.16, throttle: 0.9, boost: true),
            Ship(position: [8, 11, -25], velocity: [-52, 4, -83], facing: [-0.57, 0.06, -0.82],
                 bank: -0.36, throttle: 0.86, boost: true),
            Ship(model: "cap:Carrier:concord", position: [-123, -21, -126], velocity: [-32, 0, -37],
                 facing: [-0.86, 0, -0.49]),
        ]
    )
    let evasion = Scene(
        time: 2.5,
        objective: "{#mission.objective.corvette_hunt.kill}",
        objects: [
            Ship(position: [0, 0, 0], velocity: [-19, 9, -53], facing: [-0.29, 0.18, -1],
                 angularVelocity: [0.04, 0.08, 0.34], bank: 0.25, throttle: 0.91, boost: true),
            Ship(model: "ship:wasp", position: [21, 8, -48], velocity: [30, 9, 3], facing: [0.86, 0.29, 0.42],
                 angularVelocity: [0, 0, -0.27], bank: -0.6, throttle: 0.95),
            Ship(model: "cap:AsteroidB:rock", position: [-57, -1, -109], velocity: [0, 0, -32], scale: 0.3),
            Ship(model: "cap:AsteroidC:rock", position: [85, 37, -130], velocity: [0, 0, -32], scale: 0.32),
        ],
        missiles: [
            Missile(launch: [-53, 32, -132], bend: [-31, 20, -81], approach: [-7, 7, -21],
                    target: [36, 1, 56], start: 0.7, duration: 2.1),
            Missile(launch: [-30, -15, -83], bend: [-10, -5, -55], approach: [-3, 5, -32],
                    target: [-38, 6, -171], start: 1.65, duration: 2.65),
        ],
        bolts: [
            Bolt(from: [47, 21, -126], velocity: [-280, -65, 590], start: 1.1, life: 0.52),
            Bolt(from: [48, 25, -124], velocity: [-275, -68, 590], start: 1.28, life: 0.48),
            Bolt(from: [45, 28, -117], velocity: [-230, -80, 590], start: 1.46, life: 0.45),
        ]
    )
    let strike = Scene(
        time: 3, cockpit: true,
        objective: "{#mission.objective.corvette_hunt.kill}",
        objects: [
            Ship(position: [6, -6, -124], velocity: [0, 3, 32], facing: [0.03, 0.12, 1],
                 angularVelocity: [0.014, 0.02, -0.10], bank: -0.11, throttle: 0.88),
            Ship(model: "cap:Corvette:skarn", position: [5, 3, -70], velocity: [-1.4, 0, 2],
                 facing: [-0.92, 0.02, -0.38], angularVelocity: [0.06, 0.05, 0.01],
                 label: "Skarn Corvette Vesk", until: 3.2),
            Ship(position: [26, 13, -74], velocity: [-3, -2, 55], facing: [-0.06, -0.04, 1],
                 bank: 0.45, throttle: 0.98, boost: true),
            Ship(model: "cap:AsteroidB:rock", position: [-119, -27, 63], scale: 0.35),
            Ship(model: "cap:AsteroidC:rock", position: [76, 51, 37], scale: 0.29),
        ],
        missiles: [
            Missile(launch: [-1.6, -0.52, -6], approach: [-7, 3, -108],
                    target: [8, 6, -68], start: 1.08, duration: 1.78, fromPlayer: true),
            Missile(launch: [1.6, -0.52, -6], approach: [21, 12, -96],
                    target: [3, 8, -73], start: 1.42, duration: 1.78, fromPlayer: true),
        ],
        bolts: [
            Bolt(from: [8, 10, -74], velocity: [-62, -77, -620], start: 0.73, life: 0.48),
            Bolt(from: [9, 10, -75], velocity: [120, -66, -620], start: 0.94, life: 0.48),
        ],
        explosions: [
            Explosion(model: "cap:Corvette:skarn", position: [8, 6, -68], time: 2.86, scale: 1.13),
            Explosion(model: "cap:Corvette:skarn", position: [3, 8, -73], velocity: [-1.4, 0, 2],
                      time: 3.2, scale: 2.25),
        ]
    )
    let departure = Scene(
        time: 2,
        objects: [
            Ship(position: [0, 0, 0], velocity: [26, 13, -72], facing: [0.33, 0.17, -1],
                 angularVelocity: [-0.03, 0.05, 0.19], bank: 0.12, throttle: 0.85, boost: true),
            Ship(position: [11, 12, -32], velocity: [27, 16, -75], facing: [0.34, 0.22, -1],
                 bank: 0.57, throttle: 0.96, boost: true),
            Ship(position: [23, 25, -73], velocity: [34, 17, -81], facing: [0.4, 0.18, -1],
                 bank: 0.66, throttle: 0.9, boost: true),
            Ship(model: "cap:Carrier:concord", position: [110, -53, -225], velocity: [20, 6, -37],
                 facing: [0.88, 0.04, -0.5]),
        ]
    )
    return [
        Shot(name: "Formation flyby", source: .staged(formation), firstFrame: 12, count: 99,
             cues: [Cue("boost", 0, 0.32)]),
        Shot(name: "Cockpit intercept", source: .preset("cockpit-formation"), firstFrame: 35, count: 110,
             cues: [Cue("engine", 0, 0.13), Cue("secondary", 0.17, 0.36), Cue("laser", 0.73, 0.22),
                    Cue("impact", 2.58, 0.29)]),
        Shot(name: "Torpedo chase", source: .preset("torpedo-run"), firstFrame: 16, count: 93,
             cues: [Cue("secondary", 0, 0.43), Cue("explosion", 0.57, 0.51)]),
        Shot(name: "Missile evasion", source: .staged(evasion), firstFrame: 16, count: 116,
             cues: [Cue("laser", 0.57, 0.24), Cue("laser", 0.74, 0.24), Cue("laser", 0.91, 0.24),
                    Cue("secondary", 1.31, 0.35), Cue("boost", 1.66, 0.22)]),
        Shot(name: "Corvette strike", source: .staged(strike), firstFrame: 12, count: 141,
             cues: [Cue("laser", 0.33, 0.30), Cue("secondary", 0.68, 0.46), Cue("secondary", 1.02, 0.39),
                    Cue("impact", 2.46, 0.40), Cue("explosion", 2.8, 0.59)]),
        Shot(name: "Departure", source: .staged(departure), firstFrame: 12, count: 102,
             cues: [Cue("boost", 0, 0.18)]),
    ]
}

private func mediaTime(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 48_000) }

private func waitForInput(_ input: AVAssetWriterInput, writer: AVAssetWriter) throws {
    while !input.isReadyForMoreMediaData {
        guard writer.status == .writing else { throw writer.error ?? TrailerError("Encoder stopped writing") }
        Thread.sleep(forTimeInterval: 0.002)
    }
}

private func readExact(_ fd: Int32, into base: UnsafeMutableRawPointer, bytes: Int) throws {
    var offset = 0
    while offset < bytes {
        let received = Darwin.read(fd, base.advanced(by: offset), bytes - offset)
        if received == 0 { throw TrailerError("Renderer ended before the last complete frame") }
        if received < 0 {
            if errno == EINTR { continue }
            throw TrailerError("Reading a renderer frame failed (errno \(errno))")
        }
        offset += received
    }
}

private func appendShot(_ shot: Shot, definition: URL, app: URL, format: Format, startingAt: Int,
                        writer: AVAssetWriter, adaptor: AVAssetWriterInputPixelBufferAdaptor) throws {
    let (width, height) = format.size
    let pipe = Pipe()
    let process = Process()
    process.executableURL = app
    process.arguments = ["--render-frames", definition.path, String(width), String(height),
                         String(shot.firstFrame), String(shot.count)]
    process.standardOutput = pipe
    try process.run()
    pipe.fileHandleForWriting.closeFile()
    defer {
        pipe.fileHandleForReading.closeFile()
        if process.isRunning { process.terminate(); process.waitUntilExit() }
    }

    let fd = pipe.fileHandleForReading.fileDescriptor
    for frame in 0..<shot.count {
        try autoreleasepool {
            try waitForInput(adaptor.assetWriterInput, writer: writer)
            var pixelBuffer: CVPixelBuffer?
            guard let pool = adaptor.pixelBufferPool,
                  CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer) == kCVReturnSuccess,
                  let pixelBuffer else { throw TrailerError("Cannot allocate a video frame") }
            guard CVPixelBufferLockBaseAddress(pixelBuffer, []) == kCVReturnSuccess else {
                throw TrailerError("Cannot lock video frame")
            }
            do {
                defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
                guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else {
                    throw TrailerError("Video frame has no pixel storage")
                }
                let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
                let rowBytes = width * 4
                if stride == rowBytes {
                    try readExact(fd, into: base, bytes: rowBytes * height)
                } else {
                    for row in 0..<height {
                        try readExact(fd, into: base.advanced(by: row * stride), bytes: rowBytes)
                    }
                }
            }
            let time = CMTime(value: Int64(startingAt + frame), timescale: frameRate)
            guard adaptor.append(pixelBuffer, withPresentationTime: time) else {
                throw writer.error ?? TrailerError("Cannot encode video frame \(startingAt + frame)")
            }
        }
    }
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw TrailerError("Renderer failed in \(shot.name)") }
}

private func encodeVideo(shots: [Shot], app: URL, capture: URL, directory: URL, format: Format) async throws -> URL {
    let video = directory.appendingPathComponent("video.mp4")
    let writer = try AVAssetWriter(url: video, fileType: .mp4)
    let (width, height) = format.size
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
        AVVideoCompressionPropertiesKey: [
            AVVideoAverageBitRateKey: format.bitRate, AVVideoProfileLevelKey: format.profile,
            AVVideoExpectedSourceFrameRateKey: frameRate, AVVideoMaxKeyFrameIntervalKey: frameRate,
        ],
        AVVideoColorPropertiesKey: [
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
            AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
        ],
    ])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
    ])
    guard writer.canAdd(input) else { throw TrailerError("H.264 encoder cannot accept this format") }
    writer.add(input)
    guard writer.startWriting() else { throw writer.error ?? TrailerError("Cannot start video encoder") }
    writer.startSession(atSourceTime: .zero)

    let staged = directory.appendingPathComponent("shot.json")
    let encoder = JSONEncoder()
    var firstFrame = 0
    do {
        for (index, shot) in shots.enumerated() {
            print("[\(index + 1)/\(shots.count)] \(shot.name)")
            fflush(stdout)
            let definition: URL
            switch shot.source {
            case let .preset(name):
                definition = capture.appendingPathComponent(name).appendingPathExtension("json")
            case let .staged(scene):
                try encoder.encode(scene).write(to: staged)
                definition = staged
            }
            try appendShot(shot, definition: definition, app: app, format: format, startingAt: firstFrame,
                           writer: writer, adaptor: adaptor)
            firstFrame += shot.count
        }
    } catch {
        writer.cancelWriting()
        throw error
    }
    writer.endSession(atSourceTime: CMTime(value: Int64(firstFrame), timescale: frameRate))
    input.markAsFinished()
    await writer.finishWriting()
    guard writer.status == .completed else { throw writer.error ?? TrailerError("Video encoding failed") }
    return video
}

private func addAudio(_ name: String, sourceStart: Double, at start: Double, length: Double, gain: Float,
                      fadeIn: Double, fadeOut: Double, from library: URL, into composition: AVMutableComposition)
    async throws -> AVMutableAudioMixInputParameters {
    let asset = AVURLAsset(url: library.appendingPathComponent(name).appendingPathExtension("mp3"))
    let tracks = try await asset.loadTracks(withMediaType: .audio)
    let available = try await asset.load(.duration).seconds - sourceStart
    let duration = min(available, length)
    guard duration > 0, let source = tracks.first,
          let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
        throw TrailerError("Cannot mix \(name)")
    }
    try track.insertTimeRange(CMTimeRange(start: mediaTime(sourceStart), duration: mediaTime(duration)),
                              of: source, at: mediaTime(start))
    let parameters = AVMutableAudioMixInputParameters(track: track)
    // Leave headroom for effects that overlap the score and each other.
    let level = gain * 0.60
    parameters.setVolume(level, at: mediaTime(start))
    if fadeIn > 0 {
        parameters.setVolumeRamp(fromStartVolume: 0, toEndVolume: level,
                                 timeRange: CMTimeRange(start: mediaTime(start), duration: mediaTime(fadeIn)))
    }
    let tail = min(fadeOut, duration)
    parameters.setVolumeRamp(fromStartVolume: level, toEndVolume: 0,
                             timeRange: CMTimeRange(start: mediaTime(start + duration - tail), duration: mediaTime(tail)))
    return parameters
}

private func encodeAudio(shots: [Shot], library: URL, directory: URL) async throws -> URL {
    let duration = Double(shots.reduce(0) { $0 + $1.count }) / Double(frameRate)
    let composition = AVMutableComposition()
    var inputs = [try await addAudio("lancer-flight", sourceStart: 36.5, at: 0, length: duration, gain: 0.67,
                                     fadeIn: 0.18, fadeOut: 1.1, from: library, into: composition)]
    var start = 0.0
    for shot in shots {
        let length = Double(shot.count) / Double(frameRate)
        for cue in shot.cues {
            inputs.append(try await addAudio(cue.audio, sourceStart: 0, at: start + cue.time,
                                             length: length - cue.time, gain: cue.gain, fadeIn: 0,
                                             fadeOut: 0.3, from: library, into: composition))
        }
        start += length
    }
    let mix = AVMutableAudioMix()
    mix.inputParameters = inputs
    let reader = try AVAssetReader(asset: composition)
    let audioTracks = try await composition.loadTracks(withMediaType: .audio)
    let output = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
        AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
    ])
    output.audioMix = mix
    guard reader.canAdd(output) else { throw TrailerError("Cannot read the audio mix") }
    reader.add(output)
    let audio = directory.appendingPathComponent("audio.m4a")
    let writer = try AVAssetWriter(url: audio, fileType: .m4a)
    let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
        AVFormatIDKey: kAudioFormatMPEG4AAC, AVEncoderBitRateKey: 256_000,
        AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
    ])
    guard writer.canAdd(input) else { throw TrailerError("Cannot write the audio mix") }
    writer.add(input)
    guard reader.startReading() else { throw reader.error ?? TrailerError("Cannot start reading the audio mix") }
    guard writer.startWriting() else { throw writer.error ?? TrailerError("Cannot start encoding the audio mix") }
    writer.startSession(atSourceTime: .zero)
    while let sample = output.copyNextSampleBuffer() {
        try waitForInput(input, writer: writer)
        guard input.append(sample) else { throw writer.error ?? TrailerError("Cannot encode an audio sample") }
    }
    guard reader.status == .completed else { throw reader.error ?? TrailerError("Audio reading ended early") }
    writer.endSession(atSourceTime: mediaTime(duration))
    input.markAsFinished()
    await writer.finishWriting()
    guard writer.status == .completed else { throw writer.error ?? TrailerError("Audio encoding failed") }
    return audio
}

private func mux(video: URL, audio: URL, output: URL) async throws {
    let composition = AVMutableComposition()
    for (url, type) in [(video, AVMediaType.video), (audio, AVMediaType.audio)] {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: type)
        guard let source = tracks.first,
              let track = composition.addMutableTrack(withMediaType: type, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw TrailerError("Missing \(type.rawValue) track in \(url.lastPathComponent)")
        }
        try await track.insertTimeRange(source.load(.timeRange), of: source, at: .zero)
    }
    guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
        throw TrailerError("Cannot create a trailer export session")
    }
    exporter.shouldOptimizeForNetworkUse = true
    if #available(macOS 15, *) {
        try await exporter.export(to: output, as: .mp4)
    } else {
        exporter.outputURL = output
        exporter.outputFileType = .mp4
        await exporter.export()
        guard exporter.status == .completed else { throw exporter.error ?? TrailerError("Trailer export failed") }
    }
}

@main
private enum StoreTrailer {
    static func main() async {
        do {
            try await run()
        } catch {
            fputs("StoreTrailer: \(error.localizedDescription)\n", stderr)
            exit(EXIT_FAILURE)
        }
    }

    private static func run() async throws {
        let args = CommandLine.arguments.dropFirst()
        guard (1...2).contains(args.count), let path = args.first, path.hasSuffix(".mp4"),
              let format = Format(rawValue: args.dropFirst().first ?? "iphone") else {
            throw TrailerError("Usage from the repo root: StoreTrailer <output.mp4> [iphone|ipad|mac|header|search|draft]")
        }
        let files = FileManager.default
        let root = URL(fileURLWithPath: files.currentDirectoryPath, isDirectory: true)
        let app = root.appendingPathComponent("build/KestrelFrontier.app/Contents/MacOS/KestrelFrontier")
        guard files.isExecutableFile(atPath: app.path) else { throw TrailerError("Build the macOS app with make macos first") }
        let output = URL(fileURLWithPath: path)
        let parent = output.deletingLastPathComponent()
        let directory = parent.appendingPathComponent(".trailer-\(UUID().uuidString)")
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: directory) }
        let shots = trailerShots()
        let capture = root.appendingPathComponent("Tools/Capture")
        let video = try await encodeVideo(shots: shots, app: app, capture: capture, directory: directory, format: format)
        print("Mixing game music and effects")
        let audio = try await encodeAudio(shots: shots, library: root.appendingPathComponent("Resources/Audio"),
                                          directory: directory)
        let result = directory.appendingPathComponent("trailer.mp4")
        try await mux(video: video, audio: audio, output: result)
        guard Darwin.rename(result.path, output.path) == 0 else {
            throw TrailerError("Cannot install \(output.path) (errno \(errno))")
        }
        print("Wrote \(output.path)")
    }
}

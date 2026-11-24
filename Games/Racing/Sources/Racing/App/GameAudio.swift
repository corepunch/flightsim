import AVFoundation

/// Owns the soundtrack and the player's effects on the main thread.
final class GameAudio {
    static let shared = GameAudio()

    private static let soundKey = "audio.enabled"
    private static let menuTrack = "music-menu-pit-lane"
    private static let raceTracks = ["music-race-redline", "music-race-apex", "music-race-slipstream"]

    private var sceneActive = false
    private var interrupted = false
    private var racing = false
    private var racePaused = false
    private var nextRaceTrack = 0
    private var track = GameAudio.menuTrack
    private var music: AVAudioPlayer?
    private lazy var engine = Self.player("engine", loop: true, adjustableRate: true)
    private lazy var skid = Self.player("skid", loop: true)
    private lazy var impact = Self.player("impact")
    private var interruptionObserver: NSObjectProtocol?

    var isEnabled = UserDefaults.standard.object(forKey: GameAudio.soundKey) as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.soundKey)
            updatePlayback()
        }
    }

    private init() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.ambient)
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: session, queue: .main
        ) { [weak self] notification in
            guard let self, let value = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: value) else { return }
            self.interrupted = type == .began
            self.updatePlayback()
        }
    }

    func setSceneActive(_ active: Bool) {
        sceneActive = active
        if active { interrupted = false }
        updatePlayback()
    }

    func startRace() {
        racing = true
        racePaused = false
        stopEffects()
        selectTrack(Self.raceTracks[nextRaceTrack])
        nextRaceTrack = (nextRaceTrack + 1) % Self.raceTracks.count
    }

    func endRace() {
        racing = false
        racePaused = false
        stopEffects()
        selectTrack(Self.menuTrack)
    }

    func setRacePaused(_ paused: Bool) {
        racePaused = paused
        updatePlayback()
    }

    func updateCar(speed: Float, skidding: Float, boosting: Bool, engineRunning: Bool) {
        guard canPlay, racing else { return }
        guard engineRunning else {
            engine?.pause()
            skid?.pause()
            return
        }

        if let engine {
            engine.rate = 0.75 + 0.60 * speed + (boosting ? 0.12 : 0)
            let volume = 0.10 + 0.20 * speed + (boosting ? 0.06 : 0)
            engine.volume += 0.20 * (volume - engine.volume)
            if !engine.isPlaying { engine.play() }
        }
        if let skid {
            skid.volume += 0.24 * (0.32 * skidding - skid.volume)
            if skid.volume > 0.008 {
                if !skid.isPlaying { skid.play() }
            } else if skid.isPlaying {
                skid.pause()
            }
        }
    }

    func playImpact(strength: Float) {
        guard canPlay, racing, let impact, !impact.isPlaying || impact.currentTime > 0.2 else { return }
        impact.volume = min(0.7, 0.16 + 0.027 * strength)
        impact.currentTime = 0
        impact.play()
    }

    private var canPlay: Bool { isEnabled && sceneActive && !interrupted && !racePaused }

    private func selectTrack(_ name: String) {
        if name != track {
            music?.stop()
            music = nil
            track = name
        }
        updatePlayback()
    }

    private func updatePlayback() {
        guard canPlay else {
            music?.pause()
            if racing { stopEffects() }
            return
        }
        if music == nil { music = Self.player(track, fileExtension: "mp3", loop: true) }
        music?.volume = racing ? 0.40 : 0.52
        if let music, !music.isPlaying { music.play() }
    }

    private func stopEffects() {
        for player in [engine, skid, impact].compactMap({ $0 }) {
            player.pause()
            player.currentTime = 0
            player.volume = 0
        }
    }

    private static func player(_ name: String, fileExtension: String = "m4a", loop: Bool = false,
                               adjustableRate: Bool = false) -> AVAudioPlayer? {
        guard let url = Bundle.main.url(forResource: name, withExtension: fileExtension, subdirectory: "Audio"),
              let player = try? AVAudioPlayer(contentsOf: url) else { return nil }
        player.numberOfLoops = loop ? -1 : 0
        player.enableRate = adjustableRate
        player.volume = 0
        return player
    }
}

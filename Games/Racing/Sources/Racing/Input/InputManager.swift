import GameController

/// Reads both the system touch controller and paired extended gamepads.
final class RaceControls {
    private enum TouchState { case off, connecting, connected, waitingToRetry }

    private let touchController: GCVirtualController
    private var observers: [NSObjectProtocol] = []
    private var hardware: GCExtendedGamepad?
    private var touchState = TouchState.off
    private var retryTimer: Timer?
    private var retryDelay: TimeInterval = 1
    private var active = false

    init() {
        let config = GCVirtualController.Configuration()
        config.elements = [GCInputLeftThumbstick, GCInputButtonA, GCInputButtonB, GCInputButtonX]
        touchController = GCVirtualController(configuration: config)
        observers = [Notification.Name.GCControllerDidConnect, .GCControllerDidDisconnect].map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let disconnected = note.name == .GCControllerDidDisconnect ? note.object as? GCController : nil
                self?.updateControllers(disconnected: disconnected)
            }
        }
        updateControllers()
    }

    deinit {
        retryTimer?.invalidate()
        observers.forEach(NotificationCenter.default.removeObserver)
        if touchState == .connected { touchController.disconnect() }
    }

    func setActive(_ active: Bool) {
        guard active != self.active else { return }
        self.active = active
        updateControllers()
    }

    private func updateControllers(disconnected: GCController? = nil) {
        // The touch pad can announce itself before its underlying controller is available.
        guard touchState != .connecting else { return }
        let virtual = touchController.controller
        hardware = GCController.controllers().first {
            $0 !== virtual && $0 !== disconnected && $0.extendedGamepad != nil
        }?.extendedGamepad

        if !active {
            retryTimer?.invalidate()
            retryTimer = nil
            retryDelay = 1
            let wasConnected = touchState == .connected
            touchState = .off
            if wasConnected { touchController.disconnect() }
            return
        }
        if touchState == .connected, let disconnected, virtual == nil || virtual === disconnected {
            touchState = .off
        }
        guard touchState == .off else { return }

        touchState = .connecting
        touchController.connect { [weak self, touchController] error in
            DispatchQueue.main.async {
                guard let self else {
                    if error == nil { touchController.disconnect() }
                    return
                }
                if let error {
                    NSLog("Racing: virtual controller failed to connect: %@", error as NSError)
                    self.touchState = .waitingToRetry
                    self.retryTimer = Timer.scheduledTimer(withTimeInterval: self.retryDelay, repeats: false) { [weak self] _ in
                        guard let self else { return }
                        self.retryTimer = nil
                        self.touchState = .off
                        self.updateControllers()
                    }
                    self.retryDelay = min(8, self.retryDelay * 2)
                } else {
                    self.touchState = .connected
                    self.retryDelay = 1
                }
                self.updateControllers()
            }
        }
    }

    var instruction: String {
        if hardware != nil { return "LEFT STICK STEER   ·   RT GAS   ·   LT BRAKE / REVERSE   ·   A HANDBRAKE" }
        if touchState == .waitingToRetry { return "RECONNECTING TOUCH CONTROLS…" }
        return "LEFT STICK STEER   ·   A GAS   ·   B BRAKE / REVERSE   ·   X HANDBRAKE"
    }

    var menuPressed: Bool { hardware?.buttonMenu.isPressed ?? false }

    var input: CarInput {
        let keyboard = GCKeyboard.coalesced?.keyboardInput
        let left = keyboard?.button(forKeyCode: .leftArrow)?.value ?? 0
        let right = keyboard?.button(forKeyCode: .rightArrow)?.value ?? 0
        let brake = keyboard?.button(forKeyCode: .downArrow)?.value ?? 0
        let throttle = keyboard?.button(forKeyCode: .upArrow)?.value ?? 0
        let handbrake = keyboard?.button(forKeyCode: .spacebar)?.isPressed ?? false
        if left > 0 || right > 0 || brake > 0 || throttle > 0 || handbrake {
            return CarInput(steer: right - left, brake: brake, throttle: throttle, handbrake: handbrake)
        }
        if let pad = touchController.controller?.extendedGamepad {
            let steer = steering(pad)
            if steer != 0 || pad.buttonA.isPressed || pad.buttonB.isPressed || pad.buttonX.isPressed {
                return CarInput(steer: steer, brake: pad.buttonB.value, throttle: pad.buttonA.value,
                                handbrake: pad.buttonX.isPressed)
            }
        }
        if let pad = hardware {
            return CarInput(steer: steering(pad), brake: pad.leftTrigger.value,
                            throttle: pad.rightTrigger.value, handbrake: pad.buttonA.isPressed)
        }
        return CarInput(throttle: 0)
    }

    private func steering(_ pad: GCExtendedGamepad) -> Float {
        let axis = pad.leftThumbstick.xAxis.value
        let magnitude = min(1, max(0, (abs(axis) - 0.08) / 0.92))
        return (axis < 0 ? -1 : 1) * pow(magnitude, 1.75)
    }
}

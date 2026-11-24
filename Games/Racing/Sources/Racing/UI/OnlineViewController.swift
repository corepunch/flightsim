import UIKit

/// Races on the local network: host one, or join one the browser finds.
final class OnlineViewController: ScreenController {
    private let profile = Profile.shared
    private let browser = LANBrowser()
    private let list = UI.stack([], spacing: 10)
    private let status = UI.body("", 13)
    private let spinner = UIActivityIndicatorView(style: .medium)
    private var didAutoconnect = false

    override func viewDidLoad() {
        super.viewDidLoad()
        let header = addHeader("ONLINE")

        let car = profile.selectedCar.design
        let carCard = CardView()
        let badge = ClassBadge()
        badge.set(car.spec)
        let carText = UI.stack([UI.caps("YOU RACE AS", 9), UI.label(profile.driver, UI.font(16, .black)),
                                UI.caps(car.name, 9, UI.color(car.glow))], spacing: 2)
        carCard.fill(with: UI.stack([carText, badge], axis: .horizontal, spacing: 10, alignment: .center), inset: 14)

        let host = GlowButton("HOST A RACE", tint: UI.magenta, filled: true, size: 17)
        host.heightAnchor.constraint(equalToConstant: 58).isActive = true
        host.onTap = { [weak self] in self?.host() }
        let hostNote = UI.body("Players on the same Wi-Fi see your race here. Add bots to fill the grid.", 12, UI.faint)

        spinner.color = UI.cyan
        spinner.startAnimating()
        let nearbyHead = UI.stack([UI.caps("RACES NEARBY", 10), spinner, UIView()], axis: .horizontal, spacing: 8, alignment: .center)

        let hosting = UI.scrollColumn(UI.stack([carCard, host, hostNote], spacing: 10))
        let nearby = UI.stack([nearbyHead, UI.scrollColumn(UI.stack([list, status], spacing: 8))], spacing: 8)
        placeBody(UI.columns(hosting, nearby, leadingShare: 0.42), below: header)
        browser.onChange = { [weak self] in self?.reload() }
        reload()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        browser.start()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // `-mpHost YES` hosts at once; `-mpJoin <ip>` joins that address directly.
        guard !didAutoconnect else { return }
        didAutoconnect = true
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: "mpHost") { host() }
        if let address = defaults.string(forKey: "mpJoin") {
            open(RaceClient.join(host: address, name: profile.driver, loadout: profile.selectedCar.loadout.encoded()))
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        browser.stop()
    }

    private func reload() {
        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let servers = browser.servers
        for server in servers { list.addArrangedSubview(serverCard(server)) }
        if let error = browser.error {
            status.text = error
            status.textColor = UI.magenta
        } else {
            status.text = servers.isEmpty ? "Looking for races on this network. Both devices need Local Network access in Settings." : nil
            status.textColor = UI.faint
        }
        status.isHidden = status.text == nil
    }

    private func serverCard(_ server: LANServerInfo) -> UIView {
        let card = CardView()
        let map = TrackMaps.map(server.trackIndex, size: 46)
        let name = UI.label(server.name, UI.font(15, .black))
        let line = "\(TrackMaps.definition(server.trackIndex).name.uppercased())  ·  \(server.players)/\(server.maxPlayers)"
        let detail = UI.caps(line, 9)
        let phase = UI.caps(server.phase.uppercased(), 9, server.phase == "Lobby" ? UI.green : UI.amber)
        let text = UI.stack([name, detail, phase], spacing: 3)
        let join = GlowButton(server.isCompatible ? "JOIN" : "UPDATE", size: 12)
        join.isEnabled = server.isCompatible && server.players < server.maxPlayers
        join.widthAnchor.constraint(equalToConstant: 76).isActive = true
        join.heightAnchor.constraint(equalToConstant: 40).isActive = true
        join.onTap = { [weak self] in self?.join(server) }
        card.fill(with: UI.stack([map, text, join], axis: .horizontal, spacing: 12, alignment: .center), inset: 12)
        return card
    }

    private func host() {
        let settings = MatchSettings(trackIndex: 0, trackSeed: TrackLibrary.all[0].seed, laps: 3)
        do {
            open(try RaceClient.host(name: profile.driver, room: profile.driver + "'S RACE", loadout: profile.selectedCar.loadout.encoded(), settings: settings))
        } catch {
            present(SheetController.confirm(title: "CAN'T HOST", message: "The race server couldn't open a network port. \(error.localizedDescription)",
                                            confirm: "OK", cancel: nil) {}, animated: true)
        }
    }

    private func join(_ server: LANServerInfo) {
        open(RaceClient.join(server, name: profile.driver, loadout: profile.selectedCar.loadout.encoded()))
    }

    private func open(_ client: RaceClient) {
        navigationController?.pushViewController(LobbyViewController(client: client), animated: true)
    }
}

/// The waiting room: the host picks the track, laps and bots; everyone readies up;
/// the race starts on the server's countdown, for everyone at once.
final class LobbyViewController: ScreenController {
    private let client: RaceClient
    private let profile = Profile.shared
    private var header: HeaderBar!
    private let roomName = UI.label("", UI.font(13, .black), UI.cyan)
    private let settingsCard = CardView()
    private let roster = UI.stack([], spacing: 8)
    private let rosterTitle = UI.caps("", 10)
    private let addBot = GlowButton("ADD BOT", size: 11)
    private let action = GlowButton("", filled: true, size: 17)
    private let hint = UI.caps("", 9)
    private weak var game: GameViewController?
    private var lastSettings: MatchSettings?
    /// Set when this race's screen has been shown, cleared back in the lobby: one race, one presentation.
    private var raceShown = false
    private var didDebugSetup = false

    init(client: RaceClient) {
        self.client = client
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        header = addHeader("LOBBY")
        header.onBack = { [weak self] in self?.confirmLeave() }

        addBot.widthAnchor.constraint(equalToConstant: 92).isActive = true
        addBot.heightAnchor.constraint(equalToConstant: 34).isActive = true
        addBot.onTap = { [weak self] in self?.addBotTapped() }
        let rosterHead = UI.stack([rosterTitle, UIView(), addBot], axis: .horizontal, spacing: 8, alignment: .center)
        let setup = UI.scrollColumn(UI.stack([roomName, settingsCard], spacing: 10))

        action.heightAnchor.constraint(equalToConstant: 48).isActive = true
        action.onTap = { [weak self] in self?.actionTapped() }
        hint.textAlignment = .center
        hint.numberOfLines = 2
        let drivers = UI.stack([rosterHead, UI.scrollColumn(roster), hint, action], spacing: 8)
        placeBody(UI.columns(setup, drivers, leadingShare: 0.54), below: header)

        client.onChange = { [weak self] in self?.reload() }
        client.onDisconnect = { [weak self] reason in self?.disconnected(reason) }
        UIApplication.shared.isIdleTimerDisabled = true
        reload()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if navigationController == nil || isMovingFromParent { UIApplication.shared.isIdleTimerDisabled = false }
    }

    // MARK: - State

    private var myCar: NetCar? { client.cars.first { $0.id == client.myCarIDs.first } }

    private func reload() {
        guard isViewLoaded else { return }
        let connected = client.isConnected
        roomName.text = connected ? client.serverName.uppercased() : "CONNECTING…"
        let settings = client.settings
        if settings != lastSettings {
            lastSettings = settings
            buildSettings(settings)
        }
        buildRoster()
        updateAction()
        startRaceIfDue()
        debugSetup()
    }

    /// `-mpBots <n>`, `-mpLaps <n>`, `-mpStart YES`: a hosted race that sets itself up, for testing.
    private func debugSetup() {
        let defaults = UserDefaults.standard
        guard client.isHost, client.isConnected, !didDebugSetup, defaults.object(forKey: "mpBots") != nil else { return }
        didDebugSetup = true
        if defaults.integer(forKey: "mpLaps") > 0 { change { $0.laps = defaults.integer(forKey: "mpLaps") } }
        for _ in 0..<defaults.integer(forKey: "mpBots") { addBotTapped() }
        if defaults.bool(forKey: "mpStart") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.client.startRace() }
        }
    }

    private func buildSettings(_ s: MatchSettings) {
        settingsCard.subviews.forEach { $0.removeFromSuperview() }
        let host = client.isHost
        let track = min(max(s.trackIndex, 0), TrackLibrary.all.count - 1)
        let map = TrackMaps.map(track, size: 48)
        let definition = TrackMaps.definition(track)
        let length = TrackMaps.path(definition).totalLength
        let trackText = UI.stack([UI.caps("TRACK", 9), UI.label(definition.name.uppercased(), UI.font(14, .black)),
                                  UI.caps(String(format: "%.1f KM", length / 1000), 9, UI.color(definition.theme.neonA))], spacing: 2)
        var trackViews: [UIView] = [map, trackText]
        if host {
            let previous = CircleButton(symbol: "chevron.left", size: 36)
            previous.accessibilityLabel = "Previous track"
            previous.onTap = { [weak self] in self?.change { $0.trackIndex = ($0.trackIndex + TrackLibrary.all.count - 1) % TrackLibrary.all.count } }
            let next = CircleButton(symbol: "chevron.right", size: 36)
            next.accessibilityLabel = "Next track"
            next.onTap = { [weak self] in self?.change { $0.trackIndex = ($0.trackIndex + 1) % TrackLibrary.all.count } }
            trackViews += [UIView(), previous, next]
        }
        let trackRow = UI.stack(trackViews, axis: .horizontal, spacing: 10, alignment: .center)

        let laps = chips(title: "LAPS", options: [1, 2, 3, 4, 5], current: s.laps, label: { "\($0)" }) { [weak self] v in
            self?.change { $0.laps = v }
        }
        let note = UI.body("Free entry. Fixed prizes: \(Economy.credits(RacePrizes.lan(position: 1, finished: true))) for first, \(Economy.credits(RacePrizes.lan(position: 2, finished: true))) for second and \(Economy.credits(RacePrizes.lan(position: 3, finished: true))) for third.", 12, UI.faint)
        settingsCard.fill(with: UI.stack([trackRow, laps, note], spacing: 8), inset: 12)
    }

    private func chips(title: String, options: [Int], current: Int, label: (Int) -> String,
                       pick: @escaping (Int) -> Void) -> UIView {
        let row = UI.stack([], axis: .horizontal, spacing: 6)
        row.distribution = .fillEqually
        for option in options {
            let b = UIButton(type: .custom)
            let on = option == current
            b.setTitle(label(option), for: .normal)
            b.titleLabel?.font = UI.font(10, .black)
            b.titleLabel?.adjustsFontSizeToFitWidth = true
            b.titleLabel?.minimumScaleFactor = 0.7
            b.setTitleColor(on ? UI.ink : (client.isHost ? .white : UI.faint), for: .normal)
            b.backgroundColor = on ? UI.cyan : UIColor(white: 1, alpha: 0.05)
            b.layer.cornerRadius = 8
            b.heightAnchor.constraint(equalToConstant: 34).isActive = true
            b.isUserInteractionEnabled = client.isHost
            b.accessibilityTraits = on ? [.button, .selected] : .button
            b.addAction(UIAction { _ in UI.haptic(); pick(option) }, for: .touchUpInside)
            row.addArrangedSubview(b)
        }
        return UI.stack([UI.caps(title, 9), row], spacing: 6)
    }

    private func change(_ edit: (inout MatchSettings) -> Void) {
        var s = client.settings
        edit(&s)
        s.trackSeed = TrackLibrary.all[min(max(s.trackIndex, 0), TrackLibrary.all.count - 1)].seed
        client.updateSettings(s)
    }

    private func buildRoster() {
        roster.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let cars = client.cars
        rosterTitle.attributedText = NSAttributedString(string: "DRIVERS  \(cars.count)/\(NetProtocol.maxCars)", attributes: [.kern: 1.4])
        addBot.isHidden = !client.isHost || cars.count >= NetProtocol.maxCars
        let mine = Set(client.myCarIDs)
        for car in cars { roster.addArrangedSubview(row(for: car, mine: mine.contains(car.id))) }
    }

    private func row(for car: NetCar, mine: Bool) -> UIView {
        let card = CardView(raised: mine && !car.isBot)
        let design = Loadout.decode(car.loadout)?.design
        let dot = UIView()
        dot.backgroundColor = design.map { UI.color($0.primary) } ?? UI.faint
        dot.layer.cornerRadius = 5
        dot.widthAnchor.constraint(equalToConstant: 10).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 10).isActive = true
        let name = UI.label(car.name + (mine && !car.isBot ? "  (YOU)" : ""), UI.font(14, .black))
        let carLine = UI.caps(design?.name ?? "—", 9, design.map { UI.color($0.glow) } ?? UI.faint)
        let text = UI.stack([name, carLine], spacing: 2)
        let badge = ClassBadge()
        if let design { badge.set(design.spec) }
        badge.isHidden = design == nil
        let isHostCar = car.ownerID == hostOwnerID && !car.isBot
        let state: (String, UIColor)
        if !car.inRace && client.phase != .lobby { state = ("WAITING", UI.faint) }
        else if car.isBot { state = ("BOT", UI.dim) }
        else if isHostCar { state = ("HOST", UI.amber) }
        else { state = car.ready ? ("READY", UI.green) : ("NOT READY", UI.faint) }
        let status = UI.caps(state.0, 9, state.1)
        status.setContentHuggingPriority(.required, for: .horizontal)
        var views: [UIView] = [dot, text, badge, status]
        if client.isHost, !(mine && !car.isBot) {
            let remove = CircleButton(symbol: "xmark", size: 28)
            remove.accessibilityLabel = car.isBot ? "Remove bot" : "Remove \(car.name)"
            remove.onTap = { [weak self] in
                if car.isBot { self?.client.removeBot(car.id) } else { self?.client.kick(carID: car.id) }
            }
            views.append(remove)
        }
        card.fill(with: UI.stack(views, axis: .horizontal, spacing: 10, alignment: .center), inset: 12)
        return card
    }

    /// The host's own car is the one owned by the host client: the first car's owner.
    private var hostOwnerID: UInt8? { client.cars.first { !$0.isBot }?.ownerID }

    private func updateAction() {
        guard client.isConnected else {
            action.setTitleText("CONNECTING…")
            action.isEnabled = false
            hint.text = nil
            return
        }
        switch client.phase {
        case .lobby:
            if client.isHost {
                action.setTitleText("START RACE")
                action.restyle(tint: UI.magenta, filled: true)
                action.isEnabled = client.canStart
                let waiting = client.cars.filter { !$0.isBot && !$0.ready && $0.ownerID != hostOwnerID }.count
                hint.text = waiting > 0 ? "WAITING FOR \(waiting) TO GET READY" : "EVERYONE'S READY"
            } else {
                let ready = myCar?.ready ?? false
                action.setTitleText(ready ? "READY  ·  TAP TO CANCEL" : "READY UP")
                action.restyle(tint: ready ? UI.green : UI.cyan, filled: !ready)
                action.isEnabled = true
                hint.text = "THE HOST STARTS THE RACE"
            }
        case .loading, .countdown, .racing:
            action.setTitleText(myCar?.inRace == true ? "RACE STARTING" : "RACE IN PROGRESS")
            action.isEnabled = false
            hint.text = myCar?.inRace == true ? nil : "YOU'LL JOIN THE NEXT ONE"
        case .results:
            action.setTitleText("RESULTS ARE IN")
            action.isEnabled = false
            hint.text = client.isHost ? nil : "WAITING FOR THE HOST"
        }
    }

    private func actionTapped() {
        if client.isHost {
            client.startRace()
        } else {
            client.setReady(!(myCar?.ready ?? false))
        }
    }

    private func addBotTapped() {
        let index = profile.selectedCar.design.spec.index
        let bot = Blueprint(seed: UInt64.random(in: 1...999_999), focus: Int.random(in: 0...3), hue: Float.random(in: 0...1),
                            budget: Float(index + Int.random(in: -25...15)) * 4 / 1000)
        client.addBot(name: Drivers.name(Int.random(in: 0...999)), loadout: Loadout.generated(bot).encoded())
    }

    // MARK: - Race

    private func startRaceIfDue() {
        switch client.phase {
        case .lobby: raceShown = false; return
        case .loading, .countdown, .racing: break
        case .results: return
        }
        guard !raceShown, game == nil, presentedViewController == nil, myCar?.inRace == true,
              let window = view.window else { return }
        raceShown = true

        let settings = client.settings
        let mine = client.myCarIDs
        let cars = client.cars.filter(\.inRace).sorted { a, b in
            // Own car first, then everyone in id order.
            if a.id == mine.first { return true }
            if b.id == mine.first { return false }
            return a.id < b.id
        }
        let entries = cars.map { car in
            OnlineRace.Entry(id: car.id, name: car.name, design: Loadout.decode(car.loadout)?.design ?? Dealer.catalog[0].design,
                             remote: !mine.contains(car.id))
        }
        guard let first = entries.first else { return }
        let definition = TrackMaps.definition(settings.trackIndex)
        var config = RaceConfig(definition: definition, player: first.design, rivals: [])
        config.laps = settings.laps
        config.assist = profile.assist
        config.difficulty = 1
        config.playerName = first.name
        config.online = OnlineRace(client: client, entries: entries)
        let game = GameViewController(config: config)
        game.onOnlineResults = { [weak self] results in
            guard let self else { return [] }
            guard let index = results.firstIndex(where: { $0.carID == first.id }) else { return [] }
            let prize = self.profile.recordOnline(position: index + 1, finished: results[index].time != nil)
            var lines = [ResultLine(title: "PRIZE", value: Economy.credits(prize), color: prize > 0 ? UI.green : UI.dim)]
            lines.append(ResultLine(title: "BALANCE", value: Economy.credits(self.profile.credits), color: .white))
            return lines
        }
        game.onLeave = { [weak self] in self?.leave() }
        game.debugDriver = UserDefaults.standard.string(forKey: "driver").flatMap(GameScene.DebugDriver.init(rawValue:))
        self.game = game
        game.start(in: window)
    }

    // MARK: - Leaving

    private func confirmLeave() {
        let message = client.isHost ? "Everyone in the lobby is disconnected when the host leaves." : "You can rejoin from the list if there's room."
        present(SheetController.confirm(title: client.isHost ? "CLOSE THE LOBBY?" : "LEAVE THE LOBBY?", message: message,
                                        confirm: client.isHost ? "CLOSE LOBBY" : "LEAVE", tint: UI.magenta) { [weak self] in
            self?.leave()
        }, animated: true)
    }

    private func leave() {
        client.onChange = nil
        client.onDisconnect = nil
        client.leave()
        UIApplication.shared.isIdleTimerDisabled = false
        navigationController?.popViewController(animated: true)
    }

    private func disconnected(_ reason: String) {
        client.onChange = nil
        UIApplication.shared.isIdleTimerDisabled = false
        if let game, game.viewIfLoaded?.window?.rootViewController === game {
            game.onLeave = { [weak self] in self?.navigationController?.popViewController(animated: true) }
            game.connectionLost(reason)
            return
        }
        let sheet = SheetController.confirm(title: "DISCONNECTED", message: reason, confirm: "OK", cancel: nil) { [weak self] in
            self?.navigationController?.popViewController(animated: true)
        }
        sheet.onDismiss = { [weak self] in
            if self?.navigationController?.topViewController === self { self?.navigationController?.popViewController(animated: true) }
        }
        (presentedViewController ?? self).present(sheet, animated: true)
    }
}

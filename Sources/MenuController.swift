import AppKit
import ServiceManagement

/// L'icône de la barre de menus et son menu natif.
final class MenuController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private var servers: [Server] = []
    private var dockerRunning = true
    private var loaded = false
    private var scanning = false
    private var stopping: Set<String> = []
    private var idleTimer: Timer?
    private var openTimer: Timer?

    override init() {
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        if let button = statusItem.button {
            let img = NSImage(systemSymbolName: "server.rack", accessibilityDescription: "Serveurs locaux")
            img?.isTemplate = true
            button.image = img
            button.imagePosition = .imageLeading
        }
        rebuild()
        refresh()
        // Menu fermé : un balayage toutes les 30 s, juste pour le compteur de l'icône.
        idleTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.refresh() }
        idleTimer?.tolerance = 5

        // Pour tester : SL_DEMO=1 ouvre le menu quelques secondes après le lancement.
        if ProcessInfo.processInfo.environment["SL_DEMO"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self else { return }
                let t = Timer(timeInterval: 6, repeats: false) { [weak self] _ in self?.menu.cancelTracking() }
                RunLoop.main.add(t, forMode: .common)
                self.statusItem.button?.performClick(nil)
            }
        }
    }

    /// Contenu du menu en texte (vérification sans écran : SL_DUMP=1).
    func dump() -> String {
        rebuild()
        func walk(_ m: NSMenu, _ depth: Int) -> String {
            m.items.map { i -> String in
                let pad = String(repeating: "    ", count: depth)
                if i.isSeparatorItem { return pad + "────" }
                var line = pad + (i.state == .on ? "✓ " : "") + i.title
                if #available(macOS 14.4, *), let sub = i.subtitle { line += "   [" + sub + "]" }
                if !i.isEnabled { line += "   (info)" }
                return line + (i.submenu.map { "\n" + walk($0, depth + 1) } ?? "")
            }.joined(separator: "\n")
        }
        return walk(menu, 0)
    }

    func load(_ r: ScanResult) { apply(r) }

    // MARK: Données

    private func refresh() {
        guard !scanning else { return }
        scanning = true
        DispatchQueue.global(qos: .utility).async {
            let r = Scanner.scan()
            DispatchQueue.main.async { self.apply(r) }
        }
    }

    private func apply(_ r: ScanResult) {
        scanning = false
        let changed = !loaded || r.servers != servers || r.dockerRunning != dockerRunning
        loaded = true
        servers = r.servers
        dockerRunning = r.dockerRunning
        stopping = stopping.filter { id in servers.contains { $0.id == id } }
        updateButton()
        if changed { rebuild() }
    }

    private var devServers: [Server] { servers.filter { $0.category == .dev } }

    private func updateButton() {
        let n = devServers.count
        statusItem.button?.title = n > 0 ? " \(n)" : ""
        statusItem.button?.toolTip = n == 0 ? "Aucun serveur de dev" : "\(n) serveur\(n > 1 ? "s" : "") de dev"
    }

    // MARK: NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuild() // durées à jour dès l'ouverture
    }

    func menuWillOpen(_ menu: NSMenu) {
        refresh()
        let t = Timer(timeInterval: 3, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(t, forMode: .common) // tourne aussi pendant que le menu est ouvert
        openTimer = t
    }

    func menuDidClose(_ menu: NSMenu) {
        openTimer?.invalidate()
        openTimer = nil
    }

    // MARK: Construction du menu

    private func rebuild() {
        menu.removeAllItems()

        menu.addItem(header("Serveurs de dev"))
        if !loaded {
            menu.addItem(note("Lecture des ports…"))
        } else if devServers.isEmpty {
            menu.addItem(note("Aucun serveur en marche"))
        }
        for s in devServers { menu.addItem(serverItem(s)) }
        if loaded && !dockerRunning { menu.addItem(note("Docker n’est pas lancé")) }

        menu.addItem(.separator())
        let login = ActionItem("Ouvrir à la connexion") { [weak self] in self?.toggleLaunchAtLogin() }
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        let quit = ActionItem("Quitter Serveurs locaux") { NSApp.terminate(nil) }
        quit.keyEquivalent = "q"
        menu.addItem(quit)
    }

    private func serverItem(_ s: Server) -> NSMenuItem {
        let item = NSMenuItem(title: s.title, action: nil, keyEquivalent: "")
        item.image = Tile.image(kind: s.kind, title: s.title)

        var parts: [String] = []
        if let k = s.kind, k != s.title { parts.append(k) }
        parts.append(s.ports.map { ":\($0.port)" }.joined(separator: " "))
        if let d = s.started { parts.append(Self.uptime(d)) }
        setSubtitle(item, stopping.contains(s.id) ? "Arrêt en cours…" : parts.joined(separator: " · "))
        item.submenu = actionsMenu(s)
        return item
    }

    private func actionsMenu(_ s: Server) -> NSMenu {
        let m = NSMenu()
        m.autoenablesItems = false

        if s.isWeb, let port = s.ports.first?.port {
            m.addItem(ActionItem("Ouvrir dans le navigateur", symbol: "safari") { Self.open("http://localhost:\(port)") })
            if let tenants = s.tenants, !tenants.isEmpty {
                let sites = NSMenuItem(title: "Sites", action: nil, keyEquivalent: "")
                sites.image = symbol("globe")
                setSubtitle(sites, "\(tenants.count) garderies")
                let sm = NSMenu()
                sm.autoenablesItems = false
                for t in tenants {
                    let it = ActionItem(t.name) { Self.open("http://\(t.slug).localhost:\(port)") }
                    setSubtitle(it, t.slug)
                    sm.addItem(it)
                }
                sites.submenu = sm
                m.addItem(sites)
            }
            m.addItem(.separator())
        }

        if let cwd = s.cwd {
            m.addItem(ActionItem("Afficher dans le Finder", symbol: "folder") {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: cwd)
            })
        }
        if let c = s.container {
            m.addItem(ActionItem("Copier l’ID du conteneur", symbol: "doc.on.doc") { Self.copy(c.id) })
        } else if let pid = s.rootPid {
            m.addItem(ActionItem("Copier le PID (\(pid))", symbol: "doc.on.doc") { Self.copy(String(pid)) })
        }
        m.addItem(ActionItem("Copier la commande", symbol: "terminal") { Self.copy(s.command) })

        m.addItem(.separator())
        m.addItem(info("Lancé depuis \(s.origin)" + (s.tty.map { " (\($0))" } ?? ""), symbol: s.isDocker ? "shippingbox" : "rectangle.topthird.inset.filled"))
        if let d = s.started { m.addItem(info("Démarré " + Self.clock(d), symbol: "clock")) }
        if let p = s.cwdShort { m.addItem(info(p, symbol: "folder")) }
        if s.chain.count > 1 { m.addItem(info(s.chain.joined(separator: " → "), symbol: "arrow.triangle.branch")) }
        if s.pids.count > 1 { m.addItem(info("\(s.pids.count) processus", symbol: "square.stack")) }

        if s.canStop {
            m.addItem(.separator())
            if stopping.contains(s.id) {
                m.addItem(info("Arrêt en cours…", symbol: "hourglass"))
            } else {
                let stop = ActionItem("Arrêter…", symbol: "stop.circle") { [weak self] in self?.confirmStop(s) }
                stop.attributedTitle = NSAttributedString(string: "Arrêter…", attributes: [
                    .foregroundColor: NSColor.systemRed, .font: NSFont.menuFont(ofSize: 0),
                ])
                m.addItem(stop)
            }
        }
        return m
    }

    // MARK: Arrêt

    private func confirmStop(_ s: Server) {
        let what = s.container.map { "Le conteneur \($0.name) sera arrêté (docker stop)." }
            ?? "« \(s.launch) » et ses \(s.pids.count) processus recevront SIGTERM, comme un Ctrl-C."
        guard ask("Arrêter \(s.title) ?", what, confirm: "Arrêter") else { return }
        stop(s, force: false)
    }

    private func stop(_ s: Server, force: Bool) {
        stopping.insert(s.id)
        rebuild()
        DispatchQueue.global(qos: .userInitiated).async {
            let err = Scanner.stop(s, force: force)
            // Laisse 5 s au serveur pour se fermer proprement.
            var alive = err == nil
            for _ in 0..<20 where alive && err == nil {
                Thread.sleep(forTimeInterval: 0.25)
                alive = Scanner.isAlive(s)
            }
            DispatchQueue.main.async {
                self.stopping.remove(s.id)
                self.refresh()
                if let err {
                    self.alert("Impossible d’arrêter \(s.title)", err)
                } else if alive && !force {
                    let what = s.isDocker
                        ? "Le conteneur ne s’est pas arrêté. Le forcer avec docker kill ?"
                        : "Il n’a pas répondu à SIGTERM. Forcer l’arrêt avec SIGKILL ? Il n’aura pas le temps de se fermer proprement."
                    if self.ask("\(s.title) tourne toujours", what, confirm: "Forcer l’arrêt", cancel: "Laisser tourner") {
                        self.stop(s, force: true)
                    }
                }
            }
        }
    }

    private func ask(_ title: String, _ text: String, confirm: String, cancel: String = "Annuler") -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.alertStyle = .warning
        a.addButton(withTitle: confirm).hasDestructiveAction = true
        a.addButton(withTitle: cancel).keyEquivalent = "\u{1b}"
        return a.runModal() == .alertFirstButtonReturn
    }

    private func alert(_ title: String, _ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }

    private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            alert("Ouverture à la connexion", error.localizedDescription)
        }
    }

    // MARK: Aides

    private func header(_ title: String) -> NSMenuItem {
        if #available(macOS 14, *) { return .sectionHeader(title: title) }
        return info(title, symbol: nil)
    }

    private func note(_ text: String) -> NSMenuItem {
        let i = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    private func info(_ text: String, symbol name: String?) -> NSMenuItem {
        let i = note(text)
        if let name { i.image = symbol(name) }
        return i
    }

    private func symbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)
    }

    private func setSubtitle(_ item: NSMenuItem, _ text: String) {
        if #available(macOS 14.4, *) {
            item.subtitle = text
        } else {
            item.toolTip = text
        }
    }

    static func open(_ url: String) {
        if let u = URL(string: url) { NSWorkspace.shared.open(u) }
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    static func uptime(_ since: Date) -> String {
        let m = Int(max(0, Date().timeIntervalSince(since))) / 60
        if m < 1 { return "à l’instant" }
        if m < 60 { return "\(m) min" }
        let h = m / 60
        if h < 24 { return "\(h) h \(String(format: "%02d", m % 60))" }
        return "\(h / 24) j \(h % 24) h"
    }

    static func clock(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_CA")
        f.dateFormat = Calendar.current.isDateInToday(d) ? "'à' HH 'h' mm" : "'le' d MMM 'à' HH 'h' mm"
        return f.string(from: d)
    }
}

/// Élément de menu qui appelle une closure.
final class ActionItem: NSMenuItem {
    private var handler: () -> Void = {}

    convenience init(_ title: String, symbol: String? = nil, _ handler: @escaping () -> Void) {
        self.init(title: title, action: #selector(fire), keyEquivalent: "")
        self.target = self
        self.handler = handler
        if let symbol { image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
    }

    @objc private func fire() { handler() }
}

/// Petite pastille colorée par type de serveur (N, Pg, V…).
enum Tile {
    static let styles: [String: (String, NSColor)] = [
        "Next.js": ("N", .labelColor),
        "Postgres": ("Pg", NSColor(red: 0.2, green: 0.4, blue: 0.57, alpha: 1)),
        "Vite": ("V", NSColor(red: 0.49, green: 0.36, blue: 1, alpha: 1)),
        "Django": ("Dj", NSColor(red: 0.05, green: 0.36, blue: 0.24, alpha: 1)),
        "Docker": ("D", NSColor(red: 0.11, green: 0.39, blue: 0.93, alpha: 1)),
        "Redis": ("R", NSColor(red: 0.85, green: 0.17, blue: 0.13, alpha: 1)),
        "Expo": ("Ex", NSColor(red: 0.1, green: 0.1, blue: 0.2, alpha: 1)),
        "Astro": ("A", NSColor(red: 1, green: 0.36, blue: 0, alpha: 1)),
        "MySQL": ("My", NSColor(red: 0, green: 0.46, blue: 0.56, alpha: 1)),
        "MongoDB": ("Mo", NSColor(red: 0, green: 0.48, blue: 0.25, alpha: 1)),
        "Python": ("Py", NSColor(red: 0.22, green: 0.46, blue: 0.67, alpha: 1)),
        "Rails": ("Rb", NSColor(red: 0.8, green: 0, blue: 0, alpha: 1)),
    ]

    static func image(kind: String?, title: String) -> NSImage {
        let st = styles[kind ?? ""]
        let text = st?.0 ?? String(title.prefix(1)).uppercased()
        let size = NSSize(width: 20, height: 20)
        return NSImage(size: size, flipped: false) { r in
            let bg = st?.1 ?? NSColor.tertiaryLabelColor
            NSBezierPath(roundedRect: r.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5).fill(with: bg)
            let fg: NSColor = kind == "Next.js" ? .windowBackgroundColor : .white
            let font = NSFont.systemFont(ofSize: text.count > 1 ? 8 : 10, weight: .bold)
            let str = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: fg])
            let s = str.size()
            str.draw(at: NSPoint(x: r.midX - s.width / 2, y: r.midY - s.height / 2))
            return true
        }
    }
}

private extension NSBezierPath {
    func fill(with color: NSColor) {
        color.setFill()
        fill()
    }
}

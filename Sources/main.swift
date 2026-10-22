import AppKit

// `ServeursLocaux --list` : la liste en texte.
// `ServeursLocaux --stop PORT [--force]` : arrête le serveur de ce port (SIGTERM, ou SIGKILL avec --force).
let args = CommandLine.arguments
if args.contains("--list") {
    for s in Scanner.scan().servers where s.category == .dev {
        print(s.ports.map { ":\($0.port)" }.joined(separator: ","), s.title, "·", s.launch, "·", s.origin,
              s.rootPid.map { "· PID \($0)" } ?? "")
    }
    exit(0)
}
if let i = args.firstIndex(of: "--stop"), i + 1 < args.count, let port = Int(args[i + 1]) {
    guard let s = Scanner.scan().servers.first(where: { $0.ports.contains { $0.port == port } }) else {
        print("Rien n’écoute sur :\(port)")
        exit(1)
    }
    let err = Scanner.stop(s, force: args.contains("--force"))
    print(err ?? "Signal envoyé à \(s.title) (\(s.pids.count) processus)")
    exit(err == nil ? 0 : 1)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = MenuController()
if ProcessInfo.processInfo.environment["SL_DUMP"] == "1" {
    controller.load(Scanner.scan())
    print(controller.dump())
    exit(0)
}
app.run()

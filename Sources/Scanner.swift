import Foundation

// Inventaire des serveurs qui écoutent sur un port TCP local.
// Tout passe par les outils de macOS (lsof, ps) et par docker s'il est là.

struct PortInfo: Hashable {
    let port: Int
    let addrs: [String]
    let inner: Int?

    /// Écoute aussi sur le réseau local (pas seulement 127.0.0.1 / ::1).
    var isPublic: Bool { addrs.contains { $0 == "*" || $0 == "0.0.0.0" || $0 == "::" } }
}

struct Tenant: Hashable {
    let slug: String
    let name: String
}

struct Container: Hashable {
    let id: String
    let name: String
    let image: String
}

enum Category: Int { case dev = 0, app = 1 }

struct Server: Identifiable, Equatable {
    let id: String
    let isDocker: Bool
    let kind: String?
    let title: String
    let launch: String
    let command: String
    let chain: [String]
    let cwd: String?
    let started: Date?
    let origin: String
    let tty: String?
    let ports: [PortInfo]
    let pids: [Int32]
    let rootPid: Int32?
    let container: Container?
    let category: Category
    let canStop: Bool
    var tenants: [Tenant]?

    var cwdShort: String? { cwd.map(Scanner.tilde) }

    /// Base de données, cache… : pas une page web à ouvrir.
    var isWeb: Bool { !isDocker && !["Postgres", "MySQL", "Redis", "MongoDB"].contains(kind ?? "") }
}

struct ScanResult {
    let servers: [Server]
    let dockerRunning: Bool
}

enum Scanner {
    static let home = NSHomeDirectory()

    static func tilde(_ p: String) -> String {
        p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p
    }

    // MARK: Commandes

    @discardableResult
    static func run(_ args: [String], timeout: TimeInterval = 6) -> (ok: Bool, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + (env["PATH"] ?? "")
        env["LC_ALL"] = "C"
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return (false, "") }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if p.isRunning { p.terminate() } }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus == 0, String(decoding: data, as: UTF8.self))
    }

    static func matches(_ s: String, _ pattern: String) -> Bool {
        s.range(of: pattern, options: .regularExpression) != nil
    }

    static func capture(_ s: String, _ pattern: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        return (0..<m.numberOfRanges).map { i in
            Range(m.range(at: i), in: s).map { String(s[$0]) } ?? ""
        }
    }

    // MARK: lsof : qui écoute sur quel port

    struct Listener {
        let pid: Int32
        var ports: [Int: Set<String>] = [:]
    }

    static func listeners() -> [Int32: Listener] {
        let out = run(["lsof", "-nP", "-iTCP", "-sTCP:LISTEN", "-F", "pn"]).out
        var byPid: [Int32: Listener] = [:]
        var cur: Int32?
        for line in out.split(separator: "\n") {
            guard let k = line.first else { continue }
            let v = String(line.dropFirst())
            if k == "p", let pid = Int32(v) {
                cur = pid
                if byPid[pid] == nil { byPid[pid] = Listener(pid: pid) }
            } else if k == "n", let pid = cur, let i = v.lastIndex(of: ":"), let port = Int(v[v.index(after: i)...]) {
                let addr = String(v[..<i]).trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                byPid[pid]?.ports[port, default: []].insert(addr)
            }
        }
        return byPid
    }

    // MARK: ps : arbre des processus

    struct Proc {
        let pid: Int32
        let ppid: Int32
        let uid: Int
        let tty: String?
        let started: Date?
        let command: String
        var children: [Int32] = []
    }

    static let lstartFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return f
    }()

    static func processTable() -> [Int32: Proc] {
        let out = run(["ps", "-axww", "-o", "pid=,ppid=,uid=,tty=,lstart=,command="]).out
        var procs: [Int32: Proc] = [:]
        let pattern = #"^\s*(\d+)\s+(\d+)\s+(\d+)\s+(\S+)\s+(\w{3} \w{3}\s+\d+ \d\d:\d\d:\d\d \d{4})\s+(.*)$"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return procs }
        for lineSub in out.split(separator: "\n") {
            let line = String(lineSub)
            guard let m = re.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else { continue }
            func g(_ i: Int) -> String { Range(m.range(at: i), in: line).map { String(line[$0]) } ?? "" }
            guard let pid = Int32(g(1)), let ppid = Int32(g(2)) else { continue }
            let date = g(5).replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            procs[pid] = Proc(pid: pid, ppid: ppid, uid: Int(g(3)) ?? -1,
                              tty: g(4) == "??" ? nil : g(4),
                              started: lstartFormat.date(from: date),
                              command: g(6).trimmingCharacters(in: .whitespaces))
        }
        for p in procs.values { procs[p.ppid]?.children.append(p.pid) }
        return procs
    }

    static func cwds(_ pids: [Int32]) -> [Int32: String] {
        guard !pids.isEmpty else { return [:] }
        let out = run(["lsof", "-a", "-p", pids.map(String.init).joined(separator: ","), "-d", "cwd", "-F", "pn"]).out
        var res: [Int32: String] = [:]
        var pid: Int32?
        for line in out.split(separator: "\n") {
            if line.first == "p" { pid = Int32(line.dropFirst()) }
            else if line.first == "n", let p = pid { res[p] = String(line.dropFirst()) }
        }
        return res
    }

    // MARK: docker : conteneurs et ports publiés

    struct DockerInfo {
        let id: String
        let name: String
        let image: String
        let project: String?
        let workingDir: String?
        let service: String?
        var ports: [(host: Int, inner: Int)]
    }

    nonisolated(unsafe) static var startedCache: [String: Date] = [:]

    static func dockerContainers() -> (running: Bool, byPort: [Int: DockerInfo]) {
        let r = run(["docker", "ps", "--no-trunc", "--format", "{{json .}}"], timeout: 4)
        guard r.ok else { return (false, [:]) }
        var byPort: [Int: DockerInfo] = [:]
        var ids: [String] = []
        for line in r.out.split(separator: "\n") {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let id = obj["ID"] as? String else { continue }
            var labels: [String: String] = [:]
            for kv in ((obj["Labels"] as? String) ?? "").split(separator: ",") {
                if let i = kv.firstIndex(of: "=") { labels[String(kv[..<i])] = String(kv[kv.index(after: i)...]) }
            }
            var info = DockerInfo(id: id, name: obj["Names"] as? String ?? id, image: obj["Image"] as? String ?? "",
                                  project: labels["com.docker.compose.project"],
                                  workingDir: labels["com.docker.compose.project.working_dir"],
                                  service: labels["com.docker.compose.service"], ports: [])
            for part in ((obj["Ports"] as? String) ?? "").split(separator: ",") {
                guard let c = capture(String(part), #":(\d+)->(\d+)/tcp"#), let h = Int(c[1]), let i = Int(c[2]) else { continue }
                if !info.ports.contains(where: { $0.host == h }) { info.ports.append((h, i)) }
            }
            for p in info.ports { byPort[p.host] = info }
            ids.append(id)
        }
        // L'heure de démarrage ne change pas : un seul `docker inspect` par conteneur.
        let missing = ids.filter { startedCache[$0] == nil }
        if !missing.isEmpty {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let out = run(["docker", "inspect", "-f", "{{.Id}} {{.State.StartedAt}}"] + missing, timeout: 4).out
            for line in out.split(separator: "\n") {
                let parts = line.split(separator: " ")
                guard parts.count == 2 else { continue }
                // Docker donne des nanosecondes : on tronque aux millisecondes.
                var s = String(parts[1])
                if let dot = s.firstIndex(of: "."), let z = s.lastIndex(where: { $0 == "Z" || $0 == "+" }) {
                    let frac = s[s.index(after: dot)..<z].prefix(3)
                    s = String(s[..<dot]) + "." + frac + String(s[z...])
                }
                startedCache[String(parts[0])] = iso.date(from: s)
            }
        }
        return (true, byPort)
    }

    // MARK: Lecture des lignes de commande

    static func tokens(_ command: String) -> [String] {
        // Recolle les chemins avec espaces (« Application Support/… »).
        var out: [String] = []
        for t in command.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init) {
            if let last = out.last, last.hasPrefix("/"), !t.hasPrefix("-"), !t.hasPrefix("/"), matches(t, #"^[A-Z][\w.]*/"#) {
                out[out.count - 1] = last + " " + t
            } else {
                out.append(t)
            }
        }
        return out
    }

    static func basename(_ p: String) -> String { (p as NSString).lastPathComponent }

    static func scriptName(_ p: String) -> String {
        let parts = p.components(separatedBy: "/node_modules/")
        if parts.count > 1 {
            let rest = parts[parts.count - 1].split(separator: "/").map(String.init)
            guard let first = rest.first else { return basename(p) }
            if first == ".bin" {
                let bin = rest.dropFirst().filter { $0 != ".." }
                return bin.first ?? first
            }
            return first.hasPrefix("@") && rest.count > 1 ? first + "/" + rest[1] : first
        }
        if matches(p, #"/pnpm(\.c?js)?$"#) { return "pnpm" }
        return basename(p)
    }

    /// Nom court et lisible : « next dev », « pnpm dev », « python manage.py runserver ».
    static func shortLabel(_ command: String) -> String {
        let t = tokens(command)
        guard let first = t.first else { return command }
        var bin = basename(first)
        var args = Array(t.dropFirst())
        if matches(bin, #"^(node|bun|deno|python[\d.]*|ruby|php)$"#), let i = args.firstIndex(where: { !$0.hasPrefix("-") }) {
            let script = args[i]
            bin = bin.hasPrefix("python") && !script.contains("/") ? "python " + script : scriptName(script)
            args = Array(args[(i + 1)...])
        }
        args = args.filter { !$0.hasPrefix("-") && !matches($0, #"^[A-Z_]+="#) }
        let label = ([bin] + args).joined(separator: " ")
        return label.count > 60 ? String(label.prefix(58)) + "…" : label
    }

    static func exeBase(_ command: String) -> String { basename(tokens(command).first ?? "") }

    static func isShell(_ p: Proc) -> Bool {
        matches(exeBase(p.command), #"^-?(zsh|bash|sh|fish|nu|login|dash|ksh|tcsh)$"#)
    }

    struct Host { let key: String; let label: String }

    /// Reconnaît l'hôte qui a lancé le terminal (app, IDE, multiplexeur).
    static func hostOf(_ p: Proc) -> Host? {
        let c = p.command
        if p.pid == 1 { return Host(key: "launchd", label: "launchd") }
        if matches(c, #"/claude-code/.*/MacOS/claude(\s|$)"#) || c.contains("@anthropic-ai/claude-code") || exeBase(c) == "claude" {
            return Host(key: "claude-code", label: "Claude Code")
        }
        let apps: [(String, String, String)] = [
            (#"/Claude\.app/"#, "claude", "App Claude"),
            (#"/Cursor\.app/"#, "cursor", "Cursor"),
            (#"/(Visual Studio Code|Code - Insiders|VSCodium)\.app/"#, "vscode", "VS Code"),
            (#"/Zed\.app/"#, "zed", "Zed"),
            (#"/Terminal\.app/"#, "terminal", "Terminal"),
            (#"/iTerm\.app/"#, "iterm", "iTerm2"),
            (#"/Warp\.app/"#, "warp", "Warp"),
            (#"/Ghostty\.app/"#, "ghostty", "Ghostty"),
            (#"/WezTerm\.app/"#, "wezterm", "WezTerm"),
            (#"/kitty\.app/"#, "kitty", "kitty"),
            (#"(^|/)tmux(:| |$)"#, "tmux", "tmux"),
        ]
        for (re, key, label) in apps where matches(c, re) { return Host(key: key, label: label) }
        return nil
    }

    static let kinds: [(String, String)] = [
        (#"(^|[\s/])next(-server| dev| start|\s|$)"#, "Next.js"),
        (#"(^|[\s/])vite(\s|$)"#, "Vite"),
        (#"(^|[\s/])astro(\s|$)"#, "Astro"),
        (#"(^|[\s/])nuxt"#, "Nuxt"),
        (#"(^|[\s/])remix|react-router dev"#, "Remix"),
        (#"(^|[\s/])expo(\s|$)|metro"#, "Expo"),
        (#"storybook"#, "Storybook"),
        (#"webpack"#, "Webpack"),
        (#"manage\.py runserver|django"#, "Django"),
        (#"uvicorn|gunicorn|fastapi"#, "Python"),
        (#"flask"#, "Flask"),
        (#"rails|puma"#, "Rails"),
        (#"postgres"#, "Postgres"),
        (#"mysql|mariadb"#, "MySQL"),
        (#"redis"#, "Redis"),
        (#"mongo"#, "MongoDB"),
        (#"ngrok"#, "ngrok"),
        (#"caddy"#, "Caddy"),
        (#"nginx"#, "nginx"),
    ]

    static func kindOf(_ text: String) -> String? {
        kinds.first { matches(text, $0.0) }?.1
    }

    // MARK: Sous-domaines template-garderie (*.localhost)

    nonisolated(unsafe) static var tenantCache: [String: (at: Date, list: [Tenant])] = [:]

    static func garderieTenants(_ dir: String?, docker: [Int: DockerInfo]) -> [Tenant]? {
        guard let dir, FileManager.default.fileExists(atPath: dir + "/src/collections/Tenants.ts") else { return nil }
        if let hit = tenantCache[dir], Date().timeIntervalSince(hit.at) < 60 { return hit.list }
        var list: [Tenant] = []
        if let env = try? String(contentsOfFile: dir + "/.env", encoding: .utf8),
           let raw = capture(env, #"(?m)^DATABASE_URI=(.*)$"#)?[1],
           let u = URLComponents(string: raw.trimmingCharacters(in: CharacterSet(charactersIn: "'\" "))),
           let c = docker[u.port ?? 5432] {
            let inner = c.ports.first { $0.host == (u.port ?? 5432) }?.inner ?? 5432
            let local = "postgres://\(u.percentEncodedUser ?? ""):\(u.percentEncodedPassword ?? "")@localhost:\(inner)\(u.path)"
            let sql = "select slug || '|' || coalesce(name,'') from tenants where slug is not null and coalesce(active, true) order by name"
            var r = run(["docker", "exec", c.id, "psql", local, "-Atc", sql], timeout: 4)
            if !r.ok { r = run(["docker", "exec", c.id, "psql", local, "-Atc", sql.replacingOccurrences(of: " and coalesce(active, true)", with: "")], timeout: 4) }
            list = r.out.split(separator: "\n").map { l in
                let parts = l.split(separator: "|", maxSplits: 1).map(String.init)
                return Tenant(slug: parts[0], name: parts.count > 1 ? parts[1] : parts[0])
            }
        }
        tenantCache[dir] = (Date(), list)
        return list
    }

    // MARK: Assemblage

    static func scan() -> ScanResult {
        let lis = listeners()
        let procs = processTable()
        let docker = dockerContainers()
        let myUid = Int(getuid())

        var dockerGroups: [String: Server] = [:]
        struct Draft {
            var root: Proc
            var chain: [Proc]
            var labels: [String]
            var shell: Proc?
            var hosts: [Host]
            var tty: String?
            var appPath: Bool
            var isDev: Bool
            var listenerPids: [Int32] = []
            var ports: [PortInfo] = []
        }
        var drafts: [Int32: Draft] = [:]

        for l in lis.values {
            guard let proc = procs[l.pid] else { continue }

            // Ports publiés par Docker : on montre le conteneur, pas le moteur Docker.
            for (port, addrs) in l.ports where docker.byPort[port] != nil {
                let c = docker.byPort[port]!
                let key = "docker:" + c.id
                let info = PortInfo(port: port, addrs: addrs.sorted(), inner: c.ports.first { $0.host == port }?.inner)
                if var g = dockerGroups[key] {
                    if !g.ports.contains(where: { $0.port == port }) {
                        g = Server(id: g.id, isDocker: true, kind: g.kind, title: g.title, launch: g.launch, command: g.command,
                                   chain: g.chain, cwd: g.cwd, started: g.started, origin: g.origin, tty: nil,
                                   ports: g.ports + [info], pids: [], rootPid: nil, container: g.container,
                                   category: .dev, canStop: true, tenants: nil)
                    }
                    dockerGroups[key] = g
                } else {
                    dockerGroups[key] = Server(
                        id: key, isDocker: true, kind: kindOf(c.image) ?? "Docker",
                        title: c.service ?? c.name,
                        launch: c.project.map { "docker compose (\($0))" } ?? "docker run",
                        command: "docker " + c.image, chain: [c.image],
                        cwd: c.workingDir, started: startedCache[c.id],
                        origin: c.project != nil ? "Docker compose" : "Docker", tty: nil,
                        ports: [info], pids: [], rootPid: nil,
                        container: Container(id: c.id, name: c.name, image: c.image),
                        category: .dev, canStop: true, tenants: nil)
                }
            }
            let ownPorts = l.ports.filter { docker.byPort[$0.key] == nil }
            if ownPorts.isEmpty { continue }

            // Remonte la filiation : listener → … → racine du lancement (juste sous le shell / l'hôte).
            var chain = [proc]
            var p = proc
            var shell: Proc?
            var hosts: [Host] = []
            while p.ppid > 0, let parent = procs[p.ppid] {
                if isShell(parent) { shell = parent; break }
                if let h = hostOf(parent) { hosts.append(h); break }
                chain.append(parent)
                p = parent
            }
            let root = chain.last!
            var q = procs[(shell ?? root).ppid]
            while let cur = q {
                if let h = hostOf(cur), !hosts.contains(where: { $0.key == h.key }) { hosts.append(h) }
                if cur.pid == 1 { break }
                q = procs[cur.ppid]
            }

            let tty = chain.first { $0.tty != nil }?.tty ?? shell?.tty
            let appPath = matches(root.command, #"^/(Applications|System|usr/libexec|usr/sbin)/"#)
            let isDev = shell != nil || tty != nil || (hosts.contains { $0.key == "claude-code" || $0.key == "tmux" } && !appPath)

            var labels: [String] = []
            for c in chain.reversed() {
                let lab = shortLabel(c.command)
                if labels.last != lab { labels.append(lab) }
            }

            var d = drafts[root.pid] ?? Draft(root: root, chain: chain, labels: labels, shell: shell, hosts: hosts,
                                              tty: tty, appPath: appPath, isDev: isDev)
            if labels.count > d.labels.count { d.labels = labels; d.chain = chain }
            d.listenerPids.append(l.pid)
            for (port, addrs) in ownPorts where !d.ports.contains(where: { $0.port == port }) {
                d.ports.append(PortInfo(port: port, addrs: addrs.sorted(), inner: nil))
            }
            drafts[root.pid] = d
        }

        let cwdMap = cwds(drafts.values.flatMap { [$0.root.pid] + $0.listenerPids })

        var servers: [Server] = Array(dockerGroups.values)
        for d in drafts.values {
            // Sous-arbre du lancement : tous les PID qu'« Arrêter » visera.
            var pids: [Int32] = []
            var stack = [d.root.pid]
            var seen = Set<Int32>()
            while let pid = stack.popLast() {
                if !seen.insert(pid).inserted { continue }
                pids.append(pid)
                stack.append(contentsOf: procs[pid]?.children ?? [])
            }

            var cwd = cwdMap[d.root.pid] ?? d.listenerPids.compactMap { cwdMap[$0] }.first
            if cwd == "/" { cwd = nil }

            // Lancé en arrière-plan (nohup, &) puis rattaché à launchd : c'est quand même
            // un serveur de dev s'il tourne depuis un dossier de travail (pas « / » ni ~/Library).
            let detached = !d.isDev && !d.appPath && cwd != nil && !cwd!.hasPrefix(home + "/Library/") && !d.root.command.contains(".app/")
            let category: Category = d.isDev || detached ? .dev : .app

            let h0 = d.hosts.first
            var origin: String
            if detached { origin = "Arrière-plan" }
            else if category == .app { origin = h0?.key == "launchd" || h0 == nil ? "Application" : h0!.label }
            else if h0?.key == "claude", d.shell != nil { origin = "App Claude · terminal" }
            else if h0?.key == "claude-code" { origin = "Claude Code" }
            else if ["cursor", "vscode", "zed"].contains(h0?.key ?? ""), d.shell != nil { origin = h0!.label + " · terminal" }
            else { origin = d.hosts.first { $0.key != "launchd" }?.label ?? (d.shell != nil ? "Shell" : "Inconnu") }

            let kind = kindOf(d.labels.joined(separator: " \n ")) ?? kindOf(d.chain.map(\.command).joined(separator: " \n "))
            let appName = capture(d.root.command, #"/([^/]+)\.app/"#)?[1]
            let title = category == .app ? (appName ?? exeBase(d.root.command)) : (cwd.map(basename) ?? d.labels.first ?? "?")

            servers.append(Server(
                id: "proc:\(d.root.pid)", isDocker: false, kind: kind, title: title,
                launch: d.labels.first ?? "", command: d.root.command, chain: d.labels,
                cwd: cwd, started: d.root.started, origin: origin, tty: d.tty,
                ports: d.ports.sorted { $0.port < $1.port }, pids: pids, rootPid: d.root.pid,
                container: nil, category: category,
                canStop: d.root.uid == myUid && d.root.pid > 1 && d.root.pid != getpid(),
                tenants: nil))
        }

        // Sous-domaines *.localhost pour les projets multi-sites (template-garderie).
        for i in servers.indices where servers[i].category == .dev && servers[i].kind == "Next.js" {
            servers[i].tenants = garderieTenants(servers[i].cwd, docker: docker.byPort)
        }

        servers.sort {
            ($0.category.rawValue, $0.ports.first?.port ?? 0) < ($1.category.rawValue, $1.ports.first?.port ?? 0)
        }
        return ScanResult(servers: servers, dockerRunning: docker.running)
    }

    // MARK: Arrêt

    /// Encore en vie ? (sans relancer tout le balayage)
    static func isAlive(_ s: Server) -> Bool {
        if let c = s.container {
            return !run(["docker", "ps", "-q", "--filter", "id=\(c.id)"], timeout: 3).out
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return s.pids.contains { kill($0, 0) == 0 }
    }

    /// Relit l'état réel et n'agit que sur ce qui tourne encore, tel quel (même PID, même heure de démarrage).
    static func stop(_ target: Server, force: Bool) -> String? {
        guard let s = scan().servers.first(where: { $0.id == target.id && $0.started == target.started }) else { return nil }
        guard s.canStop else { return "Ce serveur ne peut pas être arrêté d’ici." }
        if let c = s.container {
            let r = run(["docker", force ? "kill" : "stop", c.id], timeout: 30)
            return r.ok ? nil : "Échec de docker \(force ? "kill" : "stop")."
        }
        var errors: [String] = []
        for pid in s.pids where pid > 1 && pid != getpid() {
            if kill(pid, force ? SIGKILL : SIGTERM) != 0 && errno != ESRCH { errors.append("\(pid)") }
        }
        return errors.isEmpty ? nil : "Impossible d’arrêter : \(errors.joined(separator: ", "))"
    }
}

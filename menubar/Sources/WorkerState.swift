import SwiftUI
import ServiceManagement

/// What the worker is doing, from the box's container state, its log and the network's standing.
enum Phase: Equatable {
    case dockerDown
    case stopped
    case starting
    case stopping
    case reconnecting
    case checking
    case holding(String)
    case paused(String)
    /// Paused by the wallet that holds the seat: it finishes what it is running and takes nothing new.
    case held
    case idle
    case working(Int)
    /// Another machine of the wallet's that is not connected; when it was last heard from.
    case offline(Date?)
}

/// The worker's own heartbeat, logged every thirty seconds:
/// `alive 5m · 1 task running · 3 submitted · fleet 1016 online, 1029 enrolled · …notes`
struct Heartbeat: Equatable {
    var connected: Bool
    var uptime: String
    var running: Int
    var submitted: Int
    var online: Int?
    var notes: [String]
}

/// A second runtime on the same seat, from the heartbeat: "grok for X work", or "grok off: why".
struct Companion: Equatable {
    let name: String
    let ready: Bool
    let detail: String

    static func from(_ notes: [String]) -> Companion? {
        for note in notes {
            if let range = note.range(of: "^\\w+ for X work$", options: .regularExpression) {
                return Companion(name: String(note[range].split(separator: " ")[0]).capitalizedFirst, ready: true, detail: "for X work")
            }
            if let range = note.range(of: "^\\w+ off: ", options: .regularExpression) {
                let name = String(note[range].split(separator: " ")[0]).capitalizedFirst
                return Companion(name: name, ready: false, detail: String(note[range.upperBound...]))
            }
        }
        return nil
    }
}

struct Job: Identifiable, Equatable {
    let id: String
    let objective: String
    var node: String? = nil
    var role: String? = nil
    var since: Date? = nil

    /// The step the network gave this machine, in words: `site_content_check` is "Site content check".
    var title: String {
        guard let node else { return role.map { $0.capitalizedFirst } ?? "A job" }
        if let name = Job.names[node] { return name }
        if node.hasPrefix("audit_") { return node.dropFirst(6).replacingOccurrences(of: "_", with: " ").capitalizedFirst + " audit" }
        return node.replacingOccurrences(of: "_", with: " ").capitalizedFirst
    }

    static let names = [
        "oracle_assess": "Oracle question", "design_critic": "Design review", "site_content_check": "Site content check",
        "adversarial_review": "Adversarial review", "audit_judge": "Audit judging", "audit_imported_code": "Imported code audit",
        "build_contract_project": "Contract build", "frontend_for_contract": "Frontend build", "research_report": "Research report",
        "manifest": "Launch manifest", "build_website": "Website build", "implement_contract": "Contract build",
        "write_foundry_tests": "Contract tests", "fix_findings": "Fixing findings", "create_image": "Image", "create_video": "Video",
    ]
}

/// The seat's record across every machine it has run on. No success rate: a run that fails is mostly the network's or
/// the requester's doing, not the agent's, and a percent that mixes them tells an owner nothing to act on.
struct SeatStats: Equatable {
    var today: Int
    var accepted: Int
}

/// One line of the activity list: "9:13 PM", "Took a review job".
struct Activity: Identifiable, Equatable {
    let id: Int
    let time: String
    let text: String
}

@MainActor
final class WorkerState: ObservableObject {
    static let shared = WorkerState()

    @Published var phase: Phase = .starting
    @Published var heartbeat: Heartbeat?
    @Published var jobs: [Job] = []
    @Published var step: String?
    @Published var recent: [String] = []
    @Published var activity: [Activity] = []
    @Published var stats: SeatStats?
    @Published var companion: Companion?
    @Published var startingDocker = false
    @Published var confirmingStop = false
    @Published var showingActivity = false
    @Published var tokenId: String? = UserDefaults.standard.string(forKey: "tokenId")
    @Published var problem: String?
    @Published var openAtLogin = SMAppService.mainApp.status == .enabled
    /// Whether this Mac runs an agent in the box at all; without one the menu shows only the wallets' agents.
    @Published var hasBox = FileManager.default.fileExists(atPath: (NSHomeDirectory() as NSString).appendingPathComponent("Documents/GitHub/imd-worker-box/box"))

    /// The box this app drives: `~/Documents/GitHub/imd-worker-box`.
    let boxDir = (NSHomeDirectory() as NSString).appendingPathComponent("Documents/GitHub/imd-worker-box")
    let container = "imd-worker"
    let explorer = "https://explorer.imd.fun"
    var api: String { Plane.api }

    private var panelOpen = false
    private var acting = false
    private var loop: Task<Void, Never>?
    private var lastStanding = Date.distantPast
    private var lastSeat = Date.distantPast
    private var deviceKey: String? = UserDefaults.standard.string(forKey: "deviceKey")

    // MARK: lifecycle

    func start() {
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                await self?.refreshFleet()
                // Quick while the panel is open, light while it is closed: the icon still updates.
                let seconds: UInt64 = (self?.panelOpen ?? false) ? 3 : 15
                try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            }
        }
    }

    func setPanelOpen(_ open: Bool) {
        panelOpen = open
        if open {
            lastStanding = .distantPast
            Task { await refresh() }
        }
    }

    // MARK: reading

    func refresh() async {
        guard !acting else { return }
        let inspect = await Shell.run([Shell.docker, "inspect", "-f", "{{.State.Status}}", container], timeout: 15)
        hasBox = inspect.status == 0 || FileManager.default.fileExists(atPath: "\(boxDir)/box")
        if inspect.status != 0 {
            heartbeat = nil; jobs = []; step = nil
            phase = Shell.dockerIsDown(inspect.output) ? .dockerDown : .stopped
            return
        }
        guard inspect.output.trimmingCharacters(in: .whitespacesAndNewlines) == "running" else {
            heartbeat = nil; jobs = []; step = nil
            phase = .stopped
            return
        }

        let logs = await Shell.run([Shell.docker, "logs", "--tail", "200", container], timeout: 15)
        let parsed = LogReading(logs.output)
        heartbeat = parsed.heartbeat
        companion = parsed.heartbeat.flatMap { Companion.from($0.notes) }
        step = parsed.step
        recent = parsed.recent
        activity = parsed.activity

        if Date().timeIntervalSince(lastStanding) > (panelOpen ? 10 : 60) {
            lastStanding = Date()
            await readStanding()
        }
        if tokenId != nil, Date().timeIntervalSince(lastSeat) > (panelOpen ? 60 : 300) {
            lastSeat = Date()
            await readSeat()
        }

        phase = Self.phase(from: parsed, jobs: jobs, paused: pausedNote, held: heldByOwner)
    }

    /// The wallet's other agents, after this Mac's own state is read.
    func refreshFleet() async {
        await Fleet.shared.refresh(localToken: tokenId, open: panelOpen)
    }

    private var pausedNote: String?
    /// Whether the seat's holder has paused it, from the network's standing.
    private var heldByOwner = false

    /// The network's view of this device: pauses, and the jobs it is running (with their objectives).
    private func readStanding() async {
        if deviceKey == nil {
            // As the box's user: root in the box has no capabilities, so it cannot read the worker's config.
            let who = await Shell.run([Shell.docker, "exec", "-u", "imd", container, "imd", "whoami"], timeout: 20)
            let key = who.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if who.status == 0, key.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil {
                deviceKey = key
                UserDefaults.standard.set(key, forKey: "deviceKey")
            }
        }
        guard let key = deviceKey, let url = URL(string: "\(api)/workers/\(key)/standing") else { return }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        if let enrollment = json["enrollment"] as? [String: Any], let token = enrollment["tokenId"] as? String {
            tokenId = token
            UserDefaults.standard.set(token, forKey: "tokenId")
        }
        let standing = json["standing"] as? [String: Any]
        jobs = (standing?["running"] as? [[String: Any]] ?? []).compactMap { row in
            guard let id = row["jobId"] as? String else { return nil }
            let since = (row["since"] as? String).flatMap { ISO8601DateFormatter.withFraction.date(from: $0) ?? ISO8601DateFormatter().date(from: $0) }
            return Job(id: id, objective: (row["objective"] as? String) ?? "A job", node: row["nodeKey"] as? String, role: row["role"] as? String, since: since)
        }
        heldByOwner = (standing?["pausedByOwnerAt"] as? String) != nil
        if let until = standing?["pausedUntil"] as? String, let date = ISO8601DateFormatter.withFraction.date(from: until) ?? ISO8601DateFormatter().date(from: until), date > Date() {
            let reason = (standing?["pausedFor"] as? String).map { ": \($0)" } ?? ""
            pausedNote = "Until \(date.formatted(date: .omitted, time: .shortened))\(reason)"
        } else {
            pausedNote = nil
        }
    }

    /// The seat's record: what it did today and how much was accepted.
    private func readSeat() async {
        guard let token = tokenId, let url = URL(string: "\(api)/seats/\(token)?collaborators=0"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        stats = Fleet.stats(from: json)
    }

    static func phase(from log: LogReading, jobs: [Job], paused: String?, held: Bool = false) -> Phase {
        if let paused { return .paused(paused) }
        guard let beat = log.heartbeat else {
            // No heartbeat yet: the first thirty seconds after a start.
            return log.selfTesting ? .checking : .starting
        }
        if !beat.connected { return .reconnecting }
        if let fault = beat.notes.first(where: { $0.hasPrefix("taking no work") }) {
            return .holding(fault.replacingOccurrences(of: "taking no work: ", with: "").capitalizedFirst)
        }
        if beat.notes.contains(where: { $0.hasPrefix("holding work") }) { return .holding("Rate limited, waiting to retry") }
        if beat.notes.contains(where: { $0.contains("self-testing") || $0.contains("checking the runtime") }) { return .checking }
        let running = max(beat.running, log.acceptedSinceBeat ? 1 : 0, jobs.count)
        // Paused by its holder, it still finishes what it holds, and says it is working until then.
        return running > 0 ? .working(running) : held ? .held : .idle
    }

    // MARK: acting

    var isRunning: Bool {
        switch phase { case .dockerDown, .stopped, .stopping, .offline: return false; default: return true }
    }

    var isWorking: Bool { if case .working = phase { return true } else { return false } }

    /// S, or the switch: start, or stop, asking first when a job would be dropped.
    func toggle() {
        if isRunning { requestStop() } else { startWorker() }
    }

    func requestStop() {
        if isWorking { withAnimation(.spring(response: 0.3, dampingFraction: 1)) { confirmingStop = true } } else { stop() }
    }

    func startWorker() {
        guard !acting else { return }
        acting = true
        problem = nil
        let dockerWasDown = phase == .dockerDown
        phase = .starting
        Task {
            if dockerWasDown {
                startingDocker = true
                defer { startingDocker = false }
                _ = await Shell.run(["/usr/bin/open", "-a", "Docker"], timeout: 10)
                var up = false
                for _ in 0..<60 {
                    if await Shell.run([Shell.docker, "info"], timeout: 10).status == 0 { up = true; break }
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                }
                if !up { problem = "Docker didn't start. Open Docker Desktop and try again." }
            }
            if problem == nil {
                let result = await Shell.run(["/bin/bash", "\(boxDir)/box", "start"], timeout: 120)
                if result.status != 0 { problem = result.output.lastLine }
            }
            acting = false
            await refresh()
        }
    }

    func stop() {
        confirmingStop = false
        guard !acting else { return }
        acting = true
        problem = nil
        phase = .stopping
        Task {
            let result = await Shell.run(["/bin/bash", "\(boxDir)/box", "stop"], timeout: 60)
            if result.status != 0 { problem = result.output.lastLine }
            acting = false
            await refresh()
        }
    }

    func openAgentPage() {
        let path = tokenId.map { "/agents/\($0)" } ?? ""
        if let url = URL(string: explorer + path) { NSWorkspace.shared.open(url) }
    }

    func openJob(_ job: Job) {
        if let url = URL(string: "\(explorer)/jobs/\(job.id)") { NSWorkspace.shared.open(url) }
    }

    func setOpenAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            problem = "Couldn't change Open at Login: \(error.localizedDescription)"
        }
        openAtLogin = SMAppService.mainApp.status == .enabled
    }
}

// MARK: - The log, read

struct LogReading {
    var heartbeat: Heartbeat?
    /// The current task's latest step: "Working: running claude on claude-fable-5-1".
    var step: String?
    /// A task was accepted after the last heartbeat, which can be thirty seconds old.
    var acceptedSinceBeat = false
    var selfTesting = false
    /// The last few events, not heartbeats, as "14:02  submitted review for 6a823499".
    var recent: [String] = []
    /// The same events in plain words, without the bookkeeping.
    var activity: [Activity] = []

    init(_ text: String) {
        var events: [(String, String)] = []
        var lastTaskStep: String?
        var inTask = false
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let (time, message) = Self.split(String(raw))
            if let beat = Self.heartbeat(message) {
                heartbeat = beat
                acceptedSinceBeat = false
                continue
            }
            if message.hasPrefix("accepted ") { inTask = true; acceptedSinceBeat = true; lastTaskStep = nil }
            if message.hasPrefix("submitted ") || message.hasPrefix("cancelled ") || message.hasPrefix("task failed") { inTask = false; lastTaskStep = nil }
            // "rate limit cleared" and its kin say nothing about the work; the agent's own lines do.
            let noise = message.range(of: "^  \\w+: rate limit", options: .regularExpression) != nil
            if noise { continue }
            if inTask, let range = message.range(of: "^  (\\w+): ", options: .regularExpression) {
                let phase = message[range].trimmingCharacters(in: .whitespaces).dropLast()
                _ = phase
                let text = String(message[range.upperBound...])
                lastTaskStep = text.hasPrefix("running claude") ? "Claude is on it" : text.capitalizedFirst
            }
            if message.hasPrefix("self-test: asking") { selfTesting = true }
            else if message.hasPrefix("self-test") { selfTesting = false }
            events.append((time, message.trimmingCharacters(in: .whitespaces)))
        }
        step = inTask ? lastTaskStep : nil
        recent = events.suffix(8).map { "\($0.0)  \($0.1)" }
        activity = events.compactMap { time, message in Self.plain(message).map { (time, $0) } }
            .suffix(6).enumerated().map { Activity(id: $0.offset, time: $0.element.0, text: $0.element.1) }
    }

    /// A log line in plain words, or nil for bookkeeping nobody needs to read.
    static func plain(_ message: String) -> String? {
        let m = message.trimmingCharacters(in: .whitespaces)
        if m.hasPrefix("accepted question") { return "Took a research question" }
        if m.hasPrefix("accepted ") { return "Took a \(m.split(separator: " ").dropFirst().first ?? "new") job" }
        if m.hasPrefix("submitted ") { return "Submitted the \(m.split(separator: " ").dropFirst().first ?? "work")" }
        if m.hasPrefix("cancelled ") { return "Cancelled" + (m.split(separator: ":", maxSplits: 1).dropFirst().first.map { ":\($0)" } ?? "") }
        if m.hasPrefix("task failed") { return "Failed" + (m.split(separator: ":", maxSplits: 1).dropFirst().first.map { ":\($0)" } ?? "") }
        if m.hasPrefix("connected to") { return "Connected" }
        if m.hasPrefix("server closed") { return "Network restarting" }
        if m.hasPrefix("self-test passed") {
            let seconds = m.range(of: "in [0-9.]+s", options: .regularExpression).map { String(m[$0].dropFirst(3)) }
            return "Claude check passed" + (seconds.map { " (\($0))" } ?? "")
        }
        if m.hasPrefix("self-test: asking") { return "Checking Claude" }
        if m.hasPrefix("self-test") { return m.replacingOccurrences(of: "self-test: ", with: "").capitalizedFirst }
        if let range = m.range(of: "^\\w+: ", options: .regularExpression), ["preparing", "working", "checking", "bundling", "uploading", "planning"].contains(String(m[range].dropLast(2))) {
            let text = String(m[range.upperBound...])
            if text.hasPrefix("rate limit") { return nil }
            return text.hasPrefix("running claude") ? "Claude started" : text.capitalizedFirst
        }
        if m.hasPrefix("installed ") || m.hasPrefix("updated ") || m.hasPrefix("restarting to") { return m.capitalizedFirst }
        return nil
    }

    /// "2026-10-13T02:13:37.755Z   working: …" into ("02:13", "  working: …"), in local time.
    static func split(_ line: String) -> (String, String) {
        guard line.count > 25, let space = line.firstIndex(of: " "),
              let date = ISO8601DateFormatter.withFraction.date(from: String(line[..<space])) else { return ("", line) }
        let message = String(line[line.index(after: space)...])
        return (date.formatted(date: .omitted, time: .shortened), message)
    }

    static func heartbeat(_ message: String) -> Heartbeat? {
        let parts = message.components(separatedBy: " · ")
        guard parts.count >= 3, let head = parts.first else { return nil }
        let words = head.split(separator: " ")
        guard words.count == 2, words[0] == "alive" || words[0] == "disconnected" else { return nil }
        let running = parts[1] == "idle" ? 0 : Int(parts[1].split(separator: " ").first ?? "") ?? 0
        let submitted = Int(parts[2].split(separator: " ").first ?? "") ?? 0
        var online: Int?
        var notes: [String] = []
        for part in parts.dropFirst(3) {
            if part.hasPrefix("fleet ") { online = Int(part.split(separator: " ")[1]) } else { notes.append(part) }
        }
        return Heartbeat(connected: words[0] == "alive", uptime: String(words[1]), running: running, submitted: submitted, online: online, notes: notes)
    }
}

// MARK: - Shell

enum Shell {
    /// GUI apps start with a bare PATH; Docker Desktop's CLI lives in one of these.
    static let path = "/usr/local/bin:/opt/homebrew/bin:/Applications/Docker.app/Contents/Resources/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    static let docker: String = ["/usr/local/bin/docker", "/opt/homebrew/bin/docker", "/Applications/Docker.app/Contents/Resources/bin/docker"]
        .first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/usr/local/bin/docker"

    static func dockerIsDown(_ output: String) -> Bool {
        output.contains("Cannot connect to the Docker daemon") || output.contains("Is the docker daemon running") || output.contains("docker.sock")
    }

    static func run(_ args: [String], timeout: TimeInterval) async -> (status: Int32, output: String) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: args[0])
                process.arguments = Array(args.dropFirst())
                var env = ProcessInfo.processInfo.environment
                env["PATH"] = path
                process.environment = env
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                do { try process.run() } catch {
                    continuation.resume(returning: (-1, error.localizedDescription))
                    return
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if process.isRunning { process.terminate() } }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: (process.terminationStatus, String(decoding: data, as: UTF8.self)))
            }
        }
    }
}

extension ISO8601DateFormatter {
    static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
    var lastLine: String {
        split(separator: "\n").last.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? self
    }
}

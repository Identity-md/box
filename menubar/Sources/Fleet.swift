import SwiftUI

/// One of the wallet's agents, as the network sees it: any machine, anywhere (this Mac's box, a
/// Mac mini at home, a VPS). Everything here is public; nothing needs the machine to be reachable.
struct Agent: Identifiable, Equatable {
    let tokenId: String
    /// The wallet that holds it, of the ones this app watches or is connected to.
    var wallet: String?
    /// Paused by that wallet: it takes no new work until the wallet resumes it.
    var pausedByOwner = false
    var deviceKey: String?
    var connected = false
    var working = 0
    var pausedUntil: Date?
    var pausedFor: String?
    var runtimes: [String] = []
    var lastHeartbeat: Date?
    var jobs: [Job] = []
    var stats: SeatStats?
    var id: String { tokenId }
}

/// Every agent the wallet owns, read from the network's public API.
///
/// The wallet comes from this Mac's own agent (its seat's owner), so there is nothing to set up. The
/// list of seats is the wallet's pairing record; each seat's device key comes from the fleet listing,
/// read once because it is large and changes only when a seat is paired again; live state comes from
/// each device's small standing record.
@MainActor
final class Fleet: ObservableObject {
    static let shared = Fleet()

    @Published var owner: String? = UserDefaults.standard.string(forKey: "owner")
    @Published var agents: [Agent] = []
    @Published var names: [String: String] = (UserDefaults.standard.dictionary(forKey: "agentNames") as? [String: String]) ?? [:]

    private var api: String { Plane.api }
    private var deviceKeys: [String: String] = (UserDefaults.standard.dictionary(forKey: "deviceKeys") as? [String: String]) ?? [:]
    private var lastSeats = Date.distantPast
    private var lastStats = Date.distantPast
    private var lastLive = Date.distantPast
    private var lastWatched: [String] = []

    func name(for agent: Agent, localToken: String?) -> String {
        if let custom = names[agent.tokenId], !custom.isEmpty { return custom }
        return agent.tokenId == localToken ? "This Mac" : "Agent \(agent.tokenId)"
    }

    func rename(_ tokenId: String, to name: String) {
        names[tokenId] = name.trimmingCharacters(in: .whitespaces)
        UserDefaults.standard.set(names, forKey: "agentNames")
    }

    func setOwner(_ address: String) {
        let trimmed = address.trimmingCharacters(in: .whitespaces).lowercased()
        guard trimmed.range(of: "^0x[0-9a-f]{40}$", options: .regularExpression) != nil else { return }
        owner = trimmed
        UserDefaults.standard.set(trimmed, forKey: "owner")
        lastSeats = .distantPast
    }

    func refresh(localToken: String?, open: Bool) async {
        if owner == nil, let token = localToken, let seat = await json("/seats/\(token)?collaborators=0") as? [String: Any],
           let found = seat["owner"] as? String {
            setOwner(found)
        }
        // Every wallet this app knows: the one its own agent's seat belongs to, and each that connected it.
        var watched: [String] = []
        for wallet in [owner].compactMap({ $0 }) + Connection.shared.wallets where !watched.contains(wallet) { watched.append(wallet) }
        guard !watched.isEmpty else { agents = []; return }

        // The wallets' seats, and which device each is on (a 16-character prefix here).
        // Read again on the usual clock, and at once when a wallet connects or goes.
        if Date().timeIntervalSince(lastSeats) > (open ? 30 : 300) || agents.isEmpty || watched != lastWatched {
            lastSeats = Date()
            lastWatched = watched
            var next: [Agent] = []
            var prefixes: [String: String] = [:]
            for wallet in watched {
                guard let pairing = await json("/pair/wallet/\(wallet)") as? [String: Any],
                      let tokens = pairing["tokens"] as? [[String: Any]] else { continue }
                for row in tokens {
                    guard let token = row["tokenId"] as? String, !next.contains(where: { $0.tokenId == token }) else { continue }
                    let device = row["device"] as? [String: Any]
                    var agent = agents.first { $0.tokenId == token } ?? Agent(tokenId: token)
                    agent.wallet = wallet
                    agent.connected = device?["online"] as? Bool ?? false
                    prefixes[token] = device?["key"] as? String
                    next.append(agent)
                }
            }
            // A seat paired again since last time has a new device; its key is looked up once.
            let known = { (token: String) -> String? in
                guard let prefix = prefixes[token], let key = self.deviceKeys[token], key.hasPrefix(prefix) else { return nil }
                return key
            }
            if next.contains(where: { prefixes[$0.tokenId] != nil && known($0.tokenId) == nil }) {
                await learnDeviceKeys(for: next.map(\.tokenId))
            }
            agents = next.map { agent in var a = agent; a.deviceKey = known(a.tokenId); return a }
                .sorted { Int($0.tokenId) ?? 0 < Int($1.tokenId) ?? 0 }
        }

        // Live state for each, from its own small record.
        if Date().timeIntervalSince(lastLive) > (open ? 8 : 45) {
        lastLive = Date()
        for i in agents.indices {
            guard let key = agents[i].deviceKey, let standing = await json("/workers/\(key)/standing?queue=0") as? [String: Any] else { continue }
            let presence = standing["presence"] as? [String: Any]
            let record = standing["standing"] as? [String: Any]
            agents[i].connected = presence?["connected"] as? Bool ?? false
            agents[i].working = record?["working"] as? Int ?? 0
            agents[i].runtimes = (presence?["runtimes"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
            agents[i].lastHeartbeat = (presence?["lastHeartbeatAt"] as? String).flatMap(Self.date)
            agents[i].pausedUntil = (record?["pausedUntil"] as? String).flatMap(Self.date).flatMap { $0 > Date() ? $0 : nil }
            agents[i].pausedFor = record?["pausedFor"] as? String
            agents[i].pausedByOwner = (record?["pausedByOwnerAt"] as? String) != nil
            agents[i].jobs = (record?["running"] as? [[String: Any]] ?? []).compactMap { row in
                guard let id = row["jobId"] as? String else { return nil }
                return Job(id: id, objective: (row["objective"] as? String) ?? "A job", node: row["nodeKey"] as? String,
                           role: row["role"] as? String, since: (row["since"] as? String).flatMap(Self.date))
            }
        }
        }

        // Each seat's record, a few times an hour: what it did today, accepted, success.
        if Date().timeIntervalSince(lastStats) > (open ? 60 : 600) {
            lastStats = Date()
            for i in agents.indices {
                guard let seat = await json("/seats/\(agents[i].tokenId)?collaborators=0") as? [String: Any] else { continue }
                agents[i].stats = Self.stats(from: seat)
            }
        }
    }

    /// Pauses or resumes one of the wallets' agents from its row: shown at once, sent signed with this
    /// Mac's key, put back if the network says no, and read again either way.
    func setPaused(_ paused: Bool, tokenId: String) {
        guard let i = agents.firstIndex(where: { $0.tokenId == tokenId }) else { return }
        let was = agents[i].pausedByOwner
        agents[i].pausedByOwner = paused
        Task {
            let taken = await Connection.shared.setPaused(paused, tokenId: tokenId)
            if !taken, let j = agents.firstIndex(where: { $0.tokenId == tokenId }) { agents[j].pausedByOwner = was }
            lastLive = .distantPast
        }
    }

    /// All the agents' records together, for the numbers under the list.
    var combined: SeatStats? {
        let all: [SeatStats] = agents.compactMap { $0.stats }
        guard !all.isEmpty else { return nil }
        return SeatStats(today: all.reduce(0) { $0 + $1.today }, accepted: all.reduce(0) { $0 + $1.accepted })
    }

    /// The device keys for these seats, from the fleet listing: large, so read only when one is new.
    private func learnDeviceKeys(for tokens: [String]) async {
        guard let listing = await json("/workers?fields=seat") as? [String: Any], let workers = listing["workers"] as? [[String: Any]] else { return }
        for worker in workers {
            guard let token = (worker["seat"] as? [String: Any])?["tokenId"] as? String, tokens.contains(token),
                  let key = worker["deviceKey"] as? String else { continue }
            deviceKeys[token] = key
        }
        UserDefaults.standard.set(deviceKeys, forKey: "deviceKeys")
    }

    static func stats(from seat: [String: Any]) -> SeatStats {
        let today = (seat["work"] as? [[String: Any]] ?? []).filter { row in
            (row["submittedAt"] as? String).flatMap(date).map { Calendar.current.isDateInToday($0) } ?? false
        }.count
        return SeatStats(today: today, accepted: seat["accepted"] as? Int ?? 0)
    }

    static func date(_ text: String) -> Date? {
        ISO8601DateFormatter.withFraction.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    private func json(_ path: String) async -> Any? {
        guard let url = URL(string: api + path), let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }
}

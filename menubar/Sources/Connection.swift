import AppKit
import CryptoKit
import Security

/// Where the app reads and writes. The public network unless a developer points it elsewhere
/// (`defaults write fun.imd.workerbar api http://127.0.0.1:3298`).
enum Plane {
    static var api: String { UserDefaults.standard.string(forKey: "api") ?? "https://api.imd.fun" }
    static var explorer: String { UserDefaults.standard.string(forKey: "explorer") ?? "https://explorer.imd.fun" }

    static func request(_ method: String, _ path: String, body: [String: Any]? = nil) async -> (status: Int, json: [String: Any]?) {
        guard let url = URL(string: api + path) else { return (0, nil) }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = method
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        guard let (data, response) = try? await URLSession.shared.data(for: request) else { return (0, nil) }
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, try? JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

/// This Mac's key for pausing and resuming the agents a wallet links it to. Made in the Secure
/// Enclave where the Mac has one, so it cannot be copied off this machine; kept in the Keychain as
/// the enclave's own encrypted handle. All it can do is sign a pause or a resume.
struct AppKey {
    private enum Backing {
        case enclave(SecureEnclave.P256.Signing.PrivateKey)
        case software(P256.Signing.PrivateKey)
    }
    private let backing: Backing
    private static let account = "app-key"

    /// The key, made the first time it is asked for.
    static func current() -> AppKey? {
        if let stored = Keychain.read(account) {
            if let key = try? SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: stored) { return AppKey(backing: .enclave(key)) }
            if let key = try? P256.Signing.PrivateKey(rawRepresentation: stored) { return AppKey(backing: .software(key)) }
        }
        if SecureEnclave.isAvailable, let key = try? SecureEnclave.P256.Signing.PrivateKey() {
            return Keychain.write(account, key.dataRepresentation) ? AppKey(backing: .enclave(key)) : nil
        }
        let key = P256.Signing.PrivateKey()
        return Keychain.write(account, key.rawRepresentation) ? AppKey(backing: .software(key)) : nil
    }

    /// Forgets the key, so the next connection makes a new one.
    static func forget() { Keychain.delete(account) }

    var inEnclave: Bool { if case .enclave = backing { return true } else { return false } }

    /// DER SubjectPublicKeyInfo, base64: what the network knows this Mac by.
    var publicKey: String {
        switch backing {
        case .enclave(let key): return key.publicKey.derRepresentation.base64EncodedString()
        case .software(let key): return key.publicKey.derRepresentation.base64EncodedString()
        }
    }

    /// ECDSA P-256 over the text, DER, base64.
    func sign(_ text: String) throws -> String {
        let data = Data(text.utf8)
        switch backing {
        case .enclave(let key): return try key.signature(for: data).derRepresentation.base64EncodedString()
        case .software(let key): return try key.signature(for: data).derRepresentation.base64EncodedString()
        }
    }

    /// One action as the network reads it: lines of text, so this and the server build the same bytes.
    static func actionText(_ action: String, tokenId: String?, nonce: String, issuedAt: Int, relayOrigin: String) -> String {
        ["IMD app v1", action, tokenId ?? "-", nonce, String(issuedAt), relayOrigin].joined(separator: "\n")
    }

    static func nonce() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

/// The login keychain, for the one item this app keeps there.
enum Keychain {
    private static let service = "fun.imd.workerbar"

    static func read(_ account: String) -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true]
        var result: AnyObject?
        return SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess ? result as? Data : nil
    }

    @discardableResult
    static func write(_ account: String, _ data: Data) -> Bool {
        delete(account)
        let item: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: account, kSecValueData as String: data,
                                   kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                                   kSecAttrLabel as String: "IMD Worker key"]
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    static func delete(_ account: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
    }
}

/// Which wallets have connected this Mac, and the connecting itself: a code, a page in the browser
/// where the holder approves it with one signature, and the app watching the code until they do.
/// A connection does not expire; it ends when this Mac disconnects or a wallet unlinks it, and it
/// reaches only the seats a wallet holds when each pause is sent.
@MainActor
final class Connection: ObservableObject {
    static let shared = Connection()

    /// Wallets that approved this Mac, lower case.
    @Published private(set) var wallets: [String] = UserDefaults.standard.stringArray(forKey: "linkedWallets") ?? []
    /// The code shown while a holder approves it in the browser.
    @Published private(set) var waiting: (code: String, until: Date)?
    @Published var problem: String?
    /// Seats a switch is being sent for, so the row can say so and refuse a second click.
    @Published private(set) var sending: Set<String> = []

    private var relayOrigin: String? = UserDefaults.standard.string(forKey: "relayOrigin")
    private var watch: Task<Void, Never>?

    var isWaiting: Bool { waiting != nil }

    /// For the review renders: a connection as if made, nothing saved.
    func preview(wallets: [String], waiting: (code: String, until: Date)?) {
        self.wallets = wallets
        self.waiting = waiting
    }

    func holds(_ wallet: String?) -> Bool {
        guard let wallet else { return false }
        return wallets.contains(wallet.lowercased())
    }

    /// Asks for a code, opens the approval page, and watches the code for ten minutes.
    func connect() {
        guard waiting == nil else { return reopen() }
        problem = nil
        watch?.cancel()
        watch = Task { [weak self] in await self?.run() }
    }

    func cancel() {
        watch?.cancel()
        watch = nil
        waiting = nil
    }

    private func reopen() {
        guard let code = waiting?.code, let url = URL(string: "\(Plane.explorer)/link?code=\(code)") else { return }
        NSWorkspace.shared.open(url)
    }

    private func run() async {
        guard let key = AppKey.current() else { problem = "Could not make this Mac's key"; return }
        let started = await Plane.request("POST", "/app-links", body: ["appKey": key.publicKey, "name": Self.name])
        guard started.status == 200, let code = started.json?["code"] as? String else {
            problem = started.status == 0 ? "The network did not answer"
                : started.status == 404 ? "Connecting is not live on the network yet"
                : "Could not start connecting (\(started.status))"
            return
        }
        if let origin = started.json?["relayOrigin"] as? String { remember(origin: origin) }
        waiting = (code, Date().addingTimeInterval(10 * 60))
        reopen()
        while !Task.isCancelled, let until = waiting?.until, Date() < until {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            let read = await Plane.request("GET", "/app-links/\(code)")
            guard let status = read.json?["status"] as? String else { continue }
            if status == "linked", let wallet = (read.json?["wallet"] as? String)?.lowercased() {
                add(wallet)
                waiting = nil
                NSApp.activate(ignoringOtherApps: true)
                return
            }
            if status == "expired" { break }
        }
        if !Task.isCancelled, waiting != nil { problem = "The code expired before it was approved" }
        waiting = nil
    }

    /// Unlinks this Mac from every wallet, and forgets its key.
    func disconnect() async {
        problem = nil
        if let key = AppKey.current(), let origin = relayOrigin, !wallets.isEmpty {
            let nonce = AppKey.nonce(), issuedAt = Int(Date().timeIntervalSince1970)
            let text = AppKey.actionText("unlink", tokenId: nil, nonce: nonce, issuedAt: issuedAt, relayOrigin: origin)
            if let signature = try? key.sign(text) {
                let answer = await Plane.request("POST", "/app-links/unlink", body: ["app": ["key": key.publicKey, "nonce": nonce, "issuedAt": issuedAt, "relayOrigin": origin, "signature": signature]])
                // A link the network no longer has is as gone as one it just removed.
                if answer.status != 200 && answer.status != 404 {
                    problem = answer.status == 0 ? "The network did not answer; try again" : "Could not disconnect (\(answer.status))"
                    return
                }
            }
        }
        AppKey.forget()
        wallets = []
        UserDefaults.standard.removeObject(forKey: "linkedWallets")
    }

    /// Pauses or resumes one seat, signed with this Mac's key. True when the network took it.
    func setPaused(_ paused: Bool, tokenId: String) async -> Bool {
        guard !sending.contains(tokenId) else { return false }
        guard let key = AppKey.current(), let origin = relayOrigin else { problem = "Connect a wallet first"; return false }
        sending.insert(tokenId)
        defer { sending.remove(tokenId) }
        let nonce = AppKey.nonce(), issuedAt = Int(Date().timeIntervalSince1970)
        let text = AppKey.actionText(paused ? "pause" : "resume", tokenId: tokenId, nonce: nonce, issuedAt: issuedAt, relayOrigin: origin)
        guard let signature = try? key.sign(text) else { problem = "This Mac's key could not sign"; return false }
        let answer = await Plane.request("POST", "/seats/\(tokenId)/pause", body: ["app": ["key": key.publicKey, "paused": paused, "nonce": nonce, "issuedAt": issuedAt, "relayOrigin": origin, "signature": signature]])
        if answer.status == 200 { problem = nil; return true }
        switch answer.json?["error"] as? String {
        case "app_not_linked":
            // Unlinked from the explorer: the switch goes, and the menu says why.
            wallets = []
            UserDefaults.standard.removeObject(forKey: "linkedWallets")
            problem = "This Mac was disconnected. Connect again to switch agents."
        case "not_token_owner": problem = "That wallet no longer holds agent \(tokenId)"
        case "issued_in_future": problem = "This Mac's clock is ahead; set it automatically and try again"
        case "ownership_unavailable": problem = "The chain could not be read; try again in a minute"
        default: problem = answer.status == 0 ? "The network did not answer" : "Could not switch agent \(tokenId) (\(answer.status))"
        }
        return false
    }

    private func add(_ wallet: String) {
        if !wallets.contains(wallet) { wallets.append(wallet) }
        UserDefaults.standard.set(wallets, forKey: "linkedWallets")
    }

    private func remember(origin: String) {
        relayOrigin = origin
        UserDefaults.standard.set(origin, forKey: "relayOrigin")
    }

    /// What the approval page calls this app: "IMD Worker on MacBook Pro", never the computer's personal name.
    static var name: String {
        let model = macModel()
        let cleaned = model.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == " " }.map(String.init).joined()
        let name = cleaned.isEmpty ? "IMD Worker" : "IMD Worker on \(cleaned)"
        return String(name.prefix(64))
    }

    private static func macModel() -> String {
        // The name Apple gives the model ("MacBook Pro"), from System Information; a tenth of a second, once.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPHardwareDataType", "-json"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        if (try? process.run()) != nil {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let hardware = (json["SPHardwareDataType"] as? [[String: Any]])?.first,
               let name = hardware["machine_name"] as? String, !name.isEmpty {
                return name
            }
        }
        // Else the family from the model identifier: MacBookPro18,3 is a MacBook Pro; newer ones (Mac15,10) say only Mac.
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var bytes = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &bytes, &size, nil, 0)
        let identifier = String(cString: bytes)
        let families = [("MacBookPro", "MacBook Pro"), ("MacBookAir", "MacBook Air"), ("MacBook", "MacBook"), ("Macmini", "Mac mini"),
                        ("iMacPro", "iMac Pro"), ("iMac", "iMac"), ("MacPro", "Mac Pro"), ("Mac", "Mac")]
        return families.first { identifier.hasPrefix($0.0) }?.1 ?? "Mac"
    }
}

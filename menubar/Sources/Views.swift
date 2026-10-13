import SwiftUI

// Sizes, in one place: 17 for numbers, 13 for titles and rows, 11 for everything secondary.
private enum Type {
    static let number = Font.system(size: 17, weight: .semibold, design: .rounded).monospacedDigit()
    static let title = Font.system(size: 13, weight: .semibold)
    static let row = Font.system(size: 13)
    static let small = Font.system(size: 11)
}

/// A light lift off the popover's material, the way Control Center separates its modules.
private struct Module: ViewModifier {
    func body(content: Content) -> some View {
        content.background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.055)))
    }
}

private let settle = Animation.spring(response: 0.3, dampingFraction: 1)

/// Each agent is its mask, and the lines under it start where its name does.
private enum Row {
    static let mask: CGFloat = 36
    static let indent: CGFloat = mask + 10
}

struct PanelView: View {
    @EnvironmentObject var state: WorkerState
    @ObservedObject var fleet = Fleet.shared
    @ObservedObject var connection = Connection.shared

    /// The wallet's agents other than this Mac's own.
    private var others: [Agent] { fleet.agents.filter { $0.tokenId != state.tokenId } }
    /// Agents whose wallet has not connected this Mac, so they have no switch yet.
    private var unswitchable: Bool { others.contains { !connection.holds($0.wallet) } }
    /// Nothing to show yet: no agent here, and no wallet known.
    private var empty: Bool { !state.hasBox && others.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(others.isEmpty ? "IMD Worker" : "IMD Agents").font(Type.title).padding(.horizontal, 6).padding(.top, 2)

            if empty && !connection.isWaiting {
                ConnectModule()
            } else if !empty {
                VStack(spacing: 0) {
                    if state.hasBox {
                        LocalAgentRow(name: fleet.name(for: Agent(tokenId: state.tokenId ?? "local"), localToken: state.tokenId))
                    }
                    ForEach(Array(others.enumerated()), id: \.element.id) { index, agent in
                        if index > 0 || state.hasBox { Divider().padding(.leading, Row.indent + 10) }
                        RemoteAgentRow(agent: agent, name: fleet.name(for: agent, localToken: state.tokenId), key: keyNumber(forRemote: index))
                    }
                }
                .modifier(Module())
                .animation(settle, value: state.confirmingStop)
            }

            if connection.isWaiting { WaitingModule().transition(.opacity) }
            if let problem = connection.problem {
                Text(problem).font(Type.small).foregroundStyle(.red).padding(.horizontal, 6).fixedSize(horizontal: false, vertical: true)
            }

            if !empty, let stats = fleet.combined ?? state.stats {
                StatsModule(stats: stats, everyAgent: !others.isEmpty)
            }

            Divider().padding(.horizontal, 6).padding(.top, 2)
            VStack(spacing: 0) {
                if !empty {
                    MenuRow(title: others.isEmpty ? "Agent page" : "Agent pages", shortcut: "A", key: "a") { openAgentPages() }
                }
                // The activity is this Mac's own agent's log, so there is none without one.
                if state.hasBox {
                    MenuRow(title: "Activity", shortcut: "L", key: "l", disclosure: state.showingActivity) {
                        withAnimation(settle) { state.showingActivity.toggle() }
                    }
                }
                if state.hasBox && state.showingActivity {
                    ActivityList(items: state.activity)
                        .transition(.opacity.combined(with: .offset(y: -4)))
                }
                if unswitchable && !connection.isWaiting && !empty {
                    MenuRow(title: "Connect Wallet…", shortcut: "C", key: "c") { connection.connect() }
                }
                MenuRow(title: "Open at Login", shortcut: "O", key: "o", checked: state.openAtLogin) {
                    state.setOpenAtLogin(!state.openAtLogin)
                }
                SettingsRow()
            }
            Divider().padding(.horizontal, 6)
            MenuRow(title: "Quit IMD Worker", shortcut: "⌘Q", key: "q", modifiers: .command) { NSApp.terminate(nil) }
        }
        .padding(10)
        .frame(width: 340)
        .animation(settle, value: connection.isWaiting)
        .background {
            // S starts and stops this Mac's agent from anywhere in the panel; 1 to 9 switch the agents in the order listed.
            if state.hasBox {
                Button("") { state.toggle() }
                    .keyboardShortcut("s", modifiers: [])
                    .opacity(0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            ForEach(1..<10) { number in
                Button("") { switchRow(number) }
                    .keyboardShortcut(KeyEquivalent(Character(String(number))), modifiers: [])
                    .opacity(0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }

    /// The number key of a remote agent's row: rows count from 1, this Mac's first when it has one.
    private func keyNumber(forRemote index: Int) -> Int? {
        let number = index + (state.hasBox ? 2 : 1)
        return number <= 9 ? number : nil
    }

    /// A number key: this Mac's agent on and off, or another agent paused and resumed, in the order the rows show.
    private func switchRow(_ number: Int) {
        if state.hasBox && number == 1 { return state.toggle() }
        let index = number - (state.hasBox ? 2 : 1)
        guard others.indices.contains(index) else { return }
        let agent = others[index]
        guard connection.holds(agent.wallet) else { return }
        fleet.setPaused(!agent.pausedByOwner, tokenId: agent.tokenId)
    }

    /// One agent: its own page. Several: the wallet's page, which lists them all.
    private func openAgentPages() {
        if !others.isEmpty, let owner = fleet.owner ?? connection.wallets.first, let url = URL(string: "\(state.explorer)/wallet/\(owner)") {
            NSWorkspace.shared.open(url)
        } else {
            state.openAgentPage()
        }
    }
}

// MARK: - Connecting

/// Nothing to show yet: no agent on this Mac and no wallet. One action, which connects a wallet.
struct ConnectModule: View {
    @ObservedObject private var connection = Connection.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("See your agents").font(Type.title)
            Text("Connect the wallet that holds your agents. You approve it once in your browser, and this Mac can then pause and resume them.")
                .font(Type.small).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Connect Wallet") { connection.connect() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(Pill(fill: .accentColor, ink: .white))
            }
        }
        .padding(12)
        .modifier(Module())
    }
}

/// While the holder approves this Mac in the browser: the code to compare, the page again, or stop.
struct WaitingModule: View {
    @ObservedObject private var connection = Connection.shared

    var body: some View {
        if let waiting = connection.waiting {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small).scaleEffect(0.75).frame(width: 14, height: 14)
                    Text("Approve in your browser").font(Type.title)
                }
                HStack(alignment: .firstTextBaseline) {
                    Text(waiting.code.prefix(4) + " " + waiting.code.dropFirst(4))
                        .font(.system(size: 17, weight: .semibold, design: .monospaced))
                        .tracking(2)
                        .textSelection(.enabled)
                        .help("The page shows this same code")
                    Spacer()
                    Button("Cancel") { connection.cancel() }
                        .keyboardShortcut(.cancelAction)
                        .buttonStyle(Pill(fill: Color.primary.opacity(0.1), ink: .primary))
                    Button("Open Page") { connection.connect() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(Pill(fill: .accentColor, ink: .white))
                }
            }
            .padding(12)
            .modifier(Module())
        }
    }
}

// MARK: - Agents

/// This Mac's agent, read closely from its own box: its log, its job's live step, Grok beside it.
struct LocalAgentRow: View {
    @EnvironmentObject var state: WorkerState
    let name: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AgentHeader(tokenId: state.tokenId, phase: state.phase, name: name, subtitle: { now in localSubtitle(at: now) }) {
                Toggle("", isOn: Binding(
                    get: { state.isRunning || state.phase == .starting },
                    set: { on in on ? state.startWorker() : state.requestStop() }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .disabled(state.phase == .starting || state.phase == .stopping)
                .help(state.isRunning ? "Stop this Mac's agent (S)" : "Start this Mac's agent (S)")
            }

            if state.isWorking, let job = state.jobs.first {
                Button { state.openJob(job) } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        if let step = state.step {
                            Text(step).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        }
                        Text(job.objective).foregroundStyle(.tertiary).lineLimit(1)
                    }
                    .font(Type.small)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, Row.indent)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open this job on the explorer")
            }

            if let companion = state.companion { CompanionLine(companion: companion) }
            if state.confirmingStop { confirmation.transition(.opacity) }
            if let problem = state.problem {
                Text(problem).font(Type.small).foregroundStyle(.red).padding(.leading, Row.indent).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
    }

    private var confirmation: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Stop now? The job goes back to the network.").font(Type.small).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Spacer()
                Button("Cancel") { withAnimation(settle) { state.confirmingStop = false } }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(Pill(fill: Color.primary.opacity(0.1), ink: .primary))
                Button("Stop", role: .destructive) { state.stop() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(Pill(fill: .red, ink: .white))
            }
        }
        .padding(.leading, Row.indent)
    }

    private func localSubtitle(at now: Date) -> String {
        switch state.phase {
        case .dockerDown: return "Docker isn't running · turn on to open it"
        case .starting: return state.startingDocker ? "Starting Docker…" : "Starting…"
        case .idle:
            return ["Ready", state.heartbeat.map { "up \($0.uptime)" }].compactMap { $0 }.joined(separator: " · ")
        case .working(let n):
            guard let job = state.jobs.first else { return n == 1 ? "Working" : "Working on \(n) jobs" }
            return ["Working", job.title, job.since.map { elapsed(from: $0, to: now) }].compactMap { $0 }.joined(separator: " · ")
        default:
            return words(for: state.phase, at: now)
        }
    }
}

/// Another machine of the wallet's, read from the network: a Mac mini at home, a VPS, another box.
/// Its name opens its page on the explorer. When this Mac is connected to the wallet that holds it,
/// a switch pauses and resumes it: off, it finishes what it is running and takes nothing new.
struct RemoteAgentRow: View {
    @EnvironmentObject var state: WorkerState
    @ObservedObject private var connection = Connection.shared
    let agent: Agent
    let name: String
    /// Its number key, shown with the switch: 2 for the first agent after this Mac's.
    var key: Int? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Button {
                    if let url = URL(string: "\(state.explorer)/agents/\(agent.tokenId)") { NSWorkspace.shared.open(url) }
                } label: {
                    AgentHeader(tokenId: agent.tokenId, phase: phase, name: name, subtitle: { now in subtitle(at: now) }) { EmptyView() }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open agent \(agent.tokenId) on the explorer")

                if connection.holds(agent.wallet) {
                    Toggle("", isOn: Binding(get: { !agent.pausedByOwner }, set: { on in Fleet.shared.setPaused(!on, tokenId: agent.tokenId) }))
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .labelsHidden()
                        .disabled(connection.sending.contains(agent.tokenId))
                        .help((agent.pausedByOwner ? "Resume \(name)" : "Pause \(name): it finishes what it is running and takes nothing new") + (key.map { " (\($0))" } ?? ""))
                } else {
                    Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                }
            }
            if agent.working > 0, let job = agent.jobs.first {
                Text(job.objective).font(Type.small).foregroundStyle(.tertiary).lineLimit(1).padding(.leading, Row.indent)
            }
        }
        .padding(10)
    }

    private var phase: Phase {
        if !agent.connected { return .offline(agent.lastHeartbeat) }
        if let until = agent.pausedUntil {
            return .paused("Until \(until.formatted(date: .omitted, time: .shortened))" + (agent.pausedFor.map { ": \($0)" } ?? ""))
        }
        if agent.working > 0 { return .working(agent.working) }
        return agent.pausedByOwner ? .held : .idle
    }

    private func subtitle(at now: Date) -> String {
        if connection.sending.contains(agent.tokenId) { return agent.pausedByOwner ? "Resuming…" : "Pausing…" }
        switch phase {
        case .idle: return ["Ready", agent.runtimes.first.map(\.capitalizedFirst)].compactMap { $0 }.joined(separator: " · ")
        case .working(let n):
            let finishing = agent.pausedByOwner ? "finishing, then paused" : nil
            guard let job = agent.jobs.first else { return [n == 1 ? "Working" : "Working on \(n) jobs", finishing].compactMap { $0 }.joined(separator: " · ") }
            return ["Working", finishing ?? job.title, job.since.map { elapsed(from: $0, to: now) }].compactMap { $0 }.joined(separator: " · ")
        default: return words(for: phase, at: now)
        }
    }
}

/// The line every agent row starts with: its state, its name, what it is doing, and one control.
struct AgentHeader<Accessory: View>: View {
    let tokenId: String?
    let phase: Phase
    let name: String
    let subtitle: (Date) -> String
    @ViewBuilder let accessory: () -> Accessory

    var body: some View {
        HStack(spacing: 10) {
            MaskBadge(tokenId: tokenId, phase: phase, size: Row.mask)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(Type.title)
                TimelineView(.periodic(from: .now, by: 20)) { context in
                    Text(subtitle(context.date)).font(Type.small).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            accessory()
        }
    }
}

/// A state in words, for the rows that have nothing more specific to say.
func words(for phase: Phase, at now: Date) -> String {
    switch phase {
    case .dockerDown: return "Docker isn't running"
    case .stopped: return "Off"
    case .starting: return "Starting…"
    case .stopping: return "Stopping…"
    case .reconnecting: return "Reconnecting…"
    case .checking: return "Checking Claude before it takes jobs"
    case .holding(let why): return "Not taking jobs · \(why)"
    case .paused(let why): return "Paused by the network · \(why)"
    case .held: return "Paused · takes no new work"
    case .idle: return "Ready"
    case .working(let n): return n == 1 ? "Working" : "Working on \(n) jobs"
    case .offline(let seen):
        guard let seen else { return "Offline" }
        return "Offline · last seen \(ago(from: seen, to: now))"
    }
}

/// How long ago, in the largest unit that says it: "4 min ago", "2 hr ago", "3 days ago".
func ago(from then: Date, to now: Date) -> String {
    let minutes = max(0, Int(now.timeIntervalSince(then) / 60))
    if minutes < 1 { return "just now" }
    if minutes < 60 { return "\(minutes) min ago" }
    if minutes < 48 * 60 { return "\(minutes / 60) hr ago" }
    return "\(minutes / 1440) days ago"
}

func elapsed(from start: Date, to now: Date) -> String {
    let minutes = max(0, Int(now.timeIntervalSince(start) / 60))
    if minutes < 1 { return "just now" }
    if minutes < 60 { return "\(minutes) min" }
    if minutes < 48 * 60 { return "\(minutes / 60) hr \(minutes % 60) min" }
    return "\(minutes / 1440) days"
}

/// The Settings window: names for the agents, and the wallet they belong to. ⌘, from the panel.
struct SettingsRow: View {
    @State private var hovering = false

    var body: some View {
        SettingsLink {
            HStack(spacing: 6) {
                Text("Settings…").font(Type.row)
                Spacer()
                Text("⌘,").font(Type.row).foregroundStyle(.tertiary).frame(minWidth: 22, alignment: .trailing)
            }
            .padding(.horizontal, 6)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hovering ? Color.primary.opacity(0.09) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(",", modifiers: .command)
        .onHover { hovering = $0 }
    }
}

struct SettingsView: View {
    @ObservedObject var fleet = Fleet.shared
    @ObservedObject var state = WorkerState.shared
    @ObservedObject var connection = Connection.shared
    @State private var watching = Fleet.shared.owner ?? ""
    @State private var disconnecting = false

    var body: some View {
        Form {
            Section {
                ForEach(connection.wallets, id: \.self) { wallet in
                    LabeledContent(short(wallet)) { Text("Can pause and resume").foregroundStyle(.secondary) }
                        .help(wallet)
                }
                TextField("Watch", text: $watching, prompt: Text("0x…"))
                    .onSubmit { fleet.setOwner(watching) }
                HStack {
                    Button(connection.isWaiting ? "Waiting for Approval…" : "Connect Wallet…") { connection.connect() }
                        .disabled(connection.isWaiting)
                    Spacer()
                    if !connection.wallets.isEmpty {
                        Button("Disconnect This Mac", role: .destructive) {
                            disconnecting = true
                            Task { await connection.disconnect(); disconnecting = false }
                        }
                        .disabled(disconnecting)
                    }
                }
                if let problem = connection.problem { Text(problem).foregroundStyle(.red) }
            } header: {
                Text("Wallets")
            } footer: {
                Text("A connected wallet lets this Mac pause and resume the agents it holds, with a key that stays in this Mac's Secure Enclave. It does not expire. A watched wallet only shows its agents.")
                    .foregroundStyle(.secondary)
            }
            Section("Names") {
                if fleet.agents.isEmpty { Text("No agents found yet.").foregroundStyle(.secondary) }
                ForEach(fleet.agents) { agent in
                    TextField("Agent \(agent.tokenId)", text: Binding(
                        get: { fleet.names[agent.tokenId] ?? "" },
                        set: { fleet.rename(agent.tokenId, to: $0) }
                    ), prompt: Text(fleet.name(for: Agent(tokenId: agent.tokenId), localToken: state.tokenId)))
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .onAppear { NSApp.activate(ignoringOtherApps: true) }
    }

    private func short(_ address: String) -> String { "\(address.prefix(6))…\(address.suffix(4))" }
}

/// Grok beside the main runtime: a dot that says whether it is taking its share, and what that is.
struct CompanionLine: View {
    let companion: Companion

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(companion.ready ? Color.green : Color.orange).frame(width: 6, height: 6)
            Text(companion.ready ? "\(companion.name) \(companion.detail)" : "\(companion.name) off · \(companion.detail)")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.leading, Row.indent + 4)
        .help(companion.ready ? "\(companion.name) runs the jobs about X on this seat" : "X jobs run on Claude until \(companion.name) passes its check")
    }
}

/// A small filled button that answers on press: it dims and gives a little, then springs back.
struct Pill: ButtonStyle {
    let fill: Color
    let ink: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(ink)
            .padding(.horizontal, 12)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(fill).opacity(configuration.isPressed ? 0.8 : 1))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
            .contentShape(Rectangle())
    }
}

/// A white arc turning once a second; still, with Reduce Motion on.
struct Spinner: View {
    var lineWidth: CGFloat = 2
    @State private var turning = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.72)
            .stroke(.white, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            .rotationEffect(.degrees(turning ? 360 : 0))
            .animation(reduceMotion ? nil : .linear(duration: 1).repeatForever(autoreverses: false), value: turning)
            .onAppear { turning = true }
    }
}

/// The IMD mark from the explorer's icon.svg (viewBox 32): a square ring around a diamond ring,
/// drawn as filled outlines so it stays crisp at any size. Filled, the diamond is solid.
struct MarkShape: Shape {
    var filled: Bool

    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 32
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * s, y: rect.minY + y * s) }
        var path = Path()
        path.addRect(CGRect(origin: p(0, 0), size: CGSize(width: 32 * s, height: 32 * s)))
        path.addRect(CGRect(origin: p(3, 3), size: CGSize(width: 26 * s, height: 26 * s)))
        let outer: [CGPoint] = [p(16, 6.66), p(25.34, 16), p(16, 25.34), p(6.66, 16)]
        path.addLines(outer); path.closeSubpath()
        if !filled {
            let inner: [CGPoint] = [p(16, 10.34), p(21.66, 16), p(16, 21.66), p(10.34, 16)]
            path.addLines(inner); path.closeSubpath()
        }
        return path
    }
}

// MARK: - Numbers

struct StatsModule: View {
    @EnvironmentObject var state: WorkerState
    let stats: SeatStats
    /// Every agent of the wallet's together, rather than this Mac's alone.
    var everyAgent = false

    var body: some View {
        Button {
            if everyAgent, let owner = Fleet.shared.owner ?? Connection.shared.wallets.first, let url = URL(string: "\(state.explorer)/wallet/\(owner)") { NSWorkspace.shared.open(url) }
            else { state.openAgentPage() }
        } label: {
            HStack(spacing: 0) {
                stat("\(stats.today)", "Today")
                Divider().frame(height: 26)
                stat(stats.accepted.formatted(), "Accepted")
            }
            .padding(.vertical, 9)
            .modifier(Module())
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(everyAgent ? "All your agents together" : "Your agent's record, across every machine it has run on")
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 1) {
            Text(value).font(Type.number)
            Text(label).font(Type.small).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Rows

/// A row that behaves like a macOS menu item: the title, a checkmark when it is on, the shortcut on
/// the right, and a highlight under the pointer. Titles line up with the header above.
struct MenuRow: View {
    let title: String
    var shortcut: String? = nil
    var key: KeyEquivalent? = nil
    var modifiers: EventModifiers = []
    var checked: Bool? = nil
    var disclosure: Bool? = nil
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let button = Button(action: action) {
            HStack(spacing: 6) {
                Text(title).font(Type.row)
                if let disclosure {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(disclosure ? 90 : 0))
                }
                Spacer()
                if checked == true {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                }
                if let shortcut { Text(shortcut).font(Type.row).foregroundStyle(.tertiary).frame(minWidth: 22, alignment: .trailing) }
            }
            .padding(.horizontal, 6)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hovering ? Color.primary.opacity(0.09) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }

        if let key { button.keyboardShortcut(key, modifiers: modifiers) } else { button }
    }
}

struct ActivityList: View {
    let items: [Activity]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if items.isEmpty { Text("Nothing yet").foregroundStyle(.tertiary) }
            ForEach(items) { item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(item.time).monospacedDigit().foregroundStyle(.tertiary).frame(width: 56, alignment: .leading)
                    Text(item.text).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .font(Type.small)
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - The menu bar icon

enum Mark {
    /// One icon for every agent: a warning while any needs attention (this Mac's box held or Docker
    /// closed, another machine offline or paused), filled while any works, dim when all are off.
    static func aggregate(local: Phase, others: [Agent]) -> Phase {
        switch local { case .holding, .paused, .dockerDown: return local; default: break }
        if others.contains(where: { !$0.connected || $0.pausedUntil != nil }) { return .holding("an agent needs attention") }
        if case .working = local { return local }
        if let busy = others.first(where: { $0.working > 0 }) { return .working(busy.working) }
        if local == .stopped || local == .held {
            return others.isEmpty || others.allSatisfy({ $0.pausedByOwner }) ? local : .idle
        }
        return local
    }

    static func menuBarImage(for phase: Phase) -> NSImage {
        switch phase {
        case .holding, .paused, .dockerDown:
            let image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "IMD worker needs attention") ?? NSImage()
            image.isTemplate = true
            return image
        case .working: return draw(filled: true, alpha: 1)
        case .stopped, .held: return draw(filled: false, alpha: 0.45)
        default: return draw(filled: false, alpha: 1)
        }
    }

    static func draw(filled: Bool, alpha: CGFloat) -> NSImage {
        let side: CGFloat = 16
        let image = NSImage(size: NSSize(width: side, height: side), flipped: true) { rect in
            let path = MarkShape(filled: filled).path(in: rect.insetBy(dx: 0.5, dy: 0.5))
            NSColor.black.withAlphaComponent(alpha).setFill()
            let bezier = NSBezierPath()
            bezier.windingRule = .evenOdd
            path.forEach { element in
                switch element {
                case .move(let to): bezier.move(to: to)
                case .line(let to): bezier.line(to: to)
                case .closeSubpath: bezier.close()
                default: break
                }
            }
            bezier.fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "IMD worker"
        return image
    }
}

// MARK: - Review renders

/// Draws the panel in each state to PNGs: `IMD Worker --render <dir>`. Real AppKit controls, so the
/// switch and buttons look as they do in the menu bar; the popover's material is approximated.
@MainActor
enum Renderer {
    static func renderAll(to dir: String) {
        let beat = Heartbeat(connected: true, uptime: "42m", running: 1, submitted: 3, online: 1016, notes: [])
        let job = Job(id: "7deb4144", objective: "SITE v3.1, a small continuation: the author's own CHILD CALL",
                      node: "site_content_check", role: "review", since: Date().addingTimeInterval(-9 * 60))
        let stats = SeatStats(today: 14, accepted: 284)
        let activity = [("9:12 PM", "Network restarting"), ("9:12 PM", "Connected"), ("9:13 PM", "Took a review job"),
                        ("9:13 PM", "Cloning the base repository"), ("9:13 PM", "Claude started"), ("9:15 PM", "Dependencies installed. Now building the export")]
            .enumerated().map { Activity(id: $0.offset, time: $0.element.0, text: $0.element.1) }
        let fleet = Fleet.shared
        fleet.names = ["22": "Mac mini"]
        let miniReady = Agent(tokenId: "22", deviceKey: "743b", connected: true, working: 0, runtimes: ["claude"], stats: stats)
        let miniWorking = Agent(tokenId: "22", deviceKey: "743b", connected: true, working: 1, runtimes: ["claude"],
                                jobs: [Job(id: "0e9e", objective: "Did @coinbase post that it is listing $FOO within the window?", node: "oracle_assess", role: "implement", since: Date().addingTimeInterval(-3 * 60))], stats: stats)
        let miniOffline = Agent(tokenId: "22", deviceKey: "743b", connected: false, lastHeartbeat: Date().addingTimeInterval(-2 * 3600), stats: stats)
        typealias Sample = (String, Phase, Heartbeat?, [Job], String?, Bool, Bool)
        let samples: [Sample] = [
            ("working", .working(1), beat, [job], "Dependencies installed. Now building the export in /tmp to compare against the shipped dist.", false, false),
            ("working-activity", .working(1), beat, [job], "Dependencies installed. Now building the export in /tmp to compare against the shipped dist.", false, true),
            ("confirm-stop", .working(1), beat, [job], "Claude is on it", true, false),
            ("idle", .idle, Heartbeat(connected: true, uptime: "2h 5m", running: 0, submitted: 7, online: 1016, notes: []), [], nil, false, false),
            ("checking", .checking, nil, [], nil, false, false),
            ("paused", .paused("Until 9:40 PM: three failed runs in a row"), nil, [], nil, false, false),
            ("off", .stopped, nil, [], nil, false, false),
            ("docker", .dockerDown, nil, [], nil, false, false),
            ("solo", .idle, Heartbeat(connected: true, uptime: "2h 5m", running: 0, submitted: 7, online: 1016, notes: []), [], nil, false, false),
            ("fleet-working", .working(1), beat, [job], "Claude is on it", false, false),
            ("fleet-offline", .idle, Heartbeat(connected: true, uptime: "2h 5m", running: 0, submitted: 7, online: 1016, notes: []), [], nil, false, false),
            ("connected", .idle, Heartbeat(connected: true, uptime: "2h 5m", running: 0, submitted: 7, online: 1016, notes: []), [], nil, false, false),
            ("connected-held", .idle, Heartbeat(connected: true, uptime: "2h 5m", running: 0, submitted: 7, online: 1016, notes: []), [], nil, false, false),
            ("held-here", .held, Heartbeat(connected: true, uptime: "2h 5m", running: 0, submitted: 7, online: 1016, notes: []), [], nil, false, false),
            ("empty", .stopped, nil, [], nil, false, false),
            ("waiting", .stopped, nil, [], nil, false, false),
        ]
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let state = WorkerState.shared
        func set(_ sample: Sample) {
            let (name, phase, heartbeat, jobs, step, confirming, showingActivity) = sample
            state.phase = phase; state.heartbeat = heartbeat; state.jobs = jobs; state.step = step
            state.tokenId = "12"
            let wallet = "0xfe35e15be885750d9b2363cbb6abdd57ac9c4c40"
            let local = Agent(tokenId: "12", wallet: wallet, deviceKey: "d5e4", connected: true, stats: stats)
            var mini = name == "fleet-offline" ? miniOffline : name == "fleet-working" ? miniWorking : miniReady
            mini.wallet = wallet
            mini.pausedByOwner = name == "connected-held"
            fleet.agents = name == "solo" || name == "empty" || name == "waiting" ? [] : [local, mini]
            state.hasBox = !(name == "empty" || name == "waiting")
            Connection.shared.preview(wallets: name.hasPrefix("connected") ? [wallet] : [], waiting: name == "waiting" ? ("K7QM4XJ2", Date().addingTimeInterval(600)) : nil)
            state.companion = name == "working" ? Companion(name: "Grok", ready: true, detail: "for X work")
                : name == "idle" ? Companion(name: "Grok", ready: false, detail: "Not signed in") : nil
            state.stats = stats; state.activity = activity
            state.confirmingStop = confirming; state.showingActivity = showingActivity
        }

        // The agents' masks, read before anything is drawn.
        let masks = Masks.shared
        masks.load("12"); masks.load("22")
        wait(seconds: 10) { masks.faces["12"] != nil && masks.faces["22"] != nil }
        for sample in samples {
            set(sample)
            for dark in [true, false] { save(dark: dark, to: "\(dir)/\(sample.0)-\(dark ? "dark" : "light").png") }
        }
    }

    /// The menu as it is now, to a PNG.
    static func save(dark: Bool, to path: String) {
        let view = PanelView()
            .environmentObject(WorkerState.shared)
            .background(dark ? Color(white: 0.17) : Color(white: 0.95))
            .environment(\.colorScheme, dark ? .dark : .light)
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        // A key window, off screen, so controls draw active (the switch in its accent, Stop in red).
        let window = KeyableWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        defer { window.orderOut(nil) }
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    static func wait(seconds: TimeInterval, until ready: () -> Bool) {
        let end = Date().addingTimeInterval(seconds)
        while !ready() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
    }
}

/// A borderless window that can still become key, for rendering controls in their active state.
final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

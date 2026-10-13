import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // `--render <dir>` draws the panel in each state to PNGs and quits, for reviewing the design.
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--render"), i + 1 < args.count {
            MainActor.assumeIsolated { Renderer.renderAll(to: args[i + 1]) }
            NSApp.terminate(nil)
            return
        }
        // `--status` reads the box once and prints what the panel would say, for checking the parsing.
        if args.contains("--status") {
            Task { @MainActor in
                let state = WorkerState.shared
                state.setPanelOpen(true)
                await state.refresh()
                print("phase:", state.phase)
                print("heartbeat:", state.heartbeat.map { "up \($0.uptime), \($0.running) running, \($0.submitted) submitted, \($0.online ?? 0) online, notes \($0.notes)" } ?? "none")
                print("jobs:", state.jobs.map { "\($0.id.prefix(8)) \($0.objective.prefix(70))" })
                print("step:", state.step ?? "none")
                print("token:", state.tokenId ?? "unknown")
                print("recent:"); state.recent.forEach { print("  ", $0) }
                await state.refreshFleet()
                let fleet = Fleet.shared
                print("owner:", fleet.owner ?? "unknown")
                for agent in fleet.agents {
                    print("agent \(agent.tokenId) \(fleet.name(for: agent, localToken: state.tokenId)): connected \(agent.connected), working \(agent.working), runtimes \(agent.runtimes), key \(agent.deviceKey?.prefix(8) ?? "unknown"), stats \(agent.stats.map { "\($0.today) today, \($0.accepted) accepted" } ?? "none")")
                }
                print("combined:", fleet.combined.map { "\($0.today) today, \($0.accepted) accepted" } ?? "none")
                exit(0)
            }
            return
        }
        MainActor.assumeIsolated { WorkerState.shared.start() }
    }
}

@main
struct IMDWorkerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @ObservedObject private var state = WorkerState.shared
    @ObservedObject private var fleet = Fleet.shared

    var body: some Scene {
        MenuBarExtra {
            PanelView()
                .environmentObject(state)
                .onAppear { state.setPanelOpen(true) }
                .onDisappear { state.setPanelOpen(false) }
        } label: {
            Image(nsImage: Mark.menuBarImage(for: Mark.aggregate(local: state.phase, others: fleet.agents.filter { $0.tokenId != state.tokenId })))
        }
        .menuBarExtraStyle(.window)

        Settings { SettingsView() }
    }
}

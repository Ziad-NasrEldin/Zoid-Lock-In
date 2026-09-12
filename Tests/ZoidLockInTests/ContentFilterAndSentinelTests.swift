import Foundation
import NetworkExtension
import Testing
import ZoidLockInCore
import ZoidLockInEnforcer

@Suite("Content filter provider")
struct ContentFilterProviderTests {
    @Test("maps core drop verdicts to NEFilterNewFlowVerdict.drop")
    func mapsDropVerdicts() {
        let rules = DomainFilterRules()
        let blocked = ["youtube.com", "talabat.com", "deliveroo.com", "twitter.com", "x.com"]

        for hostname in blocked {
            #expect(rules.verdict(forHostname: hostname) == .drop)

            let networkVerdict = ContentFilterProvider.networkVerdict(
                forHostname: hostname,
                rules: rules
            )
            #expect(isDropVerdict(networkVerdict))
        }
    }

    @Test("maps core allow verdicts to NEFilterNewFlowVerdict.allow")
    func mapsAllowVerdicts() {
        let rules = DomainFilterRules()
        let allowed = ["apple.com", "github.com", "swift.org"]

        for hostname in allowed {
            #expect(rules.verdict(forHostname: hostname) == .allow)

            let networkVerdict = ContentFilterProvider.networkVerdict(
                forHostname: hostname,
                rules: rules
            )
            #expect(!isDropVerdict(networkVerdict))
        }
    }

    @Test("policy defaults inspect TCP ports 80 and 443 only")
    func defaultPorts() {
        let policy = EnforcementPolicy.lockedDown
        #expect(policy.shouldInspect(port: 80))
        #expect(policy.shouldInspect(port: 443))
        #expect(!policy.shouldInspect(port: 22))
        #expect(!policy.shouldInspect(port: 8080))
    }
}

/// `NEFilterNewFlowVerdict` does not implement Equatable; inspect its drop flag via KVC.
private func isDropVerdict(_ verdict: NEFilterNewFlowVerdict) -> Bool {
    (verdict.value(forKey: "drop") as? Bool) ?? false
}

@Suite("Process sentinel")
struct ProcessSentinelTests {
    @Test("terminates matched targets with SIGSTOP then SIGKILL within one scan")
    func terminatesMatchedTargets() {
        let runtime = MockProcessRuntimeController(
            processes: [
                RunningProcess(pid: 101, name: "Finder"),
                RunningProcess(pid: 202, name: "Steam"),
                RunningProcess(pid: 303, name: "Discord"),
                RunningProcess(pid: 404, name: "Xcode"),
            ]
        )
        let sentinel = ProcessSentinel(
            matcher: ProcessTargetMatcher(),
            runtime: runtime,
            scanInterval: 1.5
        )

        let terminated = sentinel.scanAndTerminate()

        #expect(Set(terminated.map(\.pid)) == Set([202, 303]))
        #expect(runtime.sentSignals[202] == [SIGSTOP, SIGKILL])
        #expect(runtime.sentSignals[303] == [SIGSTOP, SIGKILL])
        #expect(runtime.sentSignals[101] == nil)
        #expect(sentinel.scanCount == 1)
        #expect(sentinel.scanInterval == 1.5)
    }

    @Test("ignores processes that are not on the target list")
    func ignoresNonTargets() {
        let runtime = MockProcessRuntimeController(
            processes: [
                RunningProcess(pid: 1, name: "WindowServer"),
                RunningProcess(pid: 2, name: "Cursor"),
            ]
        )
        let sentinel = ProcessSentinel(runtime: runtime)

        let terminated = sentinel.scanAndTerminate()
        #expect(terminated.isEmpty)
        #expect(runtime.sentSignals.isEmpty)
    }
}

private final class MockProcessRuntimeController: ProcessRuntimeControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var processes: [RunningProcess]
    private(set) var sentSignals: [Int32: [Int32]] = [:]

    init(processes: [RunningProcess]) {
        self.processes = processes
    }

    func listRunningProcesses() -> [RunningProcess] {
        lock.lock()
        defer { lock.unlock() }
        return processes
    }

    func terminate(pid: Int32, signal: Int32) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        sentSignals[pid, default: []].append(signal)
        if signal == SIGKILL {
            processes.removeAll { $0.pid == pid }
        }
        return true
    }
}

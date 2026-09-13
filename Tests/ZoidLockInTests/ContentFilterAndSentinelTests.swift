import Darwin
import Foundation
import NetworkExtension
import Testing
import ZoidLockInCore
import ZoidLockInEnforcer
import ZoidLockInFilterExtension

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

    @Test("policy inspects TCP/UDP HTTP ports and local proxy ports")
    func defaultPorts() {
        let policy = EnforcementPolicy.lockedDown
        #expect(policy.shouldInspect(port: 80))
        #expect(policy.shouldInspect(port: 443))
        #expect(policy.shouldInspect(port: 8080))
        #expect(policy.shouldInspect(port: 1080))
        #expect(!policy.shouldInspect(port: 22))
        #expect(!policy.shouldInspect(port: 53))
    }

    @Test("drops UDP/443 QUIC flows to blacklisted domains")
    func dropsUDP443BlacklistedHosts() {
        let policy = EnforcementPolicy.lockedDown
        let verdict = ContentFilterProvider.networkVerdict(
            hostname: "www.youtube.com",
            port: 443,
            transport: .udp,
            policy: policy
        )
        #expect(isDropVerdict(verdict))
        #expect(policy.flowVerdict(hostname: "netflix.com", port: 443, transport: .udp) == .drop)
    }

    @Test("drops unverified UDP/443 QUIC flows (HTTP/3 fail-closed)")
    func dropsUnverifiedUDP443() {
        let policy = EnforcementPolicy.lockedDown
        for hostname: String? in [nil, "", "8.8.8.8"] {
            let verdict = ContentFilterProvider.networkVerdict(
                hostname: hostname,
                port: 443,
                transport: .udp,
                policy: policy
            )
            #expect(isDropVerdict(verdict), "Expected drop for UDP/443 hostname \(String(describing: hostname))")
        }
    }

    @Test("allows verified non-blacklisted UDP/443 hosts")
    func allowsVerifiedUDP443() {
        let policy = EnforcementPolicy.lockedDown
        let verdict = ContentFilterProvider.networkVerdict(
            hostname: "apple.com",
            port: 443,
            transport: .udp,
            policy: policy
        )
        #expect(!isDropVerdict(verdict))
    }

    @Test("drops nil or empty hostnames on inspected TCP ports")
    func failClosedOnInspectedPorts() {
        let policy = EnforcementPolicy.lockedDown
        for port: UInt16 in [80, 443, 8080, 1080] {
            for hostname: String? in [nil, ""] {
                #expect(
                    policy.flowVerdict(hostname: hostname, port: port, transport: .tcp) == .drop,
                    "Expected drop for TCP/\(port) hostname \(String(describing: hostname))"
                )
            }
        }
    }

    @Test("does not inspect SSH; nil hostname on port 22 is allowed")
    func uninspectedPortsRemainOpen() {
        let policy = EnforcementPolicy.lockedDown
        #expect(policy.flowVerdict(hostname: nil, port: 22, transport: .tcp) == .allow)
        #expect(policy.flowVerdict(hostname: "youtube.com", port: 22, transport: .tcp) == .allow)
        #expect(policy.flowVerdict(hostname: "youtube.com", port: 53, transport: .udp) == .allow)
    }

    @Test("maps socketProtocol constants to TCP and UDP")
    func mapsSocketProtocols() {
        #expect(ContentFilterProvider.transport(from: IPPROTO_TCP) == .tcp)
        #expect(ContentFilterProvider.transport(from: IPPROTO_UDP) == .udp)
        #expect(ContentFilterProvider.transport(from: IPPROTO_ICMP) == .other)
    }

    @Test("unknown TCP/UDP port still fail-closes on missing hostname")
    func unknownPortFailClosed() {
        let policy = EnforcementPolicy.lockedDown
        #expect(policy.flowVerdict(hostname: nil, port: nil, transport: .tcp) == .drop)
        #expect(policy.flowVerdict(hostname: nil, port: nil, transport: .udp) == .drop)
        #expect(policy.flowVerdict(hostname: "apple.com", port: nil, transport: .tcp) == .allow)
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

    @Test("signals the process group so launcher children are killed")
    func signalsProcessGroup() {
        let runtime = MockProcessRuntimeController(
            processes: [
                RunningProcess(
                    pid: 202,
                    name: "Steam",
                    executablePath: "/Applications/Steam.app/Contents/MacOS/steam_osx"
                ),
                RunningProcess(
                    pid: 500,
                    name: "dota2",
                    executablePath: "/Users/me/Library/Application Support/Steam/steamapps/common/dota2/dota2"
                ),
            ],
            processGroups: [
                202: 202,
                500: 202,
            ]
        )
        let sentinel = ProcessSentinel(matcher: ProcessTargetMatcher(), runtime: runtime)

        let terminated = sentinel.scanAndTerminate()

        #expect(Set(terminated.map(\.pid)) == Set([202, 500]))
        #expect(runtime.sentSignals[202] == [SIGSTOP, SIGKILL])
        #expect(runtime.sentSignals[500] == [SIGSTOP, SIGKILL])
        #expect(runtime.sentGroupSignals[202]?.contains(SIGKILL) == true)
        #expect(sentinel.lastSignaledProcessGroups.contains(202))
    }

    @Test("matches helpers by executable path even when comm name is generic")
    func pathBasedMatching() {
        let runtime = MockProcessRuntimeController(
            processes: [
                RunningProcess(
                    pid: 707,
                    name: "Helper",
                    executablePath: "/Applications/Steam.app/Contents/MacOS/steamwebhelper"
                ),
            ]
        )
        let sentinel = ProcessSentinel(runtime: runtime)
        let terminated = sentinel.scanAndTerminate()
        #expect(terminated.map(\.pid) == [707])
        #expect(runtime.sentSignals[707] == [SIGSTOP, SIGKILL])
        #expect(runtime.sentGroupSignals[707] == [SIGSTOP, SIGKILL])
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
        #expect(runtime.sentGroupSignals.isEmpty)
    }
}

private final class MockProcessRuntimeController: ProcessRuntimeControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var processes: [RunningProcess]
    private var processGroups: [Int32: Int32]
    private(set) var sentSignals: [Int32: [Int32]] = [:]
    private(set) var sentGroupSignals: [Int32: [Int32]] = [:]

    init(processes: [RunningProcess], processGroups: [Int32: Int32] = [:]) {
        self.processes = processes
        self.processGroups = processGroups
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

    func processGroupID(for pid: Int32) -> Int32? {
        lock.lock()
        defer { lock.unlock() }
        return processGroups[pid] ?? pid
    }

    func terminateProcessGroup(pgid: Int32, signal: Int32) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        sentGroupSignals[pgid, default: []].append(signal)
        return true
    }
}

import Darwin
import Foundation
import ZoidLockInCore

/// Snapshot of a running process used by the process sentinel.
public struct RunningProcess: Sendable, Equatable {
    public let pid: Int32
    public let name: String
    public let executablePath: String?

    public init(pid: Int32, name: String, executablePath: String? = nil) {
        self.pid = pid
        self.name = name
        self.executablePath = executablePath
    }
}

/// Abstraction over process enumeration and signal delivery for testability.
public protocol ProcessRuntimeControlling: Sendable {
    func listRunningProcesses() -> [RunningProcess]
    func terminate(pid: Int32, signal: Int32) -> Bool
    func processGroupID(for pid: Int32) -> Int32?
    func terminateProcessGroup(pgid: Int32, signal: Int32) -> Bool
}

/// Default macOS process controller backed by `libproc`, `kill(2)`, and `killpg(2)`.
public struct DarwinProcessRuntimeController: ProcessRuntimeControlling {
    public init() {}

    public func listRunningProcesses() -> [RunningProcess] {
        let type = UInt32(PROC_ALL_PIDS)
        let pidByteCount = proc_listpids(type, 0, nil, 0)
        guard pidByteCount > 0 else { return [] }

        let capacity = Int(pidByteCount) / MemoryLayout<pid_t>.stride
        var pids = [pid_t](repeating: 0, count: capacity)
        let written = proc_listpids(
            type,
            0,
            &pids,
            Int32(pids.count * MemoryLayout<pid_t>.stride)
        )
        guard written > 0 else { return [] }

        let liveCount = Int(written) / MemoryLayout<pid_t>.stride
        var processes: [RunningProcess] = []
        processes.reserveCapacity(liveCount)

        for index in 0..<liveCount {
            let pid = pids[index]
            guard pid > 0 else { continue }

            var nameBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            let nameLength = proc_name(pid, &nameBuffer, UInt32(nameBuffer.count))
            var name = ""
            if nameLength > 0 {
                name = nameBuffer.withUnsafeBufferPointer { buffer in
                    String(cString: buffer.baseAddress!)
                }
            }

            var pathBuffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            let pathLength = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
            var executablePath: String?
            if pathLength > 0 {
                executablePath = pathBuffer.withUnsafeBufferPointer { buffer in
                    String(cString: buffer.baseAddress!)
                }
            }

            if name.isEmpty, let executablePath {
                name = URL(fileURLWithPath: executablePath).lastPathComponent
            }

            guard !name.isEmpty else { continue }
            processes.append(
                RunningProcess(pid: pid, name: name, executablePath: executablePath)
            )
        }

        return processes
    }

    public func terminate(pid: Int32, signal: Int32) -> Bool {
        kill(pid, signal) == 0
    }

    public func processGroupID(for pid: Int32) -> Int32? {
        let pgid = getpgid(pid)
        guard pgid > 0 else { return nil }
        return pgid
    }

    public func terminateProcessGroup(pgid: Int32, signal: Int32) -> Bool {
        guard pgid > 1 else { return false }
        return killpg(pgid, signal) == 0
    }
}

/// Scans for distraction binaries and terminates matches with SIGKILL.
///
/// Default scan cadence is 1.5 seconds to satisfy the Slice 1 launch-to-kill budget.
/// Matched launchers are signalled individually and via `killpg` so child game
/// processes in the same process group are terminated with the parent.
public final class ProcessSentinel: @unchecked Sendable {
    public static let defaultScanInterval: TimeInterval = 1.5

    private let runtime: any ProcessRuntimeControlling
    private let lock = NSLock()
    private var matcher: ProcessTargetMatcher
    private var mode: EnforcementMode
    private var activePassKinds: Set<PassKind> = []
    private var timer: DispatchSourceTimer?
    private var isRunning = false

    public private(set) var lastTerminatedPIDs: [Int32] = []
    public private(set) var lastSignaledProcessGroups: [Int32] = []
    public private(set) var scanCount: Int = 0

    public init(
        matcher: ProcessTargetMatcher = ProcessTargetMatcher(),
        runtime: any ProcessRuntimeControlling = DarwinProcessRuntimeController(),
        scanInterval: TimeInterval = ProcessSentinel.defaultScanInterval,
        mode: EnforcementMode = .hard
    ) {
        self.matcher = matcher
        self.runtime = runtime
        self.scanInterval = scanInterval
        self.mode = mode
    }

    public private(set) var scanInterval: TimeInterval

    public func updateMatcher(_ matcher: ProcessTargetMatcher) {
        lock.lock()
        self.matcher = matcher
        lock.unlock()
    }

    public func updateMode(_ mode: EnforcementMode) {
        lock.lock()
        self.mode = mode
        lock.unlock()
    }

    public func apply(_ policy: EnforcementPolicy, passKind: PassKind? = nil) {
        apply(policy, passKinds: Set([passKind].compactMap { $0 }))
    }

    public func apply(_ policy: EnforcementPolicy, passKinds: Set<PassKind>) {
        lock.lock()
        matcher = policy.processMatcher
        mode = policy.mode
        activePassKinds = passKinds
        lock.unlock()
    }

    public func updatePassKind(_ kind: PassKind?) {
        updatePassKinds(Set([kind].compactMap { $0 }))
    }

    public func updatePassKinds(_ kinds: Set<PassKind>) {
        lock.lock()
        activePassKinds = kinds
        lock.unlock()
    }

    /// Starts periodic scanning on a background queue.
    public func start() {
        lock.lock()
        defer { lock.unlock() }

        guard !isRunning else { return }
        isRunning = true

        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInitiated))
        timer.schedule(
            deadline: .now(),
            repeating: scanInterval,
            leeway: .milliseconds(100)
        )
        timer.setEventHandler { [weak self] in
            _ = self?.scanAndTerminate()
        }
        self.timer = timer
        timer.resume()
    }

    /// Stops periodic scanning.
    public func stop() {
        lock.lock()
        defer { lock.unlock() }

        timer?.cancel()
        timer = nil
        isRunning = false
    }

    /// Performs one scan cycle and sends SIGSTOP then SIGKILL to matched targets
    /// and their process groups.
    @discardableResult
    public func scanAndTerminate() -> [RunningProcess] {
        lock.lock()
        let activeMatcher = matcher
        let activeMode = mode
        let passKinds = activePassKinds
        lock.unlock()

        let selfPid = getpid()
        let matches = runtime.listRunningProcesses().filter { process in
            process.pid > 1
                && process.pid != selfPid
                && activeMatcher.matches(
                    processName: process.name,
                    executablePath: process.executablePath
                )
        }

        let relaxKills = passKinds.contains { $0.relaxesProcessTermination }
        guard activeMode == .hard, !relaxKills else {
            lock.lock()
            scanCount += 1
            lastTerminatedPIDs = []
            lastSignaledProcessGroups = []
            lock.unlock()
            return []
        }

        var terminated: [RunningProcess] = []
        var signaledGroups: [Int32] = []

        for process in matches {
            _ = runtime.terminate(pid: process.pid, signal: SIGSTOP)
            if runtime.terminate(pid: process.pid, signal: SIGKILL) {
                terminated.append(process)
            }

            if let pgid = runtime.processGroupID(for: process.pid), pgid > 1, pgid != getpgrp() {
                _ = runtime.terminateProcessGroup(pgid: pgid, signal: SIGSTOP)
                if runtime.terminateProcessGroup(pgid: pgid, signal: SIGKILL) {
                    signaledGroups.append(pgid)
                }
            }
        }

        lock.lock()
        scanCount += 1
        lastTerminatedPIDs = terminated.map(\.pid)
        lastSignaledProcessGroups = signaledGroups
        lock.unlock()

        return terminated
    }

    deinit {
        stop()
    }
}

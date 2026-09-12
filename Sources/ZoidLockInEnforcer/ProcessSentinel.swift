import Darwin
import Foundation
import ZoidLockInCore

/// Snapshot of a running process used by the process sentinel.
public struct RunningProcess: Sendable, Equatable {
    public let pid: Int32
    public let name: String

    public init(pid: Int32, name: String) {
        self.pid = pid
        self.name = name
    }
}

/// Abstraction over process enumeration and signal delivery for testability.
public protocol ProcessRuntimeControlling: Sendable {
    func listRunningProcesses() -> [RunningProcess]
    func terminate(pid: Int32, signal: Int32) -> Bool
}

/// Default macOS process controller backed by `libproc` and `kill(2)`.
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
            guard nameLength > 0 else { continue }

            let name = nameBuffer.withUnsafeBufferPointer { buffer in
                String(cString: buffer.baseAddress!)
            }
            processes.append(RunningProcess(pid: pid, name: name))
        }

        return processes
    }

    public func terminate(pid: Int32, signal: Int32) -> Bool {
        kill(pid, signal) == 0
    }
}

/// Scans for distraction binaries and terminates matches with SIGKILL.
///
/// Default scan cadence is 1.5 seconds to satisfy the Slice 1 launch-to-kill budget.
public final class ProcessSentinel: @unchecked Sendable {
    public static let defaultScanInterval: TimeInterval = 1.5

    private let runtime: any ProcessRuntimeControlling
    private let lock = NSLock()
    private var matcher: ProcessTargetMatcher
    private var timer: DispatchSourceTimer?
    private var isRunning = false

    public private(set) var lastTerminatedPIDs: [Int32] = []
    public private(set) var scanCount: Int = 0

    public init(
        matcher: ProcessTargetMatcher = ProcessTargetMatcher(),
        runtime: any ProcessRuntimeControlling = DarwinProcessRuntimeController(),
        scanInterval: TimeInterval = ProcessSentinel.defaultScanInterval
    ) {
        self.matcher = matcher
        self.runtime = runtime
        self.scanInterval = scanInterval
    }

    public private(set) var scanInterval: TimeInterval

    public func updateMatcher(_ matcher: ProcessTargetMatcher) {
        lock.lock()
        self.matcher = matcher
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

    /// Performs one scan cycle and sends SIGKILL to matched targets.
    @discardableResult
    public func scanAndTerminate() -> [RunningProcess] {
        lock.lock()
        let activeMatcher = matcher
        lock.unlock()

        let matches = runtime.listRunningProcesses().filter { process in
            activeMatcher.matches(processName: process.name)
        }

        var terminated: [RunningProcess] = []
        for process in matches {
            // SPEC: SIGSTOP then SIGKILL. Slice 1 prototype uses SIGKILL for hard stop.
            _ = runtime.terminate(pid: process.pid, signal: SIGSTOP)
            if runtime.terminate(pid: process.pid, signal: SIGKILL) {
                terminated.append(process)
            }
        }

        lock.lock()
        scanCount += 1
        lastTerminatedPIDs = terminated.map(\.pid)
        lock.unlock()

        return terminated
    }

    deinit {
        stop()
    }
}

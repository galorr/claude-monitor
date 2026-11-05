import Darwin
import Foundation

/// Source of process samples; the live one reads libproc, tests pass a fixed table.
public protocol ProcessTableReading: AnyObject {
    /// All processes of this user. `args` is filled for the pids `ProcessTree.needsArgs`
    /// picks for these claude roots.
    func read(roots: Set<Int32>) -> [ProcSample]
}

/// Reads the process table through libproc and sysctl: no `ps` fork. Only processes of
/// the current user are readable without privileges, which is all we need.
/// Not thread-safe: use it from one queue.
public final class LibprocProcessTable: ProcessTableReading {
    private let timebase: Double
    private let uid = getuid()
    private var argsBuffer: [UInt8]
    /// Command lines do not change while a process keeps its key and name.
    private var argsCache: [ProcKey: (name: String, args: [String])] = [:]

    public init() {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        // pti_total_* are in mach ticks: 1 on Intel, 125/3 ns on Apple Silicon.
        timebase = Double(tb.numer) / Double(tb.denom) / 1e9
        var argmax: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("kern.argmax", &argmax, &size, nil, 0) != 0 || argmax <= 0 { argmax = 256 * 1024 }
        argsBuffer = [UInt8](repeating: 0, count: Int(argmax))
    }

    public func read(roots: Set<Int32>) -> [ProcSample] {
        var samples = basicSamples()
        let wanted = ProcessTree.needsArgs(samples, roots: roots)
        var nextCache: [ProcKey: (name: String, args: [String])] = [:]
        for i in samples.indices where wanted.contains(samples[i].pid) {
            let key = samples[i].key
            if let cached = argsCache[key], cached.name == samples[i].name {
                samples[i].args = cached.args
            } else {
                samples[i].args = arguments(samples[i].pid)
            }
            if let args = samples[i].args { nextCache[key] = (samples[i].name, args) }
        }
        argsCache = nextCache
        return samples
    }

    private func basicSamples() -> [ProcSample] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let n = pids.withUnsafeMutableBufferPointer {
            proc_listallpids($0.baseAddress, Int32($0.count * MemoryLayout<pid_t>.size))
        }
        guard n > 0 else { return [] }
        var result: [ProcSample] = []
        result.reserveCapacity(Int(n))
        for pid in pids.prefix(Int(n)) where pid > 0 {
            var bsd = proc_bsdinfo()
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0,
                  bsd.pbi_uid == uid else { continue }
            var task = proc_taskinfo()
            guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, Int32(MemoryLayout<proc_taskinfo>.size)) > 0 else { continue }
            let started = Date(timeIntervalSince1970: Double(bsd.pbi_start_tvsec) + Double(bsd.pbi_start_tvusec) / 1e6)
            let cpu = Double(task.pti_total_user + task.pti_total_system) * timebase
            var name = Self.string(bsd.pbi_name)
            if name.isEmpty { name = Self.string(bsd.pbi_comm) }
            result.append(ProcSample(pid: pid, ppid: Int32(bsd.pbi_ppid), startedAt: started, cpuSeconds: cpu, name: name))
        }
        return result
    }

    /// KERN_PROCARGS2: argc (Int32), the exec path, NUL padding, then argc NUL-terminated args.
    private func arguments(_ pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = argsBuffer.count
        let ok = argsBuffer.withUnsafeMutableBytes { sysctl(&mib, 3, $0.baseAddress, &size, nil, 0) == 0 }
        guard ok, size > MemoryLayout<Int32>.size else { return nil }
        return Self.parseProcArgs(argsBuffer, size: size)
    }

    static func parseProcArgs(_ buf: [UInt8], size: Int) -> [String]? {
        guard size > 4 else { return nil }
        let argc = buf.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        var i = 4
        while i < size && buf[i] != 0 { i += 1 }  // exec path
        while i < size && buf[i] == 0 { i += 1 }  // padding
        var args: [String] = []
        while args.count < argc && i < size {
            var j = i
            while j < size && buf[j] != 0 { j += 1 }
            args.append(String(decoding: buf[i..<j], as: UTF8.self))
            i = j + 1
        }
        return args.isEmpty ? nil : args
    }

    private static func string<T>(_ tuple: T) -> String {
        withUnsafeBytes(of: tuple) { raw in
            let bytes = raw.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
    }
}

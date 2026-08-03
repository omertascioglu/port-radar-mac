import Darwin
import Foundation

/// Everything we can learn about a process from its PID.
struct ProcessDetails: Sendable {
    let pid: Int32
    let parentPID: Int32
    let executablePath: String
    let arguments: [String]
    let workingDirectory: String?
    let startTime: Date?

    /// Full launch command; falls back to the executable when argv is unreadable.
    var command: String {
        arguments.isEmpty ? executablePath : arguments.joined(separator: " ")
    }
}

enum ProcessResolver {

    /// Returns nil when the process no longer exists (died mid-scan) or is
    /// not inspectable by the current user.
    static func resolve(pid: Int32) -> ProcessDetails? {
        guard let exe = executablePath(pid: pid) else { return nil }
        let kinfo = kinfoProc(pid: pid)
        return ProcessDetails(
            pid: pid,
            parentPID: kinfo?.kp_eproc.e_ppid ?? 0,
            executablePath: exe,
            arguments: arguments(pid: pid),
            workingDirectory: workingDirectory(pid: pid),
            startTime: kinfo.map {
                Date(timeIntervalSince1970:
                    TimeInterval($0.kp_proc.p_starttime.tv_sec)
                    + TimeInterval($0.kp_proc.p_starttime.tv_usec) / 1_000_000)
            }
        )
    }

    // MARK: - proc_pidpath

    private static func executablePath(pid: Int32) -> String? {
        // PROC_PIDPATHINFO_MAXSIZE (4 * MAXPATHLEN); the macro doesn't import into Swift.
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        let bytes = buffer.prefix(Int(length)).map(UInt8.init(bitPattern:))
        return String(decoding: bytes, as: UTF8.self)
    }

    // MARK: - kinfo_proc (parent PID, start time)

    private static func kinfoProc(pid: Int32) -> kinfo_proc? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        guard info.kp_proc.p_pid == pid else { return nil }
        return info
    }

    // MARK: - working directory

    private static func workingDirectory(pid: Int32) -> String? {
        var vnodeInfo = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.stride)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vnodeInfo, size) == size else {
            return nil
        }
        return withUnsafePointer(to: &vnodeInfo.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) {
                String(cString: $0)
            }
        }
    }

    // MARK: - argv via KERN_PROCARGS2

    private static func arguments(pid: Int32) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return [] }
        return parseProcArgs2(buffer, size: size)
    }

    /// KERN_PROCARGS2 layout: Int32 argc | exec_path\0 | \0 padding | argv strings \0-separated | env…
    static func parseProcArgs2(_ buffer: [UInt8], size: Int) -> [String] {
        guard size > MemoryLayout<Int32>.size else { return [] }
        let argc = Int(buffer.withUnsafeBytes { $0.load(as: Int32.self) })
        guard argc > 0 else { return [] }

        var index = MemoryLayout<Int32>.size
        while index < size, buffer[index] != 0 { index += 1 }  // skip exec_path
        while index < size, buffer[index] == 0 { index += 1 }  // skip padding

        var args: [String] = []
        var start = index
        while index < size, args.count < argc {
            if buffer[index] == 0 {
                args.append(String(decoding: buffer[start..<index], as: UTF8.self))
                index += 1
                start = index
            } else {
                index += 1
            }
        }
        return args
    }
}

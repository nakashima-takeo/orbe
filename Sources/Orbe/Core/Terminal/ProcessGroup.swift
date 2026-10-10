import Darwin

/// OS のプロセス表から読むプロセスグループの事実。
enum ProcessGroup {
  /// グループにプロセスがいて、どれも止まっていない（SIGSTOP・SIGTSTP で止まったものが無い）。
  static func isRunning(_ group: pid_t) -> Bool {
    guard group > 0 else { return false }
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PGRP, group]
    var size = 0
    guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return false }
    let stride = MemoryLayout<kinfo_proc>.stride
    // 1 回目と 2 回目の間に増えた分の余白。
    var processes = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 8)
    size = processes.count * stride
    guard sysctl(&mib, u_int(mib.count), &processes, &size, nil, 0) == 0 else { return false }
    let found = processes.prefix(size / stride)
    return !found.isEmpty && found.allSatisfy { Int32($0.kp_proc.p_stat) != SSTOP }
  }
}

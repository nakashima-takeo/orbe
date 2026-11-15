import Darwin

/// OS のプロセス表から読む、1 つのプロセスの事実。
public struct ProcessEntry: Equatable {
  public let parent: pid_t
  public let group: pid_t
  public let hasControllingTerminal: Bool

  /// `pid` の行を読む。いない・読めなければ nil。
  public init?(pid: pid_t) {
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
    parent = info.kp_eproc.e_ppid
    group = info.kp_eproc.e_pgid
    hasControllingTerminal = info.kp_proc.p_flag & P_CONTROLT != 0
  }
}

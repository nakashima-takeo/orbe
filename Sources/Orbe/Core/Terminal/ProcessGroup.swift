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

  /// `pid` 自身から親へ辿って、最初に制御端末を持つプロセスのグループ。辿れない・どこにも無ければ nil。
  ///
  /// agent の hook は agent の子孫なので、制御端末から切り離して（setsid で）起こされても、辿れば agent に当たる。
  /// そこで止めるのは、さらに上の祖先（agent を起こしたシェル）まで含めると、agent が止まってシェルが前面へ戻った後に
  /// 届いた報告が、シェルを agent として覚えるため。
  static func terminalGroup(of pid: pid_t) -> pid_t? {
    var current = pid
    // 親の鎖は有限だが、読む間に pid が使い回されて輪になることに備えて打ち切る。
    for _ in 0..<64 where current > 1 {
      var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, current]
      var info = kinfo_proc()
      var size = MemoryLayout<kinfo_proc>.stride
      guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
      if info.kp_proc.p_flag & P_CONTROLT != 0 { return info.kp_eproc.e_pgid }
      current = info.kp_eproc.e_ppid
    }
    return nil
  }

  /// UNIX ドメインソケットの向こうのプロセス。取れなければ nil。
  static func peer(of fd: Int32) -> pid_t? {
    var pid: pid_t = 0
    var length = socklen_t(MemoryLayout<pid_t>.size)
    guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0, pid > 0 else { return nil }
    return pid
  }
}

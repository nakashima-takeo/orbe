import Metal
import QuartzCore
import os

@testable import OrbeEditorEngine

/// 窓を出さない計測の刻み。専用のスレッドが実際の表示の刻み（120Hz）で起き、止められていない面の 1 コマを描画スレッドへ
/// 頼む。画面外のテクスチャの「画面に出た」は、GPU が描き終えた時刻（命令の列の `gpuEndTime`。完了の知らせが届いた
/// 時刻ではない）を次の刻みに切り上げた時刻で、その刻みが来たときに知らせる（画面と同じく、出る前に次のコマを描かせない）。
final class HeadlessDriver: @unchecked Sendable {
  static let period = 1.0 / 120

  private struct Present {
    let at: Double
    let done: @Sendable (Double?) -> Void
  }

  private struct State {
    var paused: [Int: Bool] = [:]
    var presents: [Present] = []
    /// 面ごとに、刻みを頼んだ回数。
    var ticks: [Int: Int] = [:]
    var running = true
  }

  /// 刻み 1 つで知らせる「画面に出た」と、刻みを頼む面。
  private struct Step {
    let due: [Present]
    let ids: [Int]
    let running: Bool
  }

  private let state = OSAllocatedUnfairLock(initialState: State())

  func start() {
    let thread = Thread { [self] in run() }
    thread.qualityOfService = .userInteractive
    thread.start()
  }

  func stop() {
    state.withLock { $0.running = false }
  }

  /// 面に画面外の出し先と刻みを結ぶ。`holdsPresents` なら、その面のコマは画面に出ない（出た知らせが来ない）。
  func bind(_ id: Int, holdsPresents: Bool = false) {
    let clock = VirtualClock(id: id, driver: self)
    state.withLock { $0.paused[id] = false }
    RenderThread.shared.perform { renderer in
      renderer.bind(
        id, target: OffscreenTarget(device: renderer.device, driver: self, holds: holdsPresents),
        clock: clock)
    }
  }

  func ticks(_ id: Int) -> Int { state.withLock { $0.ticks[id] ?? 0 } }

  func setPaused(_ id: Int, _ paused: Bool) { state.withLock { $0.paused[id] = paused } }

  func isPaused(_ id: Int) -> Bool { state.withLock { $0.paused[id] ?? true } }

  func invalidate(_ id: Int) { state.withLock { $0.paused[id] = nil } }

  /// 表示の刻みと同じく時刻どおりに起きるよう、刻みのスレッドを時間制約つきにする（普通の優先度だと
  /// `mach_wait_until` がタイマーの合体で数 ms 遅れて起き、描画スレッドのせいでない遅れを数えてしまう）。
  private static func makeRealtime(_ timebase: mach_timebase_info_data_t) {
    func ticks(_ seconds: Double) -> UInt32 {
      UInt32(seconds * 1e9 * Double(timebase.denom) / Double(timebase.numer))
    }
    var policy = thread_time_constraint_policy_data_t(
      period: ticks(period), computation: ticks(0.001), constraint: ticks(0.002), preemptible: 1)
    let count = mach_msg_type_number_t(
      MemoryLayout<thread_time_constraint_policy_data_t>.size / MemoryLayout<integer_t>.size)
    _ = withUnsafeMutablePointer(to: &policy) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        thread_policy_set(
          mach_thread_self(), thread_policy_flavor_t(THREAD_TIME_CONSTRAINT_POLICY), $0, count)
      }
    }
  }

  fileprivate func schedulePresent(at time: Double, _ done: @escaping @Sendable (Double?) -> Void) {
    state.withLock { $0.presents.append(Present(at: time, done: done)) }
  }

  private func run() {
    var timebase = mach_timebase_info_data_t()
    mach_timebase_info(&timebase)
    Self.makeRealtime(timebase)
    var tick = (CACurrentMediaTime() / Self.period).rounded(.up) * Self.period
    while true {
      mach_wait_until(UInt64(tick * 1e9) * UInt64(timebase.denom) / UInt64(timebase.numer))
      let step = state.withLock { s -> Step in
        let due = s.presents.filter { $0.at <= tick + 1e-6 }
        s.presents.removeAll { $0.at <= tick + 1e-6 }
        let ids = s.paused.filter { !$0.value }.map(\.key)
        for id in ids { s.ticks[id, default: 0] += 1 }
        return Step(due: due, ids: ids, running: s.running)
      }
      guard step.running else { return }
      for present in step.due { present.done(present.at) }
      let target = tick + Self.period
      for id in step.ids { RenderThread.shared.perform { $0.tick(id, target: target) } }
      tick += Self.period
      let now = CACurrentMediaTime()
      if now > tick { tick = (now / Self.period).rounded(.up) * Self.period }
    }
  }
}

/// 計測の刻み（止める・再開するは描画スレッドから、刻みそのものは `HeadlessDriver` が打つ）。
final class VirtualClock: FrameClock {
  private let id: Int
  private let driver: HeadlessDriver

  init(id: Int, driver: HeadlessDriver) {
    self.id = id
    self.driver = driver
  }

  var isPaused: Bool {
    get { driver.isPaused(id) }
    set { driver.setPaused(id, newValue) }
  }

  var period: Double { HeadlessDriver.period }

  func nextTarget(after now: Double) -> Double {
    ((now / period).rounded(.down) + 1) * period
  }

  func invalidate() { driver.invalidate(id) }
}

/// 画面外のテクスチャ 3 枚へ出す。画面に出ていないコマは drawable 2 枚の画面と同じく 1 つまで。
final class OffscreenTarget: FrameTarget {
  private let textures: [MTLTexture]
  private let driver: HeadlessDriver
  private let holds: Bool
  private var next = 0

  init(device: MTLDevice, driver: HeadlessDriver, holds: Bool) {
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .bgra8Unorm, width: 1600, height: 1200, mipmapped: false)
    descriptor.usage = .renderTarget
    descriptor.storageMode = .private
    textures = (0..<3).map { _ in device.makeTexture(descriptor: descriptor)! }
    self.driver = driver
    self.holds = holds
  }

  var limit: Int { 1 }

  func acquire() -> AcquiredFrame? {
    let texture = textures[next % textures.count]
    next += 1
    let driver = driver
    let holds = holds
    return AcquiredFrame(texture: texture) { commands, done in
      commands.addCompletedHandler { commands in
        guard !holds else { return }
        // エラーで終わった命令の列は描き終えた時刻を持たない（0）。画面に出なかったコマとして知らせる。
        guard commands.status == .completed, commands.gpuEndTime > 0 else {
          done(nil)
          return
        }
        let period = HeadlessDriver.period
        driver.schedulePresent(at: (commands.gpuEndTime / period).rounded(.up) * period, done)
      }
    }
  }
}

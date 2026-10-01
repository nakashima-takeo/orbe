import AppKit
import Metal
import QuartzCore
import os

/// 描画スレッド（プロセスに 1 本）。Metal の装置・命令の列・パイプライン・グリフのアトラス・行の組版のキャッシュを持つ
/// `Renderer` はこのスレッドだけが触り、外からは `perform` に渡した仕事の中でしか手に入らない（型の上で main から届かない）。
///
/// main と描画スレッドの間は、面ごとの 2 つの箱（描く材料・スクロールの状態）だけで結ぶ。描画スレッドは main を待たない
/// （main への知らせは非同期だけ）。main が描画スレッドの仕事の完了を待つのは撮影（`performAndWait`）だけ。
///
/// 描画スレッドは、最初のコマから表示の刻みに合わせた時間制約つきのスレッドになる（`adopt(framePeriod:)`）。
final class RenderThread: @unchecked Sendable {
  /// 既定の Metal の装置。取れない環境（装置の無い仮想マシンなど）では nil で、面は作らない。
  static let device: MTLDevice? = MTLCreateSystemDefaultDevice()

  /// 初めて触れたときにスレッドを起こし、シェーダのコンパイルを裏で始める。
  static let shared = RenderThread()

  private let thread: Thread
  /// スレッドの run loop と持ち物。スレッドが起きて書き、`init` はそれを待ってから返る（以後は変わらない）。
  private var runLoop: CFRunLoop?
  private var renderer: Renderer?

  private init() {
    let ready = DispatchSemaphore(value: 0)
    let box = ThreadBox()
    thread = Thread {
      box.owner?.run(ready: ready)
    }
    thread.name = "orbe.editor.render"
    thread.qualityOfService = .userInteractive
    box.owner = self
    thread.start()
    ready.wait()
  }

  private func run(ready: DispatchSemaphore) {
    runLoop = CFRunLoopGetCurrent()
    renderer = Renderer(device: Self.device!)
    // 仕事の無い間も run loop が抜けないよう、何も届かない口を 1 つ置く。
    RunLoop.current.add(Port(), forMode: .default)
    ready.signal()
    while true { CFRunLoopRun() }
  }

  /// 描画スレッドで仕事をする（待たない）。
  func perform(_ work: @escaping @Sendable (Renderer) -> Void) {
    guard let runLoop else { return }
    CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue) { [self] in
      work(renderer!)
    }
    CFRunLoopWakeUp(runLoop)
  }

  /// 描画スレッドで仕事をし、その結果を待つ。撮影だけが使う。
  func performAndWait<T: Sendable>(_ work: @escaping @Sendable (Renderer) -> T) -> T {
    if Thread.current === thread { return work(renderer!) }
    let done = DispatchSemaphore(value: 0)
    let result = OSAllocatedUnfairLock<T?>(initialState: nil)
    perform { renderer in
      let value = work(renderer)
      result.withLock { $0 = value }
      done.signal()
    }
    done.wait()
    return result.withLock { $0! }
  }

  /// 1 コマの計算の見込み（秒）。行を組まないコマの CPU の関門（p99）と同じ値。
  static let frameComputation = 0.002

  /// 描画スレッド（呼んだスレッド）を、表示の刻み `period`（秒）に合わせた時間制約つきのスレッドにする。
  ///
  /// 表示の刻みごとに起き、画面に出る予定の刻みの `FrameRecorder.commitMargin` 前までに 1 コマの命令を出し終える仕事
  /// なので、Mach の時間制約つきの方針で「刻み `period` ごとに `frameComputation` の計算を、起きてから
  /// `period − commitMargin` 以内に」と申告する。優先度（QoS）だけのスレッドは、混んだ機械で同じ優先度の他の仕事に
  /// 1 刻み近く待たされて起きる（そのコマは刻みに間に合わない）。時間制約つきのスレッドは普通の優先度の仕事より先に
  /// 起き、刻みと締め切りが性能の制御に渡る。どのコアに載るかは OS が決め、コマの多くは効率コアで動く（申告の計算の量
  /// では変わらない）。
  static func adopt(framePeriod period: Double) {
    var timebase = mach_timebase_info_data_t()
    mach_timebase_info(&timebase)
    func ticks(_ seconds: Double) -> UInt32 {
      UInt32(seconds * 1e9 * Double(timebase.denom) / Double(timebase.numer))
    }
    let constraint = max(period - FrameRecorder.commitMargin, frameComputation)
    var policy = thread_time_constraint_policy_data_t(
      period: ticks(period), computation: ticks(frameComputation), constraint: ticks(constraint),
      preemptible: 1)
    let count = mach_msg_type_number_t(
      MemoryLayout<thread_time_constraint_policy_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &policy) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        thread_policy_set(
          mach_thread_self(), thread_policy_flavor_t(THREAD_TIME_CONSTRAINT_POLICY), $0, count)
      }
    }
    if result != KERN_SUCCESS {
      log.fault("描画スレッドを時間制約つきにできなかった: \(result, privacy: .public)")
    }
  }

  private static let log = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "dev.orbe", category: "editor-render")

  /// 描画スレッドの上で呼ばれる口（display link の呼び出し）から、持ち物を使う。
  func onThread(_ body: (Renderer) -> Void) {
    precondition(Thread.current === thread, "描画スレッドの外から持ち物に触れた")
    body(renderer!)
  }

  /// スレッドの本体へ自分を渡す箱（`init` の中でまだ自分を捕まえられないため）。
  private final class ThreadBox: @unchecked Sendable {
    var owner: RenderThread?
  }
}

/// スレッドをまたいで一度だけ渡す値（渡した側はもう触らない）。main と共有し続けるもの（面の層）には使わない。
struct Transfer<Value>: @unchecked Sendable {
  let value: Value
}

/// シェーダを実行時にコンパイルしたパイプライン。コンパイルは裏で 1 回だけ行い、済むまで描かない（撮影は待つ）。
final class PipelineGate: Sendable {
  struct Pipelines: @unchecked Sendable {
    let mono: MTLRenderPipelineState
    let color: MTLRenderPipelineState
    let shape: MTLRenderPipelineState
    let minimap: MTLRenderPipelineState
    let layer: MTLRenderPipelineState
  }

  private let state = OSAllocatedUnfairLock<Pipelines?>(initialState: nil)
  private let done = DispatchGroup()

  init(device: MTLDevice, onReady: @escaping @Sendable () -> Void) {
    done.enter()
    let transfer = Transfer(value: device)
    DispatchQueue.global(qos: .userInitiated).async { [state, done] in
      let pipelines = Self.compile(transfer.value)
      state.withLock { $0 = pipelines }
      done.leave()
      onReady()
    }
  }

  /// 済んでいればパイプライン（済んでいなければ nil。待たない）。
  var ready: Pipelines? { state.withLock { $0 } }

  /// 済むまで待つ。
  func wait() -> Pipelines? {
    done.wait()
    return ready
  }

  private static let log = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "dev.orbe", category: "editor-render")

  /// コンパイルに失敗したら、Metal のエラー文（どこが悪いか）をログに出す（起きないはずの状態なので debug では止める）。
  private static func compile(_ device: MTLDevice) -> Pipelines? {
    do {
      return try makePipelines(device)
    } catch {
      log.fault("シェーダのコンパイルに失敗した: \(String(describing: error), privacy: .public)")
      assertionFailure("シェーダのコンパイルに失敗した: \(error)")
      return nil
    }
  }

  private static func makePipelines(_ device: MTLDevice) throws -> Pipelines {
    let library = try device.makeLibrary(source: Shaders.source, options: nil)
    func pipeline(_ vertex: String, _ fragment: String) throws -> MTLRenderPipelineState {
      let descriptor = MTLRenderPipelineDescriptor()
      descriptor.vertexFunction = library.makeFunction(name: vertex)
      descriptor.fragmentFunction = library.makeFunction(name: fragment)
      let attachment = descriptor.colorAttachments[0]!
      attachment.pixelFormat = .bgra8Unorm
      attachment.isBlendingEnabled = true
      attachment.sourceRGBBlendFactor = .one
      attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
      attachment.sourceAlphaBlendFactor = .one
      attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
      return try device.makeRenderPipelineState(descriptor: descriptor)
    }
    return Pipelines(
      mono: try pipeline("glyph_vertex", "mono_fragment"),
      color: try pipeline("glyph_vertex", "color_fragment"),
      shape: try pipeline("shape_vertex", "shape_fragment"),
      minimap: try pipeline("minimap_vertex", "minimap_fragment"),
      layer: try pipeline("glyph_vertex", "layer_fragment"))
  }
}

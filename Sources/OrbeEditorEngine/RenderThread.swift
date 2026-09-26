import AppKit
import Metal
import QuartzCore
import os

/// 描画スレッド（プロセスに 1 本）。Metal の装置・命令の列・パイプライン・グリフのアトラス・行の組版のキャッシュを持つ
/// `Renderer` はこのスレッドだけが触り、外からは `perform` に渡した仕事の中でしか手に入らない（型の上で main から届かない）。
///
/// main と描画スレッドの間は、面ごとの 2 つの箱（描く材料・スクロールの状態）だけで結ぶ。描画スレッドは main を待たない
/// （main への知らせは非同期だけ）。main が描画スレッドの仕事の完了を待つのは撮影（`performAndWait`）だけ。
final class RenderThread: @unchecked Sendable {
  /// 既定の Metal の装置。取れない環境（装置の無い仮想マシンなど）では nil で、新しい面は作らない。
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

/// スレッドをまたいで一度だけ渡す値（渡した側はもう触らない）。
struct Transfer<Value>: @unchecked Sendable {
  let value: Value
}

/// シェーダを実行時にコンパイルしたパイプライン。コンパイルは裏で 1 回だけ行い、済むまで描かない（撮影は待つ）。
final class PipelineGate: Sendable {
  struct Pipelines: @unchecked Sendable {
    let mono: MTLRenderPipelineState
    let color: MTLRenderPipelineState
    let shape: MTLRenderPipelineState
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

  private static func compile(_ device: MTLDevice) -> Pipelines? {
    guard let library = try? device.makeLibrary(source: Shaders.source, options: nil) else {
      return nil
    }
    func pipeline(_ vertex: String, _ fragment: String) -> MTLRenderPipelineState? {
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
      return try? device.makeRenderPipelineState(descriptor: descriptor)
    }
    guard let mono = pipeline("glyph_vertex", "mono_fragment"),
      let color = pipeline("glyph_vertex", "color_fragment"),
      let shape = pipeline("shape_vertex", "shape_fragment")
    else { return nil }
    return Pipelines(mono: mono, color: color, shape: shape)
  }
}

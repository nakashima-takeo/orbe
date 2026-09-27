import AppKit
import Metal
import QuartzCore

/// 符号化の決まりごと（パイプライン・アトラスの頁・消す色）。
struct Pass {
  let pipelines: PipelineGate.Pipelines
  let atlas: GlyphAtlas
  /// 消す色。nil は透明（下の地を透かす）。
  var clear: MTLClearColor?
}

extension Renderer {
  /// 組み立てた instance を GPU の buffer に写し、描く命令を積む。buffer が全部使用中なら nil（待たない）。
  func encode(
    _ built: FrameBuilder, into texture: MTLTexture, _ pass: Pass, _ commands: MTLCommandBuffer
  ) -> Int? {
    guard let index = acquireBuffer(length: built.byteCount) else { return nil }
    buffers[index].busy = true
    encode(built, buffer: buffers[index].buffer, into: texture, pass, commands)
    return index
  }

  private func acquireBuffer(length: Int) -> Int? {
    let needed = max(length, 64 << 10)
    if let index = buffers.firstIndex(where: { !$0.busy && $0.buffer.length >= needed }) {
      return index
    }
    if let index = buffers.firstIndex(where: { !$0.busy }) {
      guard let buffer = device.makeBuffer(length: needed * 2, options: .storageModeShared) else {
        return nil
      }
      buffers[index].buffer = buffer
      return index
    }
    guard buffers.count < Self.gpuLimit,
      let buffer = device.makeBuffer(length: needed * 2, options: .storageModeShared)
    else { return nil }
    buffers.append((buffer, false))
    return buffers.count - 1
  }

  /// 下から、行の装備 → 選択の地 → 本文の字（行番号の列の右だけ）→ 色付きの字 → 行番号 → git の印 → キャレット。
  func encode(
    _ built: FrameBuilder, buffer: MTLBuffer, into texture: MTLTexture, _ pass: Pass,
    _ commands: MTLCommandBuffer
  ) {
    let descriptor = MTLRenderPassDescriptor()
    descriptor.colorAttachments[0].texture = texture
    descriptor.colorAttachments[0].loadAction = .clear
    descriptor.colorAttachments[0].storeAction = .store
    descriptor.colorAttachments[0].clearColor =
      pass.clear ?? MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
    guard let encoder = commands.makeRenderCommandEncoder(descriptor: descriptor) else { return }
    var viewport = SIMD2<Float>(Float(texture.width), Float(texture.height))
    encoder.setVertexBytes(&viewport, length: MemoryLayout<SIMD2<Float>>.size, index: 1)
    var offset = 0
    func upload<T>(_ items: [T]) -> Int? {
      guard !items.isEmpty else { return nil }
      let start = offset
      precondition(
        start + items.count * MemoryLayout<T>.stride <= buffer.length,
        "instance の buffer が足りない（byteCount と描く層の並びが食い違っている）")
      items.withUnsafeBytes {
        buffer.contents().advanced(by: start).copyMemory(from: $0.baseAddress!, byteCount: $0.count)
      }
      offset += (items.count * MemoryLayout<T>.stride + 255) & ~255
      return start
    }
    func glyphs(
      _ pages: [[GlyphInstance]], _ textures: [MTLTexture], _ pipeline: MTLRenderPipelineState
    ) {
      for (page, items) in pages.enumerated() where page < textures.count {
        guard let start = upload(items) else { continue }
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBuffer(buffer, offset: start, index: 0)
        encoder.setFragmentTexture(textures[page], index: 0)
        encoder.drawPrimitives(
          type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: items.count)
      }
    }
    func shapes(_ items: [ShapeInstance]) {
      guard let start = upload(items) else { return }
      encoder.setRenderPipelineState(pass.pipelines.shape)
      encoder.setVertexBuffer(buffer, offset: start, index: 0)
      encoder.drawPrimitives(
        type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: items.count)
    }
    encoder.setScissorRect(built.textScissor)
    shapes(built.decorShapes)
    shapes(built.underShapes)
    glyphs(built.text, pass.atlas.monoPages, pass.pipelines.mono)
    glyphs(built.color, pass.atlas.colorPages, pass.pipelines.color)
    encoder.setScissorRect(built.gutterScissor)
    glyphs(built.gutter, pass.atlas.monoPages, pass.pipelines.mono)
    shapes(built.shapes)
    encoder.setScissorRect(built.textScissor)
    shapes(built.overShapes)
    encoder.endEncoding()
  }

  // MARK: - 撮影

  /// 今の位置の 1 コマを画面外に描いた絵（面が描く色空間の絵。キャレットは点滅の位相に依らず、焦点があれば描く——撮影を
  /// 時刻に依らせない）。`background` を与えればその不透明な地に描く（無ければ透明な地）。シェーダのコンパイルが済むまで
  /// 待つ。
  func snapshot(_ id: Int, background: MTLClearColor? = nil) -> CGImage? {
    guard let slot = slot(id), let pipelines = gate.wait() else { return nil }
    let material = slot.material.take()
    slot.lines.receive(material.rowEdits)
    slot.keystrokes += material.keystrokes
    let (width, height) = Self.pixelSize(material)
    guard material.content != nil, material.palette != nil, width > 0, height > 0 else {
      return nil
    }
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
    descriptor.usage = [.renderTarget, .shaderRead]
    descriptor.storageMode = .shared
    guard let texture = device.makeTexture(descriptor: descriptor),
      let commands = queue.makeCommandBuffer()
    else { return nil }
    let atlas = atlas(scale: material.scale, space: material.space)
    if atlas.isFull { atlas.reset() }
    let revealed = begin(slot, material)
    let built = slot.builder
    built.build(
      FrameBuilder.Source(
        material: material, position: slot.scroll.peek(at: CACurrentMediaTime()).position,
        caretVisible: material.caret.showsCaret,
        pixels: (width, height), atlas: atlas, config: slot.config), cache: slot.lines, fonts: fonts
    )
    let widened = slot.scroll.measured(
      longestLine: built.longestLine, version: material.content?.version)
    if widened || revealed { slot.notify() }
    guard
      let buffer = device.makeBuffer(
        length: max(built.byteCount, 256), options: .storageModeShared)
    else { return nil }
    encode(
      built, buffer: buffer, into: texture,
      Pass(pipelines: pipelines, atlas: atlas, clear: background), commands)
    commands.commit()
    commands.waitUntilCompleted()
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    texture.getBytes(
      &bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
    guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
    return CGImage(
      width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
      space: material.space,
      bitmapInfo: CGBitmapInfo(
        rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
          | CGBitmapInfo.byteOrder32Little.rawValue),
      provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
  }
}

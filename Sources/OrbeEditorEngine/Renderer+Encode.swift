import AppKit
import Metal
import OrbeEditorCore
import QuartzCore

/// 符号化の決まりごと（パイプライン・アトラスの頁・消す色・ミニマップの字形の表と装飾の 1 枚と色の表）。
struct Pass {
  let pipelines: PipelineGate.Pipelines
  let atlas: GlyphAtlas
  /// 消す色。nil は透明（下の地を透かす）。
  var clear: MTLClearColor?
  var minimapSheet: MTLTexture?
  var minimapLayer: MTLTexture?
  /// ミニマップの字の色（0 は素の文字色、1… は役割）。
  var minimapColors: [UInt32] = []
}

/// 命令の列 1 つの instance の buffer に、描く層の順に詰めていく（層ごとに 256 バイトに揃える）。
final class InstanceWriter {
  private let buffer: MTLBuffer
  private var offset = 0

  init(buffer: MTLBuffer) {
    self.buffer = buffer
  }

  private func upload<T>(_ items: [T]) -> Int? {
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
    _ pages: [[GlyphInstance]], _ textures: [MTLTexture], _ pipeline: MTLRenderPipelineState,
    _ encoder: MTLRenderCommandEncoder
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

  func shapes(_ items: [ShapeInstance], _ encoder: MTLRenderCommandEncoder, _ pass: Pass) {
    guard let start = upload(items) else { return }
    encoder.setRenderPipelineState(pass.pipelines.shape)
    encoder.setVertexBuffer(buffer, offset: start, index: 0)
    encoder.drawPrimitives(
      type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: items.count)
  }
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

  /// 下から、行の装備 → 選択の地 → 強調の地 → 本文の字（行番号の列の右だけ）→ 色付きの字 → 行番号 → git の印 → キャレット
  /// → ミニマップ（字 → 装飾 → 帯）。ミニマップの装飾は先に画面外の 1 枚に描き、組として不透明度 .9 で重ねる（重なる装飾の
  /// 合成が今の面の透明の層と同じになる）。
  func encode(
    _ built: FrameBuilder, buffer: MTLBuffer, into texture: MTLTexture, _ pass: Pass,
    _ commands: MTLCommandBuffer
  ) {
    let instances = InstanceWriter(buffer: buffer)
    if let layer = pass.minimapLayer, !built.minimap.decorations.isEmpty {
      let descriptor = MTLRenderPassDescriptor()
      descriptor.colorAttachments[0].texture = layer
      descriptor.colorAttachments[0].loadAction = .clear
      descriptor.colorAttachments[0].storeAction = .store
      descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
      guard let encoder = commands.makeRenderCommandEncoder(descriptor: descriptor) else { return }
      var viewport = SIMD2<Float>(Float(layer.width), Float(layer.height))
      encoder.setVertexBytes(&viewport, length: MemoryLayout<SIMD2<Float>>.size, index: 1)
      instances.shapes(built.minimap.decorations, encoder, pass)
      encoder.endEncoding()
    }
    let descriptor = MTLRenderPassDescriptor()
    descriptor.colorAttachments[0].texture = texture
    descriptor.colorAttachments[0].loadAction = .clear
    descriptor.colorAttachments[0].storeAction = .store
    descriptor.colorAttachments[0].clearColor =
      pass.clear ?? MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
    guard let encoder = commands.makeRenderCommandEncoder(descriptor: descriptor) else { return }
    var viewport = SIMD2<Float>(Float(texture.width), Float(texture.height))
    encoder.setVertexBytes(&viewport, length: MemoryLayout<SIMD2<Float>>.size, index: 1)
    encoder.setScissorRect(built.textScissor)
    instances.shapes(built.decorShapes, encoder, pass)
    instances.shapes(built.underShapes, encoder, pass)
    instances.shapes(built.highlightShapes, encoder, pass)
    instances.glyphs(built.text, pass.atlas.monoPages, pass.pipelines.mono, encoder)
    instances.glyphs(built.color, pass.atlas.colorPages, pass.pipelines.color, encoder)
    encoder.setScissorRect(built.gutterScissor)
    instances.glyphs(built.gutter, pass.atlas.monoPages, pass.pipelines.mono, encoder)
    instances.shapes(built.shapes, encoder, pass)
    encoder.setScissorRect(built.textScissor)
    instances.shapes(built.overShapes, encoder, pass)
    encodeMinimap(built.minimap, instances, encoder, pass, texture)
    encoder.endEncoding()
  }

  /// ミニマップの字（チャンクごとに上端を入れて描く）と、装飾の 1 枚。
  private func encodeMinimap(
    _ minimap: MinimapFrame, _ instances: InstanceWriter, _ encoder: MTLRenderCommandEncoder,
    _ pass: Pass, _ texture: MTLTexture
  ) {
    let rect = minimap.rect
    guard rect.z > 0, rect.w > 0 else { return }
    let left = Int(min(max(0, rect.x), Float(texture.width)))
    let right = Int(min(max(Float(left), rect.x + rect.z), Float(texture.width)))
    encoder.setScissorRect(
      MTLScissorRect(x: left, y: 0, width: right - left, height: texture.height))
    if let sheet = pass.minimapSheet, !minimap.chunks.isEmpty {
      encoder.setRenderPipelineState(pass.pipelines.minimap)
      encoder.setFragmentTexture(sheet, index: 0)
      var colors = pass.minimapColors
      encoder.setFragmentBytes(
        &colors, length: MemoryLayout<UInt32>.stride * colors.count, index: 1)
      for chunk in minimap.chunks {
        var uniforms = minimap.uniforms
        uniforms.origin.y = chunk.top
        encoder.setVertexBuffer(chunk.buffer, offset: 0, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<MinimapUniforms>.stride, index: 2)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<MinimapUniforms>.stride, index: 0)
        encoder.drawPrimitives(
          type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: chunk.count)
      }
    }
    if let layer = pass.minimapLayer, !minimap.decorations.isEmpty {
      let alpha = UInt32((Float(MinimapCharSheet.opacity) * 255).rounded())
      let quad = GlyphInstance(
        position: SIMD2(rect.x, rect.y), size: SIMD2(Float(layer.width), Float(layer.height)),
        uv: SIMD2(0, 0), color: 0x00FF_FFFF | alpha << 24)
      instances.glyphs([[quad]], [layer], pass.pipelines.color, encoder)
    }
  }

  /// ミニマップを描く決まりごとを足す——字形の表（倍率ごとに 1 回作る）・装飾の 1 枚（ミニマップの大きさ。変われば作り
  /// 直す）・字の色の表。
  func minimapPass(_ slot: SurfaceSlot, _ material: FrameMaterial, _ pass: Pass) -> Pass {
    let minimap = slot.builder.minimap
    guard !minimap.chunks.isEmpty || !minimap.decorations.isEmpty, let palette = material.palette
    else { return pass }
    var pass = pass
    if slot.minimapSheet?.scale != minimap.scale {
      slot.minimapSheet = makeSheet(scale: minimap.scale, font: slot.config.font).map {
        (minimap.scale, $0)
      }
    }
    pass.minimapSheet = slot.minimapSheet?.texture
    let width = Int(minimap.rect.z)
    let height = Int(minimap.rect.w)
    if !minimap.decorations.isEmpty {
      if slot.minimapLayer?.width != width || slot.minimapLayer?.height != height {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
          pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        slot.minimapLayer = device.makeTexture(descriptor: descriptor)
      }
      pass.minimapLayer = slot.minimapLayer
    }
    pass.minimapColors =
      [palette.text.packed]
      + SyntaxRole.allCases.map { (palette.roles[$0] ?? palette.text).packed }
    return pass
  }

  /// 字形の表を 1 枚の texture に並べる（字形 `g` の (x, y) は texel (g × 幅 + x, y)）。
  private func makeSheet(scale: Int, font: CTFont) -> MTLTexture? {
    let sheet = MinimapCharSheet(scale: scale, font: font)
    let width = MinimapLine.glyphCount * sheet.glyphWidth
    let height = sheet.glyphHeight
    var bytes = [UInt8](repeating: 0, count: width * height)
    for glyph in 0..<MinimapLine.glyphCount {
      for y in 0..<height {
        for x in 0..<sheet.glyphWidth {
          bytes[y * width + glyph * sheet.glyphWidth + x] = sheet.value(glyph, x: x, y: y)
        }
      }
    }
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .r8Unorm, width: width, height: height, mipmapped: false)
    descriptor.usage = .shaderRead
    guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
    texture.replace(
      region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: bytes,
      bytesPerRow: width)
    return texture
  }

  // MARK: - 撮影

  /// 今の位置の 1 コマを画面外に描いた絵（面が描く色空間の絵。キャレットは点滅の位相に依らず、焦点があれば描く——撮影を
  /// 時刻に依らせない）。`background` を与えればその不透明な地に描く（無ければ透明な地）。シェーダのコンパイルが済むまで
  /// 待つ。
  func snapshot(_ id: Int, background: MTLClearColor? = nil) -> CGImage? {
    guard let slot = slot(id), let pipelines = gate.wait() else { return nil }
    let material = slot.material.take()
    slot.receive(material)
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
    slot.build(
      material, scroll: slot.scroll.peek(at: CACurrentMediaTime()),
      caretVisible: material.caret.showsCaret, target: ((width, height), atlas), fonts: fonts)
    let widened = slot.scroll.measured(
      longestLine: built.longestLine, version: material.content?.version)
    if widened || revealed { slot.notify() }
    guard
      let buffer = device.makeBuffer(
        length: max(built.byteCount, 256), options: .storageModeShared)
    else { return nil }
    encode(
      built, buffer: buffer, into: texture,
      minimapPass(slot, material, Pass(pipelines: pipelines, atlas: atlas, clear: background)),
      commands)
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

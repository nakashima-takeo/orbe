import AppKit
import CoreText
import OrbeEditorCore

/// 絵の差し込みを描く材料——載せる側が描いた絵を、描画スレッドがそのまま置ける形にしたもの。絵の層ごとの材料（座標は層の
/// 原点からの pt）と層の原点（絵の差し込みの左上からの pt）を、絵の層の順に持つ。main が絵を問うたとき・外観や倍率が
/// 変わったときに作り、並びと同じ書き込みで材料の箱に載せる。字は Core Text で組んだグリフと送り、色は面の外観と色空間で
/// 解いた値、画像は倍率で描いた画素。
///
/// フォントは不変で、Core Text はスレッドをまたいだ利用を保証する（`SurfaceConfig` と同じ）。
struct ZoneMaterial: @unchecked Sendable {
  /// 層 1 つの材料（座標は層の原点から）。
  struct Layer: @unchecked Sendable {
    var boxes: [Box] = []
    var runs: [Run] = []
    var images: [Image] = []
    var fields: [Field] = []
  }

  /// 箱 1 つ（塗り・枠線・影は無ければ透明）。
  struct Box {
    var frame: CGRect
    /// 角ごとの半径（左上・右上・右下・左下）。
    var radius: SIMD4<Float>
    var fill: FrameColor
    var stroke: FrameColor
    var strokeWidth: Float
    var shadow: FrameColor
    var shadowOffset: Float
    var shadowBlur: Float
  }

  /// 組んだ字の連なり 1 つ（1 つのフォントと色）。`origin` は行の基線の左端（層の座標）、`xs` は行の左端からの x、`ys` は
  /// 基線からの上向きのずれ（全部 0 なら空）。
  struct Run {
    var font: CTFont
    var glyphs: [CGGlyph]
    var xs: [Float]
    var ys: [Float]
    var origin: CGPoint
    var ink: InkColor
  }

  struct Image {
    var frame: CGRect
    var pixels: ZonePixels
  }

  /// 入力欄（場の通し番号と、文を打つ矩形）。
  struct Field {
    var serial: Int
    var frame: CGRect
  }

  /// 層ごとの原点と材料（絵の層の順）。
  var layers: [(origin: CGPoint, layer: Layer)] = []

  /// 材料が指す画像の画素の鍵。
  var pixelKeys: [Int] { layers.flatMap { $0.layer.images.map(\.pixels.key) } }
}

/// 倍率で描いた画像の画素（RGBA・乗算済み。描く色空間の値）。`key` は描画スレッドの画像の地図の鍵。
final class ZonePixels: Sendable {
  let key: Int
  let width: Int
  let height: Int
  let bytes: [UInt8]

  init(key: Int, width: Int, height: Int, bytes: [UInt8]) {
    self.key = key
    self.width = width
    self.height = height
    self.bytes = bytes
  }
}

/// 絵の差し込みの文の選択の地（絵の差し込みの中の矩形）。選択は絵の差し込みの文が主の間だけある。
struct ZoneSelectionMaterial: Equatable, Sendable {
  var zone: ObjectIdentifier
  var rects: [CGRect]
  /// 面に焦点がある（焦点のある選択の色）。
  var focused: Bool
}

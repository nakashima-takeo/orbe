import AppKit

/// 本文へ落としたときにすること。
enum DropAction: Equatable {
  /// ファイルを開く（載せる側が開く）。
  case open([URL])
  /// ファイルのパスの文字列（載せる側が決める）を位置へ入れる。
  case insertPaths([URL], at: Int)
  /// 文字列を位置へ入れる。`moving` があれば、その範囲を消す移動。
  case insert(String, at: Int, moving: NSRange?)
}

/// 落とすときの操作・落とす位置の印・すること（何もしないなら `action` が nil）。
struct DropPlan: Equatable {
  var operation: NSDragOperation = []
  var indicator: Int?
  var action: DropAction?
}

/// 落とすときの状況——落とす位置と板の中身と送り手と修飾。
struct DropSituation {
  /// 落とす位置（本文の外なら nil）。
  var offset: Int?
  /// 板のファイルの URL（無ければ nil）。
  var files: [URL]?
  /// 板の平文（無ければ nil）。
  var string: String?
  /// この面から始めたドラッグなら、運んでいる範囲（他の送り手なら nil）。
  var dragged: NSRange?
  /// 送り手が移動を許していない（⌥ を押している・他の文書やアプリから）。
  var copying = false
  /// ⇧ を押している。
  var shift = false
  /// ファイルを受ける（本文の場で、開く・パスにする載せる側がいる）。受けなければファイルは拒む。
  var opensFiles = true
  /// 字を入れられる（読むだけの場でない）。入れられなければ、ファイルを開くことだけを受ける。
  var inserts = true
}

/// 本文へ落とすときの判断（純関数）。ファイルは開く（⇧ ならパスを入れる）。この面から始めたドラッグは移動（コピーの操作
/// ならコピー）で、選択の中（両端を含む）へは落とさない——ただしコピーで選択の端なら、その隣へ写す。他の送り手の文字は
/// コピーで入れる。
enum DropRules {
  static func plan(_ drop: DropSituation) -> DropPlan {
    guard let offset = drop.offset else { return DropPlan() }
    if let files = drop.files {
      guard drop.opensFiles else { return DropPlan() }
      guard drop.shift else { return DropPlan(operation: .copy, action: .open(files)) }
      guard drop.inserts else { return DropPlan() }
      return DropPlan(operation: .copy, indicator: offset, action: .insertPaths(files, at: offset))
    }
    guard drop.inserts, let string = drop.string else { return DropPlan() }
    guard let dragged = drop.dragged else {
      return DropPlan(
        operation: .copy, indicator: offset, action: .insert(string, at: offset, moving: nil))
    }
    let copying = drop.copying
    let edge = offset == dragged.location || offset == NSMaxRange(dragged)
    let inside = offset >= dragged.location && offset <= NSMaxRange(dragged)
    guard !inside || (copying && edge) else { return DropPlan() }
    return DropPlan(
      operation: copying ? .copy : .move, indicator: offset,
      action: .insert(string, at: offset, moving: copying ? nil : dragged))
  }
}

import Foundation

/// 取り込んだカスタム音源の置き場（`StateDir.base()/sounds/`）と、その後始末。
///
/// 保存名は**取り込みごとの一意名**にしてある。決定論的な名前（スコープ×イベント）で上書きする案は、
/// `Workspace.id` が起動ごとに振り直される事実と噛み合わず、再起動を跨ぐと別 workspace の音源を
/// 黙って書き潰す。一意名なら in-place 上書きが起きないので、再生中バッファとの競合も
/// 再生層のキャッシュ破棄も要らない（キャッシュキーがファイル名＝新しい名前は新しいキー）。
///
/// 代わりに要るのが後始末で、それは**参照集合 GC 1 本**（`collectGarbage`）に閉じる。参照カウントも
/// 走査ロジックも持たない。
enum CustomSoundStore {
  /// テスト用にディレクトリを差し替える（永続 4 種の `fileURLOverride` と同じ扱い＝隔離ハーネスが張る）。
  nonisolated(unsafe) static var directoryURLOverride: URL?

  /// 音源ディレクトリ。存在しなければ作成する（解決できなければ nil）。
  static func directoryURL() -> URL? {
    let url =
      directoryURLOverride ?? StateDir.base()?.appendingPathComponent("sounds", isDirectory: true)
    guard let url else { return nil }
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  /// 相対名からファイルの URL。ディレクトリを跨ぐ名前は受けない（設定は人が手で書ける入力なので、
  /// 名前の健全性はここでも見る——`CustomSoundSource` の parse と二重に守る値域ではなく、
  /// 「この列挙の中のファイルしか触らない」という別の約束）。
  static func url(for file: String) -> URL? {
    guard !file.isEmpty, !file.contains("/"), file != "..", let dir = directoryURL() else {
      return nil
    }
    return dir.appendingPathComponent(file)
  }

  /// 新しい取り込み先の名前。48 kHz モノラル Float32 の WAV として書かれる。
  static func newFileName() -> String { "\(UUID().uuidString.lowercased()).wav" }

  /// 参照されていないファイルを消す。参照集合は「global 層＋全 workspace の上書き層が指す file 名」で、
  /// 呼ぶのは**参照集合が変わったとき**だけ（取り込みの確定時・workspace の削除時）。
  ///
  /// 毎回 `sounds/` 全体を参照集合と突き合わせるので、手編集や書き込み途中のクラッシュが残した孤児も
  /// 次にここが走ったときにまとめて回収される——起動時に別途走らせても回収範囲は増えない。
  static func collectGarbage(referenced: Set<String>) {
    guard let dir = directoryURL(),
      let files = try? FileManager.default.contentsOfDirectory(
        at: dir, includingPropertiesForKeys: nil)
    else { return }
    for file in files where !referenced.contains(file.lastPathComponent) {
      try? FileManager.default.removeItem(at: file)
    }
  }
}

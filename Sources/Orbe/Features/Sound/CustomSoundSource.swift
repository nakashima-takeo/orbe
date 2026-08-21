import Foundation

/// 取り込み済みのカスタム音源を指す設定値。`sounds/` 配下の実体と、それを人に見せるための
/// メタデータを 1 組で持つ。
///
/// 3 つの値は**取り込みという単一の書き込み点で同時に書かれ、以後ファイルは書き換わらない**ので
/// 互いにドリフトしない（差し替えは新しい名前で書いて値ごと置き換える）。map の生読みを各所に
/// 散らさず、parse をこの `init?` 1 箇所に閉じることで「不正な map ＝未設定」という規則も 1 つになる。
struct CustomSoundSource: Equatable {
  /// `sounds/` 配下の相対名（取り込みごとの一意名）。ディレクトリを跨ぐ名前は受けない。
  let file: String
  /// 元ファイル名（表示用）。
  let name: String
  /// 取り込み後の実長（秒）。試聴 EQ の点灯時間が読む。
  let duration: Double

  /// duration はミリ秒へ丸めて持つ——ディスク表現（小数 3 桁）と往復しても値が変わらないため。
  init(file: String, name: String, duration: Double) {
    self.file = file
    self.name = name
    self.duration = (duration * 1000).rounded() / 1000
  }
}

extension CustomSoundSource: SettingConvertible {
  init?(settingValue: SettingValue) {
    guard case .stringMap(let map) = settingValue,
      let file = map["file"], !file.isEmpty, !file.contains("/"), file != "..",
      let duration = map["duration"].flatMap(Double.init), duration > 0, duration.isFinite
    else { return nil }
    // name の欠落だけは未設定にしない——鳴らせる実体はあるので、表示名をファイル名で代替する。
    self.init(file: file, name: map["name"] ?? file, duration: duration)
  }

  var settingValue: SettingValue {
    .stringMap(["file": file, "name": name, "duration": String(format: "%.3f", duration)])
  }
}

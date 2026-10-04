// swiftlint:disable file_length type_body_length

/// VS Code の編集の規則の正解——monaco-editor 0.57.0 の `WordOperations` と
/// `MoveOperations` を動かした結果（scripts/gen-vscode-edit-cases.sh が生成する。手で直さない）。位置はどれも本文の
/// オフセット。範囲は [始まり, 終わり]（消さないなら空）。
enum VSCodeEditCases {
  struct Case {
    let text: String
    let offset: Int
    let wordLeft: Int
    let wordRight: Int
    let deleteLeft: [Int]
    let deleteRight: [Int]
    let word: [Int]
    let home: Int
  }

  static let cases: [Case] = [
    .init(
      text: "foo.bar(baz)  qux\n  let x = a->b; // c\n\tif (a == b) {", offset: 0, wordLeft: 0,
      wordRight: 3, deleteLeft: [], deleteRight: [0, 3], word: [0, 3], home: 0),
    .init(
      text: "foo.bar(baz)  qux\n  let x = a->b; // c\n\tif (a == b) {", offset: 1, wordLeft: 0,
      wordRight: 3, deleteLeft: [0, 1], deleteRight: [1, 3], word: [0, 3], home: 0),
    .init(
      text: "foo.bar(baz)  qux\n  let x = a->b; // c\n\tif (a == b) {", offset: 2, wordLeft: 0,
      wordRight: 3, deleteLeft: [0, 2], deleteRight: [2, 3], word: [0, 3], home: 0),
    .init(
      text: "foo.bar(baz)  qux\n  let x = a->b; // c\n\tif (a == b) {", offset: 3, wordLeft: 0,
      wordRight: 7, deleteLeft: [0, 3], deleteRight: [3, 4], word: [0, 3], home: 0),
    .init(
      text: "foo.bar(baz)  qux\n  let x = a->b; // c\n\tif (a == b) {", offset: 4, wordLeft: 0,
      wordRight: 7, deleteLeft: [3, 4], deleteRight: [4, 7], word: [4, 7], home: 0),
    .init(
      text: "foo.bar(baz)  qux\n  let x = a->b; // c\n\tif (a == b) {", offset: 5, wordLeft: 4,
      wordRight: 7, deleteLeft: [4, 5], deleteRight: [5, 7], word: [4, 7], home: 0),
    .init(
      text: "foo.bar(baz)  qux\n  let x = a->b; // c\n\tif (a == b) {", offset: 6, wordLeft: 4,
      wordRight: 7, deleteLeft: [4, 6], deleteRight: [6, 7], word: [4, 7], home: 0),
    .init(
      text: "foo.bar(baz)  qux\n  let x = a->b; // c\n\tif (a == b) {", offset: 7, wordLeft: 4,
      wordRight: 11, deleteLeft: [4, 7], deleteRight: [7, 8], word: [4, 7], home: 0),
    .init(
      text: "foo.bar(baz)  qux\n  let x = a->b; // c\n\tif (a == b) {", offset: 8, wordLeft: 4,
      wordRight: 11, deleteLeft: [7, 8], deleteRight: [8, 11], word: [8, 11], home: 0),
    .init(
      text: "foo.bar(baz)  qux\n  let x = a->b; // c\n\tif (a == b) {", offset: 9, wordLeft: 8,
      wordRight: 11, deleteLeft: [8, 9], deleteRight: [9, 11], word: [8, 11], home: 0),
    .init(
      text: "foo.bar(baz)  qux\n  let x = a->b; // c\n\tif (a == b) {", offset: 10, wordLeft: 8,
      wordRight: 11, deleteLeft: [8, 10], deleteRight: [10, 11], word: [8, 11], home: 0),
    .init(
      text: "foo.bar(baz)  qux\n  let x = a->b; // c\n\tif (a == b) {", offset: 11, wordLeft: 8,
      wordRight: 12, deleteLeft: [8, 11], deleteRight: [11, 12], word: [8, 11], home: 0),
    .init(
      text: "foo.bar(baz)  qux\n  let x = a->b; // c\n\tif (a == b) {", offset: 12, wordLeft: 8,
      wordRight: 17, deleteLeft: [11, 12], deleteRight: [12, 14], word: [12, 14], home: 0),
    .init(
      text: "foo.bar(baz)  qux\n  let x = a->b; // c\n\tif (a == b) {", offset: 13, wordLeft: 8,
      wordRight: 17, deleteLeft: [11, 13], deleteRight: [13, 14], word: [12, 14], home: 0),
    .init(
      text: "foo.bar(baz)  qux\n  let x = a->b; // c\n\tif (a == b) {", offset: 14, wordLeft: 8,
      wordRight: 17, deleteLeft: [12, 14], deleteRight: [14, 17], word: [14, 17], home: 0),
    .init(
      text: "foo.bar(baz)  qux\n  let x = a->b; // c\n\tif (a == b) {", offset: 15, wordLeft: 14,
      wordRight: 17, deleteLeft: [14, 15], deleteRight: [15, 17], word: [14, 17], home: 0),
    .init(
      text: "foo.bar(baz)  qux\n  let x = a->b; // c\n\tif (a == b) {", offset: 16, wordLeft: 14,
      wordRight: 17, deleteLeft: [14, 16], deleteRight: [16, 17], word: [14, 17], home: 0),
    .init(
      text: "foo.bar(baz)  qux\n  let x = a->b; // c\n\tif (a == b) {", offset: 17, wordLeft: 14,
      wordRight: 23, deleteLeft: [14, 17], deleteRight: [17, 20], word: [14, 17], home: 0),
    .init(
      text: "foo.bar(baz)  qux\n  let x = a->b; // c\n\tif (a == b) {", offset: 18, wordLeft: 14,
      wordRight: 23, deleteLeft: [17, 18], deleteRight: [18, 20], word: [18, 20], home: 20),
    .init(
      text: "foo.bar(baz)  qux\n  let x = a->b; // c\n\tif (a == b) {", offset: 19, wordLeft: 18,
      wordRight: 23, deleteLeft: [18, 19], deleteRight: [19, 20], word: [18, 20], home: 20),
    .init(
      text: "foo.bar(baz)  qux\n  let x = a->b; // c\n\tif (a == b) {", offset: 20, wordLeft: 18,
      wordRight: 23, deleteLeft: [18, 20], deleteRight: [20, 23], word: [20, 23], home: 18),
    .init(
      text: "foo.bar(baz)  qux\n  let x = a->b; // c\n\tif (a == b) {", offset: 21, wordLeft: 20,
      wordRight: 23, deleteLeft: [20, 21], deleteRight: [21, 23], word: [20, 23], home: 20),
    .init(
      text: "foo.bar(baz)  qux\n  let x = a->b; // c\n\tif (a == b) {", offset: 22, wordLeft: 20,
      wordRight: 23, deleteLeft: [20, 22], deleteRight: [22, 23], word: [20, 23], home: 20),
    .init(
      text: "foo.bar(baz)  qux\n  let x = a->b; // c\n\tif (a == b) {", offset: 23, wordLeft: 20,
      wordRight: 25, deleteLeft: [20, 23], deleteRight: [23, 24], word: [20, 23], home: 20),
    .init(
      text: "foo.bar(baz)  qux\n  let x = a->b; // c\n\tif (a == b) {", offset: 24, wordLeft: 20,
      wordRight: 25, deleteLeft: [20, 24], deleteRight: [24, 25], word: [24, 25], home: 20),
    .init(
      text: "foo.bar(baz)  qux\n  let x = a->b; // c\n\tif (a == b) {", offset: 25, wordLeft: 24,
      wordRight: 27, deleteLeft: [24, 25], deleteRight: [25, 26], word: [24, 25], home: 20),
    .init(
      text: "foo.bar(baz)  qux\n  let x = a->b; // c\n\tif (a == b) {", offset: 26, wordLeft: 24,
      wordRight: 27, deleteLeft: [24, 26], deleteRight: [26, 27], word: [26, 27], home: 20),
    .init(
      text: "foo.bar(baz)  qux\n  let x = a->b; // c\n\tif (a == b) {", offset: 27, wordLeft: 26,
      wordRight: 29, deleteLeft: [26, 27], deleteRight: [27, 28], word: [27, 28], home: 20),
    .init(
      text: "foo.bar(baz)  qux\n  let x = a->b; // c\n\tif (a == b) {", offset: 28, wordLeft: 26,
      wordRight: 29, deleteLeft: [26, 28], deleteRight: [28, 29], word: [28, 29], home: 20),
    .init(
      text: "foo.bar(baz)  qux\n  let x = a->b; // c\n\tif (a == b) {", offset: 29, wordLeft: 28,
      wordRight: 31, deleteLeft: [28, 29], deleteRight: [29, 31], word: [28, 29], home: 20),
    .init(
      text: "foo.bar(baz)  qux\n  let x = a->b; // c\n\tif (a == b) {", offset: 30, wordLeft: 29,
      wordRight: 31, deleteLeft: [29, 30], deleteRight: [30, 31], word: [29, 31], home: 20),
    .init(
      text: "foo.bar(baz)  qux\n  let x = a->b; // c\n\tif (a == b) {", offset: 31, wordLeft: 29,
      wordRight: 32, deleteLeft: [29, 31], deleteRight: [31, 32], word: [31, 32], home: 20),
    .init(
      text: "foo.bar(baz)  qux\n  let x = a->b; // c\n\tif (a == b) {", offset: 32, wordLeft: 31,
      wordRight: 33, deleteLeft: [31, 32], deleteRight: [32, 33], word: [31, 32], home: 20),
    .init(
      text: "foo.bar(baz)  qux\n  let x = a->b; // c\n\tif (a == b) {", offset: 33, wordLeft: 31,
      wordRight: 36, deleteLeft: [32, 33], deleteRight: [33, 34], word: [33, 34], home: 20),
    .init(
      text: "foo.bar(baz)  qux\n  let x = a->b; // c\n\tif (a == b) {", offset: 34, wordLeft: 31,
      wordRight: 36, deleteLeft: [32, 34], deleteRight: [34, 36], word: [34, 36], home: 20),
    .init(
      text: "foo.bar(baz)  qux\n  let x = a->b; // c\n\tif (a == b) {", offset: 35, wordLeft: 34,
      wordRight: 36, deleteLeft: [34, 35], deleteRight: [35, 36], word: [34, 36], home: 20),
    .init(
      text: "foo.bar(baz)  qux\n  let x = a->b; // c\n\tif (a == b) {", offset: 36, wordLeft: 34,
      wordRight: 38, deleteLeft: [34, 36], deleteRight: [36, 37], word: [36, 37], home: 20),
    .init(
      text: "foo.bar(baz)  qux\n  let x = a->b; // c\n\tif (a == b) {", offset: 37, wordLeft: 34,
      wordRight: 38, deleteLeft: [34, 37], deleteRight: [37, 38], word: [37, 38], home: 20),
    .init(
      text: "foo.bar(baz)  qux\n  let x = a->b; // c\n\tif (a == b) {", offset: 38, wordLeft: 37,
      wordRight: 42, deleteLeft: [37, 38], deleteRight: [38, 40], word: [37, 38], home: 20),
    .init(
      text: "foo.bar(baz)  qux\n  let x = a->b; // c\n\tif (a == b) {", offset: 39, wordLeft: 37,
      wordRight: 42, deleteLeft: [38, 39], deleteRight: [39, 40], word: [39, 40], home: 40),
    .init(
      text: "foo.bar(baz)  qux\n  let x = a->b; // c\n\tif (a == b) {", offset: 40, wordLeft: 39,
      wordRight: 42, deleteLeft: [39, 40], deleteRight: [40, 42], word: [40, 42], home: 39),
    .init(
      text: "foo.bar(baz)  qux\n  let x = a->b; // c\n\tif (a == b) {", offset: 41, wordLeft: 40,
      wordRight: 42, deleteLeft: [40, 41], deleteRight: [41, 42], word: [40, 42], home: 40),
    .init(
      text: "foo.bar(baz)  qux\n  let x = a->b; // c\n\tif (a == b) {", offset: 42, wordLeft: 40,
      wordRight: 45, deleteLeft: [40, 42], deleteRight: [42, 43], word: [40, 42], home: 40),
    .init(
      text: "foo.bar(baz)  qux\n  let x = a->b; // c\n\tif (a == b) {", offset: 43, wordLeft: 40,
      wordRight: 45, deleteLeft: [40, 43], deleteRight: [43, 44], word: [43, 44], home: 40),
    .init(
      text: "foo.bar(baz)  qux\n  let x = a->b; // c\n\tif (a == b) {", offset: 44, wordLeft: 43,
      wordRight: 45, deleteLeft: [43, 44], deleteRight: [44, 45], word: [44, 45], home: 40),
    .init(
      text: "foo.bar(baz)  qux\n  let x = a->b; // c\n\tif (a == b) {", offset: 45, wordLeft: 44,
      wordRight: 48, deleteLeft: [44, 45], deleteRight: [45, 46], word: [44, 45], home: 40),
    .init(
      text: "foo.bar(baz)  qux\n  let x = a->b; // c\n\tif (a == b) {", offset: 46, wordLeft: 44,
      wordRight: 48, deleteLeft: [44, 46], deleteRight: [46, 48], word: [46, 48], home: 40),
    .init(
      text: "foo.bar(baz)  qux\n  let x = a->b; // c\n\tif (a == b) {", offset: 47, wordLeft: 46,
      wordRight: 48, deleteLeft: [46, 47], deleteRight: [47, 48], word: [46, 48], home: 40),
    .init(
      text: "foo.bar(baz)  qux\n  let x = a->b; // c\n\tif (a == b) {", offset: 48, wordLeft: 46,
      wordRight: 50, deleteLeft: [46, 48], deleteRight: [48, 49], word: [48, 49], home: 40),
    .init(
      text: "foo.bar(baz)  qux\n  let x = a->b; // c\n\tif (a == b) {", offset: 49, wordLeft: 46,
      wordRight: 50, deleteLeft: [46, 49], deleteRight: [49, 50], word: [49, 50], home: 40),
    .init(
      text: "foo.bar(baz)  qux\n  let x = a->b; // c\n\tif (a == b) {", offset: 50, wordLeft: 49,
      wordRight: 51, deleteLeft: [49, 50], deleteRight: [50, 51], word: [49, 50], home: 40),
    .init(
      text: "foo.bar(baz)  qux\n  let x = a->b; // c\n\tif (a == b) {", offset: 51, wordLeft: 49,
      wordRight: 53, deleteLeft: [50, 51], deleteRight: [51, 52], word: [51, 52], home: 40),
    .init(
      text: "foo.bar(baz)  qux\n  let x = a->b; // c\n\tif (a == b) {", offset: 52, wordLeft: 49,
      wordRight: 53, deleteLeft: [50, 52], deleteRight: [52, 53], word: [52, 53], home: 40),
    .init(
      text: "foo.bar(baz)  qux\n  let x = a->b; // c\n\tif (a == b) {", offset: 53, wordLeft: 52,
      wordRight: 53, deleteLeft: [52, 53], deleteRight: [], word: [53, 53], home: 40),
    .init(
      text: "a  b\t\tc\nx=1,y=2\n--flag=value", offset: 0, wordLeft: 0, wordRight: 1,
      deleteLeft: [], deleteRight: [0, 1], word: [0, 1], home: 0),
    .init(
      text: "a  b\t\tc\nx=1,y=2\n--flag=value", offset: 1, wordLeft: 0, wordRight: 4,
      deleteLeft: [0, 1], deleteRight: [1, 3], word: [0, 1], home: 0),
    .init(
      text: "a  b\t\tc\nx=1,y=2\n--flag=value", offset: 2, wordLeft: 0, wordRight: 4,
      deleteLeft: [0, 2], deleteRight: [2, 3], word: [1, 3], home: 0),
    .init(
      text: "a  b\t\tc\nx=1,y=2\n--flag=value", offset: 3, wordLeft: 0, wordRight: 4,
      deleteLeft: [1, 3], deleteRight: [3, 4], word: [3, 4], home: 0),
    .init(
      text: "a  b\t\tc\nx=1,y=2\n--flag=value", offset: 4, wordLeft: 3, wordRight: 7,
      deleteLeft: [3, 4], deleteRight: [4, 6], word: [3, 4], home: 0),
    .init(
      text: "a  b\t\tc\nx=1,y=2\n--flag=value", offset: 5, wordLeft: 3, wordRight: 7,
      deleteLeft: [3, 5], deleteRight: [5, 6], word: [4, 6], home: 0),
    .init(
      text: "a  b\t\tc\nx=1,y=2\n--flag=value", offset: 6, wordLeft: 3, wordRight: 7,
      deleteLeft: [4, 6], deleteRight: [6, 7], word: [6, 7], home: 0),
    .init(
      text: "a  b\t\tc\nx=1,y=2\n--flag=value", offset: 7, wordLeft: 6, wordRight: 9,
      deleteLeft: [6, 7], deleteRight: [7, 8], word: [6, 7], home: 0),
    .init(
      text: "a  b\t\tc\nx=1,y=2\n--flag=value", offset: 8, wordLeft: 6, wordRight: 9,
      deleteLeft: [7, 8], deleteRight: [8, 9], word: [8, 9], home: 8),
    .init(
      text: "a  b\t\tc\nx=1,y=2\n--flag=value", offset: 9, wordLeft: 8, wordRight: 11,
      deleteLeft: [8, 9], deleteRight: [9, 10], word: [8, 9], home: 8),
    .init(
      text: "a  b\t\tc\nx=1,y=2\n--flag=value", offset: 10, wordLeft: 8, wordRight: 11,
      deleteLeft: [9, 10], deleteRight: [10, 11], word: [10, 11], home: 8),
    .init(
      text: "a  b\t\tc\nx=1,y=2\n--flag=value", offset: 11, wordLeft: 10, wordRight: 13,
      deleteLeft: [10, 11], deleteRight: [11, 12], word: [10, 11], home: 8),
    .init(
      text: "a  b\t\tc\nx=1,y=2\n--flag=value", offset: 12, wordLeft: 10, wordRight: 13,
      deleteLeft: [11, 12], deleteRight: [12, 13], word: [12, 13], home: 8),
    .init(
      text: "a  b\t\tc\nx=1,y=2\n--flag=value", offset: 13, wordLeft: 12, wordRight: 15,
      deleteLeft: [12, 13], deleteRight: [13, 14], word: [12, 13], home: 8),
    .init(
      text: "a  b\t\tc\nx=1,y=2\n--flag=value", offset: 14, wordLeft: 12, wordRight: 15,
      deleteLeft: [13, 14], deleteRight: [14, 15], word: [14, 15], home: 8),
    .init(
      text: "a  b\t\tc\nx=1,y=2\n--flag=value", offset: 15, wordLeft: 14, wordRight: 18,
      deleteLeft: [14, 15], deleteRight: [15, 16], word: [14, 15], home: 8),
    .init(
      text: "a  b\t\tc\nx=1,y=2\n--flag=value", offset: 16, wordLeft: 14, wordRight: 18,
      deleteLeft: [15, 16], deleteRight: [16, 18], word: [16, 18], home: 16),
    .init(
      text: "a  b\t\tc\nx=1,y=2\n--flag=value", offset: 17, wordLeft: 16, wordRight: 18,
      deleteLeft: [16, 17], deleteRight: [17, 18], word: [16, 18], home: 16),
    .init(
      text: "a  b\t\tc\nx=1,y=2\n--flag=value", offset: 18, wordLeft: 16, wordRight: 22,
      deleteLeft: [16, 18], deleteRight: [18, 22], word: [18, 22], home: 16),
    .init(
      text: "a  b\t\tc\nx=1,y=2\n--flag=value", offset: 19, wordLeft: 18, wordRight: 22,
      deleteLeft: [18, 19], deleteRight: [19, 22], word: [18, 22], home: 16),
    .init(
      text: "a  b\t\tc\nx=1,y=2\n--flag=value", offset: 20, wordLeft: 18, wordRight: 22,
      deleteLeft: [18, 20], deleteRight: [20, 22], word: [18, 22], home: 16),
    .init(
      text: "a  b\t\tc\nx=1,y=2\n--flag=value", offset: 21, wordLeft: 18, wordRight: 22,
      deleteLeft: [18, 21], deleteRight: [21, 22], word: [18, 22], home: 16),
    .init(
      text: "a  b\t\tc\nx=1,y=2\n--flag=value", offset: 22, wordLeft: 18, wordRight: 28,
      deleteLeft: [18, 22], deleteRight: [22, 23], word: [18, 22], home: 16),
    .init(
      text: "a  b\t\tc\nx=1,y=2\n--flag=value", offset: 23, wordLeft: 18, wordRight: 28,
      deleteLeft: [22, 23], deleteRight: [23, 28], word: [23, 28], home: 16),
    .init(
      text: "a  b\t\tc\nx=1,y=2\n--flag=value", offset: 24, wordLeft: 23, wordRight: 28,
      deleteLeft: [23, 24], deleteRight: [24, 28], word: [23, 28], home: 16),
    .init(
      text: "a  b\t\tc\nx=1,y=2\n--flag=value", offset: 25, wordLeft: 23, wordRight: 28,
      deleteLeft: [23, 25], deleteRight: [25, 28], word: [23, 28], home: 16),
    .init(
      text: "a  b\t\tc\nx=1,y=2\n--flag=value", offset: 26, wordLeft: 23, wordRight: 28,
      deleteLeft: [23, 26], deleteRight: [26, 28], word: [23, 28], home: 16),
    .init(
      text: "a  b\t\tc\nx=1,y=2\n--flag=value", offset: 27, wordLeft: 23, wordRight: 28,
      deleteLeft: [23, 27], deleteRight: [27, 28], word: [23, 28], home: 16),
    .init(
      text: "a  b\t\tc\nx=1,y=2\n--flag=value", offset: 28, wordLeft: 23, wordRight: 28,
      deleteLeft: [23, 28], deleteRight: [], word: [23, 28], home: 16),
    .init(
      text: "  \n\nfoo_bar baz-qux", offset: 0, wordLeft: 0, wordRight: 2, deleteLeft: [],
      deleteRight: [0, 2], word: [0, 2], home: 0),
    .init(
      text: "  \n\nfoo_bar baz-qux", offset: 1, wordLeft: 0, wordRight: 2, deleteLeft: [0, 1],
      deleteRight: [1, 2], word: [0, 2], home: 0),
    .init(
      text: "  \n\nfoo_bar baz-qux", offset: 2, wordLeft: 0, wordRight: 3, deleteLeft: [0, 2],
      deleteRight: [2, 3], word: [0, 2], home: 0),
    .init(
      text: "  \n\nfoo_bar baz-qux", offset: 3, wordLeft: 0, wordRight: 11, deleteLeft: [2, 3],
      deleteRight: [3, 4], word: [3, 3], home: 3),
    .init(
      text: "  \n\nfoo_bar baz-qux", offset: 4, wordLeft: 3, wordRight: 11, deleteLeft: [3, 4],
      deleteRight: [4, 11], word: [4, 11], home: 4),
    .init(
      text: "  \n\nfoo_bar baz-qux", offset: 5, wordLeft: 4, wordRight: 11, deleteLeft: [4, 5],
      deleteRight: [5, 11], word: [4, 11], home: 4),
    .init(
      text: "  \n\nfoo_bar baz-qux", offset: 6, wordLeft: 4, wordRight: 11, deleteLeft: [4, 6],
      deleteRight: [6, 11], word: [4, 11], home: 4),
    .init(
      text: "  \n\nfoo_bar baz-qux", offset: 7, wordLeft: 4, wordRight: 11, deleteLeft: [4, 7],
      deleteRight: [7, 11], word: [4, 11], home: 4),
    .init(
      text: "  \n\nfoo_bar baz-qux", offset: 8, wordLeft: 4, wordRight: 11, deleteLeft: [4, 8],
      deleteRight: [8, 11], word: [4, 11], home: 4),
    .init(
      text: "  \n\nfoo_bar baz-qux", offset: 9, wordLeft: 4, wordRight: 11, deleteLeft: [4, 9],
      deleteRight: [9, 11], word: [4, 11], home: 4),
    .init(
      text: "  \n\nfoo_bar baz-qux", offset: 10, wordLeft: 4, wordRight: 11, deleteLeft: [4, 10],
      deleteRight: [10, 11], word: [4, 11], home: 4),
    .init(
      text: "  \n\nfoo_bar baz-qux", offset: 11, wordLeft: 4, wordRight: 15, deleteLeft: [4, 11],
      deleteRight: [11, 12], word: [4, 11], home: 4),
    .init(
      text: "  \n\nfoo_bar baz-qux", offset: 12, wordLeft: 4, wordRight: 15, deleteLeft: [4, 12],
      deleteRight: [12, 15], word: [12, 15], home: 4),
    .init(
      text: "  \n\nfoo_bar baz-qux", offset: 13, wordLeft: 12, wordRight: 15, deleteLeft: [12, 13],
      deleteRight: [13, 15], word: [12, 15], home: 4),
    .init(
      text: "  \n\nfoo_bar baz-qux", offset: 14, wordLeft: 12, wordRight: 15, deleteLeft: [12, 14],
      deleteRight: [14, 15], word: [12, 15], home: 4),
    .init(
      text: "  \n\nfoo_bar baz-qux", offset: 15, wordLeft: 12, wordRight: 19, deleteLeft: [12, 15],
      deleteRight: [15, 16], word: [12, 15], home: 4),
    .init(
      text: "  \n\nfoo_bar baz-qux", offset: 16, wordLeft: 12, wordRight: 19, deleteLeft: [15, 16],
      deleteRight: [16, 19], word: [16, 19], home: 4),
    .init(
      text: "  \n\nfoo_bar baz-qux", offset: 17, wordLeft: 16, wordRight: 19, deleteLeft: [16, 17],
      deleteRight: [17, 19], word: [16, 19], home: 4),
    .init(
      text: "  \n\nfoo_bar baz-qux", offset: 18, wordLeft: 16, wordRight: 19, deleteLeft: [16, 18],
      deleteRight: [18, 19], word: [16, 19], home: 4),
    .init(
      text: "  \n\nfoo_bar baz-qux", offset: 19, wordLeft: 16, wordRight: 19, deleteLeft: [16, 19],
      deleteRight: [], word: [16, 19], home: 4),
    .init(
      text: "a.b.c\n(...)\nhello world  ", offset: 0, wordLeft: 0, wordRight: 1, deleteLeft: [],
      deleteRight: [0, 1], word: [0, 1], home: 0),
    .init(
      text: "a.b.c\n(...)\nhello world  ", offset: 1, wordLeft: 0, wordRight: 3,
      deleteLeft: [0, 1], deleteRight: [1, 2], word: [0, 1], home: 0),
    .init(
      text: "a.b.c\n(...)\nhello world  ", offset: 2, wordLeft: 0, wordRight: 3,
      deleteLeft: [1, 2], deleteRight: [2, 3], word: [2, 3], home: 0),
    .init(
      text: "a.b.c\n(...)\nhello world  ", offset: 3, wordLeft: 2, wordRight: 5,
      deleteLeft: [2, 3], deleteRight: [3, 4], word: [2, 3], home: 0),
    .init(
      text: "a.b.c\n(...)\nhello world  ", offset: 4, wordLeft: 2, wordRight: 5,
      deleteLeft: [3, 4], deleteRight: [4, 5], word: [4, 5], home: 0),
    .init(
      text: "a.b.c\n(...)\nhello world  ", offset: 5, wordLeft: 4, wordRight: 11,
      deleteLeft: [4, 5], deleteRight: [5, 6], word: [4, 5], home: 0),
    .init(
      text: "a.b.c\n(...)\nhello world  ", offset: 6, wordLeft: 4, wordRight: 11,
      deleteLeft: [5, 6], deleteRight: [6, 11], word: [6, 11], home: 6),
    .init(
      text: "a.b.c\n(...)\nhello world  ", offset: 7, wordLeft: 6, wordRight: 11,
      deleteLeft: [6, 7], deleteRight: [7, 11], word: [6, 11], home: 6),
    .init(
      text: "a.b.c\n(...)\nhello world  ", offset: 8, wordLeft: 6, wordRight: 11,
      deleteLeft: [6, 8], deleteRight: [8, 11], word: [6, 11], home: 6),
    .init(
      text: "a.b.c\n(...)\nhello world  ", offset: 9, wordLeft: 6, wordRight: 11,
      deleteLeft: [6, 9], deleteRight: [9, 11], word: [6, 11], home: 6),
    .init(
      text: "a.b.c\n(...)\nhello world  ", offset: 10, wordLeft: 6, wordRight: 11,
      deleteLeft: [6, 10], deleteRight: [10, 11], word: [6, 11], home: 6),
    .init(
      text: "a.b.c\n(...)\nhello world  ", offset: 11, wordLeft: 6, wordRight: 17,
      deleteLeft: [6, 11], deleteRight: [11, 12], word: [11, 11], home: 6),
    .init(
      text: "a.b.c\n(...)\nhello world  ", offset: 12, wordLeft: 6, wordRight: 17,
      deleteLeft: [11, 12], deleteRight: [12, 17], word: [12, 17], home: 12),
    .init(
      text: "a.b.c\n(...)\nhello world  ", offset: 13, wordLeft: 12, wordRight: 17,
      deleteLeft: [12, 13], deleteRight: [13, 17], word: [12, 17], home: 12),
    .init(
      text: "a.b.c\n(...)\nhello world  ", offset: 14, wordLeft: 12, wordRight: 17,
      deleteLeft: [12, 14], deleteRight: [14, 17], word: [12, 17], home: 12),
    .init(
      text: "a.b.c\n(...)\nhello world  ", offset: 15, wordLeft: 12, wordRight: 17,
      deleteLeft: [12, 15], deleteRight: [15, 17], word: [12, 17], home: 12),
    .init(
      text: "a.b.c\n(...)\nhello world  ", offset: 16, wordLeft: 12, wordRight: 17,
      deleteLeft: [12, 16], deleteRight: [16, 17], word: [12, 17], home: 12),
    .init(
      text: "a.b.c\n(...)\nhello world  ", offset: 17, wordLeft: 12, wordRight: 23,
      deleteLeft: [12, 17], deleteRight: [17, 18], word: [12, 17], home: 12),
    .init(
      text: "a.b.c\n(...)\nhello world  ", offset: 18, wordLeft: 12, wordRight: 23,
      deleteLeft: [12, 18], deleteRight: [18, 23], word: [18, 23], home: 12),
    .init(
      text: "a.b.c\n(...)\nhello world  ", offset: 19, wordLeft: 18, wordRight: 23,
      deleteLeft: [18, 19], deleteRight: [19, 23], word: [18, 23], home: 12),
    .init(
      text: "a.b.c\n(...)\nhello world  ", offset: 20, wordLeft: 18, wordRight: 23,
      deleteLeft: [18, 20], deleteRight: [20, 23], word: [18, 23], home: 12),
    .init(
      text: "a.b.c\n(...)\nhello world  ", offset: 21, wordLeft: 18, wordRight: 23,
      deleteLeft: [18, 21], deleteRight: [21, 23], word: [18, 23], home: 12),
    .init(
      text: "a.b.c\n(...)\nhello world  ", offset: 22, wordLeft: 18, wordRight: 23,
      deleteLeft: [18, 22], deleteRight: [22, 23], word: [18, 23], home: 12),
    .init(
      text: "a.b.c\n(...)\nhello world  ", offset: 23, wordLeft: 18, wordRight: 25,
      deleteLeft: [18, 23], deleteRight: [23, 25], word: [18, 23], home: 12),
    .init(
      text: "a.b.c\n(...)\nhello world  ", offset: 24, wordLeft: 18, wordRight: 25,
      deleteLeft: [18, 24], deleteRight: [24, 25], word: [23, 25], home: 12),
    .init(
      text: "a.b.c\n(...)\nhello world  ", offset: 25, wordLeft: 18, wordRight: 25,
      deleteLeft: [23, 25], deleteRight: [], word: [23, 25], home: 12),
    .init(
      text: "\nend", offset: 0, wordLeft: 0, wordRight: 4, deleteLeft: [], deleteRight: [0, 1],
      word: [0, 0], home: 0),
    .init(
      text: "\nend", offset: 1, wordLeft: 0, wordRight: 4, deleteLeft: [0, 1], deleteRight: [1, 4],
      word: [1, 4], home: 1),
    .init(
      text: "\nend", offset: 2, wordLeft: 1, wordRight: 4, deleteLeft: [1, 2], deleteRight: [2, 4],
      word: [1, 4], home: 1),
    .init(
      text: "\nend", offset: 3, wordLeft: 1, wordRight: 4, deleteLeft: [1, 3], deleteRight: [3, 4],
      word: [1, 4], home: 1),
    .init(
      text: "\nend", offset: 4, wordLeft: 1, wordRight: 4, deleteLeft: [1, 4], deleteRight: [],
      word: [1, 4], home: 1),
    .init(
      text: "{\n    return self.value\n}", offset: 0, wordLeft: 0, wordRight: 1, deleteLeft: [],
      deleteRight: [0, 1], word: [0, 1], home: 0),
    .init(
      text: "{\n    return self.value\n}", offset: 1, wordLeft: 0, wordRight: 12,
      deleteLeft: [0, 1], deleteRight: [1, 6], word: [1, 1], home: 0),
    .init(
      text: "{\n    return self.value\n}", offset: 2, wordLeft: 0, wordRight: 12,
      deleteLeft: [1, 2], deleteRight: [2, 6], word: [2, 6], home: 6),
    .init(
      text: "{\n    return self.value\n}", offset: 3, wordLeft: 2, wordRight: 12,
      deleteLeft: [2, 3], deleteRight: [3, 6], word: [2, 6], home: 6),
    .init(
      text: "{\n    return self.value\n}", offset: 4, wordLeft: 2, wordRight: 12,
      deleteLeft: [2, 4], deleteRight: [4, 6], word: [2, 6], home: 6),
    .init(
      text: "{\n    return self.value\n}", offset: 5, wordLeft: 2, wordRight: 12,
      deleteLeft: [2, 5], deleteRight: [5, 6], word: [2, 6], home: 6),
    .init(
      text: "{\n    return self.value\n}", offset: 6, wordLeft: 2, wordRight: 12,
      deleteLeft: [2, 6], deleteRight: [6, 12], word: [6, 12], home: 2),
    .init(
      text: "{\n    return self.value\n}", offset: 7, wordLeft: 6, wordRight: 12,
      deleteLeft: [6, 7], deleteRight: [7, 12], word: [6, 12], home: 6),
    .init(
      text: "{\n    return self.value\n}", offset: 8, wordLeft: 6, wordRight: 12,
      deleteLeft: [6, 8], deleteRight: [8, 12], word: [6, 12], home: 6),
    .init(
      text: "{\n    return self.value\n}", offset: 9, wordLeft: 6, wordRight: 12,
      deleteLeft: [6, 9], deleteRight: [9, 12], word: [6, 12], home: 6),
    .init(
      text: "{\n    return self.value\n}", offset: 10, wordLeft: 6, wordRight: 12,
      deleteLeft: [6, 10], deleteRight: [10, 12], word: [6, 12], home: 6),
    .init(
      text: "{\n    return self.value\n}", offset: 11, wordLeft: 6, wordRight: 12,
      deleteLeft: [6, 11], deleteRight: [11, 12], word: [6, 12], home: 6),
    .init(
      text: "{\n    return self.value\n}", offset: 12, wordLeft: 6, wordRight: 17,
      deleteLeft: [6, 12], deleteRight: [12, 13], word: [6, 12], home: 6),
    .init(
      text: "{\n    return self.value\n}", offset: 13, wordLeft: 6, wordRight: 17,
      deleteLeft: [6, 13], deleteRight: [13, 17], word: [13, 17], home: 6),
    .init(
      text: "{\n    return self.value\n}", offset: 14, wordLeft: 13, wordRight: 17,
      deleteLeft: [13, 14], deleteRight: [14, 17], word: [13, 17], home: 6),
    .init(
      text: "{\n    return self.value\n}", offset: 15, wordLeft: 13, wordRight: 17,
      deleteLeft: [13, 15], deleteRight: [15, 17], word: [13, 17], home: 6),
    .init(
      text: "{\n    return self.value\n}", offset: 16, wordLeft: 13, wordRight: 17,
      deleteLeft: [13, 16], deleteRight: [16, 17], word: [13, 17], home: 6),
    .init(
      text: "{\n    return self.value\n}", offset: 17, wordLeft: 13, wordRight: 23,
      deleteLeft: [13, 17], deleteRight: [17, 18], word: [13, 17], home: 6),
    .init(
      text: "{\n    return self.value\n}", offset: 18, wordLeft: 13, wordRight: 23,
      deleteLeft: [17, 18], deleteRight: [18, 23], word: [18, 23], home: 6),
    .init(
      text: "{\n    return self.value\n}", offset: 19, wordLeft: 18, wordRight: 23,
      deleteLeft: [18, 19], deleteRight: [19, 23], word: [18, 23], home: 6),
    .init(
      text: "{\n    return self.value\n}", offset: 20, wordLeft: 18, wordRight: 23,
      deleteLeft: [18, 20], deleteRight: [20, 23], word: [18, 23], home: 6),
    .init(
      text: "{\n    return self.value\n}", offset: 21, wordLeft: 18, wordRight: 23,
      deleteLeft: [18, 21], deleteRight: [21, 23], word: [18, 23], home: 6),
    .init(
      text: "{\n    return self.value\n}", offset: 22, wordLeft: 18, wordRight: 23,
      deleteLeft: [18, 22], deleteRight: [22, 23], word: [18, 23], home: 6),
    .init(
      text: "{\n    return self.value\n}", offset: 23, wordLeft: 18, wordRight: 25,
      deleteLeft: [18, 23], deleteRight: [23, 24], word: [18, 23], home: 6),
    .init(
      text: "{\n    return self.value\n}", offset: 24, wordLeft: 18, wordRight: 25,
      deleteLeft: [23, 24], deleteRight: [24, 25], word: [24, 25], home: 24),
    .init(
      text: "{\n    return self.value\n}", offset: 25, wordLeft: 24, wordRight: 25,
      deleteLeft: [24, 25], deleteRight: [], word: [25, 25], home: 24),
  ]
}
// swiftlint:enable type_body_length

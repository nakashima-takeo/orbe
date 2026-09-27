import Foundation

let defaultCapacity = 64
var sharedCache: [String: Int] = [:], hitCount = 0

typealias Handler = (String) -> Void

/// A value that can be emitted into a stream.
protocol Emitter: AnyObject {
  associatedtype Output
  var isOpen: Bool { get }
  func emit(_ value: Output, coalesce: Bool)
  init(capacity: Int)
}

enum Signal: Equatable {
  case start
  case value(Int, label: String)
  case stop, reset

  var isTerminal: Bool {
    switch self {
    case .stop: return true
    default: return false
    }
  }
}

struct Box<Element> {
  let element: Element
  var count = 0

  func map<T>(_ transform: (Element) -> T) -> Box<T> {
    Box<T>(element: transform(element))
  }

  subscript(index: Int) -> Element { element }
}

// MARK: - Channel

final class Channel: Emitter {
  typealias Output = Signal

  private(set) var isOpen = true
  private var buffer: [Signal] = []

  init(capacity: Int) {
    buffer.reserveCapacity(capacity)
  }

  convenience init() {
    self.init(capacity: defaultCapacity)
  }

  deinit {
    buffer.removeAll()
  }

  // MARK: Emitting
  // Not a mark: only MARK comments are symbols.

  func emit(_ value: Signal, coalesce: Bool) {
    let last = buffer.last
    func append(_ signal: Signal) {
      buffer.append(signal)
    }
    if coalesce, last == value { return }
    append(value)
  }

  func emit(_ values: [Signal]) {
    values.forEach { emit($0, coalesce: false) }
  }

  /* MARK: Equality */
  static func == (lhs: Channel, rhs: Channel) -> Bool { lhs === rhs }

  class Subscription {
    weak var channel: Channel?
    func cancel() {}
  }
}

extension Channel: CustomStringConvertible {
  var description: String { "Channel(\(buffer.count))" }

  func close(reason label: String, _ code: Int) {
    isOpen = false
  }
}

actor Counter {
  var value = 0
  func increment(by amount: Int = 1) { value += amount }
}

func makeChannel(capacity: Int = defaultCapacity) -> Channel {
  Channel(capacity: capacity)
}

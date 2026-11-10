import Foundation

/// An error reply from the engine (`code` is the protocol's `error`), or a failure of the kit
/// itself with one of the codes below.
public struct BrowserError: Error, Equatable, CustomStringConvertible {
  public let code: String
  public let message: String?

  public init(code: String, message: String? = nil) {
    self.code = code
    self.message = message
  }

  /// The connection closed before the reply came.
  public static let disconnected = "disconnected"
  /// The socket path does not fit in `sockaddr_un` (103 bytes plus the terminating zero).
  public static let socketPathTooLong = "socket_path_too_long"
  /// Nothing is listening on the socket (yet).
  public static let connectFailed = "connect_failed"

  public var description: String { message.map { "\(code): \($0)" } ?? code }
}

/// One connection to the engine's socket: one JSON object per line, requests matched to replies
/// by `id`, events delivered on the main actor in the order they arrived. Reconnecting is the
/// caller's decision: a closed connection stays closed.
@MainActor public final class BrowserConnection {
  /// Every event (`{"event": ...}`), with the name and the whole message.
  public var onEvent: ((String, [String: JSON]) -> Void)?
  /// Called once, when the engine closes the socket or `close()` is called.
  public var onClose: (() -> Void)?
  public private(set) var isClosed = false

  private let fd: Int32
  private let writes = DispatchQueue(label: "BrowserKit.socket.write")
  private var nextID = 1
  private var pending: [Int: (Result<[String: JSON], BrowserError>) -> Void] = [:]

  /// Longest path `sockaddr_un` takes: 104 bytes including the terminating zero.
  public static let maximumSocketPathLength = MemoryLayout.size(ofValue: sockaddr_un().sun_path) - 1

  public static func checkSocketPath(_ path: String) throws(BrowserError) {
    let length = path.utf8.count
    guard length <= maximumSocketPathLength else {
      throw BrowserError(
        code: BrowserError.socketPathTooLong,
        message: "socket path is \(length) bytes, the limit is \(maximumSocketPathLength): \(path)")
    }
  }

  public init(socketPath path: String) throws(BrowserError) {
    try Self.checkSocketPath(path)
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw BrowserError(code: BrowserError.connectFailed, message: String(cString: strerror(errno))) }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path.utf8) }
    let connected = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard connected == 0 else {
      let reason = String(cString: strerror(errno))
      Darwin.close(fd)
      throw BrowserError(code: BrowserError.connectFailed, message: "\(path): \(reason)")
    }
    var on: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    self.fd = fd
    Thread.detachNewThread { [weak self] in
      var pending = Data()
      var buffer = [UInt8](repeating: 0, count: 1 << 16)
      while true {
        let count = read(fd, &buffer, buffer.count)
        if count <= 0 { break }
        pending.append(buffer, count: count)
        while let end = pending.firstIndex(of: 0x0A) {
          let line = pending.subdata(in: pending.startIndex..<end)
          pending.removeSubrange(pending.startIndex...end)
          DispatchQueue.main.async { MainActor.assumeIsolated { self?.received(line) } }
        }
      }
      DispatchQueue.main.async { MainActor.assumeIsolated { self?.closed() } }
    }
  }

  /// Sends a request and waits for its reply. An `ok: false` reply throws `BrowserError`.
  @discardableResult
  public func send(op: String, params: [String: JSON] = [:]) async throws(BrowserError) -> [String: JSON] {
    let result = await withCheckedContinuation { continuation in
      request(op: op, params: params) { continuation.resume(returning: $0) }
    }
    return try result.get()
  }

  /// Sends a request now (so its order among other messages is the call order); the reply goes to
  /// `reply` on the main actor, or nowhere.
  public func request(
    op: String, params: [String: JSON] = [:], reply: ((Result<[String: JSON], BrowserError>) -> Void)? = nil
  ) {
    guard !isClosed else {
      reply?(.failure(BrowserError(code: BrowserError.disconnected)))
      return
    }
    let id = nextID
    nextID += 1
    if let reply { pending[id] = reply }
    var message = params
    message["id"] = .number(Double(id))
    message["op"] = .string(op)
    write(message)
  }

  /// A message with no `id`: the engine does not reply (the input ops).
  public func post(op: String, params: [String: JSON] = [:]) {
    guard !isClosed else { return }
    var message = params
    message["op"] = .string(op)
    write(message)
  }

  public func close() {
    guard !isClosed else { return }
    shutdown(fd, SHUT_RDWR)  // wakes the reader, which then reports the close
    closed()
  }

  private func write(_ message: [String: JSON]) {
    let line = JSON.line(message)
    writes.async { [fd] in
      line.withUnsafeBytes { bytes in
        var sent = 0
        while sent < bytes.count {
          let count = Darwin.write(fd, bytes.baseAddress! + sent, bytes.count - sent)
          if count <= 0 { return }  // the reader sees the close
          sent += count
        }
      }
    }
  }

  private func received(_ line: Data) {
    guard !isClosed, let message = JSON.parse(line) else { return }
    if let event = message["event"]?.string {
      onEvent?(event, message)
    } else if let id = message["id"]?.int, let reply = pending.removeValue(forKey: id) {
      if message["ok"]?.bool == true {
        reply(.success(message))
      } else {
        reply(.failure(BrowserError(code: message["error"]?.string ?? "failed", message: message["message"]?.string)))
      }
    }
  }

  private func closed() {
    guard !isClosed else { return }
    isClosed = true
    // Queued after every write already sent, so no write reaches a closed (or reused) descriptor.
    writes.async { [fd] in _ = Darwin.close(fd) }
    let waiting = pending.values
    pending = [:]
    for reply in waiting { reply(.failure(BrowserError(code: BrowserError.disconnected))) }
    onClose?()
  }
}

// MARK: - Typed operations

/// An ato (a browser profile), as `atos.list` reports it.
public struct Ato: Sendable, Equatable, Identifiable {
  public let id: String
  public let name: String
  public let color: String?
  public let tag: String?
  public let asleep: Bool
  public let shared: Bool
}

/// The colors an ato can have.
public enum AtoColor: String, Sendable, CaseIterable {
  case orange, blue, pink, purple, teal
}

/// What the person chose on the host's control indicator: take over, give back, or end.
public enum ControlAction: String, Sendable {
  case take, give, end
}

/// The answer to an `approval.ask`.
public enum ApprovalAnswer: String, Sendable {
  case allow, always, deny
}

extension BrowserConnection {
  public func hello(client: String = "BrowserKit") async throws(BrowserError) -> (protocol: Int, browser: String) {
    let reply = try await send(op: "hello", params: ["client": .string(client)])
    return (reply["protocol"]?.int ?? 0, reply["browser"]?.string ?? "")
  }

  public func atos() async throws(BrowserError) -> [Ato] {
    let reply = try await send(op: "atos.list")
    return (reply["atos"]?.array ?? []).compactMap { item in
      guard let item = item.object, let id = item["id"]?.string else { return nil }
      return Ato(
        id: id, name: item["name"]?.string ?? id, color: item["color"]?.string, tag: item["tag"]?.string,
        asleep: item["asleep"]?.bool ?? false, shared: item["shared"]?.bool ?? false)
    }
  }

  /// Creates an ato without opening a window and returns its id.
  public func createAto(name: String, color: AtoColor? = nil, tag: String? = nil) async throws(BrowserError) -> String {
    var params: [String: JSON] = ["name": .string(name)]
    if let color { params["color"] = .string(color.rawValue) }
    if let tag { params["tag"] = .string(tag) }
    let reply = try await send(op: "atos.create", params: params)
    return reply["ato"]?.string ?? ""
  }

  public func renameAto(_ ato: String, name: String) async throws(BrowserError) {
    try await send(op: "atos.rename", params: ["ato": .string(ato), "name": .string(name)])
  }

  public func setColor(_ color: AtoColor, ato: String) async throws(BrowserError) {
    try await send(op: "atos.color", params: ["ato": .string(ato), "color": .string(color.rawValue)])
  }

  public func openAto(_ ato: String, url: String? = nil) async throws(BrowserError) {
    var params: [String: JSON] = ["ato": .string(ato)]
    if let url { params["url"] = .string(url) }
    try await send(op: "atos.open", params: params)
  }

  /// Makes this connection the host's (only the process that started the engine can).
  public func hostAttach() async throws(BrowserError) {
    try await send(op: "host.attach")
  }

  public func tabs(ato: String) async throws(BrowserError) -> [BrowserTab] {
    let reply = try await send(op: "view.tabs", params: ["ato": .string(ato)])
    return (reply["tabs"]?.array ?? []).compactMap { $0.object.flatMap(BrowserTab.init(message:)) }
  }

  /// Opens a tab in the ato and returns its id.
  public func openTab(ato: String, url: String? = nil) async throws(BrowserError) -> String {
    var params: [String: JSON] = ["ato": .string(ato)]
    if let url { params["url"] = .string(url) }
    let reply = try await send(op: "view.open", params: params)
    return reply["tab"]?.string ?? ""
  }

  public func closeTab(_ tab: String) async throws(BrowserError) { try await send(op: "view.close", params: ["tab": .string(tab)]) }
  /// An address or a search, as typed in an address bar.
  public func navigate(_ tab: String, to text: String) async throws(BrowserError) {
    try await send(op: "view.navigate", params: ["tab": .string(tab), "text": .string(text)])
  }
  public func back(_ tab: String) async throws(BrowserError) { try await send(op: "view.back", params: ["tab": .string(tab)]) }
  public func forward(_ tab: String) async throws(BrowserError) { try await send(op: "view.forward", params: ["tab": .string(tab)]) }
  public func reload(_ tab: String) async throws(BrowserError) { try await send(op: "view.reload", params: ["tab": .string(tab)]) }
  public func stop(_ tab: String) async throws(BrowserError) { try await send(op: "view.stop", params: ["tab": .string(tab)]) }

  /// The tab's icon as PNG data.
  public func favicon(_ tab: String) async throws(BrowserError) -> Data? {
    let reply = try await send(op: "view.favicon", params: ["tab": .string(tab)])
    return reply["png"]?.string.flatMap { Data(base64Encoded: $0) }
  }

  public func control(_ tab: String, action: ControlAction) async throws(BrowserError) {
    try await send(op: "view.control", params: ["tab": .string(tab), "action": .string(action.rawValue)])
  }

  public func answerApproval(_ ask: JSON, answer: ApprovalAnswer) async throws(BrowserError) {
    try await send(op: "approval.answer", params: ["ask": ask, "answer": .string(answer.rawValue)])
  }
}

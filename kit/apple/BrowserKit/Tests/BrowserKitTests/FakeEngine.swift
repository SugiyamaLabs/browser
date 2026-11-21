import Foundation

@testable import BrowserKit

/// A stand-in for the engine's socket: accepts one client, records every message it gets, and
/// answers each request with what `reply` returns (lines sent in order; nil sends nothing).
final class FakeEngine: @unchecked Sendable {
  let path: String
  private let lock = NSLock()
  private var messages: [[String: JSON]] = []
  private var client: Int32 = -1
  private let listener: Int32
  var reply: @Sendable ([String: JSON]) -> [[String: Any]] = { request in
    [["id": request["id"]?.int ?? 0, "ok": true]]
  }

  init() {
    path = NSTemporaryDirectory() + "bk-\(UUID().uuidString.prefix(8)).sock"
    unlink(path)
    listener = socket(AF_UNIX, SOCK_STREAM, 0)
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path.utf8) }
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    precondition(bound == 0 && listen(listener, 1) == 0, "fake engine could not listen on \(path)")
    Thread.detachNewThread { [self] in serve() }
  }

  var received: [[String: JSON]] { lock.withLock { messages } }

  /// The messages with this op, in order.
  func received(_ op: String) -> [[String: JSON]] { received.filter { $0["op"]?.string == op } }

  func send(_ message: [String: Any]) {
    // The client may still be on its way in (accept runs on another thread): wait for it a moment.
    var fd = lock.withLock { client }
    for _ in 0..<200 where fd < 0 {
      usleep(10_000)
      fd = lock.withLock { client }
    }
    var data = try! JSONSerialization.data(withJSONObject: message)
    data.append(0x0A)
    _ = data.withUnsafeBytes { write(fd, $0.baseAddress!, $0.count) }
  }

  func stop() {
    let fd = lock.withLock { client }
    if fd >= 0 { shutdown(fd, SHUT_RDWR) }
    close(listener)
    unlink(path)
  }

  private func serve() {
    let fd = accept(listener, nil, nil)
    guard fd >= 0 else { return }
    lock.withLock { client = fd }
    var pending = Data()
    var buffer = [UInt8](repeating: 0, count: 1 << 16)
    while true {
      let count = read(fd, &buffer, buffer.count)
      if count <= 0 { break }
      pending.append(buffer, count: count)
      while let end = pending.firstIndex(of: 0x0A) {
        let line = pending.subdata(in: pending.startIndex..<end)
        pending.removeSubrange(pending.startIndex...end)
        guard let message = JSON.parse(line) else { continue }
        lock.withLock { messages.append(message) }
        if message["id"] != nil { for line in reply(message) { send(line) } }
      }
    }
    close(fd)
  }
}

/// Waits on the main actor until `condition` holds, up to `seconds`.
@MainActor func eventually(_ seconds: Double = 5, _ condition: () -> Bool) async -> Bool {
  let end = Date().addingTimeInterval(seconds)
  while Date() < end {
    if condition() { return true }
    try? await Task.sleep(nanoseconds: 20_000_000)
  }
  return condition()
}

import Foundation
import Testing

@testable import BrowserKit

nonisolated(unsafe) private let download: [String: Any] = [
    "id": "g-1", "ato": "Profile 1", "tab": "v3", "file_name": "a.txt", "path": "/tmp/d/a.txt",
    "origin": "http://127.0.0.1:8765", "mime": "text/plain", "total_bytes": 20, "received_bytes": 20,
    "state": "complete", "by_agent": true,
]
nonisolated(unsafe) private let row: [String: Any] = [
    "row_id": "3.7.0", "text": "127.0.0.1:8765/other", "fill": "http://127.0.0.1:8765/other", "inline": "her",
    "title": "Other (test)", "url": "http://127.0.0.1:8765/other", "kind": "history", "text_bold": [[0, 4]],
    "title_bold": [], "deletable": true, "favicon": Data([0x89, 0x50]).base64EncodedString(),
]

@MainActor @Suite(.serialized) struct DownloadSuggestTests {

  @Test func downloadOpsMatchTheSpec() async throws {
    let fake = FakeEngine()
    defer { fake.stop() }
    fake.reply = { request in
      var reply: [String: Any] = ["id": request["id"]?.int ?? 0, "ok": true]
      if request["op"]?.string == "view.downloads" { reply["downloads"] = [download, ["id": "g-2"]] }
      return [reply]
    }
    let connection = try BrowserConnection(socketPath: fake.path)
    let list = try await connection.downloads(ato: "Profile 1")
    #expect(list.count == 1)  // one without ato is dropped
    let d = try #require(list.first)
    #expect(d.id == "g-1" && d.ato == "Profile 1" && d.tab == "v3" && d.fileName == "a.txt" && d.path == "/tmp/d/a.txt")
    #expect(d.state == .complete && d.totalBytes == 20 && d.receivedBytes == 20 && d.byAgent && d.dangerType == nil)
    _ = try await connection.downloads()
    try await connection.downloadAction(.keepDangerous, id: "g-1")
    try await connection.downloadAction(.showInFinder, id: "g-1")
    let sent = fake.received.map { var message = $0; message["id"] = nil; return message }
    #expect(sent == [
      ["op": "view.downloads", "ato": "Profile 1"], ["op": "view.downloads"],
      ["op": "view.download.action", "download": "g-1", "action": "keep_dangerous"],
      ["op": "view.download.action", "download": "g-1", "action": "show_in_finder"],
    ])
  }

  @Test func downloadEventsReachTheHandlers() async throws {
    let fake = FakeEngine()
    defer { fake.stop() }
    let engine = BrowserEngine(executable: URL(fileURLWithPath: "/nonexistent"), dataDirectory: URL(fileURLWithPath: "/tmp"))
    engine.attach(try BrowserConnection(socketPath: fake.path))
    var seen: [Download] = []
    var removed: [String] = []
    engine.onDownload = { seen.append($0) }
    engine.onDownloadRemoved = { id, ato in removed.append("\(id) \(ato)") }
    fake.send(download.merging(["event": "view.download", "state": "dangerous", "danger_type": "DANGEROUS_FILE"]) { $1 })
    fake.send(download.merging(["event": "view.download", "state": "brand_new"]) { $1 })
    fake.send(["event": "view.download.removed", "id": "g-1", "ato": "Profile 1"])
    #expect(await eventually { removed.count == 1 })
    #expect(seen.map(\.state) == [.dangerous, .other("brand_new")] && seen[0].dangerType == "DANGEROUS_FILE")
    #expect(removed == ["g-1 Profile 1"])
  }

  @Test func settingsCarryTheDownloadFolders() async throws {
    let fake = FakeEngine()
    defer { fake.stop() }
    fake.reply = { request in
      [["id": request["id"]?.int ?? 0, "ok": true, "site_requests": false, "agent_extensions": true,
        "downloads_dir": ["Profile 1": "/tmp/d", "Profile 2": "/Users/x/Downloads"]]]
    }
    let engine = BrowserEngine(executable: URL(fileURLWithPath: "/nonexistent"), dataDirectory: URL(fileURLWithPath: "/tmp"))
    engine.attach(try BrowserConnection(socketPath: fake.path))
    let settings = try await engine.settings(downloadsDirectories: ["Profile 1": "/tmp/d", "Profile 3": ""])
    #expect(settings.downloadsDirectories == ["Profile 1": "/tmp/d", "Profile 2": "/Users/x/Downloads"])
    let sent = fake.received("host.settings").map { var message = $0; message["id"] = nil; return message }
    #expect(sent == [["op": "host.settings", "downloads_dir": ["Profile 1": "/tmp/d", "Profile 3": ""]]])
  }

  @Test func suggestOpsMatchTheSpec() async throws {
    let fake = FakeEngine()
    defer { fake.stop() }
    fake.reply = { request in
      var reply: [String: Any] = ["id": request["id"]?.int ?? 0, "ok": true]
      switch request["op"]?.string {
      case "view.suggest": reply.merge(["rows": [row, ["text": "no id"]], "done": false]) { $1 }
      case "view.suggest.open": reply["tab"] = request["disposition"]?.string == "switch_to_tab" ? "v9" : "v3"
      default: break
      }
      return [reply]
    }
    let connection = try BrowserConnection(socketPath: fake.path)
    let list = try await connection.suggest("127.0.0.1:8765/ot", in: "v3")
    #expect(list.tab == "v3" && list.text == "127.0.0.1:8765/ot" && !list.done && list.rows.count == 1)
    let row = try #require(list.rows.first)
    #expect(row.id == "3.7.0" && row.inlineCompletion == "her" && row.kind == .history && row.textBold == [0..<4])
    #expect(row.titleBold.isEmpty && row.deletable && row.favicon == Data([0x89, 0x50]) && row.title == "Other (test)")
    _ = try await connection.suggest("x", in: "v3", allowInline: false)
    #expect(try await connection.openSuggestion("3.7.0", in: "v3") == "v3")
    #expect(try await connection.openSuggestion("3.7.0", in: "v3", disposition: .switchToTab) == "v9")
    try await connection.deleteSuggestion("3.7.0")
    let sent = fake.received.map { var message = $0; message["id"] = nil; return message }
    #expect(sent == [
      ["op": "view.suggest", "tab": "v3", "text": "127.0.0.1:8765/ot", "allow_inline": true],
      ["op": "view.suggest", "tab": "v3", "text": "x", "allow_inline": false],
      ["op": "view.suggest.open", "tab": "v3", "row_id": "3.7.0", "disposition": "current_tab"],
      ["op": "view.suggest.open", "tab": "v3", "row_id": "3.7.0", "disposition": "switch_to_tab"],
      ["op": "view.suggest.delete", "row_id": "3.7.0"],
    ])
  }

  @Test func laterSuggestionsReachTheHandler() async throws {
    let fake = FakeEngine()
    defer { fake.stop() }
    let engine = BrowserEngine(executable: URL(fileURLWithPath: "/nonexistent"), dataDirectory: URL(fileURLWithPath: "/tmp"))
    engine.attach(try BrowserConnection(socketPath: fake.path))
    var lists: [Suggestions] = []
    engine.onSuggestions = { lists.append($0) }
    fake.send(["event": "view.suggest", "tab": "v3", "text": "ot", "rows": [row.merging(["kind": "open_tab"]) { $1 }], "done": true])
    #expect(await eventually { lists.count == 1 })
    #expect(lists[0].done && lists[0].rows.map(\.kind) == [.openTab] && lists[0].text == "ot")
  }
}

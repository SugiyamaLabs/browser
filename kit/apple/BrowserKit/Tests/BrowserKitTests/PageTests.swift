import Foundation
import Testing

@testable import BrowserKit

@MainActor @Suite(.serialized) struct PageTests {
  @Test func opsMatchTheSpec() async throws {
    let fake = FakeEngine()
    defer { fake.stop() }
    fake.reply = { request in
      var reply: [String: Any] = ["id": request["id"]?.int ?? 0, "ok": true]
      switch request["op"]?.string {
      case "view.reopenable": reply["count"] = 2
      case "view.reopen": reply["tab"] = "v7"
      case "view.zoom": reply["factor"] = request["factor"]?.double ?? 1.1
      default: break
      }
      return [reply]
    }
    let connection = try BrowserConnection(socketPath: fake.path)
    #expect(try await connection.reopenableCount(ato: "Profile 1") == 2)
    #expect(try await connection.reopenClosedTab(ato: "Profile 1") == "v7")
    try await connection.find("Card", in: "v3")
    try await connection.find("Card", in: "v3", forward: false, matchCase: true, next: true)
    try await connection.stopFind(in: "v3", keepSelection: true)
    #expect(try await connection.zoom(.zoomIn, in: "v3") == 1.1)
    try await connection.zoom(.zoomOut, in: "v3")
    try await connection.zoom(.reset, in: "v3")
    #expect(try await connection.zoom(.factor(1.5), in: "v3") == 1.5)
    #expect(try await connection.zoom(in: "v3") == 1.1)
    let sent = fake.received.map { var message = $0; message["id"] = nil; return message }
    #expect(sent == [
      ["op": "view.reopenable", "ato": "Profile 1"], ["op": "view.reopen", "ato": "Profile 1"],
      ["op": "view.find", "tab": "v3", "text": "Card", "forward": true, "match_case": false, "next": false],
      ["op": "view.find", "tab": "v3", "text": "Card", "forward": false, "match_case": true, "next": true],
      ["op": "view.find.stop", "tab": "v3", "keep_selection": true],
      ["op": "view.zoom", "tab": "v3", "level": "in"], ["op": "view.zoom", "tab": "v3", "level": "out"],
      ["op": "view.zoom", "tab": "v3", "level": "reset"], ["op": "view.zoom", "tab": "v3", "factor": 1.5],
      ["op": "view.zoom", "tab": "v3"],
    ])
  }

  @Test func muteIsSentAndAudioChangesReachTheHandler() async throws {
    let fake = FakeEngine()
    defer { fake.stop() }
    let engine = BrowserEngine(executable: URL(fileURLWithPath: "/nonexistent"), dataDirectory: URL(fileURLWithPath: "/tmp"))
    engine.attach(try BrowserConnection(socketPath: fake.path))
    var audio: [String] = []
    engine.onAudio = { tab, audible, muted in audio.append("\(tab) \(audible) \(muted)") }
    let tab: [String: Any] = ["event": "view.tab", "tab": "v3", "ato": "Profile 1", "title": "Som", "audible": false, "muted": false]
    fake.send(tab)  // first report: no call
    fake.send(tab.merging(["audible": true]) { $1 })
    fake.send(tab.merging(["audible": true, "title": "Som 2"]) { $1 })  // sound unchanged: no call
    fake.send(tab.merging(["audible": true, "muted": true]) { $1 })
    #expect(await eventually { audio.count == 2 })
    #expect(audio == ["v3 true false", "v3 true true"] && engine.tabs["v3"]?.muted == true)
    try await engine.connection!.mute(in: "v3")
    try await engine.connection!.mute(false, in: "v3")
    let sent = fake.received("view.mute").map { var message = $0; message["id"] = nil; return message }
    #expect(sent == [["op": "view.mute", "tab": "v3", "muted": true], ["op": "view.mute", "tab": "v3", "muted": false]])
  }

  @Test func nothingToReopenThrowsNotFound() async throws {
    let fake = FakeEngine()
    defer { fake.stop() }
    fake.reply = { request in [["id": request["id"]?.int ?? 0, "ok": false, "error": "not_found"]] }
    let connection = try BrowserConnection(socketPath: fake.path)
    do {
      _ = try await connection.reopenClosedTab(ato: "Profile 1")
      Issue.record("view.reopen should throw")
    } catch {
      #expect(error.code == "not_found")
    }
  }

  @Test func findAndZoomEventsReachTheHandlers() async throws {
    let fake = FakeEngine()
    defer { fake.stop() }
    let engine = BrowserEngine(executable: URL(fileURLWithPath: "/nonexistent"), dataDirectory: URL(fileURLWithPath: "/tmp"))
    engine.attach(try BrowserConnection(socketPath: fake.path))
    var finds: [FindResult] = []
    var zooms: [String] = []
    engine.onFind = { finds.append($0) }
    engine.onZoom = { tab, factor in zooms.append("\(tab) \(factor)") }
    fake.send(["event": "view.find", "tab": "v3", "matches": 3, "active": 1])
    fake.send(["event": "view.find", "tab": "v3"])  // no counts: dropped
    fake.send(["event": "view.zoom", "tab": "v3", "factor": 1.25])
    fake.send(["event": "view.find", "tab": "v3", "matches": 0, "active": 0])
    #expect(await eventually { finds.count == 2 && zooms.count == 1 })
    #expect(finds == [FindResult(tab: "v3", matches: 3, active: 1), FindResult(tab: "v3", matches: 0, active: 0)])
    #expect(zooms == ["v3 1.25"])
  }
}

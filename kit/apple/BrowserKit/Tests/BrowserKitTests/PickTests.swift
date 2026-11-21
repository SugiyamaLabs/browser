import AppKit
import Foundation
import Testing

@testable import BrowserKit

@MainActor @Suite(.serialized) struct PickTests {
  private func engine(_ fake: FakeEngine) throws -> BrowserEngine {
    let engine = BrowserEngine(executable: URL(fileURLWithPath: "/nonexistent"), dataDirectory: URL(fileURLWithPath: "/tmp"))
    engine.attach(try BrowserConnection(socketPath: fake.path))
    return engine
  }

  @Test func opsMatchTheSpec() async throws {
    let fake = FakeEngine()
    defer { fake.stop() }
    fake.reply = { request in
      var reply: [String: Any] = ["id": request["id"]?.int ?? 0, "ok": true]
      if request["op"] == "view.selection" { reply.merge(["text": "Olá", "truncated": true]) { $1 } }
      return [reply]
    }
    let connection = try BrowserConnection(socketPath: fake.path)
    try await connection.pick("v3")
    try await connection.pick("v3", on: false)
    try await connection.stepPick("v3", to: .parent)
    try await connection.stepPick("v3", to: .child)
    #expect(try await connection.selection("v3") == PageSelection(text: "Olá", truncated: true))
    let sent = fake.received.map { var message = $0; message["id"] = nil; return message }
    #expect(sent == [
      ["op": "view.pick", "tab": "v3", "on": true], ["op": "view.pick", "tab": "v3", "on": false],
      ["op": "view.pick.step", "tab": "v3", "to": "parent"], ["op": "view.pick.step", "tab": "v3", "to": "child"],
      ["op": "view.selection", "tab": "v3"],
    ])
  }

  @Test func anOlderEngineOnlyThrows() async throws {
    let fake = FakeEngine()
    defer { fake.stop() }
    fake.reply = { request in [["id": request["id"]?.int ?? 0, "ok": false, "error": "unknown_op"]] }
    let engine = try engine(fake)
    var results: [PickResult] = []
    engine.onPick = { results.append($0) }
    do {
      try await engine.connection!.pick("v3")
      Issue.record("view.pick should throw")
    } catch {
      #expect(error.code == "unknown_op")
    }
    #expect(engine.connection?.isClosed == false && results.isEmpty)
  }

  @Test func pickedAndCancelledReachTheHandler() async throws {
    let fake = FakeEngine()
    defer { fake.stop() }
    let engine = try engine(fake)
    var results: [PickResult] = []
    engine.onPick = { results.append($0) }
    let png = Data([0x89, 0x50, 0x4E, 0x47])
    fake.send([
      "event": "view.picked", "tab": "v3", "selector": "#card > p", "html": "<p>Oi</p>", "truncated": true,
      "text": "Oi", "x": 40, "y": 50.5, "width": 300, "height": 20,
      "styles": ["color": "rgb(0, 0, 0)", "font-size": "16px", "bad": 3], "png": png.base64EncodedString(),
    ])
    fake.send(["event": "view.picked", "tab": "v3", "selector": "body", "x": 0, "y": 0, "width": 800, "height": 900,
               "png_skipped": true, "text_truncated": true])
    fake.send(["event": "view.picked", "tab": "v3", "cancelled": true])
    fake.send(["event": "view.picked", "tab": "v3"])  // neither: dropped
    #expect(await eventually { results.count == 3 })
    try await Task.sleep(nanoseconds: 100_000_000)
    guard results.count == 3, case .picked(let first) = results[0], case .picked(let second) = results[1] else {
      Issue.record("expected two picks, got \(results)")
      return
    }
    #expect(first.tab == "v3" && first.selector == "#card > p" && first.html == "<p>Oi</p>" && first.htmlTruncated)
    #expect(first.text == "Oi" && !first.textTruncated && first.frame == CGRect(x: 40, y: 50.5, width: 300, height: 20))
    #expect(first.styles == ["color": "rgb(0, 0, 0)", "font-size": "16px"] && first.png == png && !first.pngSkipped)
    #expect(second.png == nil && second.pngSkipped && second.textTruncated && second.html.isEmpty)
    #expect(results[2] == .cancelled(tab: "v3"))
  }

  @Test func inspectIsSentAndAnOlderEngineOnlyThrows() async throws {
    let fake = FakeEngine()
    defer { fake.stop() }
    fake.reply = { request in
      let known = request["tab"] == "v3"  // v9 plays an engine without view.inspect
      return [known ? ["id": request["id"]?.int ?? 0, "ok": true] : ["id": request["id"]?.int ?? 0, "ok": false, "error": "unknown_op"]]
    }
    let engine = try engine(fake)
    try await engine.inspect("v3")
    try await engine.inspect("v3", at: CGPoint(x: 40, y: 50.5))
    do {
      try await engine.inspect("v9")
      Issue.record("view.inspect should throw")
    } catch {
      #expect(error.code == "unknown_op")
    }
    let sent = fake.received("view.inspect").map { var message = $0; message["id"] = nil; return message }
    #expect(sent == [
      ["op": "view.inspect", "tab": "v3"], ["op": "view.inspect", "tab": "v3", "x": 40, "y": 50.5],
      ["op": "view.inspect", "tab": "v9"],
    ])
    #expect(engine.connection?.isClosed == false)
  }

  @Test func theMenusInspectIsAnsweredLikeAnyAction() async throws {
    let fake = FakeEngine()
    defer { fake.stop() }
    let engine = try engine(fake)
    var offered: [String] = []
    engine.onUIRequest = { request in
      guard case .contextMenu(let menu) = request.kind else { return .cancel }
      offered = menu.actions
      return .contextMenu(action: "inspect")
    }
    fake.send(["event": "ui.ask", "ask": "u1", "kind": "context_menu", "tab": "v3", "x": 10, "y": 20,
               "context": ["editable": false, "actions": ["reload", "inspect"]]])
    #expect(await eventually { fake.received("ui.answer").count == 1 })
    #expect(offered == ["reload", "inspect"])
    let answer = fake.received("ui.answer").first.map { var message = $0; message["id"] = nil; return message }
    #expect(answer == ["op": "ui.answer", "ask": "u1", "action": "inspect"])
  }

  @Test func inspectGoesLastPastASeparator() {
    let context = ContextMenu(x: 1, y: 2, link: nil, image: nil, selection: nil, editable: false,
                              actions: ["copy", "reload", "inspect"])
    let ask = HostMenuItem(id: "ask", title: "Perguntar ao bot")
    let (menu, choices) = BrowserEngine.contextMenu(context, hostItems: [ask])
    #expect(menu.items.map(\.title) == ["Copiar", "Recarregar", "", "Perguntar ao bot", "", "Inspecionar"])
    #expect(menu.items.filter { !$0.isSeparatorItem }.map(\.tag) == [0, 1, 2, 3])
    #expect(choices == [.action("copy"), .action("reload"), .host(ask), .action("inspect")])
    let (plain, _) = BrowserEngine.contextMenu(context, hostItems: [])
    #expect(plain.items.map(\.title) == ["Copiar", "Recarregar", "", "Inspecionar"])
    // Offered alone (nothing else the kit draws): no separator first.
    let alone = ContextMenu(x: 0, y: 0, link: nil, image: nil, selection: nil, editable: false, actions: ["inspect"])
    #expect(BrowserEngine.contextMenu(alone, hostItems: []).0.items.map(\.title) == ["Inspecionar"])
    // An engine that does not offer it (older, an agent's tab, DevTools turned off): no item.
    let older = ContextMenu(x: 0, y: 0, link: nil, image: nil, selection: nil, editable: false, actions: ["reload"])
    #expect(BrowserEngine.contextMenu(older, hostItems: []).0.items.map(\.title) == ["Recarregar"])
  }

  @Test func hostItemsGoAfterTheEngineActions() {
    let context = ContextMenu(x: 1, y: 2, link: nil, image: nil, selection: "texto", editable: false,
                              actions: ["copy", "not_known", "reload"])
    let ask = HostMenuItem(id: "ask", title: "Perguntar ao bot")
    let point = HostMenuItem(id: "point", title: "Apontar elemento")
    let (menu, choices) = BrowserEngine.contextMenu(context, hostItems: [ask, point])
    #expect(menu.items.map(\.title) == ["Copiar", "Recarregar", "", "Perguntar ao bot", "Apontar elemento"])
    #expect(menu.items[2].isSeparatorItem)
    #expect(menu.items.filter { !$0.isSeparatorItem }.map(\.tag) == [0, 1, 2, 3])
    #expect(choices == [.action("copy"), .action("reload"), .host(ask), .host(point)])
    // Nothing added: the menu the kit always drew.
    let (plain, plainChoices) = BrowserEngine.contextMenu(context, hostItems: [])
    #expect(plain.items.map(\.title) == ["Copiar", "Recarregar"] && plainChoices == [.action("copy"), .action("reload")])
    // No engine action it can draw: only the host's, with no separator.
    let none = ContextMenu(x: 0, y: 0, link: nil, image: nil, selection: nil, editable: false, actions: [])
    #expect(BrowserEngine.contextMenu(none, hostItems: [ask]).0.items.map(\.title) == ["Perguntar ao bot"])
  }
}

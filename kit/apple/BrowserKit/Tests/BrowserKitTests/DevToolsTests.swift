import AppKit
import Foundation
import Testing

@testable import BrowserKit

@MainActor @Suite(.serialized) struct DevToolsTests {
  private func engine(_ fake: FakeEngine) throws -> BrowserEngine {
    let engine = BrowserEngine(executable: URL(fileURLWithPath: "/nonexistent"), dataDirectory: URL(fileURLWithPath: "/tmp"))
    engine.attach(try BrowserConnection(socketPath: fake.path))
    return engine
  }
  private func sent(_ fake: FakeEngine, _ op: String) -> [[String: JSON]] {
    fake.received(op).map { var message = $0; message["id"] = nil; return message }
  }

  @Test func opsCarryTheDockAndInspectGivesTheView() async throws {
    let fake = FakeEngine()
    defer { fake.stop() }
    fake.reply = { request in
      var reply: [String: Any] = ["id": request["id"]?.int ?? 0, "ok": true]
      if request["op"] == "view.inspect", request["dock"] != "window" { reply["devtools"] = "v8" }
      return [reply]
    }
    let engine = try engine(fake)
    #expect(try await engine.inspect("v3", at: CGPoint(x: 10, y: 20), dock: .bottom) == "v8")
    #expect(try await engine.inspect("v3", dock: .window) == nil)
    engine.devToolsDock = .right
    #expect(try await engine.inspect("v3") == "v8")  // the host's remembered side
    try await engine.setDevToolsDock("v3", .right)
    try await engine.closeDevTools("v3")
    #expect(sent(fake, "view.inspect") == [
      ["op": "view.inspect", "tab": "v3", "x": 10, "y": 20, "dock": "bottom"], ["op": "view.inspect", "tab": "v3", "dock": "window"],
      ["op": "view.inspect", "tab": "v3", "dock": "right"],
    ])
    #expect(sent(fake, "view.devtools.dock") == [["op": "view.devtools.dock", "tab": "v3", "dock": "right"]])
    #expect(sent(fake, "view.devtools.close") == [["op": "view.devtools.close", "tab": "v3"]])
  }

  @Test func eventsKeepTheStateAndReachTheHandlers() async throws {
    let fake = FakeEngine()
    defer { fake.stop() }
    let engine = try engine(fake)
    var seen: [DevToolsState] = []
    var closed: [String] = []
    engine.onDevTools = { seen.append($0) }
    engine.onDevToolsClosed = { tab, devtools in closed.append("\(tab) \(devtools)") }
    fake.send(["event": "view.devtools", "tab": "v3", "devtools": "v8", "dock": "bottom"])
    fake.send(["event": "view.devtools", "tab": "v3", "devtools": "v8", "dock": "right"])
    fake.send(["event": "view.devtools", "tab": "v4", "devtools": "v9", "dock": "sideways"])  // unknown: dropped
    #expect(await eventually { seen.count == 2 })
    #expect(engine.devTools["v3"]?.dock == .right && engine.devTools["v3"]?.devtools == "v8" && engine.devTools["v4"] == nil)
    #expect(engine.isDevTools("v8") && !engine.isDevTools("v3"))
    fake.send(["event": "view.devtools.closed", "tab": "v3", "devtools": "v8"])
    #expect(await eventually { closed == ["v3 v8"] })
    #expect(engine.devTools.isEmpty && !engine.isDevTools("v8"))
  }

  @Test func theMenusInspectCarriesTheRememberedSide() async throws {
    let fake = FakeEngine()
    defer { fake.stop() }
    let engine = try engine(fake)
    engine.devToolsDock = .bottom
    engine.onUIRequest = { _ in .contextMenu(action: "inspect") }
    fake.send(["event": "ui.ask", "ask": "u1", "kind": "context_menu", "tab": "v3", "x": 1, "y": 2,
               "context": ["editable": false, "actions": ["reload", "inspect"]]])
    #expect(await eventually { fake.received("ui.answer").count == 1 })
    #expect(sent(fake, "ui.answer") == [["op": "ui.answer", "ask": "u1", "action": "inspect", "dock": "bottom"]])
  }

  @Test func aDevToolsMenuIsItsOwnEntriesThenTheEditingActions() async throws {
    let fake = FakeEngine()
    defer { fake.stop() }
    let engine = try engine(fake)
    var menu: ContextMenu?
    engine.onUIRequest = { request in
      guard case .contextMenu(let m) = request.kind else { return .cancel }
      menu = m
      return .contextMenuItem(id: 7)
    }
    fake.send(["event": "ui.ask", "ask": "u2", "kind": "context_menu", "tab": "v8", "x": 1, "y": 2,
               "context": ["editable": false, "actions": ["copy"], "items": [
                 ["id": 3, "label": "Edit attribute"], ["separator": true], ["id": 4, "label": "Off", "disabled": true],
                 ["label": "Copy", "items": [["id": 7, "label": "Copy selector"]]], ["label": "Header", "group": true],
                 ["id": 5, "label": "Word wrap", "checked": true],
               ]]])
    #expect(await eventually { fake.received("ui.answer").count == 1 })
    #expect(sent(fake, "ui.answer") == [["op": "ui.answer", "ask": "u2", "item": 7]])
    guard let menu else {
      Issue.record("no menu")
      return
    }
    #expect(menu.items.count == 6 && menu.items[0].id == 3 && menu.items[1].separator && menu.items[2].disabled)
    #expect(menu.items[3].id == nil && menu.items[3].items.first?.id == 7 && menu.items[4].group && menu.items[5].checked == true)
    let (drawn, choices) = BrowserEngine.contextMenu(menu, hostItems: [])
    #expect(drawn.items.map(\.title) == ["Edit attribute", "", "Off", "Copy", "Header", "Word wrap", "", "Copiar"])
    #expect(drawn.items[3].submenu?.items.map(\.title) == ["Copy selector"])
    #expect(!drawn.items[2].isEnabled && drawn.items[5].state == .on)
    #expect(choices == [.item(3), .item(4), .item(7), .item(5), .action("copy")])
    #expect(drawn.items[3].submenu?.items.first?.tag == 2)
  }

  @Test func theSplitKeepsTheMinimumsAndSaysTheSize() {
    #expect(BrowserDevToolsSplit.size(nil, default: 420, total: 1000) == 420)
    #expect(BrowserDevToolsSplit.size(900, default: 420, total: 1000) == 799)  // the page keeps 200 pt
    #expect(BrowserDevToolsSplit.size(50, default: 420, total: 1000) == 120)  // DevTools keeps 120 pt
    #expect(BrowserDevToolsSplit.size(nil, default: 420, total: 200) == 100)  // too small for both: half
    #expect(DevToolsDivider.sizeText(312, of: 743) == "312 px · 42%")
  }

  @Test func aDevToolsViewTakesItsCommandKeysButNotTheHostsOwn() {
    #expect(BrowserTabView.hostKeys.isSuperset(of: ["c", "v", "x", "a", "z", "q", "w"]))
    #expect(!BrowserTabView.hostKeys.contains("f") && !BrowserTabView.hostKeys.contains("[") && !BrowserTabView.hostKeys.contains("p"))
  }
}

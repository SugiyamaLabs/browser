import AppKit
import Foundation
import Testing

@testable import BrowserKit

@MainActor @Suite(.serialized) struct ExtensionTests {
  private func engine(_ fake: FakeEngine) throws -> BrowserEngine {
    let engine = BrowserEngine(executable: URL(fileURLWithPath: "/nonexistent"), dataDirectory: URL(fileURLWithPath: "/tmp"))
    engine.attach(try BrowserConnection(socketPath: fake.path))
    return engine
  }

  nonisolated(unsafe) private static let listed: [String: Any] = [
    "id": "abc", "name": "Gate action", "version": "1.0", "enabled": true, "from": "folder", "action": true,
    "title": "Gate", "badge": "7", "badge_color": "#D93025", "visible": true, "popup": true, "pinned": false,
    "options": true, "permissions": ["Ler o histórico"], "host_permissions": ["https://*/*"], "atos": ["Default", "Profile 1"],
  ]

  @Test func opsMatchTheSpec() async throws {
    let fake = FakeEngine()
    defer { fake.stop() }
    fake.reply = { request in
      var reply: [String: Any] = ["id": request["id"]?.int ?? 0, "ok": true]
      switch request["op"]?.string {
      case "extensions.list": reply["extensions"] = [Self.listed, ["id": "def", "name": "Sem ação", "from": "nova"], ["name": "no id"]]
      case "extension.icon": reply["png"] = request["tab"] == nil ? "iVBORw0K" : ""
      case "extension.options": reply["tab"] = "v8"
      case "extension.install": reply["extension"] = "abc"
      case "extension.click": if request["tab"] == "v3" { reply["popup"] = "v9" }
      case "extension.enable": if request["extension"] != "abc" { reply = ["id": request["id"]?.int ?? 0, "ok": false, "error": "not_found"] }
      default: break
      }
      return [reply]
    }
    let connection = try BrowserConnection(socketPath: fake.path)
    let list = try await connection.extensions(in: "Default", tab: "v3")
    #expect(list.map(\.id) == ["abc", "def"])
    let first = list[0]
    #expect(first.name == "Gate action" && first.version == "1.0" && first.enabled && first.source == .folder && !first.pinned)
    #expect(first.hasOptions && first.permissions == ["Ler o histórico"] && first.hostPermissions == ["https://*/*"])
    #expect(first.atos == ["Default", "Profile 1"])
    #expect(first.action == ExtensionActionState(message: ["title": "Gate", "badge": "7", "badge_color": "#D93025", "popup": true], name: ""))
    #expect(list[1].action == nil && list[1].source == nil && !list[1].enabled)
    #expect(try await connection.extensionIcon("abc", ato: "Default") == Data(base64Encoded: "iVBORw0K"))
    #expect(try await connection.extensionIcon("abc", ato: "Default", tab: "v3") == nil)  // empty: none
    try await connection.setExtension("abc", ato: "Default", enabled: false)
    try await connection.removeExtension("abc", ato: "Default")
    try await connection.removeExtension("abc", ato: "Default", everywhere: true)
    try await connection.pinExtension("abc", ato: "Default", pinned: true)
    #expect(try await connection.openExtensionOptions("abc", ato: "Default") == "v8")
    let folder = FileManager.default.temporaryDirectory
    #expect(try await connection.installExtension(ato: "Default", from: folder) == "abc")
    #expect(try await connection.installExtension(ato: "Default", from: URL(fileURLWithPath: "/tmp/x.crx")) == "abc")
    #expect(try await connection.clickExtension("abc", tab: "v3") == "v9")
    #expect(try await connection.clickExtension("abc", tab: "v4") == nil)
    try await connection.closeExtensionPopup("v9")
    let sent = fake.received.map { var message = $0; message["id"] = nil; return message }
    #expect(sent == [
      ["op": "extensions.list", "ato": "Default", "tab": "v3"],
      ["op": "extension.icon", "ato": "Default", "extension": "abc"],
      ["op": "extension.icon", "ato": "Default", "extension": "abc", "tab": "v3"],
      ["op": "extension.enable", "ato": "Default", "extension": "abc", "on": false],
      ["op": "extension.remove", "ato": "Default", "extension": "abc"],
      ["op": "extension.remove", "ato": "Default", "extension": "abc", "all": true],
      ["op": "extension.pin", "ato": "Default", "extension": "abc", "on": true],
      ["op": "extension.options", "ato": "Default", "extension": "abc"],
      ["op": "extension.install", "ato": "Default", "folder": .string(folder.path)],
      ["op": "extension.install", "ato": "Default", "crx": "/tmp/x.crx"],
      ["op": "extension.click", "tab": "v3", "extension": "abc"],
      ["op": "extension.click", "tab": "v4", "extension": "abc"],
      ["op": "extension.popup.close", "popup": "v9"],
    ])
  }

  @Test func anOlderEngineOnlyThrows() async throws {
    let fake = FakeEngine()
    defer { fake.stop() }
    fake.reply = { request in [["id": request["id"]?.int ?? 0, "ok": false, "error": "unknown_op"]] }
    let engine = try engine(fake)
    do {
      _ = try await engine.connection!.extensions(in: "Default")
      Issue.record("extensions.list should throw")
    } catch {
      #expect(error.code == "unknown_op")
    }
    #expect(engine.connection?.isClosed == false)
  }

  @Test func eventsReachTheHandlers() async throws {
    let fake = FakeEngine()
    defer { fake.stop() }
    let engine = try engine(fake)
    var changes: [ExtensionChange] = []
    var actions: [ExtensionActionUpdate] = []
    var popups: [ExtensionPopup] = []
    var closed: [String] = []
    engine.onExtensionChange = { changes.append($0) }
    engine.onExtensionAction = { actions.append($0) }
    engine.onExtensionPopup = { popups.append($0) }
    engine.onExtensionPopupClosed = { closed.append($0) }
    fake.send(["event": "extension.changed", "ato": "Default", "extension": "abc", "change": "installed"])
    fake.send(["event": "extension.changed", "ato": "Default", "extension": "abc", "change": "renamed"])
    fake.send(["event": "extension.action", "ato": "Default", "extension": "abc", "title": "Gate", "badge": "7", "badge_color": "",
               "visible": false, "popup": true])
    fake.send(["event": "extension.action", "ato": "Default", "tab": "v3", "extension": "abc", "badge": ""])
    fake.send(["event": "extension.popup", "popup": "v9", "tab": "v3", "extension": "abc", "width": 240, "height": 120])
    fake.send(["event": "extension.popup", "popup": "v9", "extension": "abc"])  // no size: dropped
    fake.send(["event": "extension.popup.closed", "popup": "v9"])
    #expect(await eventually { closed.count == 1 })
    #expect(changes == [ExtensionChange(ato: "Default", id: "abc", kind: .installed),
                        ExtensionChange(ato: "Default", id: "abc", kind: .other("renamed"))])
    #expect(actions.count == 2 && actions[0].tab == nil && actions[1].tab == "v3")
    #expect(actions[0].state.title == "Gate" && actions[0].state.badge == "7" && actions[0].state.badgeColor == nil)
    #expect(!actions[0].state.visible && actions[0].state.hasPopup && actions[1].state.visible && !actions[1].state.hasPopup)
    #expect(popups == [ExtensionPopup(message: ["popup": "v9", "tab": "v3", "extension": "abc", "width": 240, "height": 120])!])
    #expect(popups.first?.size == CGSize(width: 240, height: 120) && closed == ["v9"])
  }

  @Test func theInstallAskCarriesTheAtosAndTheAnswerTheChoice() async throws {
    let fake = FakeEngine()
    defer { fake.stop() }
    let engine = try engine(fake)
    var asked: ExtensionInstall?
    engine.onUIRequest = { request in
      guard case .extension(let install) = request.kind else { return .cancel }
      asked = install
      return request.ask == "u1" ? .extension(allow: true, atos: ["Default", "Profile 1"]) : .extension(allow: true)
    }
    let atos: [[String: Any]] = [["id": "Default", "name": "Pessoal", "color": "orange", "installed": false],
                                 ["id": "Profile 1", "name": "Estúdio", "color": "blue", "installed": true]]
    fake.send(["event": "ui.ask", "ask": "u1", "kind": "extension", "name": "Gate", "version": "1.0", "permissions": [],
               "host_permissions": [], "from": "folder", "ato": "Default", "id": "abc", "icon": "iVBORw0K", "atos": atos])
    #expect(await eventually { fake.received("ui.answer").count == 1 })
    #expect(asked?.ato == "Default" && asked?.id == "abc" && asked?.icon == Data(base64Encoded: "iVBORw0K"))
    #expect(asked?.atos == [ExtensionInstall.Ato(id: "Default", name: "Pessoal", color: "orange", installed: false),
                            ExtensionInstall.Ato(id: "Profile 1", name: "Estúdio", color: "blue", installed: true)])
    // An older engine: none of the new fields; the answer is the one it knows.
    fake.send(["event": "ui.ask", "ask": "u2", "kind": "extension", "name": "Old", "version": "2", "from": "store"])
    #expect(await eventually { fake.received("ui.answer").count == 2 })
    #expect(asked?.ato == nil && asked?.atos == [] && asked?.icon == nil)
    let answers = fake.received("ui.answer").map { var message = $0; message["id"] = nil; return message }
    #expect(answers == [["op": "ui.answer", "ask": "u1", "allow": true, "atos": ["Default", "Profile 1"]],
                        ["op": "ui.answer", "ask": "u2", "allow": true]])
    // Atos go only with allow, and an empty list is the same as none.
    #expect(UIAnswer.extension(allow: false, atos: ["Profile 1"]).params == ["allow": false])
    #expect(UIAnswer.extension(allow: true, atos: []).params == ["allow": true])
  }

  @Test func theDefaultSheetsChoice() {
    let atos = [ExtensionInstall.Ato(id: "Default", name: "Pessoal", color: nil, installed: false),
                ExtensionInstall.Ato(id: "Profile 1", name: "Estúdio", color: nil, installed: false),
                ExtensionInstall.Ato(id: "Profile 2", name: "Cliente A", color: nil, installed: true)]
    var install = ExtensionInstall(name: "Gate", version: "1.0", permissions: [], hostPermissions: [], from: "store")
    install.ato = "Default"
    install.atos = atos
    let choice = InstallChoice(install)
    _ = choice.view(details: "")
    let button = NSButton()
    choice.button = button
    choice.update()
    #expect(button.title == "Instalar no ato Pessoal" && choice.chosen == nil)  // the default: only this ato
    choice.pickAll()
    #expect(button.title == "Instalar em 3 atos" && choice.chosen == ["Default", "Profile 1", "Profile 2"])
    choice.pickAll(leaving: ["Profile 1", "Default", "Profile 2"])  // this ato and one that has it stay
    #expect(button.title == "Instalar em 2 atos" && choice.chosen == ["Default", "Profile 2"])
    // One ato only, or an older engine: no choice at all.
    let alone = InstallChoice(ExtensionInstall(name: "Gate", version: "1.0", permissions: [], hostPermissions: [], from: "file"))
    _ = alone.view(details: "")
    alone.button = button
    alone.update()
    #expect(button.title == "Instalar" && alone.chosen == nil)
    #expect(BrowserEngine.installSource("folder").contains("pasta") && BrowserEngine.installSource("https://a.example") == "pedida por https://a.example")
  }
}

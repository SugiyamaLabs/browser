import AppKit
import Foundation
import Testing

@testable import BrowserKit

@MainActor @Suite(.serialized) struct ConnectionTests {
  @Test func repliesMatchRequestsWithEventsInBetween() async throws {
    let fake = FakeEngine()
    defer { fake.stop() }
    // The first request is answered after the second, with events before and between.
    nonisolated(unsafe) var held: [String: JSON]?
    fake.reply = { request in
      let id = request["id"]!.int!
      if request["op"]?.string == "atos.list" {
        held = request
        return [["event": "view.closed", "tab": "v1"]]
      }
      return [
        ["event": "view.closed", "tab": "v2"],
        ["id": id, "ok": true, "ato": "Profile 2"],
        ["event": "view.closed", "tab": "v3"],
        ["id": held!["id"]!.int!, "ok": true, "atos": [["id": "Default", "name": "Pessoal", "asleep": false, "shared": true]]],
      ]
    }
    let connection = try BrowserConnection(socketPath: fake.path)
    var events: [String] = []
    connection.onEvent = { name, message in events.append("\(name) \(message["tab"]?.string ?? "")") }
    async let list = connection.atos()
    try await Task.sleep(nanoseconds: 100_000_000)
    let created = try await connection.createAto(name: "Cliente A", color: .blue, tag: "time-123")
    let atos = try await list
    #expect(created == "Profile 2")
    #expect(atos == [Ato(id: "Default", name: "Pessoal", color: nil, tag: nil, asleep: false, shared: true)])
    #expect(await eventually { events.count == 3 })
    #expect(events == ["view.closed v1", "view.closed v2", "view.closed v3"])
    let create = fake.received("atos.create").first!
    #expect(create["name"] == "Cliente A" && create["color"] == "blue" && create["tag"] == "time-123")
  }

  @Test func errorReplyIsABrowserError() async throws {
    let fake = FakeEngine()
    defer { fake.stop() }
    fake.reply = { [["id": $0["id"]!.int!, "ok": false, "error": "not_found", "message": "no such tab"]] }
    let connection = try BrowserConnection(socketPath: fake.path)
    do {
      try await connection.closeTab("v9")
      Issue.record("expected an error")
    } catch {
      #expect(error == BrowserError(code: "not_found", message: "no such tab"))
    }
  }

  @Test func closingFailsWhatIsPending() async throws {
    let fake = FakeEngine()
    fake.reply = { _ in [] }
    let connection = try BrowserConnection(socketPath: fake.path)
    var closed = 0
    connection.onClose = { closed += 1 }
    async let reply: Void = connection.hostAttach()
    try await Task.sleep(nanoseconds: 100_000_000)
    fake.stop()
    do {
      try await reply
      Issue.record("expected an error")
    } catch {
      #expect((error as? BrowserError)?.code == BrowserError.disconnected)
    }
    #expect(closed == 1)
  }

  @Test func socketPathTooLong() {
    let path = "/tmp/" + String(repeating: "a", count: 100) + "/agens.sock"
    do {
      _ = try BrowserConnection(socketPath: path)
      Issue.record("expected an error")
    } catch {
      #expect(error.code == BrowserError.socketPathTooLong)
    }
    #expect(BrowserConnection.maximumSocketPathLength == 103)
  }

  @Test func lineIsOneLine() {
    let line = JSON.line(["op": "view.navigate", "text": "a\nb", "width": 1000, "scale": 2, "x": 10.5])
    #expect(line.last == 0x0A && line.dropLast().firstIndex(of: 0x0A) == nil)
    let text = String(decoding: line, as: UTF8.self)
    #expect(text.contains("\"width\":1000") && text.contains("\"scale\":2") && text.contains("\"x\":10.5"))
  }
}

@MainActor @Suite(.serialized) struct TabModelTests {
  @Test func followsTabEvents() async throws {
    let fake = FakeEngine()
    defer { fake.stop() }
    let png = Data([0x89, 0x50, 0x4E, 0x47])
    fake.reply = { request in
      let id = request["id"]!.int!
      switch request["op"]?.string {
      case "view.favicon": return [["id": id, "ok": true, "png": png.base64EncodedString()]]
      case "view.tabs":
        return [["id": id, "ok": true, "tabs": [["tab": "v1", "ato": "Profile 1", "title": "A", "url": "https://a/"]]]]
      default: return [["id": id, "ok": true]]
      }
    }
    let engine = BrowserEngine(executable: URL(fileURLWithPath: "/nonexistent"), dataDirectory: URL(fileURLWithPath: "/tmp"))
    engine.attach(try BrowserConnection(socketPath: fake.path))
    var seen: [String] = []
    engine.onEvent = { name, _ in seen.append(name) }

    try await engine.tabs.load(ato: "Profile 1")
    #expect(engine.tabs.tabs(in: "Profile 1").map(\.id) == ["v1"])
    fake.send([
      "event": "view.tab", "tab": "v3", "ato": "Profile 1", "title": "Example Domain", "url": "https://example.com/",
      "loading": false, "audible": true, "can_back": true, "can_forward": false,
      "control": ["agent": "Agente", "title": "Preenchendo", "detail": "passo 2", "state": "working"],
    ])
    #expect(await eventually { engine.tabs["v3"] != nil })
    let tab = engine.tabs["v3"]!
    #expect(tab.title == "Example Domain" && tab.audible && tab.canGoBack && !tab.canGoForward)
    #expect(tab.control == AgentControl(agent: "Agente", title: "Preenchendo", detail: "passo 2", state: "working"))

    fake.send(["event": "view.favicon", "tab": "v3"])
    #expect(await eventually { engine.tabs["v3"]?.favicon == png })
    // An update keeps the icon and drops a control that ended.
    fake.send(["event": "view.tab", "tab": "v3", "ato": "Profile 1", "title": "B", "url": "https://example.com/b", "loading": true])
    #expect(await eventually { engine.tabs["v3"]?.title == "B" })
    #expect(engine.tabs["v3"]?.favicon == png && engine.tabs["v3"]?.control == nil && engine.tabs["v3"]?.loading == true)

    fake.send(["event": "view.closed", "tab": "v3"])
    #expect(await eventually { engine.tabs["v3"] == nil })
    #expect(engine.tabs.all.map(\.id) == ["v1"])
    #expect(seen.contains("view.closed"))
  }

  @Test func approvalGoesToTheHostAndBack() async throws {
    let fake = FakeEngine()
    defer { fake.stop() }
    let engine = BrowserEngine(executable: URL(fileURLWithPath: "/nonexistent"), dataDirectory: URL(fileURLWithPath: "/tmp"))
    engine.attach(try BrowserConnection(socketPath: fake.path))
    var asked: ApprovalRequest?
    engine.onApproval = { request in
      asked = request
      return .always
    }
    fake.send(["event": "approval.ask", "ask": "a7", "title": "Usar abas", "detail": "Cliente A", "offer_always": true])
    #expect(await eventually { !fake.received("approval.answer").isEmpty })
    #expect(asked == ApprovalRequest(ask: "a7", title: "Usar abas", detail: "Cliente A", offerAlways: true))
    let answer = fake.received("approval.answer")[0]
    #expect(answer["ask"] == "a7" && answer["answer"] == "always" && answer["id"] != nil)

    engine.onApproval = nil
    fake.send(["event": "approval.ask", "ask": 8, "title": "x", "detail": "", "offer_always": false])
    #expect(await eventually { fake.received("approval.answer").count == 2 })
    #expect(fake.received("approval.answer")[1]["ask"] == 8 && fake.received("approval.answer")[1]["answer"] == "deny")
  }
}

@MainActor @Suite(.serialized) struct UITests {
  private func engine(_ fake: FakeEngine) throws -> BrowserEngine {
    let engine = BrowserEngine(executable: URL(fileURLWithPath: "/nonexistent"), dataDirectory: URL(fileURLWithPath: "/tmp"))
    engine.attach(try BrowserConnection(socketPath: fake.path))
    return engine
  }

  /// The `ui.answer`s minus `id`, in order.
  private func answers(_ fake: FakeEngine) -> [[String: JSON]] {
    fake.received("ui.answer").map { var answer = $0; answer["id"] = nil; return answer }
  }

  @Test func eachKindBecomesItsTypeAndItsAnswerGoesBack() async throws {
    let fake = FakeEngine()
    defer { fake.stop() }
    let engine = try engine(fake)
    var asked: [UIRequest] = []
    engine.onUIRequest = { request in
      asked.append(request)
      switch request.kind {
      case .select: return .select(index: 2)
      case .contextMenu: return .contextMenu(action: "copy_link")
      case .dialog: return .dialog(accept: true, text: "Ana")
      case .file: return .file(paths: ["/tmp/a.png"])
      case .auth: return .auth(username: "ana", password: "s3cr3t")
      case .permission: return .permission(allow: true, remember: true)
      case .extension: return .extension(allow: false)
      }
    }
    let events: [[String: Any]] = [
      ["kind": "select", "tab": "v3", "x": 120, "y": 340, "width": 180,
       "items": [["label": "Brasil"], ["label": "Chile", "disabled": true], ["label": "Sul", "group": true]], "selected": 0],
      ["kind": "context_menu", "tab": "v3", "x": 10, "y": 20,
       "context": ["link": "https://example.com/a", "selection": "texto", "editable": true], "actions": ["open_link_new_tab", "copy_link"]],
      ["kind": "dialog", "tab": "v3", "type": "prompt", "message": "Nome?", "origin": "https://example.com", "default": "x"],
      ["kind": "file", "tab": "v3", "mode": "open_multiple", "accept": [".png", "image/*"]],
      ["kind": "auth", "tab": "v3", "origin": "https://example.com", "realm": "Intranet", "proxy": false, "retry": true],
      ["kind": "permission", "tab": "v3", "origin": "https://meet.example", "permissions": ["camera", "microphone"]],
      ["kind": "extension", "name": "Bloqueador", "version": "1.2", "permissions": ["Ler o histórico"],
       "host_permissions": ["https://*/*"], "from": "store"],
    ]
    for (index, event) in events.enumerated() {
      fake.send(event.merging(["event": "ui.ask", "ask": "u\(index)"]) { $1 })
    }
    #expect(await eventually { fake.received("ui.answer").count == events.count })

    let kinds = asked.map(\.kind)
    #expect(asked.map(\.ask) == (0..<7).map { "u\($0)" })
    #expect(asked.map(\.tab) == ["v3", "v3", "v3", "v3", "v3", "v3", nil])
    #expect(kinds[0] == .select(SelectMenu(
      x: 120, y: 340, width: 180,
      items: [.init(label: "Brasil", disabled: false, group: false), .init(label: "Chile", disabled: true, group: false),
              .init(label: "Sul", disabled: false, group: true)],
      selected: 0)))
    #expect(kinds[1] == .contextMenu(ContextMenu(
      x: 10, y: 20, link: "https://example.com/a", image: nil, selection: "texto", editable: true,
      actions: ["open_link_new_tab", "copy_link"])))
    #expect(kinds[2] == .dialog(PageDialog(type: .prompt, message: "Nome?", origin: "https://example.com", defaultText: "x")))
    #expect(kinds[3] == .file(FileChooser(mode: .openMultiple, accept: [".png", "image/*"], suggested: nil)))
    #expect(kinds[4] == .auth(HTTPAuth(origin: "https://example.com", realm: "Intranet", proxy: false, retry: true)))
    #expect(kinds[5] == .permission(PermissionRequest(origin: "https://meet.example", permissions: ["camera", "microphone"])))
    #expect(kinds[6] == .extension(ExtensionInstall(
      name: "Bloqueador", version: "1.2", permissions: ["Ler o histórico"], hostPermissions: ["https://*/*"], from: "store")))

    let sent = Dictionary(uniqueKeysWithValues: answers(fake).map { ($0["ask"]!.string!, $0) })
    #expect(sent["u0"] == ["op": "ui.answer", "ask": "u0", "index": 2])
    #expect(sent["u1"] == ["op": "ui.answer", "ask": "u1", "action": "copy_link"])
    #expect(sent["u2"] == ["op": "ui.answer", "ask": "u2", "accept": true, "text": "Ana"])
    #expect(sent["u3"] == ["op": "ui.answer", "ask": "u3", "paths": ["/tmp/a.png"]])
    #expect(sent["u4"] == ["op": "ui.answer", "ask": "u4", "username": "ana", "password": "s3cr3t"])
    #expect(sent["u5"] == ["op": "ui.answer", "ask": "u5", "allow": true, "remember": true])
    #expect(sent["u6"] == ["op": "ui.answer", "ask": "u6", "allow": false])
    #expect(fake.received("ui.answer").allSatisfy { $0["id"] != nil })
  }

  @Test func answersOutsideTheHandler() async throws {
    let fake = FakeEngine()
    defer { fake.stop() }
    let connection = try BrowserConnection(socketPath: fake.path)
    try await connection.answerUI("u1", .cancel)
    try await connection.answerUI("u2", .dialog(accept: false))
    try await connection.answerUI("u3", .permission(allow: false))
    #expect(answers(fake) == [
      ["op": "ui.answer", "ask": "u1", "cancel": true], ["op": "ui.answer", "ask": "u2", "accept": false],
      ["op": "ui.answer", "ask": "u3", "allow": false],
    ])
  }

  @Test func cancelReachesTheHandlerAndNothingIsSent() async throws {
    let fake = FakeEngine()
    defer { fake.stop() }
    let engine = try engine(fake)
    var cancelled: [String] = []
    var reasons: [String] = []
    engine.onEvent = { name, message in if name == "ui.cancel" { reasons.append(message["reason"]?.string ?? "") } }
    engine.onUIRequest = { request in
      try? await Task.sleep(nanoseconds: 10_000_000_000)
      if Task.isCancelled { cancelled.append(request.ask) }
      return .select(index: 0)
    }
    fake.send(["event": "ui.ask", "ask": "u1", "kind": "select", "tab": "v3", "items": [["label": "A"]], "selected": -1])
    try await Task.sleep(nanoseconds: 100_000_000)
    fake.send(["event": "ui.cancel", "ask": "u1", "reason": "navigated"])
    #expect(await eventually { cancelled == ["u1"] })
    #expect(reasons == ["navigated"])
    try await Task.sleep(nanoseconds: 100_000_000)
    #expect(fake.received("ui.answer").isEmpty)
  }

  @Test func withoutAHandlerItIsCancelled() async throws {
    let fake = FakeEngine()
    defer { fake.stop() }
    let engine = try engine(fake)
    fake.send(["event": "ui.ask", "ask": "u1", "kind": "auth", "tab": "v3", "origin": "https://a"])
    #expect(await eventually { !fake.received("ui.answer").isEmpty })
    #expect(engine.onUIRequest == nil)
    #expect(answers(fake) == [["op": "ui.answer", "ask": "u1", "cancel": true]])
  }

  @Test func malformedMessagesAreIgnoredOrCancelled() async throws {
    let fake = FakeEngine()
    defer { fake.stop() }
    let engine = try engine(fake)
    let view = BrowserTabView(engine: engine, tab: "v3")
    var asked: [String] = []
    engine.onUIRequest = { request in
      asked.append(request.ask)
      return .select(index: 0)
    }
    // No ask: nothing to answer.
    fake.send(["event": "ui.ask", "kind": "select", "tab": "v3", "items": []])
    fake.send(["event": "ui.ask", "ask": 5, "kind": "select", "tab": "v3", "items": []])
    // An ask the kit cannot read: cancelled, so the page does not wait.
    for (ask, rest) in [
      ("b1", ["kind": "teleport", "tab": "v3"]), ("b2", ["kind": "select", "tab": "v3"]),
      ("b3", ["kind": "select", "items": []]), ("b4", ["kind": "dialog", "tab": "v3", "type": "shout"]),
      ("b5", ["kind": "file", "tab": "v3", "mode": 1]), ("b6", ["kind": "permission", "tab": "v3", "origin": "https://a"]),
      ("b7", ["kind": "extension"]),
    ] as [(String, [String: Any])] {
      fake.send(rest.merging(["event": "ui.ask", "ask": ask]) { $1 })
    }
    fake.send(["event": "ui.cancel", "ask": "nope", "reason": "gone"])
    fake.send(["event": "ui.cancel"])
    fake.send(["event": "view.cursor", "tab": "v3"])
    fake.send(["event": "view.cursor", "tab": "v404", "cursor": "pointer"])
    fake.send(["event": "view.caret", "tab": "v3", "x": "a", "y": 1, "width": 1, "height": 1])
    // Still alive: a good request after all that is answered.
    fake.send(["event": "ui.ask", "ask": "u9", "kind": "select", "tab": "v3", "items": [["label": "A"]], "selected": 0])
    #expect(await eventually { fake.received("ui.answer").count == 8 })
    #expect(asked == ["u9"])
    let sent = answers(fake)
    #expect(sent.dropLast().map { $0["ask"]?.string } == ["b1", "b2", "b3", "b4", "b5", "b6", "b7"])
    #expect(sent.dropLast().allSatisfy { $0["cancel"] == true })
    #expect(sent.last == ["op": "ui.answer", "ask": "u9", "index": 0])
    #expect(view.cursorName == "default" && view.caret == nil)
  }

  @Test func thePasswordNeverShows() {
    let answer = UIAnswer.auth(username: "ana", password: "s3cr3t")
    var dumped = ""
    dump(answer, to: &dumped)
    for text in [answer.description, answer.debugDescription, "\(answer)", String(reflecting: answer), dumped] {
      #expect(!text.contains("s3cr3t") && text.contains("ana"), "\(text)")
    }
    #expect(UIAnswer.select(index: 2).description == #"UIAnswer {"index":2}"#)
  }

  @Test func cursorAndCaretFollowTheEngine() async throws {
    let fake = FakeEngine()
    defer { fake.stop() }
    let engine = try engine(fake)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    let view = BrowserTabView(engine: engine, tab: "v3")
    view.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
    window.contentView!.addSubview(view)

    fake.send(["event": "view.cursor", "tab": "v3", "cursor": "pointer"])
    #expect(await eventually { view.cursorName == "pointer" })
    fake.send(["event": "view.cursor", "tab": "v3", "cursor": "zoom_in"])
    #expect(await eventually { view.cursorName == "default" })
    #expect(BrowserTabView.cursor("text") == .iBeam && BrowserTabView.cursor("zoom_in") == nil)
    #expect(BrowserTabView.cursor("none") != nil && BrowserTabView.cursor("none") != .arrow)

    #expect(view.firstRect(forCharacterRange: NSRange(location: 0, length: 0), actualRange: nil).height == 0)
    fake.send(["event": "view.caret", "tab": "v3", "x": 10, "y": 20, "width": 2, "height": 16])
    #expect(await eventually { view.caret == CGRect(x: 10, y: 20, width: 2, height: 16) })
    // From the top left to the screen's bottom-left coordinates.
    let origin = window.frame.origin
    #expect(view.firstRect(forCharacterRange: NSRange(location: 0, length: 0), actualRange: nil)
      == NSRect(x: origin.x + 10, y: origin.y + 264, width: 2, height: 16))
  }
}

@MainActor @Suite(.serialized) struct InputTests {
  /// The message minus `id`/`data`, plus whether `data` held a CGEvent.
  private func shape(_ message: [String: JSON]) -> ([String: JSON], Bool) {
    var rest = message
    let data = rest.removeValue(forKey: "data")?.string.flatMap { Data(base64Encoded: $0) }
    let isEvent = data.map { CGEvent(withDataAllocator: nil, data: $0 as CFData) != nil } ?? false
    return (rest, isEvent)
  }

  @Test func eachInputOpMatchesTheSpec() async throws {
    let fake = FakeEngine()
    defer { fake.stop() }
    let engine = BrowserEngine(executable: URL(fileURLWithPath: "/nonexistent"), dataDirectory: URL(fileURLWithPath: "/tmp"))
    engine.attach(try BrowserConnection(socketPath: fake.path))
    let view = BrowserTabView(engine: engine, tab: "v3")
    view.frame = NSRect(x: 0, y: 0, width: 400, height: 300)

    _ = view.becomeFirstResponder()
    _ = view.resignFirstResponder()
    func mouse(_ type: NSEvent.EventType, _ x: CGFloat, _ y: CGFloat) -> NSEvent {
      NSEvent.mouseEvent(
        with: type, location: NSPoint(x: x, y: y), modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
        eventNumber: 0, clickCount: 1, pressure: 1)!
    }
    view.mouseDown(with: mouse(.leftMouseDown, 10, 290))
    view.mouseUp(with: mouse(.leftMouseUp, 10, 290))
    view.mouseMoved(with: mouse(.mouseMoved, 20.5, 100))
    view.mouseExited(with: mouse(.mouseMoved, 0, 0))  // the handler ignores the event
    let scroll = NSEvent(cgEvent: CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -120, wheel2: 0, wheel3: 0)!)!
    view.scrollWheel(with: scroll)
    let key = { (type: NSEvent.EventType) in
      NSEvent.keyEvent(
        with: type, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "a",
        charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0)!
    }
    view.keyDown(with: key(.keyDown))
    view.keyUp(with: key(.keyUp))
    view.copy(nil)
    view.paste(nil)
    view.selectAll(nil)

    #expect(await eventually { fake.received.count == 12 })
    let messages = fake.received
    #expect(messages.allSatisfy { $0["id"] == nil && $0["tab"] == "v3" })
    #expect(messages[0] == ["op": "view.focus", "tab": "v3", "on": true])
    #expect(messages[1] == ["op": "view.focus", "tab": "v3", "on": false])
    let down = shape(messages[2])
    #expect(down.0 == ["op": "view.mouse", "tab": "v3", "x": 10, "y": 10] && down.1)
    #expect(shape(messages[3]).0 == ["op": "view.mouse", "tab": "v3", "x": 10, "y": 10])
    #expect(shape(messages[4]).0 == ["op": "view.mouse", "tab": "v3", "x": 20.5, "y": 200])
    #expect(messages[5] == ["op": "view.mouse.leave", "tab": "v3"])
    let wheel = shape(messages[6])
    #expect(wheel.0["op"] == "view.wheel" && wheel.0["x"]?.double != nil && wheel.0["y"]?.double != nil && wheel.1)
    let keyDown = shape(messages[7])
    #expect(keyDown.1)
    #expect(Set(keyDown.0.keys) == ["op", "tab", "text", "commands", "marked", "sel_start", "sel_end", "had_marked", "unmarked"])
    #expect(keyDown.0["marked"] == "" && keyDown.0["had_marked"] == false && keyDown.0["sel_start"] == 0)
    #expect(shape(messages[8]).0 == ["op": "view.key", "tab": "v3"] && shape(messages[8]).1)
    #expect(messages[9] == ["op": "view.edit", "tab": "v3", "command": "copy"])
    #expect(messages[10] == ["op": "view.edit", "tab": "v3", "command": "paste"])
    #expect(messages[11] == ["op": "view.edit", "tab": "v3", "command": "selectAll"])
  }

  /// A window that is never ordered in: nothing reaches the screen.
  @Test func attachResizeDetachAndLayer() async throws {
    let fake = FakeEngine()
    defer { fake.stop() }
    let engine = BrowserEngine(executable: URL(fileURLWithPath: "/nonexistent"), dataDirectory: URL(fileURLWithPath: "/tmp"))
    engine.attach(try BrowserConnection(socketPath: fake.path))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 640), styleMask: [.borderless], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    let view = BrowserTabView(engine: engine, tab: "v3")
    view.frame = NSRect(x: 0, y: 0, width: 1000, height: 640)
    window.contentView!.addSubview(view)
    let scale = window.backingScaleFactor
    #expect(await eventually { fake.received("view.attach").count == 1 })
    var attach = fake.received("view.attach")[0]
    #expect(attach.removeValue(forKey: "id") != nil)
    #expect(attach == ["op": "view.attach", "tab": "v3", "width": 1000, "height": 640, "scale": .number(scale)])

    fake.send(["event": "view.layer", "tab": "v3", "context": 3626435823, "width": 1000, "height": 640, "scale": scale])
    #expect(await eventually { view.layer?.sublayers?.first?.sublayers?.isEmpty == false })
    let host = view.layer!.sublayers!.first!.sublayers!.first!
    #expect((host.value(forKey: "contextId") as? NSNumber)?.uint32Value == 3626435823)

    view.setFrameSize(NSSize(width: 800, height: 500))
    #expect(await eventually { fake.received("view.resize").count == 1 })
    #expect(fake.received("view.resize")[0]["width"] == 800 && fake.received("view.resize")[0]["height"] == 500)
    view.removeFromSuperview()
    #expect(await eventually { fake.received("view.detach").count == 1 })
    #expect(fake.received("view.detach")[0]["tab"] == "v3" && fake.received("view.detach")[0]["id"] != nil)
  }
}

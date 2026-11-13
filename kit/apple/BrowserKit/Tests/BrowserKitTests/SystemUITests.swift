import AppKit
import Foundation
import Testing

@testable import BrowserKit

/// What used to be a window of the engine's own: pickers, links to other apps, printing, passkeys
/// (docs/protocolo.md, passo 5.3, itens 10 a 13).
@MainActor @Suite(.serialized) struct SystemUITests {
  private func engine(_ fake: FakeEngine) throws -> BrowserEngine {
    let engine = BrowserEngine(executable: URL(fileURLWithPath: "/nonexistent"), dataDirectory: URL(fileURLWithPath: "/tmp"))
    engine.attach(try BrowserConnection(socketPath: fake.path))
    return engine
  }

  private func answers(_ fake: FakeEngine) -> [String: [String: JSON]] {
    Dictionary(uniqueKeysWithValues: fake.received("ui.answer").map { var answer = $0; answer["id"] = nil; return (answer["ask"]!.string!, answer) })
  }

  @Test func theNewKindsAreReadAndAnswered() async throws {
    let fake = FakeEngine()
    defer { fake.stop() }
    let engine = try engine(fake)
    var asked: [UIRequest.Kind] = []
    engine.onUIRequest = { request in
      asked.append(request.kind)
      switch request.kind {
      case .date: return .date(value: 1_794_441_600_000)
      case .color: return .color(hex: "#1a2b3c")
      case .webauthn(let passkey) where passkey.type == .create: return .webauthn(response: ["id": "abc", "type": "public-key"])
      case .webauthn: return .webauthnError("InvalidStateError")
      case .permission: return .permission(allow: false)
      default: return .cancel
      }
    }
    let events: [[String: Any]] = [
      ["kind": "date", "tab": "v3", "type": "date", "value": 1_700_000_000_000, "min": -62_135_596_800_000, "max": 8_640_000_000_000_000,
       "step": 86_400_000, "suggestions": [["value": 0, "label": "Início"]], "x": 400, "y": 140, "width": 150, "height": 30],
      ["kind": "date", "tab": "v3", "type": "datetime-local", "min": 0, "max": 1, "step": 60000, "suggestions": []],
      ["kind": "color", "tab": "v3", "value": "#336699", "suggestions": [["value": "#ff0000", "label": "Vermelho"]]],
      ["kind": "print", "tab": "v3", "title": "Fatura", "url": "https://a.example/f"],
      ["kind": "webauthn", "tab": "v3", "type": "create", "origin": "https://a.example", "cross_origin": false,
       "request": ["rp": ["id": "a.example"], "challenge": "Y2g"]],
      ["kind": "webauthn", "tab": "v3", "type": "get", "origin": "https://b.example", "cross_origin": true, "request": ["rpId": "b.example"]],
      ["kind": "permission", "tab": "v3", "origin": "https://mail.example", "permission": "protocol_handler",
       "scheme": "mailto", "handler_url": "https://mail.example/c?to=%s"],
    ]
    for (index, event) in events.enumerated() { fake.send(event.merging(["event": "ui.ask", "ask": "s\(index)"]) { $1 }) }
    #expect(await eventually { fake.received("ui.answer").count == events.count })

    #expect(asked[0] == .date(DatePicker(
      type: .date, value: 1_700_000_000_000, min: -62_135_596_800_000, max: 8_640_000_000_000_000, step: 86_400_000,
      suggestions: [.init(value: 0, label: "Início")], anchor: CGRect(x: 400, y: 140, width: 150, height: 30))))
    #expect(asked[1] == .date(DatePicker(type: .datetimeLocal, value: nil, min: 0, max: 1, step: 60000, suggestions: [], anchor: nil)))
    #expect(asked[2] == .color(ColorPicker(value: "#336699", suggestions: [.init(value: "#ff0000", label: "Vermelho")], anchor: nil)))
    #expect(asked[3] == .print(PrintRequest(title: "Fatura", url: "https://a.example/f")))
    #expect(asked[4] == .webauthn(PasskeyRequest(
      type: .create, origin: "https://a.example", crossOrigin: false, request: ["rp": ["id": "a.example"], "challenge": "Y2g"])))
    #expect(asked[5] == .webauthn(PasskeyRequest(type: .get, origin: "https://b.example", crossOrigin: true, request: ["rpId": "b.example"])))
    #expect(asked[6] == .permission(PermissionRequest(
      origin: "https://mail.example", permissions: ["protocol_handler"], scheme: "mailto", handlerURL: "https://mail.example/c?to=%s")))

    let sent = answers(fake)
    #expect(sent["s0"] == ["op": "ui.answer", "ask": "s0", "value": 1_794_441_600_000])
    #expect(sent["s2"] == ["op": "ui.answer", "ask": "s2", "value": "#1a2b3c"])
    #expect(sent["s3"] == ["op": "ui.answer", "ask": "s3", "cancel": true])
    #expect(sent["s4"] == ["op": "ui.answer", "ask": "s4", "response": ["id": "abc", "type": "public-key"]])
    #expect(sent["s5"] == ["op": "ui.answer", "ask": "s5", "error": "InvalidStateError"])
    #expect(sent["s6"] == ["op": "ui.answer", "ask": "s6", "allow": false])
  }

  @Test func whatTheKitCannotReadIsCancelled() async throws {
    let fake = FakeEngine()
    defer { fake.stop() }
    let engine = try engine(fake)
    engine.onUIRequest = { _ in .date(value: 0) }
    for (ask, rest) in [
      ("b1", ["kind": "date", "tab": "v3", "type": "year", "min": 0, "max": 1, "step": 1]),
      ("b2", ["kind": "date", "tab": "v3", "type": "date", "min": 0, "max": 1]),
      ("b3", ["kind": "color", "tab": "v3"]), ("b4", ["kind": "print"]),
      ("b5", ["kind": "webauthn", "tab": "v3", "type": "sign", "origin": "https://a", "request": [:] as [String: Any]]),
      ("b6", ["kind": "webauthn", "tab": "v3", "type": "get", "origin": "https://a"]),
    ] as [(String, [String: Any])] {
      fake.send(rest.merging(["event": "ui.ask", "ask": ask]) { $1 })
    }
    #expect(await eventually { fake.received("ui.answer").count == 6 })
    #expect(answers(fake).values.allSatisfy { $0["cancel"] == true })
  }

  @Test func externalLinksGoToTheHandler() async throws {
    let fake = FakeEngine()
    defer { fake.stop() }
    let engine = try engine(fake)
    var links: [ExternalLink] = []
    engine.onExternalLink = { links.append($0) }
    fake.send(["event": "view.external", "tab": "v3", "url": "mailto:ana@example.com", "scheme": "mailto",
               "origin": "https://a.example", "gesture": true])
    fake.send(["event": "view.external", "tab": "v3", "url": "webcal://example.com/c.ics", "scheme": "webcal", "gesture": false])
    fake.send(["event": "view.external", "tab": "v3", "scheme": "mailto"])  // no url: ignored
    #expect(await eventually { links.count == 2 })
    try await Task.sleep(nanoseconds: 100_000_000)
    #expect(links.count == 2)
    #expect(links[0].url == URL(string: "mailto:ana@example.com") && links[0].scheme == "mailto")
    #expect(links[0].origin == "https://a.example" && links[0].gesture && links[0].tab == "v3")
    #expect(links[1].origin == nil && !links[1].gesture)
  }

  @Test func printPDFSendsTheOptions() async throws {
    let fake = FakeEngine()
    defer { fake.stop() }
    fake.reply = { request in
      [["id": request["id"]?.int ?? 0, "ok": true, "path": "/tmp/print/v3/page.pdf", "bytes": 1234, "pages": 3]]
    }
    let connection = try BrowserConnection(socketPath: fake.path)
    var options = PrintOptions(landscape: true, pageRanges: "1-2")
    options.margins = (top: 0.4, bottom: 0.4, left: 0.5, right: 0.5)
    options.cssPageSize = false
    let pdf = try await connection.printPDF(tab: "v3", options: options)
    #expect(pdf == PrintedPDF(url: URL(fileURLWithPath: "/tmp/print/v3/page.pdf"), bytes: 1234, pages: 3))
    _ = try await connection.printPDF(tab: "v4")
    let sent = fake.received("view.print_pdf").map { var m = $0; m["id"] = nil; return m }
    #expect(sent == [
      ["op": "view.print_pdf", "tab": "v3", "landscape": true, "page_ranges": "1-2", "css_page_size": false,
       "margins": ["top": 0.4, "bottom": 0.4, "left": 0.5, "right": 0.5]],
      ["op": "view.print_pdf", "tab": "v4"],
    ])
  }

  @Test func theDefaultPickersKeepTheFieldsUnits() {
    let day = 86_400_000.0
    let date = DatePicker(type: .date, value: nil, min: 0, max: 400 * day, step: day, suggestions: [], anchor: nil)
    // A moment in the day is that day's midnight, UTC.
    #expect(BrowserEngine.value(DatePicker.date(3 * day + 5_000), for: date) == 3 * day)
    #expect(BrowserEngine.value(DatePicker.date(900 * day), for: date) == 400 * day)  // clamped to max
    let month = DatePicker(type: .month, value: 682, min: -24000, max: 24000, step: 1, suggestions: [], anchor: nil)
    #expect(BrowserEngine.value(BrowserEngine.date(682, for: .month), for: month) == 682)  // 2026-11
    let time = DatePicker(type: .time, value: nil, min: 0, max: day - 1, step: 60_000, suggestions: [], anchor: nil)
    #expect(BrowserEngine.value(DatePicker.date((13 * 60 + 45) * 60_000), for: time) == (13 * 60 + 45) * 60_000)
    #expect(BrowserEngine.hex(BrowserEngine.color("#1a2b3c")!) == "#1a2b3c")
    #expect(BrowserEngine.color("red") == nil && BrowserEngine.color("#12345") == nil)
  }

  @Test func theDefaultUIRefusesPasskeysForNow() async throws {
    let fake = FakeEngine()
    defer { fake.stop() }
    let engine = try engine(fake)
    let request = try #require(UIRequest(message: [
      "ask": "u1", "kind": "webauthn", "tab": "v3", "type": "create", "origin": "https://a.example", "request": [:],
    ]))
    #expect(await engine.presentDefaultUI(request) == .webauthnError("NotAllowedError"))
  }
}

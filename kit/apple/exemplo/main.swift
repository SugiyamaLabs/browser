// Proof of the embed (docs/poc/embed.md): a plain AppKit app, with no Chromium code, that shows
// a tab of the engine running in another process. The engine draws the tab into a CAContext; this
// app hosts it in a CALayerHost and sends its own NSEvents back over a Unix socket (one JSON
// message per line).
//
//   exemplo <socket>      run against an engine started with --agens-embed-socket=<socket>
//   exemplo --selftest    checks what can be checked without a window or an engine

import AppKit
import QuartzCore

/// The engine's socket. Events arrive on the main thread.
final class Engine {
  private let fd: Int32
  var onEvent: (([String: Any]) -> Void)?
  var onClosed: (() -> Void)?

  init?(path: String) {
    fd = socket(AF_UNIX, SOCK_STREAM, 0)
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    guard path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path.utf8) }
    let connected = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard fd >= 0, connected == 0 else { return nil }
    var on: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    Thread.detachNewThread { [weak self, fd] in
      var pending = Data()
      var buffer = [UInt8](repeating: 0, count: 1 << 16)
      while true {
        let count = read(fd, &buffer, buffer.count)
        if count <= 0 { break }
        pending.append(buffer, count: count)
        while let end = pending.firstIndex(of: 0x0A) {
          let line = pending.subdata(in: pending.startIndex..<end)
          pending.removeSubrange(pending.startIndex...end)
          if let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
            DispatchQueue.main.async { self?.onEvent?(event) }
          }
        }
      }
      DispatchQueue.main.async { self?.onClosed?() }
    }
  }

  func send(_ message: [String: Any]) {
    let line = Engine.line(message)
    line.withUnsafeBytes { bytes in
      var sent = 0
      while sent < bytes.count {
        let count = write(fd, bytes.baseAddress! + sent, bytes.count - sent)
        if count <= 0 { return }
        sent += count
      }
    }
  }

  static func line(_ message: [String: Any]) -> Data {
    var data = (try? JSONSerialization.data(withJSONObject: message)) ?? Data("{}".utf8)
    data.append(0x0A)
    return data
  }
}

/// The NSEvent as the engine rebuilds it (ui::EventFromData), or nil for events with no CGEvent.
func encoded(_ event: NSEvent) -> String? {
  (event.cgEvent?.data as Data?)?.base64EncodedString()
}

/// A CALayerHost showing the engine's CAContext, or nil if this macOS no longer has the class.
func makeLayerHost(context: UInt32) -> CALayer? {
  guard let type = NSClassFromString("CALayerHost") as? CALayer.Type else { return nil }
  let host = type.init()
  host.anchorPoint = .zero
  host.setValue(NSNumber(value: context), forKey: "contextId")
  host.autoresizingMask = [.layerMaxXMargin, .layerMaxYMargin]
  return host
}

/// One tab. The same layer setup as Chromium's own view for a page (DisplayCALayerTree): a
/// layer-hosting view, a flipped layer the size of the view, the CALayerHost at its origin.
final class TabView: NSView, NSTextInputClient {
  private let engine: Engine
  private let flippedLayer = CALayer()
  private var host: CALayer?

  // What the text input system did with the key being handled (sent along with it).
  private var handlingKey = false
  private var insertedText = ""
  private var commands: [String] = []
  private var marked = ""
  private var markedSelection = NSRange(location: 0, length: 0)
  private var unmarked = false

  init(engine: Engine) {
    self.engine = engine
    super.init(frame: .zero)
    let root = CALayer()
    root.backgroundColor = NSColor.white.cgColor
    layer = root
    wantsLayer = true
    flippedLayer.isGeometryFlipped = true
    flippedLayer.anchorPoint = .zero
    root.addSublayer(flippedLayer)
    addTrackingArea(NSTrackingArea(
      rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
      owner: self))
  }
  required init?(coder: NSCoder) { fatalError() }

  func show(context: UInt32) {
    guard let new = makeLayerHost(context: context) else {
      print("FAIL: no CALayerHost class on this macOS")
      return
    }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    flippedLayer.addSublayer(new)
    host?.removeFromSuperlayer()
    host = new
    CATransaction.commit()
  }

  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    flippedLayer.frame = bounds
    CATransaction.commit()
    engine.send(["op": "resize", "width": Int(newSize.width), "height": Int(newSize.height)])
  }

  // Focus.
  override var acceptsFirstResponder: Bool { true }
  override func becomeFirstResponder() -> Bool {
    engine.send(["op": "focus", "on": true])
    return true
  }
  override func resignFirstResponder() -> Bool {
    engine.send(["op": "focus", "on": false])
    return true
  }

  // Mouse. Points go in the page's coordinates: from the top left.
  // shortcut: the right button is not sent. The engine would open its own context menu, in a
  // process with no window to anchor it; the menu has to come here as data first.
  private func mouse(_ event: NSEvent, op: String = "mouse") {
    guard let data = encoded(event) else { return }
    let point = convert(event.locationInWindow, from: nil)
    engine.send(["op": op, "data": data, "x": point.x, "y": bounds.height - point.y])
  }
  override func mouseDown(with event: NSEvent) {
    window?.makeFirstResponder(self)
    mouse(event)
  }
  override func mouseUp(with event: NSEvent) { mouse(event) }
  override func mouseDragged(with event: NSEvent) { mouse(event) }
  override func mouseMoved(with event: NSEvent) { mouse(event) }
  override func mouseExited(with event: NSEvent) { engine.send(["op": "mouse.leave"]) }
  override func scrollWheel(with event: NSEvent) { mouse(event, op: "wheel") }

  // Keyboard. The text input system runs here (dead keys, input methods, key bindings); the
  // engine gets the key plus what came out of it, as its own view would have collected.
  override func keyDown(with event: NSEvent) {
    guard let data = encoded(event) else { return }
    let hadMarked = !marked.isEmpty
    insertedText = ""
    commands = []
    unmarked = false
    handlingKey = true
    interpretKeyEvents([event])
    handlingKey = false
    engine.send([
      "op": "key", "data": data, "text": insertedText, "commands": commands, "marked": marked,
      "sel_start": markedSelection.location, "sel_end": NSMaxRange(markedSelection),
      "had_marked": hadMarked, "unmarked": unmarked,
    ])
  }
  override func keyUp(with event: NSEvent) {
    if let data = encoded(event) { engine.send(["op": "key", "data": data]) }
  }
  override func flagsChanged(with event: NSEvent) {
    if let data = encoded(event) { engine.send(["op": "key", "data": data]) }
  }
  override func doCommand(by selector: Selector) {
    if handlingKey { commands.append(NSStringFromSelector(selector)) }
  }

  // NSTextInputClient.
  // shortcut: text that arrives outside a key press (the emoji picker, dictation) is dropped, and
  // the input method's window appears under the view instead of at the caret; both need the
  // engine to report the selection and its rectangle.
  func insertText(_ string: Any, replacementRange: NSRange) {
    if handlingKey { insertedText += (string as? NSAttributedString)?.string ?? (string as? String ?? "") }
    marked = ""
  }
  func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
    marked = (string as? NSAttributedString)?.string ?? (string as? String ?? "")
    markedSelection = selectedRange.location == NSNotFound ? NSRange(location: 0, length: 0) : selectedRange
  }
  func unmarkText() {
    marked = ""
    unmarked = true
  }
  func hasMarkedText() -> Bool { !marked.isEmpty }
  func markedRange() -> NSRange {
    marked.isEmpty ? NSRange(location: NSNotFound, length: 0) : NSRange(location: 0, length: marked.utf16.count)
  }
  func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
  func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
  func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
  func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
    window?.convertToScreen(convert(NSRect(x: 0, y: 0, width: bounds.width, height: 0), to: nil)) ?? .zero
  }
  func characterIndex(for point: NSPoint) -> Int { NSNotFound }

  // The Edit menu.
  @objc func cut(_ sender: Any?) { engine.send(["op": "edit", "command": "cut"]) }
  @objc func copy(_ sender: Any?) { engine.send(["op": "edit", "command": "copy"]) }
  @objc func paste(_ sender: Any?) { engine.send(["op": "edit", "command": "paste"]) }
  @objc func undo(_ sender: Any?) { engine.send(["op": "edit", "command": "undo"]) }
  @objc func redo(_ sender: Any?) { engine.send(["op": "edit", "command": "redo"]) }
  override func selectAll(_ sender: Any?) { engine.send(["op": "edit", "command": "selectAll"]) }
}

/// The window: this app's own address bar and tab row over the engine's page.
final class Controller: NSObject, NSApplicationDelegate, NSTextFieldDelegate {
  private let engine: Engine
  private let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
    styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
  private let address = NSTextField()
  private let tabs = NSSegmentedControl()
  private let page: TabView

  init(engine: Engine) {
    self.engine = engine
    page = TabView(engine: engine)
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    let content = window.contentView!
    let size = content.bounds.size
    func button(_ title: String, _ op: String, x: CGFloat) {
      let button = NSButton(title: title, target: self, action: #selector(send(_:)))
      button.identifier = NSUserInterfaceItemIdentifier(op)
      button.frame = NSRect(x: x, y: size.height - 30, width: 30, height: 24)
      button.autoresizingMask = [.minYMargin]
      content.addSubview(button)
    }
    button("‹", "back", x: 8)
    button("›", "forward", x: 40)
    button("↻", "reload", x: 72)
    button("+", "tab.new", x: size.width - 38)
    content.subviews.last!.autoresizingMask = [.minYMargin, .minXMargin]
    address.frame = NSRect(x: 108, y: size.height - 29, width: size.width - 154, height: 22)
    address.autoresizingMask = [.minYMargin, .width]
    address.placeholderString = "Endereço ou busca"
    address.target = self
    address.action = #selector(navigate)
    content.addSubview(address)
    tabs.frame = NSRect(x: 8, y: size.height - 60, width: size.width - 16, height: 24)
    tabs.autoresizingMask = [.minYMargin, .width]
    tabs.target = self
    tabs.action = #selector(activate)
    content.addSubview(tabs)
    page.frame = NSRect(x: 0, y: 0, width: size.width, height: size.height - 66)
    page.autoresizingMask = [.width, .height]
    content.addSubview(page)

    engine.onEvent = { [weak self] in self?.handle($0) }
    engine.onClosed = {
      print("engine closed the socket")
      NSApp.terminate(nil)
    }
    engine.send(["op": "attach", "width": Int(page.bounds.width), "height": Int(page.bounds.height)])

    window.title = "Exemplo do embed"
    window.center()
    window.makeKeyAndOrderFront(nil)
    window.makeFirstResponder(page)
    NSApp.activate(ignoringOtherApps: true)
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

  private func handle(_ event: [String: Any]) {
    switch event["event"] as? String {
    case "layer":
      // The line to look for on the first run: the engine is drawing the tab for us.
      print("layer context=\(event["context"] ?? "?") \(event["width"] ?? "?")x\(event["height"] ?? "?") scale=\(event["scale"] ?? "?")")
      if let context = (event["context"] as? NSNumber)?.uint32Value { page.show(context: context) }
    case "tabs":
      let list = event["tabs"] as? [[String: Any]] ?? []
      print("tabs \(list.map { ($0["active"] as? Bool == true ? "*" : "") + ($0["title"] as? String ?? "") })")
      tabs.segmentCount = list.count
      for (index, tab) in list.enumerated() {
        tabs.setLabel(String((tab["title"] as? String ?? "").prefix(24)), forSegment: index)
        if tab["active"] as? Bool == true {
          tabs.selectedSegment = index
          if address.currentEditor() == nil { address.stringValue = tab["url"] as? String ?? "" }
        }
      }
    default:
      print("event \(event)")
    }
  }

  @objc private func send(_ sender: NSButton) {
    engine.send(["op": sender.identifier!.rawValue])
  }
  @objc private func navigate() {
    engine.send(["op": "navigate", "text": address.stringValue])
    window.makeFirstResponder(page)
  }
  @objc private func activate() {
    engine.send(["op": "tab.activate", "index": tabs.selectedSegment])
    window.makeFirstResponder(page)
  }
}

/// Key equivalents (⌘C, ⌘V, ⌘Q…) only exist through a menu.
func makeMenu() -> NSMenu {
  let main = NSMenu()
  let app = NSMenu()
  app.addItem(withTitle: "Encerrar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
  let edit = NSMenu(title: "Editar")
  edit.addItem(withTitle: "Desfazer", action: #selector(TabView.undo(_:)), keyEquivalent: "z")
  edit.addItem(withTitle: "Refazer", action: #selector(TabView.redo(_:)), keyEquivalent: "Z")
  edit.addItem(withTitle: "Recortar", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
  edit.addItem(withTitle: "Copiar", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
  edit.addItem(withTitle: "Colar", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
  edit.addItem(withTitle: "Selecionar Tudo", action: #selector(NSResponder.selectAll(_:)), keyEquivalent: "a")
  for menu in [app, edit] {
    let item = NSMenuItem()
    item.submenu = menu
    main.addItem(item)
  }
  return main
}

func selftest() {
  // The private class this whole path stands on, and the property the context id goes in.
  guard let host = makeLayerHost(context: 42) else { fatalError("no CALayerHost class") }
  precondition((host.value(forKey: "contextId") as? NSNumber)?.uint32Value == 42, "contextId does not hold")
  // An NSEvent survives the trip as CGEvent data.
  let key = NSEvent.keyEvent(
    with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
    characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0)!
  guard let data = encoded(key), let bytes = Data(base64Encoded: data), let cg = CGEvent(withDataAllocator: nil, data: bytes as CFData),
    let back = NSEvent(cgEvent: cg)
  else { fatalError("NSEvent does not round-trip as CGEvent data") }
  precondition(back.type == .keyDown && back.keyCode == 0, "the key event came back different")
  // One message is one line, whatever is in it.
  let line = Engine.line(["op": "navigate", "text": "a\nb"])
  precondition(line.last == 0x0A && line.dropLast().firstIndex(of: 0x0A) == nil, "a message must be one line")
  print("ok")
}

let arguments = CommandLine.arguments
if arguments.count == 2, arguments[1] == "--selftest" {
  selftest()
} else if arguments.count == 2, let engine = Engine(path: arguments[1]) {
  let app = NSApplication.shared
  let controller = Controller(engine: engine)
  app.delegate = controller
  app.setActivationPolicy(.regular)
  app.mainMenu = makeMenu()
  app.run()
} else {
  FileHandle.standardError.write(Data("usage: exemplo <socket> | --selftest (is the engine running with --agens-embed-socket?)\n".utf8))
  exit(1)
}

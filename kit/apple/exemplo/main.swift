// The embed sample (docs/poc/embed.md, docs/kit.md): a plain AppKit app, with no Chromium code,
// that shows tabs of the engine through BrowserKit. The kit starts the engine as a hidden child,
// talks to it over its socket and gives one view per tab; this app only draws a bare toolbar and
// tab row around it.
//
//   exemplo <engine executable> [data folder]
//                         runs with a window
//   exemplo --selftest    checks what can be checked without a window or an engine
//   exemplo --autotest <engine executable> <data folder> <page url> <out folder> [engine args...]
//                         drives its own view with synthetic events against teste.html and
//                         prints PASS/FAIL per step (autoteste.sh runs it)

import AppKit
import BrowserKit
import QuartzCore

/// The window: this app's own address bar and tab row over the engine's page.
@MainActor final class Controller: NSObject, NSApplicationDelegate {
  let engine: BrowserEngine
  let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
    styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
  private let address = NSTextField()
  private let tabRow = NSSegmentedControl()
  /// This app's tabs, in its own order; only the selected one is in the window.
  private(set) var pages: [BrowserTabView] = []
  private(set) var selected = 0
  private(set) var ato = "Default"
  let autotest: (url: String, folder: String)?
  // What the engine said (the autotest reads these).
  var layers: [(tab: String, context: Int, width: Int, height: Int)] = []

  init(engine: BrowserEngine, autotest: (url: String, folder: String)? = nil) {
    self.engine = engine
    self.autotest = autotest
  }

  var page: BrowserTabView? { pages.indices.contains(selected) ? pages[selected] : nil }

  func applicationDidFinishLaunching(_ notification: Notification) {
    let content = window.contentView!
    let size = content.bounds.size
    func button(_ title: String, _ action: Selector, x: CGFloat) {
      let button = NSButton(title: title, target: self, action: action)
      button.frame = NSRect(x: x, y: size.height - 30, width: 30, height: 24)
      button.autoresizingMask = [.minYMargin]
      content.addSubview(button)
    }
    button("‹", #selector(back), x: 8)
    button("›", #selector(forward), x: 40)
    button("↻", #selector(reload), x: 72)
    button("+", #selector(newTab), x: size.width - 38)
    content.subviews.last!.autoresizingMask = [.minYMargin, .minXMargin]
    address.frame = NSRect(x: 108, y: size.height - 29, width: size.width - 154, height: 22)
    address.autoresizingMask = [.minYMargin, .width]
    address.placeholderString = "Endereço ou busca"
    address.target = self
    address.action = #selector(navigate)
    content.addSubview(address)
    tabRow.frame = NSRect(x: 8, y: size.height - 60, width: size.width - 16, height: 24)
    tabRow.autoresizingMask = [.minYMargin, .width]
    tabRow.target = self
    tabRow.action = #selector(activate)
    content.addSubview(tabRow)

    engine.onStateChange = { [weak self] state in self?.stateChanged(state) }
    engine.onEvent = { [weak self] name, message in self?.handle(name, message) }
    engine.onApproval = { request in
      let alert = NSAlert()
      alert.messageText = request.title
      alert.informativeText = request.detail
      alert.addButton(withTitle: "Permitir")
      alert.addButton(withTitle: "Não permitir")
      if request.offerAlways { alert.addButton(withTitle: "Permitir sempre") }
      switch alert.runModal() {
      case .alertFirstButtonReturn: return .allow
      case .alertThirdButtonReturn: return .always
      default: return .deny
      }
    }
    // Menus, page dialogs, file panels, logins and permissions, drawn by the kit.
    engine.onUIRequest = { [weak engine] in await engine?.presentDefaultUI($0) ?? .cancel }

    window.title = "Exemplo do embed"
    window.center()
    if autotest != nil {
      // Behind everything and never active: the person at this Mac keeps typing where they were.
      window.orderBack(nil)
    } else {
      window.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
    }
    Task { await startEngine() }
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
  func applicationWillTerminate(_ notification: Notification) { engine.stop() }

  private func startEngine() async {
    await engine.start()
    guard case .ready = engine.state, let connection = engine.connection else { return }
    do {
      ato = try await connection.atos().first?.id ?? ato
      let tab = try await connection.openTab(ato: ato)
      try await engine.tabs.load(ato: ato)
      add(tab)
    } catch {
      print("could not open a tab: \(error)")
    }
    if autotest != nil { await runAutotest() }
  }

  private func stateChanged(_ state: BrowserEngine.State) {
    print("state \(state)")
    switch state {
    case .starting: window.title = "Abrindo o navegador…"
    case .ready(_, let browser): window.title = "Exemplo do embed · \(browser)"
    case .versionTooOld: window.title = "Atualize o navegador"
    case .failed(let reason): window.title = "O navegador não abriu: \(reason)"
    case .stopped: break
    case .exited:
      // The old tab ids are gone with the engine: drop the views and start over.
      pages.forEach { $0.removeFromSuperview() }
      pages = []
      refresh()
      window.title = "Reabrindo o navegador…"
      if autotest != nil {
        print("FAIL the engine went away")
        NSApp.terminate(nil)
      } else {
        Task { await startEngine() }
      }
    }
  }

  private func handle(_ name: String, _ message: [String: JSON]) {
    switch name {
    case "view.layer":
      // The line to look for on the first run: the engine is drawing the tab for us.
      print("layer tab=\(message["tab"]?.string ?? "?") context=\(message["context"]?.int ?? 0) \(message["width"]?.int ?? 0)x\(message["height"]?.int ?? 0) scale=\(message["scale"]?.double ?? 0)")
      layers.append((message["tab"]?.string ?? "", message["context"]?.int ?? 0, message["width"]?.int ?? 0, message["height"]?.int ?? 0))
    case "view.tab", "view.closed":
      if name == "view.closed", let index = pages.firstIndex(where: { $0.tab == message["tab"]?.string }) {
        pages[index].removeFromSuperview()
        pages.remove(at: index)
        select(min(selected, pages.count - 1))
      }
      refresh()
    default:
      print("event \(name) \(message)")
    }
  }

  func add(_ tab: String) {
    pages.append(BrowserTabView(engine: engine, tab: tab))
    select(pages.count - 1)
  }

  func select(_ index: Int) {
    page?.removeFromSuperview()
    selected = index
    if let page {
      let content = window.contentView!.bounds
      page.frame = NSRect(x: 0, y: 0, width: content.width, height: content.height - 66)
      page.autoresizingMask = [.width, .height]
      window.contentView!.addSubview(page)
      window.makeFirstResponder(page)
    }
    refresh()
  }

  private func refresh() {
    tabRow.segmentCount = pages.count
    for (index, page) in pages.enumerated() {
      tabRow.setLabel(String((engine.tabs[page.tab]?.title ?? "").prefix(24)), forSegment: index)
    }
    if pages.indices.contains(selected) { tabRow.selectedSegment = selected }
    if let page, address.currentEditor() == nil { address.stringValue = engine.tabs[page.tab]?.url ?? "" }
  }

  private func run(_ op: @escaping (BrowserConnection, String) async throws -> Void) {
    guard let connection = engine.connection, let tab = page?.tab else { return }
    Task {
      do { try await op(connection, tab) } catch { print("error \(error)") }
    }
  }

  @objc private func back() { run { try await $0.back($1) } }
  @objc private func forward() { run { try await $0.forward($1) } }
  @objc private func reload() { run { try await $0.reload($1) } }
  @objc private func navigate() {
    let text = address.stringValue
    run { try await $0.navigate($1, to: text) }
    if let page { window.makeFirstResponder(page) }
  }
  @objc func newTab() {
    guard let connection = engine.connection else { return }
    Task {
      do { add(try await connection.openTab(ato: ato)) } catch { print("error \(error)") }
    }
  }
  @objc private func activate() { select(tabRow.selectedSegment) }
}

// MARK: - Autotest

extension Controller {
  /// What teste.html reports in its title: {"c":clicks,"h":hovered,"y":scrollY,"v":input,"k":key,"w":width}.
  private var state: [String: Any] {
    guard let tab = page?.tab, let title = engine.tabs[tab]?.title, title.hasPrefix("T "),
      let object = try? JSONSerialization.jsonObject(with: Data(title.dropFirst(2).utf8)) as? [String: Any]
    else { return [:] }
    return object
  }

  private func until(_ seconds: Double = 5, _ condition: () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
      if condition() { return true }
      try? await Task.sleep(nanoseconds: 50_000_000)
    }
    return condition()
  }

  private func check(_ name: String, _ ok: Bool, _ detail: String = "") {
    print("\(ok ? "PASS" : "FAIL") \(name) \(detail)")
  }

  /// Our own window only, by its id: nothing else on screen gets into the picture.
  private func capture(_ name: String) async {
    try? await Task.sleep(nanoseconds: 700_000_000)  // let the window server show the new frame
    let shot = Process()
    shot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    shot.arguments = ["-x", "-o", "-l", String(window.windowNumber), "\(autotest!.folder)/\(name).png"]
    try? shot.run()
    shot.waitUntilExit()
    print("capture \(name).png window=\(window.windowNumber)")
  }

  /// `at` is in the page's coordinates (from the top left), as in teste.html's CSS.
  private func mouseEvent(_ type: NSEvent.EventType, at: NSPoint, clicks: Int = 1) -> NSEvent {
    let inWindow = page!.convert(NSPoint(x: at.x, y: page!.bounds.height - at.y), to: nil)
    return NSEvent.mouseEvent(
      with: type, location: inWindow, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
      windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
  }
  private func click(_ at: NSPoint) {
    page!.mouseMoved(with: mouseEvent(.mouseMoved, at: at, clicks: 0))
    page!.mouseDown(with: mouseEvent(.leftMouseDown, at: at))
    page!.mouseUp(with: mouseEvent(.leftMouseUp, at: at))
  }
  /// The wheel goes as the message the view sends: a synthetic scroll event carries the real
  /// pointer's position, not a point in this view.
  private func wheel(_ delta: Int32, at: NSPoint) {
    guard let scroll = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: delta, wheel2: 0, wheel3: 0),
      let data = scroll.data as Data?
    else { return }
    engine.connection?.post(op: "view.wheel", params: [
      "tab": .string(page!.tab), "data": .string(data.base64EncodedString()), "x": .number(at.x), "y": .number(at.y),
    ])
  }
  private func keyEvent(_ type: NSEvent.EventType, _ characters: String, _ code: UInt16, _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
    NSEvent.keyEvent(
      with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
      windowNumber: window.windowNumber, context: nil, characters: characters,
      charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
  }
  /// Through the view's real handlers, so the text input system here takes part.
  private func press(_ characters: String, _ code: UInt16, _ flags: NSEvent.ModifierFlags = []) async {
    page!.keyDown(with: keyEvent(.keyDown, characters, code, flags))
    page!.keyUp(with: keyEvent(.keyUp, characters, code, flags))
    try? await Task.sleep(nanoseconds: 80_000_000)
  }
  private func value() -> String { state["v"] as? String ?? "" }
  private func encoded(_ event: NSEvent) -> String? { (event.cgEvent?.data as Data?)?.base64EncodedString() }

  func runAutotest() async {
    guard let first = page, let connection = engine.connection else {
      check("1 layer", false, "no tab (state \(engine.state))")
      NSApp.terminate(nil)
      return
    }
    let url = autotest!.url
    // 1. The engine draws the tab for us.
    check("1 layer", await until(10) { self.layers.contains { $0.tab == first.tab } }, "\(layers.last.map { "\($0)" } ?? "none")")

    // 5a. Navigate by address.
    try? await connection.navigate(first.tab, to: url)
    check("5a navigate", await until(10) { !self.state.isEmpty }, "\(state)")
    // 2. Does it show here? Only the picture answers.
    await capture("1-pagina")

    // 3. Click, hover, wheel.
    click(NSPoint(x: 80, y: 40))
    check("3a click", await until { self.state["c"] as? Int == 1 }, "c=\(state["c"] ?? "?")")
    first.mouseMoved(with: mouseEvent(.mouseMoved, at: NSPoint(x: 260, y: 40), clicks: 0))
    check("3b hover", await until { self.state["h"] as? Int == 1 }, "h=\(state["h"] ?? "?")")
    await capture("2-hover")
    check("3b hover stays", state["o"] == nil, "mouseout=\(state["o"] ?? 0)")
    wheel(-120, at: NSPoint(x: 400, y: 300))
    check("3c wheel", await until { (self.state["y"] as? Int ?? 0) > 0 }, "y=\(state["y"] ?? "?")")
    wheel(2000, at: NSPoint(x: 400, y: 300))
    _ = await until { self.state["y"] as? Int == 0 }

    // 4. Typing: click the field, then keys through the view's keyDown.
    window.makeFirstResponder(nil)
    window.makeFirstResponder(first)
    click(NSPoint(x: 100, y: 115))
    await press("a", 0)
    await press("b", 11)
    await press("c", 8)
    check("4a letters", await until { self.value() == "abc" }, "v=\(value())")
    await press("\u{F702}", 123, [.numericPad, .function])  // left arrow
    await press("x", 7)
    check("4b arrow", await until { self.value() == "abxc" }, "v=\(value())")
    await press("\u{7F}", 51)  // delete (Backspace)
    check("4c backspace", await until { self.value() == "abc" }, "v=\(value())")
    // A dead key and its letter, as the text input system reports them (´ then a = á). Sent as
    // the messages BrowserTabView would send: a synthetic NSEvent cannot make the system compose.
    if let dead = encoded(keyEvent(.keyDown, "", 39)), let letter = encoded(keyEvent(.keyDown, "a", 0)) {
      connection.post(op: "view.key", params: [
        "tab": .string(first.tab), "data": .string(dead), "text": "", "commands": [], "marked": "´", "sel_start": 1,
        "sel_end": 1, "had_marked": false, "unmarked": false,
      ])
      _ = await until(1) { self.value() == "ab´c" }
      let during = value()
      connection.post(op: "view.key", params: [
        "tab": .string(first.tab), "data": .string(letter), "text": "á", "commands": [], "marked": "", "sel_start": 0,
        "sel_end": 0, "had_marked": true, "unmarked": false,
      ])
      check("4d accent", await until { self.value() == "abác" }, "composing=\(during) v=\(value())")
    }
    await press("\r", 36)
    check("4e enter", await until { self.state["k"] as? String == "Enter" }, "k=\(state["k"] ?? "?")")
    await capture("3-digitado")

    // 6. Resize.
    let before = layers.count
    window.setContentSize(NSSize(width: 800, height: 566))
    check("6 resize", await until { self.state["w"] as? Int == 800 }, "w=\(state["w"] ?? "?") layer=\(layers.last.map { "\($0)" } ?? "") new layers=\(layers.count - before)")
    await capture("4-menor")

    // 5b. A second tab, then back to the first.
    newTab()
    check("5b new tab", await until { self.pages.count == 2 && self.selected == 1 && self.engine.tabs.tabs(in: self.ato).count == 2 }, "tabs=\(engine.tabs.tabs(in: ato).count)")
    if let second = pages.last, pages.count == 2 {
      try? await connection.navigate(second.tab, to: url + "?segunda")
      _ = await until(10) { !self.state.isEmpty }
      click(NSPoint(x: 80, y: 40))
      click(NSPoint(x: 80, y: 40))
      check("5c second tab takes input", await until { self.state["c"] as? Int == 2 }, "c=\(state["c"] ?? "?")")
      await capture("5-segunda-aba")
    }
    let contexts = Set(layers.map { $0.context }).count
    select(0)
    check("5d switch back", await until { self.selected == 0 && self.value() == "abác" }, "v=\(value()) contexts seen=\(contexts)")
    await capture("6-primeira-aba")

    // 7. A page dialog: the engine asks (ui.ask), the kit draws a sheet on this window, the answer reaches the page.
    if let tab = page?.tab {
      try? await connection.navigate(tab, to: url + "?confirma")
      let shown = await until(10) { self.window.attachedSheet != nil }
      check("7 page dialog shows as a sheet", shown)
      await capture("7-dialogo")
      func buttons(_ view: NSView) -> [NSButton] { view.subviews.flatMap { ($0 as? NSButton).map { [$0] } ?? buttons($0) } }
      if let sheet = window.attachedSheet, let content = sheet.contentView {
        buttons(content).first { $0.title == "OK" }?.performClick(nil)
      }
      check("7b the answer reaches the page", await until { self.state["q"] as? Int == 1 }, "q=\(state["q"] ?? "?")")
    }

    // For the memory numbers: autoteste.sh measures while this line is the last one printed.
    print("MEASURE")
    try? await Task.sleep(nanoseconds: 4_000_000_000)
    print("DONE")
    NSApp.terminate(nil)
  }
}

/// Key equivalents (⌘C, ⌘V, ⌘Q…) only exist through a menu.
@MainActor func makeMenu() -> NSMenu {
  let main = NSMenu()
  let app = NSMenu()
  app.addItem(withTitle: "Encerrar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
  let edit = NSMenu(title: "Editar")
  edit.addItem(withTitle: "Desfazer", action: #selector(BrowserTabView.undo(_:)), keyEquivalent: "z")
  edit.addItem(withTitle: "Refazer", action: #selector(BrowserTabView.redo(_:)), keyEquivalent: "Z")
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

@MainActor func selftest() {
  // The private class this whole path stands on, and the property the context id goes in.
  guard let type = NSClassFromString("CALayerHost") as? CALayer.Type else { fatalError("no CALayerHost class") }
  let host = type.init()
  host.setValue(NSNumber(value: 42), forKey: "contextId")
  precondition((host.value(forKey: "contextId") as? NSNumber)?.uint32Value == 42, "contextId does not hold")
  // An NSEvent survives the trip as CGEvent data.
  let key = NSEvent.keyEvent(
    with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
    characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0)!
  guard let data = key.cgEvent?.data as Data?, let cg = CGEvent(withDataAllocator: nil, data: data as CFData),
    let back = NSEvent(cgEvent: cg)
  else { fatalError("NSEvent does not round-trip as CGEvent data") }
  precondition(back.type == .keyDown && back.keyCode == 0, "the key event came back different")
  // The kit refuses a socket path the system cannot take, before starting anything.
  do {
    try BrowserConnection.checkSocketPath("/" + String(repeating: "a", count: 104))
    fatalError("a 105-byte socket path was accepted")
  } catch {
    precondition(error.code == BrowserError.socketPathTooLong)
  }
  print("ok")
}

let arguments = CommandLine.arguments
if arguments.count == 2, arguments[1] == "--selftest" {
  selftest()
} else if arguments.count == 2 || arguments.count == 3 || (arguments.count >= 6 && arguments[1] == "--autotest") {
  setvbuf(stdout, nil, _IOLBF, 0)  // lines reach a log file as they happen
  let auto = arguments[1] == "--autotest"
  let executable = URL(fileURLWithPath: arguments[auto ? 2 : 1])
  let data = arguments.count >= 3
    ? URL(fileURLWithPath: arguments[auto ? 3 : 2])
    : FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("BrowserKitExemplo")
  // Unsigned during development: the engine has to be told to accept it.
  let engine = BrowserEngine(
    executable: executable, dataDirectory: data,
    arguments: auto ? Array(arguments.dropFirst(6)) : ["--agens-accept-unsigned", "--use-mock-keychain", "--no-first-run"])
  let app = NSApplication.shared
  let controller = Controller(engine: engine, autotest: auto ? (arguments[4], arguments[5]) : nil)
  app.delegate = controller
  // The autotest never becomes the active app (no Dock icon either).
  app.setActivationPolicy(auto ? .accessory : .regular)
  app.mainMenu = makeMenu()
  app.run()
} else {
  FileHandle.standardError.write(Data(
    "usage: exemplo <engine executable> [data folder] | --autotest <engine executable> <data folder> <page url> <out folder> [engine args...] | --selftest\n".utf8))
  exit(1)
}

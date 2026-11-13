import AppKit

// DevTools for the host (docs/protocolo.md, "Passo 5.5"): docked at the bottom or on the right it
// is a view the host shows like a tab (`BrowserTabView` with its id), next to the page; in its own
// window it is the engine's, the only window the engine puts on screen. `BrowserDevToolsSplit`
// lays the page and its DevTools out for a host that draws nothing of its own.

/// Where DevTools goes.
public enum DevToolsDock: String, Sendable, CaseIterable {
  case bottom, right
  /// Its own window (the engine's).
  case window
}

/// A tab's DevTools (`view.devtools`): its view id (`BrowserTabView(engine:tab: devtools)`), which
/// stays the same while it lives, also across sides, and where it is now. In `.window` there is
/// nothing to show: the engine has it in its window.
public struct DevToolsState: Sendable, Equatable {
  /// The inspected tab.
  public let tab: String
  public let devtools: String
  public let dock: DevToolsDock

  init?(message: [String: JSON]) {
    guard let tab = message["tab"]?.string, let devtools = message["devtools"]?.string,
      let dock = message["dock"]?.string.flatMap(DevToolsDock.init(rawValue:))
    else { return nil }
    self.tab = tab
    self.devtools = devtools
    self.dock = dock
  }
}

extension BrowserEngine {
  /// Opens the inspector (DevTools) for a tab, on the element at `point` (the view's points, as
  /// `view.mouse`) or just opened: at `dock`, else at `devToolsDock`, else where the engine had it
  /// last (its own window at first). If it is open for that tab already it moves there and shows
  /// again. Returns its view id when docked (show it like a tab, `BrowserTabView`), nil in a window.
  /// `denied` while an agent works on the tab, `failed` when developer tools are turned off for
  /// the page; an engine older than this op throws `unknown_op`. Answering the right-click menu's
  /// `inspect` does the same, with `devToolsDock`.
  @discardableResult
  public func inspect(_ tab: String, at point: CGPoint? = nil, dock: DevToolsDock? = nil) async throws(BrowserError)
    -> String?
  {
    guard let connection else { throw BrowserError(code: BrowserError.disconnected) }
    var params: [String: JSON] = ["tab": .string(tab)]
    if let point {
      params["x"] = .number(Double(point.x))
      params["y"] = .number(Double(point.y))
    }
    let dock = dock ?? devToolsDock
    if let dock { params["dock"] = .string(dock.rawValue) }
    if dock == nil || dock == .window { yieldActivationToEngine() }
    let reply = try await connection.send(op: "view.inspect", params: params)
    return reply["devtools"]?.string
  }

  /// Moves the tab's open DevTools to another side, or into its own window and back (the view id
  /// stays). `not_found` when it has none open.
  public func setDevToolsDock(_ tab: String, _ dock: DevToolsDock) async throws(BrowserError) {
    guard let connection else { throw BrowserError(code: BrowserError.disconnected) }
    if dock == .window { yieldActivationToEngine() }
    try await connection.send(op: "view.devtools.dock", params: ["tab": .string(tab), "dock": .string(dock.rawValue)])
  }

  /// Closes the tab's DevTools (`onDevToolsClosed` follows). `not_found` when it has none open.
  public func closeDevTools(_ tab: String) async throws(BrowserError) {
    guard let connection else { throw BrowserError(code: BrowserError.disconnected) }
    try await connection.send(op: "view.devtools.close", params: ["tab": .string(tab)])
  }
}

/// A tab's page with its DevTools docked next to it, as the prototype draws it: DevTools at the
/// bottom or on the right, a divider to drag (at least 120 pt of DevTools and 200 pt of page),
/// and a bar over DevTools with bottom, right, its own window and close. Put it where you would put
/// the tab's `BrowserTabView`; it follows the engine's `view.devtools` events by itself. The side
/// the person picks goes to `engine.devToolsDock` (keep it if you like); the sizes are
/// `bottomSize` and `rightSize`.
public final class BrowserDevToolsSplit: NSView {
  public let page: BrowserTabView
  public private(set) var devtools: BrowserTabView?
  /// DevTools' height at the bottom and width on the right, bar included (nil: 40% and 420 pt).
  public var bottomSize: CGFloat? { didSet { needsLayout = true } }
  public var rightSize: CGFloat? { didSet { needsLayout = true } }
  /// Called after the person drags the divider, to keep the size.
  public var onResize: ((DevToolsDock, CGFloat) -> Void)?

  private weak var engine: BrowserEngine?
  private var dock: DevToolsDock = .bottom
  private let divider = DevToolsDivider()
  private let bar = NSStackView()
  private var buttons: [DevToolsDock: NSButton] = [:]
  static let barHeight: CGFloat = 28, minDevTools: CGFloat = 120, minPage: CGFloat = 200

  public init(engine: BrowserEngine, tab: String) {
    self.engine = engine
    page = BrowserTabView(engine: engine, tab: tab)
    super.init(frame: .zero)
    addSubview(page)
    divider.onDrag = { [weak self] point, done in self?.drag(to: point, done: done) }
    bar.orientation = .horizontal
    bar.spacing = 2
    bar.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 6)
    let title = NSTextField(labelWithString: "DevTools")
    title.font = .systemFont(ofSize: 12, weight: .medium)
    title.textColor = .secondaryLabelColor
    title.setContentHuggingPriority(.init(1), for: .horizontal)
    bar.addArrangedSubview(title)
    let symbols: [(DevToolsDock?, String, String)] = [
      (.bottom, "rectangle.bottomthird.inset.filled", "Encaixar embaixo"),
      (.right, "rectangle.rightthird.inset.filled", "Encaixar à direita"),
      (.window, "macwindow.on.rectangle", "Em janela própria"), (nil, "xmark", "Fechar DevTools"),
    ]
    for (dock, symbol, label) in symbols {
      let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label) ?? NSImage(),
                            target: self, action: #selector(pressed(_:)))
      button.isBordered = false
      button.toolTip = label
      button.tag = dock.map { DevToolsDock.allCases.firstIndex(of: $0)! } ?? -1
      bar.addArrangedSubview(button)
      if let dock { buttons[dock] = button }
    }
    bar.wantsLayer = true
    engine.register(self, tab: tab)
    update()
  }
  required init?(coder: NSCoder) { fatalError("BrowserDevToolsSplit is made in code") }

  public override var isFlipped: Bool { true }

  /// The engine's DevTools state for the tab changed (or this view just appeared).
  func update() {
    guard let engine else { return }
    let state = engine.devTools[page.tab]
    let docked = state.flatMap { $0.dock == .window ? nil : $0 }
    if let docked {
      dock = docked.dock
      if devtools?.tab != docked.devtools {
        devtools?.removeFromSuperview()
        let view = BrowserTabView(engine: engine, tab: docked.devtools)
        addSubview(view)
        devtools = view
      }
      if divider.superview == nil { addSubview(divider) }
      if bar.superview == nil { addSubview(bar) }
    } else {
      devtools?.removeFromSuperview()
      devtools = nil
      divider.removeFromSuperview()
      bar.removeFromSuperview()
    }
    for (dock, button) in buttons { button.contentTintColor = dock == state?.dock ? .controlAccentColor : .secondaryLabelColor }
    needsLayout = true
  }

  /// DevTools' part of `total`, kept to the minimums.
  static func size(_ wanted: CGFloat?, default fallback: CGFloat, total: CGFloat) -> CGFloat {
    max(min(wanted ?? fallback, total - minPage - 1), min(minDevTools, total / 2)).rounded(.down)
  }

  public override func layout() {
    super.layout()
    guard let devtools else {
      page.frame = bounds
      return
    }
    let right = dock == .right
    let total = right ? bounds.width : bounds.height
    let size = Self.size(right ? rightSize : bottomSize, default: right ? 420 : (total * 0.4).rounded(), total: total)
    if right {
      page.frame = NSRect(x: 0, y: 0, width: total - size - 1, height: bounds.height)
      divider.frame = NSRect(x: page.frame.maxX - 4, y: 0, width: 9, height: bounds.height)
      bar.frame = NSRect(x: page.frame.maxX + 1, y: 0, width: size, height: Self.barHeight)
    } else {
      page.frame = NSRect(x: 0, y: 0, width: bounds.width, height: total - size - 1)
      divider.frame = NSRect(x: 0, y: page.frame.maxY - 4, width: bounds.width, height: 9)
      bar.frame = NSRect(x: 0, y: page.frame.maxY + 1, width: bounds.width, height: Self.barHeight)
    }
    divider.vertical = right
    devtools.frame = NSRect(x: bar.frame.minX, y: bar.frame.maxY, width: bar.frame.width, height: bounds.height - bar.frame.maxY)
    bar.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
  }

  private func drag(to point: NSPoint, done: Bool) {
    let right = dock == .right
    let total = right ? bounds.width : bounds.height
    let size = max(Self.minDevTools, min(right ? bounds.width - point.x : bounds.height - point.y, total - Self.minPage - 1)).rounded()
    if right { rightSize = size } else { bottomSize = size }
    divider.showSize(size, of: total, done: done)
    if done { onResize?(dock, size) }
  }

  @objc private func pressed(_ sender: NSButton) {
    guard let engine else { return }
    let tab = page.tab
    guard sender.tag >= 0 else {
      Task { try? await engine.closeDevTools(tab) }
      return
    }
    let dock = DevToolsDock.allCases[sender.tag]
    engine.devToolsDock = dock
    Task { try? await engine.setDevToolsDock(tab, dock) }
  }
}

/// The 1 pt line between the page and DevTools, 9 pt to grab, with the size while dragged.
final class DevToolsDivider: NSView {
  var vertical = false {
    didSet { if vertical != oldValue { window?.invalidateCursorRects(for: self); needsDisplay = true } }
  }
  var onDrag: ((NSPoint, Bool) -> Void)?
  private let label = NSTextField(labelWithString: "")
  private var dragging = false

  override init(frame: NSRect) {
    super.init(frame: frame)
    label.font = .systemFont(ofSize: 11.5, weight: .medium)
    label.drawsBackground = true
    label.backgroundColor = .windowBackgroundColor
    label.isHidden = true
    setAccessibilityRole(.splitter)
    setAccessibilityLabel("Arraste para mudar o tamanho")
  }
  required init?(coder: NSCoder) { fatalError("made in code") }

  override var isFlipped: Bool { true }
  override func draw(_ dirtyRect: NSRect) {
    (dragging ? NSColor.systemOrange : NSColor.separatorColor).setFill()
    (vertical ? NSRect(x: bounds.midX.rounded(.down), y: 0, width: 1, height: bounds.height)
      : NSRect(x: 0, y: bounds.midY.rounded(.down), width: bounds.width, height: 1)).fill()
  }
  override func resetCursorRects() { addCursorRect(bounds, cursor: vertical ? .resizeLeftRight : .resizeUpDown) }
  override func mouseDown(with event: NSEvent) {
    dragging = true
    needsDisplay = true
  }
  override func mouseDragged(with event: NSEvent) {
    onDrag?(superview?.convert(event.locationInWindow, from: nil) ?? .zero, false)
  }
  override func mouseUp(with event: NSEvent) {
    dragging = false
    needsDisplay = true
    onDrag?(superview?.convert(event.locationInWindow, from: nil) ?? .zero, true)
  }

  /// "312 px · 42%" next to the divider while it is dragged.
  func showSize(_ size: CGFloat, of total: CGFloat, done: Bool) {
    label.stringValue = Self.sizeText(size, of: total)
    if label.superview == nil { superview?.addSubview(label) }
    label.sizeToFit()
    label.frame.origin = vertical ? NSPoint(x: frame.minX - label.frame.width - 4, y: frame.midY - label.frame.height / 2)
      : NSPoint(x: frame.midX - label.frame.width / 2, y: frame.minY - label.frame.height - 4)
    label.isHidden = done
  }

  static func sizeText(_ size: CGFloat, of total: CGFloat) -> String {
    "\(Int(size.rounded())) px · \(Int((size / total * 100).rounded()))%"
  }
}

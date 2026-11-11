import AppKit
import QuartzCore

/// The page of one tab. It sends its size, focus and input to the engine and shows the picture
/// the engine draws (`view.layer`) in a `CALayerHost`. Put it in a window to show the tab, take it
/// out to stop drawing (`view.detach`). Several views can be alive at once, each on its own tab.
///
/// The same layer setup as Chromium's own view for a page (DisplayCALayerTree): a layer-hosting
/// view, a flipped layer the size of the view, the CALayerHost at its origin.
public final class BrowserTabView: NSView, @preconcurrency NSTextInputClient {
  public let tab: String
  /// The connection the tab id belongs to: after the engine restarts, a leftover view sends nothing.
  private weak var connection: BrowserConnection?
  private let flippedLayer = CALayer()
  private var host: CALayer?
  /// What the last view.attach/view.resize said; nil while detached.
  private var sentSize: [String: JSON]?

  // What the text input system did with the key being handled (sent along with it).
  private var handlingKey = false
  private var insertedText = ""
  private var commands: [String] = []
  private var marked = ""
  private var markedSelection = NSRange(location: 0, length: 0)
  private var unmarked = false

  /// The page's mouse cursor (`view.cursor`), by its protocol name; an unknown one is `default`.
  private(set) var cursorName = "default"
  /// Where the text being edited is (`view.caret`), in points from the top left.
  var caret: CGRect? {
    didSet { inputContext?.invalidateCharacterCoordinates() }
  }

  public init(engine: BrowserEngine, tab: String) {
    connection = engine.connection
    self.tab = tab
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
    engine.register(self, tab: tab)
  }
  required init?(coder: NSCoder) { fatalError("BrowserTabView is made in code") }

  private var tabParam: [String: JSON] { ["tab": .string(tab)] }

  /// A CALayerHost showing the engine's CAContext, or nil if this macOS no longer has the class.
  static func makeLayerHost(context: UInt32) -> CALayer? {
    guard let type = NSClassFromString("CALayerHost") as? CALayer.Type else { return nil }
    let host = type.init()
    host.anchorPoint = .zero
    host.setValue(NSNumber(value: context), forKey: "contextId")
    host.autoresizingMask = [.layerMaxXMargin, .layerMaxYMargin]
    return host
  }

  func show(context: UInt32) {
    guard sentSize != nil, let new = Self.makeLayerHost(context: context) else { return }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    flippedLayer.addSublayer(new)
    host?.removeFromSuperlayer()
    host = new
    CATransaction.commit()
  }

  // Size and attachment.
  private func sendSize() {
    guard let connection, let window, bounds.width > 0, bounds.height > 0 else { return }
    var params = tabParam
    params["width"] = .number(bounds.width.rounded())
    params["height"] = .number(bounds.height.rounded())
    params["scale"] = .number(window.backingScaleFactor)
    guard params != sentSize else { return }
    connection.request(op: sentSize == nil ? "view.attach" : "view.resize", params: params)
    sentSize = params
  }

  public override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window != nil {
      sendSize()
    } else if sentSize != nil {
      sentSize = nil
      connection?.request(op: "view.detach", params: tabParam)
      host?.removeFromSuperlayer()
      host = nil
    }
  }

  public override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    sendSize()
  }

  public override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    flippedLayer.frame = bounds
    CATransaction.commit()
    sendSize()
  }

  // Cursor.
  private static let hiddenCursor = NSCursor(image: NSImage(size: NSSize(width: 1, height: 1)), hotSpot: .zero)

  /// The cursor for a `view.cursor` name, or nil for a name this kit does not know.
  static func cursor(_ name: String) -> NSCursor? {
    switch name {
    // macOS has no public wait or move cursor.
    case "default", "wait", "move": return .arrow
    case "pointer": return .pointingHand
    case "text": return .iBeam
    case "crosshair": return .crosshair
    case "grab": return .openHand
    case "grabbing": return .closedHand
    case "not_allowed": return .operationNotAllowed
    case "resize_ew": return .resizeLeftRight
    case "resize_ns": return .resizeUpDown
    case "resize_nesw", "resize_nwse":
      guard #available(macOS 15, *) else { return .arrow }
      return .frameResize(position: name == "resize_nesw" ? .topRight : .topLeft, directions: .all)
    case "none": return hiddenCursor
    default: return nil
    }
  }

  func setCursor(_ name: String) {
    cursorName = Self.cursor(name) == nil ? "default" : name
    window?.invalidateCursorRects(for: self)
  }

  public override func resetCursorRects() {
    addCursorRect(bounds, cursor: Self.cursor(cursorName) ?? .arrow)
  }

  // Focus.
  public override var acceptsFirstResponder: Bool { true }
  public override func becomeFirstResponder() -> Bool {
    post("view.focus", ["on": true])
    return true
  }
  public override func resignFirstResponder() -> Bool {
    post("view.focus", ["on": false])
    return true
  }

  private func post(_ op: String, _ params: [String: JSON] = [:]) {
    connection?.post(op: op, params: tabParam.merging(params) { $1 })
  }

  /// The NSEvent as the engine rebuilds it (ui::EventFromData), or nil for events with no CGEvent.
  static func encoded(_ event: NSEvent) -> String? {
    (event.cgEvent?.data as Data?)?.base64EncodedString()
  }

  // Mouse. Points go in the page's coordinates: from the top left.
  // shortcut: the right button is not sent. The engine would open its own context menu, in a
  // process with no window to anchor it; the menu has to come here as data first.
  private func mouse(_ event: NSEvent, op: String) {
    guard let data = Self.encoded(event) else { return }
    let point = convert(event.locationInWindow, from: nil)
    post(op, ["data": .string(data), "x": .number(point.x), "y": .number(bounds.height - point.y)])
  }
  public override func mouseDown(with event: NSEvent) {
    window?.makeFirstResponder(self)
    mouse(event, op: "view.mouse")
  }
  public override func mouseUp(with event: NSEvent) { mouse(event, op: "view.mouse") }
  public override func mouseDragged(with event: NSEvent) { mouse(event, op: "view.mouse") }
  public override func mouseMoved(with event: NSEvent) { mouse(event, op: "view.mouse") }
  public override func mouseExited(with event: NSEvent) { post("view.mouse.leave") }
  public override func scrollWheel(with event: NSEvent) { mouse(event, op: "view.wheel") }

  // Keyboard. The text input system runs here (dead keys, input methods, key bindings); the
  // engine gets the key plus what came out of it, as its own view would have collected.
  public override func keyDown(with event: NSEvent) {
    guard let data = Self.encoded(event) else { return }
    let hadMarked = !marked.isEmpty
    insertedText = ""
    commands = []
    unmarked = false
    handlingKey = true
    interpretKeyEvents([event])
    handlingKey = false
    post("view.key", [
      "data": .string(data), "text": .string(insertedText), "commands": .array(commands.map(JSON.string)),
      "marked": .string(marked), "sel_start": .number(Double(markedSelection.location)),
      "sel_end": .number(Double(NSMaxRange(markedSelection))), "had_marked": .bool(hadMarked),
      "unmarked": .bool(unmarked),
    ])
  }
  // Key up and modifier changes carry only the event: nothing goes through the text system.
  public override func keyUp(with event: NSEvent) {
    if let data = Self.encoded(event) { post("view.key", ["data": .string(data)]) }
  }
  public override func flagsChanged(with event: NSEvent) {
    if let data = Self.encoded(event) { post("view.key", ["data": .string(data)]) }
  }
  public override func doCommand(by selector: Selector) {
    if handlingKey { commands.append(NSStringFromSelector(selector)) }
  }

  // NSTextInputClient.
  // shortcut: text that arrives outside a key press (the emoji picker, dictation) is dropped; it
  // needs the engine to report the selection. The input method's window goes at `caret`, or under
  // the view until the engine reports one.
  public func insertText(_ string: Any, replacementRange: NSRange) {
    if handlingKey { insertedText += (string as? NSAttributedString)?.string ?? (string as? String ?? "") }
    marked = ""
  }
  public func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
    marked = (string as? NSAttributedString)?.string ?? (string as? String ?? "")
    markedSelection = selectedRange.location == NSNotFound ? NSRange(location: 0, length: 0) : selectedRange
  }
  public func unmarkText() {
    marked = ""
    unmarked = true
  }
  public func hasMarkedText() -> Bool { !marked.isEmpty }
  public func markedRange() -> NSRange {
    marked.isEmpty ? NSRange(location: NSNotFound, length: 0) : NSRange(location: 0, length: marked.utf16.count)
  }
  public func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
  public func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
  public func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
  public func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
    let rect = caret.map { NSRect(x: $0.minX, y: bounds.height - $0.maxY, width: $0.width, height: $0.height) }
      ?? NSRect(x: 0, y: 0, width: bounds.width, height: 0)
    return window?.convertToScreen(convert(rect, to: nil)) ?? .zero
  }
  public func characterIndex(for point: NSPoint) -> Int { NSNotFound }

  // The Edit menu.
  @objc public func cut(_ sender: Any?) { post("view.edit", ["command": "cut"]) }
  @objc public func copy(_ sender: Any?) { post("view.edit", ["command": "copy"]) }
  @objc public func paste(_ sender: Any?) { post("view.edit", ["command": "paste"]) }
  @objc public func undo(_ sender: Any?) { post("view.edit", ["command": "undo"]) }
  @objc public func redo(_ sender: Any?) { post("view.edit", ["command": "redo"]) }
  public override func selectAll(_ sender: Any?) { post("view.edit", ["command": "selectAll"]) }
}

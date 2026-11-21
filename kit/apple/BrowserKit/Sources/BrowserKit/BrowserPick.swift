import CoreGraphics
import Foundation

/// An element the person pointed at on a tab (`view.picked`, docs/protocolo.md "Passo 5.4"). Every
/// string comes from the page, cut by the engine: show it, never run it.
public struct PickedElement: Sendable, Equatable {
  public let tab: String
  /// A CSS path that finds the element again (`#card > p:nth-of-type(2)`).
  public let selector: String
  /// Its outer HTML, at most 16 KiB; a password field has no value in it.
  public let html: String
  public let htmlTruncated: Bool
  /// Its visible text, at most 2000 characters.
  public let text: String
  public let textTruncated: Bool
  /// Where it is, in the view's points from its top left (the space of `view.mouse`). It may
  /// reach past the view.
  public let frame: CGRect
  /// About a dozen computed values (`font-size`, `color`, `padding`…), each at most 40 characters.
  public let styles: [String: String]
  /// A PNG of the part inside the view, at the screen's scale (half of it for a big element); nil
  /// when it did not fit the budget or nothing of it was on screen (`pngSkipped`).
  public let png: Data?
  public let pngSkipped: Bool

  init?(message: [String: JSON]) {
    guard let tab = message["tab"]?.string, let selector = message["selector"]?.string else { return nil }
    func number(_ key: String) -> Double { message[key]?.double ?? 0 }
    self.tab = tab
    self.selector = selector
    html = message["html"]?.string ?? ""
    htmlTruncated = message["truncated"]?.bool ?? false
    text = message["text"]?.string ?? ""
    textTruncated = message["text_truncated"]?.bool ?? false
    frame = CGRect(x: number("x"), y: number("y"), width: number("width"), height: number("height"))
    styles = (message["styles"]?.object ?? [:]).compactMapValues(\.string)
    png = message["png"]?.string.flatMap { Data(base64Encoded: $0) }
    pngSkipped = message["png_skipped"]?.bool ?? false
  }
}

/// What `BrowserEngine.onPick` gets: a pick, or the picker ending without one (Escape in the
/// page, navigation, the page's process gone, an agent starting on the tab). After `cancelled` the
/// earlier pick is no longer highlighted.
public enum PickResult: Sendable, Equatable {
  case picked(PickedElement)
  case cancelled(tab: String)

  init?(message: [String: JSON]) {
    if message["cancelled"]?.bool == true, let tab = message["tab"]?.string {
      self = .cancelled(tab: tab)
    } else if let element = PickedElement(message: message) {
      self = .picked(element)
    } else {
      return nil
    }
  }
}

/// Where `stepPick` moves the pick.
public enum PickStep: String, Sendable {
  case parent, child
}

/// The page's selected text (`view.selection`).
public struct PageSelection: Sendable, Equatable {
  /// At most 16 KiB; empty when nothing is selected or the selection is inside a form field.
  public let text: String
  public let truncated: Bool
}

extension BrowserConnection {
  /// Arms the picker on an attached tab (`on`), again after a pick, or ends it and clears the
  /// highlight. The result comes in `BrowserEngine.onPick`. `denied` while an agent works on the
  /// tab; an engine older than the picker throws `unknown_op`.
  public func pick(_ tab: String, on: Bool = true) async throws(BrowserError) {
    try await send(op: "view.pick", params: ["tab": .string(tab), "on": .bool(on)])
  }

  /// Moves the pick to its parent or first child element; a new pick follows in `onPick`.
  /// `not_found` when there is none (the pick stays) or nothing is picked.
  public func stepPick(_ tab: String, to step: PickStep) async throws(BrowserError) {
    try await send(op: "view.pick.step", params: ["tab": .string(tab), "to": .string(step.rawValue)])
  }

  /// The text the page has selected now (the right-click menu's `selection` stops at 200 characters).
  public func selection(_ tab: String) async throws(BrowserError) -> PageSelection {
    let reply = try await send(op: "view.selection", params: ["tab": .string(tab)])
    return PageSelection(text: reply["text"]?.string ?? "", truncated: reply["truncated"]?.bool ?? false)
  }
}

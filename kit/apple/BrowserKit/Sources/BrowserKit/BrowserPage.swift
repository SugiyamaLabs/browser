import Foundation

/// A search's count on a tab (`view.find`, docs/protocolo.md "Passo 5.7"): after each `find`, and
/// `0` and `0` after `stopFind`. `active` counts from 1; 0 when nothing is selected.
public struct FindResult: Sendable, Equatable {
  public let tab: String
  public let matches: Int
  public let active: Int

  public init(tab: String, matches: Int, active: Int) {
    self.tab = tab
    self.matches = matches
    self.active = active
  }
}

/// What `zoom` does to the tab's site.
public enum ZoomChange: Sendable, Equatable {
  case zoomIn, zoomOut, reset
  /// 0.25 to 5.
  case factor(Double)
}

extension BrowserConnection {
  /// How many closed tabs of the ato `reopenClosedTab` can bring back (never an agent's), to grey
  /// out the menu item at 0.
  public func reopenableCount(ato: String) async throws(BrowserError) -> Int {
    let reply = try await send(op: "view.reopenable", params: ["ato": .string(ato)])
    return reply["count"]?.int ?? 0
  }

  /// Brings back the ato's most recently closed tab, with its history, and returns its id; it
  /// arrives as `view.tab` too. `not_found` when there is none.
  public func reopenClosedTab(ato: String) async throws(BrowserError) -> String {
    let reply = try await send(op: "view.reopen", params: ["ato": .string(ato)])
    return reply["tab"]?.string ?? ""
  }

  /// Finds `text` in the page, which highlights it itself; the count comes in `BrowserEngine.onFind`.
  /// `next`: on to the following match of the same text (backwards with `forward: false`); without
  /// it the search starts over. `denied` while an agent works on the tab.
  public func find(
    _ text: String, in tab: String, forward: Bool = true, matchCase: Bool = false, next: Bool = false
  ) async throws(BrowserError) {
    try await send(op: "view.find", params: [
      "tab": .string(tab), "text": .string(text), "forward": .bool(forward), "match_case": .bool(matchCase),
      "next": .bool(next),
    ])
  }

  /// Ends the search and its highlight; with `keepSelection` the active match stays selected.
  public func stopFind(in tab: String, keepSelection: Bool = false) async throws(BrowserError) {
    try await send(op: "view.find.stop", params: ["tab": .string(tab), "keep_selection": .bool(keepSelection)])
  }

  /// Changes the zoom of the tab's site in its ato (remembered per site, as in Chrome), or with nil
  /// only reads it. Returns the factor now (1 is 100%). `denied` for a change while an agent works.
  @discardableResult
  public func zoom(_ change: ZoomChange? = nil, in tab: String) async throws(BrowserError) -> Double {
    var params: [String: JSON] = ["tab": .string(tab)]
    switch change {
    case .zoomIn: params["level"] = "in"
    case .zoomOut: params["level"] = "out"
    case .reset: params["level"] = "reset"
    case .factor(let factor): params["factor"] = .number(factor)
    case nil: break
    }
    let reply = try await send(op: "view.zoom", params: params)
    return reply["factor"]?.double ?? 1
  }
}

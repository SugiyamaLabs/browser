import Foundation

/// A download of an ato (`view.download`, docs/protocolo.md "Passo 5.9"). File names and origins
/// come from the page: show them, never run them.
public struct Download: Sendable, Equatable, Identifiable {
  public enum State: Sendable, Equatable {
    case inProgress, paused, complete, cancelled, interrupted
    /// Held until the person decides: `keepDangerous` or `discardDangerous`. Never opened by itself.
    case dangerous
    /// A state a newer engine sends.
    case other(String)

    init(_ name: String) {
      switch name {
      case "in_progress": self = .inProgress
      case "paused": self = .paused
      case "complete": self = .complete
      case "cancelled": self = .cancelled
      case "interrupted": self = .interrupted
      case "dangerous": self = .dangerous
      default: self = .other(name)
      }
    }
  }

  public let id: String
  public let ato: String
  /// The tab that started it, while the engine knows it (none for older ones from the history).
  public let tab: String?
  public let fileName: String
  /// Where the file goes (or went), once the engine knows it.
  public let path: String?
  /// Where it came from: scheme, host and port only.
  public let origin: String
  public let mime: String
  /// 0 when unknown.
  public let totalBytes: Int64
  public let receivedBytes: Int64
  public let state: State
  /// Why it is dangerous (Chromium's name, e.g. `DANGEROUS_FILE`), only while `dangerous`.
  public let dangerType: String?
  /// An agent's tab started it.
  public let byAgent: Bool

  init?(message: [String: JSON]) {
    guard let id = message["id"]?.string, let ato = message["ato"]?.string else { return nil }
    self.id = id
    self.ato = ato
    tab = message["tab"]?.string
    fileName = message["file_name"]?.string ?? ""
    path = message["path"]?.string
    origin = message["origin"]?.string ?? ""
    mime = message["mime"]?.string ?? ""
    totalBytes = Int64(message["total_bytes"]?.double ?? 0)
    receivedBytes = Int64(message["received_bytes"]?.double ?? 0)
    state = State(message["state"]?.string ?? "")
    dangerType = message["danger_type"]?.string
    byAgent = message["by_agent"]?.bool ?? false
  }
}

/// What `downloadAction` does to a download.
public enum DownloadAction: String, Sendable {
  case pause, resume, cancel
  /// Opens a complete file with its app; `denied` for a dangerous one.
  case open
  case showInFinder = "show_in_finder"
  /// Out of the list: a running or dangerous one is cancelled and its file goes; a finished file stays.
  case remove
  case keepDangerous = "keep_dangerous"
  case discardDangerous = "discard_dangerous"
}

/// A row of the address field's suggestions (`view.suggest`).
public struct Suggestion: Sendable, Equatable, Identifiable {
  public enum Kind: Sendable, Equatable {
    case history, bookmark, search
    /// Open in another tab of the ato: "Ir para a aba" (`.switchToTab`).
    case openTab
    case other(String)

    init(_ name: String) {
      switch name {
      case "history": self = .history
      case "bookmark": self = .bookmark
      case "search": self = .search
      case "open_tab": self = .openTab
      default: self = .other(name)
      }
    }
  }

  /// Valid for this list only (`openSuggestion`, `deleteSuggestion`).
  public let id: String
  /// The address as shown, or the search terms.
  public let text: String
  /// What the field shows while this row is selected.
  public let fill: String
  /// First row only: the rest of the address after what was typed, shown selected after the caret.
  public let inlineCompletion: String
  /// The page's title; for a search, the engine's name.
  public let title: String
  public let url: String
  public let kind: Kind
  /// Matched characters, to draw bold: UTF-16 offsets.
  public let textBold: [Range<Int>]
  public let titleBold: [Range<Int>]
  /// `deleteSuggestion` takes it out of the history.
  public let deletable: Bool
  /// The page's icon (PNG) from the local history, when it has one.
  public let favicon: Data?

  init?(message: [String: JSON]) {
    guard let id = message["row_id"]?.string else { return nil }
    func ranges(_ key: String) -> [Range<Int>] {
      (message[key]?.array ?? []).compactMap { pair in
        guard let pair = pair.array, pair.count == 2, let start = pair[0].int, let end = pair[1].int, start <= end else {
          return nil
        }
        return start..<end
      }
    }
    self.id = id
    text = message["text"]?.string ?? ""
    fill = message["fill"]?.string ?? ""
    inlineCompletion = message["inline"]?.string ?? ""
    title = message["title"]?.string ?? ""
    url = message["url"]?.string ?? ""
    kind = Kind(message["kind"]?.string ?? "")
    textBold = ranges("text_bold")
    titleBold = ranges("title_bold")
    deletable = message["deletable"]?.bool ?? false
    favicon = message["favicon"]?.string.flatMap { Data(base64Encoded: $0) }
  }
}

/// The suggestions for what was typed in a tab's address field. `done` false: more may come in
/// `BrowserEngine.onSuggestions` (the slower history lookups, icons).
public struct Suggestions: Sendable, Equatable {
  public let tab: String
  public let text: String
  public let rows: [Suggestion]
  public let done: Bool

  init(tab: String, text: String, message: [String: JSON]) {
    self.tab = message["tab"]?.string ?? tab
    self.text = message["text"]?.string ?? text
    rows = (message["rows"]?.array ?? []).compactMap { $0.object.flatMap(Suggestion.init(message:)) }
    done = message["done"]?.bool ?? true
  }
}

/// Where `openSuggestion` opens a row.
public enum SuggestionDisposition: String, Sendable {
  case currentTab = "current_tab"
  case newTab = "new_tab"
  /// The tab of the ato that already shows it (`.openTab` rows): the engine only names it.
  case switchToTab = "switch_to_tab"
}

extension BrowserConnection {
  /// The loaded atos' downloads (or one ato's), newest first, the ones from the history included.
  public func downloads(ato: String? = nil) async throws(BrowserError) -> [Download] {
    var params: [String: JSON] = [:]
    if let ato { params["ato"] = .string(ato) }
    let reply = try await send(op: "view.downloads", params: params)
    return (reply["downloads"]?.array ?? []).compactMap { $0.object.flatMap(Download.init(message:)) }
  }

  public func downloadAction(_ action: DownloadAction, id: String) async throws(BrowserError) {
    try await send(op: "view.download.action", params: ["download": .string(id), "action": .string(action.rawValue)])
  }

  /// Suggestions for `text` typed in the tab's address field; call it on every edit, "" when the
  /// field empties or loses focus. `allowInline` false after a deletion, with the caret not at the
  /// end, or while composing.
  public func suggest(_ text: String, in tab: String, allowInline: Bool = true) async throws(BrowserError)
    -> Suggestions
  {
    let reply = try await send(
      op: "view.suggest", params: ["tab": .string(tab), "text": .string(text), "allow_inline": .bool(allowInline)])
    return Suggestions(tab: tab, text: text, message: reply)
  }

  /// Opens a row of the tab's current list; returns the tab that shows it (the same one, a new
  /// one, or for `.switchToTab` the one that already has it, to bring forward).
  @discardableResult
  public func openSuggestion(
    _ id: String, in tab: String, disposition: SuggestionDisposition = .currentTab
  ) async throws(BrowserError) -> String {
    let reply = try await send(
      op: "view.suggest.open",
      params: ["tab": .string(tab), "row_id": .string(id), "disposition": .string(disposition.rawValue)])
    return reply["tab"]?.string ?? tab
  }

  /// Takes a `deletable` row out of the history; the list comes again in `onSuggestions`.
  public func deleteSuggestion(_ id: String) async throws(BrowserError) {
    try await send(op: "view.suggest.delete", params: ["row_id": .string(id)])
  }
}

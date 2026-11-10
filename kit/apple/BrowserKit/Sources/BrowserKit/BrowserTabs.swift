import Foundation
import Observation

/// An agent using a tab (`control` in `view.tab`). The host draws its indicator from this.
public struct AgentControl: Sendable, Equatable {
  public let agent: String
  public let title: String
  public let detail: String
  /// `"working"` or `"paused"`.
  public let state: String
}

/// A tab as the engine last reported it.
public struct BrowserTab: Sendable, Equatable, Identifiable {
  public let id: String
  public let ato: String
  public var title: String
  public var url: String
  public var loading: Bool
  public var audible: Bool
  public var canGoBack: Bool
  public var canGoForward: Bool
  public var control: AgentControl?
  /// PNG data, fetched when the engine says the icon changed.
  public var favicon: Data?

  init?(message: [String: JSON]) {
    guard let id = message["tab"]?.string, let ato = message["ato"]?.string else { return nil }
    self.id = id
    self.ato = ato
    title = message["title"]?.string ?? ""
    url = message["url"]?.string ?? ""
    loading = message["loading"]?.bool ?? false
    audible = message["audible"]?.bool ?? false
    canGoBack = message["can_back"]?.bool ?? false
    canGoForward = message["can_forward"]?.bool ?? false
    control = message["control"]?.object.map {
      AgentControl(
        agent: $0["agent"]?.string ?? "", title: $0["title"]?.string ?? "", detail: $0["detail"]?.string ?? "",
        state: $0["state"]?.string ?? "")
    }
  }
}

/// The tabs of every ato the host loaded or that sent events, kept current by `view.tab`,
/// `view.closed` and `view.favicon`. Emptied when the engine goes away (tab ids do not survive it).
@MainActor @Observable public final class BrowserTabs {
  /// In the order the kit first heard of them.
  public private(set) var all: [BrowserTab] = []

  @ObservationIgnored weak var connection: BrowserConnection?

  init() {}

  public func tabs(in ato: String) -> [BrowserTab] { all.filter { $0.ato == ato } }
  public subscript(id: String) -> BrowserTab? { all.first { $0.id == id } }

  /// Asks the engine for the ato's tabs (`view.tabs`) and merges them in.
  public func load(ato: String) async throws(BrowserError) {
    guard let connection else { throw BrowserError(code: BrowserError.disconnected) }
    let fresh = try await connection.tabs(ato: ato)
    let ids = Set(fresh.map(\.id))
    all.removeAll { $0.ato == ato && !ids.contains($0.id) }
    for tab in fresh { update(tab) }
    for tab in fresh where self[tab.id]?.favicon == nil { fetchFavicon(tab.id) }
  }

  /// Returns true for the events it handles.
  func handle(_ event: String, _ message: [String: JSON]) -> Bool {
    switch event {
    case "view.tab":
      if let tab = BrowserTab(message: message) { update(tab) }
    case "view.closed":
      all.removeAll { $0.id == message["tab"]?.string }
    case "view.favicon":
      if let id = message["tab"]?.string { fetchFavicon(id) }
    default:
      return false
    }
    return true
  }

  func reset() { all = [] }

  private func update(_ tab: BrowserTab) {
    if let index = all.firstIndex(where: { $0.id == tab.id }) {
      var tab = tab
      tab.favicon = all[index].favicon
      all[index] = tab
    } else {
      all.append(tab)
    }
  }

  private func fetchFavicon(_ id: String) {
    connection?.request(op: "view.favicon", params: ["tab": .string(id)]) { [weak self] result in
      guard let self, case .success(let reply) = result, let index = all.firstIndex(where: { $0.id == id }) else { return }
      all[index].favicon = reply["png"]?.string.flatMap { Data(base64Encoded: $0) }
    }
  }
}

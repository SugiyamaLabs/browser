import CoreGraphics
import Foundation

// Extensions for the host (docs/protocolo.md, "Passo 5.6"): the list per ato, the toolbar's state
// per tab, installing from a file (the person always answers the prompt, `UIRequest.Kind.extension`)
// and the extension's popup, a view the host shows like a tab (`BrowserTabView`). An engine older
// than these ops throws `unknown_op`. Ops and events name the extension `extension` (a request's
// `id` is its own); a listed one has it as `id`.

/// What a toolbar shows of an extension's action on a tab (or on every tab, when no tab was given).
public struct ExtensionActionState: Sendable, Equatable {
  /// Its tooltip; the extension's name when it set none.
  public let title: String
  /// "" for none.
  public let badge: String
  /// `#RRGGBB`, or nil for the host's default.
  public let badgeColor: String?
  /// Off on this tab: draw it greyed.
  public let visible: Bool
  /// A click opens a popup (`clickExtension` gives its id).
  public let hasPopup: Bool

  init(message: [String: JSON], name: String) {
    title = message["title"]?.string ?? name
    badge = message["badge"]?.string ?? ""
    badgeColor = message["badge_color"]?.string.flatMap { $0.isEmpty ? nil : $0 }
    visible = message["visible"]?.bool ?? true
    hasPopup = message["popup"]?.bool ?? false
  }
}

/// An extension of an ato (`extensions.list`).
public struct BrowserExtension: Sendable, Equatable, Identifiable {
  /// Where it came from: the store updates it; a file does not; a folder stays linked to it.
  public enum Source: String, Sendable {
    case store, file, folder
  }
  public let id: String
  public let name: String
  public let version: String
  public let enabled: Bool
  /// nil for a source this kit does not know.
  public let source: Source?
  /// In the bar (else only in the extensions menu); kept per ato.
  public let pinned: Bool
  /// It has an options page (`openExtensionOptions`).
  public let hasOptions: Bool
  /// Ready to show.
  public let permissions: [String]
  /// Address patterns.
  public let hostPermissions: [String]
  /// The ids of the atos that have it, this one included.
  public let atos: [String]
  /// Its button, as the tab asked about shows it; nil when it has no action.
  public let action: ExtensionActionState?

  init?(message: [String: JSON]) {
    guard let id = message["id"]?.string else { return nil }
    func strings(_ key: String) -> [String] { (message[key]?.array ?? []).compactMap(\.string) }
    self.id = id
    name = message["name"]?.string ?? id
    version = message["version"]?.string ?? ""
    enabled = message["enabled"]?.bool ?? false
    source = message["from"]?.string.flatMap(Source.init(rawValue:))
    pinned = message["pinned"]?.bool ?? false
    hasOptions = message["options"]?.bool ?? false
    permissions = strings("permissions")
    hostPermissions = strings("host_permissions")
    atos = strings("atos")
    action = message["action"]?.bool == true ? ExtensionActionState(message: message, name: name) : nil
  }
}

/// `extension.changed`: something happened to an extension in an ato.
public struct ExtensionChange: Sendable, Equatable {
  public enum Kind: Sendable, Equatable {
    case installed, updated, enabled, disabled, removed, pinned
    /// A change this kit does not know (a newer engine).
    case other(String)
    init(_ name: String) {
      switch name {
      case "installed": self = .installed
      case "updated": self = .updated
      case "enabled": self = .enabled
      case "disabled": self = .disabled
      case "removed": self = .removed
      case "pinned": self = .pinned
      default: self = .other(name)
      }
    }
  }
  public let ato: String
  public let id: String
  public let kind: Kind
}

/// `extension.action`: an action's badge, title, icon or visibility changed. Ask for the icon
/// again (`extensionIcon(_:ato:tab:)`) when you draw it.
public struct ExtensionActionUpdate: Sendable, Equatable {
  public let ato: String
  /// nil: the default, on every tab of the ato.
  public let tab: String?
  public let id: String
  public let state: ExtensionActionState
}

/// `extension.popup`: an extension's popup (a view id from the tabs' numbering) and the size its
/// page wants, again on every change. Show it with `BrowserTabView(engine:tab: popup)` at that size.
public struct ExtensionPopup: Sendable, Equatable {
  public let popup: String
  /// The tab it was opened on.
  public let tab: String
  public let id: String
  /// Points, between 25 x 25 and 800 x 600.
  public let size: CGSize

  init?(message: [String: JSON]) {
    guard let popup = message["popup"]?.string, let id = message["extension"]?.string, let width = message["width"]?.double,
      let height = message["height"]?.double
    else { return nil }
    self.popup = popup
    tab = message["tab"]?.string ?? ""
    self.id = id
    size = CGSize(width: width, height: height)
  }
}

extension BrowserConnection {
  /// The ato's extensions (it wakes the ato if it sleeps). With `tab`, each action as that tab shows it.
  public func extensions(in ato: String, tab: String? = nil) async throws(BrowserError) -> [BrowserExtension] {
    var params: [String: JSON] = ["ato": .string(ato)]
    if let tab { params["tab"] = .string(tab) }
    let reply = try await send(op: "extensions.list", params: params)
    return (reply["extensions"]?.array ?? []).compactMap { $0.object.flatMap(BrowserExtension.init(message:)) }
  }

  /// A PNG (32 px): with `tab`, the action's icon on that tab; else the extension's. nil when it has none.
  public func extensionIcon(_ id: String, ato: String, tab: String? = nil) async throws(BrowserError) -> Data? {
    var params: [String: JSON] = ["ato": .string(ato), "extension": .string(id)]
    if let tab { params["tab"] = .string(tab) }
    let reply = try await send(op: "extension.icon", params: params)
    return reply["png"]?.string.flatMap { $0.isEmpty ? nil : Data(base64Encoded: $0) }
  }

  public func setExtension(_ id: String, ato: String, enabled: Bool) async throws(BrowserError) {
    try await send(op: "extension.enable", params: ["ato": .string(ato), "extension": .string(id), "on": .bool(enabled)])
  }

  /// From this ato, or (`everywhere`) from every ato that has it.
  public func removeExtension(_ id: String, ato: String, everywhere: Bool = false) async throws(BrowserError) {
    var params: [String: JSON] = ["ato": .string(ato), "extension": .string(id)]
    if everywhere { params["all"] = true }
    try await send(op: "extension.remove", params: params)
  }

  public func pinExtension(_ id: String, ato: String, pinned: Bool) async throws(BrowserError) {
    try await send(op: "extension.pin", params: ["ato": .string(ato), "extension": .string(id), "on": .bool(pinned)])
  }

  /// Opens the options page in a new tab of the ato and returns the tab's id.
  public func openExtensionOptions(_ id: String, ato: String) async throws(BrowserError) -> String {
    let reply = try await send(op: "extension.options", params: ["ato": .string(ato), "extension": .string(id)])
    return reply["tab"]?.string ?? ""
  }

  /// "Adicionar de um arquivo": a `.crx` file or an unpacked folder. The engine asks the person
  /// first (`UIRequest.Kind.extension`, with the atos to install into), so this returns only after
  /// they answer and it is in: the extension's id. `denied` when they said no, `failed` when it
  /// would not install, `bad_request` for a path that is not a .crx or an extension folder.
  public func installExtension(ato: String, from url: URL) async throws(BrowserError) -> String {
    let folder = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
    let reply = try await send(op: "extension.install", params: ["ato": .string(ato), folder ? "folder" : "crx": .string(url.path)])
    return reply["extension"]?.string ?? ""  // not "id": a reply's id is the request's
  }

  /// The extension's action on that tab, as a click on its button: the popup's id when it opens
  /// one (its size comes in `BrowserEngine.onExtensionPopup`), nil when the extension handled the
  /// click itself. `denied` on a tab an agent uses while `agentExtensions` is off.
  public func clickExtension(_ id: String, tab: String) async throws(BrowserError) -> String? {
    let reply = try await send(op: "extension.click", params: ["tab": .string(tab), "extension": .string(id)])
    return reply["popup"]?.string
  }

  /// Closes a popup (the person clicked elsewhere, or pressed Escape outside it).
  public func closeExtensionPopup(_ popup: String) async throws(BrowserError) {
    try await send(op: "extension.popup.close", params: ["popup": .string(popup)])
  }
}

import Foundation

/// Something the engine asks the host to draw (`ui.ask`): a `<select>` menu, the right-click menu,
/// a page dialog, a file panel, an HTTP login, a site permission or an extension install. The host
/// answers with a `UIAnswer` (`BrowserEngine.onUIRequest`), or lets the kit draw it
/// (`BrowserEngine.presentDefaultUI`).
public struct UIRequest: Sendable, Equatable {
  /// The engine's id for this request (`"u4"`), echoed back in the answer.
  public let ask: String
  /// The tab (`v…`) that caused it; nil for `extension`, which belongs to no tab.
  public let tab: String?
  public let kind: Kind

  public enum Kind: Sendable, Equatable {
    case select(SelectMenu)
    case contextMenu(ContextMenu)
    case dialog(PageDialog)
    case file(FileChooser)
    case auth(HTTPAuth)
    case permission(PermissionRequest)
    case `extension`(ExtensionInstall)
  }

  /// Nil when the message lacks what its kind needs (or the kind is unknown).
  init?(message: [String: JSON]) {
    guard let ask = message["ask"]?.string else { return nil }
    let tab = message["tab"]?.string
    func string(_ key: String) -> String { message[key]?.string ?? "" }
    func number(_ key: String) -> Double { message[key]?.double ?? 0 }
    func strings(_ key: String) -> [String] { (message[key]?.array ?? []).compactMap(\.string) }
    let kind: Kind
    switch message["kind"]?.string {
    case "select":
      guard let items = message["items"]?.array else { return nil }
      kind = .select(SelectMenu(
        x: number("x"), y: number("y"), width: number("width"),
        items: items.map {
          SelectMenu.Item(
            label: $0.object?["label"]?.string ?? "", disabled: $0.object?["disabled"]?.bool ?? false,
            group: $0.object?["group"]?.bool ?? false)
        },
        selected: message["selected"]?.int ?? -1))
    case "context_menu":
      let context = message["context"]?.object ?? [:]
      guard let actions = context["actions"]?.array else { return nil }  // the list comes inside `context`
      kind = .contextMenu(ContextMenu(
        x: number("x"), y: number("y"), link: context["link"]?.string, image: context["image"]?.string,
        selection: context["selection"]?.string, editable: context["editable"]?.bool ?? false, actions: actions.compactMap(\.string)))
    case "dialog":
      guard let type = message["type"]?.string.flatMap(PageDialog.DialogType.init(rawValue:)) else { return nil }
      kind = .dialog(PageDialog(type: type, message: string("message"), origin: string("origin"), defaultText: message["default"]?.string))
    case "file":
      guard let mode = message["mode"]?.string.flatMap(FileChooser.Mode.init(rawValue:)) else { return nil }
      kind = .file(FileChooser(mode: mode, accept: strings("accept"), suggested: message["suggested"]?.string))
    case "auth":
      guard let origin = message["origin"]?.string else { return nil }
      kind = .auth(HTTPAuth(
        origin: origin, realm: string("realm"), proxy: message["proxy"]?.bool ?? false, retry: message["retry"]?.bool ?? false))
    case "permission":
      // Camera and microphone asked together come as `permissions` and no `permission`.
      let permissions = message["permission"]?.string.map { [$0] } ?? strings("permissions")
      guard let origin = message["origin"]?.string, !permissions.isEmpty else { return nil }
      kind = .permission(PermissionRequest(origin: origin, permissions: permissions))
    case "extension":
      guard let name = message["name"]?.string else { return nil }
      kind = .extension(ExtensionInstall(
        name: name, version: string("version"), permissions: strings("permissions"),
        hostPermissions: strings("host_permissions"), from: string("from"), ato: message["ato"]?.string,
        id: message["id"]?.string, icon: message["icon"]?.string.flatMap { Data(base64Encoded: $0) },
        atos: (message["atos"]?.array ?? []).compactMap { item in
          guard let item = item.object, let id = item["id"]?.string else { return nil }
          return ExtensionInstall.Ato(
            id: id, name: item["name"]?.string ?? id, color: item["color"]?.string, installed: item["installed"]?.bool ?? false)
        }))
    default:
      return nil
    }
    if case .extension = kind {} else if tab == nil { return nil }
    self.ask = ask
    self.tab = tab
    self.kind = kind
  }
}

/// A `<select>`'s list (`kind: "select"`).
public struct SelectMenu: Sendable, Equatable {
  public struct Item: Sendable, Equatable {
    public let label: String
    public let disabled: Bool
    /// An `<optgroup>` header: shown, never chosen.
    public let group: Bool
  }
  /// The control's top left, in points from the view's top left, and its width.
  public let x: Double
  public let y: Double
  public let width: Double
  public let items: [Item]
  /// The current index in `items`, or -1.
  public let selected: Int
}

/// The right-click menu (`kind: "context_menu"`).
public struct ContextMenu: Sendable, Equatable {
  /// The click, in points from the view's top left.
  public let x: Double
  public let y: Double
  public let link: String?
  public let image: String?
  /// Up to 200 characters.
  public let selection: String?
  public let editable: Bool
  /// What may be offered now, in the engine's order (`"copy_link"`, `"paste"`…). Draw fewer if you
  /// like, never one outside the list.
  public let actions: [String]
}

/// `alert`, `confirm`, `prompt` or `beforeunload` of a tab with no agent (`kind: "dialog"`).
public struct PageDialog: Sendable, Equatable {
  public enum DialogType: String, Sendable {
    case alert, confirm, prompt, beforeunload
  }
  public let type: DialogType
  public let message: String
  /// Whose dialog it is: show it.
  public let origin: String
  /// The prompt's initial text.
  public let defaultText: String?
}

/// A file or folder to choose (`kind: "file"`).
public struct FileChooser: Sendable, Equatable {
  public enum Mode: String, Sendable {
    case open
    case openMultiple = "open_multiple"
    case folder, save
  }
  public let mode: Mode
  /// Extensions and MIME types the page asked for (`[".png", "image/*"]`): a hint.
  public let accept: [String]
  /// The suggested name, only in `save`.
  public let suggested: String?
}

/// An HTTP login (`kind: "auth"`).
public struct HTTPAuth: Sendable, Equatable {
  /// Scheme, host and port of who asks.
  public let origin: String
  public let realm: String
  /// Who asks is a proxy.
  public let proxy: Bool
  /// The previous credentials were refused.
  public let retry: Bool
}

/// A site asking for a permission (`kind: "permission"`).
public struct PermissionRequest: Sendable, Equatable {
  public let origin: String
  /// `camera`, `microphone`, `geolocation` or `notifications`; camera and microphone asked
  /// together come as one request with both.
  public let permissions: [String]
}

/// An extension to install (`kind: "extension"`).
public struct ExtensionInstall: Sendable, Equatable {
  /// An ato it may go into as well (the prompt's "Onde instalar").
  public struct Ato: Sendable, Equatable {
    public let id: String
    public let name: String
    public let color: String?
    /// It has the extension already.
    public let installed: Bool
  }
  public let name: String
  public let version: String
  /// Ready to show.
  public let permissions: [String]
  /// Address patterns.
  public let hostPermissions: [String]
  /// The origin that asked, or `"store"` / `"file"` (a .crx) / `"folder"` (unpacked).
  public let from: String
  /// The ato it installs into first (nil from an older engine).
  public var ato: String? = nil
  /// The extension's id.
  public var id: String? = nil
  /// A small PNG of its icon.
  public var icon: Data? = nil
  /// Every ato, for the choice "only this ato" (the default) or "all", with a box per ato; empty
  /// when there is no choice (an older engine, or a prompt that is not a new install). Answer
  /// with `.extension(allow: true, atos:)`.
  public var atos: [Ato] = []
}

/// The answer to a `UIRequest`, one case per kind, or `cancel` for any of them (no choice, dialog
/// refused, no file, no credentials, permission denied without remembering, not installed). Its
/// description never shows the password.
public enum UIAnswer: Sendable, Equatable {
  /// An index in `SelectMenu.items`.
  case select(index: Int)
  /// One of `ContextMenu.actions`.
  case contextMenu(action: String)
  /// `text` only for an accepted `prompt`.
  case dialog(accept: Bool, text: String? = nil)
  /// Absolute paths; empty is the same as cancelling.
  case file(paths: [String])
  case auth(username: String, password: String)
  case permission(allow: Bool, remember: Bool = false)
  /// `atos`: the ids of `ExtensionInstall.atos` it goes into as well (nil or empty: only the
  /// asking ato); only with `allow`.
  case `extension`(allow: Bool, atos: [String]? = nil)
  case cancel

  /// The fields of `ui.answer`, besides `ask`.
  var params: [String: JSON] {
    switch self {
    case .select(let index): ["index": .number(Double(index))]
    case .contextMenu(let action): ["action": .string(action)]
    case .dialog(let accept, let text): text.map { ["accept": .bool(accept), "text": .string($0)] } ?? ["accept": .bool(accept)]
    case .file(let paths): ["paths": .array(paths.map(JSON.string))]
    case .auth(let username, let password): ["username": .string(username), "password": .string(password)]
    case .permission(let allow, let remember): remember ? ["allow": .bool(allow), "remember": true] : ["allow": .bool(allow)]
    case .extension(let allow, let atos):
      if allow, let atos, !atos.isEmpty { ["allow": true, "atos": .array(atos.map(JSON.string))] } else { ["allow": .bool(allow)] }
    case .cancel: ["cancel": true]
    }
  }
}

extension UIAnswer: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
  public var description: String {
    var shown = params
    if shown["password"] != nil { shown["password"] = "<hidden>" }
    return "UIAnswer " + String(decoding: JSON.line(shown).dropLast(), as: UTF8.self)
  }
  public var debugDescription: String { description }
  public var customMirror: Mirror { Mirror(self, children: ["answer": description]) }
}

extension BrowserConnection {
  /// Answers a `ui.ask`; `.cancel` cancels it. An `ask` that is gone throws `not_found`.
  public func answerUI(_ ask: String, _ answer: UIAnswer) async throws(BrowserError) {
    try await send(op: "ui.answer", params: answer.params.merging(["ask": .string(ask)]) { $1 })
  }
}

import Foundation

/// Something the engine asks the host to draw (`ui.ask`): a `<select>` menu, the right-click menu,
/// a page dialog, a file panel, an HTTP login, a site permission, an extension install, a date or
/// color picker, a print or a passkey. The host
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
    case date(DatePicker)
    case color(ColorPicker)
    case print(PrintRequest)
    case webauthn(PasskeyRequest)
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
        selection: context["selection"]?.string, editable: context["editable"]?.bool ?? false, actions: actions.compactMap(\.string),
        items: ContextMenuItem.list(context["items"])))
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
      kind = .permission(PermissionRequest(
        origin: origin, permissions: permissions, scheme: message["scheme"]?.string, handlerURL: message["handler_url"]?.string))
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
    case "date":
      guard let type = message["type"]?.string.flatMap(DatePicker.FieldType.init(rawValue:)),
        let min = message["min"]?.double, let max = message["max"]?.double, let step = message["step"]?.double
      else { return nil }
      kind = .date(DatePicker(
        type: type, value: message["value"]?.double, min: min, max: max, step: step,
        suggestions: (message["suggestions"]?.array ?? []).compactMap { item in
          item.object?["value"]?.double.map { DatePicker.Suggestion(value: $0, label: item.object?["label"]?.string ?? "") }
        },
        anchor: Self.anchor(message)))
    case "color":
      guard let value = message["value"]?.string else { return nil }
      kind = .color(ColorPicker(
        value: value,
        suggestions: (message["suggestions"]?.array ?? []).compactMap { item in
          item.object?["value"]?.string.map { ColorPicker.Suggestion(value: $0, label: item.object?["label"]?.string ?? "") }
        },
        anchor: Self.anchor(message)))
    case "print":
      kind = .print(PrintRequest(title: string("title"), url: string("url")))
    case "webauthn":
      guard let type = message["type"]?.string.flatMap(PasskeyRequest.RequestType.init(rawValue:)),
        let origin = message["origin"]?.string, let request = message["request"]?.object
      else { return nil }
      kind = .webauthn(PasskeyRequest(type: type, origin: origin, crossOrigin: message["cross_origin"]?.bool ?? false, request: request))
    default:
      return nil
    }
    if case .extension = kind {} else if tab == nil { return nil }
    self.ask = ask
    self.tab = tab
    self.kind = kind
  }

  /// The field a picker belongs to, in points from the view's top left; nil when the engine does
  /// not know where it is.
  static func anchor(_ message: [String: JSON]) -> CGRect? {
    guard let x = message["x"]?.double, let y = message["y"]?.double else { return nil }
    return CGRect(x: x, y: y, width: message["width"]?.double ?? 0, height: message["height"]?.double ?? 0)
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
  /// A DevTools view's own entries (its menu, as DevTools builds it), drawn before `actions`;
  /// empty for a page. Answer with `.contextMenuItem(id:)`.
  public var items: [ContextMenuItem] = []
}

/// An entry of a DevTools view's menu: one to choose (with `id`), a separator, a group header or a
/// submenu (`items`).
public struct ContextMenuItem: Sendable, Equatable {
  /// What to answer; nil for a separator, a header or a submenu.
  public let id: Int?
  public let label: String
  public let disabled: Bool
  /// A check mark's state, for an entry that has one.
  public let checked: Bool?
  public let separator: Bool
  public let group: Bool
  public let items: [ContextMenuItem]

  static func list(_ json: JSON?) -> [ContextMenuItem] {
    (json?.array ?? []).compactMap { value in
      guard let item = value.object else { return nil }
      return ContextMenuItem(
        id: item["id"]?.int, label: item["label"]?.string ?? "", disabled: item["disabled"]?.bool ?? false,
        checked: item["checked"]?.bool, separator: item["separator"]?.bool ?? false, group: item["group"]?.bool ?? false,
        items: list(item["items"]))
    }
  }
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
  /// `camera`, `microphone`, `geolocation`, `notifications` or `protocol_handler`; camera and
  /// microphone asked together come as one request with both.
  public let permissions: [String]
  /// `protocol_handler` (`navigator.registerProtocolHandler`): the scheme the site wants to open
  /// (`web+app`, `mailto`…) and its address for it, with `%s` where the link goes.
  public var scheme: String? = nil
  public var handlerURL: String? = nil
}

/// An `<input>`'s date, time, month or week picker (`kind: "date"`). Every number is in the
/// field's own unit (its `valueAsNumber`): milliseconds since 1970-01-01 UTC for `date`,
/// `datetimeLocal` and `week` (the week's Monday), milliseconds since midnight for `time`, months
/// since January 1970 for `month`. Answer with `.date(value:)`, between `min` and `max`, a whole
/// number of `step`s from `min`.
public struct DatePicker: Sendable, Equatable {
  public enum FieldType: String, Sendable {
    case date
    case datetimeLocal = "datetime-local"
    case month, time, week
  }
  /// One of the field's `<datalist>` options.
  public struct Suggestion: Sendable, Equatable {
    public let value: Double
    public let label: String
  }
  public let type: FieldType
  /// The field's value; nil while it is empty.
  public let value: Double?
  public let min: Double
  public let max: Double
  public let step: Double
  public let suggestions: [Suggestion]
  /// The field, in points from the view's top left (draw the picker next to it); nil if unknown.
  public let anchor: CGRect?

  /// `value` as a date (for `date`, `datetimeLocal`, `week` and `time`, which counts from
  /// 1970-01-01), in UTC.
  public static func date(_ value: Double) -> Date { Date(timeIntervalSince1970: value / 1000) }
  public static func value(_ date: Date) -> Double { (date.timeIntervalSince1970 * 1000).rounded() }
}

/// An `<input type=color>` (`kind: "color"`): `value` and the answer are `"#rrggbb"`.
public struct ColorPicker: Sendable, Equatable {
  public struct Suggestion: Sendable, Equatable {
    public let value: String
    public let label: String
  }
  public let value: String
  public let suggestions: [Suggestion]
  public let anchor: CGRect?
}

/// The page wants to print (`window.print()`, `kind: "print"`). The page goes on at once: print
/// with `BrowserConnection.printPDF(tab:)`, then answer `.cancel` (the only answer) when done.
public struct PrintRequest: Sendable, Equatable {
  public let title: String
  public let url: String
}

/// A passkey request (`navigator.credentials.create` or `get`, `kind: "webauthn"`). Answer with
/// `.webauthn(response:)`, the `PublicKeyCredential` as JSON (`RegistrationResponseJSON` for
/// create, `AuthenticationResponseJSON` for get), or `.webauthnError(_:)`; `.cancel` is
/// `NotAllowedError`.
public struct PasskeyRequest: Sendable, Equatable {
  public enum RequestType: String, Sendable {
    case create, get
  }
  public let type: RequestType
  /// Who asks (the frame's origin), and whether it is an iframe of another origin.
  public let origin: String
  public let crossOrigin: Bool
  /// The options as WebAuthn JSON (`PublicKeyCredentialCreationOptionsJSON` or
  /// `PublicKeyCredentialRequestOptionsJSON`: base64url for the bytes).
  public let request: [String: JSON]
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
  /// The menu's `inspect`, with where DevTools goes.
  case inspect(dock: DevToolsDock)
  /// The `id` of one of `ContextMenu.items` (a DevTools view's menu).
  case contextMenuItem(id: Int)
  /// `text` only for an accepted `prompt`.
  case dialog(accept: Bool, text: String? = nil)
  /// Absolute paths; empty is the same as cancelling.
  case file(paths: [String])
  case auth(username: String, password: String)
  case permission(allow: Bool, remember: Bool = false)
  /// `atos`: the ids of `ExtensionInstall.atos` it goes into as well (nil or empty: only the
  /// asking ato); only with `allow`.
  case `extension`(allow: Bool, atos: [String]? = nil)
  /// A `DatePicker` value, in its unit.
  case date(value: Double)
  /// `"#rrggbb"`.
  case color(hex: String)
  /// The `PublicKeyCredential` as WebAuthn JSON.
  case webauthn(response: [String: JSON])
  /// The `DOMException` the page gets: `NotAllowedError`, `InvalidStateError`,
  /// `NotSupportedError`, `SecurityError`, `AbortError`, `ConstraintError` or `UnknownError`.
  case webauthnError(String)
  case cancel

  /// The fields of `ui.answer`, besides `ask`.
  var params: [String: JSON] {
    switch self {
    case .select(let index): ["index": .number(Double(index))]
    case .contextMenu(let action): ["action": .string(action)]
    case .inspect(let dock): ["action": "inspect", "dock": .string(dock.rawValue)]
    case .contextMenuItem(let id): ["item": .number(Double(id))]
    case .dialog(let accept, let text): text.map { ["accept": .bool(accept), "text": .string($0)] } ?? ["accept": .bool(accept)]
    case .file(let paths): ["paths": .array(paths.map(JSON.string))]
    case .auth(let username, let password): ["username": .string(username), "password": .string(password)]
    case .permission(let allow, let remember): remember ? ["allow": .bool(allow), "remember": true] : ["allow": .bool(allow)]
    case .extension(let allow, let atos):
      if allow, let atos, !atos.isEmpty { ["allow": true, "atos": .array(atos.map(JSON.string))] } else { ["allow": .bool(allow)] }
    case .date(let value): ["value": .number(value)]
    case .color(let hex): ["value": .string(hex)]
    case .webauthn(let response): ["response": .object(response)]
    case .webauthnError(let name): ["error": .string(name)]
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

  /// The tab's page as a PDF (`view.print_pdf`), in a file of the engine's (mode 0600) that lives
  /// until the next call for the tab, the tab closing or the host going: read or copy it right
  /// away. Wrong options throw `bad_request`; a tab an agent works, `denied`.
  public func printPDF(tab: String, options: PrintOptions = PrintOptions()) async throws(BrowserError) -> PrintedPDF {
    let reply = try await send(op: "view.print_pdf", params: options.params.merging(["tab": .string(tab)]) { $1 })
    guard let path = reply["path"]?.string else { throw BrowserError(code: "failed", message: "no path in the reply") }
    return PrintedPDF(url: URL(fileURLWithPath: path), bytes: reply["bytes"]?.int ?? 0, pages: reply["pages"]?.int ?? 0)
  }
}

/// How `printPDF` lays the page out; nil leaves the engine's default. Sizes in inches.
public struct PrintOptions: Sendable, Equatable {
  public var landscape: Bool?
  /// Print background colors and images.
  public var background: Bool?
  public var scale: Double?
  public var paperWidth: Double?
  public var paperHeight: Double?
  public var margins: (top: Double, bottom: Double, left: Double, right: Double)?
  /// `"1-3, 5"`; nil or empty: every page.
  public var pageRanges: String?
  /// Chromium's header and footer (date, title, address, page number).
  public var headerFooter: Bool?
  /// The page's own `@page size` wins over `paperWidth`/`paperHeight` (the engine's default: true).
  public var cssPageSize: Bool?

  public init(landscape: Bool? = nil, background: Bool? = nil, scale: Double? = nil, pageRanges: String? = nil) {
    self.landscape = landscape
    self.background = background
    self.scale = scale
    self.pageRanges = pageRanges
  }

  public static func == (a: PrintOptions, b: PrintOptions) -> Bool { a.params == b.params }

  var params: [String: JSON] {
    var params: [String: JSON] = [:]
    if let landscape { params["landscape"] = .bool(landscape) }
    if let background { params["background"] = .bool(background) }
    if let scale { params["scale"] = .number(scale) }
    if let paperWidth { params["paper_width"] = .number(paperWidth) }
    if let paperHeight { params["paper_height"] = .number(paperHeight) }
    if let margins {
      params["margins"] = ["top": .number(margins.top), "bottom": .number(margins.bottom), "left": .number(margins.left), "right": .number(margins.right)]
    }
    if let pageRanges { params["page_ranges"] = .string(pageRanges) }
    if let headerFooter { params["header_footer"] = .bool(headerFooter) }
    if let cssPageSize { params["css_page_size"] = .bool(cssPageSize) }
    return params
  }
}

/// What `printPDF` made: the file, its size and its page count.
public struct PrintedPDF: Sendable, Equatable {
  public let url: URL
  public let bytes: Int
  public let pages: Int
}

/// A link the page opens in another app (`view.external`): `mailto:`, `webcal:`, `zoommtg:`…
/// The engine launches nothing itself; the host decides (its own mail or calendar, or the system).
public struct ExternalLink: Sendable, Equatable {
  public let tab: String
  public let url: URL
  public let scheme: String
  /// Who started it (the page's origin), when the engine knows.
  public let origin: String?
  /// It came from a click or a key (not from a script on its own).
  public let gesture: Bool

  init?(message: [String: JSON]) {
    guard let tab = message["tab"]?.string, let text = message["url"]?.string, let url = URL(string: text),
      let scheme = message["scheme"]?.string
    else { return nil }
    self.tab = tab
    self.url = url
    self.scheme = scheme
    origin = message["origin"]?.string
    gesture = message["gesture"]?.bool ?? false
  }
}

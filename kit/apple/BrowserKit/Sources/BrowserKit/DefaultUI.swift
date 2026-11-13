import AppKit

// The kit's own drawing of `ui.ask`, in plain AppKit with Portuguese text: menus at the page's
// point, sheets on the view's window, the standard file panels. Cancelling the calling task (the
// kit does it on `ui.cancel`) closes what is open.

extension BrowserEngine {
  /// Draws the request and returns what the person chose. Use it as the handler,
  /// `engine.onUIRequest = { [weak engine] in await engine?.presentDefaultUI($0) ?? .cancel }`,
  /// or call it from your own for the kinds you do not draw. Without the tab's view (or a window,
  /// for the sheets) the answer is `cancel`.
  public func presentDefaultUI(_ request: UIRequest) async -> UIAnswer {
    guard !Task.isCancelled else { return .cancel }
    let view = view(request.tab)
    let window = view?.window ?? NSApp.keyWindow ?? NSApp.mainWindow
    switch request.kind {
    case .select(let select):
      guard let view else { return .cancel }
      let menu = NSMenu()
      menu.autoenablesItems = false
      menu.minimumWidth = select.width
      for (index, item) in select.items.enumerated() {
        let entry = item.group ? NSMenuItem.sectionHeader(title: item.label) : NSMenuItem(title: item.label, action: nil, keyEquivalent: "")
        entry.tag = index
        entry.isEnabled = !item.disabled && !item.group
        entry.state = index == select.selected ? .on : .off
        menu.addItem(entry)
      }
      let current = select.items.indices.contains(select.selected) ? menu.item(at: select.selected) : nil
      return await popUp(menu, positioning: current, at: (select.x, select.y), in: view).map { .select(index: $0) } ?? .cancel

    case .contextMenu(let context):
      guard let view else { return .cancel }
      let (menu, choices) = Self.contextMenu(context, hostItems: contextMenuItems)
      guard menu.numberOfItems > 0,
        let tag = await popUp(menu, positioning: nil, at: (context.x, context.y), in: view)
      else { return .cancel }
      switch choices[tag] {
      case .action(let action):
        return .contextMenu(action: action)
      case .item(let id):
        return .contextMenuItem(id: id)
      case .host(let item):
        onContextMenuItem?(item, request)
        return .cancel
      }

    case .dialog(let dialog):
      guard let window else { return .cancel }
      let alert = NSAlert()
      alert.messageText = dialog.type == .beforeunload ? "Sair desta página?" : dialog.origin
      alert.informativeText = dialog.type == .beforeunload ? "As alterações podem não ser salvas." : dialog.message
      alert.addButton(withTitle: dialog.type == .beforeunload ? "Sair" : "OK")
      if dialog.type != .alert { Self.addCancel(alert, "Cancelar") }
      let field = NSTextField(string: dialog.defaultText ?? "")
      if dialog.type == .prompt {
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 22)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
      }
      let accepted = await sheet(alert, on: window) == .alertFirstButtonReturn
      return .dialog(accept: accepted, text: accepted && dialog.type == .prompt ? field.stringValue : nil)

    case .file(let chooser):
      let panel: NSSavePanel
      if chooser.mode == .save {
        panel = NSSavePanel()
        panel.nameFieldStringValue = chooser.suggested ?? ""
      } else {
        let open = NSOpenPanel()
        open.canChooseFiles = chooser.mode != .folder
        open.canChooseDirectories = chooser.mode == .folder
        open.allowsMultipleSelection = chooser.mode == .openMultiple
        panel = open
      }
      // shortcut: `accept` does not filter the panel; the engine checks what comes back anyway.
      let response = await closing({ panel.cancel(nil) }) {
        if let window { await panel.beginSheetModal(for: window) } else { await panel.begin() }
      }
      guard response == .OK else { return .cancel }
      let urls = (panel as? NSOpenPanel)?.urls ?? panel.url.map { [$0] } ?? []
      return .file(paths: urls.map(\.path))

    case .auth(let auth):
      guard let window else { return .cancel }
      let alert = NSAlert()
      alert.messageText = auth.proxy ? "O proxy \(auth.origin) pede login" : "Entrar em \(auth.origin)"
      alert.informativeText = auth.retry ? "Usuário ou senha incorretos. \(auth.realm)" : auth.realm
      alert.addButton(withTitle: "Entrar")
      Self.addCancel(alert, "Cancelar")
      let username = NSTextField()
      username.placeholderString = "Usuário"
      let password = NSSecureTextField()
      password.placeholderString = "Senha"
      let fields = NSStackView(views: [username, password])
      fields.orientation = .vertical
      fields.frame = NSRect(x: 0, y: 0, width: 260, height: 52)
      alert.accessoryView = fields
      alert.window.initialFirstResponder = username
      guard await sheet(alert, on: window) == .alertFirstButtonReturn else { return .cancel }
      return .auth(username: username.stringValue, password: password.stringValue)

    case .permission(let permission):
      guard let window else { return .cancel }
      let alert = NSAlert()
      let wants = permission.permissions.map { Self.permissionTexts[$0] ?? $0 }.joined(separator: " e ")
      alert.messageText = "\(permission.origin) quer \(wants)"
      // The engine has no one-time grant for notifications: allowing is always kept.
      if permission.permissions.contains("notifications") { alert.informativeText = "Notificações: permitir fica valendo para este site, com ou sem Lembrar." }
      alert.addButton(withTitle: "Permitir")
      Self.addCancel(alert, "Não permitir")
      alert.showsSuppressionButton = true
      alert.suppressionButton?.title = "Lembrar"
      let allow = await sheet(alert, on: window) == .alertFirstButtonReturn
      return .permission(allow: allow, remember: alert.suppressionButton?.state == .on)

    case .extension(let install):
      guard let window else { return .cancel }
      let alert = NSAlert()
      alert.messageText = "Instalar \(install.name)?"
      if let icon = install.icon.flatMap(NSImage.init(data:)) { alert.icon = icon }
      alert.informativeText = "\(install.version) · \(Self.installSource(install.from))"
      var lines: [String] = []
      if !install.permissions.isEmpty { lines.append("O que ela pode fazer:\n" + install.permissions.map { "• \($0)" }.joined(separator: "\n")) }
      if !install.hostPermissions.isEmpty { lines.append("Em:\n" + install.hostPermissions.map { "• \($0)" }.joined(separator: "\n")) }
      let choice = InstallChoice(install)
      alert.accessoryView = choice.view(details: lines.joined(separator: "\n\n"))
      choice.button = alert.addButton(withTitle: "")
      choice.update()
      Self.addCancel(alert, "Cancelar")
      guard await sheet(alert, on: window) == .alertFirstButtonReturn else { return .extension(allow: false) }
      return .extension(allow: true, atos: choice.chosen)
    }
  }

  /// What an item of the right-click menu stands for; an item's tag is its index here.
  enum ContextChoice: Equatable {
    case action(String)
    case item(Int)
    case host(HostMenuItem)
  }

  /// The right-click menu: the engine's actions this kit has a title for, then the host's items
  /// past a separator, then "Inspecionar" past another, last, when the engine offers it.
  static func contextMenu(_ context: ContextMenu, hostItems: [HostMenuItem]) -> (NSMenu, [ContextChoice]) {
    let menu = NSMenu()
    var choices: [ContextChoice] = []
    func add(_ title: String, _ choice: ContextChoice) {
      menu.addItem(withTitle: title, action: nil, keyEquivalent: "").tag = choices.count
      choices.append(choice)
    }
    // A DevTools view's own entries first, as DevTools lays them out (submenus included).
    func addItems(_ items: [ContextMenuItem], to menu: NSMenu) {
      for item in items {
        if item.separator {
          menu.addItem(.separator())
        } else if item.group {
          menu.addItem(.sectionHeader(title: item.label))
        } else if !item.items.isEmpty {
          let entry = NSMenuItem(title: item.label, action: nil, keyEquivalent: "")
          let submenu = NSMenu(title: item.label)
          submenu.autoenablesItems = false
          addItems(item.items, to: submenu)
          entry.submenu = submenu
          menu.addItem(entry)
        } else if let id = item.id {
          let entry = menu.addItem(withTitle: item.label, action: nil, keyEquivalent: "")
          entry.tag = choices.count
          entry.isEnabled = !item.disabled
          entry.state = item.checked == true ? .on : .off
          choices.append(.item(id))
        }
      }
    }
    if !context.items.isEmpty {
      menu.autoenablesItems = false
      addItems(context.items, to: menu)
      if !context.actions.isEmpty { menu.addItem(.separator()) }
    }
    for action in context.actions where action != "inspect" {
      guard let title = contextTitles[action] else { continue }  // the host may draw fewer
      add(title, .action(action))
    }
    if menu.numberOfItems > 0 && !hostItems.isEmpty { menu.addItem(.separator()) }
    for item in hostItems { add(item.title, .host(item)) }
    if context.actions.contains("inspect") {
      if menu.numberOfItems > 0 { menu.addItem(.separator()) }
      add("Inspecionar", .action("inspect"))
    }
    return (menu, choices)
  }

  private static let contextTitles = [
    "open_link_new_tab": "Abrir link em nova aba", "copy_link": "Copiar link", "copy_image": "Copiar imagem",
    "save_image": "Salvar imagem como…", "copy": "Copiar", "cut": "Recortar", "paste": "Colar",
    "select_all": "Selecionar tudo", "back": "Voltar", "forward": "Avançar", "reload": "Recarregar",
  ]

  private static let permissionTexts = [
    "camera": "usar a câmera", "microphone": "usar o microfone", "geolocation": "saber a sua localização",
    "notifications": "mostrar notificações",
  ]

  static func installSource(_ from: String) -> String {
    switch from {
    case "store": "da Chrome Web Store"
    case "file": "de um arquivo .crx; não se atualiza sozinha"
    case "folder": "de uma pasta; fica ligada a ela e não se atualiza sozinha"
    default: "pedida por \(from)"
    }
  }

  /// Shows a popup (`onExtensionPopup`) under `anchor`, its button, in a transient popover with
  /// the popup's `BrowserTabView`: it follows the size the page wants, and a click elsewhere or
  /// Escape closes it (the kit tells the engine). Does nothing for a popup it shows already.
  public func presentExtensionPopup(_ popup: ExtensionPopup, from anchor: NSView) {
    guard popups[popup.popup] == nil, anchor.window != nil else { return }
    popups[popup.popup] = ExtensionPopupPresenter(engine: self, popup: popup, anchor: anchor)
  }

  /// A second button that Escape presses.
  private static func addCancel(_ alert: NSAlert, _ title: String) {
    alert.addButton(withTitle: title).keyEquivalent = "\u{1b}"
  }

  /// Runs `body`; if the task is cancelled meanwhile, `close` runs on the main actor.
  private func closing<T>(_ close: @escaping @MainActor @Sendable () -> Void, _ body: () async -> T) async -> T {
    await withTaskCancellationHandler(operation: body, onCancel: { Task { @MainActor in close() } })
  }

  private func sheet(_ alert: NSAlert, on window: NSWindow) async -> NSApplication.ModalResponse {
    await closing({ window.endSheet(alert.window, returnCode: .cancel) }) { await alert.beginSheetModal(for: window) }
  }

  /// Pops the menu up at a point given from the view's top left; returns the chosen item's tag.
  private func popUp(_ menu: NSMenu, positioning: NSMenuItem?, at point: (x: Double, y: Double), in view: BrowserTabView) async -> Int? {
    let picker = MenuPicker()
    func wire(_ menu: NSMenu) {
      for item in menu.items where !item.isSeparatorItem {
        if let submenu = item.submenu {
          wire(submenu)
        } else {
          item.target = picker
          item.action = #selector(MenuPicker.pick(_:))
        }
      }
    }
    wire(menu)
    await closing({ menu.cancelTracking() }) {
      // Tracking runs a nested loop here: the cancel above still gets through it.
      _ = menu.popUp(positioning: positioning, at: NSPoint(x: point.x, y: view.bounds.height - point.y), in: view)
    }
    return picker.picked
  }
}

private final class MenuPicker: NSObject {
  var picked: Int?
  @objc func pick(_ item: NSMenuItem) { picked = item.tag }
}

/// The install sheet's "Onde instalar" (prototipos/extensoes.html #instalar): only the asking ato
/// (the default) or all, with a box per ato (the asking one and those that have it stay checked);
/// the button says where it goes.
@MainActor final class InstallChoice: NSObject {
  let install: ExtensionInstall
  var button: NSButton?
  private let only = NSButton(radioButtonWithTitle: "", target: nil, action: nil)
  private let all = NSButton(radioButtonWithTitle: "Em todos os atos — cada ato continua com os próprios logins", target: nil, action: nil)
  private var boxes: [(id: String, box: NSButton, locked: Bool)] = []

  init(_ install: ExtensionInstall) {
    self.install = install
    super.init()
  }

  private var askingName: String { install.atos.first { $0.id == install.ato }?.name ?? "" }
  private var offersChoice: Bool { install.atos.count > 1 && install.ato != nil }

  func view(details: String) -> NSView {
    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = .leading
    let text = NSTextField(wrappingLabelWithString: details.isEmpty ? "Nada além da própria página." : details)
    text.preferredMaxLayoutWidth = 300
    stack.addArrangedSubview(text)
    if offersChoice {
      stack.addArrangedSubview(NSTextField(labelWithString: "Onde instalar"))
      only.title = "Só no ato \(askingName) — os outros atos não veem"
      only.state = .on
      for radio in [only, all] {
        radio.target = self
        radio.action = #selector(changed)
        stack.addArrangedSubview(radio)
      }
      for ato in install.atos {
        let mine = ato.id == install.ato
        let title = ato.name + (mine ? "  (este ato)" : ato.installed ? "  (já tem)" : "")
        let box = NSButton(checkboxWithTitle: title, target: self, action: #selector(changed))
        box.state = .on
        boxes.append((ato.id, box, mine || ato.installed))
        let row = NSStackView(views: [box])  // indented under "Em todos os atos"
        row.edgeInsets = NSEdgeInsets(top: 0, left: 22, bottom: 0, right: 0)
        stack.addArrangedSubview(row)
      }
    }
    stack.frame = NSRect(x: 0, y: 0, width: 320, height: stack.fittingSize.height)
    return stack
  }

  @objc func changed() { update() }

  func update() {
    let everywhere = all.state == .on
    for entry in boxes { entry.box.isEnabled = everywhere && !entry.locked }
    let count = boxes.filter { $0.box.state == .on }.count
    button?.title = offersChoice && everywhere && count > 1 ? "Instalar em \(count) atos"
      : askingName.isEmpty ? "Instalar" : "Instalar no ato \(askingName)"
  }

  /// The checked atos (the engine skips the asking one and those that have it), or nil for only
  /// the asking one.
  var chosen: [String]? {
    guard offersChoice, all.state == .on else { return nil }
    return boxes.filter { $0.box.state == .on }.map(\.id)
  }

  /// For the tests: the person picks "Em todos os atos" and unchecks these.
  func pickAll(leaving out: Set<String> = []) {
    all.state = .on
    only.state = .off
    update()
    for entry in boxes where out.contains(entry.id) && entry.box.isEnabled { entry.box.state = .off }
    update()
  }
}

/// One popup `presentExtensionPopup` shows: a transient popover around its view.
@MainActor final class ExtensionPopupPresenter: NSObject, NSPopoverDelegate {
  private weak var engine: BrowserEngine?
  private let id: String
  private let popover = NSPopover()
  private var closing = false

  init(engine: BrowserEngine, popup: ExtensionPopup, anchor: NSView) {
    self.engine = engine
    id = popup.popup
    super.init()
    let view = BrowserTabView(engine: engine, tab: popup.popup)
    view.frame = NSRect(origin: .zero, size: popup.size)
    let controller = NSViewController()
    controller.view = view
    popover.contentViewController = controller
    popover.contentSize = popup.size
    popover.behavior = .transient  // a click elsewhere closes it: the focus loss the engine waits for
    popover.delegate = self
    // Below the button (its bottom edge; a flipped view's bottom is maxY).
    popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: anchor.isFlipped ? .maxY : .minY)
    view.window?.makeFirstResponder(view)
  }

  func resize(to size: CGSize) { popover.contentSize = size }

  /// The engine closed it first: no op goes back.
  func closed() {
    closing = true
    popover.close()
  }

  func popoverDidClose(_ notification: Notification) {
    guard !closing else { return }
    closing = true
    engine?.popups[id] = nil
    engine?.connection?.request(op: "extension.popup.close", params: ["popup": .string(id)])
  }
}

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
      let menu = NSMenu()
      for (index, action) in context.actions.enumerated() {
        guard let title = Self.contextTitles[action] else { continue }  // the host may draw fewer
        menu.addItem(withTitle: title, action: nil, keyEquivalent: "").tag = index
      }
      guard menu.numberOfItems > 0 else { return .cancel }
      return await popUp(menu, positioning: nil, at: (context.x, context.y), in: view).map { .contextMenu(action: context.actions[$0]) } ?? .cancel

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
      alert.messageText = "Adicionar \(install.name) \(install.version)?"
      var lines = ["Pedido por: \(install.from == "store" ? "loja" : install.from == "file" ? "arquivo" : install.from)"]
      if !install.permissions.isEmpty { lines.append("Pode:\n" + install.permissions.map { "• \($0)" }.joined(separator: "\n")) }
      if !install.hostPermissions.isEmpty { lines.append("Em:\n" + install.hostPermissions.map { "• \($0)" }.joined(separator: "\n")) }
      alert.informativeText = lines.joined(separator: "\n\n")
      alert.addButton(withTitle: "Permitir")
      Self.addCancel(alert, "Não permitir")
      return .extension(allow: await sheet(alert, on: window) == .alertFirstButtonReturn)
    }
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
    for item in menu.items {
      item.target = picker
      item.action = #selector(MenuPicker.pick(_:))
    }
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

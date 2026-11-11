import AppKit
import Foundation
import Observation

/// A request from the engine for the person's approval (`approval.ask`). The host draws it:
/// `title` and `detail` always come; the parts below come when the engine knows them (an older
/// engine sends none), for a host that lays the sheet out itself.
public struct ApprovalRequest: Sendable, Equatable {
  /// What is being asked.
  public enum Kind: Sendable, Equatable {
    /// An app wants to connect (`hello` from a signed client).
    case connect
    /// `control.start`: an agent wants to use tabs of an ato.
    case control
    /// `session`: an app wants cookies, localStorage or headers of an ato.
    case session
    /// A kind this kit does not know (a newer engine): show `title` and `detail`.
    case other(String)

    init(_ name: String) {
      switch name {
      case "connect": self = .connect
      case "control": self = .control
      case "session": self = .session
      default: self = .other(name)
      }
    }
  }

  /// One thing `session` asks for.
  public struct Item: Sendable, Equatable {
    /// `cookie`, `localStorage` or `header`.
    public let type: String
    /// The origin, as the app sent it.
    public let from: String
    public let name: String
  }

  /// The engine's id for this request, echoed back in the answer.
  public let ask: JSON
  public let title: String
  public let detail: String
  /// Whether "always" may be offered.
  public let offerAlways: Bool
  public var kind: Kind? = nil
  /// The ato's id and name (control, session).
  public var ato: String? = nil
  public var atoName: String? = nil
  /// The name the controlled tabs will show (control).
  public var agent: String? = nil
  /// The app's reason, when it gave one.
  public var reason: String? = nil
  /// Extra permissions asked (control): `passwords`, `clipboard`, `eval`.
  public var allow: [String]? = nil
  /// Names of the atos this one shares cookies with; empty when none.
  public var sharesWith: [String] = []
  /// What `session` asks for.
  public var items: [Item]? = nil

  init(message: [String: JSON]) {
    ask = message["ask"] ?? .null
    title = message["title"]?.string ?? ""
    detail = message["detail"]?.string ?? ""
    offerAlways = message["offer_always"]?.bool ?? false
    kind = message["kind"]?.string.map(Kind.init)
    ato = message["ato"]?.string
    atoName = message["ato_name"]?.string
    agent = message["agent"]?.string
    reason = message["reason"]?.string
    allow = message["allow"]?.array?.compactMap(\.string)
    sharesWith = message["shares_with"]?.array?.compactMap(\.string) ?? []
    items = message["items"]?.array?.compactMap { item in
      guard let item = item.object, let type = item["type"]?.string, let from = item["from"]?.string,
        let name = item["name"]?.string
      else { return nil }
      return Item(type: type, from: from, name: name)
    }
  }

  init(ask: JSON, title: String, detail: String, offerAlways: Bool) {
    self.ask = ask
    self.title = title
    self.detail = detail
    self.offerAlways = offerAlways
  }
}

/// An item the host adds to the right-click menu (`BrowserEngine.contextMenuItems`).
public struct HostMenuItem: Sendable, Equatable, Identifiable {
  public let id: String
  public let title: String
  public init(id: String, title: String) {
    self.id = id
    self.title = title
  }
}

/// The two options the host switches (`host.settings`), as the engine has them now.
public struct HostSettings: Sendable, Equatable {
  /// Sites may ask for location and notifications (the host's `ui.ask`); off, they are blocked.
  public let siteRequests: Bool
  /// Extensions act on the tabs an agent controls.
  public let agentExtensions: Bool
}

/// The browser engine as a hidden child process of the host app: starts it, connects, says
/// `hello` and `host.attach`, and routes what comes back to the tab model, the page views and the
/// host. If it exits, the state says so and the host calls `start()` again when it wants.
@MainActor @Observable public final class BrowserEngine {
  public enum State: Equatable, Sendable {
    case stopped
    case starting
    case ready(protocol: Int, browser: String)
    case failed(String)
    /// It was running and went away (crash, or the socket closed). Tab ids are no longer valid.
    case exited
    /// It answered but speaks an older protocol than this kit needs.
    case versionTooOld(protocol: Int, browser: String)
  }

  /// The lowest `hello.protocol` this kit works with.
  public static let minimumProtocol = 1
  /// How long `start()` waits for the socket.
  public static let startTimeout: TimeInterval = 30

  public let executable: URL
  public let dataDirectory: URL
  public let arguments: [String]

  public private(set) var state: State = .stopped {
    didSet { if state != oldValue { onStateChange?(state) } }
  }
  public let tabs = BrowserTabs()
  /// The live connection while `ready`, for the typed and raw operations.
  public private(set) var connection: BrowserConnection?

  @ObservationIgnored public var onStateChange: ((State) -> Void)?
  /// Approval requests. Without a handler the kit answers `deny`.
  @ObservationIgnored public var onApproval: ((ApprovalRequest) async -> ApprovalAnswer)?
  /// What the engine asks the host to draw (`ui.ask`). Without a handler the kit cancels it;
  /// `presentDefaultUI` draws it with AppKit. On `ui.cancel` (and when the engine goes away) the kit
  /// cancels the handler's task, so close what you drew in `withTaskCancellationHandler`, and
  /// sends nothing; the reason comes in `onEvent`.
  @ObservationIgnored public var onUIRequest: ((UIRequest) async -> UIAnswer)?
  /// Picks of the element picker (`connection.pick`), and its ending without one.
  @ObservationIgnored public var onPick: ((PickResult) -> Void)?
  /// The host's own items in the right-click menu `presentDefaultUI` draws: after the engine's
  /// actions, past a separator. Choosing one calls `onContextMenuItem` and answers the engine
  /// with cancel.
  @ObservationIgnored public var contextMenuItems: [HostMenuItem] = []
  /// Which of `contextMenuItems` was chosen, with the menu's request (tab, point, link, selection).
  @ObservationIgnored public var onContextMenuItem: ((HostMenuItem, UIRequest) -> Void)?
  /// An extension was installed, updated, turned on or off, removed or pinned in an ato.
  @ObservationIgnored public var onExtensionChange: ((ExtensionChange) -> Void)?
  /// An action's badge, title, icon or visibility changed (redraw that button).
  @ObservationIgnored public var onExtensionAction: ((ExtensionActionUpdate) -> Void)?
  /// A popup's size, first after `clickExtension`, then on every change. `presentExtensionPopup`
  /// shows it under its button; a popup it shows follows the new size by itself.
  @ObservationIgnored public var onExtensionPopup: ((ExtensionPopup) -> Void)?
  /// A popup closed (`window.close()`, its tab navigated or closed, the extension went off, or
  /// `closeExtensionPopup`). One `presentExtensionPopup` showed closes by itself.
  @ObservationIgnored public var onExtensionPopupClosed: ((String) -> Void)?
  /// Every event, after the kit has handled the ones it knows.
  @ObservationIgnored public var onEvent: ((String, [String: JSON]) -> Void)?

  @ObservationIgnored private var process: Process?
  @ObservationIgnored private var generation = 0
  @ObservationIgnored private var views: [String: WeakView] = [:]
  /// The handlers of the `ui.ask`s still open, by `ask`.
  @ObservationIgnored private var uiTasks: [String: Task<Void, Never>] = [:]
  /// The popups `presentExtensionPopup` shows, by popup id.
  @ObservationIgnored var popups: [String: ExtensionPopupPresenter] = [:]

  /// - Parameters:
  ///   - executable: the engine binary, e.g. `Contents/Helpers/AgensBrowser.app/Contents/MacOS/AgensBrowser`.
  ///   - dataDirectory: the engine's profile folder; the socket is `agens.sock` inside it.
  ///   - arguments: extra engine arguments (e.g. `--agens-accept-unsigned` in development).
  public init(executable: URL, dataDirectory: URL, arguments: [String] = []) {
    self.executable = executable
    self.dataDirectory = dataDirectory
    self.arguments = arguments
  }

  public var socketPath: String { dataDirectory.appendingPathComponent("agens.sock").path }

  /// Starts the engine and returns when it is ready or has failed (see `state`). Does nothing
  /// while starting or ready.
  public func start() async {
    switch state {
    case .starting, .ready: return
    default: break
    }
    generation += 1
    let generation = generation
    state = .starting
    do {
      try BrowserConnection.checkSocketPath(socketPath)
      try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
    } catch {
      state = .failed("\(error)")
      return
    }

    let process = Process()
    process.executableURL = executable
    process.arguments = ["--agens-embedded", "--user-data-dir=\(dataDirectory.path)"] + arguments
    process.terminationHandler = { [weak self] process in
      let status = process.terminationStatus
      DispatchQueue.main.async { MainActor.assumeIsolated { self?.processExited(generation, status: status) } }
    }
    do {
      try process.run()
    } catch {
      state = .failed("could not start \(executable.path): \(error.localizedDescription)")
      return
    }
    self.process = process

    // A socket left by an earlier run may exist before the engine listens: retry until it connects.
    let deadline = Date().addingTimeInterval(Self.startTimeout)
    var connection: BrowserConnection?
    while connection == nil {
      guard self.generation == generation, state == .starting else { return }
      do {
        connection = try BrowserConnection(socketPath: socketPath)
      } catch {
        if Date() > deadline {
          fail(generation, "the engine did not open \(socketPath) in \(Int(Self.startTimeout)) s")
          return
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
      }
    }
    guard let connection else { return }
    attach(connection)
    do {
      let hello = try await connection.hello()
      guard self.generation == generation else { return }
      guard hello.protocol >= Self.minimumProtocol else {
        tearDown()
        state = .versionTooOld(protocol: hello.protocol, browser: hello.browser)
        return
      }
      do {
        try await connection.hostAttach()
      } catch where error.code == "unknown_op" {
        // An engine that does not know phase 5 is too old for the kit, whatever its number says.
        tearDown()
        state = .versionTooOld(protocol: hello.protocol, browser: hello.browser)
        return
      }
      guard self.generation == generation else { return }
      state = .ready(protocol: hello.protocol, browser: hello.browser)
    } catch {
      fail(generation, "\(error)")
    }
  }

  /// Terminates the engine. Call it when the app quits: the engine does not outlive its host by itself.
  public func stop() {
    tearDown()
    state = .stopped
  }

  /// Sets the options given (nil leaves one as it is) and returns both as the engine now has them;
  /// with no argument it only reads. The engine keeps them across launches. An engine older than
  /// this op throws `unknown_op`: it behaves as `siteRequests` false and `agentExtensions` true.
  public func settings(siteRequests: Bool? = nil, agentExtensions: Bool? = nil) async throws(BrowserError)
    -> HostSettings
  {
    guard let connection else { throw BrowserError(code: BrowserError.disconnected) }
    var params: [String: JSON] = [:]
    if let siteRequests { params["site_requests"] = .bool(siteRequests) }
    if let agentExtensions { params["agent_extensions"] = .bool(agentExtensions) }
    let reply = try await connection.send(op: "host.settings", params: params)
    return HostSettings(
      siteRequests: reply["site_requests"]?.bool ?? false, agentExtensions: reply["agent_extensions"]?.bool ?? true)
  }

  /// Opens the inspector (DevTools) for a tab in the engine's own window, the only one it puts on
  /// screen: Elements on the element at `point` (the view's points, as `view.mouse`), or just
  /// opened without one. If it is open for that tab already, it comes to the front. `denied` while an
  /// agent works on the tab, `failed` when developer tools are turned off for the page; an engine
  /// older than this op throws `unknown_op`. Answering the right-click menu's `inspect` does the same.
  public func inspect(_ tab: String, at point: CGPoint? = nil) async throws(BrowserError) {
    guard let connection else { throw BrowserError(code: BrowserError.disconnected) }
    var params: [String: JSON] = ["tab": .string(tab)]
    if let point {
      params["x"] = .number(Double(point.x))
      params["y"] = .number(Double(point.y))
    }
    yieldActivationToEngine()
    try await connection.send(op: "view.inspect", params: params)
  }

  /// The engine is another process, with no Dock icon: its DevTools window comes to the front and
  /// takes the keyboard only if this app hands activation over first (cooperative activation).
  private func yieldActivationToEngine() {
    guard let pid = process?.processIdentifier, let engine = NSRunningApplication(processIdentifier: pid) else { return }
    NSApp.yieldActivation(to: engine)
  }

  /// Wires a connection to the model and the views (also used by the tests, without a process).
  func attach(_ connection: BrowserConnection) {
    self.connection = connection
    tabs.connection = connection
    connection.onEvent = { [weak self] in self?.handle($0, $1) }
    let generation = generation
    connection.onClose = { [weak self] in self?.connectionClosed(generation) }
  }

  func register(_ view: BrowserTabView, tab: String) {
    views = views.filter { $0.value.view != nil }
    views[tab] = WeakView(view: view)
  }

  func view(_ tab: String?) -> BrowserTabView? { tab.flatMap { views[$0]?.view } }

  private func handle(_ event: String, _ message: [String: JSON]) {
    if !tabs.handle(event, message) {
      let view = view(message["tab"]?.string)
      switch event {
      case "view.layer":
        if let context = message["context"]?.double { view?.show(context: UInt32(context)) }
      case "view.cursor":
        if let cursor = message["cursor"]?.string { view?.setCursor(cursor) }
      case "view.caret":
        if let x = message["x"]?.double, let y = message["y"]?.double, let width = message["width"]?.double,
          let height = message["height"]?.double
        {
          view?.caret = CGRect(x: x, y: y, width: width, height: height)
        }
      case "approval.ask":
        answer(message)
      case "ui.ask":
        ask(message)
      case "ui.cancel":
        if let ask = message["ask"]?.string { uiTasks.removeValue(forKey: ask)?.cancel() }
      case "view.picked":
        if let result = PickResult(message: message) { onPick?(result) }
      case "extension.changed":
        if let ato = message["ato"]?.string, let id = message["extension"]?.string, let change = message["change"]?.string {
          onExtensionChange?(ExtensionChange(ato: ato, id: id, kind: ExtensionChange.Kind(change)))
        }
      case "extension.action":
        if let ato = message["ato"]?.string, let id = message["extension"]?.string {
          onExtensionAction?(ExtensionActionUpdate(
            ato: ato, tab: message["tab"]?.string, id: id, state: ExtensionActionState(message: message, name: id)))
        }
      case "extension.popup":
        if let popup = ExtensionPopup(message: message) {
          popups[popup.popup]?.resize(to: popup.size)
          onExtensionPopup?(popup)
        }
      case "extension.popup.closed":
        if let popup = message["popup"]?.string {
          popups.removeValue(forKey: popup)?.closed()
          onExtensionPopupClosed?(popup)
        }
      default:
        break
      }
    }
    onEvent?(event, message)
  }

  private func ask(_ message: [String: JSON]) {
    guard let ask = message["ask"]?.string, uiTasks[ask] == nil else { return }
    // One the kit cannot read is cancelled, so the page does not wait for it forever.
    guard let request = UIRequest(message: message), let onUIRequest else {
      connection?.request(op: "ui.answer", params: ["ask": .string(ask), "cancel": true])
      return
    }
    uiTasks[ask] = Task {
      let answer = await onUIRequest(request)
      guard !Task.isCancelled else { return }
      uiTasks[ask] = nil
      if answer == .contextMenu(action: "inspect") { yieldActivationToEngine() }
      try? await connection?.answerUI(ask, answer)
    }
  }

  private func answer(_ message: [String: JSON]) {
    let request = ApprovalRequest(message: message)
    Task {
      let answer = await onApproval?(request) ?? .deny
      try? await connection?.answerApproval(request.ask, answer: answer)
    }
  }

  private func processExited(_ generation: Int, status: Int32) {
    guard generation == self.generation else { return }
    if state == .starting {
      fail(generation, "the engine exited with status \(status) while starting")
    } else {
      wentAway(generation)
    }
  }

  private func connectionClosed(_ generation: Int) {
    guard generation == self.generation else { return }
    if state == .starting {
      fail(generation, "the engine closed the connection while starting")
    } else {
      wentAway(generation)
    }
  }

  private func wentAway(_ generation: Int) {
    guard case .ready = state else { return }
    tearDown()
    state = .exited
  }

  private func fail(_ generation: Int, _ reason: String) {
    guard generation == self.generation else { return }
    tearDown()
    state = .failed(reason)
  }

  private func tearDown() {
    generation += 1
    connection?.close()
    connection = nil
    tabs.connection = nil
    tabs.reset()
    views = [:]
    uiTasks.values.forEach { $0.cancel() }
    uiTasks = [:]
    popups.values.forEach { $0.closed() }
    popups = [:]
    if let process, process.isRunning { process.terminate() }
    process = nil
  }
}

private struct WeakView {
  weak var view: BrowserTabView?
}

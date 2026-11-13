import Foundation
import Testing

@testable import BrowserKit

/// A fake engine executable: checks its arguments, opens `<dir>/agens.sock` and answers every
/// request with `ok` (`hello` with `--protocol=N`, default 1). `--exit-after-attach` exits a moment
/// after `host.attach`.
private let fakeEngineScript = """
  #!/usr/bin/env python3
  import json, os, socket, sys, time
  args = sys.argv[1:]
  assert args[0] == "--agens-embedded", args
  data = next(a.split("=", 1)[1] for a in args if a.startswith("--user-data-dir="))
  version = int(next((a.split("=", 1)[1] for a in args if a.startswith("--protocol=")), "1"))
  with open(os.path.join(data, "args.json"), "w") as f: json.dump(args, f)
  path = os.path.join(data, "agens.sock")
  if os.path.exists(path): os.unlink(path)
  server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
  server.bind(path)
  server.listen(1)
  client, _ = server.accept()
  stream = client.makefile("rwb")
  for line in stream:
      request = json.loads(line)
      reply = {"protocol": version, "browser": "156.0.0.1"} if request["op"] == "hello" else {}
      reply.update(id=request["id"], ok=True)
      stream.write((json.dumps(reply) + "\\n").encode())
      stream.flush()
      if request["op"] == "host.attach" and "--exit-after-attach" in args:
          time.sleep(0.3)
          sys.exit(0)
  """

@MainActor @Suite(.serialized) struct EngineTests {
  private func folder() throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bk-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func script(_ text: String, in folder: URL) throws -> URL {
    let url = folder.appendingPathComponent("engine")
    try text.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url
  }

  @Test func startsAndStops() async throws {
    let base = try folder()
    defer { try? FileManager.default.removeItem(at: base) }
    let data = base.appendingPathComponent("data")
    let engine = BrowserEngine(executable: try script(fakeEngineScript, in: base), dataDirectory: data, arguments: ["--agens-accept-unsigned"])
    var states: [BrowserEngine.State] = []
    engine.onStateChange = { states.append($0) }
    await engine.start()
    #expect(engine.state == .ready(protocol: 1, browser: "156.0.0.1"))
    #expect(states == [.starting, .ready(protocol: 1, browser: "156.0.0.1")])
    let args = try JSONSerialization.jsonObject(with: Data(contentsOf: data.appendingPathComponent("args.json"))) as? [String]
    #expect(args == ["--agens-embedded", "--user-data-dir=\(data.path)", "--agens-accept-unsigned"])
    #expect(engine.connection != nil)
    engine.stop()
    #expect(engine.state == .stopped && engine.connection == nil)
    try await Task.sleep(nanoseconds: 300_000_000)
    #expect(engine.state == .stopped)  // the child's exit after stop() is not reported as `exited`
  }

  @Test func reportsAnEngineThatGoesAway() async throws {
    let base = try folder()
    defer { try? FileManager.default.removeItem(at: base) }
    let engine = BrowserEngine(
      executable: try script(fakeEngineScript, in: base), dataDirectory: base.appendingPathComponent("data"),
      arguments: ["--exit-after-attach"])
    await engine.start()
    #expect(engine.state == .ready(protocol: 1, browser: "156.0.0.1"))
    #expect(await eventually { engine.state == .exited })
    #expect(engine.connection == nil)
    // The host starts it again.
    await engine.start()
    #expect(engine.state == .ready(protocol: 1, browser: "156.0.0.1"))
    engine.stop()
  }

  @Test func failsWhenTheEngineExitsEarly() async throws {
    let base = try folder()
    defer { try? FileManager.default.removeItem(at: base) }
    let engine = BrowserEngine(executable: try script("#!/bin/sh\nexit 3\n", in: base), dataDirectory: base.appendingPathComponent("data"))
    await engine.start()
    #expect(engine.state == .failed("the engine exited with status 3 while starting"))
  }

  @Test func failsWhenTheExecutableIsMissing() async throws {
    let engine = BrowserEngine(executable: URL(fileURLWithPath: "/nonexistent/engine"), dataDirectory: try folder())
    await engine.start()
    guard case .failed(let reason) = engine.state else { Issue.record("\(engine.state)"); return }
    #expect(reason.contains("/nonexistent/engine"))
  }

  @Test func versionTooOld() async throws {
    let base = try folder()
    defer { try? FileManager.default.removeItem(at: base) }
    let engine = BrowserEngine(
      executable: try script(fakeEngineScript, in: base), dataDirectory: base.appendingPathComponent("data"),
      arguments: ["--protocol=0"])
    await engine.start()
    #expect(engine.state == .versionTooOld(protocol: 0, browser: "156.0.0.1"))
  }

  @Test func socketPathTooLong() async throws {
    let long = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(String(repeating: "d", count: 100))
    let engine = BrowserEngine(executable: URL(fileURLWithPath: "/bin/sh"), dataDirectory: long)
    await engine.start()
    guard case .failed(let reason) = engine.state else { Issue.record("\(engine.state)"); return }
    #expect(reason.hasPrefix("socket_path_too_long: socket path is"))
    #expect(!FileManager.default.fileExists(atPath: long.path))
  }
}

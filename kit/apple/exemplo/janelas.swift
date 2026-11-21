// Lists the windows of the given process ids only (owner, on screen, layer, size): what the
// test put on the screen, without looking at anyone else's windows.
import CoreGraphics
import Foundation

let pids = Set(CommandLine.arguments.dropFirst().compactMap { Int($0) })
let all = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
for window in all where pids.contains(window[kCGWindowOwnerPID as String] as? Int ?? -1) {
  let bounds = window[kCGWindowBounds as String] as? [String: Any] ?? [:]
  print(
    window[kCGWindowOwnerName as String] ?? "?", "id=\(window[kCGWindowNumber as String] ?? "?")",
    "onscreen=\(window[kCGWindowIsOnscreen as String] ?? 0)", "layer=\(window[kCGWindowLayer as String] ?? "?")",
    "\(bounds["Width"] ?? "?")x\(bounds["Height"] ?? "?")")
}

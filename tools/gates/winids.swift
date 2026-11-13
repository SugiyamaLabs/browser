// Prints the ids of the on-screen, normal-layer windows owned by a pid, one per line.
import CoreGraphics
import Foundation
let pid = Int(CommandLine.arguments[1])!
let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as! [[String: Any]]
for w in list where (w[kCGWindowOwnerPID as String] as? Int) == pid && (w[kCGWindowLayer as String] as? Int) == 0 {
  let b = w[kCGWindowBounds as String] as! [String: Any]
  if (b["Height"] as? Double ?? 0) > 200 { print(w[kCGWindowNumber as String] as! Int) }
}

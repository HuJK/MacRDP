// axpress — press a button in another process's windows via the
// Accessibility API (no AppleEvents, so no Automation prompt).
//
//   axpress <process-name> <button-title> [window-text-filter]
//
// Lists every window of <process-name> with its static text, and presses
// <button-title> in each window whose text contains [window-text-filter]
// (all windows when omitted). Exits 1 if nothing was pressed.
//
// Runs inside the Tart VM through `tart exec`, whose guest agent already
// holds Accessibility, e.g. to approve the ScreenCaptureKit
// "bypass the system private window picker" alert for MacRDP.

import AppKit
import ApplicationServices

func attr(_ el: AXUIElement, _ name: String) -> AnyObject? {
    var v: AnyObject?
    return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? v : nil
}

func descendants(_ el: AXUIElement) -> [AXUIElement] {
    let kids = (attr(el, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    return kids + kids.flatMap(descendants)
}

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write("usage: axpress <process-name> <button-title> [window-text-filter]\n".data(using: .utf8)!)
    exit(2)
}
let (procName, title) = (args[1], args[2])
let filter = args.count > 3 ? args[3] : nil

guard AXIsProcessTrusted() else {
    FileHandle.standardError.write("axpress: not trusted for Accessibility\n".data(using: .utf8)!)
    exit(2)
}

var pressed = 0
for app in NSWorkspace.shared.runningApplications where app.localizedName == procName
    || app.executableURL?.lastPathComponent == procName {
    let axApp = AXUIElementCreateApplication(app.processIdentifier)
    for win in (attr(axApp, kAXWindowsAttribute) as? [AXUIElement]) ?? [] {
        let nodes = descendants(win)
        let text = nodes.compactMap { el -> String? in
            guard attr(el, kAXRoleAttribute) as? String == kAXStaticTextRole as String else { return nil }
            return attr(el, kAXValueAttribute) as? String
        }.joined(separator: " ")
        print("window: \(text)")
        if let filter, !text.contains(filter) { continue }
        for el in nodes where attr(el, kAXRoleAttribute) as? String == kAXButtonRole as String
            && attr(el, kAXTitleAttribute) as? String == title {
            if AXUIElementPerformAction(el, kAXPressAction as CFString) == .success {
                print("  pressed \"\(title)\"")
                pressed += 1
            }
        }
    }
}
exit(pressed > 0 ? 0 : 1)

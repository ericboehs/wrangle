import Cocoa
import ApplicationServices
import CoreGraphics
import Darwin

let protocolVersion = "1.2"
let maxSnapshotNodes = 1_500
let maxChildrenPerNode = 120
let maxTextCharacters = 500

enum HelperFailure: Error {
    case refused(String, String, String?, [String: Any]?)
}

// LaunchServices leaves launchDate unset for directly executed app bundles such as `tart run`.
// Kernel process birth time remains available there and still detects PID reuse across app restarts.
func processInstance(_ app: NSRunningApplication) throws -> String {
    let pid = app.processIdentifier
    var info = proc_bsdinfo()
    let expected = MemoryLayout<proc_bsdinfo>.size
    let actual = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(expected))
    guard actual == expected, info.pbi_start_tvsec > 0, info.pbi_start_tvusec < 1_000_000 else {
        throw HelperFailure.refused("scope_changed", "The application has no stable launch identity", nil, nil)
    }
    return "macos-proc-v2:\(pid):\(info.pbi_start_tvsec):\(info.pbi_start_tvusec)"
}

func application(_ pid: pid_t, expected: String?) throws -> NSRunningApplication {
    guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else {
        throw HelperFailure.refused("scope_changed", "The scoped application is no longer running", nil, nil)
    }
    let actual = try processInstance(app)
    if let expected, expected != actual {
        throw HelperFailure.refused("scope_changed", "The scoped application process was replaced", nil,
                                    ["expected": expected, "actual": actual])
    }
    return app
}

func runningApplications(named wanted: String) -> [NSRunningApplication] {
    let needle = wanted.lowercased()
    return NSWorkspace.shared.runningApplications.filter { app in
        guard !app.isTerminated else { return false }
        return app.bundleIdentifier?.lowercased() == needle || app.localizedName?.lowercased() == needle
    }
}

func rect(_ dictionary: [String: Any]) -> [String: Double]? {
    guard let bounds = CGRect(dictionaryRepresentation: dictionary as CFDictionary) else { return nil }
    return ["x": bounds.origin.x, "y": bounds.origin.y,
            "width": bounds.size.width, "height": bounds.size.height]
}

func windows(appName: String, titles: Bool) throws -> [[String: Any]] {
    let apps = runningApplications(named: appName)
    guard !apps.isEmpty else {
        throw HelperFailure.refused("app_not_found", "Application is not running", "Open \(appName) and try again", nil)
    }
    let byPID = Dictionary(uniqueKeysWithValues: try apps.map {
        (Int($0.processIdentifier), (try processInstance($0), $0.bundleIdentifier ?? ""))
    })
    let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
    let records = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        as? [[String: Any]] ?? []
    var firstForPID = Set<Int>()
    return records.compactMap { record in
        guard let pid = record[kCGWindowOwnerPID as String] as? Int,
              let identity = byPID[pid],
              (record[kCGWindowLayer as String] as? Int) == 0,
              let number = record[kCGWindowNumber as String] as? Int,
              let rawBounds = record[kCGWindowBounds as String] as? [String: Any],
              let bounds = rect(rawBounds), bounds["width", default: 0] > 1, bounds["height", default: 0] > 1
        else { return nil }
        let focused = pid_t(pid) == frontPID && !firstForPID.contains(pid)
        firstForPID.insert(pid)
        var result: [String: Any] = [
            "id": "w-\(number)", "number": number, "pid": pid, "process_instance": identity.0,
            "bundle_id": identity.1, "app_name": record[kCGWindowOwnerName as String] as? String ?? appName,
            "bounds": bounds, "focused": focused,
            "visible": (record[kCGWindowIsOnscreen as String] as? Bool) ?? true
        ]
        if titles, let title = record[kCGWindowName as String] as? String { result["title"] = title }
        return result
    }
}

func displays() -> [[String: Any]] {
    guard let primary = NSScreen.screens.first else { return [] }
    let top = primary.frame.maxY
    return NSScreen.screens.enumerated().map { index, screen in
        let frame = screen.frame
        let visible = screen.visibleFrame
        let number = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
        return [
            "id": "display-\(number)", "index": index, "primary": index == 0,
            "scale": screen.backingScaleFactor,
            "bounds": ["x": frame.minX, "y": top - frame.maxY,
                       "width": frame.width, "height": frame.height],
            "visible_bounds": ["x": visible.minX, "y": top - visible.maxY,
                               "width": visible.width, "height": visible.height]
        ]
    }
}

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
}

func boolean(_ element: AXUIElement, _ name: String) -> Bool? {
    attribute(element, name) as? Bool
}

func string(_ element: AXUIElement, _ name: String) -> String? {
    attribute(element, name) as? String
}

func point(_ value: CFTypeRef?) -> CGPoint? {
    guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
    var result = CGPoint.zero
    return AXValueGetValue(value as! AXValue, .cgPoint, &result) ? result : nil
}

func size(_ value: CFTypeRef?) -> CGSize? {
    guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
    var result = CGSize.zero
    return AXValueGetValue(value as! AXValue, .cgSize, &result) ? result : nil
}

func elementBounds(_ element: AXUIElement) -> CGRect? {
    guard let origin = point(attribute(element, kAXPositionAttribute)),
          let dimensions = size(attribute(element, kAXSizeAttribute)),
          dimensions.width >= 0, dimensions.height >= 0 else { return nil }
    return CGRect(origin: origin, size: dimensions)
}

func boundsDictionary(_ bounds: CGRect) -> [String: Double] {
    ["x": bounds.minX, "y": bounds.minY, "width": bounds.width, "height": bounds.height]
}

func inputBounds(_ value: Any?) -> CGRect? {
    guard let dictionary = value as? [String: Any],
          let x = dictionary["x"] as? NSNumber, let y = dictionary["y"] as? NSNumber,
          let width = dictionary["width"] as? NSNumber, let height = dictionary["height"] as? NSNumber
    else { return nil }
    return CGRect(x: x.doubleValue, y: y.doubleValue, width: width.doubleValue, height: height.doubleValue)
}

func nearlyEqual(_ first: CGRect, _ second: CGRect, tolerance: Double = 2) -> Bool {
    abs(first.minX - second.minX) <= tolerance && abs(first.minY - second.minY) <= tolerance &&
        abs(first.width - second.width) <= tolerance && abs(first.height - second.height) <= tolerance
}

func overlapScore(_ first: CGRect, _ second: CGRect) -> Double {
    let overlap = first.intersection(second)
    guard !overlap.isNull else { return 0 }
    let smaller = min(first.width * first.height, second.width * second.height)
    return smaller > 0 ? (overlap.width * overlap.height) / smaller : 0
}

func windowNumber(_ identifier: String) -> CGWindowID? {
    guard identifier.hasPrefix("w-"), let number = UInt32(identifier.dropFirst(2)), number > 0 else { return nil }
    return CGWindowID(number)
}

func verifyCGWindow(pid: pid_t, identifier: String, expectedBounds: CGRect) throws -> CGRect {
    guard let number = windowNumber(identifier) else {
        throw HelperFailure.refused("bad_request", "Invalid scoped window identifier", nil, nil)
    }
    let records = CGWindowListCopyWindowInfo(.optionIncludingWindow, number) as? [[String: Any]] ?? []
    guard let record = records.first(where: {
        ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == number
    }), (record[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
          let rawBounds = record[kCGWindowBounds as String] as? [String: Any],
          let currentBounds = rect(rawBounds).flatMap({ inputBounds($0) }),
          nearlyEqual(currentBounds, expectedBounds)
    else {
        throw HelperFailure.refused("scope_changed", "The exact CoreGraphics window changed before AX access", nil,
                                    ["window_id": identifier])
    }
    return currentBounds
}

func axChildren(_ element: AXUIElement) -> [AXUIElement] {
    attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
}

func sessionLocked() -> Bool {
    let session = CGSessionCopyCurrentDictionary() as? [String: Any]
    return (session?["CGSSessionScreenIsLocked"] as? Bool) == true
}

func exactAXWindow(pid: pid_t, identifier: String, expectedBounds: CGRect) throws -> AXUIElement {
    if sessionLocked() {
        throw HelperFailure.refused("session_locked", "The macOS session is locked", "Unlock it and observe again", nil)
    }
    let currentBounds = try verifyCGWindow(pid: pid, identifier: identifier, expectedBounds: expectedBounds)
    let applicationElement = AXUIElementCreateApplication(pid)
    let candidates = axChildren(applicationElement).filter {
        string($0, kAXRoleAttribute) == kAXWindowRole && elementBounds($0).map {
            overlapScore($0, currentBounds) >= 0.90 &&
                abs($0.midX - currentBounds.midX) <= 32 && abs($0.midY - currentBounds.midY) <= 32
        } == true
    }
    guard candidates.count == 1, let match = candidates.first else {
        throw HelperFailure.refused(
            candidates.isEmpty ? "action_not_supported" : "ambiguous_target",
            candidates.isEmpty ? "No AX window matched the exact CoreGraphics root" :
                "More than one AX window matched the exact CoreGraphics root",
            nil, ["window_id": identifier, "candidate_count": candidates.count]
        )
    }
    return match
}

func normalizedRole(_ raw: String?) -> String {
    guard var role = raw, !role.isEmpty else { return "unknown" }
    if role.hasPrefix("AX") { role.removeFirst(2) }
    return role.lowercased().replacingOccurrences(of: "_", with: "")
}

func normalizedSubrole(_ raw: String?) -> String? {
    guard var role = raw, !role.isEmpty else { return nil }
    if role.hasPrefix("AX") { role.removeFirst(2) }
    return role.lowercased().replacingOccurrences(of: "_", with: "")
}

func directElementName(_ element: AXUIElement, role: String) -> String {
    for name in [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute, "AXLabel"] {
        if let value = string(element, name), !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return String(value.prefix(maxTextCharacters))
        }
    }
    if role == "statictext", let value = string(element, kAXValueAttribute) {
        return String(value.prefix(maxTextCharacters))
    }
    return ""
}

func elementName(_ element: AXUIElement, role: String) -> String {
    let direct = directElementName(element, role: role)
    if !direct.isEmpty || !["row", "treeitem", "cell"].contains(role) { return direct }

    var queue = axChildren(element).map { ($0, 1) }
    var visited = 0
    while !queue.isEmpty && visited < 24 {
        let (child, depth) = queue.removeFirst()
        visited += 1
        let childRole = normalizedRole(string(child, kAXRoleAttribute))
        let name = directElementName(child, role: childRole)
        if !name.isEmpty { return name }
        if depth < 2 { queue.append(contentsOf: axChildren(child).map { ($0, depth + 1) }) }
    }
    return ""
}

func scalarValue(_ element: AXUIElement, secure: Bool) -> Any? {
    guard !secure, let value = attribute(element, kAXValueAttribute) else { return nil }
    if let text = value as? String { return String(text.prefix(maxTextCharacters)) }
    if let flag = value as? Bool { return flag }
    if let number = value as? NSNumber { return number }
    return nil
}

func isSettable(_ element: AXUIElement, _ name: String) -> Bool {
    var settable = DarwinBoolean(false)
    return AXUIElementIsAttributeSettable(element, name as CFString, &settable) == .success && settable.boolValue
}

func actionNames(_ element: AXUIElement) -> [String] {
    var names: CFArray?
    guard AXUIElementCopyActionNames(element, &names) == .success else { return [] }
    return names as? [String] ?? []
}

func operationMap(_ element: AXUIElement, role: String, subrole: String?) -> [String: String] {
    if boolean(element, kAXEnabledAttribute) == false ||
        ["closebutton", "minimizebutton", "zoombutton", "fullscreenbutton"].contains(subrole ?? "") {
        return [:]
    }
    let names = actionNames(element)
    var operations: [String: String] = [:]
    let textRole = ["textfield", "textarea", "searchfield", "combobox"].contains(role)
    if textRole && isSettable(element, kAXValueAttribute) {
        operations["SET_TEXT"] = "AXSetValue"
        operations["CLEAR"] = "AXSetValue"
    }
    if ["checkbox", "switch", "radiobutton"].contains(role), names.contains(kAXPressAction) {
        operations["TOGGLE"] = kAXPressAction
    } else if ["row", "treeitem", "cell"].contains(role),
              isSettable(element, kAXSelectedAttribute), boolean(element, kAXSelectedAttribute) != true {
        operations["PRESS"] = "AXSetSelected"
    } else if let action = [kAXPressAction, "AXOpen", "AXConfirm"].first(where: names.contains) {
        operations["PRESS"] = action
    }
    if isSettable(element, kAXExpandedAttribute), let expanded = boolean(element, kAXExpandedAttribute) {
        operations[expanded ? "COLLAPSE" : "EXPAND"] = "AXSetExpanded"
    }
    return operations
}

func elementStates(_ element: AXUIElement) -> [String] {
    var states: [String] = []
    if boolean(element, kAXEnabledAttribute) == true { states.append("enabled") }
    if boolean(element, kAXFocusedAttribute) == true { states.append("focused") }
    if boolean(element, kAXSelectedAttribute) == true { states.append("selected") }
    if boolean(element, kAXExpandedAttribute) == true { states.append("expanded") }
    if let value = boolean(element, kAXValueAttribute), value { states.append("checked") }
    return states
}

func targetSignature(_ element: AXUIElement, path: [Int], role: String, subrole: String?, name: String,
                     operations: [String: String]) -> [String: Any] {
    var signature: [String: Any] = ["path": path, "role": role, "name": name, "operations": operations]
    if let subrole { signature["subrole"] = subrole }
    if let identifier = string(element, kAXIdentifierAttribute), !identifier.isEmpty {
        signature["identifier"] = identifier
    }
    if let bounds = elementBounds(element) { signature["bounds"] = boundsDictionary(bounds) }
    return signature
}

func targetKey(path: [Int], role: String) -> String {
    "native:\(path.map(String.init).joined(separator: ".")):\(role)"
}

func resolvePath(root: AXUIElement, path: [Int]) throws -> AXUIElement {
    var current = root
    for index in path {
        let children = axChildren(current)
        guard index >= 0, index < children.count else {
            throw HelperFailure.refused("stale_ref", "The native AX target path no longer exists", nil, nil)
        }
        current = children[index]
    }
    return current
}

func validateTarget(_ element: AXUIElement, target: [String: Any]) throws {
    let role = normalizedRole(string(element, kAXRoleAttribute))
    let subrole = normalizedSubrole(string(element, kAXSubroleAttribute))
    let name = elementName(element, role: role)
    guard role == target["role"] as? String, name == target["name"] as? String,
          subrole == target["subrole"] as? String else {
        throw HelperFailure.refused("stale_ref", "The native AX target identity changed", nil, nil)
    }
    if let expected = target["identifier"] as? String,
       string(element, kAXIdentifierAttribute) != expected {
        throw HelperFailure.refused("stale_ref", "The native AX target identifier changed", nil, nil)
    }
    if let expected = inputBounds(target["bounds"]),
       elementBounds(element).map({ nearlyEqual($0, expected) }) != true {
        throw HelperFailure.refused("stale_ref", "The native AX target bounds changed", nil, nil)
    }
}

func snapshot(pid: pid_t, processInstance expected: String, windowID: String, bounds: CGRect,
              rootTarget: [String: Any]?, maxDepth: Int) throws -> [String: Any] {
    _ = try application(pid, expected: expected)
    let window = try exactAXWindow(pid: pid, identifier: windowID, expectedBounds: bounds)
    let root: AXUIElement
    let rootPath: [Int]
    if let rootTarget {
        rootPath = rootTarget["path"] as? [Int] ?? []
        root = try resolvePath(root: window, path: rootPath)
        try validateTarget(root, target: rootTarget)
    } else {
        root = window
        rootPath = []
    }

    let snapshotID = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16).lowercased()
    var targets: [String: Any] = [:]
    var sequence = 0
    var nodeCount = 0
    var complete = true

    func visit(_ element: AXUIElement, path: [Int], depth: Int, ancestors: [AXUIElement]) -> [String: Any] {
        nodeCount += 1
        let role = normalizedRole(string(element, kAXRoleAttribute))
        let subrole = normalizedSubrole(string(element, kAXSubroleAttribute))
        let name = elementName(element, role: role)
        let secure = subrole == "securetextfield" ||
            name.range(of: "password|passcode|security code", options: [.regularExpression, .caseInsensitive]) != nil
        let operations = operationMap(element, role: role, subrole: subrole)
        var node: [String: Any] = ["role": role, "name": name, "states": elementStates(element)]
        if let subrole { node["subrole"] = subrole }
        if let value = scalarValue(element, secure: secure) { node["value"] = value }

        let children = axChildren(element)
        var included: [[String: Any]] = []
        var omitted = 0
        if depth >= maxDepth {
            omitted = children.count
        } else {
            for (index, child) in children.enumerated() {
                if index >= maxChildrenPerNode || nodeCount >= maxSnapshotNodes {
                    omitted = children.count - index
                    break
                }
                if ancestors.contains(where: { CFEqual($0, child) }) {
                    omitted += 1
                    continue
                }
                included.append(visit(child, path: path + [index], depth: depth + 1,
                                      ancestors: ancestors + [element]))
            }
        }
        if omitted > 0 {
            complete = false
            node["children_count"] = omitted
        }
        if !included.isEmpty { node["children"] = included }
        if !operations.isEmpty || omitted > 0 {
            sequence += 1
            let reference = "@n\(snapshotID):e\(sequence)"
            node["ref_id"] = reference
            node["operations"] = Array(operations.keys).sorted()
            node["target_key"] = targetKey(path: path, role: role)
            targets[reference] = targetSignature(element, path: path, role: role, subrole: subrole,
                                                 name: name, operations: operations)
        }
        return node
    }

    let tree = visit(root, path: rootPath, depth: 0, ancestors: [])
    return ["snapshot_id": String(snapshotID), "complete": complete,
            "window": ["id": windowID], "tree": tree, "targets": targets,
            "provenance": ["ax", "macos_helper_native"]]
}

func expandedAccessibility(_ app: AXUIElement) -> Bool {
    var queue = axChildren(app)
    var visited = 0
    while !queue.isEmpty && visited < 600 {
        let element = queue.removeFirst()
        visited += 1
        if string(element, kAXRoleAttribute) == "AXWebArea" { return true }
        queue.append(contentsOf: axChildren(element).prefix(80))
    }
    return false
}

func enableAccessibility(pid: pid_t, expected: String?) throws -> [String: Any] {
    if sessionLocked() {
        throw HelperFailure.refused("session_locked", "The macOS session is locked", "Unlock it and try again", nil)
    }
    let app = try application(pid, expected: expected)
    let element = AXUIElementCreateApplication(pid)
    let attributeName = "AXManualAccessibility"
    let before = boolean(element, attributeName)
    let result = AXUIElementSetAttributeValue(element, attributeName as CFString, kCFBooleanTrue)
    let after = boolean(element, attributeName)
    let expanded = expandedAccessibility(element)
    guard (result == .success && after == true) || expanded else {
        throw HelperFailure.refused("action_not_supported", "Application did not expose expanded accessibility", nil,
                                    ["ax_error": result.rawValue, "attribute_verified": after == true,
                                     "expansion_verified": expanded])
    }
    return ["pid": pid, "process_instance": try processInstance(app),
            "changed": before != true, "verified": true,
            "attribute_verified": after == true, "expansion_verified": expanded]
}

func executeNative(pid: pid_t, processInstance expected: String, windowID: String, bounds: CGRect,
                   target: [String: Any], operation: String, text: String?) throws -> [String: Any] {
    _ = try application(pid, expected: expected)
    let window = try exactAXWindow(pid: pid, identifier: windowID, expectedBounds: bounds)
    guard let path = target["path"] as? [Int] else {
        throw HelperFailure.refused("bad_request", "Native action target has no path", nil, nil)
    }
    let element = try resolvePath(root: window, path: path)
    try validateTarget(element, target: target)
    let role = normalizedRole(string(element, kAXRoleAttribute))
    let subrole = normalizedSubrole(string(element, kAXSubroleAttribute))
    let currentOperations = operationMap(element, role: role, subrole: subrole)
    guard let operations = target["operations"] as? [String: String], let native = operations[operation],
          currentOperations[operation] == native else {
        throw HelperFailure.refused("stale_ref", "Operation is no longer observed on the native AX target", nil, nil)
    }

    let result: AXError
    if native == "AXSetValue" {
        let value = operation == "CLEAR" ? "" : text
        guard let value else {
            throw HelperFailure.refused("bad_request", "SET_TEXT requires exact text", nil, nil)
        }
        result = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, value as CFTypeRef)
    } else if native == "AXSetExpanded" {
        result = AXUIElementSetAttributeValue(element, kAXExpandedAttribute as CFString,
                                              (operation == "EXPAND" ? kCFBooleanTrue : kCFBooleanFalse))
    } else if native == "AXSetSelected" {
        result = AXUIElementSetAttributeValue(element, kAXSelectedAttribute as CFString, kCFBooleanTrue)
    } else {
        result = AXUIElementPerformAction(element, native as CFString)
    }
    if result == .success {
        return ["dispatch": "delivered", "effect": "pending_verification", "driver": "macos_helper_native"]
    }
    if result == .actionUnsupported || result == .attributeUnsupported || result == .illegalArgument {
        return ["dispatch": "not_delivered", "code": "AX_\(result.rawValue)",
                "driver": "macos_helper_native"]
    }
    return ["dispatch": "delivery_unknown", "code": "AX_\(result.rawValue)",
            "driver": "macos_helper_native"]
}

func requiredScope(_ input: [String: Any]) throws -> (pid_t, String, String, CGRect) {
    guard let pid = input["pid"] as? Int, pid > 0,
          let instance = input["process_instance"] as? String, !instance.isEmpty,
          let windowID = input["window_id"] as? String, !windowID.isEmpty,
          let bounds = inputBounds(input["bounds"]) else {
        throw HelperFailure.refused("bad_request", "Native AX operation requires exact scope evidence", nil, nil)
    }
    return (pid_t(pid), instance, windowID, bounds)
}

func request() throws -> [String: Any] {
    guard CommandLine.arguments.count == 2,
          let data = CommandLine.arguments[1].data(using: .utf8),
          let input = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let operation = input["op"] as? String
    else { throw HelperFailure.refused("bad_request", "Expected one JSON request argument", nil, nil) }

    switch operation {
    case "ping":
        return ["version": protocolVersion, "platform": "macos", "accessibility": AXIsProcessTrusted(),
                "session_locked": sessionLocked()]
    case "displays":
        let found = displays()
        guard !found.isEmpty else {
            throw HelperFailure.refused("incomplete_observation", "macOS returned no attached displays", nil, nil)
        }
        return ["displays": found]
    case "windows":
        guard let app = input["app"] as? String, !app.isEmpty else {
            throw HelperFailure.refused("bad_request", "Window discovery requires an application", nil, nil)
        }
        return ["windows": try windows(appName: app, titles: input["titles"] as? Bool ?? false)]
    case "frontmost":
        guard let app = NSWorkspace.shared.frontmostApplication,
              let name = app.bundleIdentifier ?? app.localizedName else {
            throw HelperFailure.refused("scope_changed", "There is no frontmost application", nil, nil)
        }
        let found = try windows(appName: name, titles: input["titles"] as? Bool ?? false)
        guard let first = found.first(where: { ($0["focused"] as? Bool) == true }) ?? found.first else {
            throw HelperFailure.refused("scope_changed", "The frontmost application has no visible window", nil, nil)
        }
        return ["window": first]
    case "enable_accessibility":
        guard let pid = input["pid"] as? Int else {
            throw HelperFailure.refused("bad_request", "Accessibility setup requires a PID", nil, nil)
        }
        return try enableAccessibility(pid: pid_t(pid), expected: input["process_instance"] as? String)
    case "snapshot":
        let (pid, instance, windowID, bounds) = try requiredScope(input)
        let depth = min(max(input["max_depth"] as? Int ?? 18, 1), 24)
        return try snapshot(pid: pid, processInstance: instance, windowID: windowID, bounds: bounds,
                            rootTarget: input["root_target"] as? [String: Any], maxDepth: depth)
    case "execute":
        let (pid, instance, windowID, bounds) = try requiredScope(input)
        guard let target = input["target"] as? [String: Any],
              let action = input["operation"] as? String else {
            throw HelperFailure.refused("bad_request", "Native AX execution requires a target and operation", nil, nil)
        }
        return try executeNative(pid: pid, processInstance: instance, windowID: windowID, bounds: bounds,
                                 target: target, operation: action, text: input["text"] as? String)
    default:
        throw HelperFailure.refused("bad_request", "Unknown operation \(operation)", nil, nil)
    }
}

func emit(_ object: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    print(String(data: data, encoding: .utf8)!)
}

do {
    emit(["version": protocolVersion, "ok": true, "value": try request()])
} catch HelperFailure.refused(let code, let message, let suggestion, let details) {
    var error: [String: Any] = ["code": code, "message": message,
                                "disposition": ["delivery": "not_delivered", "retry": "unsafe"]]
    if let suggestion { error["suggestion"] = suggestion }
    if let details { error["details"] = details }
    emit(["version": protocolVersion, "ok": false, "error": error])
    exit(1)
} catch {
    emit(["version": protocolVersion, "ok": false,
          "error": ["code": "bridge_error", "message": "macOS helper failed",
                    "disposition": ["delivery": "not_delivered", "retry": "unsafe"]]])
    exit(1)
}

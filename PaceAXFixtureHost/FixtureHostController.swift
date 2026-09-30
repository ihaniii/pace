//
//  FixtureHostController.swift
//  PaceAXFixtureHost
//
//  Parses one control-channel request and dispatches it to the FixtureScene. Every command
//  answers with {"ok": true, ...} or {"ok": false, "error": "..."}; nothing is ever guessed.
//
//  The Phase 0 spike commands (createTextFieldWindow, createButtonWindow, focus, query,
//  closeWindow) keep their original geometry and behavior so the spike tests stay unchanged.
//

import AppKit
import Foundation

@MainActor
final class FixtureHostController: NSObject {
    private let scene = FixtureScene()

    func handle(requestLine: String) -> [String: Any] {
        guard let requestData = requestLine.data(using: .utf8),
              let request = (try? JSONSerialization.jsonObject(with: requestData)) as? [String: Any],
              let requestId = request["id"] as? Int,
              let command = request["command"] as? String else {
            return ["id": -1, "ok": false, "error": "malformed request"]
        }
        var response: [String: Any]
        do {
            response = try perform(command: command, request: request)
            response["ok"] = true
        } catch {
            response = ["ok": false, "error": String(describing: error)]
        }
        response["id"] = requestId
        return response
    }

    private func perform(command: String, request: [String: Any]) throws -> [String: Any] {
        switch command {
        case "ping":
            return [
                "pid": Int(ProcessInfo.processInfo.processIdentifier),
                "parentPid": Int(getppid()),
                "bundleIdentifier": Bundle.main.bundleIdentifier ?? ""
            ]

        // MARK: Phase 0 spike commands

        case "createTextFieldWindow":
            let identifier = try requiredString("identifier", in: request)
            let windowToken = try scene.createWindow(identifier: nil, title: nil, width: 300, height: 80, styleNames: ["titled"], kind: "window")
            try scene.addControl(
                kind: "textField",
                identifier: identifier,
                windowTokenOrIdentifier: windowToken,
                parentIdentifier: nil,
                frame: NSRect(x: 20, y: 20, width: 240, height: 24),
                properties: ["stringValue": request["value"] as? String ?? ""]
            )
            return ["windowToken": windowToken]
        case "createButtonWindow":
            let identifier = try requiredString("identifier", in: request)
            let windowToken = try scene.createWindow(identifier: nil, title: nil, width: 300, height: 80, styleNames: ["titled"], kind: "window")
            try scene.addControl(
                kind: "button",
                identifier: identifier,
                windowTokenOrIdentifier: windowToken,
                parentIdentifier: nil,
                frame: NSRect(x: 20, y: 20, width: 200, height: 32),
                properties: ["title": request["title"] as? String ?? "Fixture Button"]
            )
            return ["windowToken": windowToken]
        case "focus":
            let identifier = try requiredString("identifier", in: request)
            guard let control = scene.viewsByIdentifier[identifier], let window = control.window else {
                throw FixtureSceneError.unknownIdentifier(identifier)
            }
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            let madeFirstResponder = window.makeFirstResponder(control)
            return ["madeFirstResponder": madeFirstResponder, "isActive": NSApp.isActive]
        case "query":
            let identifier = try requiredString("identifier", in: request)
            let property = try requiredString("property", in: request)
            guard property == "stringValue" || property == "pressCount" else {
                throw FixtureSceneError.unsupportedKey(key: property, target: "query")
            }
            return ["value": try scene.value(forKey: property, identifier: identifier)]
        case "closeWindow":
            let windowToken = try requiredString("windowToken", in: request)
            guard let window = scene.removeWindow(token: windowToken) else { throw FixtureSceneError.unknownIdentifier(windowToken) }
            window.close()
            return [:]

        // MARK: Generic scene commands

        case "createWindow":
            let windowToken = try scene.createWindow(
                identifier: request["identifier"] as? String,
                title: request["title"] as? String,
                width: request["width"] as? Double ?? 480,
                height: request["height"] as? Double ?? 360,
                styleNames: request["styles"] as? [String],
                kind: request["kind"] as? String ?? "window"
            )
            return ["windowToken": windowToken]
        case "addControl":
            try scene.addControl(
                kind: try requiredString("kind", in: request),
                identifier: try requiredString("identifier", in: request),
                windowTokenOrIdentifier: request["windowToken"] as? String,
                parentIdentifier: request["parentIdentifier"] as? String,
                frame: try optionalFrame(in: request),
                properties: request["properties"] as? [String: Any] ?? [:]
            )
            return [:]
        case "get":
            let value = try scene.value(forKey: try requiredString("key", in: request), identifier: try requiredString("identifier", in: request))
            return ["value": value]
        case "set":
            guard let value = request["value"] else { throw FixtureSceneError.missingParameter("value") }
            try scene.setValue(value, forKey: try requiredString("key", in: request), identifier: try requiredString("identifier", in: request))
            return [:]
        case "perform":
            try scene.perform(action: try requiredString("action", in: request), identifier: try requiredString("identifier", in: request))
            return [:]
        case "setAccessibility":
            guard let value = request["value"] else { throw FixtureSceneError.missingParameter("value") }
            try scene.setAccessibility(
                attribute: try requiredString("attribute", in: request),
                value: value,
                identifier: try requiredString("identifier", in: request)
            )
            return [:]
        case "presentSheet":
            let sheetToken = try scene.presentSheet(
                parentTokenOrIdentifier: try requiredString("parent", in: request),
                identifier: try requiredString("identifier", in: request),
                title: request["title"] as? String
            )
            return ["windowToken": sheetToken]
        case "endSheet":
            try scene.endSheet(identifier: try requiredString("identifier", in: request))
            return [:]
        case "startModal":
            try scene.startModalSession(tokenOrIdentifier: try requiredString("identifier", in: request))
            return [:]
        case "stopModal":
            scene.stopModalSession()
            return [:]
        case "isModalSessionRunning":
            return ["value": NSApp.modalWindow != nil]
        case "application":
            return try scene.performApplicationOperation(try requiredString("operation", in: request))
        case "installMenu":
            scene.installMenu(
                menuBarTitle: try requiredString("menuBarTitle", in: request),
                itemTitle: try requiredString("itemTitle", in: request),
                itemEnabled: request["itemEnabled"] as? Bool ?? true,
                countsSelections: request["countsSelections"] as? Bool ?? false
            )
            return [:]
        case "appendMenuItem":
            try scene.appendMenuItem(menuBarTitle: try requiredString("menuBarTitle", in: request), itemTitle: try requiredString("itemTitle", in: request))
            return [:]
        case "insertRootMenu":
            scene.insertRootMenu(title: try requiredString("title", in: request), itemTitle: try requiredString("itemTitle", in: request))
            return [:]
        case "menuSelectionCount":
            return ["value": try scene.menuSelectionCount(menuBarTitle: try requiredString("menuBarTitle", in: request))]
        case "events":
            return ["events": scene.eventLog]
        case "clearEvents":
            scene.clearEventLog()
            return [:]
        case "quit":
            // exit() directly: the main queue may not be drained (e.g. during a modal session).
            exit(0)
        default:
            throw FixtureSceneError.unsupportedAction(action: command, target: "control channel")
        }
    }

    private func requiredString(_ name: String, in request: [String: Any]) throws -> String {
        guard let value = request[name] as? String, !value.isEmpty else { throw FixtureSceneError.missingParameter(name) }
        return value
    }

    private func optionalFrame(in request: [String: Any]) throws -> NSRect? {
        guard let frameValue = request["frame"] else { return nil }
        guard let frameParts = frameValue as? [Double], frameParts.count == 4 else { throw FixtureSceneError.invalidValue(key: "frame") }
        return NSRect(x: frameParts[0], y: frameParts[1], width: frameParts[2], height: frameParts[3])
    }
}

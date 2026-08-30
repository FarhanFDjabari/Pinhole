//
//  MenuContent.swift
//  What drops down from the menu bar icon. Quick controls only — the window
//  behind "Open Control Panel" carries the preview and the full source list.
//

import AppKit
import SwiftUI

struct MenuContent: View {
    @ObservedObject var controller: DaemonController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(headline)

        if let error = controller.lastError {
            Text(error)
        }

        Divider()

        Button("Open Control Panel…") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: SimCamMenuBarApp.controlPanelID)
        }
        .keyboardShortcut("o")

        Button(controller.isRunning ? "Stop" : "Start") { controller.toggle() }
            .keyboardShortcut("s")

        Divider()

        Menu("Source: \(controller.feed.label)") {
            Button("Test Pattern") { controller.feed = .pattern }
            Button("Mac Camera") { controller.feed = .webcam(device: nil) }

            if controller.devices.count > 1 {
                Divider()
                ForEach(controller.devices, id: \.self) { device in
                    Button(device) { controller.feed = .webcam(device: device) }
                }
            }
        }

        Menu("Frame Rate: \(controller.fps) fps") {
            ForEach([15, 24, 30, 60], id: \.self) { rate in
                Button("\(rate) fps") { controller.fps = rate }
            }
        }

        Divider()

        Button("Copy SIMCAM_SOURCE=network") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("network", forType: .string)
        }

        Divider()

        Button("Quit SimCam") {
            controller.stop()
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private var headline: String {
        guard controller.isRunning else { return "Stopped" }
        let clients = controller.clientCount == 1 ? "1 client" : "\(controller.clientCount) clients"
        return "\(controller.status) · :\(DaemonController.port) · \(clients)"
    }
}

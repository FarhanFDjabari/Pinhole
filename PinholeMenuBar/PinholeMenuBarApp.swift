//
//  PinholeMenuBarApp.swift
//  Menu bar front end for pinholed — start/stop the feed the iOS Simulator
//  reads, switch sources, and watch what is going out.
//

import SwiftUI

@main
struct PinholeMenuBarApp: App {
    @StateObject private var controller = DaemonController()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(controller: controller)
        } label: {
            Image(systemName: controller.isRunning ? "camera.aperture" : "circle.dotted")
        }
        .menuBarExtraStyle(.menu)

        Window("Pinhole", id: Self.controlPanelID) {
            ControlPanelView(controller: controller)
        }
        .windowResizability(.contentMinSize)
        .defaultPosition(.center)
    }

    static let controlPanelID = "control-panel"
}

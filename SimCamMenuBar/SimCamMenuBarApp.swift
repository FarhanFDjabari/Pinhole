//
//  SimCamMenuBarApp.swift
//  Menu bar front end for simcamd — start/stop the feed the iOS Simulator
//  reads, switch sources, and watch what is going out.
//

import SwiftUI

@main
struct SimCamMenuBarApp: App {
    @StateObject private var controller = DaemonController()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(controller: controller)
        } label: {
            Image(systemName: controller.isRunning ? "video.fill" : "video.slash")
        }
        .menuBarExtraStyle(.menu)

        Window("SimCam", id: Self.controlPanelID) {
            ControlPanelView(controller: controller)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }

    static let controlPanelID = "control-panel"
}

//
//  ControlPanelView.swift
//  The window behind "Open Control Panel" — live preview of the outgoing feed,
//  source picker, and diagnostics.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ControlPanelView: View {
    @ObservedObject var controller: DaemonController
    @StateObject private var preview = PreviewClient()

    @State private var qrPayload = "https://simcam.local"
    @State private var diagnostics: String?

    var body: some View {
        VStack(spacing: 16) {
            statusBar
            previewArea
            sourcePicker
            formatRow
            footer
        }
        .padding(20)
        .padding(.top, 8)
        .frame(minWidth: 520, minHeight: 660)
        .onAppear {
            preview.start(port: DaemonController.port)
            if case .qr(let payload) = controller.feed { qrPayload = payload }
        }
        .onDisappear { preview.stop() }
    }

    // MARK: - Status

    private var statusBar: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(controller.isRunning ? (controller.clientCount > 0 ? .green : .yellow) : .secondary)
                .frame(width: 10, height: 10)

            VStack(alignment: .leading, spacing: 2) {
                Text(controller.isRunning ? controller.status : "Stopped")
                    .font(.headline)
                // Interpolating Int into Text applies grouping separators —
                // "47,009" is not a port number.
                Text(verbatim: "127.0.0.1:\(DaemonController.port) · \(controller.clientCount) client\(controller.clientCount == 1 ? "" : "s") · \(controller.framesSent) frames sent")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(controller.isRunning ? "Stop" : "Start") { controller.toggle() }
                .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Preview

    private var previewArea: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10).fill(.black)

            if let frame = preview.frame {
                Image(nsImage: frame)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            } else {
                VStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(controller.isRunning ? "Waiting for frames…" : "Feed stopped")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if preview.frame != nil {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Text(String(format: "%.0f fps", preview.measuredFPS))
                            .font(.caption.monospacedDigit())
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.black.opacity(0.6), in: Capsule())
                            .foregroundStyle(.white)
                            .padding(8)
                    }
                }
            }
        }
        .frame(height: 260)
    }

    // MARK: - Sources

    private var sourcePicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Source").font(.headline)

            row(title: "Test Pattern", subtitle: "Colour bars. No camera, no setup.",
                icon: "tv", isActive: controller.feed == .pattern) {
                controller.feed = .pattern
            }

            row(title: "Mac Camera", subtitle: controller.devices.first ?? "No camera found",
                icon: "camera.fill", isActive: controller.feed.needsCamera) {
                controller.feed = .webcam(device: nil)
            }

            if controller.devices.count > 1 {
                Picker("Camera", selection: cameraSelection) {
                    ForEach(controller.devices, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.menu)
                .padding(.leading, 34)
            }

            Divider()

            row(title: "Video File", subtitle: fileSubtitle(video: true),
                icon: "film", isActive: isVideo) { pickFile(video: true) }

            row(title: "Image", subtitle: fileSubtitle(video: false),
                icon: "photo", isActive: isStill) { pickFile(video: false) }

            HStack(spacing: 8) {
                Image(systemName: "qrcode").frame(width: 26)
                TextField("QR payload", text: $qrPayload)
                    .textFieldStyle(.roundedBorder)
                Button("Use") { controller.feed = .qr(qrPayload) }
                    .disabled(qrPayload.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            if let error = controller.lastError {
                Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    private func row(title: String, subtitle: String, icon: String,
                     isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon).frame(width: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if isActive { Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Format

    private var formatRow: some View {
        HStack(spacing: 20) {
            Picker("Resolution", selection: $controller.resolution) {
                ForEach(DaemonController.Resolution.allCases) { Text($0.rawValue).tag($0) }
            }
            .frame(maxWidth: 210)

            Picker("Frame rate", selection: $controller.fps) {
                ForEach([15, 24, 30, 60], id: \.self) { Text("\($0) fps").tag($0) }
            }
            .frame(maxWidth: 180)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 10) {
            HStack {
                Button("Run Diagnostics") { diagnostics = controller.diagnostics() }
                Button("Refresh Cameras") { controller.refreshDevices() }
                Spacer()
                Button("Copy SIMCAM_SOURCE=network") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("network", forType: .string)
                }
            }

            if let diagnostics {
                ScrollView {
                    Text(diagnostics)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 150)
                .padding(8)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    // MARK: - Helpers

    private var isVideo: Bool { if case .video = controller.feed { return true }; return false }
    private var isStill: Bool { if case .still = controller.feed { return true }; return false }

    private var cameraSelection: Binding<String> {
        Binding(
            get: {
                if case .webcam(let device) = controller.feed, let device { return device }
                return controller.devices.first ?? ""
            },
            set: { controller.feed = .webcam(device: $0) }
        )
    }

    private func fileSubtitle(video: Bool) -> String {
        switch controller.feed {
        case .video(let url) where video: return url.lastPathComponent
        case .still(let url) where !video: return url.lastPathComponent
        default: return video ? "Loop a movie file" : "Stream a still"
        }
    }

    private func pickFile(video: Bool) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = video ? [.movie, .video, .quickTimeMovie, .mpeg4Movie] : [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "Use"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        controller.feed = video ? .video(url) : .still(url)
    }
}

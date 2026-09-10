import Combine
import Foundation
import ReplayKit
import SwiftUI
import UIKit

/// Bug-report tooling lives in this overlay so the product screen remains untouched.
@MainActor
struct BugReportCaptureLayer<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var recorder = BugReportRecorder()
    @State private var hidesControlsForSnapshot = false

    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            content

            captureControls
                .padding(.horizontal, 16)
                .padding(.bottom, 92)
                .opacity(hidesControlsForSnapshot ? 0 : 1)
                .allowsHitTesting(!hidesControlsForSnapshot)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: recorder.phase.animationValue)
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background {
                recorder.stop()
            }
        }
    }

    @ViewBuilder
    private var captureControls: some View {
        VStack(spacing: 8) {
            if let message = recorder.statusMessage {
                Text(message)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(recorder.hasError ? Color.red : Color.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(.regularMaterial, in: Capsule())
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                    .accessibilityLabel(message)
            }

            switch recorder.phase {
            case .idle:
                startButton

            case .preparing:
                preparingControl

            case .recording(let startedAt):
                RecordingControl(startedAt: startedAt, stopAction: recorder.stop)

            case .stopping:
                stoppingControl
            }
        }
    }

    private var startButton: some View {
        Button(action: takeScreenshotAndStartRecording) {
            Label("Сделать скриншот", systemImage: "camera.viewfinder")
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .frame(minHeight: 50)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 1))
        }
        .buttonStyle(CaptureButtonStyle())
        .accessibilityHint("Создает снимок и начинает временную запись экрана приложения")
    }

    private var preparingControl: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)

            Text("Начинаем запись…")
                .font(.body.weight(.semibold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 18)
        .frame(minHeight: 50)
        .background(.regularMaterial, in: Capsule())
        .accessibilityElement(children: .combine)
    }

    private var stoppingControl: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)

            Text("Завершаем запись…")
                .font(.body.weight(.semibold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 18)
        .frame(minHeight: 50)
        .background(.regularMaterial, in: Capsule())
        .accessibilityElement(children: .combine)
    }

    private func takeScreenshotAndStartRecording() {
        guard recorder.prepare() else { return }

        hidesControlsForSnapshot = true

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 100_000_000)
            let screenshot = WindowSnapshotter.captureKeyWindow()
            hidesControlsForSnapshot = false
            recorder.start(with: screenshot)
        }
    }
}

private struct RecordingControl: View {
    let startedAt: Date
    let stopAction: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(Color.red)
                .frame(width: 10, height: 10)
                .accessibilityHidden(true)

            TimelineView(.periodic(from: startedAt, by: 1)) { context in
                Text("Запись · \(elapsedTime(at: context.date))")
                    .font(.body.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.primary)
            }

            Spacer(minLength: 8)

            Button(action: stopAction) {
                HStack(spacing: 7) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(Color.white)
                        .frame(width: 12, height: 12)

                    Text("Стоп")
                        .font(.body.weight(.semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .frame(minHeight: 44)
                .background(Color.red, in: Capsule())
            }
            .buttonStyle(CaptureButtonStyle())
            .accessibilityHint("Останавливает запись и сохраняет ее только во временных данных приложения")
        }
        .padding(.leading, 18)
        .padding(.trailing, 6)
        .frame(maxWidth: .infinity, minHeight: 56)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 1))
        .accessibilityElement(children: .contain)
    }

    private func elapsedTime(at date: Date) -> String {
        let elapsed = max(0, Int(date.timeIntervalSince(startedAt)))
        return String(format: "%02d:%02d", elapsed / 60, elapsed % 60)
    }
}

private struct CaptureButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(!reduceMotion && configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.82 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

@MainActor
final class BugReportRecorder: ObservableObject {
    enum Phase {
        case idle
        case preparing
        case recording(startedAt: Date)
        case stopping

        var animationValue: Int {
            switch self {
            case .idle: 0
            case .preparing: 1
            case .recording: 2
            case .stopping: 3
            }
        }
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var statusMessage: String?
    @Published private(set) var hasError = false

    private(set) var initialScreenshot: UIImage?
    private(set) var latestRecordingURL: URL?

    private let screenRecorder = RPScreenRecorder.shared()

    init() {
        removeStaleRecordings()
    }

    @discardableResult
    func prepare() -> Bool {
        guard case .idle = phase else { return false }
        statusMessage = nil
        hasError = false
        phase = .preparing
        return true
    }

    func start(with screenshot: UIImage?) {
        guard case .preparing = phase else { return }
        initialScreenshot = screenshot

        guard screenRecorder.isAvailable else {
            fail(with: "Запись экрана сейчас недоступна")
            return
        }

        screenRecorder.startRecording(withMicrophoneEnabled: false) { [weak self] error in
            Task { @MainActor in
                guard let self else { return }

                if let error {
                    self.fail(with: error.localizedDescription)
                    return
                }

                self.phase = .recording(startedAt: Date())
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            }
        }
    }

    func stop() {
        guard case .recording = phase else { return }
        phase = .stopping

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("bug-report-\(UUID().uuidString)")
            .appendingPathExtension("mp4")

        screenRecorder.stopRecording(withOutput: outputURL) { [weak self] error in
            Task { @MainActor in
                guard let self else { return }

                if let error {
                    try? FileManager.default.removeItem(at: outputURL)
                    self.fail(with: error.localizedDescription)
                    return
                }

                if let previousURL = self.latestRecordingURL {
                    try? FileManager.default.removeItem(at: previousURL)
                }

                self.latestRecordingURL = outputURL
                self.phase = .idle
                self.hasError = false
                self.statusMessage = "Запись готова и не добавлена в Фото"
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            }
        }
    }

    private func fail(with message: String) {
        phase = .idle
        hasError = true
        statusMessage = message
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }

    private func removeStaleRecordings() {
        let directory = FileManager.default.temporaryDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return }

        for file in files where file.lastPathComponent.hasPrefix("bug-report-") {
            try? FileManager.default.removeItem(at: file)
        }
    }
}

@MainActor
private enum WindowSnapshotter {
    static func captureKeyWindow() -> UIImage? {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }),
              let window = scene.windows.first(where: \.isKeyWindow) else {
            return nil
        }

        let format = UIGraphicsImageRendererFormat()
        format.scale = window.screen.scale

        return UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
    }
}

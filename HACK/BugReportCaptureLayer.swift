import Combine
import Foundation
import ReplayKit
import SwiftUI
import UIKit

/// Bug-report tooling is an overlay so the approved product screen remains untouched.
@MainActor
struct BugReportCaptureLayer<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var recorder = BugReportRecorder()

    @State private var pendingScreenshot: UIImage?
    @State private var isCapturePalettePresented = false
    @State private var reportSession: BugReportSession?
    @State private var isReportPresented = false
    @State private var isReportMinimized = false
    @State private var isReportDiscardPresented = false
    @State private var isWaitingForRecording = false

    private let reporterUsername = "@e.m.usov"
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            content

            if shouldShowCapturePalette {
                CaptureSidePalette(
                    phase: recorder.phase,
                    canSendScreenshot: pendingScreenshot != nil,
                    sendScreenshotAction: sendPendingScreenshot,
                    startRecordingAction: beginRecording,
                    stopRecordingAction: finishRecording
                )
                .padding(.trailing, 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                .transition(.move(edge: .trailing).combined(with: .opacity))
                .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: recorder.phase.animationValue)
            }

            if recorder.hasError, let message = recorder.statusMessage {
                Text(message)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Color.red)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 92)
                    .accessibilityLabel(message)
            }

            if let reportSession, isReportMinimized {
                BugReportIsland(
                    session: reportSession,
                    onExpand: expandReport,
                    onClose: { isReportDiscardPresented = true }
                )
                .padding(.horizontal, 12)
                .padding(.bottom, 84)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: isReportMinimized)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: shouldShowCapturePalette)
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.userDidTakeScreenshotNotification)) { _ in
            handleSystemScreenshot()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background {
                recorder.stop()
            }
        }
        .confirmationDialog(
            "Удалить черновик?",
            isPresented: $isReportDiscardPresented,
            titleVisibility: .visible
        ) {
            Button("Удалить", role: .destructive, action: closeReport)
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Комментарий и подготовленные вложения будут удалены.")
        }
        .sheet(isPresented: $isReportPresented, onDismiss: reportSheetDidDismiss) {
            if let reportSession {
                BugReportFlowSheet(
                    session: reportSession,
                    username: reporterUsername,
                    onMinimize: minimizeReport,
                    onClose: closeReport
                )
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            }
        }
    }

    private var shouldShowCapturePalette: Bool {
        isCapturePalettePresented || recorder.phase.animationValue != 0
    }

    private func handleSystemScreenshot() {
        guard case .idle = recorder.phase,
              !isCapturePalettePresented,
              reportSession == nil else { return }

        Task { @MainActor in
            // UIKit posts the notification after the system has made the screenshot.
            try? await Task.sleep(nanoseconds: 250_000_000)
            pendingScreenshot = WindowSnapshotter.captureKeyWindow()
            isCapturePalettePresented = true
        }
    }

    private func sendPendingScreenshot() {
        guard let pendingScreenshot else { return }
        openReport(with: BugReportAttachment(screenshot: pendingScreenshot))
    }

    private func openReport(with attachment: BugReportAttachment?) {
        guard let attachment else { return }
        isCapturePalettePresented = false
        pendingScreenshot = nil

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 180_000_000)
            reportSession = BugReportSession(attachment: attachment)
            isReportMinimized = false
            isReportPresented = true
        }
    }

    private func beginRecording() {
        isCapturePalettePresented = false
        isWaitingForRecording = true

        guard recorder.prepare() else {
            isWaitingForRecording = false
            return
        }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 120_000_000)
            recorder.start(with: pendingScreenshot)
            pendingScreenshot = nil
        }
    }

    private func finishRecording() {
        recorder.stop { url in
            guard isWaitingForRecording else { return }
            isWaitingForRecording = false

            guard let url else { return }
            openReport(with: BugReportAttachment(videoAt: url))
        }
    }

    private func minimizeReport() {
        guard reportSession != nil else { return }
        isReportMinimized = true
        isReportPresented = false
    }

    private func expandReport() {
        guard reportSession != nil else { return }
        isReportMinimized = false
        isReportPresented = true
    }

    private func closeReport() {
        isReportMinimized = false
        isReportPresented = false
        reportSession = nil
    }

    private func reportSheetDidDismiss() {
        guard reportSession != nil else { return }
        isReportMinimized = true
    }
}

@MainActor
private struct CaptureSidePalette: View {
    let phase: BugReportRecorder.Phase
    let canSendScreenshot: Bool
    let sendScreenshotAction: () -> Void
    let startRecordingAction: () -> Void
    let stopRecordingAction: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            switch phase {
            case .idle:
                sendScreenshotButton
                recordButton(action: startRecordingAction, symbol: .record)

            case .preparing:
                stateLabel("…")
                recordButton(action: {}, symbol: .progress)
                    .disabled(true)

            case .recording(let startedAt):
                TimelineView(.periodic(from: startedAt, by: 1)) { context in
                    stateLabel(elapsedTime(from: startedAt, at: context.date))
                }
                recordButton(action: stopRecordingAction, symbol: .stop)

            case .stopping:
                stateLabel("…")
                recordButton(action: {}, symbol: .progress)
                    .disabled(true)
            }
        }
        .padding(8)
        .frame(width: 72)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 32, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .stroke(Color.white.opacity(0.16), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.22), radius: 16, x: -4, y: 5)
        .accessibilityElement(children: .contain)
    }

    private var sendScreenshotButton: some View {
        Button(action: sendScreenshotAction) {
            Image(systemName: "paperplane.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Color.black)
                .frame(width: 52, height: 52)
                .background(Color.white, in: Circle())
        }
        .buttonStyle(CaptureButtonStyle())
        .disabled(!canSendScreenshot)
        .accessibilityLabel("Отправить снимок")
        .accessibilityHint("Открывает форму баг-репорта со снимком экрана")
    }

    private func recordButton(
        action: @escaping () -> Void,
        symbol: RecordingButtonSymbol
    ) -> some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(Color.red)

                switch symbol {
                case .record:
                    Circle()
                        .fill(Color.white)
                        .frame(width: 20, height: 20)

                case .stop:
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color.white)
                        .frame(width: 18, height: 18)

                case .progress:
                    ProgressView()
                        .tint(.white)
                }
            }
            .frame(width: 52, height: 52)
        }
        .buttonStyle(CaptureButtonStyle())
        .accessibilityLabel(recordingAccessibilityLabel(for: symbol))
        .accessibilityHint(recordingAccessibilityHint(for: symbol))
    }

    private func stateLabel(_ value: String) -> some View {
        Text(value)
            .font(.caption2.monospacedDigit().weight(.semibold))
            .foregroundStyle(.primary)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .frame(width: 52)
            .frame(minHeight: 44)
    }

    private func elapsedTime(from startedAt: Date, at date: Date) -> String {
        let elapsed = max(0, Int(date.timeIntervalSince(startedAt)))
        return String(format: "%02d:%02d", elapsed / 60, elapsed % 60)
    }

    private func recordingAccessibilityLabel(for symbol: RecordingButtonSymbol) -> String {
        switch symbol {
        case .record: "Записать экран"
        case .stop: "Остановить запись"
        case .progress: "Запись подготавливается"
        }
    }

    private func recordingAccessibilityHint(for symbol: RecordingButtonSymbol) -> String {
        switch symbol {
        case .record: "Начинает временную запись экрана"
        case .stop: "Останавливает запись и открывает форму отправки видео"
        case .progress: "Дождитесь завершения операции"
        }
    }

    private enum RecordingButtonSymbol {
        case record
        case stop
        case progress
    }
}

@MainActor
private final class BugReportSession: ObservableObject, Identifiable {
    enum Stage {
        case videoMarkup
        case report
    }

    let id = UUID()
    @Published var attachment: BugReportAttachment
    @Published var comment = ""
    @Published var stage: Stage

    init(attachment: BugReportAttachment) {
        self.attachment = attachment
        stage = attachment.isVideo ? .videoMarkup : .report
    }
}

private struct BugReportIsland: View {
    @ObservedObject var session: BugReportSession

    let onExpand: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Удалить черновик баг-репорта")

            Button(action: onExpand) {
                HStack(spacing: 10) {
                    Image(systemName: "ladybug.fill")
                        .foregroundStyle(.red)
                        .frame(width: 28, height: 28)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Баг-репорт")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.primary)

                        Text(summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 8)

                    Image(systemName: "chevron.up")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 44)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Развернуть баг-репорт")
            .accessibilityValue(summary)
        }
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, minHeight: 62)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(Color.primary.opacity(0.1), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.22), radius: 16, y: 7)
    }

    private var summary: String {
        switch session.stage {
        case .videoMarkup:
            return "Редактирование видео"
        case .report:
            if !session.comment.isEmpty {
                return "Комментарий сохранён"
            }

            if session.attachment.isVideo {
                let count = session.attachment.annotations.count
                return count == 0 ? "Видео готово к отправке" : "Видео · \(count) кадров"
            }

            return "Снимок готов к отправке"
        }
    }
}

private struct BugReportFlowSheet: View {
    @ObservedObject var session: BugReportSession

    let username: String
    let onMinimize: () -> Void
    let onClose: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            switch session.stage {
            case .videoMarkup:
                VideoBugMarkupEditor(
                    videoURL: session.attachment.editingVideoURL,
                    existingAnnotations: session.attachment.annotations,
                    onCancel: cancelVideoMarkup,
                    onComplete: { result in
                        session.attachment = session.attachment.adding(
                            annotatedVideoURL: result.videoURL,
                            annotations: result.annotations
                        )
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                            session.stage = .report
                        }
                    }
                )

            case .report:
                BugReportSubmissionSheet(
                    attachment: session.attachment,
                    username: username,
                    comment: $session.comment,
                    onEditVideo: session.attachment.isVideo ? {
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                            session.stage = .videoMarkup
                        }
                    } : nil,
                    onMinimize: onMinimize,
                    onDismiss: onClose
                )
            }
        }
        .interactiveDismissDisabled(session.stage == .videoMarkup)
    }

    private func cancelVideoMarkup() {
        if !session.attachment.annotations.isEmpty {
            session.stage = .report
        } else {
            onClose()
        }
    }
}

private struct BugReportSubmissionSheet: View {
    let attachment: BugReportAttachment
    let username: String
    @Binding var comment: String
    let onEditVideo: (() -> Void)?
    let onMinimize: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Вложение") {
                    attachmentPreview
                }

                Section("Автор") {
                    Label(username, systemImage: "person.crop.circle.fill")
                        .foregroundStyle(.primary)
                }

                Section("Комментарий") {
                    ZStack(alignment: .topLeading) {
                        if comment.isEmpty {
                            Text("Что произошло?")
                                .foregroundStyle(.tertiary)
                                .padding(.top, 8)
                                .padding(.leading, 5)
                                .accessibilityHidden(true)
                        }

                        TextEditor(text: $comment)
                            .frame(minHeight: 104)
                            .accessibilityLabel("Комментарий к баг-репорту")
                    }
                }

                Section {
                    ShareLink(
                        items: attachment.fileURLs,
                        subject: Text("Баг-репорт от \(username)"),
                        message: Text(shareMessage)
                    ) {
                        Label("Отправить", systemImage: "paperplane.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
                    .accessibilityHint("Открывает системное меню для отправки видео и отмеченных кадров")
                }
            }
            .navigationTitle("Отправить баг-репорт")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        onDismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Закрыть")
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: onMinimize) {
                        Image(systemName: "chevron.down")
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Свернуть баг-репорт")
                }
            }
        }
    }

    @ViewBuilder
    private var attachmentPreview: some View {
        switch attachment.kind {
        case .screenshot(let image):
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxHeight: 130)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityLabel("Снимок экрана")

        case .video:
            VStack(alignment: .leading, spacing: 12) {
                Label(
                    attachment.annotations.isEmpty ? "Запись экрана" : "Видео с пометками",
                    systemImage: "video.fill"
                )
                    .foregroundStyle(.primary)

                if !attachment.annotations.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 10) {
                            ForEach(Array(attachment.annotations.enumerated()), id: \.element.id) { index, annotation in
                                VStack(alignment: .leading, spacing: 6) {
                                    Image(uiImage: annotation.preview)
                                        .resizable()
                                        .scaledToFit()
                                        .frame(width: 150, height: 150)
                                        .background(Color.black)
                                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                                    Text("\(index + 1) · \(formattedTime(annotation.time))")
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel("Отмеченный кадр \(index + 1) на \(formattedTime(annotation.time))")
                            }
                        }
                    }

                    Label(
                        "\(attachment.annotations.count) \(attachment.markerCountWord)",
                        systemImage: "pencil.and.outline"
                    )
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }

                if let onEditVideo {
                    Button("Изменить пометки", action: onEditVideo)
                }
            }
        }
    }

    private var shareMessage: String {
        var parts = [username]

        if !comment.isEmpty {
            parts.append(comment)
        }

        if !attachment.annotations.isEmpty {
            let moments = attachment.annotations
                .map { formattedTime($0.time) }
                .joined(separator: ", ")
            parts.append("Отмеченные моменты: \(moments)")
        }

        return parts.joined(separator: "\n\n")
    }

    private func formattedTime(_ value: Double) -> String {
        let clamped = max(0, value)
        let minutes = Int(clamped) / 60
        let seconds = clamped.truncatingRemainder(dividingBy: 60)
        return String(format: "%02d:%04.1f", minutes, seconds)
    }
}

private struct BugReportAttachment: Identifiable {
    enum Kind {
        case screenshot(UIImage)
        case video
    }

    let id = UUID()
    let kind: Kind
    let fileURL: URL
    let annotations: [VideoFrameAnnotation]
    let sourceVideoURL: URL?

    var isVideo: Bool {
        if case .video = kind { return true }
        return false
    }

    var fileURLs: [URL] {
        [fileURL] + annotations.map(\.fileURL)
    }

    var editingVideoURL: URL {
        sourceVideoURL ?? fileURL
    }

    var markerCountWord: String {
        let value = annotations.count % 100
        if (11...14).contains(value) { return "отмеченных кадров" }

        switch annotations.count % 10 {
        case 1: return "отмеченный кадр"
        case 2...4: return "отмеченных кадра"
        default: return "отмеченных кадров"
        }
    }

    init?(screenshot: UIImage) {
        guard let data = screenshot.pngData() else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bug-report-\(UUID().uuidString)")
            .appendingPathExtension("png")

        do {
            try data.write(to: url, options: .atomic)
            kind = .screenshot(screenshot)
            fileURL = url
            annotations = []
            sourceVideoURL = nil
        } catch {
            return nil
        }
    }

    init(videoAt url: URL) {
        kind = .video
        fileURL = url
        annotations = []
        sourceVideoURL = url
    }

    private init(
        videoAt url: URL,
        sourceVideoURL: URL,
        annotations: [VideoFrameAnnotation]
    ) {
        kind = .video
        fileURL = url
        self.annotations = annotations
        self.sourceVideoURL = sourceVideoURL
    }

    func adding(
        annotatedVideoURL: URL,
        annotations: [VideoFrameAnnotation]
    ) -> BugReportAttachment {
        let sourceURL = sourceVideoURL ?? fileURL
        if fileURL != sourceURL, fileURL != annotatedVideoURL {
            try? FileManager.default.removeItem(at: fileURL)
        }
        return BugReportAttachment(
            videoAt: annotatedVideoURL,
            sourceVideoURL: sourceURL,
            annotations: annotations
        )
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
        removeStaleAttachments()
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

        screenRecorder.isMicrophoneEnabled = false
        screenRecorder.startRecording { [weak self] error in
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

    func stop(completion: @escaping (URL?) -> Void = { _ in }) {
        guard case .recording = phase else {
            completion(nil)
            return
        }

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
                    completion(nil)
                    return
                }

                if let previousURL = self.latestRecordingURL {
                    try? FileManager.default.removeItem(at: previousURL)
                }

                self.latestRecordingURL = outputURL
                self.phase = .idle
                self.hasError = false
                self.statusMessage = "Запись готова к отправке"
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                completion(outputURL)
            }
        }
    }

    private func fail(with message: String) {
        phase = .idle
        hasError = true
        statusMessage = message
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }

    private func removeStaleAttachments() {
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

import AVFoundation
import AVKit
import Combine
import Foundation
import PencilKit
import PhotosUI
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
    @State private var pendingAdditionalScreenshots: [UIImage] = []
    @State private var isCapturePalettePresented = false
    @State private var reportSession: BugReportSession?
    @State private var isReportPresented = false
    @State private var isReportMinimized = false
    @State private var isReportDiscardPresented = false
    @State private var isWaitingForRecording = false
    @State private var successToastID: UUID?

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

            if successToastID != nil {
                BugReportSuccessToast()
                    .padding(.horizontal, 20)
                    .padding(.top, 68)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(10)
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
                    onClose: closeReport,
                    onSubmitted: reportDidSubmit
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
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let screenshot = WindowSnapshotter.captureKeyWindow() else { return }

            if let reportSession {
                reportSession.addScreenshot(screenshot)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } else if isCapturePalettePresented || recorder.phase.animationValue != 0 {
                pendingAdditionalScreenshots.append(screenshot)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } else {
                pendingScreenshot = screenshot
                isCapturePalettePresented = true
            }
        }
    }

    private func sendPendingScreenshot() {
        guard let pendingScreenshot else { return }
        openReport(with: BugReportAttachment(screenshot: pendingScreenshot))
    }

    private func openReport(with attachment: BugReportAttachment?) {
        guard let attachment else { return }
        let queuedScreenshots = pendingAdditionalScreenshots
        isCapturePalettePresented = false
        pendingScreenshot = nil
        pendingAdditionalScreenshots = []

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 180_000_000)
            let session = BugReportSession(attachment: attachment)
            queuedScreenshots.forEach(session.addScreenshot)
            reportSession = session
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

    private func reportDidSubmit() {
        closeReport()
        let toastID = UUID()
        withAnimation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.86)) {
            successToastID = toastID
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_800_000_000)
            guard successToastID == toastID else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                successToastID = nil
            }
        }
    }
}

private struct BugReportSuccessToast: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(Color.green)
                .accessibilityHidden(true)

            Text("Баг отправился к разработчикам")
                .font(.headline)
                .foregroundStyle(.primary)

            Text("Следить за решением проблемы\nможно в канале ~mb-bugs-prod")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
        .frame(maxWidth: 360)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isStaticText)
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
    @Published private(set) var screenshots: [BugReportScreenshot] = []
    @Published var comment = ""
    @Published var category = BugReportCategory.bug
    @Published var stage: Stage
    private var insertedAnnotationIDs: Set<UUID> = []

    init(attachment: BugReportAttachment) {
        self.attachment = attachment
        stage = attachment.isVideo ? .videoMarkup : .report
    }

    var fileURLs: [URL] {
        attachment.fileURLs + screenshots.map(\.fileURL)
    }

    func addScreenshot(_ image: UIImage) {
        guard let screenshot = BugReportScreenshot(image: image) else { return }
        screenshots.append(screenshot)
    }

    func applyMarkupToPrimaryScreenshot(_ result: ScreenshotMarkupResult) {
        guard let updatedAttachment = attachment.adding(screenshotMarkup: result) else { return }
        let previousURL = attachment.fileURL
        attachment = updatedAttachment
        if previousURL != attachment.fileURL {
            try? FileManager.default.removeItem(at: previousURL)
        }
    }

    func applyMarkup(_ result: ScreenshotMarkupResult, to screenshotID: UUID) {
        guard let index = screenshots.firstIndex(where: { $0.id == screenshotID }),
              let updatedScreenshot = screenshots[index].adding(markup: result) else { return }
        let previousURL = screenshots[index].fileURL
        screenshots[index] = updatedScreenshot
        if previousURL != updatedScreenshot.fileURL {
            try? FileManager.default.removeItem(at: previousURL)
        }
    }

    func appendAnnotationTimecodesIfNeeded() async {
        guard attachment.isVideo, !attachment.annotations.isEmpty else { return }

        let asset = AVURLAsset(url: attachment.fileURL)
        guard let loadedDuration = try? await asset.load(.duration),
              loadedDuration.seconds.isFinite,
              loadedDuration.seconds > 10 else { return }

        let newAnnotations = attachment.annotations
            .filter { !insertedAnnotationIDs.contains($0.id) }
            .sorted { $0.time < $1.time }
        guard !newAnnotations.isEmpty else { return }

        let timecodeLines = newAnnotations
            .map { "\(Self.formattedTime($0.time)) — " }
            .joined(separator: "\n")
        let prompt = "Моменты с пометками:\n\(timecodeLines)"
        comment += comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? prompt
            : "\n\n\(prompt)"
        insertedAnnotationIDs.formUnion(newAnnotations.map(\.id))
    }

    private static func formattedTime(_ value: Double) -> String {
        let clamped = max(0, value.isFinite ? value : 0)
        return String(format: "%02d:%02d", Int(clamped) / 60, Int(clamped) % 60)
    }
}

private struct BugReportIsland: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var session: BugReportSession
    @GestureState private var upwardDrag: CGFloat = 0

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
        .offset(y: reduceMotion ? 0 : upwardDrag * 0.18)
        .contentShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .simultaneousGesture(expandGesture)
    }

    private var expandGesture: some Gesture {
        DragGesture(minimumDistance: 10)
            .updating($upwardDrag) { value, state, _ in
                state = min(0, value.translation.height)
            }
            .onEnded { value in
                let passedDistance = value.translation.height < -28
                let passedVelocity = value.predictedEndTranslation.height < -64
                guard passedDistance || passedVelocity else { return }
                UISelectionFeedbackGenerator().selectionChanged()
                onExpand()
            }
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
    let onSubmitted: () -> Void

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
                    session: session,
                    username: username,
                    comment: $session.comment,
                    onEditVideo: session.attachment.isVideo ? {
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                            session.stage = .videoMarkup
                        }
                    } : nil,
                    onMinimize: onMinimize,
                    onDismiss: onClose,
                    onSubmitted: onSubmitted
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var session: BugReportSession
    let username: String
    @Binding var comment: String
    let onEditVideo: (() -> Void)?
    let onMinimize: () -> Void
    let onDismiss: () -> Void
    let onSubmitted: () -> Void

    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var isVideoPreviewPresented = false
    @State private var screenshotEditTarget: ScreenshotEditTarget?
    @State private var isKeyboardVisible = false

    private var attachment: BugReportAttachment {
        session.attachment
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    reportSection("Вложения") {
                        attachmentPreview
                    }

                    reportSection("Автор") {
                        Label(username, systemImage: "person.crop.circle.fill")
                            .font(.body)
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 16)
                            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                            .background(
                                Color(uiColor: .secondarySystemGroupedBackground),
                                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                            )
                    }

                    reportSection("Комментарий") {
                        VStack(alignment: .leading, spacing: 12) {
                            categoryChips

                            TextField("Что произошло?", text: $comment, axis: .vertical)
                                .font(.body)
                                .lineLimit(6...)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(14)
                                .frame(maxWidth: .infinity, minHeight: 136, alignment: .topLeading)
                                .background(
                                    Color(uiColor: .secondarySystemGroupedBackground),
                                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                                )
                                .accessibilityLabel("Комментарий к баг-репорту")
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if !isKeyboardVisible {
                    sendBar
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: isKeyboardVisible)
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                isKeyboardVisible = true
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                isKeyboardVisible = false
            }
            .onChange(of: selectedPhotoItems) { _, items in
                importScreenshots(from: items)
            }
            .task(id: attachment.id) {
                await session.appendAnnotationTimecodesIfNeeded()
            }
            .navigationTitle("Отправить баг-репорт")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        onDismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.body.weight(.semibold))
                            .frame(width: 44, height: 44)
                            .background(.regularMaterial, in: Circle())
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Закрыть")
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: onMinimize) {
                        Image(systemName: "chevron.down")
                            .font(.body.weight(.semibold))
                            .frame(width: 44, height: 44)
                            .background(.regularMaterial, in: Circle())
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Свернуть баг-репорт")
                }
            }
        }
        .fullScreenCover(isPresented: $isVideoPreviewPresented) {
            VideoPreviewScreen(videoURL: attachment.fileURL)
        }
        .fullScreenCover(item: $screenshotEditTarget) { target in
            ScreenshotMarkupEditor(
                image: target.image,
                existingDrawing: target.drawing,
                onCancel: { screenshotEditTarget = nil },
                onComplete: { result in
                    applyScreenshotMarkup(result, to: target.location)
                    screenshotEditTarget = nil
                }
            )
        }
    }

    private func reportSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)

            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var attachmentPreview: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    switch attachment.kind {
                    case .screenshot(let image):
                        screenshotCard(
                            image: image,
                            title: "Снимок 1",
                            action: editPrimaryScreenshot
                        )

                    case .video:
                        VideoAttachmentPreviewCard(
                            videoURL: attachment.fileURL,
                            annotations: attachment.annotations,
                            action: { isVideoPreviewPresented = true }
                        )
                    }

                    ForEach(Array(session.screenshots.enumerated()), id: \.element.id) { index, screenshot in
                        screenshotCard(
                            image: screenshot.image,
                            title: "Снимок \(index + (attachment.isVideo ? 1 : 2))",
                            action: { editScreenshot(screenshot) }
                        )
                    }

                    PhotosPicker(
                        selection: $selectedPhotoItems,
                        maxSelectionCount: 20,
                        matching: .images
                    ) {
                        VStack(spacing: 10) {
                            Image(systemName: "plus")
                                .font(.title.bold())

                            Text("Добавить файл")
                                .font(.headline)
                                .multilineTextAlignment(.center)
                        }
                        .foregroundStyle(Color.blue)
                        .frame(width: 156, height: 278)
                        .background(Color(uiColor: .secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Добавить снимок")
                    .accessibilityHint("Открывает медиатеку для выбора изображений")
                }
            }

            if attachment.isVideo, let onEditVideo {
                Button("Изменить пометки", action: onEditVideo)
            }
        }
    }

    private func screenshotCard(
        image: UIImage,
        title: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .bottomTrailing) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 156, height: 242)
                        .background(Color.black)

                    Image(systemName: "pencil")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.white)
                        .frame(width: 32, height: 32)
                        .background(.regularMaterial, in: Circle())
                        .padding(8)
                }

                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
            }
            .frame(width: 156, height: 278, alignment: .topLeading)
            .background(Color(uiColor: .secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), изменить пометки")
    }

    private var sendBar: some View {
        Button(action: onSubmitted) {
            Text("Отправить")
                .font(.headline)
                .foregroundStyle(Color.white)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .tint(.blue)
        .accessibilityHint("Отправляет баг-репорт разработчикам")
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial)
    }

    private var categoryChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(BugReportCategory.allCases) { category in
                    Button {
                        session.category = category
                    } label: {
                        Text(category.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(session.category == category ? Color.white : Color.primary)
                            .padding(.horizontal, 16)
                            .frame(minHeight: 44)
                            .background(
                                session.category == category
                                    ? Color.blue
                                    : Color(uiColor: .secondarySystemBackground),
                                in: Capsule()
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(session.category == category ? .isSelected : [])
                }
            }
        }
        .accessibilityLabel("Категория баг-репорта")
    }

    private func editPrimaryScreenshot() {
        guard let image = attachment.editingScreenshotImage else { return }
        screenshotEditTarget = ScreenshotEditTarget(
            location: .primary,
            image: image,
            drawing: attachment.screenshotDrawing ?? PKDrawing()
        )
    }

    private func editScreenshot(_ screenshot: BugReportScreenshot) {
        screenshotEditTarget = ScreenshotEditTarget(
            location: .supplemental(screenshot.id),
            image: screenshot.sourceImage,
            drawing: screenshot.drawing ?? PKDrawing()
        )
    }

    private func applyScreenshotMarkup(
        _ result: ScreenshotMarkupResult,
        to location: ScreenshotEditTarget.Location
    ) {
        switch location {
        case .primary:
            session.applyMarkupToPrimaryScreenshot(result)
        case .supplemental(let screenshotID):
            session.applyMarkup(result, to: screenshotID)
        }
    }

    private func importScreenshots(from items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }

        Task { @MainActor in
            for item in items {
                guard let data = try? await item.loadTransferable(type: Data.self),
                      let image = UIImage(data: data) else { continue }
                session.addScreenshot(image)
            }
            selectedPhotoItems = []
        }
    }
}

private enum BugReportCategory: String, CaseIterable, Identifiable {
    case bug
    case badExperience
    case advertising

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bug: "Нашёлся баг"
        case .badExperience: "Плохой опыт"
        case .advertising: "Реклама"
        }
    }
}

private struct ScreenshotEditTarget: Identifiable {
    enum Location {
        case primary
        case supplemental(UUID)
    }

    let id = UUID()
    let location: Location
    let image: UIImage
    let drawing: PKDrawing
}

private struct VideoAttachmentPreviewCard: View {
    let videoURL: URL
    let annotations: [VideoFrameAnnotation]
    let action: () -> Void

    @State private var poster: UIImage?

    var body: some View {
        Button(action: action) {
            ZStack {
                Color.black

                if let poster {
                    Image(uiImage: poster)
                        .resizable()
                        .scaledToFit()
                } else {
                    ProgressView()
                        .tint(.white)
                }

                Circle()
                    .fill(.regularMaterial)
                    .frame(width: 52, height: 52)
                    .overlay {
                        Image(systemName: "play.fill")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(Color.white)
                            .offset(x: 1)
                    }
                    .shadow(color: .black.opacity(0.25), radius: 8, y: 3)

                VStack {
                    Spacer()

                    HStack(spacing: 6) {
                        Image(systemName: annotations.isEmpty ? "video.fill" : "pencil.and.outline")

                        Text(annotations.isEmpty ? "Видео" : "\(annotations.count) \(markerCountWord)")
                            .lineLimit(1)
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.white)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 9)
                    .background(.ultraThinMaterial)
                }
            }
            .frame(width: 156, height: 278)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .task(id: videoURL) {
            poster = await loadPoster()
        }
        .accessibilityLabel(annotations.isEmpty ? "Открыть видео" : "Открыть видео с \(annotations.count) пометками")
        .accessibilityHint("Открывает полноэкранный системный видеоплеер")
    }

    private func loadPoster() async -> UIImage? {
        let asset = AVURLAsset(url: videoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 468, height: 834)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.1, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.1, preferredTimescale: 600)
        let requestedTime = CMTime(seconds: 0, preferredTimescale: 600)
        guard let result = try? await generator.image(at: requestedTime) else { return nil }
        return UIImage(cgImage: result.image)
    }

    private var markerCountWord: String {
        let value = annotations.count % 100
        if (11...14).contains(value) { return "пометок" }

        switch annotations.count % 10 {
        case 1: return "пометка"
        case 2...4: return "пометки"
        default: return "пометок"
        }
    }
}

private struct VideoPreviewScreen: View {
    let videoURL: URL

    @Environment(\.dismiss) private var dismiss
    @State private var player = AVPlayer()

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black
                .ignoresSafeArea()

            VideoPlayer(player: player)
                .ignoresSafeArea(edges: .horizontal)

            Button(action: dismiss.callAsFunction) {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.white)
                    .frame(width: 44, height: 44)
                    .background(.regularMaterial, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .padding(.leading, 16)
            .padding(.top, 10)
            .accessibilityLabel("Закрыть видео")
        }
        .onAppear {
            player.replaceCurrentItem(with: AVPlayerItem(url: videoURL))
            player.play()
        }
        .onDisappear {
            player.pause()
            player.replaceCurrentItem(with: nil)
        }
    }
}

private struct BugReportScreenshot: Identifiable {
    let id: UUID
    let image: UIImage
    let fileURL: URL
    let sourceImage: UIImage
    let drawing: PKDrawing?

    init?(image: UIImage) {
        self.init(
            id: UUID(),
            image: image,
            sourceImage: image,
            drawing: nil
        )
    }

    private init?(
        id: UUID,
        image: UIImage,
        sourceImage: UIImage,
        drawing: PKDrawing?
    ) {
        guard let data = image.pngData() else { return nil }
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("bug-report-screenshot-\(UUID().uuidString)")
            .appendingPathExtension("png")

        do {
            try data.write(to: outputURL, options: .atomic)
            self.id = id
            self.image = image
            fileURL = outputURL
            self.sourceImage = sourceImage
            self.drawing = drawing
        } catch {
            return nil
        }
    }

    func adding(markup: ScreenshotMarkupResult) -> BugReportScreenshot? {
        BugReportScreenshot(
            id: id,
            image: markup.image,
            sourceImage: sourceImage,
            drawing: markup.drawing
        )
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
    let sourceScreenshot: UIImage?
    let screenshotDrawing: PKDrawing?

    var isVideo: Bool {
        if case .video = kind { return true }
        return false
    }

    var fileURLs: [URL] {
        [fileURL]
    }

    var editingVideoURL: URL {
        sourceVideoURL ?? fileURL
    }

    var editingScreenshotImage: UIImage? {
        guard case .screenshot = kind else { return nil }
        return sourceScreenshot
    }

    var markerCountWord: String {
        let value = annotations.count % 100
        if (11...14).contains(value) { return "пометок" }

        switch annotations.count % 10 {
        case 1: return "пометка"
        case 2...4: return "пометки"
        default: return "пометок"
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
            sourceScreenshot = screenshot
            screenshotDrawing = nil
        } catch {
            return nil
        }
    }

    init(videoAt url: URL) {
        kind = .video
        fileURL = url
        annotations = []
        sourceVideoURL = url
        sourceScreenshot = nil
        screenshotDrawing = nil
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
        sourceScreenshot = nil
        screenshotDrawing = nil
    }

    private init?(
        screenshot: UIImage,
        sourceScreenshot: UIImage,
        drawing: PKDrawing
    ) {
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
            self.sourceScreenshot = sourceScreenshot
            screenshotDrawing = drawing
        } catch {
            return nil
        }
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

    func adding(screenshotMarkup: ScreenshotMarkupResult) -> BugReportAttachment? {
        guard let sourceScreenshot else { return nil }
        return BugReportAttachment(
            screenshot: screenshotMarkup.image,
            sourceScreenshot: sourceScreenshot,
            drawing: screenshotMarkup.drawing
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

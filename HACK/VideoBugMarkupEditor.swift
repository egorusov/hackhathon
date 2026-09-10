import AVFoundation
import AVKit
import Combine
import PencilKit
import QuartzCore
import SwiftUI
import UIKit

struct VideoFrameAnnotation: Identifiable {
    let id: UUID
    let fileURL: URL
    let preview: UIImage
    let time: Double
    let drawing: PKDrawing
}

struct VideoMarkupResult {
    let videoURL: URL
    let annotations: [VideoFrameAnnotation]
}

private struct VideoTimelineThumbnail: Identifiable {
    let id: Int
    let time: Double
    var image: UIImage?
}

private struct VideoMarkupMarker: Identifiable {
    let id: UUID
    let time: Double
    var drawing: PKDrawing
}

@MainActor
struct VideoBugMarkupEditor: View {
    let videoURL: URL
    let onCancel: () -> Void
    let onComplete: (VideoMarkupResult) -> Void

    @StateObject private var playback: VideoMarkupPlayback
    @State private var markers: [VideoMarkupMarker]
    @State private var selectedMarkerID: UUID?
    @State private var drawing: PKDrawing
    @State private var inkColor = MarkupInkColor.red
    @State private var canvasCommand: MarkupCanvasCommand?
    @State private var canvasSize: CGSize = .zero
    @State private var isRendering = false
    @State private var errorMessage: String?
    @State private var isDiscardConfirmationPresented = false

    init(
        videoURL: URL,
        existingAnnotations: [VideoFrameAnnotation] = [],
        onCancel: @escaping () -> Void,
        onComplete: @escaping (VideoMarkupResult) -> Void
    ) {
        self.videoURL = videoURL
        self.onCancel = onCancel
        self.onComplete = onComplete

        let existingMarkers = existingAnnotations.map {
            VideoMarkupMarker(id: $0.id, time: $0.time, drawing: $0.drawing)
        }
        let firstMarker = existingMarkers.sorted { $0.time < $1.time }.first

        _playback = StateObject(wrappedValue: VideoMarkupPlayback(videoURL: videoURL))
        _markers = State(initialValue: existingMarkers)
        _selectedMarkerID = State(initialValue: firstMarker?.id)
        _drawing = State(initialValue: firstMarker?.drawing ?? PKDrawing())
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                markupToolbar

                Spacer(minLength: 10)

                videoCanvas

                Spacer(minLength: 10)

                timelineControls
            }
            .background(Color(uiColor: .systemBackground))
            .navigationTitle("Пометки на видео")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: requestClose) {
                        Image(systemName: "xmark")
                            .frame(width: 44, height: 44)
                    }
                    .disabled(isRendering)
                    .accessibilityLabel("Закрыть")
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: renderAnnotations) {
                        if isRendering {
                            ProgressView()
                        } else {
                            Text("Готово")
                        }
                    }
                    .fontWeight(.semibold)
                    .disabled(!playback.isReady || canvasSize.width <= 0 || isRendering)
                    .accessibilityHint("Создает снимки отмеченных кадров и открывает форму баг-репорта")
                }
            }
            .task {
                let initialTime = sortedMarkers.first?.time ?? 0
                playback.load(initialTime: initialTime)
            }
            .onDisappear {
                playback.tearDown()
            }
            .alert("Не удалось подготовить кадры", isPresented: errorBinding) {
                Button("Закрыть", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "Повторите попытку")
            }
            .confirmationDialog(
                "Закрыть редактор?",
                isPresented: $isDiscardConfirmationPresented,
                titleVisibility: .visible
            ) {
                Button("Удалить пометки", role: .destructive, action: onCancel)
                Button("Продолжить редактирование", role: .cancel) {}
            } message: {
                Text("Несохраненные маркеры и рисунки будут удалены.")
            }
        }
    }

    private var markupToolbar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                Button {
                    canvasCommand = MarkupCanvasCommand(kind: .undo)
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .frame(width: 44, height: 44)
                }
                .disabled(!canEditDrawing || drawing.strokes.isEmpty)
                .accessibilityLabel("Отменить штрих")

                Button {
                    canvasCommand = MarkupCanvasCommand(kind: .redo)
                } label: {
                    Image(systemName: "arrow.uturn.forward")
                        .frame(width: 44, height: 44)
                }
                .disabled(!canEditDrawing)
                .accessibilityLabel("Повторить штрих")

                Button {
                    canvasCommand = MarkupCanvasCommand(kind: .clear)
                } label: {
                    Image(systemName: "eraser.line.dashed")
                        .frame(width: 44, height: 44)
                }
                .disabled(!canEditDrawing || drawing.strokes.isEmpty)
                .accessibilityLabel("Очистить рисунок")

                Divider()
                    .frame(height: 26)
                    .padding(.horizontal, 4)

                ForEach(MarkupInkColor.allCases) { color in
                    Button {
                        inkColor = color
                    } label: {
                        Circle()
                            .fill(color.color)
                            .frame(width: 24, height: 24)
                            .overlay {
                                if inkColor == color {
                                    Image(systemName: "checkmark")
                                        .font(.caption.bold())
                                        .foregroundStyle(color == .yellow ? Color.black : Color.white)
                                }
                            }
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .disabled(!canEditDrawing)
                    .accessibilityLabel(color.accessibilityName)
                    .accessibilityAddTraits(inkColor == color ? .isSelected : [])
                }

                Divider()
                    .frame(height: 26)
                    .padding(.horizontal, 4)

                Button(role: .destructive, action: deleteSelectedMarker) {
                    Image(systemName: "trash")
                        .frame(width: 44, height: 44)
                }
                .disabled(!canEditDrawing)
                .accessibilityLabel("Удалить выбранный маркер")
            }
            .padding(.horizontal, 12)
        }
        .frame(height: 60)
        .background(.regularMaterial)
    }

    private var videoCanvas: some View {
        ZStack {
            Color.black

            VideoPlayer(player: playback.player)
                .allowsHitTesting(false)

            GeometryReader { proxy in
                MarkupCanvas(
                    drawing: $drawing,
                    inkColor: inkColor,
                    command: canvasCommand,
                    isEnabled: canEditDrawing,
                    onDrawingChanged: updateSelectedMarkerDrawing
                )
                .onAppear {
                    canvasSize = proxy.size
                }
                .onChange(of: proxy.size) { _, newSize in
                    canvasSize = newSize
                }
            }

            if !canEditDrawing {
                VStack {
                    Spacer()

                    Label("Добавьте кадр, чтобы рисовать", systemImage: "plus.circle.fill")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.regularMaterial, in: Capsule())
                        .padding(12)
                }
                .allowsHitTesting(false)
            }
        }
        .aspectRatio(playback.aspectRatio, contentMode: .fit)
        .frame(maxWidth: .infinity, maxHeight: 410)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        }
        .padding(.horizontal, 16)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Кадр видео с областью для рисования")
    }

    private var timelineControls: some View {
        VStack(spacing: 10) {
            HStack {
                Label("\(markers.count) \(markerCountWord)", systemImage: "rectangle.stack")
                    .font(.headline)

                Spacer()

                Text("\(formattedTime(playback.currentTime)) / \(formattedTime(playback.duration))")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Button(action: togglePlayback) {
                    Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 48, height: 64)
                        .background(Color(uiColor: .secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(Color.primary.opacity(0.16), lineWidth: 1)
                        }
                }
                .buttonStyle(.plain)
                .disabled(!playback.isReady)
                .accessibilityLabel(playback.isPlaying ? "Пауза" : "Воспроизвести")

                markerTimeline
            }

            HStack(spacing: 10) {
                Button {
                    stepPlayhead(by: -1)
                } label: {
                    Image(systemName: "chevron.left")
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.bordered)
                .disabled(!playback.isReady || playback.currentTime <= 0)
                .accessibilityLabel("Предыдущий кадр")

                Button {
                    stepPlayhead(by: 1)
                } label: {
                    Image(systemName: "chevron.right")
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.bordered)
                .disabled(!playback.isReady || playback.currentTime >= playback.lastFrameTime)
                .accessibilityLabel("Следующий кадр")

                Spacer(minLength: 0)

                Button(action: addMarkerAtPlayhead) {
                    Label("Кадр", systemImage: "plus.rectangle.on.rectangle")
                        .frame(minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!playback.isReady)
                .accessibilityHint("Добавляет маркер на текущем кадре для рисования")
            }

            Text(canEditDrawing ? "Пометка появится в видео на 1,2 секунды." : "Проведите по ленте или переключайте видео покадрово.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            if !markers.isEmpty {
                markerChips
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    private var markerTimeline: some View {
        GeometryReader { proxy in
            let count = max(playback.thumbnails.count, 1)
            let spacing = CGFloat(max(0, count - 1))
            let thumbnailWidth = max(1, (proxy.size.width - spacing) / CGFloat(count))

            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemBackground))

                HStack(spacing: 1) {
                    ForEach(playback.thumbnails) { thumbnail in
                        Group {
                            if let image = thumbnail.image {
                                Image(uiImage: image)
                                    .resizable()
                                    .scaledToFill()
                            } else {
                                Rectangle()
                                    .fill(Color.secondary.opacity(0.12))
                                    .overlay {
                                        ProgressView()
                                            .controlSize(.mini)
                                    }
                            }
                        }
                        .frame(width: thumbnailWidth, height: proxy.size.height)
                        .clipped()
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                ForEach(markers) { marker in
                    Circle()
                        .fill(selectedMarkerID == marker.id ? Color.blue : Color.orange)
                        .frame(width: selectedMarkerID == marker.id ? 12 : 9)
                        .overlay(Circle().stroke(Color.white, lineWidth: 2))
                    .position(
                        x: markerPosition(for: marker.time, width: proxy.size.width),
                        y: 9
                    )
                }

                Rectangle()
                    .fill(Color.white)
                    .frame(width: 3)
                    .overlay(Rectangle().stroke(Color.black.opacity(0.2), lineWidth: 0.5))
                    .position(
                        x: playheadPosition(width: proxy.size.width),
                        y: proxy.size.height / 2
                    )
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        scrubTimeline(at: value.location.x, width: proxy.size.width)
                    }
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.primary.opacity(0.16), lineWidth: 1)
                    .allowsHitTesting(false)
            }
        }
        .frame(height: 64)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Лента кадров видео")
        .accessibilityValue(formattedTime(playback.currentTime))
        .accessibilityAdjustableAction { direction in
            let delta = direction == .increment ? playback.safeFrameStep : -playback.safeFrameStep
            movePlayhead(to: playback.currentTime + delta)
        }
    }

    private var markerChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(sortedMarkers.enumerated()), id: \.element.id) { index, marker in
                    Button {
                        selectMarker(marker.id)
                    } label: {
                        HStack(spacing: 6) {
                            Text("\(index + 1)")
                                .font(.caption.bold())
                                .foregroundStyle(.white)
                                .frame(width: 22, height: 22)
                                .background(selectedMarkerID == marker.id ? Color.blue : Color.orange, in: Circle())

                            Text(formattedTime(marker.time))
                                .font(.caption.monospacedDigit())
                        }
                        .padding(.horizontal, 10)
                        .frame(minHeight: 44)
                        .background(
                            selectedMarkerID == marker.id ? Color.blue.opacity(0.12) : Color.secondary.opacity(0.1),
                            in: Capsule()
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Кадр \(index + 1), \(formattedTime(marker.time))")
                    .accessibilityAddTraits(selectedMarkerID == marker.id ? .isSelected : [])
                }
            }
        }
    }

    private var sortedMarkers: [VideoMarkupMarker] {
        markers.sorted { $0.time < $1.time }
    }

    private var canEditDrawing: Bool {
        selectedMarkerID != nil
    }

    private var markerCountWord: String {
        let value = markers.count % 100
        if (11...14).contains(value) { return "кадров" }

        switch markers.count % 10 {
        case 1: return "кадр"
        case 2...4: return "кадра"
        default: return "кадров"
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private func requestClose() {
        if markers.isEmpty {
            onCancel()
        } else {
            isDiscardConfirmationPresented = true
        }
    }

    private func addMarkerAtPlayhead() {
        let frameTime = playback.snappedTime(playback.currentTime)
        playback.seek(to: frameTime)

        if let existing = markers.first(where: {
            abs($0.time - frameTime) < playback.safeFrameStep / 2
        }) {
            selectMarker(existing.id)
            return
        }

        let marker = VideoMarkupMarker(
            id: UUID(),
            time: frameTime,
            drawing: PKDrawing()
        )
        markers.append(marker)
        selectedMarkerID = marker.id
        drawing = marker.drawing
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    private func togglePlayback() {
        if !playback.isPlaying {
            selectedMarkerID = nil
            drawing = PKDrawing()
        }
        playback.togglePlayback()
    }

    private func selectMarker(_ id: UUID) {
        guard let marker = markers.first(where: { $0.id == id }) else { return }
        playback.seek(to: marker.time)
        selectedMarkerID = marker.id
        drawing = marker.drawing
    }

    private func movePlayhead(to time: Double) {
        selectedMarkerID = nil
        drawing = PKDrawing()
        playback.seek(to: playback.snappedTime(time))
    }

    private func updateSelectedMarkerDrawing(_ newDrawing: PKDrawing) {
        playback.pause()
        drawing = newDrawing

        guard let selectedMarkerID,
              let index = markers.firstIndex(where: { $0.id == selectedMarkerID }) else { return }
        markers[index].drawing = newDrawing
    }

    private func deleteSelectedMarker() {
        guard let selectedMarkerID else { return }
        markers.removeAll { $0.id == selectedMarkerID }
        self.selectedMarkerID = nil
        drawing = PKDrawing()
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }

    private func markerPosition(for time: Double, width: CGFloat) -> CGFloat {
        guard playback.lastFrameTime > 0 else { return width / 2 }
        let ratio = min(max(time / playback.lastFrameTime, 0), 1)
        return CGFloat(ratio) * width
    }

    private func playheadPosition(width: CGFloat) -> CGFloat {
        let x = markerPosition(for: playback.currentTime, width: width)
        return min(max(2, x), max(2, width - 2))
    }

    private func scrubTimeline(at x: CGFloat, width: CGFloat) {
        guard playback.isReady, width > 0 else { return }
        let ratio = min(max(x / width, 0), 1)
        movePlayhead(to: Double(ratio) * playback.lastFrameTime)
    }

    private func stepPlayhead(by frameCount: Int) {
        movePlayhead(to: playback.currentTime + Double(frameCount) * playback.safeFrameStep)
        UISelectionFeedbackGenerator().selectionChanged()
    }

    private func renderAnnotations() {
        playback.pause()
        isRendering = true

        let markersToRender = sortedMarkers
        let selectedCanvasSize = canvasSize

        Task { @MainActor in
            do {
                let result = try await VideoFrameAnnotationRenderer.render(
                    videoURL: videoURL,
                    markers: markersToRender,
                    canvasSize: selectedCanvasSize
                )
                isRendering = false
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                onComplete(result)
            } catch {
                isRendering = false
                errorMessage = error.localizedDescription
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }
    }

    private func formattedTime(_ value: Double) -> String {
        guard value.isFinite else { return "00:00.0" }
        let clamped = max(0, value)
        let minutes = Int(clamped) / 60
        let seconds = clamped.truncatingRemainder(dividingBy: 60)
        return String(format: "%02d:%04.1f", minutes, seconds)
    }
}

@MainActor
private final class VideoMarkupPlayback: ObservableObject {
    @Published private(set) var duration: Double = 0
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var aspectRatio: CGFloat = 9 / 16
    @Published private(set) var frameStep: Double = 1.0 / 30.0
    @Published private(set) var isReady = false
    @Published private(set) var thumbnails: [VideoTimelineThumbnail] = []

    let player: AVPlayer

    var safeFrameStep: Double {
        guard frameStep.isFinite, frameStep > 0 else { return 1.0 / 30.0 }
        return frameStep
    }

    var lastFrameTime: Double {
        guard duration.isFinite, duration > 0 else { return 0 }
        return max(0, duration - safeFrameStep)
    }

    private let videoURL: URL
    private var timeObserver: Any?
    private var didLoad = false

    init(videoURL: URL) {
        self.videoURL = videoURL
        player = AVPlayer(url: videoURL)
    }

    func load(initialTime: Double) {
        guard !didLoad else { return }
        didLoad = true

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 30),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                let observedTime = max(0, time.seconds.isFinite ? time.seconds : 0)

                if self.duration > 0, observedTime >= self.lastFrameTime {
                    self.currentTime = self.lastFrameTime
                    self.player.pause()
                    self.isPlaying = false
                } else {
                    self.currentTime = observedTime
                }
            }
        }

        Task { @MainActor in
            do {
                let asset = AVURLAsset(url: videoURL)
                let assetDuration = try await asset.load(.duration)
                let videoTracks = try await asset.loadTracks(withMediaType: .video)
                let loadedDuration = assetDuration.seconds
                duration = loadedDuration.isFinite ? max(0, loadedDuration) : 0

                if let track = videoTracks.first {
                    let naturalSize = try await track.load(.naturalSize)
                    let preferredTransform = try await track.load(.preferredTransform)
                    let nominalFrameRate = try await track.load(.nominalFrameRate)
                    let transformedSize = naturalSize.applying(preferredTransform)
                    let width = abs(transformedSize.width)
                    let height = abs(transformedSize.height)

                    if width > 0, height > 0 {
                        aspectRatio = width / height
                    }

                    if nominalFrameRate.isFinite, nominalFrameRate > 0 {
                        frameStep = 1 / Double(nominalFrameRate)
                    }
                }

                isReady = duration > 0
                seek(to: initialTime)
                await loadTimelineThumbnails(asset: asset)
            } catch {
                isReady = false
            }
        }
    }

    func snappedTime(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        let frame = (value / safeFrameStep).rounded()
        return min(max(0, frame * safeFrameStep), lastFrameTime)
    }

    func seek(to value: Double) {
        pause()
        let bounded = snappedTime(value)
        currentTime = bounded
        let time = CMTime(seconds: bounded, preferredTimescale: 600)
        player.currentItem?.cancelPendingSeeks()
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func togglePlayback() {
        if isPlaying {
            pause()
            return
        }

        if duration > 0, currentTime >= lastFrameTime {
            seek(to: 0)
        }

        isPlaying = true
        player.play()
    }

    func pause() {
        guard isPlaying || player.rate != 0 else { return }
        player.pause()
        isPlaying = false
    }

    func tearDown() {
        player.pause()
        isPlaying = false

        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
    }

    private func loadTimelineThumbnails(asset: AVURLAsset) async {
        let count = 12
        let timelineEnd = max(lastFrameTime, 0)
        thumbnails = (0..<count).map { index in
            let progress = count > 1 ? Double(index) / Double(count - 1) : 0
            return VideoTimelineThumbnail(
                id: index,
                time: timelineEnd * progress,
                image: nil
            )
        }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 180, height: 180)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.15, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.15, preferredTimescale: 600)

        for index in thumbnails.indices {
            guard !Task.isCancelled else {
                generator.cancelAllCGImageGeneration()
                return
            }

            let requestedTime = CMTime(seconds: thumbnails[index].time, preferredTimescale: 600)
            if let result = try? await generator.image(at: requestedTime) {
                thumbnails[index].image = UIImage(cgImage: result.image)
            }
        }
    }
}

private enum MarkupInkColor: String, CaseIterable, Identifiable {
    case red
    case yellow
    case blue
    case white

    var id: String { rawValue }

    var color: Color {
        switch self {
        case .red: .red
        case .yellow: .yellow
        case .blue: .blue
        case .white: .white
        }
    }

    var uiColor: UIColor {
        switch self {
        case .red: .systemRed
        case .yellow: .systemYellow
        case .blue: .systemBlue
        case .white: .white
        }
    }

    var accessibilityName: String {
        switch self {
        case .red: "Красный маркер"
        case .yellow: "Желтый маркер"
        case .blue: "Синий маркер"
        case .white: "Белый маркер"
        }
    }
}

private struct MarkupCanvasCommand: Equatable {
    enum Kind {
        case undo
        case redo
        case clear
    }

    let id = UUID()
    let kind: Kind
}

private struct MarkupCanvas: UIViewRepresentable {
    @Binding var drawing: PKDrawing
    let inkColor: MarkupInkColor
    let command: MarkupCanvasCommand?
    let isEnabled: Bool
    let onDrawingChanged: (PKDrawing) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = PKCanvasView()
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.isScrollEnabled = false
        canvas.drawingPolicy = .anyInput
        canvas.tool = PKInkingTool(.marker, color: inkColor.uiColor, width: 12)
        canvas.delegate = context.coordinator
        return canvas
    }

    func updateUIView(_ canvas: PKCanvasView, context: Context) {
        context.coordinator.parent = self
        canvas.isUserInteractionEnabled = isEnabled
        canvas.tool = PKInkingTool(.marker, color: inkColor.uiColor, width: 12)

        if canvas.drawing.dataRepresentation() != drawing.dataRepresentation() {
            canvas.drawing = drawing
        }

        guard let command,
              context.coordinator.lastCommandID != command.id else { return }

        context.coordinator.lastCommandID = command.id

        switch command.kind {
        case .undo:
            canvas.undoManager?.undo()
        case .redo:
            canvas.undoManager?.redo()
        case .clear:
            canvas.drawing = PKDrawing()
        }

        drawing = canvas.drawing
        onDrawingChanged(canvas.drawing)
    }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        var parent: MarkupCanvas
        var lastCommandID: UUID?

        init(parent: MarkupCanvas) {
            self.parent = parent
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            parent.drawing = canvasView.drawing
            parent.onDrawingChanged(canvasView.drawing)
        }
    }
}

@MainActor
private enum VideoFrameAnnotationRenderer {
    private static let annotationVisibilityDuration = 1.2

    static func render(
        videoURL: URL,
        markers: [VideoMarkupMarker],
        canvasSize: CGSize
    ) async throws -> VideoMarkupResult {
        guard markers.isEmpty || (canvasSize.width > 0 && canvasSize.height > 0) else {
            throw RenderingError.invalidCanvas
        }

        let asset = AVURLAsset(url: videoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        var annotations: [VideoFrameAnnotation] = []

        for marker in markers {
            let requestedTime = CMTime(seconds: marker.time, preferredTimescale: 600)
            let result = try await generator.image(at: requestedTime)
            let frame = UIImage(cgImage: result.image)
            let targetSize = frame.size

            guard targetSize.width > 0, targetSize.height > 0 else {
                throw RenderingError.invalidFrame
            }

            let scale = targetSize.width / canvasSize.width
            let markup = marker.drawing.image(
                from: CGRect(origin: .zero, size: canvasSize),
                scale: scale
            )

            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = true

            let annotatedFrame = UIGraphicsImageRenderer(size: targetSize, format: format).image { _ in
                frame.draw(in: CGRect(origin: .zero, size: targetSize))
                markup.draw(in: CGRect(origin: .zero, size: targetSize))
            }

            guard let data = annotatedFrame.pngData() else {
                throw RenderingError.encodingFailed
            }

            let outputURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("bug-report-frame-\(marker.id.uuidString)")
                .appendingPathExtension("png")
            try data.write(to: outputURL, options: .atomic)

            annotations.append(
                VideoFrameAnnotation(
                    id: marker.id,
                    fileURL: outputURL,
                    preview: annotatedFrame,
                    time: marker.time,
                    drawing: marker.drawing
                )
            )
        }

        guard markers.contains(where: { !$0.drawing.strokes.isEmpty }) else {
            return VideoMarkupResult(videoURL: videoURL, annotations: annotations)
        }

        let annotatedVideoURL = try await exportAnnotatedVideo(
            asset: asset,
            markers: markers,
            canvasSize: canvasSize
        )
        return VideoMarkupResult(videoURL: annotatedVideoURL, annotations: annotations)
    }

    private static func exportAnnotatedVideo(
        asset: AVURLAsset,
        markers: [VideoMarkupMarker],
        canvasSize: CGSize
    ) async throws -> URL {
        let assetDuration = try await asset.load(.duration)
        let duration = assetDuration.seconds
        guard duration.isFinite, duration > 0 else {
            throw RenderingError.invalidFrame
        }
        guard !(try await asset.loadTracks(withMediaType: .video)).isEmpty else {
            throw RenderingError.invalidFrame
        }

        var configuration = try await AVVideoComposition.Configuration(for: asset)
        let renderSize = configuration.renderSize
        guard renderSize.width > 0, renderSize.height > 0 else {
            throw RenderingError.invalidFrame
        }

        let parentLayer = CALayer()
        parentLayer.frame = CGRect(origin: .zero, size: renderSize)

        let videoLayer = CALayer()
        videoLayer.frame = parentLayer.bounds
        parentLayer.addSublayer(videoLayer)

        for marker in markers where !marker.drawing.strokes.isEmpty {
            let image = overlayImage(
                for: marker.drawing,
                canvasSize: canvasSize,
                renderSize: renderSize
            )
            guard let cgImage = image.cgImage else {
                throw RenderingError.encodingFailed
            }

            let annotationLayer = CALayer()
            annotationLayer.frame = parentLayer.bounds
            annotationLayer.contents = cgImage
            annotationLayer.contentsGravity = .resize
            annotationLayer.opacity = 0
            annotationLayer.add(
                visibilityAnimation(at: marker.time, duration: duration),
                forKey: "bug-report-annotation-\(marker.id.uuidString)"
            )
            parentLayer.addSublayer(annotationLayer)
        }

        configuration.animationTool = AVVideoCompositionCoreAnimationTool(
            postProcessingAsVideoLayer: videoLayer,
            in: parentLayer
        )
        let videoComposition = AVVideoComposition(configuration: configuration)

        guard let exportSession = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetHighestQuality
        ) else {
            throw RenderingError.exportUnavailable
        }
        exportSession.videoComposition = videoComposition

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("bug-report-annotated-\(UUID().uuidString)")
            .appendingPathExtension("mp4")
        try? FileManager.default.removeItem(at: outputURL)
        try await exportSession.export(to: outputURL, as: .mp4)
        return outputURL
    }

    private static func overlayImage(
        for drawing: PKDrawing,
        canvasSize: CGSize,
        renderSize: CGSize
    ) -> UIImage {
        let scale = renderSize.width / canvasSize.width
        let markup = drawing.image(
            from: CGRect(origin: .zero, size: canvasSize),
            scale: scale
        )
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false

        return UIGraphicsImageRenderer(size: renderSize, format: format).image { _ in
            markup.draw(in: CGRect(origin: .zero, size: renderSize))
        }
    }

    private static func visibilityAnimation(at time: Double, duration: Double) -> CAKeyframeAnimation {
        let start = min(max(0, time), duration)
        let end = min(duration, start + annotationVisibilityDuration)
        let startRatio = NSNumber(value: start / duration)
        let endRatio = NSNumber(value: end / duration)

        let animation = CAKeyframeAnimation(keyPath: "opacity")
        animation.beginTime = AVCoreAnimationBeginTimeAtZero
        animation.duration = duration
        animation.calculationMode = .discrete
        animation.isRemovedOnCompletion = false
        animation.fillMode = .both

        if start <= 0 {
            animation.values = [1, 0, 0]
            animation.keyTimes = [0, endRatio, 1]
        } else if end >= duration {
            animation.values = [0, 1, 1]
            animation.keyTimes = [0, startRatio, 1]
        } else {
            animation.values = [0, 1, 0, 0]
            animation.keyTimes = [0, startRatio, endRatio, 1]
        }

        return animation
    }

    private enum RenderingError: LocalizedError {
        case invalidCanvas
        case invalidFrame
        case encodingFailed
        case exportUnavailable

        var errorDescription: String? {
            switch self {
            case .invalidCanvas:
                "Область разметки еще не готова"
            case .invalidFrame:
                "Видео не содержит доступного кадра"
            case .encodingFailed:
                "Не удалось сохранить отмеченный кадр"
            case .exportUnavailable:
                "Не удалось подготовить экспорт видео"
            }
        }
    }
}

import AppKit
import Combine
import SwiftUI

@MainActor
final class OverlayController {
    private static let size = NSSize(width: 220, height: 64)
    private static let bottomMargin: CGFloat = 70
    private static let fadeDuration: TimeInterval = 0.18

    private let panel: NSPanel
    private var subscription: AnyCancellable?

    init(state: AppState) {
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: OverlayView(state: state))
        panel.alphaValue = 0

        subscription = state.$phase
            .removeDuplicates()
            .sink { [weak self] phase in self?.update(for: phase) }
    }

    private func update(for phase: DictationPhase) {
        phase == .idle ? hide() : show()
    }

    private func show() {
        guard !panel.isVisible || panel.alphaValue < 1 else { return }
        positionOnActiveScreen()
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fadeDuration
            panel.animator().alphaValue = 1
        }
    }

    private func hide() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fadeDuration
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self, self.panel.alphaValue == 0 else { return }
                self.panel.orderOut(nil)
            }
        }
    }

    private func positionOnActiveScreen() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        panel.setFrameOrigin(NSPoint(x: frame.midX - Self.size.width / 2, y: frame.minY + Self.bottomMargin))
    }
}

struct OverlayView: View {
    @ObservedObject var state: AppState

    var body: some View {
        HStack(spacing: 10) {
            switch state.phase {
            case .recording:
                RecordingDot()
                WaveformBars(meter: state.meter)
            case .transcribing:
                ThinkingDots()
                if state.loadedModelID == nil, state.modelStatus.isBusy {
                    Text("Preparing model…")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                }
            case .idle:
                EmptyView()
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 38)
        .background(
            Capsule()
                .fill(Color.black.opacity(0.88))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
                .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
        )
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: state.phase)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct RecordingDot: View {
    var body: some View {
        TimelineView(.animation) { context in
            let pulse = (sin(context.date.timeIntervalSinceReferenceDate * 4) + 1) / 2
            Circle()
                .fill(Color.red)
                .frame(width: 8, height: 8)
                .opacity(0.55 + 0.45 * pulse)
        }
        .frame(width: 8, height: 8)
    }
}

private struct WaveformBars: View {
    @ObservedObject var meter: AudioLevelMeter

    private var level: CGFloat { CGFloat(meter.level) }

    private static let envelope: [CGFloat] = [0.35, 0.55, 0.8, 1.0, 0.9, 1.0, 0.8, 0.55, 0.35, 0.5, 0.7, 0.45]
    private static let minHeight: CGFloat = 3
    private static let maxHeight: CGFloat = 24

    var body: some View {
        TimelineView(.animation) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 3) {
                ForEach(Self.envelope.indices, id: \.self) { index in
                    let wave = CGFloat((sin(time * 9 + Double(index) * 0.8) + 1) / 2)
                    let height = Self.minHeight + level * (Self.maxHeight - Self.minHeight) * Self.envelope[index] * (0.45 + 0.55 * wave)
                    Capsule()
                        .fill(Color.white)
                        .frame(width: 3, height: height)
                }
            }
            .frame(height: Self.maxHeight)
        }
        .animation(.easeOut(duration: 0.08), value: level)
    }
}

private struct ThinkingDots: View {
    var body: some View {
        TimelineView(.animation) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { index in
                    let bounce = (sin(time * 6 - Double(index) * 0.9) + 1) / 2
                    Circle()
                        .fill(Color.white)
                        .frame(width: 6, height: 6)
                        .opacity(0.4 + 0.6 * bounce)
                        .offset(y: -4 * bounce)
                }
            }
            .frame(height: 24)
        }
    }
}

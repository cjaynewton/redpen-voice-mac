import AppKit
import SwiftUI

/// Show the actual native drawing before asking someone to choose its name.
/// Input here is synthetic. The settings preview never starts the microphone or HUD.
struct IndicatorShapeChoices: View {
    @Binding var selection: String
    let colour: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var activeState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose a shape").font(.system(size: 14, weight: .medium)).foregroundStyle(Ink.text)
            TimelineView(.animation(minimumInterval: 1.0 / 15, paused: reduceMotion || activeState != .key)) { context in
                HStack(spacing: 16) {
                    ForEach(VoiceIndicator.Shape.allCases, id: \.rawValue) { shape in
                        Button { selection = shape.rawValue } label: {
                            VStack(spacing: 9) {
                                IndicatorSettingsDrawing(shape: shape, colour: colour,
                                    phase: context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 60),
                                    reducedMotion: reduceMotion)
                                    .frame(width: 116, height: 40)
                                    .allowsHitTesting(false).accessibilityHidden(true)
                                Text(shape.title).font(.system(size: 13, weight: selection == shape.rawValue ? .semibold : .regular))
                                    .foregroundStyle(selection == shape.rawValue ? Ink.text : Ink.mid)
                                Rectangle().fill(selection == shape.rawValue ? Ink.text : .clear).frame(height: 2)
                            }.frame(maxWidth: .infinity).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                            .accessibilityLabel(shape.title)
                            .accessibilityValue(selection == shape.rawValue ? "Selected" : "Not selected")
                            .help("Use the " + shape.title.lowercased() + " recording indicator")
                    }
                }
            }
            Text("Animated preview. Your microphone is not used.")
                .font(.system(size: 12)).foregroundStyle(Ink.mid)
        }
    }
}

private struct IndicatorSettingsDrawing: NSViewRepresentable {
    let shape: VoiceIndicator.Shape
    let colour: String
    let phase: Double
    let reducedMotion: Bool

    func makeNSView(context: Context) -> TalkingBarView {
        let view = TalkingBarView(frame: CGRect(x: 0, y: 0, width: 116, height: 40))
        view.state = .listening
        view.setAccessibilityElement(false)
        return view
    }

    func updateNSView(_ view: TalkingBarView, context: Context) {
        view.indicatorShape = shape
        view.indicatorColour = VoiceIndicator.colour(colour)
        view.previewBackdrop = Ink.color(.paper)
        view.reducedMotion = reducedMotion
        view.phase = phase
        view.smooth = reducedMotion ? 0.4 : max(0, sin(phase * 1.8)) * (0.3 + 0.4 * abs(sin(phase * 6.2)))
        view.needsDisplay = true
    }
}

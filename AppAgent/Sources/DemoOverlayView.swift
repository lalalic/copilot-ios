#if os(iOS)
import SwiftUI

/// Transparent overlay that renders demo visuals (spotlight, tooltip, caption, step badge, cursor).
/// Add as `.overlay { DemoOverlayView() }` on app's root view.
public struct DemoOverlayView: View {
    @EnvironmentObject var demo: DemoRuntime

    public init() {}

    public var body: some View {
        ZStack {
            // Spotlight mask
            if let frame = demo.spotlightFrame {
                SpotlightMask(cutout: frame)
                    .transition(.opacity)
            }

            // Tooltip
            if let text = demo.tooltipText, let pos = demo.tooltipPosition {
                TooltipView(text: text)
                    .position(pos)
                    .transition(.opacity)
            }

            // Caption bar
            if let caption = demo.captionText {
                VStack {
                    Spacer()
                    CaptionBar(text: caption)
                }
                .transition(.move(edge: .bottom))
            }

            // Step badge
            if let title = demo.stepTitle {
                VStack {
                    StepBadge(number: demo.stepNumber, title: title)
                        .padding(.top, 60)
                    Spacer()
                }
                .transition(.move(edge: .top))
            }

            // Cursor dot
            if demo.cursorVisible, let pos = demo.cursorPosition {
                CursorDot()
                    .position(pos)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: demo.spotlightFrame)
        .animation(.easeInOut(duration: 0.3), value: demo.tooltipText)
        .animation(.easeInOut(duration: 0.3), value: demo.captionText)
        .animation(.easeInOut(duration: 0.3), value: demo.stepTitle)
        .animation(.easeInOut(duration: 0.4), value: demo.cursorPosition)
        .allowsHitTesting(false)
    }
}

// MARK: - Spotlight Mask

struct SpotlightMask: View {
    let cutout: CGRect
    let cornerRadius: CGFloat = 8
    let padding: CGFloat = 4

    var body: some View {
        Canvas { context, size in
            // Full dim
            context.fill(
                Path(CGRect(origin: .zero, size: size)),
                with: .color(.black.opacity(0.5))
            )
            // Cut out the spotlight area
            let padded = cutout.insetBy(dx: -padding, dy: -padding)
            context.blendMode = .destinationOut
            context.fill(
                Path(roundedRect: padded, cornerRadius: cornerRadius),
                with: .color(.white)
            )
        }
        .compositingGroup()
        .ignoresSafeArea()
    }
}

// MARK: - Tooltip

struct TooltipView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.callout.weight(.medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.black.opacity(0.85))
            )
            .fixedSize()
    }
}

// MARK: - Caption Bar

struct CaptionBar: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.body)
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .background(.ultraThinMaterial)
            .padding(.horizontal, 16)
            .padding(.bottom, 40)
    }
}

// MARK: - Step Badge

struct StepBadge: View {
    let number: Int
    let title: String

    var body: some View {
        HStack(spacing: 8) {
            Text("\(number)")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.blue))

            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            Capsule().fill(Color.black.opacity(0.75))
        )
    }
}

// MARK: - Cursor Dot

struct CursorDot: View {
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(Color.blue)
            .frame(width: 16, height: 16)
            .overlay(
                Circle()
                    .stroke(Color.blue.opacity(0.4), lineWidth: 2)
                    .scaleEffect(pulse ? 2.0 : 1.0)
                    .opacity(pulse ? 0 : 1)
            )
            .onAppear {
                withAnimation(.easeOut(duration: 0.8).repeatForever(autoreverses: false)) {
                    pulse = true
                }
            }
    }
}
#endif

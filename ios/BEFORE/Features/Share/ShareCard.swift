import SwiftUI
import BeforeKit

// =============================================================================
// BEFORE — the share card.
//
// Rendered on device from SwiftUI (spec §14). No backend round trip, no image
// upload: a share card is a picture of someone's shopping decision and it never
// leaves the phone unless they send it.
//
// Prices and dates use the device locale, never a hard-coded "$" (spec §63).
// =============================================================================

struct ShareCard: View {
    let analysis: Analysis
    let style: Style

    enum Style: Hashable {
        /// 1080×1920 for Instagram Stories.
        case story
        /// 1080×1350, the standard share image.
        case standard

        var size: CGSize {
            switch self {
            case .story: CGSize(width: 1080, height: 1920)
            case .standard: CGSize(width: 1080, height: 1350)
            }
        }

        var scale: CGFloat {
            // The card is laid out at a comfortable point size and scaled up on
            // render, so the layout code is readable rather than full of
            // hundreds-of-points constants.
            switch self {
            case .story: 1080 / 360
            case .standard: 1080 / 360
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("BEFORE")
                .font(.system(size: 13, weight: .semibold))
                .tracking(4)
                .foregroundStyle(BeforeTheme.secondaryText)

            Spacer().frame(height: 28)

            Text("SHOULD I BUY THIS?")
                .font(.system(size: 15, weight: .medium))
                .tracking(1.5)
                .foregroundStyle(BeforeTheme.secondaryText)

            Spacer().frame(height: 16)

            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Text(analysis.verdict.label)
                    .font(.system(size: 64, weight: .bold))
                    .tracking(-1)
                    .foregroundStyle(BeforeTheme.color(for: analysis.verdict))

                Text("\(analysis.score)")
                    .font(.system(size: 40, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(BeforeTheme.primaryText)
            }

            Spacer().frame(height: 24)

            // One line, the most useful one. A share card is not a report.
            Text(headline)
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(BeforeTheme.primaryText)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()

            if analysis.verdict != .buy,
               let price = Formatting.price(
                   analysis.product.price,
                   currencyCode: analysis.product.currency
               ) {
                VStack(alignment: .leading, spacing: 2) {
                    // Never "you saved" — BEFORE cannot know that (spec §32).
                    Text("Potential spend avoided")
                        .font(.system(size: 12, weight: .medium))
                        .tracking(0.8)
                        .foregroundStyle(BeforeTheme.secondaryText)
                    Text(price)
                        .font(.system(size: 26, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(BeforeTheme.primaryText)
                }
                Spacer().frame(height: 20)
            }

            Text("before")
                .font(.system(size: 12, weight: .medium))
                .tracking(2)
                .foregroundStyle(BeforeTheme.tertiaryText)
        }
        .padding(32)
        .frame(width: 360, height: style == .story ? 640 : 450, alignment: .topLeading)
        .background(BeforeTheme.background)
    }

    private var headline: String {
        if let first = analysis.reasons.negative.first, analysis.verdict != .buy { return first }
        if let first = analysis.reasons.positive.first { return first }
        return analysis.verdict.headline
    }
}

// MARK: - Rendering

enum ShareCardRenderer {
    /// Render at export resolution. Runs on the main actor because ImageRenderer
    /// requires it; the work is small and bounded.
    @MainActor
    static func render(analysis: Analysis, style: ShareCard.Style) -> UIImage? {
        let renderer = ImageRenderer(content: ShareCard(analysis: analysis, style: style))
        renderer.scale = style.scale
        renderer.isOpaque = true
        return renderer.uiImage
    }
}

// MARK: - Share sheet

struct ShareResultSheet: View {
    let analysis: Analysis

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    @State private var style: ShareCard.Style = .standard
    @State private var rendered: UIImage?

    var body: some View {
        NavigationStack {
            VStack(spacing: BeforeTheme.Spacing.xl) {
                Picker("Format", selection: $style) {
                    Text("Post").tag(ShareCard.Style.standard)
                    Text("Story").tag(ShareCard.Style.story)
                }
                .pickerStyle(.segmented)

                ScrollView {
                    ShareCard(analysis: analysis, style: style)
                        .clipShape(
                            RoundedRectangle(cornerRadius: BeforeTheme.Radius.card, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: BeforeTheme.Radius.card, style: .continuous)
                                .stroke(BeforeTheme.divider, lineWidth: 1)
                        )
                        .scaleEffect(0.85)
                        .frame(height: style == .story ? 560 : 400)
                }

                if let rendered {
                    ShareLink(
                        item: Image(uiImage: rendered),
                        preview: SharePreview("BEFORE — \(analysis.verdict.label)", image: Image(uiImage: rendered))
                    ) {
                        Text("Share image")
                            .font(BeforeTheme.Typeface.headline)
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: BeforeTheme.Sizing.buttonHeight)
                            .foregroundStyle(BeforeTheme.background)
                            .background(
                                RoundedRectangle(cornerRadius: BeforeTheme.Radius.control, style: .continuous)
                                    .fill(BeforeTheme.primaryText)
                            )
                    }
                    .simultaneousGesture(TapGesture().onEnded {
                        Analytics.track(.shareCompleted, analysis: analysis, isPlus: environment.isPlus)
                    })
                } else {
                    ProgressView().frame(minHeight: BeforeTheme.Sizing.buttonHeight)
                }
            }
            .padding(.top, BeforeTheme.Spacing.l)
            .beforeScreen()
            .navigationTitle("Share result")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
            .task(id: style) {
                rendered = ShareCardRenderer.render(analysis: analysis, style: style)
            }
        }
    }
}

#Preview("Share card — WAIT") {
    ShareCard(analysis: Fixtures.leatherJacket, style: .standard)
}

#Preview("Share card — BUY story") {
    ShareCard(analysis: Fixtures.loafers, style: .story)
}

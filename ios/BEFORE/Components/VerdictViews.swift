import SwiftUI
import BeforeKit

// =============================================================================
// BEFORE — the verdict visual language.
//
// Two rules govern everything here:
//   1. Colour never carries meaning alone. Every badge shows its word (§61).
//   2. BYE reads as "good decision to skip", never as a failure (§56).
// =============================================================================

public struct VerdictBadge: View {
    public enum Size { case small, large }

    private let verdict: Verdict
    private let size: Size

    public init(_ verdict: Verdict, size: Size = .small) {
        self.verdict = verdict
        self.size = size
    }

    public var body: some View {
        Text(verdict.label)
            .font(size == .large
                  ? BeforeTheme.Typeface.headline
                  : BeforeTheme.Typeface.caption.weight(.semibold))
            .tracking(size == .large ? 1.2 : 0.8)
            .foregroundStyle(BeforeTheme.color(for: verdict))
            .padding(.horizontal, size == .large ? BeforeTheme.Spacing.m : BeforeTheme.Spacing.s)
            .padding(.vertical, size == .large ? BeforeTheme.Spacing.s : BeforeTheme.Spacing.xs)
            .background(
                RoundedRectangle(cornerRadius: BeforeTheme.Radius.control, style: .continuous)
                    .fill(BeforeTheme.tint(for: verdict))
            )
            // The word is already the label; the container is what needs naming.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Verdict: \(verdict.label)")
    }
}

/// The score, drawn as a ring. The only gradient in the app.
public struct ScoreRing: View {
    private let score: Int
    private let verdict: Verdict
    private let diameter: CGFloat
    private let animated: Bool

    @State private var progress: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        score: Int,
        verdict: Verdict,
        diameter: CGFloat = BeforeTheme.Sizing.scoreRing,
        animated: Bool = true
    ) {
        self.score = score
        self.verdict = verdict
        self.diameter = diameter
        self.animated = animated
    }

    public var body: some View {
        ZStack {
            Circle()
                .stroke(BeforeTheme.divider, lineWidth: 8)

            Circle()
                .trim(from: 0, to: progress)
                .stroke(
                    BeforeTheme.color(for: verdict),
                    style: StrokeStyle(lineWidth: 8, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))

            VStack(spacing: 0) {
                Text("\(score)")
                    .font(BeforeTheme.Typeface.score)
                    .foregroundStyle(BeforeTheme.primaryText)
                Text("BEFORE score")
                    .font(BeforeTheme.Typeface.caption)
                    .foregroundStyle(BeforeTheme.secondaryText)
            }
        }
        .frame(width: diameter, height: diameter)
        .onAppear {
            let target = Double(max(0, min(100, score))) / 100
            // Respect Reduce Motion: show the final state immediately.
            if animated && !reduceMotion {
                withAnimation(BeforeTheme.Motion.reveal) { progress = target }
            } else {
                progress = target
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("BEFORE score \(score) out of 100. Verdict: \(verdict.label).")
    }
}

/// One row of the factor breakdown.
public struct FactorRow: View {
    private let factor: FactorScore

    public init(_ factor: FactorScore) { self.factor = factor }

    public var body: some View {
        VStack(alignment: .leading, spacing: BeforeTheme.Spacing.xs) {
            HStack(alignment: .firstTextBaseline) {
                Text(factor.label)
                    .font(BeforeTheme.Typeface.body)
                    .foregroundStyle(
                        factor.included ? BeforeTheme.primaryText : BeforeTheme.tertiaryText
                    )
                Spacer(minLength: BeforeTheme.Spacing.s)
                if factor.included {
                    Text(Formatting.factorValue(factor.value))
                        .font(BeforeTheme.Typeface.number)
                        .foregroundStyle(BeforeTheme.primaryText)
                } else {
                    Text("Not judged")
                        .font(BeforeTheme.Typeface.caption)
                        .foregroundStyle(BeforeTheme.tertiaryText)
                }
            }

            if factor.included {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(BeforeTheme.divider)
                        Capsule()
                            .fill(BeforeTheme.primaryText.opacity(0.75))
                            .frame(width: geometry.size.width * (factor.value / 10))
                    }
                }
                .frame(height: 4)
            } else if let reason = factor.excludedReason {
                // An excluded factor explains itself rather than disappearing —
                // silence would read as a zero.
                Text(reason)
                    .font(BeforeTheme.Typeface.caption)
                    .foregroundStyle(BeforeTheme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, BeforeTheme.Spacing.xs)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        if factor.included {
            return "\(factor.label): \(Formatting.factorValue(factor.value))"
        }
        return "\(factor.label): not judged. \(factor.excludedReason ?? "")"
    }
}

/// A compact row for Home, History, and Saved.
public struct AnalysisRow: View {
    private let analysis: Analysis

    public init(_ analysis: Analysis) { self.analysis = analysis }

    public var body: some View {
        HStack(spacing: BeforeTheme.Spacing.m) {
            ProductThumbnail(urlString: analysis.imageUrl, category: analysis.product.category)

            VStack(alignment: .leading, spacing: BeforeTheme.Spacing.xs) {
                Text(analysis.product.displayName)
                    .font(BeforeTheme.Typeface.body)
                    .foregroundStyle(BeforeTheme.primaryText)
                    .lineLimit(1)

                HStack(spacing: BeforeTheme.Spacing.s) {
                    VerdictBadge(analysis.verdict)
                    Text("\(analysis.score)")
                        .font(BeforeTheme.Typeface.number)
                        .foregroundStyle(BeforeTheme.secondaryText)
                    if let price = Formatting.price(
                        analysis.product.price,
                        currencyCode: analysis.product.currency
                    ) {
                        Text(price)
                            .font(BeforeTheme.Typeface.caption)
                            .foregroundStyle(BeforeTheme.secondaryText)
                    }
                }
            }

            Spacer(minLength: BeforeTheme.Spacing.s)

            Text(Formatting.relativeDay(analysis.createdAt))
                .font(BeforeTheme.Typeface.caption)
                .foregroundStyle(BeforeTheme.tertiaryText)
        }
        .padding(.vertical, BeforeTheme.Spacing.s)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

public struct ProductThumbnail: View {
    private let urlString: String?
    private let category: ProductCategory
    private let size: CGFloat

    public init(
        urlString: String?,
        category: ProductCategory = .other,
        size: CGFloat = BeforeTheme.Sizing.thumbnail
    ) {
        self.urlString = urlString
        self.category = category
        self.size = size
    }

    private var placeholderIcon: String {
        switch category {
        case .beauty: "sparkles"
        case .fashion, .accessory: "tshirt"
        case .home: "house"
        case .travel: "suitcase"
        case .gift: "gift"
        case .other: "photo"
        }
    }

    public var body: some View {
        Group {
            if let urlString, let url = URL(string: urlString) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    case .failure:
                        placeholder
                    case .empty:
                        ProgressView().tint(BeforeTheme.tertiaryText)
                    @unknown default:
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: BeforeTheme.Radius.thumbnail, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: BeforeTheme.Radius.thumbnail, style: .continuous)
                .stroke(BeforeTheme.divider, lineWidth: BeforeTheme.Sizing.hairline)
        )
        .accessibilityHidden(true)
    }

    private var placeholder: some View {
        ZStack {
            BeforeTheme.accentSubtle
            Image(systemName: placeholderIcon)
                .foregroundStyle(BeforeTheme.tertiaryText)
        }
    }
}

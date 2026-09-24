import SwiftUI
import BeforeKit

// =============================================================================
// BEFORE — buttons, cards, chips, and headers.
//
// The whole point of this file is that no feature screen ever writes styling.
// =============================================================================

// MARK: - Buttons

public struct BeforeButton: View {
    private let title: String
    private let systemImage: String?
    private let isLoading: Bool
    private let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    public init(
        _ title: String,
        systemImage: String? = nil,
        isLoading: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.isLoading = isLoading
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: BeforeTheme.Spacing.s) {
                if isLoading {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(BeforeTheme.background)
                } else if let systemImage {
                    Image(systemName: systemImage)
                }
                Text(title)
                    .font(BeforeTheme.Typeface.headline)
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: BeforeTheme.Sizing.buttonHeight)
            .foregroundStyle(BeforeTheme.background)
            .background(
                RoundedRectangle(cornerRadius: BeforeTheme.Radius.control, style: .continuous)
                    .fill(isEnabled ? BeforeTheme.primaryText : BeforeTheme.tertiaryText)
            )
        }
        .buttonStyle(.plain)
        .disabled(isLoading || !isEnabled)
        // VoiceOver needs to know the button is busy, not just that it exists.
        .accessibilityLabel(isLoading ? "\(title), in progress" : title)
        .accessibilityAddTraits(.isButton)
    }
}

public struct BeforeSecondaryButton: View {
    private let title: String
    private let systemImage: String?
    private let action: () -> Void

    public init(_ title: String, systemImage: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: BeforeTheme.Spacing.s) {
                if let systemImage { Image(systemName: systemImage) }
                Text(title).font(BeforeTheme.Typeface.headline)
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: BeforeTheme.Sizing.buttonHeight)
            .foregroundStyle(BeforeTheme.primaryText)
            .background(
                RoundedRectangle(cornerRadius: BeforeTheme.Radius.control, style: .continuous)
                    .stroke(BeforeTheme.divider, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isButton)
    }
}

/// A quiet text button for tertiary actions — "Restore purchases", "Skip".
public struct BeforeTextButton: View {
    private let title: String
    private let role: ButtonRole?
    private let action: () -> Void

    public init(_ title: String, role: ButtonRole? = nil, action: @escaping () -> Void) {
        self.title = title
        self.role = role
        self.action = action
    }

    public var body: some View {
        Button(role: role, action: action) {
            Text(title)
                .font(BeforeTheme.Typeface.callout)
                .foregroundStyle(role == .destructive ? BeforeTheme.destructive : BeforeTheme.secondaryText)
                .frame(minHeight: BeforeTheme.Sizing.minimumTouchTarget)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Surfaces

public struct BeforeCard<Content: View>: View {
    private let content: Content
    private let padding: CGFloat

    public init(padding: CGFloat = BeforeTheme.Spacing.cardPadding, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    public var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: BeforeTheme.Radius.card, style: .continuous)
                    .fill(BeforeTheme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: BeforeTheme.Radius.card, style: .continuous)
                    .stroke(BeforeTheme.divider, lineWidth: BeforeTheme.Sizing.hairline)
            )
    }
}

public struct SectionHeader: View {
    private let title: String
    private let accessory: String?

    public init(_ title: String, accessory: String? = nil) {
        self.title = title
        self.accessory = accessory
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title.uppercased())
                .font(BeforeTheme.Typeface.sectionHeader)
                .tracking(0.8)
                .foregroundStyle(BeforeTheme.secondaryText)
            Spacer(minLength: BeforeTheme.Spacing.s)
            if let accessory {
                Text(accessory)
                    .font(BeforeTheme.Typeface.caption)
                    .foregroundStyle(BeforeTheme.tertiaryText)
            }
        }
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Chips

/// Shows where a product fact came from. Rule 5 lives here visually: an
/// estimate never looks like a confirmed fact.
public struct SourceChip: View {
    private let text: String
    private let source: FactSource

    public init(_ text: String, source: FactSource) {
        self.text = text
        self.source = source
    }

    private var icon: String {
        switch source {
        case .confirmed: "checkmark.seal.fill"
        case .estimated: "questionmark.circle"
        case .unknown: "minus.circle"
        }
    }

    private var tint: Color {
        switch source {
        case .confirmed: BeforeTheme.success
        case .estimated: BeforeTheme.warning
        case .unknown: BeforeTheme.tertiaryText
        }
    }

    private var accessibilityDescription: String {
        switch source {
        case .confirmed: "Confirmed: \(text)"
        case .estimated: "Estimated: \(text)"
        case .unknown: "Not confidently identified: \(text)"
        }
    }

    public var body: some View {
        HStack(spacing: BeforeTheme.Spacing.xs) {
            Image(systemName: icon).font(.caption2)
            Text(text).font(BeforeTheme.Typeface.caption)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, BeforeTheme.Spacing.s)
        .padding(.vertical, BeforeTheme.Spacing.xs)
        .background(Capsule().fill(tint.opacity(0.1)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
    }
}

public struct PremiumBadge: View {
    public init() {}

    public var body: some View {
        Text("PLUS")
            .font(BeforeTheme.Typeface.caption.weight(.semibold))
            .tracking(0.6)
            .foregroundStyle(BeforeTheme.accent)
            .padding(.horizontal, BeforeTheme.Spacing.s)
            .padding(.vertical, 2)
            .background(Capsule().fill(BeforeTheme.accentSubtle))
            .accessibilityLabel("BEFORE Plus")
    }
}

/// A localised price, or an honest statement that we do not know it.
public struct PriceLabel: View {
    private let amount: Double?
    private let currencyCode: String?
    private let font: Font

    public init(amount: Double?, currencyCode: String?, font: Font = BeforeTheme.Typeface.headline) {
        self.amount = amount
        self.currencyCode = currencyCode
        self.font = font
    }

    public var body: some View {
        if let formatted = Formatting.price(amount, currencyCode: currencyCode) {
            Text(formatted)
                .font(font)
                .monospacedDigit()
                .foregroundStyle(BeforeTheme.primaryText)
        } else {
            Text("Price not identified")
                .font(BeforeTheme.Typeface.caption)
                .foregroundStyle(BeforeTheme.tertiaryText)
        }
    }
}

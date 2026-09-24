import SwiftUI
import BeforeKit

// =============================================================================
// BEFORE — theme.
//
// Every colour, radius, and spacing value in the app comes from here. Feature
// code never writes a literal Color or a magic number, so the whole product can
// be re-skinned from one file (spec §4).
//
// Colours are built from UIColor closures rather than asset catalogue entries
// so the palette is readable and reviewable as code, and so a change shows up
// in a diff instead of in a binary plist.
// =============================================================================

public enum BeforeTheme {

    // MARK: - Palette

    /// Warm off-white. Never pure white — it reads clinical next to product
    /// photography.
    public static let background = dynamic(light: 0xFA_F8_F5, dark: 0x12_11_10)
    public static let surface = dynamic(light: 0xFF_FF_FF, dark: 0x1C_1A_18)
    /// One step above `surface`, for a card sitting on a card.
    public static let surfaceRaised = dynamic(light: 0xFF_FF_FF, dark: 0x25_22_1F)
    public static let primaryText = dynamic(light: 0x12_12_12, dark: 0xF5_F2_ED)
    public static let secondaryText = dynamic(light: 0x6B_66_60, dark: 0x9A_94_8C)
    /// For disabled states and the least important metadata only.
    public static let tertiaryText = dynamic(light: 0x9B_95_8D, dark: 0x6E_68_61)
    public static let divider = dynamic(light: 0xE6_E1_DA, dark: 0x2E_2B_27)

    /// Restrained burgundy. Lifted in dark mode, where the deep tone goes muddy.
    public static let accent = dynamic(light: 0x6E_26_39, dark: 0xC4_67_7F)
    public static let accentSubtle = dynamic(light: 0xF3_E9_EC, dark: 0x32_1C_23)

    public static let success = dynamic(light: 0x2F_6B_4F, dark: 0x6F_B8_92)
    public static let warning = dynamic(light: 0x9A_6B_1F, dark: 0xD8_A9_51)
    /// Muted, not alarm red. BYE should read as "good decision to skip", not
    /// as an error (spec §56).
    public static let destructive = dynamic(light: 0x8A_3D_3D, dark: 0xD0_82_82)

    // MARK: - Verdict colours

    public static func color(for verdict: Verdict) -> Color {
        switch verdict {
        case .buy: success
        case .wait: warning
        case .bye: destructive
        }
    }

    /// The tinted background behind a verdict badge.
    public static func tint(for verdict: Verdict) -> Color {
        color(for: verdict).opacity(0.12)
    }

    // MARK: - Typography
    //
    // System fonts only. Every size is a Dynamic Type text style with a weight
    // and tracking applied, so nothing breaks at accessibility sizes.

    public enum Typeface {
        /// The verdict word. The largest thing on any screen.
        public static let verdict = Font.system(.largeTitle, design: .default).weight(.bold)
        /// The score. Monospaced digits so it does not jitter while animating.
        public static let score = Font.system(.largeTitle, design: .rounded)
            .weight(.semibold)
            .monospacedDigit()
        public static let hero = Font.system(.title, design: .default).weight(.bold)
        public static let title = Font.system(.title3).weight(.semibold)
        public static let headline = Font.system(.headline)
        public static let body = Font.system(.body)
        public static let callout = Font.system(.callout)
        public static let caption = Font.system(.caption)
        /// Uppercase section headers.
        public static let sectionHeader = Font.system(.caption).weight(.semibold)
        public static let number = Font.system(.body).monospacedDigit()
    }

    /// Tight tracking on display text; body copy keeps default tracking so it
    /// stays readable.
    public static let displayTracking: CGFloat = -0.5

    // MARK: - Layout

    public enum Spacing {
        /// 4pt grid.
        public static let xs: CGFloat = 4
        public static let s: CGFloat = 8
        public static let m: CGFloat = 12
        public static let l: CGFloat = 16
        public static let xl: CGFloat = 20
        public static let xxl: CGFloat = 32
        public static let section: CGFloat = 32
        /// Screen gutter.
        public static let gutter: CGFloat = 20
        public static let cardPadding: CGFloat = 20
    }

    public enum Radius {
        public static let card: CGFloat = 16
        public static let control: CGFloat = 12
        public static let thumbnail: CGFloat = 10
        public static let pill: CGFloat = 999
    }

    public enum Sizing {
        /// Apple's minimum touch target. Nothing interactive goes below it.
        public static let minimumTouchTarget: CGFloat = 44
        public static let buttonHeight: CGFloat = 52
        public static let scoreRing: CGFloat = 132
        public static let thumbnail: CGFloat = 64
        public static let hairline: CGFloat = 1 / 3
    }

    public enum Motion {
        public static let standard = Animation.easeOut(duration: 0.25)
        /// The score ring reveal. Slightly longer because it is the moment the
        /// whole screen is built around.
        public static let reveal = Animation.easeOut(duration: 0.65)
    }

    // MARK: - Colour construction

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light)
        })
    }
}

private extension UIColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

// =============================================================================
// View conveniences
// =============================================================================

public extension View {
    /// Standard screen padding and background. Every top-level screen uses it.
    func beforeScreen() -> some View {
        self
            .padding(.horizontal, BeforeTheme.Spacing.gutter)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(BeforeTheme.background.ignoresSafeArea())
    }

    /// A hairline divider that survives Dynamic Type and dark mode.
    func beforeDivider() -> some View {
        overlay(alignment: .bottom) {
            Rectangle()
                .fill(BeforeTheme.divider)
                .frame(height: BeforeTheme.Sizing.hairline)
        }
    }
}

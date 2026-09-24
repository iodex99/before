import Foundation

// =============================================================================
// BEFORE — app configuration.
//
// Everything here is public, non-secret information: a project URL, a
// publishable anon key, some product identifiers, and two legal URLs.
//
// The app is allowed to know exactly two credentials — SUPABASE_URL and
// SUPABASE_ANON_KEY — and nothing else. The anon key is safe on a device
// because Row Level Security is what actually protects the data; it is not a
// password. Every real secret (AI keys, the service-role key, the App Store
// signing key) lives server-side. `npm run check:secrets` fails the build if
// anything else shows up under ios/.
//
// Values arrive through Info.plist, populated from Config.xcconfig at build
// time, so a developer can point a build at staging without editing Swift.
// =============================================================================

enum AppConfig {

    enum ConfigError: Error, CustomStringConvertible {
        case missing(String)

        var description: String {
            switch self {
            case .missing(let key):
                "Info.plist is missing \(key). Copy ios/Config.xcconfig.example to Config.xcconfig and fill it in — see docs/SETUP.md."
            }
        }
    }

    private static func string(_ key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func require(_ key: String) -> String {
        guard let value = string(key) else {
            // Deliberately fatal, and only reachable on a misconfigured build:
            // an app that silently points at nothing is worse to debug than one
            // that refuses to start with a message naming the missing key.
            fatalError(String(describing: ConfigError.missing(key)))
        }
        return value
    }

    // MARK: - Backend

    static var supabaseURL: URL {
        guard let url = URL(string: require("SUPABASE_URL")) else {
            fatalError("SUPABASE_URL is not a valid URL")
        }
        return url
    }

    static var supabaseAnonKey: String { require("SUPABASE_ANON_KEY") }

    /// All endpoints are versioned (spec §100).
    static var apiBaseURL: URL { supabaseURL.appendingPathComponent("functions/v1") }

    // MARK: - App Group
    //
    // Shared with the share extension. Change it in Config.xcconfig and in both
    // targets' entitlements together — see docs/SETUP.md.

    static var appGroupIdentifier: String {
        string("APP_GROUP_IDENTIFIER") ?? "group.com.yourcompany.before"
    }

    // MARK: - StoreKit
    //
    // Centralised so a product identifier is never typed twice (spec §34).

    enum Subscription {
        static let groupIdentifier = "before_plus"
        static let monthly = "before.plus.monthly"
        static let yearly = "before.plus.yearly"
        static var all: [String] { [monthly, yearly] }
    }

    // MARK: - Legal
    //
    // Configurable rather than baked in: BEFORE does not invent a company name
    // or a legal entity (spec §78).

    static var termsURL: URL? { string("TERMS_URL").flatMap(URL.init(string:)) }
    static var privacyURL: URL? { string("PRIVACY_URL").flatMap(URL.init(string:)) }
    static var supportEmail: String? { string("SUPPORT_EMAIL") }

    // MARK: - Build environment

    static var isDebugBuild: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    /// Uses bundled fixtures instead of the network. Debug builds only — the
    /// compile-time guard means this cannot be switched on in a release build.
    static var useMockData: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-BEFOREUseMockData")
            || ProcessInfo.processInfo.environment["BEFORE_MOCK"] == "1"
        #else
        false
        #endif
    }

    /// Set by UI tests so a run starts from a known, empty state.
    static var isUITesting: Bool {
        ProcessInfo.processInfo.arguments.contains("-BEFOREUITesting")
    }
}

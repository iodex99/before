import Foundation
import Observation
import UserNotifications
import BeforeKit

// =============================================================================
// BEFORE — notifications.
//
// Spec §64, and the reason this file is short: permission is NEVER requested
// during onboarding, and nothing is scheduled that the user did not ask for.
//
// There are exactly two notifications, and both are opt-in per item:
//
//   1. "Wait 48 hours" — the user taps Remind me on a WAIT verdict. BEFORE
//      already told them to sleep on it; this is the only honest reminder the
//      product has, because the user chose it.
//   2. "How's it going?" — a fortnight after they said they bought something,
//      and only if they have already allowed notifications for reason 1.
//
// There is no re-engagement nudge, no streak, and no "you haven't checked
// anything lately". An app that helps people spend less has no business
// manufacturing reasons to open it.
// =============================================================================

@MainActor
@Observable
public final class NotificationService {

    public enum Permission: Equatable, Sendable {
        case notDetermined
        case authorised
        case denied

        public var canSchedule: Bool { self == .authorised }
    }

    public private(set) var permission: Permission = .notDetermined

    private let center: UNUserNotificationCenter

    public init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    // MARK: - Permission

    /// Read the current state without prompting. Safe to call on launch.
    public func refreshPermission() async {
        let settings = await center.notificationSettings()
        permission = switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: .authorised
        case .denied: .denied
        default: .notDetermined
        }
    }

    /// Ask. Only ever called from a button the user pressed for a stated reason.
    @discardableResult
    public func requestPermission() async -> Bool {
        // Asking again after a denial just shows nothing; send them to Settings.
        guard permission != .denied else { return false }

        let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        permission = granted ? .authorised : .denied
        return granted
    }

    // MARK: - Scheduling

    private enum Identifier {
        static func wait(_ analysisId: String) -> String { "before.wait.\(analysisId)" }
        static func followUp(_ analysisId: String) -> String { "before.followup.\(analysisId)" }
    }

    /// The 48-hour reminder, requested explicitly by the user.
    @discardableResult
    public func scheduleWaitReminder(
        for analysis: Analysis,
        after interval: TimeInterval = 48 * 3600
    ) async -> Bool {
        guard permission.canSchedule else { return false }

        let content = UNMutableNotificationContent()
        content.title = "Still thinking about it?"
        content.body = waitBody(for: analysis)
        content.sound = .default
        content.userInfo = ["analysisId": analysis.analysisId, "kind": "wait_reminder"]

        return await add(
            identifier: Identifier.wait(analysis.analysisId),
            content: content,
            after: interval
        )
    }

    /// The purchase follow-up. Outcomes are the only ground truth BEFORE gets,
    /// so this is the one notification that makes the product better.
    @discardableResult
    public func schedulePurchaseFollowUp(
        for analysis: Analysis,
        after interval: TimeInterval = 14 * 86_400
    ) async -> Bool {
        guard permission.canSchedule else { return false }

        let content = UNMutableNotificationContent()
        content.title = "How's it going?"
        content.body = "You bought \(analysis.product.displayName.lowercased()) a couple of weeks ago. Worth it?"
        content.sound = nil // a quiet, low-stakes question
        content.userInfo = ["analysisId": analysis.analysisId, "kind": "purchase_followup"]

        return await add(
            identifier: Identifier.followUp(analysis.analysisId),
            content: content,
            after: interval
        )
    }

    /// Cancel everything for an analysis. Called when the user records an
    /// outcome — being reminded to decide something already decided is the
    /// fastest way to get notifications turned off.
    public func cancelReminders(for analysisId: String) {
        center.removePendingNotificationRequests(
            withIdentifiers: [Identifier.wait(analysisId), Identifier.followUp(analysisId)]
        )
    }

    public func cancelAll() {
        center.removeAllPendingNotificationRequests()
    }

    public func pendingCount() async -> Int {
        await center.pendingNotificationRequests().count
    }

    // MARK: - Copy

    /// References the actual reason BEFORE hesitated, so the reminder is worth
    /// reading. Falls back to the product name rather than inventing a concern.
    private func waitBody(for analysis: Analysis) -> String {
        if let concern = analysis.reasons.negative.first {
            return "\(analysis.product.displayName): \(concern.lowercased())"
        }
        return "You were thinking about \(analysis.product.displayName.lowercased())."
    }

    private func add(
        identifier: String,
        content: UNMutableNotificationContent,
        after interval: TimeInterval
    ) async -> Bool {
        // Replace rather than duplicate: tapping Remind me twice must not
        // produce two notifications.
        center.removePendingNotificationRequests(withIdentifiers: [identifier])

        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: max(interval, 60), repeats: false)
        )

        do {
            try await center.add(request)
            return true
        } catch {
            return false
        }
    }
}

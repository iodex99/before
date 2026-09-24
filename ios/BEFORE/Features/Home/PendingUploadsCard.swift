import SwiftData
import SwiftUI
import BeforeKit

// =============================================================================
// BEFORE — pending uploads.
//
// Spec §48: never silently discard a pending upload. Writing the row was only
// half of that promise — without somewhere to see it, the photo was preserved
// and then forgotten, which is the same outcome from the user's side.
//
// Retrying reuses the ORIGINAL idempotency key, so if the first attempt did
// reach the server the retry returns that same analysis instead of paying for a
// second one (spec §50).
// =============================================================================

struct PendingUploadsCard: View {
    @Environment(\.modelContext) private var modelContext

    @Query(sort: \PendingUpload.createdAt, order: .forward)
    private var pending: [PendingUpload]

    let onRetry: (AnalysisRequestDraft) -> Void

    var body: some View {
        if let upload = pending.first {
            BeforeCard {
                VStack(alignment: .leading, spacing: BeforeTheme.Spacing.m) {
                    HStack(spacing: BeforeTheme.Spacing.s) {
                        Image(systemName: "arrow.up.circle")
                            .foregroundStyle(BeforeTheme.warning)
                        Text(title)
                            .font(BeforeTheme.Typeface.headline)
                            .foregroundStyle(BeforeTheme.primaryText)
                        Spacer(minLength: 0)
                    }

                    Text(message(for: upload))
                        .font(BeforeTheme.Typeface.callout)
                        .foregroundStyle(BeforeTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: BeforeTheme.Spacing.m) {
                        BeforeSecondaryButton("Discard") { discard(upload) }
                        BeforeButton("Try again") { retry(upload) }
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("home.pendingUpload")
        }
    }

    private var title: String {
        pending.count == 1 ? "One check didn't finish" : "\(pending.count) checks didn't finish"
    }

    private func message(for upload: PendingUpload) -> String {
        // Prefer the real reason over a generic one — "you were offline" and
        // "that image couldn't be read" call for different actions.
        if let reason = upload.lastErrorMessage, !reason.isEmpty {
            return "\(reason) Your photo is still here."
        }
        return "Your photo is still here. BEFORE can pick up where it left off."
    }

    private func retry(_ upload: PendingUpload) {
        upload.attemptCount += 1
        try? modelContext.save()

        onRetry(
            AnalysisRequestDraft(
                imageData: upload.imageData,
                productUrl: upload.productUrlString,
                userNote: upload.userNote,
                inputType: upload.inputType,
                // Reusing the key is what stops a retry costing a second check.
                idempotencyKey: upload.idempotencyKey
            )
        )

        // Removed optimistically: if this attempt also fails, AnalysisFlowView
        // writes a fresh row rather than leaving a stale one behind.
        modelContext.delete(upload)
        try? modelContext.save()
    }

    private func discard(_ upload: PendingUpload) {
        modelContext.delete(upload)
        try? modelContext.save()
    }
}

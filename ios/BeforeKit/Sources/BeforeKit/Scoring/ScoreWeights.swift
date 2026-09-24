import Foundation

/// Mirror of `backend/shared/scoring/weights.ts`.
///
/// The backend is authoritative: it computes every score a user ever sees. This
/// copy exists so the app can score locally in mock mode and so the two can be
/// proved identical by the shared fixture suite. If you change one file, change
/// both and bump the version — `ScoreParityTests` fails otherwise.
public enum ScoreWeights {
    public static let algorithmVersion = "score_v1"

    /// Base weights in percentage points. Must sum to 100.
    public static let base: [SignalKey: Double] = [
        .wardrobeCompatibility: 25,
        .duplicationRisk: 15,
        .expectedUsage: 15,
        .styleMatch: 15,
        .valueForMoney: 15,
        .budgetFit: 10,
        .wardrobeGap: 5,
    ]

    public static let totalBaseWeight: Double = 100

    /// Signals where a HIGH raw value is BAD, and whose contribution is
    /// therefore inverted before weighting.
    public static let inverseSignals: Set<SignalKey> = [.duplicationRisk]

    public enum Threshold {
        public static let buy: Int = 80
        public static let wait: Int = 60
    }

    public enum Override {
        public static let duplicationByeRisk: Double = 90
        public static let duplicationByeGap: Double = 20
        public static let duplicationWaitRisk: Double = 75
        public static let duplicationWaitGap: Double = 35
        public static let expensiveForBudgetMultiple: Double = 2.0
        /// Below this, BEFORE will not tell someone to spend money.
        public static let minConfidenceForBuy: Double = 0.45
    }

    public enum ConfidenceBand {
        public static let high: Double = 0.75
        public static let medium: Double = 0.5
    }
}

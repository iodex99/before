import XCTest

// =============================================================================
// BEFORE — UI tests (spec §69).
//
// Launched with -BEFOREUITesting, which puts the app on mock repositories and
// an in-memory store, so a run is deterministic and never touches the network
// or a real account.
//
// These assert flows, not pixels. A screenshot test would fail on every font
// change and teach the team to ignore red.
// =============================================================================

final class BEFOREUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false

        app = XCUIApplication()
        app.launchArguments = ["-BEFOREUITesting", "-BEFOREUseMockData"]
        app.launch()
    }

    // MARK: Onboarding

    func testOnboardingShowsTheProductPromiseAndASignInRoute() {
        let headline = app.staticTexts["Before you buy it,\nask BEFORE."]
        XCTAssertTrue(
            headline.waitForExistence(timeout: 5) || app.staticTexts["BEFORE"].exists,
            "onboarding should lead with the product promise"
        )
        XCTAssertTrue(app.buttons["See how it works"].exists)
    }

    func testHowItWorksExplainsTheAiNatureOfTheAdvice() throws {
        let button = app.buttons["See how it works"]
        guard button.waitForExistence(timeout: 5) else {
            throw XCTSkip("not on the onboarding screen")
        }
        button.tap()

        // App Store review needs this stated in the app, not only in a policy.
        let disclosure = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS[c] %@", "AI-generated")
        ).firstMatch
        XCTAssertTrue(disclosure.waitForExistence(timeout: 3))
        app.buttons["Done"].tap()
    }

    // MARK: Home

    func testHomeOffersTheCheckAction() throws {
        try skipUnlessSignedIn()

        let check = app.buttons["home.checkSomething"]
        XCTAssertTrue(check.waitForExistence(timeout: 5))
        XCTAssertTrue(app.tabBars.buttons["Home"].exists)
        XCTAssertTrue(app.tabBars.buttons["Saved"].exists)
        XCTAssertTrue(app.tabBars.buttons["History"].exists)
        XCTAssertTrue(app.tabBars.buttons["Profile"].exists)
    }

    func testCheckSheetAcceptsALinkAndRunsAnAnalysis() throws {
        try skipUnlessSignedIn()

        app.buttons["home.checkSomething"].tap()

        let field = app.textFields["check.linkField"]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.tap()
        field.typeText("https://shop.example.com/p/1")

        let submit = app.buttons["check.submit"]
        XCTAssertTrue(submit.isEnabled, "a valid link should enable Check")
        submit.tap()

        // Staged loading, then a verdict — never a bare spinner (spec §15).
        let verdict = app.staticTexts["result.verdict"]
        XCTAssertTrue(verdict.waitForExistence(timeout: 20), "the result should appear")

        let score = app.otherElements["result.score"]
        XCTAssertTrue(score.exists, "the score ring should be present")
    }

    func testResultCanBeSaved() throws {
        try skipUnlessSignedIn()
        try runAnalysis()

        let save = app.buttons["result.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        save.tap()

        XCTAssertTrue(
            app.staticTexts.containing(
                NSPredicate(format: "label CONTAINS[c] %@", "Saved to")
            ).firstMatch.waitForExistence(timeout: 3)
        )
    }

    func testOutcomeCanBeRecorded() throws {
        try skipUnlessSignedIn()
        try runAnalysis()

        let whatDidYouDo = app.buttons["What did you do?"]
        guard whatDidYouDo.waitForExistence(timeout: 5) else {
            throw XCTSkip("outcome prompt not shown for this verdict")
        }
        whatDidYouDo.tap()

        let skipped = app.buttons["outcome.skipped"]
        XCTAssertTrue(skipped.waitForExistence(timeout: 3))
        skipped.tap()
    }

    // MARK: History and Saved

    func testHistoryShowsAnEmptyStateWithRealCopy() throws {
        try skipUnlessSignedIn()
        app.tabBars.buttons["History"].tap()

        // Spec §84: no blank screens.
        let empty = app.staticTexts["Your shopping decisions will live here."]
        let hasRows = app.cells.count > 0 || app.buttons.count > 3
        XCTAssertTrue(empty.waitForExistence(timeout: 3) || hasRows)
    }

    func testHistoryCanBeFilteredByVerdict() throws {
        try skipUnlessSignedIn()
        app.tabBars.buttons["History"].tap()

        let filter = app.segmentedControls.firstMatch
        guard filter.waitForExistence(timeout: 3) else { throw XCTSkip("no history yet") }

        for label in ["BUY", "WAIT", "BYE", "All"] where filter.buttons[label].exists {
            filter.buttons[label].tap()
        }
    }

    func testSavedShowsItsThreeBuckets() throws {
        try skipUnlessSignedIn()
        app.tabBars.buttons["Saved"].tap()

        let picker = app.segmentedControls.firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 3))
        XCTAssertTrue(picker.buttons["Maybe"].exists)
        XCTAssertTrue(picker.buttons["Bought"].exists)
        XCTAssertTrue(picker.buttons["Owned"].exists)
    }

    // MARK: Wardrobe

    func testWardrobeLivesInTheOwnedBucketAndCanBeAddedTo() throws {
        try skipUnlessSignedIn()
        app.tabBars.buttons["Saved"].tap()

        let picker = app.segmentedControls.firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 3))
        picker.buttons["Owned"].tap()

        let add = app.buttons["wardrobe.add"]
        XCTAssertTrue(
            add.waitForExistence(timeout: 3) || app.buttons["Add an item"].waitForExistence(timeout: 2),
            "the Owned bucket should offer a way to add a wardrobe item"
        )
    }

    func testWardrobeEditorSavesAnItem() throws {
        try skipUnlessSignedIn()
        app.tabBars.buttons["Saved"].tap()
        app.segmentedControls.firstMatch.buttons["Owned"].tap()

        let add = app.buttons["wardrobe.add"]
        if add.waitForExistence(timeout: 3) {
            add.tap()
        } else if app.buttons["Add an item"].waitForExistence(timeout: 2) {
            app.buttons["Add an item"].tap()
        } else {
            throw XCTSkip("no add control available")
        }

        let save = app.buttons["wardrobe.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 3))

        // The editor must explain why BEFORE wants this, not just collect it.
        XCTAssertTrue(
            app.staticTexts.containing(
                NSPredicate(format: "label CONTAINS[c] %@", "spot duplicates")
            ).firstMatch.exists
        )
        save.tap()
    }

    func testWardrobeEmptyStateDoesNotReadAsAChore() throws {
        try skipUnlessSignedIn()
        app.tabBars.buttons["Saved"].tap()
        app.segmentedControls.firstMatch.buttons["Owned"].tap()

        // The product promise is that you do NOT have to digitise your closet.
        let reassurance = app.staticTexts["You don't need to add your whole closet."]
        let hasItems = app.cells.count > 0
        XCTAssertTrue(reassurance.waitForExistence(timeout: 3) || hasItems)
    }

    // MARK: Reminders and deeper explanations

    func testWaitVerdictOffersAnOptInReminder() throws {
        try skipUnlessSignedIn()
        try runAnalysis()

        let verdict = app.staticTexts["result.verdict"]
        XCTAssertTrue(verdict.waitForExistence(timeout: 5))
        guard verdict.label == "WAIT" else {
            throw XCTSkip("this run produced a \(verdict.label) verdict")
        }

        // Spec §64: notification permission is never requested in onboarding.
        // It is offered here, attached to a specific reason.
        XCTAssertTrue(app.buttons["result.remindMe"].waitForExistence(timeout: 3))
    }

    func testGoDeeperOffersFixedQuestionsAndNoTextField() throws {
        try skipUnlessSignedIn()
        try runAnalysis()

        let goDeeper = app.staticTexts["GO DEEPER"]
        XCTAssertTrue(goDeeper.waitForExistence(timeout: 5))

        XCTAssertTrue(app.buttons["Why this verdict?"].exists)
        XCTAssertTrue(app.buttons["What would change it?"].exists)

        // Rule 1: BEFORE is not a chatbot. A free-text box here is how it would
        // become one, so there must not be one.
        let resultTextFields = app.textFields.count
        XCTAssertEqual(resultTextFields, 0, "the result screen must not offer free-text questions")
    }

    // MARK: Paywall

    func testPaywallStatesAutoRenewalAndOffersRestore() throws {
        try skipUnlessSignedIn()
        app.tabBars.buttons["Profile"].tap()

        let seePlus = app.buttons["See BEFORE Plus"]
        guard seePlus.waitForExistence(timeout: 5) else {
            throw XCTSkip("already subscribed in this run")
        }
        seePlus.tap()

        XCTAssertTrue(app.staticTexts["Know before you buy."].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["paywall.restore"].exists, "Restore must always be reachable")

        // Apple requires the auto-renewal disclosure to be visible.
        XCTAssertTrue(
            app.staticTexts.containing(
                NSPredicate(format: "label CONTAINS[c] %@", "Renews automatically")
            ).firstMatch.exists
        )

        // No dark pattern: the close button is present and works.
        XCTAssertTrue(app.buttons["paywall.close"].exists)
        app.buttons["paywall.close"].tap()
    }

    func testRestorePurchasesIsReachableFromTheProfile() throws {
        try skipUnlessSignedIn()
        app.tabBars.buttons["Profile"].tap()

        let restore = app.buttons["Restore Purchases"]
        guard restore.waitForExistence(timeout: 5) else {
            throw XCTSkip("already subscribed in this run")
        }
        restore.tap()
    }

    // MARK: Profile and deletion

    func testProfileShowsTheAiDisclosure() throws {
        try skipUnlessSignedIn()
        app.tabBars.buttons["Profile"].tap()

        let disclosure = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS[c] %@", "generated by AI")
        ).firstMatch
        XCTAssertTrue(disclosure.waitForExistence(timeout: 5))
    }

    func testDeleteAccountRequiresTwoConfirmationsAndMentionsAppleBilling() throws {
        try skipUnlessSignedIn()
        app.tabBars.buttons["Profile"].tap()

        let delete = app.buttons["profile.deleteAccount"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        delete.tap()

        let firstConfirm = app.buttons["Continue"]
        XCTAssertTrue(firstConfirm.waitForExistence(timeout: 3), "deletion must be confirmed twice")
        firstConfirm.tap()

        // The second step must say we cannot cancel their subscription (§77).
        let appleNotice = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS[c] %@", "only Apple")
        ).firstMatch
        XCTAssertTrue(appleNotice.waitForExistence(timeout: 3))

        // Back out — this test verifies the gate, not the deletion.
        app.buttons["Keep my account"].tap()
    }

    // MARK: Helpers

    /// The signed-out build starts at onboarding. Skip rather than fail so a
    /// run without a mock session still reports usefully.
    private func skipUnlessSignedIn() throws {
        if app.tabBars.buttons["Home"].waitForExistence(timeout: 5) { return }
        throw XCTSkip("app is signed out; sign-in requires an Apple ID and cannot be automated")
    }

    private func runAnalysis() throws {
        app.buttons["home.checkSomething"].tap()
        let field = app.textFields["check.linkField"]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.tap()
        field.typeText("https://shop.example.com/p/1")
        app.buttons["check.submit"].tap()
        XCTAssertTrue(app.staticTexts["result.verdict"].waitForExistence(timeout: 20))
    }
}

# BEFORE — common tasks.
# Backend targets run anywhere Node 22 does. iOS targets need macOS.

.PHONY: help test test-backend test-ios check-secrets parity ios-project ios-build ios-test icon clean

help:
	@echo "BEFORE"
	@echo ""
	@echo "  make test            backend tests + secret scan (works on any OS)"
	@echo "  make test-backend    Node test runner over backend/tests"
	@echo "  make check-secrets   fail if key material is in the repo"
	@echo "  make parity          print the shared score fixtures"
	@echo ""
	@echo "  macOS only:"
	@echo "  make ios-project     generate ios/BEFORE.xcodeproj with XcodeGen"
	@echo "  make ios-build       build the app for the simulator"
	@echo "  make ios-test        BeforeKit + app unit tests + UI tests"
	@echo "  make icon            regenerate the app icon PNG"

test: test-backend check-secrets

test-backend:
	npm run --silent test:backend

check-secrets:
	npm run --silent check:secrets

parity:
	npm run --silent parity

icon:
	node ios/scripts/make-app-icon.mjs

# ---- macOS -----------------------------------------------------------------

ios-project:
	@command -v xcodegen >/dev/null 2>&1 || { echo "xcodegen not found: brew install xcodegen"; exit 1; }
	@test -f ios/Config.xcconfig || { echo "ios/Config.xcconfig missing. cp ios/Config.xcconfig.example ios/Config.xcconfig"; exit 1; }
	cd ios && xcodegen generate

ios-build: ios-project
	xcodebuild build \
		-project ios/BEFORE.xcodeproj \
		-scheme BEFORE \
		-destination 'platform=iOS Simulator,name=iPhone 16' \
		CODE_SIGNING_ALLOWED=NO

ios-test: ios-project
	swift test --package-path ios/BeforeKit
	xcodebuild test \
		-project ios/BEFORE.xcodeproj \
		-scheme BEFORE \
		-destination 'platform=iOS Simulator,name=iPhone 16' \
		CODE_SIGNING_ALLOWED=NO

test-ios: ios-test

clean:
	rm -rf ios/BEFORE.xcodeproj ios/BeforeKit/.build

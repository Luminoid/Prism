.PHONY: lint lint-fix format check setup-hooks build test test-27 build-example

lint:
	swiftlint

lint-fix:
	swiftlint --fix

format:
	swiftformat .

check:
	swiftlint --strict
	swiftformat --lint .

setup-hooks:
	git config core.hooksPath Scripts/git-hooks
	@echo "Git hooks configured to Scripts/git-hooks/"

# PrismUI needs UIKit and Metal, so the package builds and tests through xcodebuild on an
# iOS simulator; `swift build` targets the macOS host and fails.
DESTINATION ?= platform=iOS Simulator,name=iPhone 17,OS=26.2
DESTINATION_27 ?= platform=iOS Simulator,name=iPhone 17,OS=27.0

build:
	xcodebuild build -scheme Prism-Package -destination '$(DESTINATION)' CODE_SIGNING_ALLOWED=NO -quiet

test:
	xcodebuild test -scheme Prism-Package -destination '$(DESTINATION)' CODE_SIGNING_ALLOWED=NO -quiet

# Runs the iOS 27-gated tests, which report as skipped on the default destination.
test-27:
	xcodebuild test -scheme Prism-Package -destination '$(DESTINATION_27)' CODE_SIGNING_ALLOWED=NO -quiet

build-example:
	xcodebuild build -project Example/PrismExample.xcodeproj -scheme PrismExample -destination '$(DESTINATION_27)' CODE_SIGNING_ALLOWED=NO -quiet

#!/bin/sh
# Xcode Cloud: regenerate the project from project.yml (source of truth)
# and stamp a unique build number for TestFlight.
set -e
cd "$CI_PRIMARY_REPOSITORY_PATH"
brew install xcodegen
xcodegen generate
if [ -n "$CI_BUILD_NUMBER" ]; then
  cd Cini.xcodeproj/.. && agvtool new-version -all "$CI_BUILD_NUMBER"
fi

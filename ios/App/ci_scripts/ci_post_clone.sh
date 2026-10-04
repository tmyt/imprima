#!/bin/sh
# Xcode Cloud: regenerate the Xcode project from project.yml so the committed
# project can never drift from the spec. Runs after the repository is cloned.
set -eu
cd "$(dirname "$0")/.."
brew install xcodegen
xcodegen generate

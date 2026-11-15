#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
command -v xcodegen >/dev/null || { echo "需要先安装 XcodeGen：brew install xcodegen"; exit 1; }
xcodegen generate
xcodebuild -project DeepSeekAIBrowser.xcodeproj -scheme DeepSeekAIBrowser -sdk iphonesimulator -configuration Debug build
#!/bin/bash
# Prepares this repository for building in Xcode on a Mac:
# checks Xcode, installs XcodeGen, creates Config/Local.xcconfig and opens the project.
set -euo pipefail
cd "$(dirname "$0")/.."

developer_dir="$(xcode-select -p 2>/dev/null || true)"
if [[ ! -d /Applications/Xcode.app ]]; then
    echo "❌ Xcode가 없습니다. App Store에서 Xcode를 설치한 뒤 다시 실행하세요."
    echo "   https://apps.apple.com/app/xcode/id497799835"
    exit 1
fi
if [[ "$developer_dir" != /Applications/Xcode.app/* ]]; then
    echo "ℹ️  명령줄 도구가 Xcode를 쓰도록 전환합니다 (Mac 암호 입력)."
    sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
fi
if ! xcodebuild -checkFirstLaunchStatus >/dev/null 2>&1; then
    echo "ℹ️  Xcode 첫 실행 준비(라이선스 동의·구성 요소 설치)를 합니다 (Mac 암호 입력)."
    sudo xcodebuild -runFirstLaunch
fi

if ! command -v brew >/dev/null 2>&1; then
    echo "❌ Homebrew가 없습니다. 터미널에 아래 한 줄을 붙여 넣어 설치한 뒤 다시 실행하세요."
    echo '   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
    exit 1
fi
command -v xcodegen >/dev/null 2>&1 || brew install xcodegen

if [[ ! -f Config/Local.xcconfig ]]; then
    cp Config/Local.xcconfig.example Config/Local.xcconfig
    echo "✅ Config/Local.xcconfig 를 만들었습니다 (번들 ID·Team 개인 설정용)."
fi

xcodegen generate
open HWPViewer.xcodeproj
echo "✅ Xcode에서 HWPViewer 타깃 › Signing & Capabilities › Team 을 고른 뒤 iPad를 선택하고 ▶︎ 를 누르세요."

#!/bin/zsh
# Wraps the SPM binary in a minimal .app bundle so macOS treats AgentDeck as a
# real app (Dock icon, UNUserNotificationCenter banners, proper bundle id).
set -e
cd "$(dirname "$0")/.."
swift build -c release
APP=AgentDeck.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/AgentDeck "$APP/Contents/MacOS/AgentDeck"
# Always (re)generate the icon from the repo's generator — /tmp is wiped on
# reboot, which silently stripped the icon from past bundles.
if [[ -f scripts/generate_icon.py ]]; then
  if command -v python3 >/dev/null && python3 -c "import PIL" >/dev/null 2>&1; then
    python3 scripts/generate_icon.py
  else
    echo "⚠ PIL なし: 既存の icns を使います" >&2
  fi
fi
mkdir -p "$APP/Contents/Resources"
if [[ -f scripts/AgentDeck.icns ]]; then
  cp scripts/AgentDeck.icns "$APP/Contents/Resources/AgentDeck.icns"
else
  echo "⚠ scripts/AgentDeck.icns が見つかりません (アイコンなし)" >&2
fi
# SwiftTerm の Metal シェーダーをリソースへ。SPM ビルドは .metal を
# バンドルしないため、このコピーがないと Metal 有効化が
# "Failed to load Metal shader source" で失敗し CPU 描画のままになる。
ST_SHDIR=".build/checkouts/SwiftTerm/Sources/SwiftTerm/Apple/Metal"
if [[ -f "$ST_SHDIR/Shaders.metal" ]]; then
  cp "$ST_SHDIR/Shaders.metal" "$APP/Contents/Resources/Shaders.metal"
else
  echo "⚠ SwiftTerm Shaders.metal が見つかりません (Metal 描画オフのまま)" >&2
fi
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>dev.agentdeck.app</string>
  <key>CFBundleName</key><string>AgentDeck</string>
  <key>CFBundleDisplayName</key><string>AgentDeck</string>
  <key>CFBundleExecutable</key><string>AgentDeck</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>⌘⌘ 音声入力をターミナルに挿入するためにマイクを使用します。</string>
  <key>NSSpeechRecognitionUsageDescription</key><string>⌘⌘ 音声入力を文字起こしするために音声認識を使用します。</string>
  <key>CFBundleIconFile</key><string>AgentDeck</string>
</dict>
</plist>
PLIST
printf 'APPL????' > "$APP/Contents/PkgInfo"
# UNUserNotificationCenter は署名識別子と CFBundleIdentifier の一致を見る。
# linker-signed のまま (Identifier=AgentDeck) だと requestAuthorization が
# UNErrorDomain Code=1 で即拒否され、通知が一切出ない。
# Apple Development 証明書がキーチェーンにあればそれを使い (システム通知が
# 有効化される)、なければ ad-hoc で識別子のみ揃える。
# Apple 発行証明書を最優先 (自己署名ではシステム通知が拒否されるため)。
CODESIGN_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
  | grep '"Apple Development' | head -1 | grep -oE '"[^"]+"' | tail -1 | tr -d '"' || true)
if [[ -z "$CODESIGN_IDENTITY" ]]; then
  CODESIGN_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -oE '"[^"]+"' | head -1 | tr -d '"' || true)
fi
if [[ -n "$CODESIGN_IDENTITY" ]]; then
  echo "codesign: $CODESIGN_IDENTITY"
  codesign --force --sign "$CODESIGN_IDENTITY" --identifier dev.agentdeck.app "$APP"
else
  codesign --force --sign - --identifier dev.agentdeck.app "$APP" >/dev/null 2>&1 || true
fi
echo "built $APP"

# 毎ビルド /Applications へ同期 (起動中はコピー失敗するため先に終了させる)
DEST="/Applications/AgentDeck.app"
if pgrep -x AgentDeck >/dev/null 2>&1; then
  echo "⚠ AgentDeck 起動中 → 終了してからコピーします" >&2
  osascript -e 'tell application "AgentDeck" to quit' >/dev/null 2>&1 || pkill -x AgentDeck
  sleep 1
fi
rm -rf "$DEST"
cp -R "$APP" "$DEST"
echo "installed $DEST"

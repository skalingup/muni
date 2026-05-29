#!/bin/bash
# Build a self-contained, UNIVERSAL (Apple Silicon + Intel), unsigned Muni.app + .dmg.
# The PDF extractor (Python + PyMuPDF) is bundled as a standalone binary per arch,
# so recipients need nothing installed.
#
# Prerequisites on the BUILD machine (Apple Silicon):
#   - Xcode command line tools (swiftc, lipo)
#   - Rosetta:  softwareupdate --install-rosetta --agree-to-license
#   - native python deps:  python3 -m pip install --user pymupdf pyinstaller
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"; SRC="$HERE/src"; APP="$HERE/build/Muni.app"
rm -rf "$HERE/build"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "[1/6] Extractor — arm64 (native)…"
python3 -m PyInstaller --onefile --name muni-extract-arm64 --noconfirm \
  --distpath "$HERE/build/a/dist" --workpath "$HERE/build/a/work" --specpath "$HERE/build/a" "$SRC/extract.py" >/dev/null
cp "$HERE/build/a/dist/muni-extract-arm64" "$SRC/muni-extract-arm64"

echo "[2/6] Extractor — x86_64 (Rosetta venv)…"
if [ ! -x /tmp/x86env/bin/python ]; then
  arch -x86_64 /usr/bin/python3 -m venv /tmp/x86env
  arch -x86_64 /tmp/x86env/bin/python -m pip install --quiet --upgrade pip
  arch -x86_64 /tmp/x86env/bin/python -m pip install --quiet pymupdf pyinstaller
fi
arch -x86_64 /tmp/x86env/bin/pyinstaller --onefile --name muni-extract-x86_64 --noconfirm \
  --distpath "$HERE/build/x/dist" --workpath "$HERE/build/x/work" --specpath "$HERE/build/x" "$SRC/extract.py" >/dev/null
cp "$HERE/build/x/dist/muni-extract-x86_64" "$SRC/muni-extract-x86_64"

echo "[3/6] Universal Swift binary…"
swiftc -O -target arm64-apple-macosx11.0  "$SRC/main.swift" -o "$HERE/build/m_arm64"
swiftc -O -target x86_64-apple-macosx11.0 "$SRC/main.swift" -o "$HERE/build/m_x86"
lipo -create "$HERE/build/m_arm64" "$HERE/build/m_x86" -o "$APP/Contents/MacOS/Muni"

echo "[4/6] Resources…"
cp "$SRC/reader.html" "$SRC/logo.png" "$SRC/AppIcon.icns" "$SRC/extract.py" "$APP/Contents/Resources/"
cp "$SRC/muni-extract-arm64" "$SRC/muni-extract-x86_64" "$APP/Contents/Resources/"
chmod +x "$APP/Contents/Resources/muni-extract-arm64" "$APP/Contents/Resources/muni-extract-x86_64"
cp "$SRC/Info.plist" "$APP/Contents/Info.plist"

echo "[5/6] Ad-hoc sign…"
xattr -cr "$APP"; codesign --force --deep --sign - "$APP"; codesign --verify --deep "$APP" && echo "  valid ($(lipo -archs "$APP/Contents/MacOS/Muni"))"

echo "[6/6] DMG…"
STAGE="$HERE/build/stage"; mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/Muni.app"; xattr -cr "$STAGE/Muni.app"; ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Muni" -srcfolder "$STAGE" -ov -format UDZO "$HERE/build/Muni.dmg" >/dev/null
rm -rf "$STAGE" "$HERE/build/a" "$HERE/build/x" "$HERE/build/m_arm64" "$HERE/build/m_x86"
echo "Done → $HERE/build/Muni.dmg"

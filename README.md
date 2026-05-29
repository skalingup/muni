# Muni

A calm, paginated PDF reader for macOS. Native (Swift + WebKit), fully self-contained, runs on **Apple Silicon and Intel**.

## Features
- Distraction-free paginated reading — sepia / gray / dark / light themes, adjustable font, size, line spacing, page width
- **Real page numbers** mapped to the source PDF: page N shows page N's content (independent of font size), shown as `96 — 1/3`
- **Fullscreen immersive** mode — text only; arrow keys or click left/right to turn pages, Esc to exit
- **Highlights** (in-page) and **saved quotes**, **bookmarks**, contents list with reading-progress graying
- **Pin up to 3 books**, drag to reorder, search across all your books
- **Find & download** public-domain / open-access books (Project Gutenberg, Standard Ebooks, Internet Archive)
- **Universal undo** of the last 10 actions, with notifications

## Install
1. Download the latest **`Muni.dmg`** from [Releases](../../releases).
2. Open it and drag **Muni** to Applications.
3. The app isn't signed with an Apple Developer certificate, so clear the download-quarantine flag once:
   ```
   xattr -dr com.apple.quarantine /Applications/Muni.app
   ```
   (Or: try to open it, then go to **System Settings ▸ Privacy & Security ▸ "Open Anyway".**)

Requires macOS 11 (Big Sur) or newer. No other dependencies.

## Build from source
`./build.sh` produces a universal, self-contained `.dmg`.
Prerequisites (build machine, Apple Silicon): Xcode command line tools, Rosetta
(`softwareupdate --install-rosetta`), and `python3 -m pip install --user pymupdf pyinstaller`.

## How it works
A native Swift shell (`src/main.swift`) hosts the entire reader UI — a single self-contained
HTML/CSS/JS file (`src/reader.html`) — in a `WKWebView`. PDF text is extracted by `src/extract.py`
(PyMuPDF), bundled per-architecture as a standalone binary so users need nothing installed.

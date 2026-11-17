# Better Notepad

A native macOS (14+) plain-text editor that works like Windows 11 Notepad: tabs, continuous autosave,
full session restore, a line-selection gutter and a Notepad-style status bar. Built with AppKit
(NSTextView on TextKit 2) plus SwiftUI for the tab bar, find bar, status bar and Settings.

## Project layout

```
project.yml                      XcodeGen spec (regenerates BetterNotepad.xcodeproj)
install.sh                       Release build + install into /Applications
BetterNotepad/
  Info.plist                     Bundle info + .txt / text document type registration
  Assets.xcassets                App icon
  App/       main.swift, AppDelegate.swift (launch/quit/open events), MainMenu.swift
  Model/     Preferences, SessionStore (autosave + session.json), TextFileFormat
             (encoding & line-ending codec), LineIndex (incremental line table), TextSearch, RecentFiles
  Editor/    EditorTab (one document), NotepadTextView (margin line selection, context menu),
             LineNumberRulerView (gutter)
  Window/    MainWindowController (tabs, file actions, find/replace, go to line, change monitor)
  Views/     TabBarView, FindBarView, StatusBarView, SettingsView (SwiftUI)
```

## Build and run

The active developer directory on this Mac is the Command Line Tools, so either prefix commands with
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` (what `install.sh` does) or switch once with
`sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`.

- **In Xcode:** open `BetterNotepad.xcodeproj`, pick the *BetterNotepad* scheme, press ⌘R.
- **From the terminal:** `./install.sh` builds Release and installs to `/Applications/Better Notepad.app`.

If you edit `project.yml` or add files, run `xcodegen generate` to refresh the project.

## Set as the default app for .txt

Any one of:
1. Better Notepad → Settings (⌘,) → **Make Better Notepad the Default App for .txt Files** (macOS asks to confirm).
2. Finder: select any `.txt` file → ⌘I → *Open with:* Better Notepad → **Change All…**
3. With Homebrew `duti`: `duti -s com.betternotepad.BetterNotepad public.plain-text all`

## Where data lives

`~/Library/Application Support/Better Notepad/`
- `session.json` – tab order, selected tab, per-tab cursor/selection/scroll, window frame
- `Unsaved/<tab-id>.txt` – autosaved contents of tabs with unsaved changes (written ~1 s after you stop typing)

Real files are only written on ⌘S, unless *Autosave directly to the file* is on in Settings.
Closing the window or quitting never prompts; closing a single tab with changes asks Save / Don't Save / Cancel.

## Shortcuts

| Action | Keys |
|---|---|
| New tab / Close tab | ⌘T / ⌘W |
| Next / previous tab | ⇧⌘] / ⇧⌘[ |
| Open / Save / Save As / Save All | ⌘O / ⌘S / ⇧⌘S / ⌥⌘S |
| Find / Find & Replace | ⌘F / ⌥⌘F |
| Find next / previous | ⌘G / ⇧⌘G |
| Go to line | ⌘L |
| Zoom in / out / reset | ⌘= / ⌘- / ⌘0 |
| Insert time/date | F5 (fn‑F5 on laptop keyboards) |
| Settings | ⌘, |

Click in the line-number gutter (or the narrow left margin when numbers are hidden) to select a line;
drag to select several; triple-click anywhere selects the line.

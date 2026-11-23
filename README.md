# Better Notepad

A native macOS (14+) plain-text editor that works like Windows 11 Notepad: tabs and multiple windows,
continuous autosave, full session restore, whole-line selection from the left margin and a Notepad-style
status bar. Built with AppKit (NSTextView on TextKit 2) plus SwiftUI for the tab bar, find bar, status bar
and Settings.

**[Download the latest version](https://github.com/saoneill01-a11y/Better-Notepad/releases/latest/download/Better-Notepad.dmg)**
(signed and notarized; open the disk image and drag Better Notepad into Applications). Installed copies
check for updates automatically.

## Features

- Tabs (drag to reorder, unsaved dot, ⇧⌘T reopens a closed tab) and multiple windows (⇧⌘N, or move a tab to its own window)
- Drag a tab out of the window to open it in a new window, onto another window's tab bar to move it there,
  or onto Finder / the Desktop to save a copy named after its first line (asks which, or set a default in Settings).
  Drag a whole window by its title bar onto another window's title or tab bar to merge its tabs into it.
- Autosave of every tab, including untitled ones, without touching the real file until ⌘S; nothing prompts on quit
- Session restore: windows, tabs, cursor, selection, scroll position
- Markdown: `.md` files show formatting right in the editor (headings, bold, italic, lists, checklists, links,
  code) with the symbols faded, a formatting toolbar (⌘B, ⌘I, ⌘K…), lists that continue on Return, clickable
  checkboxes, and an optional live preview beside the text (⌥⌘P). Files stay plain Markdown.
- Find & Replace (match case, whole word), Go to Line, Insert Time/Date (F5)
- Keeps each file's encoding and line endings; change either from the status bar or in Save As
- Print and Page Setup, word wrap, optional line numbers, zoom (keys or pinch), spell check
- Light, Dark or System appearance
- Opens files of tens of MB (a 40 MB file opens in about 0.2 s)

## Project layout

```
project.yml                      XcodeGen spec (regenerates BetterNotepad.xcodeproj); Sparkle and swift-markdown via SwiftPM
install.sh                       Release build + install into /Applications (local use)
release.sh                       Signed + notarized Better-Notepad.dmg and Sparkle appcast.xml for publishing
BetterNotepad/
  Info.plist                     Bundle info, .txt document types, Sparkle feed URL and public key
  Assets.xcassets                App icon
  App/       main.swift, AppDelegate.swift (windows, session, updates, open events), MainMenu.swift,
             Diagnostics.swift (Debug-only self tests)
  Model/     Preferences, SessionStore (autosave + session.json), TextFileFormat
             (encoding & line-ending codec), LineIndex (incremental line table), TextSearch, RecentFiles
  Editor/    EditorTab (one document), NotepadTextView (margin line selection, context menu, spelling),
             LineNumberRulerView (gutter), MarkdownStyler (in-editor formatting), MarkdownCommands
             (toolbar actions, list continuation), MarkdownPreview (HTML renderer + WKWebView pane)
  Window/    MainWindowController (one window: tabs, file actions, find/replace, printing), PrintRenderer
  Views/     TabBarView, FindBarView, StatusBarView, SettingsView (SwiftUI), Theme (light/dark colours)
```

## Build and run

The active developer directory on this Mac is the Command Line Tools, so either prefix commands with
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` (what the scripts do) or switch once with
`sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`.

- **In Xcode:** open `BetterNotepad.xcodeproj`, pick the *BetterNotepad* scheme, press ⌘R.
- **From the terminal:** `./install.sh` builds Release and installs to `/Applications/Better Notepad.app`.

If you edit `project.yml` or add files, run `xcodegen generate` to refresh the project.

## Releasing a new version

1. Raise `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `project.yml`.
2. `./release.sh` – builds, signs (Developer ID), notarizes and staples `build/Better-Notepad.dmg` and writes
   `build/appcast.xml`. It needs the `notary` notarytool profile and the Sparkle private key in
   `~/.config/better-notepad/sparkle_private_key` (also stored in the login keychain).
3. `gh release create vX.Y build/Better-Notepad.dmg build/appcast.xml --title "Better Notepad X.Y"`

Keep a backup of the Sparkle private key: without it, existing installs can't verify new updates.

## Set as the default app for .txt

Any one of:
1. Better Notepad → Settings (⌘,) → **Make Better Notepad the Default App for .txt Files** (macOS asks to confirm).
2. Finder: select any `.txt` file → ⌘I → *Open with:* Better Notepad → **Change All…**
3. With Homebrew `duti`: `duti -s com.csioly.betternotepad public.plain-text all`

## Where data lives

`~/Library/Application Support/Better Notepad/`
- `session.json` – windows, tab order, selected tab, per-tab cursor/selection/scroll, window frames
- `Unsaved/<tab-id>.txt` – autosaved contents of tabs with unsaved changes (written ~1 s after you stop typing)

Real files are only written on ⌘S, unless *Autosave directly to the file* is on in Settings.
Quitting, or closing the last window, never prompts. Closing a tab, or one of several windows, asks
Save / Don't Save / Cancel for tabs with unsaved changes.

## Shortcuts

| Action | Keys |
|---|---|
| New tab / New window | ⌘T / ⇧⌘N |
| Close tab / Close window | ⌘W / ⇧⌘W |
| Reopen closed tab | ⇧⌘T |
| Next / previous tab | ⇧⌘] / ⇧⌘[ |
| Open / Save / Save As / Save All | ⌘O / ⌘S / ⇧⌘S / ⌥⌘S |
| Print / Page Setup | ⌘P / ⇧⌘P |
| Find / Find & Replace | ⌘F / ⌥⌘F |
| Find next / previous | ⌘G / ⇧⌘G |
| Go to line | ⌘L |
| Zoom in / out / reset | ⌘= / ⌘- / ⌘0, or pinch; two-finger double-tap resets |
| Insert time/date | F5 (fn‑F5 on laptop keyboards) |
| Markdown formatting on/off / Preview | ⇧⌘M / ⌥⌘P |
| Bold / Italic / Strikethrough / Code / Link | ⌘B / ⌘I / ⇧⌘X / ⌘E / ⌘K |
| Heading 1–3 / Normal text | ⌥⌘1–3 / ⌥⌘0 |
| Bulleted / Numbered list / Checklist / Quote | ⇧⌘8 / ⇧⌘7 / ⇧⌘9 / ⇧⌘' |
| Settings | ⌘, |

Click in the left margin (or the line-number gutter) to select a line; drag to select several;
triple-click anywhere selects the line.

## Known limitation

Files with a single extremely long line (several MB with no line breaks, such as minified JSON) open,
but typing in them is slow (around 0.15 s per key for a 2 MB line). Both of Apple's text engines lay out a
whole line at once, so this would need a custom text engine to fix.

## License

MIT – see [LICENSE](LICENSE).

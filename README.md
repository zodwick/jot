<img src="Resources/AppIcon.png" width="128" alt="Jot icon">

# Jot

One endless, auto-saved Markdown page in a floating Liquid Glass window. No files, no names. Built for throwaway drafting.

## Build & install

```bash
scripts/bundle.sh            # release build → build/Jot.app
cp -R build/Jot.app /Applications/
```

`swift scripts/make_icon.swift` redraws the app icon (`Resources/AppIcon.png` and `.icns`).
You only need the Xcode Command Line Tools (Swift 6.2+). The app targets macOS 26 or later.

## Using it

| | |
|---|---|
| ⌥Space | Show or hide Jot from anywhere |
| ⌘⇧P | Float on top of other windows |
| ⌘, | Settings: glass density (clear ↔ frosted), text size |
| ⌘B / ⌘I / ⌘E / ⌘⇧X | Bold / italic / inline code / strikethrough |
| ⌘8 / ⌘7 / ⌘⇧L | Bulleted / numbered / checklist |
| Tab / ⇧Tab | Nest / un-nest list items (or ⌘] / ⌘[) |
| ⌘F | Find |

Type Markdown and the markers disappear as you go:

- `- ` makes a bullet and `1. ` a numbered item.
- `[] ` makes a checkbox; click it to tick it.
- `# ` makes a heading and `> ` a quote.
- `---` makes a divider.
- ```` ``` ```` followed by Return opens a code block, and Jot closes it for you.

On a list item, Return continues the list. Return on an empty item ends it, and Backspace at the start of an item removes its bullet.

Paste or drop a file to add it. Images appear inline. Other files show as a chip that you double-click to open.

## Where things live

`~/Library/Application Support/Jot/`:

- `page.md`: the page, as plain Markdown that any editor can open.
- `attachments/`: copies of everything you pasted or dropped in.
- `backups/`: one copy of the page per day, kept for 7 days.

## Design notes

- **Liquid Glass.** Apple's guidelines reserve glass for floating layers, not content backgrounds. Jot's whole window is a small panel floating over other apps, so it uses the adaptive `.regular` glass with a tinted layer under the text; the density slider controls that layer. It switches to `.clear` only at the very bottom of the slider. When Reduce Transparency is on, the window is fully opaque.
- **TextKit 1, on purpose.** It is the only text stack with a per-glyph hook for hiding Markdown markers, and its scroll heights are exact.
  - Hidden markers are zero-width control glyphs, never `.null`; null glyphs at the start of a line break indentation.
  - Bullets are the real `-` character with a `•` drawn over it, which keeps cursor positions simple.
  - Images and files are single attachment characters that are turned back into Markdown on save and copy.
- **Self-test.** `JOT_SELFTEST=1 .build/release/Jot` runs the editing cases and a 20k-line performance check. Set `JOT_DATA_DIR=/some/dir` to point the app at a scratch data folder.

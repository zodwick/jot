<img src="Resources/AppIcon.png" width="128" alt="Jot icon">

# Jot

One endless, auto-saved Markdown page in a floating Liquid Glass window. No files, no names. Built for throwaway drafting.

## Build & install

```bash
scripts/bundle.sh --install  # release build → /Applications/Jot.app
```

`swift scripts/make_icon.swift` redraws the app icon (`Resources/AppIcon.png` and `.icns`).
You only need the Xcode Command Line Tools (Swift 6.2+). The app targets macOS 26 or later.

## Using it

| | |
|---|---|
| ⌘⇧P | Float on top of other windows (the glass gets a little clearer while floating) |
| ⌘, | Settings: glass density (clear ↔ frosted), text size, optional ⌥Space show/hide shortcut |
| ⌘B / ⌘I / ⌘E / ⌘⇧X | Bold / italic / inline code / strikethrough |
| ⌘8 / ⌘7 / ⌘⇧L | Bulleted / numbered / checklist |
| Tab / ⇧Tab | Nest / un-nest list items (or ⌘] / ⌘[) |
| ⌘F | Find |
| ⌘1 | Show the pad again (so does ⌘Tab back to Jot or clicking its Dock icon) |

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

- **Liquid Glass.** Apple's guidelines reserve glass for floating layers, not content backgrounds. Jot's whole window is a small panel floating over other apps, so it uses the adaptive `.regular` glass with a tinted layer under the text; the density slider controls that layer. It switches to `.clear` only at the very bottom of the slider. When Reduce Transparency is on, the window is fully opaque. While floating on top, the layer is set as if the slider were 0.12 closer to Clear, but never less than half its normal strength (0 stays 0, 0.35 → 0.23, 1 → 0.88), and the change fades unless Reduce Motion is on.
- **Text-height cursor.** `NSTextView` sizes its cursor to the whole line, so beside an inline image it grows to the image's height, and since macOS 14 its old drawing hook is never called. Like STTextView, Jot hides the built-in cursor and places the system's own `NSTextInsertionIndicator` itself, sized to the font on the text baseline.
- **One copy at a time.** Jot locks its data folder at launch, so a second copy brings the first one forward and quits instead of writing the same `page.md`.
- **TextKit 1, on purpose.** It is the only text stack with a per-glyph hook for hiding Markdown markers, and its scroll heights are exact.
  - Hidden markers are zero-width control glyphs, never `.null`; null glyphs at the start of a line break indentation.
  - Bullets are the real `-` character with a `•` drawn over it, which keeps cursor positions simple.
  - Images and files are single attachment characters that are turned back into Markdown on save and copy.
- **Self-test.** `JOT_SELFTEST=1 .build/release/Jot` runs the editing cases and a 20k-line performance check. Set `JOT_DATA_DIR=/some/dir` to point the app at a scratch data folder.

## License

MIT. See [LICENSE](LICENSE).

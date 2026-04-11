# Spec for Stu Anki Import/Export

branch: claude/feature/stu-anki-import-export

## Summary

Add two-way conversion between stu flashcard sessions (`.stu/*.json`) and Anki decks (`.apkg` files). Users can export a stu flashcard session to an Anki-compatible deck for use in Anki, and import an Anki deck (exported as a tab-delimited `.txt` or `.apkg`) into a stu flashcard session stored in `.stu/`.

## Functional Requirements

### Export: stu flashcard → Anki deck

- A new CLI subcommand `stu export <file.json>` converts a stu flashcard session to an Anki-importable format.
- The output format is a tab-delimited `.txt` file (one card per line: `front\tback\n`) which Anki can import via File → Import.
- The output file is written to the current directory, named after the session title (slugified), e.g. `go-basics.txt`.
- If the `--output` flag is provided, write to that path instead.
- Only sessions with `"type": "flashcards"` are valid for export; quiz sessions produce a clear error.
- Card front maps to `Card.front`, card back maps to `Card.back`. The optional `Card.explanation` is appended to the back field, separated by `<br>`, so it appears as a note in Anki.

### Import: Anki deck → stu flashcard session

- A new CLI subcommand `stu import <file.txt>` converts an Anki tab-delimited export into a stu flashcard session saved in `.stu/`.
- The input is a tab-delimited `.txt` file (Anki "Notes in Plain Text" export format): each line is `front\tback`.
- Lines beginning with `#` are treated as comments and skipped.
- The session `title` defaults to the filename (without extension, de-slugified). A `--title` flag overrides this.
- `difficulty` defaults to `"medium"`. A `--difficulty` flag accepts `easy`, `medium`, or `hard`.
- The output session is saved to `.stu/<slugified-title>.json` with `"type": "flashcards"`, `"created_at"` set to the current UTC time, and an empty `"sources"` array.
- If a `.stu/<slugified-title>.json` already exists, the command exits with an error unless `--force` is passed.

## Possible Edge Cases

- Cards with tabs in their content may cause mis-parsing; the importer should handle quoted fields or warn on lines with unexpected tab counts.
- Anki HTML entities (`&nbsp;`, `<br>`, etc.) in imported card text should be preserved as-is rather than stripped, since stu renders in a terminal and the user may want to clean them manually.
- Empty front or back fields should be skipped with a warning, not cause a panic.
- The `.stu/` directory may not exist; the importer should create it if absent.
- A session with zero cards after filtering should produce an error rather than an empty session file.
- File path collisions on export (output file already exists) should prompt or error unless `--force` is passed.

## Acceptance Criteria

- `stu export <flashcard-session.json>` produces a valid tab-delimited `.txt` file that Anki can import without error.
- `stu import <anki-export.txt>` produces a valid `.stu/*.json` file that `stu <file.json>` can open and play through.
- Passing a quiz session to `stu export` exits non-zero with a descriptive error message.
- Passing a malformed or non-existent file to either command exits non-zero with a clear error.
- Round-trip: exporting a stu session then re-importing the result produces a session with the same number of cards and equivalent front/back content.
- `--output`, `--title`, `--difficulty`, and `--force` flags work as specified.

## Open Questions

- Should `.apkg` (SQLite-based binary) be supported directly, or is the tab-delimited `.txt` format sufficient for an initial version? (`.apkg` requires SQLite and Anki's schema; `.txt` is simpler and covers the common import/export workflow.)
- Should `stu export` support a `--html-strip` flag to remove HTML tags from card content before writing?
- Should multi-line card backs (Anki supports `\n` within a quoted field) be supported in the importer?

## Testing Guidelines

Create test files in `./internal/anki/` (or alongside the command in `./cmd/stu/`) covering:

- Export produces correct tab-delimited output for a known flashcard session fixture.
- Export correctly appends `Card.explanation` to the back field when present.
- Export rejects a session with `"type": "quiz"`.
- Import correctly parses a known tab-delimited fixture into the expected `Session` struct.
- Import skips comment lines and empty lines without error.
- Import handles lines with missing back field (only front present) by skipping with a warning.
- Round-trip: marshal a session → export to bytes → import from bytes → compare card count and content.

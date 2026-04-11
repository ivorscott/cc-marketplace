# Spec for Stu Anki Import/Export

branch: claude/feature/stu-anki-import-export

## Summary

Add two-way conversion between stu flashcard sessions (`.stu/*.json`) and Anki decks. Users can export a stu flashcard session to an Anki-compatible `.apkg` deck or tab-delimited `.txt` file, and import either format into a stu flashcard session stored in `.stu/`.

## Functional Requirements

### Export: stu flashcard → Anki deck

- A new CLI subcommand `stu export <file.json>` converts a stu flashcard session to an Anki-importable format.
- The default output format is `.apkg` (Anki's native SQLite-based package), built using `github.com/mattn/go-sqlite3`. A `--format txt` flag writes a tab-delimited `.txt` file instead (one card per line: `front\tback\n`), useful for manual inspection or older Anki versions.
- The output file is written to the current directory, named after the session title (slugified), e.g. `go-basics.apkg` or `go-basics.txt`.
- If the `--output` flag is provided, write to that path instead.
- Only sessions with `"type": "flashcards"` are valid for export; quiz sessions produce a clear error.
- Card front maps to `Card.front`, card back maps to `Card.back`. The optional `Card.explanation` is appended to the back field, separated by `<br>`, so it appears as a note in Anki.
- When producing `.apkg`, media files referenced in card HTML (`<img src="...">`, `[sound:...]`) are scanned from the card fields, resolved relative to the session file's directory, and embedded in the `.apkg` zip alongside the `media` manifest JSON.
- If `--html-strip` is passed, HTML tags are stripped from all card fields before writing (media embedding is skipped when `--html-strip` is active).

### Import: Anki deck → stu flashcard session

- A new CLI subcommand `stu import <file>` converts an Anki export into a stu flashcard session saved in `.stu/`.
- Supported input formats:
  - `.txt`: Anki "Notes in Plain Text" export (tab-delimited, one note per logical line). Lines beginning with `#` are treated as comments and skipped.
  - `.apkg`: Anki's native package format (SQLite). The importer reads the embedded `collection.anki2` database and extracts the first note type's front and back fields.
- Multi-line card backs are supported: Anki encodes newlines as `<br>` in `.apkg` fields and as `\n` within quoted fields in `.txt`. Both are preserved in `Card.back` as `\n` so stu can render them.
- The session `title` defaults to the filename (without extension, de-slugified). A `--title` flag overrides this.
- `difficulty` defaults to `"medium"`. A `--difficulty` flag accepts `easy`, `medium`, or `hard`.
- The output session is saved to `.stu/<slugified-title>.json` with `"type": "flashcards"`, `"created_at"` set to the current UTC time, and an empty `"sources"` array.
- If a `.stu/<slugified-title>.json` already exists, the command exits with an error unless `--force` is passed.

## Possible Edge Cases

- Cards with tabs in their content may cause mis-parsing in `.txt` mode; the importer should handle quoted fields or warn on lines with unexpected tab counts.
- `.apkg` files embed a SQLite database (`collection.anki2`) inside a zip archive; the importer must handle zip extraction and SQLite reads via `github.com/mattn/go-sqlite3`, and fail cleanly if the file is corrupt or not a valid `.apkg`.
- Anki note types vary; the `.apkg` importer should map the first two fields of the first note type to front/back, and warn if a note has fewer than two fields.
- Anki HTML entities (`&nbsp;`, `<br>`, etc.) in imported card text are preserved unless `--html-strip` is passed.
- Empty front or back fields should be skipped with a warning, not cause a panic.
- The `.stu/` directory may not exist; the importer should create it if absent.
- A session with zero cards after filtering should produce an error rather than an empty session file.
- File path collisions on export (output file already exists) should prompt or error unless `--force` is passed.
- A media file referenced in card HTML that cannot be found on disk should log a warning and be skipped, not abort the export.
- Media embedding is silently skipped when `--html-strip` is active (no warning needed).

## Acceptance Criteria

- `stu export <flashcard-session.json>` produces a valid `.apkg` file that Anki can open, and a valid `.txt` file when `--format txt` is used.
- `stu import <file.apkg>` and `stu import <file.txt>` each produce a valid `.stu/*.json` file that `stu <file.json>` can open and play through.
- `--html-strip` removes HTML tags from all card fields on both export and import.
- Multi-line card backs round-trip correctly: newlines survive export to `.apkg`/`.txt` and re-import without corruption.
- Passing a quiz session to `stu export` exits non-zero with a descriptive error message.
- Passing a malformed, corrupt, or non-existent file to either command exits non-zero with a clear error.
- Round-trip: exporting a stu session then re-importing the result produces a session with the same number of cards and equivalent front/back content.
- `--format`, `--output`, `--title`, `--difficulty`, `--html-strip`, and `--force` flags work as specified.

## Open Questions

None — all questions resolved.

## Testing Guidelines

Create test files in `./internal/anki/` (or alongside the command in `./cmd/stu/`) covering:

- Export to `.apkg` produces a zip containing a valid SQLite `collection.anki2` with the expected note rows, a `media` JSON manifest, and any referenced media files.
- Export to `.apkg` with a missing media file logs a warning but still produces a valid `.apkg`.
- Export to `.txt` (`--format txt`) produces correct tab-delimited output for a known flashcard session fixture.
- Export correctly appends `Card.explanation` to the back field when present.
- `--html-strip` removes tags from front and back on export.
- Export rejects a session with `"type": "quiz"`.
- Import from `.txt` correctly parses a known tab-delimited fixture, including multi-line backs encoded as quoted `\n`.
- Import from `.apkg` extracts notes from the embedded SQLite database and maps them to cards.
- `<br>` tags in `.apkg` back fields are normalized to `\n` on import (unless `--html-strip` is also passed, in which case they are removed).
- Import skips comment lines and empty lines without error.
- Import handles notes with fewer than two fields by skipping with a warning.
- Round-trip (`.txt`): marshal a session → export to `.txt` bytes → import → compare card count and content.
- Round-trip (`.apkg`): marshal a session → export to `.apkg` bytes → import → compare card count and content.

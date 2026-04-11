package anki

import (
	"archive/zip"
	"database/sql"
	"encoding/csv"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"

	_ "github.com/mattn/go-sqlite3"

	"github.com/ivorscott/stu/internal/types"
)

// ImportOptions controls the behaviour of ImportFile.
type ImportOptions struct {
	Title      string // "" = derive from filename
	Difficulty string // "easy"|"medium"|"hard"; default "medium"
	Force      bool   // overwrite existing .stu/<slug>.json
}

// ImportFile imports an Anki file (.txt or .apkg) into a stu flashcard session
// saved under stuDir. stuDir is typically filepath.Join(cwd, ".stu").
func ImportFile(inputPath string, opts ImportOptions, stuDir string) error {
	ext := strings.ToLower(filepath.Ext(inputPath))
	switch ext {
	case ".txt":
		return importTXT(inputPath, opts, stuDir)
	case ".apkg":
		return importAPKG(inputPath, opts, stuDir)
	default:
		return fmt.Errorf("import: unsupported format %q: want .txt or .apkg", ext)
	}
}

// sessionTitle returns the title to use, falling back to Deslugify(filename).
func sessionTitle(opts ImportOptions, inputPath string) string {
	if opts.Title != "" {
		return opts.Title
	}
	base := strings.TrimSuffix(filepath.Base(inputPath), filepath.Ext(inputPath))
	return Deslugify(base)
}

// sessionDifficulty returns the difficulty, defaulting to "medium".
func sessionDifficulty(opts ImportOptions) string {
	if opts.Difficulty != "" {
		return opts.Difficulty
	}
	return "medium"
}

// writeSession marshals s and writes it to stuDir/<slug>.json.
func writeSession(s *types.Session, stuDir string, force bool) error {
	if err := os.MkdirAll(stuDir, 0o755); err != nil {
		return fmt.Errorf("import: create .stu dir: %w", err)
	}
	slug := Slugify(s.Title)
	dst := filepath.Join(stuDir, slug+".json")
	if _, err := os.Stat(dst); err == nil && !force {
		return fmt.Errorf("import: output file already exists: %s (use --force to overwrite)", dst)
	}
	data, err := json.MarshalIndent(s, "", "  ")
	if err != nil {
		return fmt.Errorf("import: marshal session: %w", err)
	}
	if err := os.WriteFile(dst, data, 0o644); err != nil {
		return fmt.Errorf("import: write session: %w", err)
	}
	return nil
}

// importTXT parses an Anki tab-delimited text export and writes a stu session.
func importTXT(inputPath string, opts ImportOptions, stuDir string) error {
	f, err := os.Open(inputPath)
	if err != nil {
		return fmt.Errorf("import txt: open %s: %w", inputPath, err)
	}
	defer f.Close()

	r := csv.NewReader(f)
	r.Comma = '\t'
	r.Comment = '#'
	r.LazyQuotes = true
	r.FieldsPerRecord = -1 // allow variable field count

	var cards []types.Card
	id := 1
	for {
		record, err := r.Read()
		if err == io.EOF {
			break
		}
		if err != nil {
			fmt.Fprintf(os.Stderr, "warning: skipping malformed line: %v\n", err)
			continue
		}
		if len(record) < 2 {
			fmt.Fprintf(os.Stderr, "warning: skipping line with fewer than 2 fields\n")
			continue
		}
		front := strings.TrimSpace(record[0])
		back := strings.TrimSpace(record[1])
		if front == "" {
			fmt.Fprintf(os.Stderr, "warning: skipping card with empty front field\n")
			continue
		}
		if back == "" {
			fmt.Fprintf(os.Stderr, "warning: skipping card with empty back field\n")
			continue
		}
		cards = append(cards, types.Card{ID: id, Front: front, Back: back})
		id++
	}

	if len(cards) == 0 {
		return fmt.Errorf("import txt: no valid cards found in %s", inputPath)
	}

	s := &types.Session{
		Type:       types.TypeFlashcard,
		Title:      sessionTitle(opts, inputPath),
		Difficulty: sessionDifficulty(opts),
		Sources:    []string{},
		CreatedAt:  time.Now().UTC(),
		Cards:      cards,
	}
	return writeSession(s, stuDir, opts.Force)
}

// importAPKG reads an Anki .apkg file and writes a stu session.
func importAPKG(inputPath string, opts ImportOptions, stuDir string) error {
	zr, err := zip.OpenReader(inputPath)
	if err != nil {
		return fmt.Errorf("import apkg: open zip %s: %w", inputPath, err)
	}
	defer zr.Close()

	// Find and extract collection.anki2.
	var colEntry *zip.File
	for _, f := range zr.File {
		if f.Name == "collection.anki2" {
			colEntry = f
			break
		}
	}
	if colEntry == nil {
		return fmt.Errorf("import apkg: collection.anki2 not found in %s", inputPath)
	}

	tmp, err := os.CreateTemp("", "anki-import-*.anki2")
	if err != nil {
		return fmt.Errorf("import apkg: create temp: %w", err)
	}
	tmpPath := tmp.Name()
	defer os.Remove(tmpPath)

	rc, err := colEntry.Open()
	if err != nil {
		tmp.Close()
		return fmt.Errorf("import apkg: open collection.anki2 in zip: %w", err)
	}
	if _, err := io.Copy(tmp, rc); err != nil {
		rc.Close()
		tmp.Close()
		return fmt.Errorf("import apkg: extract collection.anki2: %w", err)
	}
	rc.Close()
	tmp.Close()

	db, err := sql.Open("sqlite3", tmpPath)
	if err != nil {
		return fmt.Errorf("import apkg: open sqlite: %w", err)
	}
	defer db.Close()

	// Parse col to determine field separator (always \x1f in Anki 2.1).
	// We still read models to verify the deck has at least 2 fields.
	var modelsJSON string
	if err := db.QueryRow("SELECT models FROM col LIMIT 1").Scan(&modelsJSON); err != nil {
		return fmt.Errorf("import apkg: read col: %w", err)
	}
	minFields, err := minFieldCount(modelsJSON)
	if err != nil {
		// Non-fatal: warn and assume 2 fields.
		fmt.Fprintf(os.Stderr, "warning: could not parse models JSON, assuming 2 fields: %v\n", err)
		minFields = 2
	}

	rows, err := db.Query("SELECT flds FROM notes")
	if err != nil {
		return fmt.Errorf("import apkg: query notes: %w", err)
	}
	defer rows.Close()

	var cards []types.Card
	id := 1
	for rows.Next() {
		var flds string
		if err := rows.Scan(&flds); err != nil {
			fmt.Fprintf(os.Stderr, "warning: skipping unreadable note: %v\n", err)
			continue
		}
		parts := strings.Split(flds, "\x1f")
		if len(parts) < 2 || (minFields > 2 && len(parts) < minFields) {
			fmt.Fprintf(os.Stderr, "warning: skipping note with fewer than 2 fields\n")
			continue
		}
		front := strings.TrimSpace(parts[0])
		back := strings.TrimSpace(BRToNewline(parts[1]))
		if front == "" {
			fmt.Fprintf(os.Stderr, "warning: skipping note with empty front field\n")
			continue
		}
		if back == "" {
			fmt.Fprintf(os.Stderr, "warning: skipping note with empty back field\n")
			continue
		}
		cards = append(cards, types.Card{ID: id, Front: front, Back: back})
		id++
	}

	if len(cards) == 0 {
		return fmt.Errorf("import apkg: no valid cards found in %s", inputPath)
	}

	s := &types.Session{
		Type:       types.TypeFlashcard,
		Title:      sessionTitle(opts, inputPath),
		Difficulty: sessionDifficulty(opts),
		Sources:    []string{},
		CreatedAt:  time.Now().UTC(),
		Cards:      cards,
	}
	return writeSession(s, stuDir, opts.Force)
}

// minFieldCount parses the models JSON blob and returns the field count of the
// first note type, or 2 on error.
func minFieldCount(modelsJSON string) (int, error) {
	var models map[string]json.RawMessage
	if err := json.Unmarshal([]byte(modelsJSON), &models); err != nil {
		return 2, err
	}
	for _, raw := range models {
		var m struct {
			Flds []json.RawMessage `json:"flds"`
		}
		if err := json.Unmarshal(raw, &m); err != nil {
			return 2, err
		}
		if len(m.Flds) < 2 {
			return len(m.Flds), nil
		}
		return len(m.Flds), nil
	}
	return 2, nil
}

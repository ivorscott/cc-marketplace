package anki

import (
	"archive/zip"
	"database/sql"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	_ "github.com/mattn/go-sqlite3"

	"github.com/ivorscott/stu/internal/loader"
	"github.com/ivorscott/stu/internal/types"
)

// ExportOptions controls the behaviour of Export.
type ExportOptions struct {
	Format    string // "apkg" (default) or "txt"
	Output    string // override output path; "" = derive from session
	HTMLStrip bool   // strip HTML tags from all card fields
	Force     bool   // overwrite output file if it already exists
}

// Export loads a flashcard session from sessionPath and writes an Anki-
// compatible file. The output format is determined by opts.Format.
func Export(sessionPath string, opts ExportOptions) error {
	s, err := loader.Load(sessionPath)
	if err != nil {
		return err
	}
	if s.Type != types.TypeFlashcard {
		return fmt.Errorf("export: session type is %q — only %q sessions can be exported", s.Type, types.TypeFlashcard)
	}

	format := opts.Format
	if format == "" {
		format = "apkg"
	}

	switch format {
	case "apkg":
		return exportAPKG(sessionPath, s, opts)
	case "txt":
		return exportTXT(sessionPath, s, opts)
	default:
		return fmt.Errorf("export: unknown format %q: want \"apkg\" or \"txt\"", format)
	}
}

// outputPath derives the default output path from the session file path,
// replacing its extension with ext and placing it in the same directory.
// If opts.Output is non-empty it is used directly.
func outputPath(sessionPath, ext string, opts ExportOptions) string {
	if opts.Output != "" {
		return opts.Output
	}
	base := strings.TrimSuffix(filepath.Base(sessionPath), filepath.Ext(sessionPath))
	return filepath.Join(filepath.Dir(sessionPath), base+ext)
}

// checkCollision returns an error if dst already exists and Force is false.
func checkCollision(dst string, force bool) error {
	_, err := os.Stat(dst)
	if err == nil && !force {
		return fmt.Errorf("output file already exists: %s (use --force to overwrite)", dst)
	}
	return nil
}

// exportTXT writes cards as a tab-delimited text file importable by Anki.
func exportTXT(sessionPath string, s *types.Session, opts ExportOptions) error {
	dst := outputPath(sessionPath, ".txt", opts)
	if err := checkCollision(dst, opts.Force); err != nil {
		return err
	}

	f, err := os.Create(dst)
	if err != nil {
		return fmt.Errorf("export txt: create %s: %w", dst, err)
	}
	defer f.Close()

	for _, card := range s.Cards {
		front, back := card.Front, card.Back
		if opts.HTMLStrip {
			front = StripHTML(front)
			back = StripHTML(back)
		}
		if card.Explanation != "" {
			exp := card.Explanation
			if opts.HTMLStrip {
				exp = StripHTML(exp)
			}
			back = back + "\n" + exp
		}
		if _, err := fmt.Fprintf(f, "%s\t%s\n", front, back); err != nil {
			return fmt.Errorf("export txt: write: %w", err)
		}
	}
	return nil
}

// exportAPKG writes cards as an Anki .apkg package (zip containing a SQLite DB).
func exportAPKG(sessionPath string, s *types.Session, opts ExportOptions) error {
	dst := outputPath(sessionPath, ".apkg", opts)
	if err := checkCollision(dst, opts.Force); err != nil {
		return err
	}

	sessionDir := filepath.Dir(sessionPath)

	// Scan media before processing cards (skip when html-strip is active).
	var mediaRefs []MediaRef
	if !opts.HTMLStrip {
		mediaRefs = ScanMedia(s.Cards, sessionDir)
		for _, ref := range mediaRefs {
			if ref.Missing {
				fmt.Fprintf(os.Stderr, "warning: media file not found, skipping: %s\n", ref.Original)
			}
		}
	}
	manifest := BuildManifest(mediaRefs)

	// Create temp SQLite file.
	tmp, err := os.CreateTemp("", "anki-*.anki2")
	if err != nil {
		return fmt.Errorf("export apkg: create temp: %w", err)
	}
	tmpPath := tmp.Name()
	tmp.Close()
	defer os.Remove(tmpPath)

	// Build SQLite database.
	db, err := sql.Open("sqlite3", tmpPath)
	if err != nil {
		return fmt.Errorf("export apkg: open sqlite: %w", err)
	}
	if err := initSchema(db); err != nil {
		db.Close()
		return err
	}

	now := time.Now()
	nowSec := now.Unix()
	nowMs := now.UnixMilli()
	deckID := nowMs

	confJSON, modelsJSON, decksJSON, dconfJSON, tagsJSON, err := colJSON(s.Title, deckID)
	if err != nil {
		db.Close()
		return fmt.Errorf("export apkg: build col JSON: %w", err)
	}

	_, err = db.Exec(
		`INSERT INTO col VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)`,
		1, nowSec, nowMs, nowMs, 11, 0, 0, 0,
		confJSON, modelsJSON, decksJSON, dconfJSON, tagsJSON,
	)
	if err != nil {
		db.Close()
		return fmt.Errorf("export apkg: insert col: %w", err)
	}

	for i, card := range s.Cards {
		front, back, exp := card.Front, card.Back, card.Explanation
		if opts.HTMLStrip {
			front = StripHTML(front)
			back = StripHTML(back)
			exp = StripHTML(exp)
		}
		if exp != "" {
			back = back + "<br>" + exp
		}

		flds := front + "\x1f" + back
		sfld := front
		csum := computeCSUM(sfld)
		guid := randomGUID()
		noteID := nowMs + int64(i)
		cardID := noteID + 1

		_, err = db.Exec(
			`INSERT INTO notes VALUES (?,?,?,?,?,?,?,?,?,?,?)`,
			noteID, guid, ModelID, nowSec, -1, "", flds, sfld, csum, 0, "",
		)
		if err != nil {
			db.Close()
			return fmt.Errorf("export apkg: insert note %d: %w", i, err)
		}

		_, err = db.Exec(
			`INSERT INTO cards VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)`,
			cardID, noteID, deckID, 0, nowSec, -1, 0, 0, i+1, 0, 0, 0, 0, 0, 0, 0, 0, "",
		)
		if err != nil {
			db.Close()
			return fmt.Errorf("export apkg: insert card %d: %w", i, err)
		}
	}
	db.Close()

	// Build the manifest JSON.
	manifestJSON, err := json.Marshal(manifest)
	if err != nil {
		return fmt.Errorf("export apkg: marshal media manifest: %w", err)
	}

	// Write the .apkg zip.
	outFile, err := os.Create(dst)
	if err != nil {
		return fmt.Errorf("export apkg: create output: %w", err)
	}
	defer outFile.Close()

	zw := zip.NewWriter(outFile)
	defer zw.Close()

	// Add collection.anki2.
	sqliteData, err := os.ReadFile(tmpPath)
	if err != nil {
		return fmt.Errorf("export apkg: read sqlite temp: %w", err)
	}
	w, err := zw.Create("collection.anki2")
	if err != nil {
		return fmt.Errorf("export apkg: zip create collection.anki2: %w", err)
	}
	if _, err := w.Write(sqliteData); err != nil {
		return fmt.Errorf("export apkg: zip write collection.anki2: %w", err)
	}

	// Add media manifest.
	w, err = zw.Create("media")
	if err != nil {
		return fmt.Errorf("export apkg: zip create media: %w", err)
	}
	if _, err := w.Write(manifestJSON); err != nil {
		return fmt.Errorf("export apkg: zip write media: %w", err)
	}

	// Embed media files (only when not html-stripping).
	if !opts.HTMLStrip {
		idx := 0
		for _, ref := range mediaRefs {
			if ref.Missing {
				continue
			}
			data, err := os.ReadFile(ref.AbsPath)
			if err != nil {
				fmt.Fprintf(os.Stderr, "warning: could not read media file %s: %v\n", ref.Original, err)
				continue
			}
			w, err = zw.Create(fmt.Sprintf("%d", idx))
			if err != nil {
				return fmt.Errorf("export apkg: zip create media entry %d: %w", idx, err)
			}
			if _, err := w.Write(data); err != nil {
				return fmt.Errorf("export apkg: zip write media entry %d: %w", idx, err)
			}
			idx++
		}
	}

	return nil
}

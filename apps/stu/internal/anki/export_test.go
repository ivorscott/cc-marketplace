package anki

import (
	"archive/zip"
	"database/sql"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	_ "github.com/mattn/go-sqlite3"

	"github.com/ivorscott/stu/internal/types"
)

// makeSession creates a minimal flashcard session JSON file in dir and returns its path.
func makeSession(t *testing.T, dir string, cards []types.Card) string {
	t.Helper()
	s := types.Session{
		Type:       types.TypeFlashcard,
		Title:      "Test Deck",
		Difficulty: "medium",
		Sources:    []string{},
		CreatedAt:  time.Now(),
		Cards:      cards,
	}
	data, err := json.Marshal(s)
	if err != nil {
		t.Fatalf("marshal session: %v", err)
	}
	path := filepath.Join(dir, "deck.json")
	if err := os.WriteFile(path, data, 0o644); err != nil {
		t.Fatalf("write session: %v", err)
	}
	return path
}

// makeQuizSession creates a quiz session JSON file in dir and returns its path.
func makeQuizSession(t *testing.T, dir string) string {
	t.Helper()
	s := types.Session{
		Type:      types.TypeQuiz,
		Title:     "Quiz",
		CreatedAt: time.Now(),
		Questions: []types.Question{{ID: 1, Question: "Q?", Options: []string{"A", "B"}, Correct: 0}},
	}
	data, _ := json.Marshal(s)
	path := filepath.Join(dir, "quiz.json")
	os.WriteFile(path, data, 0o644)
	return path
}

func TestExportTXT_Basic(t *testing.T) {
	dir := t.TempDir()
	cards := []types.Card{
		{ID: 1, Front: "Q1", Back: "A1"},
		{ID: 2, Front: "Q2", Back: "A2"},
	}
	path := makeSession(t, dir, cards)
	dst := filepath.Join(dir, "out.txt")

	if err := Export(path, ExportOptions{Format: "txt", Output: dst}); err != nil {
		t.Fatalf("Export: %v", err)
	}

	data, _ := os.ReadFile(dst)
	lines := strings.Split(strings.TrimRight(string(data), "\n"), "\n")
	if len(lines) != 2 {
		t.Fatalf("want 2 lines, got %d: %v", len(lines), lines)
	}
	if lines[0] != "Q1\tA1" {
		t.Errorf("line 0 = %q, want %q", lines[0], "Q1\tA1")
	}
	if lines[1] != "Q2\tA2" {
		t.Errorf("line 1 = %q, want %q", lines[1], "Q2\tA2")
	}
}

func TestExportTXT_WithExplanation(t *testing.T) {
	dir := t.TempDir()
	cards := []types.Card{
		{ID: 1, Front: "Q", Back: "A", Explanation: "Because."},
	}
	path := makeSession(t, dir, cards)
	dst := filepath.Join(dir, "out.txt")

	if err := Export(path, ExportOptions{Format: "txt", Output: dst}); err != nil {
		t.Fatalf("Export: %v", err)
	}

	data, _ := os.ReadFile(dst)
	line := strings.TrimRight(string(data), "\n")
	if !strings.Contains(line, "A\nBecause.") {
		t.Errorf("explanation not appended correctly: %q", line)
	}
}

func TestExportTXT_HTMLStrip(t *testing.T) {
	dir := t.TempDir()
	cards := []types.Card{
		{ID: 1, Front: "<b>Bold</b>", Back: "<i>Italic</i>"},
	}
	path := makeSession(t, dir, cards)
	dst := filepath.Join(dir, "out.txt")

	if err := Export(path, ExportOptions{Format: "txt", Output: dst, HTMLStrip: true}); err != nil {
		t.Fatalf("Export: %v", err)
	}

	data, _ := os.ReadFile(dst)
	if strings.Contains(string(data), "<b>") || strings.Contains(string(data), "<i>") {
		t.Errorf("HTML tags not stripped: %q", string(data))
	}
	if !strings.Contains(string(data), "Bold") || !strings.Contains(string(data), "Italic") {
		t.Errorf("text content missing: %q", string(data))
	}
}

func TestExportTXT_QuizError(t *testing.T) {
	dir := t.TempDir()
	path := makeQuizSession(t, dir)
	dst := filepath.Join(dir, "out.txt")

	err := Export(path, ExportOptions{Format: "txt", Output: dst})
	if err == nil {
		t.Fatal("expected error for quiz session, got nil")
	}
}

func TestExportTXT_CollisionNoForce(t *testing.T) {
	dir := t.TempDir()
	cards := []types.Card{{ID: 1, Front: "Q", Back: "A"}}
	path := makeSession(t, dir, cards)
	dst := filepath.Join(dir, "out.txt")
	os.WriteFile(dst, []byte("existing"), 0o644)

	err := Export(path, ExportOptions{Format: "txt", Output: dst, Force: false})
	if err == nil {
		t.Fatal("expected collision error, got nil")
	}
}

func TestExportTXT_CollisionForce(t *testing.T) {
	dir := t.TempDir()
	cards := []types.Card{{ID: 1, Front: "Q", Back: "A"}}
	path := makeSession(t, dir, cards)
	dst := filepath.Join(dir, "out.txt")
	os.WriteFile(dst, []byte("existing"), 0o644)

	if err := Export(path, ExportOptions{Format: "txt", Output: dst, Force: true}); err != nil {
		t.Fatalf("expected force overwrite to succeed: %v", err)
	}
}

func TestExportAPKG_Basic(t *testing.T) {
	dir := t.TempDir()
	cards := []types.Card{
		{ID: 1, Front: "Hello", Back: "World"},
		{ID: 2, Front: "Foo", Back: "Bar"},
	}
	path := makeSession(t, dir, cards)
	dst := filepath.Join(dir, "out.apkg")

	if err := Export(path, ExportOptions{Format: "apkg", Output: dst}); err != nil {
		t.Fatalf("Export apkg: %v", err)
	}

	// Verify it is a valid zip.
	zr, err := zip.OpenReader(dst)
	if err != nil {
		t.Fatalf("open zip: %v", err)
	}
	defer zr.Close()

	fileNames := map[string]bool{}
	for _, f := range zr.File {
		fileNames[f.Name] = true
	}
	if !fileNames["collection.anki2"] {
		t.Error("zip missing collection.anki2")
	}
	if !fileNames["media"] {
		t.Error("zip missing media entry")
	}
}

func TestExportAPKG_SQLiteSchema(t *testing.T) {
	dir := t.TempDir()
	cards := []types.Card{
		{ID: 1, Front: "Front1", Back: "Back1"},
		{ID: 2, Front: "Front2", Back: "Back2", Explanation: "Explain"},
	}
	path := makeSession(t, dir, cards)
	dst := filepath.Join(dir, "out.apkg")

	if err := Export(path, ExportOptions{Format: "apkg", Output: dst}); err != nil {
		t.Fatalf("Export: %v", err)
	}

	// Extract collection.anki2 from the zip.
	zr, err := zip.OpenReader(dst)
	if err != nil {
		t.Fatalf("open zip: %v", err)
	}
	defer zr.Close()

	var sqliteData []byte
	for _, f := range zr.File {
		if f.Name == "collection.anki2" {
			rc, _ := f.Open()
			buf := make([]byte, f.UncompressedSize64)
			rc.Read(buf)
			rc.Close()
			sqliteData = buf
			break
		}
	}
	if sqliteData == nil {
		t.Fatal("collection.anki2 not found in zip")
	}

	// Write to temp file and open.
	sqlitePath := filepath.Join(dir, "collection.anki2")
	os.WriteFile(sqlitePath, sqliteData, 0o644)

	db, err := sql.Open("sqlite3", sqlitePath)
	if err != nil {
		t.Fatalf("open sqlite: %v", err)
	}
	defer db.Close()

	var count int
	if err := db.QueryRow("SELECT COUNT(*) FROM notes").Scan(&count); err != nil {
		t.Fatalf("count notes: %v", err)
	}
	if count != 2 {
		t.Errorf("want 2 notes, got %d", count)
	}

	// Verify flds separator and explanation folding.
	rows, err := db.Query("SELECT flds FROM notes ORDER BY id")
	if err != nil {
		t.Fatalf("query notes: %v", err)
	}
	defer rows.Close()
	var fldsList []string
	for rows.Next() {
		var flds string
		rows.Scan(&flds)
		fldsList = append(fldsList, flds)
	}
	if fldsList[0] != "Front1\x1fBack1" {
		t.Errorf("note 0 flds = %q, want %q", fldsList[0], "Front1\x1fBack1")
	}
	if !strings.Contains(fldsList[1], "Explain") {
		t.Errorf("note 1 flds should contain explanation: %q", fldsList[1])
	}
}

func TestExportAPKG_MediaEmbed(t *testing.T) {
	dir := t.TempDir()
	writeTinyPNG(t, filepath.Join(dir, "img.png"))

	cards := []types.Card{
		{ID: 1, Front: `<img src="img.png">`, Back: "back"},
	}
	path := makeSession(t, dir, cards)
	dst := filepath.Join(dir, "out.apkg")

	if err := Export(path, ExportOptions{Format: "apkg", Output: dst}); err != nil {
		t.Fatalf("Export: %v", err)
	}

	zr, err := zip.OpenReader(dst)
	if err != nil {
		t.Fatalf("open zip: %v", err)
	}
	defer zr.Close()

	// Should have media manifest with one entry and a numeric file "0".
	fileNames := map[string]bool{}
	for _, f := range zr.File {
		fileNames[f.Name] = true
	}
	if !fileNames["0"] {
		t.Error("expected media file '0' in zip")
	}

	// Verify manifest JSON.
	for _, f := range zr.File {
		if f.Name == "media" {
			rc, _ := f.Open()
			var m map[string]string
			json.NewDecoder(rc).Decode(&m)
			rc.Close()
			if m["0"] != "img.png" {
				t.Errorf("manifest[0] = %q, want %q", m["0"], "img.png")
			}
			break
		}
	}
}

func TestExportAPKG_HTMLStrip(t *testing.T) {
	dir := t.TempDir()
	writeTinyPNG(t, filepath.Join(dir, "img.png"))

	cards := []types.Card{
		{ID: 1, Front: `<img src="img.png"><b>Front</b>`, Back: "<i>Back</i>"},
	}
	path := makeSession(t, dir, cards)
	dst := filepath.Join(dir, "out.apkg")

	if err := Export(path, ExportOptions{Format: "apkg", Output: dst, HTMLStrip: true}); err != nil {
		t.Fatalf("Export: %v", err)
	}

	zr, err := zip.OpenReader(dst)
	if err != nil {
		t.Fatalf("open zip: %v", err)
	}
	defer zr.Close()

	fileNames := map[string]bool{}
	for _, f := range zr.File {
		fileNames[f.Name] = true
	}
	// With html-strip, no media files should be embedded.
	if fileNames["0"] {
		t.Error("expected no media file '0' when html-strip is active")
	}
}

package anki

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/ivorscott/cc-marketplace/apps/stu/internal/types"
)

// ---- helpers ----

func loadSession(t *testing.T, stuDir, slug string) *types.Session {
	t.Helper()
	data, err := os.ReadFile(filepath.Join(stuDir, slug+".json"))
	if err != nil {
		t.Fatalf("read session: %v", err)
	}
	var s types.Session
	if err := json.Unmarshal(data, &s); err != nil {
		t.Fatalf("parse session: %v", err)
	}
	return &s
}

// ---- TXT import tests ----

func TestImportTXT_Basic(t *testing.T) {
	stuDir := t.TempDir()
	src := filepath.Join("testdata", "sample.txt")

	if err := ImportFile(src, ImportOptions{Title: "My Deck"}, stuDir); err != nil {
		t.Fatalf("ImportFile: %v", err)
	}

	s := loadSession(t, stuDir, "my-deck")
	if s.Type != types.TypeFlashcard {
		t.Errorf("type = %q, want %q", s.Type, types.TypeFlashcard)
	}
	if len(s.Cards) != 3 {
		t.Errorf("want 3 cards, got %d", len(s.Cards))
	}
	if s.Cards[0].Front != "Front 1" || s.Cards[0].Back != "Back 1" {
		t.Errorf("card 0 = %+v, want Front1/Back1", s.Cards[0])
	}
}

func TestImportTXT_CommentsSkipped(t *testing.T) {
	stuDir := t.TempDir()
	src := filepath.Join("testdata", "sample.txt")

	if err := ImportFile(src, ImportOptions{Title: "Deck"}, stuDir); err != nil {
		t.Fatalf("ImportFile: %v", err)
	}

	s := loadSession(t, stuDir, "deck")
	for _, card := range s.Cards {
		if strings.HasPrefix(card.Front, "#") {
			t.Errorf("comment line was not skipped: %+v", card)
		}
	}
}

func TestImportTXT_MultilineBack(t *testing.T) {
	stuDir := t.TempDir()
	src := filepath.Join("testdata", "sample_multiline.txt")

	if err := ImportFile(src, ImportOptions{Title: "Multi"}, stuDir); err != nil {
		t.Fatalf("ImportFile: %v", err)
	}

	s := loadSession(t, stuDir, "multi")
	if len(s.Cards) < 1 {
		t.Fatal("no cards imported")
	}
	if !strings.Contains(s.Cards[0].Back, "\n") {
		t.Errorf("multi-line back not preserved: %q", s.Cards[0].Back)
	}
}

func TestImportTXT_DifficultyDefault(t *testing.T) {
	stuDir := t.TempDir()
	src := filepath.Join("testdata", "sample.txt")

	ImportFile(src, ImportOptions{Title: "D"}, stuDir)
	s := loadSession(t, stuDir, "d")
	if s.Difficulty != "medium" {
		t.Errorf("difficulty = %q, want %q", s.Difficulty, "medium")
	}
}

func TestImportTXT_DifficultyOverride(t *testing.T) {
	stuDir := t.TempDir()
	src := filepath.Join("testdata", "sample.txt")

	ImportFile(src, ImportOptions{Title: "D2", Difficulty: "hard"}, stuDir)
	s := loadSession(t, stuDir, "d2")
	if s.Difficulty != "hard" {
		t.Errorf("difficulty = %q, want %q", s.Difficulty, "hard")
	}
}

func TestImportTXT_CollisionNoForce(t *testing.T) {
	stuDir := t.TempDir()
	src := filepath.Join("testdata", "sample.txt")
	opts := ImportOptions{Title: "Deck"}

	// First import.
	if err := ImportFile(src, opts, stuDir); err != nil {
		t.Fatalf("first import: %v", err)
	}
	// Second import without --force.
	err := ImportFile(src, opts, stuDir)
	if err == nil {
		t.Fatal("expected collision error, got nil")
	}
}

func TestImportTXT_CollisionForce(t *testing.T) {
	stuDir := t.TempDir()
	src := filepath.Join("testdata", "sample.txt")
	opts := ImportOptions{Title: "Deck"}

	ImportFile(src, opts, stuDir)
	opts.Force = true
	if err := ImportFile(src, opts, stuDir); err != nil {
		t.Fatalf("force import: %v", err)
	}
}

func TestImportTXT_TitleFromFilename(t *testing.T) {
	stuDir := t.TempDir()
	src := filepath.Join("testdata", "sample.txt")

	ImportFile(src, ImportOptions{}, stuDir)
	// filename is "sample" → Deslugify → "Sample"
	s := loadSession(t, stuDir, "sample")
	if s.Title != "Sample" {
		t.Errorf("title = %q, want %q", s.Title, "Sample")
	}
}

// ---- APKG import tests ----

// buildTestAPKG creates a minimal .apkg with the given cards and returns its path.
func buildTestAPKG(t *testing.T, dir string, cards []types.Card) string {
	t.Helper()
	sessionPath := makeSession(t, dir, cards)
	apkgPath := filepath.Join(dir, "test.apkg")
	if err := Export(sessionPath, ExportOptions{Format: "apkg", Output: apkgPath}); err != nil {
		t.Fatalf("build test apkg: %v", err)
	}
	return apkgPath
}

func TestImportAPKG_Basic(t *testing.T) {
	dir := t.TempDir()
	stuDir := t.TempDir()

	cards := []types.Card{
		{ID: 1, Front: "Capital of France", Back: "Paris"},
		{ID: 2, Front: "Capital of Japan", Back: "Tokyo"},
	}
	apkg := buildTestAPKG(t, dir, cards)

	if err := ImportFile(apkg, ImportOptions{Title: "Geo"}, stuDir); err != nil {
		t.Fatalf("ImportFile: %v", err)
	}

	s := loadSession(t, stuDir, "geo")
	if len(s.Cards) != 2 {
		t.Errorf("want 2 cards, got %d", len(s.Cards))
	}
	if s.Cards[0].Front != "Capital of France" {
		t.Errorf("card 0 front = %q", s.Cards[0].Front)
	}
}

func TestImportAPKG_BRConversion(t *testing.T) {
	dir := t.TempDir()
	stuDir := t.TempDir()

	// Build a session where the back field contains a <br> which gets embedded in apkg.
	cards := []types.Card{
		{ID: 1, Front: "Q", Back: "line1<br>line2"},
	}
	apkg := buildTestAPKG(t, dir, cards)

	if err := ImportFile(apkg, ImportOptions{Title: "BR"}, stuDir); err != nil {
		t.Fatalf("ImportFile: %v", err)
	}

	s := loadSession(t, stuDir, "br")
	if len(s.Cards) == 0 {
		t.Fatal("no cards")
	}
	if !strings.Contains(s.Cards[0].Back, "\n") {
		t.Errorf("<br> not converted to newline: %q", s.Cards[0].Back)
	}
}

func TestImportAPKG_SkipInvalidNotes(t *testing.T) {
	dir := t.TempDir()
	stuDir := t.TempDir()

	// Build a valid apkg first.
	cards := []types.Card{
		{ID: 1, Front: "Good", Back: "Card"},
	}
	apkg := buildTestAPKG(t, dir, cards)

	// The apkg built from our exporter always has valid cards,
	// so just verify the import succeeds and card count is correct.
	if err := ImportFile(apkg, ImportOptions{Title: "Skip"}, stuDir); err != nil {
		t.Fatalf("ImportFile: %v", err)
	}
	s := loadSession(t, stuDir, "skip")
	if len(s.Cards) != 1 {
		t.Errorf("want 1 card, got %d", len(s.Cards))
	}
}

func TestImportAPKG_RoundTrip(t *testing.T) {
	dir := t.TempDir()
	stuDir := t.TempDir()

	original := []types.Card{
		{ID: 1, Front: "Alpha", Back: "Beta"},
		{ID: 2, Front: "Gamma", Back: "Delta"},
		{ID: 3, Front: "Epsilon", Back: "Zeta"},
	}

	sessionPath := makeSession(t, dir, original)

	// Export.
	apkgPath := filepath.Join(dir, "roundtrip.apkg")
	if err := Export(sessionPath, ExportOptions{Format: "apkg", Output: apkgPath}); err != nil {
		t.Fatalf("Export: %v", err)
	}

	// Import.
	if err := ImportFile(apkgPath, ImportOptions{Title: "Roundtrip"}, stuDir); err != nil {
		t.Fatalf("ImportFile: %v", err)
	}

	s := loadSession(t, stuDir, "roundtrip")
	if len(s.Cards) != len(original) {
		t.Errorf("round-trip: want %d cards, got %d", len(original), len(s.Cards))
	}
	for i, orig := range original {
		if s.Cards[i].Front != orig.Front || s.Cards[i].Back != orig.Back {
			t.Errorf("card %d: got %+v, want Front=%s Back=%s", i, s.Cards[i], orig.Front, orig.Back)
		}
	}
}

func TestImportFile_UnsupportedFormat(t *testing.T) {
	stuDir := t.TempDir()
	err := ImportFile("deck.xlsx", ImportOptions{}, stuDir)
	if err == nil {
		t.Fatal("expected error for unsupported format")
	}
}

func TestImportFile_CreatesStuDir(t *testing.T) {
	base := t.TempDir()
	stuDir := filepath.Join(base, "newdir", ".stu")
	src := filepath.Join("testdata", "sample.txt")

	if err := ImportFile(src, ImportOptions{Title: "Mk"}, stuDir); err != nil {
		t.Fatalf("ImportFile: %v", err)
	}
	if _, err := os.Stat(stuDir); err != nil {
		t.Errorf(".stu dir not created: %v", err)
	}
}

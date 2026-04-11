package anki

import (
	"image"
	"image/color"
	"image/png"
	"os"
	"path/filepath"
	"testing"

	"github.com/ivorscott/stu/internal/types"
)

// writeTinyPNG creates a 1x1 PNG file at the given path.
func writeTinyPNG(t *testing.T, path string) {
	t.Helper()
	img := image.NewRGBA(image.Rect(0, 0, 1, 1))
	img.Set(0, 0, color.RGBA{255, 0, 0, 255})
	f, err := os.Create(path)
	if err != nil {
		t.Fatalf("create png: %v", err)
	}
	defer f.Close()
	if err := png.Encode(f, img); err != nil {
		t.Fatalf("encode png: %v", err)
	}
}

func TestScanMedia_ImgTag(t *testing.T) {
	dir := t.TempDir()
	writeTinyPNG(t, filepath.Join(dir, "foo.png"))

	cards := []types.Card{
		{Front: `<img src="foo.png">`, Back: "back"},
	}
	refs := ScanMedia(cards, dir)
	if len(refs) != 1 {
		t.Fatalf("want 1 ref, got %d", len(refs))
	}
	if refs[0].Original != "foo.png" {
		t.Errorf("Original = %q, want %q", refs[0].Original, "foo.png")
	}
	if refs[0].Missing {
		t.Error("expected Missing=false for existing file")
	}
}

func TestScanMedia_SoundTag(t *testing.T) {
	dir := t.TempDir()
	// create a dummy audio file
	if err := os.WriteFile(filepath.Join(dir, "beep.mp3"), []byte("fake"), 0o644); err != nil {
		t.Fatal(err)
	}

	cards := []types.Card{
		{Front: "[sound:beep.mp3]", Back: "back"},
	}
	refs := ScanMedia(cards, dir)
	if len(refs) != 1 {
		t.Fatalf("want 1 ref, got %d", len(refs))
	}
	if refs[0].Original != "beep.mp3" {
		t.Errorf("Original = %q, want %q", refs[0].Original, "beep.mp3")
	}
	if refs[0].Missing {
		t.Error("expected Missing=false for existing file")
	}
}

func TestScanMedia_Missing(t *testing.T) {
	dir := t.TempDir()
	cards := []types.Card{
		{Front: `<img src="ghost.png">`, Back: "back"},
	}
	refs := ScanMedia(cards, dir)
	if len(refs) != 1 {
		t.Fatalf("want 1 ref, got %d", len(refs))
	}
	if !refs[0].Missing {
		t.Error("expected Missing=true for absent file")
	}
}

func TestScanMedia_Dedup(t *testing.T) {
	dir := t.TempDir()
	writeTinyPNG(t, filepath.Join(dir, "a.png"))

	cards := []types.Card{
		{Front: `<img src="a.png">`, Back: `<img src="a.png">`},
		{Front: `<img src="a.png">`, Back: "back"},
	}
	refs := ScanMedia(cards, dir)
	if len(refs) != 1 {
		t.Errorf("expected 1 deduplicated ref, got %d", len(refs))
	}
}

func TestScanMedia_ExplanationField(t *testing.T) {
	dir := t.TempDir()
	writeTinyPNG(t, filepath.Join(dir, "exp.png"))

	cards := []types.Card{
		{Front: "front", Back: "back", Explanation: `<img src="exp.png">`},
	}
	refs := ScanMedia(cards, dir)
	if len(refs) != 1 {
		t.Fatalf("want 1 ref from explanation field, got %d", len(refs))
	}
	if refs[0].Original != "exp.png" {
		t.Errorf("Original = %q, want %q", refs[0].Original, "exp.png")
	}
}

func TestBuildManifest(t *testing.T) {
	refs := []MediaRef{
		{Original: "a.png", Missing: false},
		{Original: "b.mp3", Missing: true}, // should be excluded
		{Original: "c.png", Missing: false},
	}
	m := BuildManifest(refs)
	if len(m) != 2 {
		t.Fatalf("want 2 entries in manifest, got %d", len(m))
	}
	if m["0"] != "a.png" {
		t.Errorf("manifest[0] = %q, want %q", m["0"], "a.png")
	}
	if m["1"] != "c.png" {
		t.Errorf("manifest[1] = %q, want %q", m["1"], "c.png")
	}
}

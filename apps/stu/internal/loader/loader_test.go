package loader

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/ivorscott/stu/internal/types"
)

const quizJSON = `{
	"type": "quiz",
	"title": "Test Quiz",
	"difficulty": "easy",
	"sources": ["a.md"],
	"questions": [
		{
			"id": 1,
			"question": "Q1?",
			"options": ["A", "B", "C", "D"],
			"correct": 0,
			"hint": "think",
			"explanations": ["right", "wrong", "wrong", "wrong"]
		}
	]
}`

const flashcardJSON = `{
	"type": "flashcards",
	"title": "Test Cards",
	"difficulty": "medium",
	"sources": ["b.md"],
	"cards": [
		{"id": 1, "front": "Front", "back": "Back", "explanation": "Because"}
	]
}`

func writeTemp(t *testing.T, dir, name, content string) string {
	t.Helper()
	path := filepath.Join(dir, name)
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestLoad_Quiz(t *testing.T) {
	dir := t.TempDir()
	path := writeTemp(t, dir, "quiz.json", quizJSON)

	s, err := Load(path)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if s.Type != types.TypeQuiz {
		t.Errorf("type = %q, want %q", s.Type, types.TypeQuiz)
	}
	if s.Title != "Test Quiz" {
		t.Errorf("title = %q, want %q", s.Title, "Test Quiz")
	}
	if len(s.Questions) != 1 {
		t.Errorf("questions = %d, want 1", len(s.Questions))
	}
}

func TestLoad_Flashcard(t *testing.T) {
	dir := t.TempDir()
	path := writeTemp(t, dir, "cards.json", flashcardJSON)

	s, err := Load(path)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if s.Type != types.TypeFlashcard {
		t.Errorf("type = %q, want %q", s.Type, types.TypeFlashcard)
	}
	if len(s.Cards) != 1 {
		t.Errorf("cards = %d, want 1", len(s.Cards))
	}
	if s.Cards[0].Front != "Front" {
		t.Errorf("front = %q, want %q", s.Cards[0].Front, "Front")
	}
}

func TestLoad_UnknownType(t *testing.T) {
	dir := t.TempDir()
	path := writeTemp(t, dir, "bad.json", `{"type": "unknown"}`)

	_, err := Load(path)
	if err == nil {
		t.Fatal("expected error for unknown type, got nil")
	}
}

func TestLoad_InvalidJSON(t *testing.T) {
	dir := t.TempDir()
	path := writeTemp(t, dir, "bad.json", `not json`)

	_, err := Load(path)
	if err == nil {
		t.Fatal("expected error for invalid JSON, got nil")
	}
}

func TestLoad_FileNotFound(t *testing.T) {
	_, err := Load("/nonexistent/path/file.json")
	if err == nil {
		t.Fatal("expected error for missing file, got nil")
	}
}

func TestListSessions_NoDir(t *testing.T) {
	dir := t.TempDir() // no .stu/ subdirectory

	files, err := ListSessions(dir)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(files) != 0 {
		t.Errorf("got %d files, want 0", len(files))
	}
}

func TestListSessions_WithFiles(t *testing.T) {
	dir := t.TempDir()
	stuDir := filepath.Join(dir, ".stu")
	if err := os.Mkdir(stuDir, 0o755); err != nil {
		t.Fatal(err)
	}

	writeTemp(t, stuDir, "a.json", quizJSON)
	writeTemp(t, stuDir, "b.json", flashcardJSON)
	writeTemp(t, stuDir, "ignore.txt", "not json")

	files, err := ListSessions(dir)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(files) != 2 {
		t.Errorf("got %d files, want 2", len(files))
	}
}

func TestListSessions_EmptyDir(t *testing.T) {
	dir := t.TempDir()
	stuDir := filepath.Join(dir, ".stu")
	if err := os.Mkdir(stuDir, 0o755); err != nil {
		t.Fatal(err)
	}

	files, err := ListSessions(dir)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(files) != 0 {
		t.Errorf("got %d files, want 0", len(files))
	}
}

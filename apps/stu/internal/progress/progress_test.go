package progress

import (
	"os"
	"path/filepath"
	"testing"
)

func TestPathFor(t *testing.T) {
	got := pathFor(filepath.Join(".stu", "kafka-flashcard-20260316.json"))
	want := filepath.Join(".stu", ".state", "kafka-flashcard-20260316.json.state.json")
	if got != want {
		t.Errorf("pathFor() = %q, want %q", got, want)
	}
}

func TestLoadMissingFile(t *testing.T) {
	dir := t.TempDir()
	st, err := Load(filepath.Join(dir, "nonexistent.json"))
	if err != nil {
		t.Fatalf("Load() error = %v, want nil", err)
	}
	if len(st.Right) != 0 || len(st.Wrong) != 0 {
		t.Errorf("Load() = %+v, want zero-value State", st)
	}
}

func TestLoadCorruptFile(t *testing.T) {
	dir := t.TempDir()
	sessionPath := filepath.Join(dir, "session.json")
	stateFile := pathFor(sessionPath)
	if err := os.MkdirAll(filepath.Dir(stateFile), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(stateFile, []byte("not json"), 0o644); err != nil {
		t.Fatal(err)
	}

	if _, err := Load(sessionPath); err == nil {
		t.Error("Load() error = nil, want error for corrupt JSON")
	}
}

func TestSaveLoadRoundTrip(t *testing.T) {
	dir := t.TempDir()
	sessionPath := filepath.Join(dir, "session.json")
	want := State{Right: []int{1, 3}, Wrong: []int{5}}

	if err := Save(sessionPath, want); err != nil {
		t.Fatalf("Save() error = %v", err)
	}

	got, err := Load(sessionPath)
	if err != nil {
		t.Fatalf("Load() error = %v", err)
	}
	if len(got.Right) != len(want.Right) || len(got.Wrong) != len(want.Wrong) {
		t.Errorf("Load() = %+v, want %+v", got, want)
	}
}

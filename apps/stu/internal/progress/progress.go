// Package progress persists per-session-file resume state for flashcard
// sessions, so a session can pick up where a prior run left off.
package progress

import (
	"encoding/json"
	"os"
	"path/filepath"
)

// State is the on-disk resume record for one flashcard session file.
// Right and Wrong record the card IDs answered correctly/incorrectly across
// all runs so far, so a resumed session can restore each card's specific
// verdict (not just aggregate counts).
type State struct {
	Right []int `json:"right,omitempty"`
	Wrong []int `json:"wrong,omitempty"`
}

// pathFor returns the sibling state file path for a session file, e.g.
// ".stu/kafka-flashcard-20260316.json" -> ".stu/.state/kafka-flashcard-20260316.json.state.json"
func pathFor(sessionPath string) string {
	dir := filepath.Dir(sessionPath)
	name := filepath.Base(sessionPath)
	return filepath.Join(dir, ".state", name+".state.json")
}

// Load reads existing progress for a session file. A missing file is not an
// error — it returns a zero-value State (no cards seen yet).
func Load(sessionPath string) (State, error) {
	data, err := os.ReadFile(pathFor(sessionPath))
	if err != nil {
		if os.IsNotExist(err) {
			return State{}, nil
		}
		return State{}, err
	}
	var s State
	if err := json.Unmarshal(data, &s); err != nil {
		return State{}, err
	}
	return s, nil
}

// Save writes progress for a session file, creating .stu/.state/ if needed.
func Save(sessionPath string, s State) error {
	p := pathFor(sessionPath)
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		return err
	}
	data, err := json.MarshalIndent(s, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(p, data, 0o644)
}

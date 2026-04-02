package loader

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"

	"github.com/ivorscott/stu/internal/types"
)

// Load reads and parses a study session JSON file.
func Load(path string) (*types.Session, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("reading file: %w", err)
	}

	var s types.Session
	if err := json.Unmarshal(data, &s); err != nil {
		return nil, fmt.Errorf("parsing JSON: %w", err)
	}

	if s.Type != types.TypeQuiz && s.Type != types.TypeFlashcard {
		return nil, fmt.Errorf("unknown type %q: must be %q or %q", s.Type, types.TypeQuiz, types.TypeFlashcard)
	}

	return &s, nil
}

// ListSessions returns all .json files under the .stu/ directory in dir.
func ListSessions(dir string) ([]string, error) {
	stuDir := filepath.Join(dir, ".stu")
	entries, err := os.ReadDir(stuDir)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, err
	}

	var files []string
	for _, e := range entries {
		if !e.IsDir() && filepath.Ext(e.Name()) == ".json" {
			files = append(files, filepath.Join(stuDir, e.Name()))
		}
	}
	return files, nil
}

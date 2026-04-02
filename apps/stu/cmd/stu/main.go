package main

import (
	"fmt"
	"os"
	"path/filepath"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/ivorscott/stu/internal/flashcard"
	"github.com/ivorscott/stu/internal/loader"
	"github.com/ivorscott/stu/internal/quiz"
	"github.com/ivorscott/stu/internal/types"
)

const usage = `stu — terminal study tool

Usage:
  stu <file.json>   Open a quiz or flashcard session
  stu list          List sessions in .stu/

Controls:
  Quiz:       ↑↓ · abcd  select   enter  submit   h  hint   q  quit
  Flashcard:  space  reveal   x  wrong   c  correct   e  explain   q  quit
`

func main() {
	if len(os.Args) < 2 {
		fmt.Print(usage)
		os.Exit(0)
	}

	switch os.Args[1] {
	case "list":
		runList()
	case "-h", "--help", "help":
		fmt.Print(usage)
	default:
		runSession(os.Args[1])
	}
}

func runList() {
	cwd, err := os.Getwd()
	if err != nil {
		fmt.Fprintf(os.Stderr, "error: %v\n", err)
		os.Exit(1)
	}

	files, err := loader.ListSessions(cwd)
	if err != nil {
		fmt.Fprintf(os.Stderr, "error listing sessions: %v\n", err)
		os.Exit(1)
	}

	if len(files) == 0 {
		fmt.Println("No sessions found in .stu/")
		fmt.Println("Run /study in Claude Code to generate one.")
		return
	}

	fmt.Printf("Sessions in .stu/\n\n")
	for _, f := range files {
		s, err := loader.Load(f)
		if err != nil {
			fmt.Printf("  %-40s  error: %v\n", filepath.Base(f), err)
			continue
		}
		count := len(s.Questions)
		if s.Type == types.TypeFlashcard {
			count = len(s.Cards)
		}
		fmt.Printf("  %-44s  [%-10s]  %2d items  %s\n", filepath.Base(f), s.Type, count, s.Difficulty)
	}
}

func runSession(path string) {
	s, err := loader.Load(path)
	if err != nil {
		fmt.Fprintf(os.Stderr, "error loading %s: %v\n", path, err)
		os.Exit(1)
	}

	var m tea.Model
	switch s.Type {
	case types.TypeQuiz:
		if len(s.Questions) == 0 {
			fmt.Fprintln(os.Stderr, "error: quiz has no questions")
			os.Exit(1)
		}
		m = quiz.New(s)
	case types.TypeFlashcard:
		if len(s.Cards) == 0 {
			fmt.Fprintln(os.Stderr, "error: flashcard set has no cards")
			os.Exit(1)
		}
		m = flashcard.New(s)
	}

	p := tea.NewProgram(m, tea.WithAltScreen())
	if _, err := p.Run(); err != nil {
		fmt.Fprintf(os.Stderr, "error: %v\n", err)
		os.Exit(1)
	}
}

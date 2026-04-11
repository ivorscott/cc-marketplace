package main

import (
	"flag"
	"fmt"
	"os"
	"path/filepath"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/ivorscott/stu/internal/anki"
	"github.com/ivorscott/stu/internal/flashcard"
	"github.com/ivorscott/stu/internal/loader"
	"github.com/ivorscott/stu/internal/quiz"
	"github.com/ivorscott/stu/internal/types"
)

var version = "dev" // overridden at build time: -ldflags="-X main.version=v0.1.0"

const usage = `stu — terminal study tool

Usage:
  stu <file.json>              Open a quiz or flashcard session
  stu list                     List sessions in .stu/
  stu export <file.json>       Export flashcards to an Anki deck
  stu import <file>            Import an Anki deck (.apkg or .txt) into .stu/

Export flags:
  --format apkg|txt            Output format (default: apkg)
  --output <path>              Override output file path
  --html-strip                 Strip HTML tags from card fields
  --force                      Overwrite existing output file

Import flags:
  --title <string>             Session title (default: filename)
  --difficulty easy|medium|hard  Difficulty level (default: medium)
  --force                      Overwrite existing session file

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
	case "export":
		runExport(os.Args[2:])
	case "import":
		runImport(os.Args[2:])
	case "-v", "--version", "version":
		fmt.Printf("stu %s\n", version)
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

func runExport(args []string) {
	fs := flag.NewFlagSet("export", flag.ExitOnError)
	format := fs.String("format", "apkg", "output format: apkg|txt")
	output := fs.String("output", "", "output path (default: <name>.<format> next to input file)")
	htmlStrip := fs.Bool("html-strip", false, "strip HTML tags from card fields before writing")
	force := fs.Bool("force", false, "overwrite existing output file")
	fs.Usage = func() {
		fmt.Fprintln(os.Stderr, "Usage: stu export [flags] <file.json>")
		fs.PrintDefaults()
	}
	fs.Parse(args)

	if fs.NArg() < 1 {
		fs.Usage()
		os.Exit(1)
	}
	if *format != "apkg" && *format != "txt" {
		fmt.Fprintf(os.Stderr, "error: unknown format %q: want \"apkg\" or \"txt\"\n", *format)
		os.Exit(1)
	}

	if err := anki.Export(fs.Arg(0), anki.ExportOptions{
		Format:    *format,
		Output:    *output,
		HTMLStrip: *htmlStrip,
		Force:     *force,
	}); err != nil {
		fmt.Fprintf(os.Stderr, "error: %v\n", err)
		os.Exit(1)
	}
}

func runImport(args []string) {
	fs := flag.NewFlagSet("import", flag.ExitOnError)
	title := fs.String("title", "", "session title (default: filename without extension)")
	difficulty := fs.String("difficulty", "medium", "difficulty: easy|medium|hard")
	force := fs.Bool("force", false, "overwrite existing .stu/<slug>.json")
	fs.Usage = func() {
		fmt.Fprintln(os.Stderr, "Usage: stu import [flags] <file.apkg|file.txt>")
		fs.PrintDefaults()
	}
	fs.Parse(args)

	if fs.NArg() < 1 {
		fs.Usage()
		os.Exit(1)
	}
	if *difficulty != "easy" && *difficulty != "medium" && *difficulty != "hard" {
		fmt.Fprintf(os.Stderr, "error: unknown difficulty %q: want easy|medium|hard\n", *difficulty)
		os.Exit(1)
	}

	cwd, err := os.Getwd()
	if err != nil {
		fmt.Fprintf(os.Stderr, "error: %v\n", err)
		os.Exit(1)
	}
	stuDir := filepath.Join(cwd, ".stu")

	if err := anki.ImportFile(fs.Arg(0), anki.ImportOptions{
		Title:      *title,
		Difficulty: *difficulty,
		Force:      *force,
	}, stuDir); err != nil {
		fmt.Fprintf(os.Stderr, "error: %v\n", err)
		os.Exit(1)
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

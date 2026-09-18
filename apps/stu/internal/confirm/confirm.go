// Package confirm renders a shared yes/no confirmation prompt used by both
// the quiz and flashcard packages before a destructive action (retake).
package confirm

import "github.com/charmbracelet/lipgloss"

var (
	boxStyle = lipgloss.NewStyle().
			Border(lipgloss.NormalBorder()).
			BorderForeground(lipgloss.Color("214")).
			Padding(1, 3).
			Bold(true).
			Foreground(lipgloss.Color("15"))

	hintStyle = lipgloss.NewStyle().
			Foreground(lipgloss.Color("242"))
)

// Prompt renders a bordered confirmation box with the given message plus a
// keybinding hint.
func Prompt(message string) string {
	return boxStyle.Render(message) + "\n\n" + hintStyle.Render("y  yes    n/esc  cancel")
}

// IsConfirm reports whether key confirms the prompt.
func IsConfirm(key string) bool {
	return key == "y"
}

// IsCancel reports whether key cancels the prompt.
func IsCancel(key string) bool {
	return key == "n" || key == "esc"
}

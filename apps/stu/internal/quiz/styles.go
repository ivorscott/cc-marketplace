package quiz

import "github.com/charmbracelet/lipgloss"

var (
	titleStyle = lipgloss.NewStyle().
		Bold(true).
		Foreground(lipgloss.Color("15"))

	badgeStyle = lipgloss.NewStyle().
		Foreground(lipgloss.Color("242"))

	progressCountStyle = lipgloss.NewStyle().
		Foreground(lipgloss.Color("242"))

	questionStyle = lipgloss.NewStyle().
		Bold(true).
		Foreground(lipgloss.Color("252"))

	cursorStyle = lipgloss.NewStyle().
		Foreground(lipgloss.Color("214")).
		Bold(true)

	selectedOptStyle = lipgloss.NewStyle().
		Foreground(lipgloss.Color("214")).
		Bold(true)

	optLabelStyle = lipgloss.NewStyle().
		Foreground(lipgloss.Color("242"))

	optTextStyle = lipgloss.NewStyle().
		Foreground(lipgloss.Color("246"))

	correctOptStyle = lipgloss.NewStyle().
		Foreground(lipgloss.Color("79")).
		Bold(true)

	wrongOptStyle = lipgloss.NewStyle().
		Foreground(lipgloss.Color("203"))

	explanationStyle = lipgloss.NewStyle().
		Foreground(lipgloss.Color("242")).
		Italic(true)

	correctExplStyle = lipgloss.NewStyle().
		Foreground(lipgloss.Color("79")).
		Italic(true)

	wrongExplStyle = lipgloss.NewStyle().
		Foreground(lipgloss.Color("203")).
		Italic(true)

	hintStyle = lipgloss.NewStyle().
		Foreground(lipgloss.Color("214")).
		Italic(true)

	sepStyle = lipgloss.NewStyle().
		Foreground(lipgloss.Color("238"))

	statusStyle = lipgloss.NewStyle().
		Foreground(lipgloss.Color("242"))

	completeTitleStyle = lipgloss.NewStyle().
		Bold(true).
		Foreground(lipgloss.Color("15"))

	scoreStyle = lipgloss.NewStyle().
		Bold(true).
		Foreground(lipgloss.Color("15"))

	gradeStyle = lipgloss.NewStyle().
		Bold(true).
		Foreground(lipgloss.Color("214"))

	timeStyle = lipgloss.NewStyle().
		Foreground(lipgloss.Color("242"))

	barCorrectStyle = lipgloss.NewStyle().
		Foreground(lipgloss.Color("79"))

	barScoreGoodStyle = lipgloss.NewStyle().
		Foreground(lipgloss.Color("79"))

	barScorePoorStyle = lipgloss.NewStyle().
		Foreground(lipgloss.Color("203"))

	barWrongStyle = lipgloss.NewStyle().
		Foreground(lipgloss.Color("203"))

	barSkippedStyle = lipgloss.NewStyle().
		Foreground(lipgloss.Color("242"))

	barEmptyStyle = lipgloss.NewStyle().
		Foreground(lipgloss.Color("238"))

	statLabelStyle = lipgloss.NewStyle().
		Foreground(lipgloss.Color("242"))

	statCountStyle = lipgloss.NewStyle().
		Bold(true).
		Foreground(lipgloss.Color("252"))

	topicsTitleStyle = lipgloss.NewStyle().
		Bold(true).
		Foreground(lipgloss.Color("252"))

	topicItemStyle = lipgloss.NewStyle().
		Foreground(lipgloss.Color("242"))
)

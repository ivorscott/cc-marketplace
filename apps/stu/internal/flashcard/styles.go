package flashcard

import "github.com/charmbracelet/lipgloss"

var (
	titleStyle = lipgloss.NewStyle().
		Bold(true).
		Foreground(lipgloss.Color("15"))

	badgeStyle = lipgloss.NewStyle().
		Foreground(lipgloss.Color("242"))

	progressCountStyle = lipgloss.NewStyle().
		Foreground(lipgloss.Color("242"))

	progressDiamondStyle = lipgloss.NewStyle().
		Foreground(lipgloss.Color("214")).
		Bold(true)

	gotItStyle = lipgloss.NewStyle().
		Foreground(lipgloss.Color("79")).
		Bold(true)

	// Question-side card: dim border, no background
	questionCardStyle = lipgloss.NewStyle().
		Border(lipgloss.NormalBorder()).
		BorderForeground(lipgloss.Color("238")).
		Padding(2, 3).
		Width(52)

	// Answer-side card: amber border, no background
	revealedCardStyle = lipgloss.NewStyle().
		Border(lipgloss.NormalBorder()).
		BorderForeground(lipgloss.Color("214")).
		Padding(2, 3).
		Width(52)

	frontTextStyle = lipgloss.NewStyle().
		Bold(true).
		Foreground(lipgloss.Color("252"))

	backTextStyle = lipgloss.NewStyle().
		Bold(true).
		Foreground(lipgloss.Color("252"))

	revealPromptStyle = lipgloss.NewStyle().
		Foreground(lipgloss.Color("242")).
		Italic(true)

	explanationStyle = lipgloss.NewStyle().
		Foreground(lipgloss.Color("242")).
		Italic(true)

	explainBtnStyle = lipgloss.NewStyle().
		Foreground(lipgloss.Color("242"))

	// Nav bar (no borders — plain styled text)
	navAccentStyle = lipgloss.NewStyle().
		Foreground(lipgloss.Color("214"))

	wrongNavStyle = lipgloss.NewStyle().
		Foreground(lipgloss.Color("203"))

	rightNavStyle = lipgloss.NewStyle().
		Foreground(lipgloss.Color("79"))

	sepStyle = lipgloss.NewStyle().
		Foreground(lipgloss.Color("238"))

	statusStyle = lipgloss.NewStyle().
		Foreground(lipgloss.Color("242"))

	// Results
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

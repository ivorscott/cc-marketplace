package quiz

import (
	"fmt"
	"strings"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/ivorscott/stu/internal/render"
	"github.com/ivorscott/stu/internal/types"
)

type state int

const (
	stateQuestion state = iota
	stateAnswered
	stateResults
)

// Model is the bubbletea model for quiz sessions.
type Model struct {
	session   *types.Session
	current   int
	selected  int // -1 = none chosen
	state     state
	showHint  bool
	results   []bool // true = correct
	startTime time.Time
	width     int
	height    int
}

func New(s *types.Session) Model {
	return Model{
		session:   s,
		selected:  -1,
		startTime: time.Now(),
	}
}

func (m Model) Init() tea.Cmd {
	return nil
}

func (m Model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width = msg.Width
		m.height = msg.Height
	case tea.KeyMsg:
		switch m.state {
		case stateQuestion:
			return m.updateQuestion(msg)
		case stateAnswered:
			return m.updateAnswered(msg)
		case stateResults:
			return m.updateResults(msg)
		}
	}
	return m, nil
}

func (m Model) updateQuestion(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	q := m.session.Questions[m.current]
	switch msg.String() {
	case "ctrl+c", "q":
		return m, tea.Quit
	case "h":
		m.showHint = !m.showHint
	case "up", "k":
		if m.selected > 0 {
			m.selected--
		} else {
			m.selected = len(q.Options) - 1
		}
	case "down", "j":
		if m.selected < len(q.Options)-1 {
			m.selected++
		} else {
			m.selected = 0
		}
	case "a":
		m.selected = 0
	case "b":
		m.selected = 1
	case "c":
		m.selected = 2
	case "d":
		m.selected = 3
	case "enter", " ":
		if m.selected >= 0 {
			m.results = append(m.results, m.selected == q.Correct)
			m.state = stateAnswered
			m.showHint = false
		}
	}
	return m, nil
}

func (m Model) updateAnswered(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	switch msg.String() {
	case "ctrl+c", "q":
		return m, tea.Quit
	case "enter", "right", "l", "n":
		m.current++
		if m.current >= len(m.session.Questions) {
			m.state = stateResults
		} else {
			m.state = stateQuestion
			m.selected = -1
		}
	}
	return m, nil
}

func (m Model) updateResults(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	switch msg.String() {
	case "ctrl+c", "q":
		return m, tea.Quit
	case "r":
		m.current = 0
		m.selected = -1
		m.state = stateQuestion
		m.results = nil
		m.startTime = time.Now()
	}
	return m, nil
}

func (m Model) View() string {
	switch m.state {
	case stateQuestion:
		return m.viewQuestion()
	case stateAnswered:
		return m.viewAnswered()
	case stateResults:
		return m.viewResults()
	}
	return ""
}

func (m Model) sepW() int {
	return render.SepW(m.width)
}

func (m Model) viewQuestion() string {
	q := m.session.Questions[m.current]
	total := len(m.session.Questions)
	var b strings.Builder

	b.WriteString(titleStyle.Render(m.session.Title))
	b.WriteString(badgeStyle.Render("  ·  " + m.session.Difficulty + "  ·  " + render.SourcesLabel(len(m.session.Sources))))
	b.WriteString("\n")
	b.WriteString(sepStyle.Render(strings.Repeat("━", m.sepW())))
	b.WriteString("\n\n")

	b.WriteString(render.BlockBar(m.current+1, total, 20, barCorrectStyle, barEmptyStyle))
	b.WriteString("  ")
	b.WriteString(progressCountStyle.Render(fmt.Sprintf("%d/%d", m.current+1, total)))
	b.WriteString("\n\n")

	b.WriteString(questionStyle.Render(q.Question))
	b.WriteString("\n\n")

	labels := []string{"A", "B", "C", "D"}
	for i, opt := range q.Options {
		label := ""
		if i < len(labels) {
			label = labels[i] + ".  "
		}
		if i == m.selected {
			b.WriteString(cursorStyle.Render("▶") + " " + selectedOptStyle.Render(label+opt))
		} else {
			b.WriteString("  " + optLabelStyle.Render(label) + optTextStyle.Render(opt))
		}
		b.WriteString("\n")
	}
	b.WriteString("\n")

	if m.showHint && q.Hint != "" {
		b.WriteString(hintStyle.Render("◆  " + q.Hint))
		b.WriteString("\n\n")
	}

	b.WriteString(sepStyle.Render(strings.Repeat("─", m.sepW())))
	b.WriteString("\n")
	b.WriteString(statusStyle.Render("↑↓ · abcd  select   enter  submit   h  hint   q  quit"))
	b.WriteString("\n")

	return b.String()
}

func (m Model) viewAnswered() string {
	q := m.session.Questions[m.current]
	total := len(m.session.Questions)
	var b strings.Builder

	b.WriteString(titleStyle.Render(m.session.Title))
	b.WriteString(badgeStyle.Render("  ·  " + m.session.Difficulty + "  ·  " + render.SourcesLabel(len(m.session.Sources))))
	b.WriteString("\n")
	b.WriteString(sepStyle.Render(strings.Repeat("━", m.sepW())))
	b.WriteString("\n\n")

	b.WriteString(render.BlockBar(m.current+1, total, 20, barCorrectStyle, barEmptyStyle))
	b.WriteString("  ")
	b.WriteString(progressCountStyle.Render(fmt.Sprintf("%d/%d", m.current+1, total)))
	b.WriteString("\n\n")

	b.WriteString(questionStyle.Render(q.Question))
	b.WriteString("\n\n")

	labels := []string{"A", "B", "C", "D"}
	for i, opt := range q.Options {
		label := ""
		if i < len(labels) {
			label = labels[i] + ".  "
		}
		if i == q.Correct {
			b.WriteString(correctOptStyle.Render("✓ " + label + opt))
			b.WriteString("\n")
			if i < len(q.Explanations) {
				prefix := ""
				if i == m.selected {
					prefixes := []string{"Correct!", "That's right!", "You got it!"}
					prefix = prefixes[m.current%len(prefixes)] + " "
				}
				b.WriteString("  " + correctExplStyle.Render("↳  "+prefix+q.Explanations[i]))
				b.WriteString("\n")
			}
		} else if i == m.selected {
			b.WriteString(wrongOptStyle.Render("✗ " + label + opt))
			b.WriteString("\n")
			if i < len(q.Explanations) {
				b.WriteString("  " + wrongExplStyle.Render("↳  "+q.Explanations[i]))
				b.WriteString("\n")
			}
		} else {
			b.WriteString("  " + optLabelStyle.Render(label) + optTextStyle.Render(opt))
			b.WriteString("\n")
			if i < len(q.Explanations) {
				b.WriteString("  " + explanationStyle.Render("↳  "+q.Explanations[i]))
				b.WriteString("\n")
			}
		}
	}
	b.WriteString("\n")

	b.WriteString(sepStyle.Render(strings.Repeat("─", m.sepW())))
	b.WriteString("\n")
	b.WriteString(statusStyle.Render("enter · →  next   q  quit"))
	b.WriteString("\n")

	return b.String()
}

func (m Model) viewResults() string {
	right := 0
	for _, r := range m.results {
		if r {
			right++
		}
	}
	wrong := len(m.results) - right
	total := len(m.session.Questions)
	skipped := total - len(m.results)
	pct := 0
	if total > 0 {
		pct = right * 100 / total
	}
	elapsed := time.Since(m.startTime).Round(time.Second)

	var b strings.Builder

	b.WriteString(completeTitleStyle.Render("Session complete"))
	b.WriteString(badgeStyle.Render("  ·  " + m.session.Title))
	b.WriteString("\n")
	b.WriteString(sepStyle.Render(strings.Repeat("━", m.sepW())))
	b.WriteString("\n\n")

	b.WriteString(scoreStyle.Render(fmt.Sprintf("%d/%d", right, total)))
	b.WriteString(badgeStyle.Render("  ·  "))
	b.WriteString(scoreStyle.Render(fmt.Sprintf("%d%%", pct)))
	b.WriteString(badgeStyle.Render("  ·  "))
	b.WriteString(gradeStyle.Render(render.LetterGrade(pct)))
	b.WriteString("\n")
	b.WriteString(timeStyle.Render(render.FormatElapsed(elapsed)))
	b.WriteString("\n\n")

	scoreBarFill := barScoreGoodStyle
	if pct < 70 {
		scoreBarFill = barScorePoorStyle
	}
	b.WriteString(render.BlockBar(right, total, 30, scoreBarFill, barEmptyStyle))
	b.WriteString("\n\n")

	const barW = 20
	b.WriteString(statLabelStyle.Render("Correct   "))
	b.WriteString(render.BlockBar(right, total, barW, barCorrectStyle, barEmptyStyle))
	b.WriteString("  " + statCountStyle.Render(fmt.Sprintf("%d", right)))
	b.WriteString("\n")

	b.WriteString(statLabelStyle.Render("Wrong     "))
	b.WriteString(render.BlockBar(wrong, total, barW, barWrongStyle, barEmptyStyle))
	b.WriteString("  " + statCountStyle.Render(fmt.Sprintf("%d", wrong)))
	b.WriteString("\n")

	b.WriteString(statLabelStyle.Render("Skipped   "))
	b.WriteString(render.BlockBar(skipped, total, barW, barSkippedStyle, barEmptyStyle))
	b.WriteString("  " + statCountStyle.Render(fmt.Sprintf("%d", skipped)))
	b.WriteString("\n\n")

	if len(m.session.Sources) > 0 {
		b.WriteString(topicsTitleStyle.Render("Sources"))
		b.WriteString("\n")
		for _, src := range m.session.Sources {
			b.WriteString(topicItemStyle.Render("  ·  " + render.FormatSource(src)))
			b.WriteString("\n")
		}
		b.WriteString("\n")
	}

	b.WriteString(sepStyle.Render(strings.Repeat("─", m.sepW())))
	b.WriteString("\n")
	b.WriteString(statusStyle.Render("r  retake   q  quit"))
	b.WriteString("\n")

	return b.String()
}

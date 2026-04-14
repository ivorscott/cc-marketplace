package flashcard

import (
	"fmt"
	"strings"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/ivorscott/cc-marketplace/apps/stu/internal/render"
	"github.com/ivorscott/cc-marketplace/apps/stu/internal/types"
)

type state int

const (
	stateQuestion state = iota
	stateRevealed
	stateResults
)

type answer int

const (
	answerNone  answer = iota
	answerRight        // marked correct
	answerWrong        // marked wrong
)

// Model is the bubbletea model for flashcard sessions.
type Model struct {
	session     *types.Session
	current     int
	state       state
	showExplain bool
	answers     map[int]answer
	wrong       int
	right       int
	startTime   time.Time
	width       int
	height      int
}

func New(s *types.Session) Model {
	return Model{session: s, answers: make(map[int]answer), startTime: time.Now()}
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
		case stateRevealed:
			return m.updateRevealed(msg)
		case stateResults:
			return m.updateResults(msg)
		}
	}
	return m, nil
}

func (m Model) updateQuestion(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	switch msg.String() {
	case "ctrl+c", "q":
		return m, tea.Quit
	case "enter", " ":
		m.state = stateRevealed
		m.showExplain = false
	case "right", "l":
		m.advance()
	case "left", "h":
		m.retreat()
	case "f":
		m.state = stateResults
	}
	return m, nil
}

func (m Model) updateRevealed(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	switch msg.String() {
	case "ctrl+c", "q":
		return m, tea.Quit
	case "e":
		m.showExplain = !m.showExplain
	case "x":
		prev := m.answers[m.current]
		if prev != answerWrong {
			if prev == answerRight {
				m.right--
			}
			m.wrong++
			m.answers[m.current] = answerWrong
		}
		if m.right+m.wrong == len(m.session.Cards) {
			m.state = stateResults
		} else {
			m.advance()
		}
	case "enter", "c":
		prev := m.answers[m.current]
		if prev != answerRight {
			if prev == answerWrong {
				m.wrong--
			}
			m.right++
			m.answers[m.current] = answerRight
		}
		if m.right+m.wrong == len(m.session.Cards) {
			m.state = stateResults
		} else {
			m.advance()
		}
	case "right", "l":
		m.advance()
	case "left", "h":
		m.retreat()
	case "f":
		m.state = stateResults
	}
	return m, nil
}

func (m Model) updateResults(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	switch msg.String() {
	case "ctrl+c", "q":
		return m, tea.Quit
	case "r":
		m.current = 0
		m.state = stateQuestion
		m.answers = make(map[int]answer)
		m.wrong = 0
		m.right = 0
		m.startTime = time.Now()
		m.showExplain = false
	}
	return m, nil
}

func (m *Model) advance() {
	if m.current < len(m.session.Cards)-1 {
		m.current++
	} else {
		m.current = 0
	}
	m.state = stateQuestion
	m.showExplain = false
}

func (m *Model) retreat() {
	if m.current > 0 {
		m.current--
	} else {
		m.current = len(m.session.Cards) - 1
	}
	m.state = stateQuestion
	m.showExplain = false
}

func (m Model) View() string {
	switch m.state {
	case stateQuestion:
		return m.viewQuestion()
	case stateRevealed:
		return m.viewRevealed()
	case stateResults:
		return m.viewResults()
	}
	return ""
}

func (m Model) sepW() int {
	return render.SepW(m.width)
}

func (m Model) viewQuestion() string {
	card := m.session.Cards[m.current]
	total := len(m.session.Cards)
	var b strings.Builder

	b.WriteString(titleStyle.Render(m.session.Title))
	b.WriteString(badgeStyle.Render("  ·  " + m.session.Difficulty))
	b.WriteString("\n")
	b.WriteString(sepStyle.Render(strings.Repeat("━", m.sepW())))
	b.WriteString("\n\n")

	progress := progressDiamondStyle.Render("◈") + "  " +
		progressCountStyle.Render(fmt.Sprintf("%d / %d", m.current+1, total))
	if m.answers[m.current] == answerRight {
		progress += "    " + gotItStyle.Render("Got it")
	}
	b.WriteString(progress)
	b.WriteString("\n\n")

	front := frontTextStyle.Render(card.Front) + "\n\n" + revealPromptStyle.Render("↵  reveal")
	b.WriteString(questionCardStyle.Render(front))
	b.WriteString("\n\n")

	b.WriteString(m.navBar())
	b.WriteString("\n\n")

	b.WriteString(sepStyle.Render(strings.Repeat("─", m.sepW())))
	b.WriteString("\n")
	b.WriteString(statusStyle.Render("←/→  navigate   space  reveal   f  finish   q  quit"))
	b.WriteString("\n")

	return b.String()
}

func (m Model) viewRevealed() string {
	card := m.session.Cards[m.current]
	total := len(m.session.Cards)
	var b strings.Builder

	b.WriteString(titleStyle.Render(m.session.Title))
	b.WriteString(badgeStyle.Render("  ·  " + m.session.Difficulty))
	b.WriteString("\n")
	b.WriteString(sepStyle.Render(strings.Repeat("━", m.sepW())))
	b.WriteString("\n\n")

	b.WriteString(progressDiamondStyle.Render("◈") + "  " +
		progressCountStyle.Render(fmt.Sprintf("%d / %d", m.current+1, total)))
	b.WriteString("\n\n")

	back := backTextStyle.Render(card.Back)
	if m.showExplain && card.Explanation != "" {
		back += "\n\n" + explanationStyle.Render(card.Explanation)
	}
	if card.Explanation != "" {
		back += "\n\n" + explainBtnStyle.Render("⊞  explain [e]")
	}
	b.WriteString(revealedCardStyle.Render(back))
	b.WriteString("\n\n")

	b.WriteString(m.navBar())
	b.WriteString("\n\n")

	b.WriteString(sepStyle.Render(strings.Repeat("─", m.sepW())))
	b.WriteString("\n")
	b.WriteString(statusStyle.Render("x  wrong   c/↵  correct   e  explain   ←/→  navigate   q  quit"))
	b.WriteString("\n")

	return b.String()
}

func (m Model) viewResults() string {
	total := len(m.session.Cards)
	skipped := total - m.right - m.wrong
	pct := 0
	if total > 0 {
		pct = m.right * 100 / total
	}
	elapsed := time.Since(m.startTime).Round(time.Second)

	var b strings.Builder

	b.WriteString(completeTitleStyle.Render("Session complete"))
	b.WriteString(badgeStyle.Render("  ·  " + m.session.Title))
	b.WriteString("\n")
	b.WriteString(sepStyle.Render(strings.Repeat("━", m.sepW())))
	b.WriteString("\n\n")

	b.WriteString(scoreStyle.Render(fmt.Sprintf("%d/%d", m.right, total)))
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
	b.WriteString(render.BlockBar(m.right, total, 30, scoreBarFill, barEmptyStyle))
	b.WriteString("\n\n")

	const barW = 20
	b.WriteString(statLabelStyle.Render("Got it    "))
	b.WriteString(render.BlockBar(m.right, total, barW, barCorrectStyle, barEmptyStyle))
	b.WriteString("  " + statCountStyle.Render(fmt.Sprintf("%d", m.right)))
	b.WriteString("\n")

	b.WriteString(statLabelStyle.Render("Missed    "))
	b.WriteString(render.BlockBar(m.wrong, total, barW, barWrongStyle, barEmptyStyle))
	b.WriteString("  " + statCountStyle.Render(fmt.Sprintf("%d", m.wrong)))
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

func (m Model) navBar() string {
	return navAccentStyle.Render("←") +
		"   " + wrongNavStyle.Render(fmt.Sprintf("✗ %d", m.wrong)) +
		"   " + rightNavStyle.Render(fmt.Sprintf("%d ✓", m.right)) +
		"   " + navAccentStyle.Render("→")
}

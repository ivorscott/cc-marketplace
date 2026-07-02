package flashcard

import (
	"fmt"
	"math/rand"
	"strings"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/ivorscott/cc-marketplace/apps/stu/internal/confirm"
	"github.com/ivorscott/cc-marketplace/apps/stu/internal/progress"
	"github.com/ivorscott/cc-marketplace/apps/stu/internal/render"
	"github.com/ivorscott/cc-marketplace/apps/stu/internal/types"
)

type state int

const (
	stateQuestion state = iota
	stateRevealed
	stateResults
	stateConfirmRetake
)

type answer int

const (
	answerNone  answer = iota
	answerRight        // marked correct
	answerWrong        // marked wrong
)

type resultsPage int

const (
	resultsPageStats resultsPage = iota
	resultsPageMissed
)

// Model is the bubbletea model for flashcard sessions.
type Model struct {
	session      *types.Session
	sessionPath  string
	byID         map[int]types.Card // card.ID -> Card
	deck         []int              // ordered card IDs for this attempt
	current      int                // index into deck
	state        state
	resultsPage  resultsPage
	showExplain  bool
	answers      map[int]answer // keyed by card.ID, this run only
	wrong        int            // this run only
	right        int            // this run only
	priorSeenIDs []int          // cards already seen before this run (from a resumed prior run)
	priorRight   int            // right count carried over from a resumed prior run
	priorWrong   int            // wrong count carried over from a resumed prior run
	startTime    time.Time
	width        int
	height       int
}

// New builds a flashcard Model for the given session, loaded from path (used
// to locate/write this session's per-file progress state under .stu/.state/).
// If prior progress exists for path, already-seen cards are skipped and their
// stats are carried over so results reflect the combined attempt. m.right and
// m.wrong always track only this run's grading, so the existing
// right+wrong==len(deck) termination check stays correct regardless of resume.
func New(s *types.Session, path string) Model {
	byID := make(map[int]types.Card, len(s.Cards))
	st, _ := progress.Load(path) // ignore error: missing/corrupt state = start fresh
	seen := make(map[int]bool, len(st.SeenIDs))
	for _, id := range st.SeenIDs {
		seen[id] = true
	}

	deck := make([]int, 0, len(s.Cards))
	for _, c := range s.Cards {
		byID[c.ID] = c
		if !seen[c.ID] {
			deck = append(deck, c.ID)
		}
	}
	if len(deck) == 0 {
		// Every card already seen in a prior run: treat as a full fresh pass
		// rather than presenting an empty/immediately-finished session.
		for _, c := range s.Cards {
			deck = append(deck, c.ID)
		}
		st = progress.State{}
	}

	return Model{
		session:      s,
		sessionPath:  path,
		byID:         byID,
		deck:         deck,
		answers:      make(map[int]answer),
		priorSeenIDs: st.SeenIDs,
		priorRight:   st.Right,
		priorWrong:   st.Wrong,
		startTime:    time.Now(),
	}
}

func (m Model) currentCard() types.Card {
	return m.byID[m.deck[m.current]]
}

// missedCardIDs returns the card IDs marked wrong in the current attempt.
func (m Model) missedCardIDs() []int {
	var ids []int
	for id, a := range m.answers {
		if a == answerWrong {
			ids = append(ids, id)
		}
	}
	return ids
}

// startRetake builds a fresh shuffled deck, weighting toward cards missed in
// the just-finished attempt (see buildWeightedDeck), and resets session state.
// Retake always starts a full fresh deck and clears any carried-over resume
// state — it never consults .stu/.state/.
func (m *Model) startRetake() {
	missed := m.missedCardIDs()

	base := make([]int, len(m.session.Cards))
	for i, c := range m.session.Cards {
		base[i] = c.ID
	}
	rand.Shuffle(len(base), func(i, j int) { base[i], base[j] = base[j], base[i] })

	m.deck = buildWeightedDeck(base, missed, rand.New(rand.NewSource(time.Now().UnixNano())))
	m.current = 0
	m.state = stateQuestion
	m.resultsPage = resultsPageStats
	m.answers = make(map[int]answer)
	m.wrong = 0
	m.right = 0
	m.priorSeenIDs = nil
	m.priorRight = 0
	m.priorWrong = 0
	m.startTime = time.Now()
	m.showExplain = false
}

// buildWeightedDeck walks base (already shuffled) and, for each slot after
// the first, has a 1-in-3 chance to substitute a randomly chosen missed-card
// ID instead of the next base card, provided doing so would not repeat the
// immediately preceding deck entry. If missed is empty, base is returned
// unchanged. rng is injected for testability.
func buildWeightedDeck(base []int, missed []int, rng *rand.Rand) []int {
	if len(missed) == 0 || len(base) == 0 {
		return base
	}
	deck := make([]int, 0, len(base))
	for i, id := range base {
		next := id
		if i > 0 && rng.Intn(3) == 0 {
			candidate := missed[rng.Intn(len(missed))]
			if candidate != deck[len(deck)-1] {
				next = candidate
			}
		}
		// The fallback (unchanged base card) can itself collide with the
		// previous deck entry if an earlier injection replaced that slot
		// with this position's natural card. Try a missed-pool alternative
		// before accepting the repeat.
		if i > 0 && next == deck[len(deck)-1] {
			for _, cand := range missed {
				if cand != deck[len(deck)-1] {
					next = cand
					break
				}
			}
		}
		deck = append(deck, next)
	}
	return deck
}

// saveProgress persists which cards have been seen across this run and any
// prior resumed run, so a later launch of the same session file can skip
// them and display combined stats.
func (m Model) saveProgress() {
	if m.sessionPath == "" {
		return
	}
	seenSet := make(map[int]bool, len(m.priorSeenIDs)+len(m.answers))
	for _, id := range m.priorSeenIDs {
		seenSet[id] = true
	}
	for id := range m.answers {
		seenSet[id] = true
	}
	seen := make([]int, 0, len(seenSet))
	for id := range seenSet {
		seen = append(seen, id)
	}
	_ = progress.Save(m.sessionPath, progress.State{
		SeenIDs: seen,
		Right:   m.priorRight + m.right,
		Wrong:   m.priorWrong + m.wrong,
	})
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
		case stateConfirmRetake:
			return m.updateConfirmRetake(msg)
		}
	}
	return m, nil
}

func (m Model) updateQuestion(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	switch msg.String() {
	case "ctrl+c", "q":
		m.saveProgress()
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
		m.saveProgress()
	}
	return m, nil
}

func (m Model) updateRevealed(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	switch msg.String() {
	case "ctrl+c", "q":
		m.saveProgress()
		return m, tea.Quit
	case "e":
		m.showExplain = !m.showExplain
	case "x":
		id := m.deck[m.current]
		prev := m.answers[id]
		if prev != answerWrong {
			if prev == answerRight {
				m.right--
			}
			m.wrong++
			m.answers[id] = answerWrong
		}
		if m.right+m.wrong == len(m.deck) {
			m.state = stateResults
			m.saveProgress()
		} else {
			m.advance()
		}
	case "enter", "c":
		id := m.deck[m.current]
		prev := m.answers[id]
		if prev != answerRight {
			if prev == answerWrong {
				m.wrong--
			}
			m.right++
			m.answers[id] = answerRight
		}
		if m.right+m.wrong == len(m.deck) {
			m.state = stateResults
			m.saveProgress()
		} else {
			m.advance()
		}
	case "right", "l":
		m.advance()
	case "left", "h":
		m.retreat()
	case "f":
		m.state = stateResults
		m.saveProgress()
	}
	return m, nil
}

func (m Model) updateResults(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	switch msg.String() {
	case "ctrl+c", "q":
		m.saveProgress()
		return m, tea.Quit
	case "r":
		m.state = stateConfirmRetake
	case "tab":
		if m.resultsPage == resultsPageStats {
			m.resultsPage = resultsPageMissed
		} else {
			m.resultsPage = resultsPageStats
		}
	}
	return m, nil
}

func (m Model) updateConfirmRetake(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	switch {
	case confirm.IsConfirm(msg.String()):
		m.startRetake()
	case confirm.IsCancel(msg.String()):
		m.state = stateResults
	}
	return m, nil
}

func (m *Model) advance() {
	if m.current < len(m.deck)-1 {
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
		m.current = len(m.deck) - 1
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
	case stateConfirmRetake:
		return m.viewConfirmRetake()
	}
	return ""
}

func (m Model) sepW() int {
	return render.SepW(m.width)
}

func (m Model) viewQuestion() string {
	card := m.currentCard()
	total := len(m.deck)
	var b strings.Builder

	b.WriteString(titleStyle.Render(m.session.Title))
	b.WriteString(badgeStyle.Render("  ·  " + m.session.Difficulty))
	b.WriteString("\n")
	b.WriteString(sepStyle.Render(strings.Repeat("━", m.sepW())))
	b.WriteString("\n\n")

	progress := progressDiamondStyle.Render("◈") + "  " +
		progressCountStyle.Render(fmt.Sprintf("%d / %d", m.current+1, total))
	if m.answers[card.ID] == answerRight {
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
	card := m.currentCard()
	total := len(m.deck)
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
	if m.resultsPage == resultsPageMissed {
		return m.viewMissedCards()
	}

	total := len(m.session.Cards)
	right := m.priorRight + m.right
	wrong := m.priorWrong + m.wrong
	skipped := total - right - wrong
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
	b.WriteString(statLabelStyle.Render("Got it    "))
	b.WriteString(render.BlockBar(right, total, barW, barCorrectStyle, barEmptyStyle))
	b.WriteString("  " + statCountStyle.Render(fmt.Sprintf("%d", right)))
	b.WriteString("\n")

	b.WriteString(statLabelStyle.Render("Missed    "))
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
	b.WriteString(statusStyle.Render("tab  missed cards   r  retake   q  quit"))
	b.WriteString("\n")

	return b.String()
}

func (m Model) viewMissedCards() string {
	var b strings.Builder

	b.WriteString(completeTitleStyle.Render("Cards to review"))
	b.WriteString(badgeStyle.Render("  ·  " + m.session.Title))
	b.WriteString("\n")
	b.WriteString(sepStyle.Render(strings.Repeat("━", m.sepW())))
	b.WriteString("\n\n")

	n := 0
	for _, card := range m.session.Cards {
		if m.answers[card.ID] == answerWrong {
			n++
			line := fmt.Sprintf("%d. \"%s -> %s\"", n, truncate52(card.Front), truncate52(card.Back))
			b.WriteString(topicItemStyle.Render(line))
			b.WriteString("\n")
		}
	}
	if n == 0 {
		b.WriteString(statusStyle.Render("No missed cards — nice work!"))
		b.WriteString("\n")
	}
	b.WriteString("\n")

	b.WriteString(sepStyle.Render(strings.Repeat("─", m.sepW())))
	b.WriteString("\n")
	b.WriteString(statusStyle.Render("tab  back to stats   r  retake   q  quit"))
	b.WriteString("\n")

	return b.String()
}

// truncate52 truncates s to 52 visible runes, appending " [...]" if truncated.
func truncate52(s string) string {
	r := []rune(s)
	if len(r) <= 52 {
		return s
	}
	return string(r[:52]) + " [...]"
}

func (m Model) viewConfirmRetake() string {
	return m.viewResults() + "\n" + confirm.Prompt("Retake this session? Current progress will be reset.")
}

func (m Model) navBar() string {
	return navAccentStyle.Render("←") +
		"   " + wrongNavStyle.Render(fmt.Sprintf("✗ %d", m.wrong)) +
		"   " + rightNavStyle.Render(fmt.Sprintf("%d ✓", m.right)) +
		"   " + navAccentStyle.Render("→")
}

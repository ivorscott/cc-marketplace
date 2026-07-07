package flashcard

import (
	"fmt"
	"math/rand"
	"strings"
	"time"

	vpkey "github.com/charmbracelet/bubbles/key"
	"github.com/charmbracelet/bubbles/viewport"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/ivorscott/cc-marketplace/apps/stu/internal/confirm"
	"github.com/ivorscott/cc-marketplace/apps/stu/internal/progress"
	"github.com/ivorscott/cc-marketplace/apps/stu/internal/render"
	"github.com/ivorscott/cc-marketplace/apps/stu/internal/types"
)

const (
	// defaultMissedWidth/Height size the missed-cards viewport before the
	// first WindowSizeMsg arrives (tests, or a program that never resizes).
	defaultMissedWidth  = 56
	defaultMissedHeight = 12

	// missedViewportChrome is the number of non-content lines viewMissedCards
	// wraps around the viewport (title+badge, separator, blank, blank,
	// separator, footer), subtracted from terminal height to size the
	// viewport so the whole view fits without the terminal itself scrolling.
	missedViewportChrome = 7
)

type state int

const (
	stateQuestion state = iota
	stateRevealed
	stateResults
	stateConfirmRetake
	statePeekMissed
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
	session     *types.Session
	sessionPath string
	byID        map[int]types.Card // card.ID -> Card
	deck        []int              // ordered card IDs, always the full session card set
	current     int                // index into deck
	state       state
	peekReturn  state // state to restore when leaving statePeekMissed
	resultsPage resultsPage
	showExplain bool
	answers     map[int]answer // keyed by card.ID, all-time (this run + resumed prior runs)
	wrong       int            // all-time count
	right       int            // all-time count
	startTime   time.Time
	width       int
	height      int
	missedVP    viewport.Model // scrollable "cards to review" list
}

// New builds a flashcard Model for the given session, loaded from path (used
// to locate/write this session's per-file progress state under .stu/.state/).
// The deck always spans the full session card set, in original order, so
// resuming never shrinks the visible total or the position numbering. If
// prior progress exists for path, each card's specific right/wrong verdict
// is restored into m.answers (not just an aggregate count), and m.current is
// set to the first not-yet-answered card so resuming picks up right after
// where the prior run left off.
func New(s *types.Session, path string) Model {
	byID := make(map[int]types.Card, len(s.Cards))
	st, _ := progress.Load(path) // ignore error: missing/corrupt state = start fresh

	answers := make(map[int]answer, len(st.Right)+len(st.Wrong))
	for _, id := range st.Right {
		answers[id] = answerRight
	}
	for _, id := range st.Wrong {
		answers[id] = answerWrong
	}

	deck := make([]int, len(s.Cards))
	for i, c := range s.Cards {
		byID[c.ID] = c
		deck[i] = c.ID
	}

	if len(answers) >= len(deck) {
		// Every card already answered in a prior run: treat as a full fresh
		// pass rather than presenting an already-finished session.
		answers = make(map[int]answer)
	}

	current := 0
	for i, id := range deck {
		if answers[id] == answerNone {
			current = i
			break
		}
	}

	right, wrong := 0, 0
	for _, a := range answers {
		switch a {
		case answerRight:
			right++
		case answerWrong:
			wrong++
		}
	}

	vp := viewport.New(defaultMissedWidth, defaultMissedHeight)
	vp.KeyMap = viewport.KeyMap{
		Up:       vpkey.NewBinding(vpkey.WithKeys("up")),
		Down:     vpkey.NewBinding(vpkey.WithKeys("down")),
		PageUp:   vpkey.NewBinding(vpkey.WithKeys("pgup")),
		PageDown: vpkey.NewBinding(vpkey.WithKeys("pgdown")),
	}

	return Model{
		session:     s,
		sessionPath: path,
		byID:        byID,
		deck:        deck,
		current:     current,
		answers:     answers,
		right:       right,
		wrong:       wrong,
		startTime:   time.Now(),
		missedVP:    vp,
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

// saveProgress persists each card's right/wrong verdict across this run and
// any prior resumed run, so a later launch of the same session file can
// restore exactly which cards were missed, not just an aggregate count.
func (m Model) saveProgress() {
	if m.sessionPath == "" {
		return
	}
	var right, wrong []int
	for id, a := range m.answers {
		switch a {
		case answerRight:
			right = append(right, id)
		case answerWrong:
			wrong = append(wrong, id)
		}
	}
	_ = progress.Save(m.sessionPath, progress.State{Right: right, Wrong: wrong})
}

func (m Model) Init() tea.Cmd {
	return nil
}

func (m Model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width = msg.Width
		m.height = msg.Height
		m.missedVP.Width = m.sepW()
		h := m.height - missedViewportChrome
		if h < 3 {
			h = 3
		}
		m.missedVP.Height = h
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
		case statePeekMissed:
			return m.updatePeekMissed(msg)
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
	case "tab":
		m.peekReturn = stateQuestion
		m.state = statePeekMissed
		m.refreshMissedViewport()
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
	case "tab":
		m.peekReturn = stateRevealed
		m.state = statePeekMissed
		m.refreshMissedViewport()
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
		return m, nil
	case "tab":
		if m.resultsPage == resultsPageStats {
			m.resultsPage = resultsPageMissed
			m.refreshMissedViewport()
		} else {
			m.resultsPage = resultsPageStats
		}
		return m, nil
	}
	if m.resultsPage == resultsPageMissed {
		var cmd tea.Cmd
		m.missedVP, cmd = m.missedVP.Update(msg)
		return m, cmd
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

func (m Model) updatePeekMissed(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	switch msg.String() {
	case "ctrl+c", "q":
		m.saveProgress()
		return m, tea.Quit
	case "tab", "esc":
		m.state = m.peekReturn
		return m, nil
	}
	var cmd tea.Cmd
	m.missedVP, cmd = m.missedVP.Update(msg)
	return m, cmd
}

// refreshMissedViewport rebuilds the missed-cards viewport content from the
// current answers and scrolls back to the top. Call this whenever a view
// showing the missed-cards list is entered, since answers may have changed
// since the viewport content was last set.
func (m *Model) refreshMissedViewport() {
	width := m.missedVP.Width
	if width <= 0 {
		width = m.sepW()
	}
	wrap := lipgloss.NewStyle().Width(width)

	var b strings.Builder
	n := 0
	for _, card := range m.session.Cards {
		if m.answers[card.ID] == answerWrong {
			n++
			line := fmt.Sprintf("%d. \"%s\"\n\t-> \"%s\"", n, card.Front, card.Back)
			b.WriteString(topicItemStyle.Render(wrap.Render(line)))
			b.WriteString("\n")
		}
	}
	if n == 0 {
		b.WriteString(statusStyle.Render("No missed cards — nice work!"))
	}
	m.missedVP.SetContent(strings.TrimRight(b.String(), "\n"))
	m.missedVP.GotoTop()
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
	case statePeekMissed:
		return m.viewMissedCards()
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
	switch m.answers[card.ID] {
	case answerRight:
		progress += "    " + gotItStyle.Render("Got it")
	case answerWrong:
		progress += "    " + missedItStyle.Render("Missed it")
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
	b.WriteString(statusStyle.Render("←/→  navigate   space  reveal   tab  missed   f  finish   q  quit"))
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

	progress := progressDiamondStyle.Render("◈") + "  " +
		progressCountStyle.Render(fmt.Sprintf("%d / %d", m.current+1, total))
	switch m.answers[card.ID] {
	case answerRight:
		progress += "    " + gotItStyle.Render("Got it")
	case answerWrong:
		progress += "    " + missedItStyle.Render("Missed it")
	}
	b.WriteString(progress)
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
	b.WriteString(statusStyle.Render("x  wrong   c/↵  correct   e  explain   tab  missed   ←/→  navigate   q  quit"))
	b.WriteString("\n")

	return b.String()
}

func (m Model) viewResults() string {
	if m.resultsPage == resultsPageMissed {
		return m.viewMissedCards()
	}

	total := len(m.session.Cards)
	right := m.right
	wrong := m.wrong
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

	b.WriteString(m.missedVP.View())
	b.WriteString("\n\n")

	b.WriteString(sepStyle.Render(strings.Repeat("─", m.sepW())))
	b.WriteString("\n")
	footer := "↑/↓ pgup/pgdn  scroll   tab  back to stats   r  retake   q  quit"
	if m.state == statePeekMissed {
		footer = "↑/↓ pgup/pgdn  scroll   tab  back to session   q  quit"
	}
	b.WriteString(statusStyle.Render(footer))
	b.WriteString("\n")

	return b.String()
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

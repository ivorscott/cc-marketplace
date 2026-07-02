package flashcard

import (
	"math/rand"
	"path/filepath"
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/ivorscott/cc-marketplace/apps/stu/internal/types"
)

// session builds a flashcard session with n cards.
func session(n int) *types.Session {
	cards := make([]types.Card, n)
	for i := range cards {
		cards[i] = types.Card{
			ID:          i + 1,
			Front:       "Front",
			Back:        "Back",
			Explanation: "Because",
		}
	}
	return &types.Session{Type: types.TypeFlashcard, Title: "T", Cards: cards}
}

func key(k string) tea.KeyMsg {
	switch k {
	case "enter":
		return tea.KeyMsg{Type: tea.KeyEnter}
	case "space":
		return tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{' '}}
	case "left":
		return tea.KeyMsg{Type: tea.KeyLeft}
	case "right":
		return tea.KeyMsg{Type: tea.KeyRight}
	default:
		return tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune(k)}
	}
}

func update(m Model, k string) Model {
	next, _ := m.Update(key(k))
	return next.(Model)
}

func TestNew(t *testing.T) {
	m := New(session(3), "")
	if m.current != 0 {
		t.Errorf("current = %d, want 0", m.current)
	}
	if m.state != stateQuestion {
		t.Errorf("state = %v, want stateQuestion", m.state)
	}
	if m.right != 0 || m.wrong != 0 {
		t.Errorf("right=%d wrong=%d, want 0 0", m.right, m.wrong)
	}
}

func TestUpdate_WindowSize(t *testing.T) {
	m := New(session(1), "")
	next, _ := m.Update(tea.WindowSizeMsg{Width: 80, Height: 24})
	m = next.(Model)
	if m.width != 80 || m.height != 24 {
		t.Errorf("width=%d height=%d, want 80 24", m.width, m.height)
	}
}

func TestUpdate_Reveal(t *testing.T) {
	for _, k := range []string{"space", "enter"} {
		m := New(session(1), "")
		m = update(m, k)
		if m.state != stateRevealed {
			t.Errorf("key %q: state = %v, want stateRevealed", k, m.state)
		}
	}
}

func TestUpdate_MarkCorrect(t *testing.T) {
	for _, k := range []string{"c", "enter"} {
		m := New(session(2), "")
		m = update(m, "space") // reveal
		m = update(m, k)       // mark correct
		if m.right != 1 {
			t.Errorf("key %q: right = %d, want 1", k, m.right)
		}
		if m.wrong != 0 {
			t.Errorf("key %q: wrong = %d, want 0", k, m.wrong)
		}
		if m.state != stateQuestion {
			t.Errorf("key %q: state = %v, want stateQuestion", k, m.state)
		}
	}
}

func TestUpdate_MarkWrong(t *testing.T) {
	m := New(session(2), "")
	m = update(m, "space") // reveal
	m = update(m, "x")     // mark wrong
	if m.wrong != 1 {
		t.Errorf("wrong = %d, want 1", m.wrong)
	}
	if m.right != 0 {
		t.Errorf("right = %d, want 0", m.right)
	}
	if m.state != stateQuestion {
		t.Errorf("state = %v, want stateQuestion", m.state)
	}
}

func TestUpdate_Rescoring_WrongToCorrect(t *testing.T) {
	m := New(session(2), "")
	m = update(m, "space")
	m = update(m, "x")
	m = update(m, "left")
	m = update(m, "space")
	m = update(m, "c")
	if m.right != 1 {
		t.Errorf("right = %d, want 1 after rescoring", m.right)
	}
	if m.wrong != 0 {
		t.Errorf("wrong = %d, want 0 after rescoring", m.wrong)
	}
}

func TestUpdate_Rescoring_CorrectToWrong(t *testing.T) {
	m := New(session(2), "")
	m = update(m, "space")
	m = update(m, "c")
	m = update(m, "left")
	m = update(m, "space")
	m = update(m, "x")
	if m.wrong != 1 {
		t.Errorf("wrong = %d, want 1 after rescoring", m.wrong)
	}
	if m.right != 0 {
		t.Errorf("right = %d, want 0 after rescoring", m.right)
	}
}

func TestUpdate_DoubleMarkDoesNotDouble(t *testing.T) {
	m := New(session(2), "")
	m = update(m, "space")
	m = update(m, "c")     // → card 1
	m = update(m, "left")  // back to card 0
	m = update(m, "space")
	m = update(m, "c") // mark correct again — should not increment
	if m.right != 1 {
		t.Errorf("right = %d, want 1 (no double count)", m.right)
	}
}

func TestUpdate_AutoAdvanceToResults(t *testing.T) {
	m := New(session(2), "")
	m = update(m, "space")
	m = update(m, "c") // card 0 correct, advance
	m = update(m, "space")
	m = update(m, "c") // card 1 correct, all answered → results
	if m.state != stateResults {
		t.Errorf("state = %v, want stateResults after all cards answered", m.state)
	}
}

func TestUpdate_Finish(t *testing.T) {
	m := New(session(3), "")
	m = update(m, "f")
	if m.state != stateResults {
		t.Errorf("state = %v, want stateResults after f", m.state)
	}
}

func TestUpdate_NavigateForwardBack(t *testing.T) {
	m := New(session(3), "")
	m = update(m, "right")
	if m.current != 1 {
		t.Errorf("current = %d, want 1 after right", m.current)
	}
	m = update(m, "left")
	if m.current != 0 {
		t.Errorf("current = %d, want 0 after left", m.current)
	}
}

func TestUpdate_NavigationWraps(t *testing.T) {
	m := New(session(3), "")
	m = update(m, "left")
	if m.current != 2 {
		t.Errorf("wrap left: current = %d, want 2", m.current)
	}
	m = update(m, "right")
	if m.current != 0 {
		t.Errorf("wrap right: current = %d, want 0", m.current)
	}
}

func TestUpdate_NavigationResetsState(t *testing.T) {
	m := New(session(2), "")
	m = update(m, "space") // reveal card 0
	if m.state != stateRevealed {
		t.Fatalf("state = %v, want stateRevealed", m.state)
	}
	m = update(m, "right") // navigate away
	if m.state != stateQuestion {
		t.Errorf("state = %v, want stateQuestion after navigating", m.state)
	}
}

func TestUpdate_ExplainToggle(t *testing.T) {
	m := New(session(1), "")
	m = update(m, "space") // reveal
	if m.showExplain {
		t.Error("showExplain should start false")
	}
	m = update(m, "e")
	if !m.showExplain {
		t.Error("showExplain should be true after e")
	}
	m = update(m, "e")
	if m.showExplain {
		t.Error("showExplain should be false after second e")
	}
}

func TestUpdate_ExplainClearedOnNavigate(t *testing.T) {
	m := New(session(2), "")
	m = update(m, "space")
	m = update(m, "e")
	m = update(m, "right")
	if m.showExplain {
		t.Error("showExplain should be cleared after navigation")
	}
}

func TestUpdate_Retake(t *testing.T) {
	m := New(session(2), "")
	m = update(m, "space")
	m = update(m, "c")
	m = update(m, "f") // → results
	m = update(m, "r") // retake -> confirmation prompt
	if m.state != stateConfirmRetake {
		t.Fatalf("state = %v, want stateConfirmRetake after pressing r", m.state)
	}
	m = update(m, "y") // confirm
	if m.state != stateQuestion {
		t.Errorf("state = %v, want stateQuestion after confirmed retake", m.state)
	}
	if m.current != 0 {
		t.Errorf("current = %d, want 0 after retake", m.current)
	}
	if m.right != 0 || m.wrong != 0 {
		t.Errorf("right=%d wrong=%d, want 0 0 after retake", m.right, m.wrong)
	}
	if len(m.answers) != 0 {
		t.Errorf("answers not cleared after retake")
	}
	if len(m.deck) != 2 {
		t.Errorf("deck length = %d, want 2 after retake", len(m.deck))
	}
}

func TestUpdate_RetakeCancel(t *testing.T) {
	m := New(session(2), "")
	m = update(m, "space")
	m = update(m, "c")
	m = update(m, "f") // → results
	m = update(m, "r") // retake -> confirmation prompt
	for _, k := range []string{"n", "esc"} {
		next := update(m, k)
		if next.state != stateResults {
			t.Errorf("key %q: state = %v, want stateResults after cancel", k, next.state)
		}
		if next.right != m.right || next.wrong != m.wrong {
			t.Errorf("key %q: cancel should leave state untouched", k)
		}
	}
}

func TestUpdate_ResultsPageToggle(t *testing.T) {
	m := New(session(2), "")
	m = update(m, "space")
	m = update(m, "x") // mark wrong
	m = update(m, "space")
	m = update(m, "c") // mark correct, → results
	if m.state != stateResults {
		t.Fatalf("state = %v, want stateResults", m.state)
	}
	if m.resultsPage != resultsPageStats {
		t.Fatalf("resultsPage = %v, want resultsPageStats initially", m.resultsPage)
	}
	m = update(m, "tab")
	if m.resultsPage != resultsPageMissed {
		t.Errorf("resultsPage = %v, want resultsPageMissed after tab", m.resultsPage)
	}
	view := m.View()
	if !strings.Contains(view, "Cards to review") {
		t.Errorf("missed-cards view missing expected heading: %q", view)
	}
	m = update(m, "tab")
	if m.resultsPage != resultsPageStats {
		t.Errorf("resultsPage = %v, want resultsPageStats after second tab", m.resultsPage)
	}
}

func TestTruncate52(t *testing.T) {
	exact := strings.Repeat("a", 52)
	if got := truncate52(exact); got != exact {
		t.Errorf("truncate52(52-char) = %q, want unchanged", got)
	}

	over := strings.Repeat("a", 53)
	want := strings.Repeat("a", 52) + " [...]"
	if got := truncate52(over); got != want {
		t.Errorf("truncate52(53-char) = %q, want %q", got, want)
	}

	unicodeStr := strings.Repeat("é", 53)
	gotUnicode := truncate52(unicodeStr)
	wantUnicode := strings.Repeat("é", 52) + " [...]"
	if gotUnicode != wantUnicode {
		t.Errorf("truncate52(unicode) = %q, want %q", gotUnicode, wantUnicode)
	}
}

func TestBuildWeightedDeckEmptyMissed(t *testing.T) {
	base := []int{1, 2, 3, 4}
	rng := rand.New(rand.NewSource(1))
	got := buildWeightedDeck(base, nil, rng)
	if len(got) != len(base) {
		t.Fatalf("len(got) = %d, want %d", len(got), len(base))
	}
	for i := range base {
		if got[i] != base[i] {
			t.Errorf("got[%d] = %d, want %d (should pass through unchanged)", i, got[i], base[i])
		}
	}
}

func TestBuildWeightedDeckNoImmediateRepeat(t *testing.T) {
	base := []int{1, 2, 3, 4, 5}
	missed := []int{1, 2, 3, 4, 5}
	for seed := int64(0); seed < 200; seed++ {
		rng := rand.New(rand.NewSource(seed))
		deck := buildWeightedDeck(base, missed, rng)
		for i := 1; i < len(deck); i++ {
			if deck[i] == deck[i-1] {
				t.Fatalf("seed %d: deck has immediate repeat at index %d: %v", seed, i, deck)
			}
		}
	}
}

func TestBuildWeightedDeckSingleCard(t *testing.T) {
	base := []int{1}
	missed := []int{1}
	rng := rand.New(rand.NewSource(1))
	got := buildWeightedDeck(base, missed, rng)
	if len(got) != 1 || got[0] != 1 {
		t.Errorf("buildWeightedDeck(single card) = %v, want [1]", got)
	}
}

func TestBuildWeightedDeckInjectionRateRoughlyOneThird(t *testing.T) {
	base := make([]int, 100)
	for i := range base {
		base[i] = i
	}
	missed := []int{9000, 9001, 9002} // IDs disjoint from base, easy to detect injections
	rng := rand.New(rand.NewSource(42))
	deck := buildWeightedDeck(base, missed, rng)

	injected := 0
	for _, id := range deck {
		for _, m := range missed {
			if id == m {
				injected++
			}
		}
	}
	frac := float64(injected) / float64(len(deck))
	if frac < 0.15 || frac > 0.45 {
		t.Errorf("injection rate = %.2f, want roughly 1/3 (loose bound 0.15-0.45)", frac)
	}
}

func TestProgressResume(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "session.json")

	m := New(session(4), path)
	m = update(m, "space")
	m = update(m, "c") // card 1 correct
	m = update(m, "space")
	m = update(m, "x") // card 2 wrong
	m = update(m, "q") // quit -> saves progress

	m2 := New(session(4), path)
	if len(m2.deck) != 2 {
		t.Fatalf("resumed deck length = %d, want 2 (2 of 4 cards already seen)", len(m2.deck))
	}
	if m2.priorRight != 1 || m2.priorWrong != 1 {
		t.Errorf("priorRight=%d priorWrong=%d, want 1 1", m2.priorRight, m2.priorWrong)
	}

	// Finish the resumed deck and confirm combined stats show in results.
	m2 = update(m2, "space")
	m2 = update(m2, "c")
	m2 = update(m2, "space")
	m2 = update(m2, "c")
	if m2.state != stateResults {
		t.Fatalf("state = %v, want stateResults after finishing resumed deck", m2.state)
	}
	view := m2.View()
	if !strings.Contains(view, "3/4") {
		t.Errorf("results view missing combined score 3/4: %q", view)
	}
}

func TestProgressResumeAllSeenFallsBackToFreshPass(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "session.json")

	m := New(session(2), path)
	m = update(m, "space")
	m = update(m, "c")
	m = update(m, "space")
	m = update(m, "c") // → results, saves progress with both cards seen

	m2 := New(session(2), path)
	if len(m2.deck) != 2 {
		t.Errorf("deck length = %d, want 2 (fresh full pass, not empty)", len(m2.deck))
	}
	if m2.priorRight != 0 || m2.priorWrong != 0 {
		t.Errorf("priorRight=%d priorWrong=%d, want 0 0 for a fresh fallback pass", m2.priorRight, m2.priorWrong)
	}
}

func TestSepW(t *testing.T) {
	cases := []struct{ width, want int }{
		{0, 56},
		{40, 40},
		{80, 72},
		{72, 72},
	}
	for _, tc := range cases {
		m := Model{width: tc.width}
		if got := m.sepW(); got != tc.want {
			t.Errorf("width=%d: sepW()=%d, want %d", tc.width, got, tc.want)
		}
	}
}

func TestNavBar_DoesNotPanic(t *testing.T) {
	m := New(session(2), "")
	got := m.navBar()
	if !strings.Contains(got, "←") || !strings.Contains(got, "→") {
		t.Errorf("navBar missing arrows: %q", got)
	}
}

func TestView_DoesNotPanic(t *testing.T) {
	m := New(session(2), "")
	_ = m.View() // stateQuestion

	m = update(m, "space")
	_ = m.View() // stateRevealed

	m = update(m, "f")
	_ = m.View() // stateResults
}

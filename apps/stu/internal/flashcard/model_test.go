package flashcard

import (
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/ivorscott/stu/internal/types"
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
	m := New(session(3))
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
	m := New(session(1))
	next, _ := m.Update(tea.WindowSizeMsg{Width: 80, Height: 24})
	m = next.(Model)
	if m.width != 80 || m.height != 24 {
		t.Errorf("width=%d height=%d, want 80 24", m.width, m.height)
	}
}

func TestUpdate_Reveal(t *testing.T) {
	for _, k := range []string{"space", "enter"} {
		m := New(session(1))
		m = update(m, k)
		if m.state != stateRevealed {
			t.Errorf("key %q: state = %v, want stateRevealed", k, m.state)
		}
	}
}

func TestUpdate_MarkCorrect(t *testing.T) {
	for _, k := range []string{"c", "enter"} {
		m := New(session(2))
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
	m := New(session(2))
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
	m := New(session(2))
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
	m := New(session(2))
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
	m := New(session(2))
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
	m := New(session(2))
	m = update(m, "space")
	m = update(m, "c") // card 0 correct, advance
	m = update(m, "space")
	m = update(m, "c") // card 1 correct, all answered → results
	if m.state != stateResults {
		t.Errorf("state = %v, want stateResults after all cards answered", m.state)
	}
}

func TestUpdate_Finish(t *testing.T) {
	m := New(session(3))
	m = update(m, "f")
	if m.state != stateResults {
		t.Errorf("state = %v, want stateResults after f", m.state)
	}
}

func TestUpdate_NavigateForwardBack(t *testing.T) {
	m := New(session(3))
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
	m := New(session(3))
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
	m := New(session(2))
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
	m := New(session(1))
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
	m := New(session(2))
	m = update(m, "space")
	m = update(m, "e")
	m = update(m, "right")
	if m.showExplain {
		t.Error("showExplain should be cleared after navigation")
	}
}

func TestUpdate_Retake(t *testing.T) {
	m := New(session(2))
	m = update(m, "space")
	m = update(m, "c")
	m = update(m, "f") // → results
	m = update(m, "r") // retake
	if m.state != stateQuestion {
		t.Errorf("state = %v, want stateQuestion after retake", m.state)
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
	m := New(session(2))
	got := m.navBar()
	if !strings.Contains(got, "←") || !strings.Contains(got, "→") {
		t.Errorf("navBar missing arrows: %q", got)
	}
}

func TestView_DoesNotPanic(t *testing.T) {
	m := New(session(2))
	_ = m.View() // stateQuestion

	m = update(m, "space")
	_ = m.View() // stateRevealed

	m = update(m, "f")
	_ = m.View() // stateResults
}

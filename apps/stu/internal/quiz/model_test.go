package quiz

import (
	"testing"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/ivorscott/cc-marketplace/apps/stu/internal/types"
)

// session builds a quiz session with n questions, each with correct answer at index 0.
func session(n int) *types.Session {
	qs := make([]types.Question, n)
	for i := range qs {
		qs[i] = types.Question{
			ID:           i + 1,
			Question:     "Q?",
			Options:      []string{"Right", "Wrong", "Wrong", "Wrong"},
			Correct:      0,
			Hint:         "hint",
			Explanations: []string{"yes", "no", "no", "no"},
		}
	}
	return &types.Session{Type: types.TypeQuiz, Title: "T", Questions: qs}
}

func key(k string) tea.KeyMsg {
	switch k {
	case "enter":
		return tea.KeyMsg{Type: tea.KeyEnter}
	case "up":
		return tea.KeyMsg{Type: tea.KeyUp}
	case "down":
		return tea.KeyMsg{Type: tea.KeyDown}
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
	if m.selected != -1 {
		t.Errorf("selected = %d, want -1", m.selected)
	}
	if m.state != stateQuestion {
		t.Errorf("state = %v, want stateQuestion", m.state)
	}
}

func TestUpdate_WindowSize(t *testing.T) {
	m := New(session(1))
	next, _ := m.Update(tea.WindowSizeMsg{Width: 100, Height: 40})
	m = next.(Model)
	if m.width != 100 || m.height != 40 {
		t.Errorf("width=%d height=%d, want 100 40", m.width, m.height)
	}
}

func TestUpdate_SelectWithLetters(t *testing.T) {
	for _, tc := range []struct {
		key  string
		want int
	}{
		{"a", 0}, {"b", 1}, {"c", 2}, {"d", 3},
	} {
		m := New(session(1))
		m = update(m, tc.key)
		if m.selected != tc.want {
			t.Errorf("key %q: selected = %d, want %d", tc.key, m.selected, tc.want)
		}
	}
}

func TestUpdate_NavigateUpDown(t *testing.T) {
	m := New(session(1))
	m = update(m, "down")
	if m.selected != 0 {
		t.Errorf("after down from -1: selected = %d, want 0", m.selected)
	}
	m = update(m, "down")
	if m.selected != 1 {
		t.Errorf("after second down: selected = %d, want 1", m.selected)
	}
	m = update(m, "up")
	if m.selected != 0 {
		t.Errorf("after up: selected = %d, want 0", m.selected)
	}
}

func TestUpdate_NavigationWraps(t *testing.T) {
	m := New(session(1)) // 4 options
	m.selected = 3
	m = update(m, "down") // wrap to 0
	if m.selected != 0 {
		t.Errorf("wrap down: selected = %d, want 0", m.selected)
	}
	m.selected = 0
	m = update(m, "up") // wrap to 3
	if m.selected != 3 {
		t.Errorf("wrap up: selected = %d, want 3", m.selected)
	}
}

func TestUpdate_SubmitAnswer_Correct(t *testing.T) {
	m := New(session(1))
	m = update(m, "a") // select correct (index 0)
	m = update(m, "enter")
	if m.state != stateAnswered {
		t.Errorf("state = %v, want stateAnswered", m.state)
	}
	if len(m.results) != 1 || !m.results[0] {
		t.Errorf("results[0] = %v, want true", m.results)
	}
}

func TestUpdate_SubmitAnswer_Wrong(t *testing.T) {
	m := New(session(1))
	m = update(m, "b") // select wrong (index 1)
	m = update(m, "enter")
	if m.state != stateAnswered {
		t.Errorf("state = %v, want stateAnswered", m.state)
	}
	if len(m.results) != 1 || m.results[0] {
		t.Errorf("results[0] = %v, want false", m.results)
	}
}

func TestUpdate_SubmitWithoutSelection(t *testing.T) {
	m := New(session(1))
	m = update(m, "enter")
	if m.state != stateQuestion {
		t.Errorf("state = %v, want stateQuestion (no selection)", m.state)
	}
}

func TestUpdate_HintToggle(t *testing.T) {
	m := New(session(1))
	if m.showHint {
		t.Error("showHint should start false")
	}
	m = update(m, "h")
	if !m.showHint {
		t.Error("showHint should be true after h")
	}
	m = update(m, "h")
	if m.showHint {
		t.Error("showHint should be false after second h")
	}
}

func TestUpdate_HintClearedOnSubmit(t *testing.T) {
	m := New(session(2))
	m = update(m, "h")
	m = update(m, "a")
	m = update(m, "enter")
	if m.showHint {
		t.Error("showHint should be cleared after submitting")
	}
}

func TestUpdate_StateTransition_ToResults(t *testing.T) {
	m := New(session(2))
	m = update(m, "a")
	m = update(m, "enter")
	m = update(m, "enter") // next
	if m.state != stateQuestion || m.current != 1 {
		t.Errorf("state=%v current=%d, want stateQuestion 1", m.state, m.current)
	}
	m = update(m, "a")
	m = update(m, "enter")
	m = update(m, "enter") // next → results
	if m.state != stateResults {
		t.Errorf("state = %v, want stateResults", m.state)
	}
}

func TestUpdate_Retake(t *testing.T) {
	m := New(session(1))
	m = update(m, "a")
	m = update(m, "enter")
	m = update(m, "enter") // → results
	if m.state != stateResults {
		t.Fatalf("expected stateResults, got %v", m.state)
	}
	m = update(m, "r")
	if m.state != stateQuestion {
		t.Errorf("state = %v, want stateQuestion after retake", m.state)
	}
	if m.current != 0 {
		t.Errorf("current = %d, want 0 after retake", m.current)
	}
	if m.selected != -1 {
		t.Errorf("selected = %d, want -1 after retake", m.selected)
	}
	if len(m.results) != 0 {
		t.Errorf("results not cleared after retake")
	}
}

func TestUpdate_NextKeysInAnswered(t *testing.T) {
	for _, k := range []string{"enter", "right", "l", "n"} {
		m := New(session(2))
		m = update(m, "a")
		m = update(m, "enter") // → answered
		m = update(m, k)       // → next question
		if m.state != stateQuestion {
			t.Errorf("key %q: state = %v, want stateQuestion", k, m.state)
		}
		if m.current != 1 {
			t.Errorf("key %q: current = %d, want 1", k, m.current)
		}
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

func TestView_DoesNotPanic(t *testing.T) {
	m := New(session(2))
	_ = m.View() // stateQuestion

	m = update(m, "a")
	m = update(m, "enter")
	_ = m.View() // stateAnswered

	m = update(m, "enter") // next
	m = update(m, "a")
	m = update(m, "enter")
	m = update(m, "enter") // → results
	_ = m.View()           // stateResults
}

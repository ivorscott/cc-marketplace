package render

import (
	"strings"
	"testing"
	"time"

	"github.com/charmbracelet/lipgloss"
)

var (
	filledStyle = lipgloss.NewStyle().Foreground(lipgloss.Color("79"))
	emptyStyle  = lipgloss.NewStyle().Foreground(lipgloss.Color("238"))
)

func TestBlockBar_Empty(t *testing.T) {
	got := BlockBar(0, 10, 5, filledStyle, emptyStyle)
	if !strings.Contains(got, "░") {
		t.Errorf("BlockBar(0,10,5): expected empty chars, got %q", got)
	}
}

func TestBlockBar_Full(t *testing.T) {
	got := BlockBar(10, 10, 5, filledStyle, emptyStyle)
	if !strings.Contains(got, "█") {
		t.Errorf("BlockBar(10,10,5): expected filled chars, got %q", got)
	}
}

func TestBlockBar_ZeroTotal(t *testing.T) {
	got := BlockBar(0, 0, 5, filledStyle, emptyStyle)
	if got == "" {
		t.Error("BlockBar(0,0,5): got empty string")
	}
}

func TestLetterGrade(t *testing.T) {
	cases := []struct {
		pct  int
		want string
	}{
		{95, "A"}, {90, "A"},
		{85, "B"}, {80, "B"},
		{75, "C"}, {70, "C"},
		{65, "D"}, {60, "D"},
		{59, "F"}, {0, "F"},
	}
	for _, tc := range cases {
		if got := LetterGrade(tc.pct); got != tc.want {
			t.Errorf("LetterGrade(%d) = %q, want %q", tc.pct, got, tc.want)
		}
	}
}

func TestFormatElapsed(t *testing.T) {
	cases := []struct {
		d    time.Duration
		want string
	}{
		{30 * time.Second, "30 sec"},
		{59 * time.Second, "59 sec"},
		{60 * time.Second, "1m 0s"},
		{90 * time.Second, "1m 30s"},
		{125 * time.Second, "2m 5s"},
	}
	for _, tc := range cases {
		if got := FormatElapsed(tc.d); got != tc.want {
			t.Errorf("FormatElapsed(%v) = %q, want %q", tc.d, got, tc.want)
		}
	}
}

func TestFormatSource(t *testing.T) {
	cases := []struct{ in, want string }{
		{"1-introduction.md", "Introduction"},
		{"kafka-topics.md", "Kafka Topics"},
		{"plain.md", "Plain"},
		{"02-deep-dive.md", "Deep Dive"},
	}
	for _, tc := range cases {
		if got := FormatSource(tc.in); got != tc.want {
			t.Errorf("FormatSource(%q) = %q, want %q", tc.in, got, tc.want)
		}
	}
}

func TestSourcesLabel(t *testing.T) {
	if got := SourcesLabel(1); got != "1 source" {
		t.Errorf("SourcesLabel(1) = %q, want %q", got, "1 source")
	}
	if got := SourcesLabel(5); got != "5 sources" {
		t.Errorf("SourcesLabel(5) = %q, want %q", got, "5 sources")
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
		if got := SepW(tc.width); got != tc.want {
			t.Errorf("SepW(%d) = %d, want %d", tc.width, got, tc.want)
		}
	}
}

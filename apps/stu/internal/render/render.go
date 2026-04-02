package render

import (
	"fmt"
	"path/filepath"
	"strings"
	"time"

	"github.com/charmbracelet/lipgloss"
)

// BlockBar renders a block-character progress bar using █ (filled) and ░ (empty).
func BlockBar(n, total, width int, filledStyle, emptyStyle lipgloss.Style) string {
	if total == 0 || width == 0 {
		return emptyStyle.Render(strings.Repeat("░", width))
	}
	filled := n * width / total
	if filled < 0 {
		filled = 0
	}
	if filled > width {
		filled = width
	}
	return filledStyle.Render(strings.Repeat("█", filled)) +
		emptyStyle.Render(strings.Repeat("░", width-filled))
}

// LetterGrade converts a percentage score to a letter grade.
func LetterGrade(pct int) string {
	switch {
	case pct >= 90:
		return "A"
	case pct >= 80:
		return "B"
	case pct >= 70:
		return "C"
	case pct >= 60:
		return "D"
	default:
		return "F"
	}
}

// FormatElapsed formats a duration as "Xs" or "Xm Ys".
func FormatElapsed(d time.Duration) string {
	s := int(d.Seconds())
	if s < 60 {
		return fmt.Sprintf("%d sec", s)
	}
	return fmt.Sprintf("%dm %ds", s/60, s%60)
}

// FormatSource prettifies a markdown filename: strips numberic prefix and capitalizes words.
func FormatSource(s string) string {
	base := strings.TrimSuffix(filepath.Base(s), ".md")
	base = strings.ReplaceAll(base, "-", " ")
	if len(base) > 0 && base[0] >= '0' && base[0] <= '9' {
		if idx := strings.Index(base, " "); idx >= 0 {
			base = strings.TrimSpace(base[idx+1:])
		}
	}
	words := strings.Fields(base)
	for i, w := range words {
		if len(w) > 0 {
			words[i] = strings.ToUpper(w[:1]) + w[1:]
		}
	}
	return strings.Join(words, " ")
}

// SourcesLabel returns "1 source" or "N sources".
func SourcesLabel(n int) string {
	if n == 1 {
		return "1 source"
	}
	return fmt.Sprintf("%d sources", n)
}

// SepW clamps a terminal width to the layout range [56, 72].
func SepW(width int) int {
	if width <= 0 {
		return 56
	}
	if width > 72 {
		return 72
	}
	return width
}

package anki

import (
	"regexp"
	"strings"

	"golang.org/x/net/html"
)

var reBR = regexp.MustCompile(`(?i)<br\s*/?>`)

// BRToNewline replaces <br>, <br/>, <BR />, etc. with a newline character.
// Call this before StripHTML so line breaks survive tag removal.
func BRToNewline(s string) string {
	return reBR.ReplaceAllString(s, "\n")
}

// StripHTML removes all HTML tags from s, returning plain text.
func StripHTML(s string) string {
	tokenizer := html.NewTokenizer(strings.NewReader(s))
	var b strings.Builder
	for {
		tt := tokenizer.Next()
		if tt == html.ErrorToken {
			break
		}
		if tt == html.TextToken {
			b.Write(tokenizer.Text())
		}
	}
	return b.String()
}

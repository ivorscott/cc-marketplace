package anki

import (
	"strings"
	"unicode"
)

// Slugify converts a human-readable title to a lowercase, hyphen-separated slug
// suitable for use as a filename. e.g. "My Kafka Topic!" → "my-kafka-topic"
func Slugify(s string) string {
	var b strings.Builder
	prevHyphen := true // avoid leading hyphen
	for _, r := range strings.ToLower(s) {
		if unicode.IsLetter(r) || unicode.IsDigit(r) {
			b.WriteRune(r)
			prevHyphen = false
		} else {
			if !prevHyphen {
				b.WriteByte('-')
				prevHyphen = true
			}
		}
	}
	result := b.String()
	return strings.TrimRight(result, "-")
}

// Deslugify converts a slug back to a title-cased string.
// e.g. "my-kafka-topic" → "My Kafka Topic"
func Deslugify(s string) string {
	words := strings.Split(s, "-")
	for i, w := range words {
		if len(w) == 0 {
			continue
		}
		runes := []rune(w)
		runes[0] = unicode.ToUpper(runes[0])
		words[i] = string(runes)
	}
	return strings.Join(words, " ")
}

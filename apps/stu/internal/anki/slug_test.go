package anki

import "testing"

func TestSlugify(t *testing.T) {
	cases := []struct {
		in   string
		want string
	}{
		{"My Kafka Topic", "my-kafka-topic"},
		{"Go Basics!", "go-basics"},
		{"already-slugged", "already-slugged"},
		{"Mixed_Case And Spaces", "mixed-case-and-spaces"},
		{"  leading spaces", "leading-spaces"},
		{"trailing spaces  ", "trailing-spaces"},
		{"multiple   spaces", "multiple-spaces"},
		{"Special #@! Chars", "special-chars"},
		{"single", "single"},
		{"123 Numbers", "123-numbers"},
		{"", ""},
	}
	for _, c := range cases {
		got := Slugify(c.in)
		if got != c.want {
			t.Errorf("Slugify(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}

func TestDeslugify(t *testing.T) {
	cases := []struct {
		in   string
		want string
	}{
		{"my-kafka-topic", "My Kafka Topic"},
		{"go-basics", "Go Basics"},
		{"single", "Single"},
		{"already title", "Already title"},
		{"", ""},
	}
	for _, c := range cases {
		got := Deslugify(c.in)
		if got != c.want {
			t.Errorf("Deslugify(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}

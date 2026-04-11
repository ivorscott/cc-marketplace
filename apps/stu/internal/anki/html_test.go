package anki

import "testing"

func TestStripHTML(t *testing.T) {
	cases := []struct {
		in   string
		want string
	}{
		{"plain text", "plain text"},
		{"<b>bold</b>", "bold"},
		{"<p>Hello <b>world</b></p>", "Hello world"},
		{"<img src=\"x.png\">caption", "caption"},
		{"no tags here", "no tags here"},
		{"<br>line2", "line2"},
		{"nested <span><b>deep</b></span> end", "nested deep end"},
		{"malformed <b unclosed", "malformed "},
		{"", ""},
	}
	for _, c := range cases {
		got := StripHTML(c.in)
		if got != c.want {
			t.Errorf("StripHTML(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}

func TestBRToNewline(t *testing.T) {
	cases := []struct {
		in   string
		want string
	}{
		{"line1<br>line2", "line1\nline2"},
		{"line1<br/>line2", "line1\nline2"},
		{"line1<br />line2", "line1\nline2"},
		{"line1<BR>line2", "line1\nline2"},
		{"line1<BR />line2", "line1\nline2"},
		{"no breaks here", "no breaks here"},
		{"a<br>b<br>c", "a\nb\nc"},
		{"", ""},
	}
	for _, c := range cases {
		got := BRToNewline(c.in)
		if got != c.want {
			t.Errorf("BRToNewline(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}

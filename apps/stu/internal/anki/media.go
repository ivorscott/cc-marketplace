package anki

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"

	"github.com/ivorscott/stu/internal/types"
)

var (
	reImgSrc = regexp.MustCompile(`(?i)<img\s+[^>]*src="([^"]+)"`)
	reSound  = regexp.MustCompile(`\[sound:([^\]]+)\]`)
)

// MediaRef represents a media file referenced in card HTML.
type MediaRef struct {
	Original string // filename as it appears in the card HTML
	AbsPath  string // resolved absolute path on disk
	Missing  bool   // true if file not found on disk
}

// ScanMedia scans all card fields for media references and resolves them
// relative to sessionDir. Duplicates (by Original name) are collapsed.
func ScanMedia(cards []types.Card, sessionDir string) []MediaRef {
	seen := map[string]bool{}
	var refs []MediaRef

	for _, card := range cards {
		for _, field := range []string{card.Front, card.Back, card.Explanation} {
			for _, m := range reImgSrc.FindAllStringSubmatch(field, -1) {
				name := m[1]
				if seen[name] {
					continue
				}
				seen[name] = true
				abs := filepath.Join(sessionDir, name)
				_, err := os.Stat(abs)
				refs = append(refs, MediaRef{
					Original: name,
					AbsPath:  abs,
					Missing:  err != nil,
				})
			}
			for _, m := range reSound.FindAllStringSubmatch(field, -1) {
				name := m[1]
				if seen[name] {
					continue
				}
				seen[name] = true
				abs := filepath.Join(sessionDir, name)
				_, err := os.Stat(abs)
				refs = append(refs, MediaRef{
					Original: name,
					AbsPath:  abs,
					Missing:  err != nil,
				})
			}
		}
	}
	return refs
}

// BuildManifest constructs the Anki media manifest: a JSON-serializable map
// from numeric string index ("0", "1", ...) to the original filename.
// Only non-missing refs are included.
func BuildManifest(refs []MediaRef) map[string]string {
	m := map[string]string{}
	i := 0
	for _, ref := range refs {
		if ref.Missing {
			continue
		}
		m[fmt.Sprintf("%d", i)] = ref.Original
		i++
	}
	return m
}

package anki

import (
	"crypto/rand"
	"crypto/sha1"
	"database/sql"
	"encoding/binary"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"time"

	_ "github.com/mattn/go-sqlite3"
)

const (
	sqlCreateCol = `CREATE TABLE col (
		id    integer PRIMARY KEY,
		crt   integer NOT NULL,
		mod   integer NOT NULL,
		scm   integer NOT NULL,
		ver   integer NOT NULL,
		dty   integer NOT NULL,
		usn   integer NOT NULL,
		ls    integer NOT NULL,
		conf  text    NOT NULL,
		models text   NOT NULL,
		decks  text   NOT NULL,
		dconf  text   NOT NULL,
		tags   text   NOT NULL
	)`

	sqlCreateNotes = `CREATE TABLE notes (
		id    integer PRIMARY KEY,
		guid  text    NOT NULL,
		mid   integer NOT NULL,
		mod   integer NOT NULL,
		usn   integer NOT NULL,
		tags  text    NOT NULL,
		flds  text    NOT NULL,
		sfld  text    NOT NULL,
		csum  integer NOT NULL,
		flags integer NOT NULL,
		data  text    NOT NULL
	)`

	sqlCreateCards = `CREATE TABLE cards (
		id     integer PRIMARY KEY,
		nid    integer NOT NULL,
		did    integer NOT NULL,
		ord    integer NOT NULL,
		mod    integer NOT NULL,
		usn    integer NOT NULL,
		type   integer NOT NULL,
		queue  integer NOT NULL,
		due    integer NOT NULL,
		ivl    integer NOT NULL,
		factor integer NOT NULL,
		reps   integer NOT NULL,
		lapses integer NOT NULL,
		left   integer NOT NULL,
		odue   integer NOT NULL,
		odid   integer NOT NULL,
		flags  integer NOT NULL,
		data   text    NOT NULL
	)`

	sqlCreateGraves = `CREATE TABLE graves (
		usn  integer NOT NULL,
		oid  integer NOT NULL,
		type integer NOT NULL
	)`

	sqlCreateRevlog = `CREATE TABLE revlog (
		id      integer PRIMARY KEY,
		cid     integer NOT NULL,
		usn     integer NOT NULL,
		ease    integer NOT NULL,
		ivl     integer NOT NULL,
		lastIvl integer NOT NULL,
		factor  integer NOT NULL,
		time    integer NOT NULL,
		type    integer NOT NULL
	)`

	// ModelID is a fixed constant used as the Anki note type ID.
	ModelID int64 = 1700000000000
)

// initSchema creates all required Anki SQLite tables in db.
func initSchema(db *sql.DB) error {
	for _, ddl := range []string{
		sqlCreateCol,
		sqlCreateNotes,
		sqlCreateCards,
		sqlCreateGraves,
		sqlCreateRevlog,
	} {
		if _, err := db.Exec(ddl); err != nil {
			return fmt.Errorf("initSchema: %w", err)
		}
	}
	return nil
}

// colJSON builds the five JSON blob columns for the col table.
// deckID must be a non-zero epoch-millisecond value so Anki does not treat it
// as the built-in "Default" deck (which has the reserved ID 1).
func colJSON(title string, deckID int64) (conf, models, decks, dconf, tags string, err error) {
	now := time.Now().Unix()

	// conf
	confMap := map[string]any{
		"activeDecks":    []int64{deckID},
		"curDeck":        deckID,
		"newSpread":      0,
		"collapseTime":   1200,
		"timeLim":        0,
		"estTimes":       true,
		"dueCounts":      true,
		"curModel":       fmt.Sprintf("%d", ModelID),
		"nextPos":        1,
		"sortType":       "noteFld",
		"sortBackwards":  false,
		"addToCur":       true,
		"dayLearnFirst":  false,
		"schedVer":       2,
	}
	b, err := json.Marshal(confMap)
	if err != nil {
		return
	}
	conf = string(b)

	// models
	modelsMap := map[string]any{
		fmt.Sprintf("%d", ModelID): map[string]any{
			"id":   ModelID,
			"name": "Basic",
			"type": 0,
			"mod":  now,
			"usn":  -1,
			"sortf": 0,
			"did":  deckID,
			"tmpls": []map[string]any{
				{
					"name":  "Card 1",
					"ord":   0,
					"qfmt":  "{{Front}}",
					"afmt":  "{{FrontSide}}\n\n<hr id=answer>\n\n{{Back}}",
					"bqfmt": "",
					"bafmt": "",
					"did":   nil,
					"bfont": "",
					"bsize": 0,
				},
			},
			"flds": []map[string]any{
				{"name": "Front", "ord": 0, "sticky": false, "rtl": false, "font": "Arial", "size": 20, "media": []any{}},
				{"name": "Back", "ord": 1, "sticky": false, "rtl": false, "font": "Arial", "size": 20, "media": []any{}},
			},
			"css":       ".card { font-family: arial; font-size: 20px; text-align: center; color: black; background-color: white; }",
			"latexPre":  "\\documentclass[12pt]{article}\n\\special{papersize=3in,5in}\n\\usepackage{amssymb,amsmath}\n\\pagestyle{empty}\n\\setlength{\\parindent}{0in}\n\\begin{document}\n",
			"latexPost": "\\end{document}",
			"req":       []any{[]any{0, "any", []int{0}}},
		},
	}
	b, err = json.Marshal(modelsMap)
	if err != nil {
		return
	}
	models = string(b)

	// decks
	decksMap := map[string]any{
		fmt.Sprintf("%d", deckID): map[string]any{
			"id":         deckID,
			"name":       title,
			"conf":       deckID,
			"extendNew":  0,
			"extendRev":  50,
			"collapsed":  false,
			"desc":       "",
			"dyn":        0,
			"usn":        -1,
			"lrnToday":   []int{0, 0},
			"revToday":   []int{0, 0},
			"newToday":   []int{0, 0},
			"timeToday":  []int{0, 0},
			"mod":        now,
		},
	}
	b, err = json.Marshal(decksMap)
	if err != nil {
		return
	}
	decks = string(b)

	// dconf
	dconfMap := map[string]any{
		fmt.Sprintf("%d", deckID): map[string]any{
			"id":      deckID,
			"name":    "Default",
			"replayq": true,
			"lapse": map[string]any{
				"leechFails":  8,
				"minInt":      1,
				"delays":      []int{10},
				"leechAction": 0,
				"mult":        0,
			},
			"rev": map[string]any{
				"perDay": 200,
				"fuzz":   0.05,
				"ivlFct": 1,
				"maxIvl": 36500,
				"ease4":  1.3,
				"bury":   false,
				"minSpace": 1,
			},
			"timer":    0,
			"maxTaken": 60,
			"usn":      0,
			"new": map[string]any{
				"perDay":        20,
				"delays":        []int{1, 10},
				"separate":      true,
				"ints":          []int{1, 4, 7},
				"initialFactor": 2500,
				"bury":          false,
				"order":         1,
			},
			"mod":      now,
			"autoplay": true,
		},
	}
	b, err = json.Marshal(dconfMap)
	if err != nil {
		return
	}
	dconf = string(b)

	tags = "{}"
	return
}

// computeCSUM computes the Anki note checksum: first 4 bytes of SHA-1(sfld) as big-endian uint32.
func computeCSUM(sfld string) int64 {
	h := sha1.Sum([]byte(sfld))
	return int64(binary.BigEndian.Uint32(h[:4]))
}

// randomGUID returns a 10-character random base64url string suitable for use as an Anki note GUID.
func randomGUID() string {
	b := make([]byte, 8)
	_, _ = rand.Read(b)
	return base64.RawURLEncoding.EncodeToString(b)[:10]
}

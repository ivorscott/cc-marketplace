package types

import "time"

type StudyType string

const (
	TypeQuiz      StudyType = "quiz"
	TypeFlashcard StudyType = "flashcards"
)

// Session is the top-level envelope for both quiz and flashcard JSON files.
type Session struct {
	Type       StudyType  `json:"type"`
	Title      string     `json:"title"`
	Difficulty string     `json:"difficulty"`
	Sources    []string   `json:"sources"`
	CreatedAt  time.Time  `json:"created_at"`
	Questions  []Question `json:"questions,omitempty"`
	Cards      []Card     `json:"cards,omitempty"`
}

// Question represents a single multiple-choice quiz question.
type Question struct {
	ID           int      `json:"id"`
	Question     string   `json:"question"`
	Options      []string `json:"options"`
	Correct      int      `json:"correct"` // 0-based index
	Hint         string   `json:"hint"`
	Explanations []string `json:"explanations"`
}

// Card represents a single flashcard (front/back pair).
type Card struct {
	ID          int    `json:"id"`
	Front       string `json:"front"`
	Back        string `json:"back"`
	Explanation string `json:"explanation,omitempty"`
}

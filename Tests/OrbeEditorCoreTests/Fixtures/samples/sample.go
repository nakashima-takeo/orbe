package main

import "fmt"

// LineIndex holds line start offsets.
type LineIndex struct {
	starts []int
}

func NewLineIndex(text string) *LineIndex {
	starts := []int{0}
	for i, r := range text {
		if r == '\n' {
			starts = append(starts, i+1)
		}
	}
	return &LineIndex{starts: starts}
}

func main() {
	fmt.Println(len(NewLineIndex("a\nb").starts))
}

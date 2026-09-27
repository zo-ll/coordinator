// Package events is the append-only event log, the single source of truth.
// The queue and the slice ledger are projections of it.
//
// One JSON object per line, seq 1, 2, … with no gaps. Every append is one
// transaction under an exclusive lock: replay, decide, allocate seq, write,
// fsync. A final line truncated by a crash is ignored on read and cut off by
// the next append.
package events

import (
	"bufio"
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"time"

	"github.com/zo-ll/coordinator/internal/fsx"
)

// Event is one log entry; Type says which fields are set.
type Event struct {
	Seq  int    `json:"seq"`
	TS   string `json:"ts"`
	Type string `json:"type"`

	// queue: enqueued (Slug, Line); claimed, acked, nacked (Slugs; claimed also Batch)
	Slug  string   `json:"slug,omitempty"`
	Line  string   `json:"line,omitempty"`
	Slugs []string `json:"slugs,omitempty"`
	Batch string   `json:"batch,omitempty"`

	// ledger: slice_added, readied (IDs), dispatched, review, verdict,
	// merged, blocked, dropped
	Unit     string   `json:"unit,omitempty"`
	IDs      []string `json:"ids,omitempty"`
	Goal     string   `json:"goal,omitempty"`
	Blockers string   `json:"blockers,omitempty"`
	PID      string   `json:"pid,omitempty"`
	Worktree string   `json:"worktree,omitempty"`
	Branch   string   `json:"branch,omitempty"`
	Task     string   `json:"task,omitempty"`
	Round    string   `json:"round,omitempty"`
	Verdict  string   `json:"verdict,omitempty"`
	Head     string   `json:"head,omitempty"`
	SHA      string   `json:"sha,omitempty"`
}

type Log struct{ Path string }

// Read replays the log. A missing log is os.ErrNotExist; a line that does
// not parse (a torn final write) is skipped.
func (l Log) Read() ([]Event, error) {
	b, err := os.ReadFile(l.Path)
	if err != nil {
		return nil, err
	}
	return parse(b), nil
}

func parse(b []byte) []Event {
	var evs []Event
	sc := bufio.NewScanner(bytes.NewReader(b))
	sc.Buffer(make([]byte, 0, 64*1024), 16*1024*1024)
	for sc.Scan() {
		var e Event
		if json.Unmarshal(sc.Bytes(), &e) == nil && e.Type != "" {
			evs = append(evs, e)
		}
	}
	return evs
}

// Append runs decide over the current log under the lock and appends what
// it returns (possibly nothing), assigning seq and ts. decide's error aborts
// the transaction without writing.
func (l Log) Append(decide func(log []Event) ([]Event, error)) ([]Event, error) {
	if err := os.MkdirAll(filepath.Dir(l.Path), 0o755); err != nil {
		return nil, err
	}
	lk, err := fsx.Lock(l.Path + ".lock")
	if err != nil {
		return nil, err
	}
	defer lk.Close()

	f, err := os.OpenFile(l.Path, os.O_RDWR|os.O_CREATE, 0o644)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	b, err := os.ReadFile(l.Path)
	if err != nil {
		return nil, err
	}
	// cut a torn final line so the next record starts clean
	if n := len(b); n > 0 && b[n-1] != '\n' {
		keep := bytes.LastIndexByte(b, '\n') + 1
		if err := f.Truncate(int64(keep)); err != nil {
			return nil, err
		}
		b = b[:keep]
	}
	log := parse(b)
	add, err := decide(log)
	if err != nil || len(add) == 0 {
		return nil, err
	}

	seq := 0
	if len(log) > 0 {
		seq = log[len(log)-1].Seq
	}
	ts := time.Now().UTC().Format(time.RFC3339Nano)
	var out bytes.Buffer
	for i := range add {
		seq++
		add[i].Seq, add[i].TS = seq, ts
		line, err := json.Marshal(add[i])
		if err != nil {
			return nil, err
		}
		out.Write(line)
		out.WriteByte('\n')
	}
	if _, err := f.Seek(0, 2); err != nil {
		return nil, err
	}
	if _, err := f.Write(out.Bytes()); err != nil {
		return nil, err
	}
	return add, f.Sync()
}

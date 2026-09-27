// Package ledger is the slice ledger as a projection of the event log. Each
// slice is a row: id, status, blockers, task, round, worktree, branch, pid,
// head, verdict, merge, goal. status: todo | ready | dispatched | reviewing |
// handback | merged | blocked | dropped.
//
// Events: slice_added, readied, dispatched, review, verdict, merged,
// blocked, dropped. A mutation of an unknown id appends nothing.
package ledger

import (
	"errors"
	"fmt"
	"os"
	"strings"

	"github.com/zo-ll/coordinator/internal/events"
)

const (
	FID = iota
	FStatus
	FBlockers
	FTask
	FRound
	FWorktree
	FBranch
	FPID
	FHead
	FVerdict
	FMerge
	FGoal
	nfields
)

var fieldIndex = map[string]int{
	"id": FID, "status": FStatus, "blockers": FBlockers, "task": FTask, "round": FRound,
	"worktree": FWorktree, "branch": FBranch, "pid": FPID, "head": FHead,
	"verdict": FVerdict, "merge": FMerge, "goal": FGoal,
}

// Field returns the column index of a named field.
func Field(name string) (int, bool) {
	i, ok := fieldIndex[name]
	return i, ok
}

var ErrExists = errors.New("id already exists")

type Ledger struct{ Log events.Log }

type Row []string

func (r Row) F(i int) string { return r[i] }

// project folds the log into rows in the order slices were added.
func project(log []events.Event) []Row {
	var rows []Row
	at := map[string]int{}
	for _, e := range log {
		if e.Type == "slice_added" {
			if _, ok := at[e.Unit]; !ok {
				at[e.Unit] = len(rows)
				rows = append(rows, Row{e.Unit, "todo", e.Blockers, "", "1", "", "", "", "", "", "", e.Goal})
			}
			continue
		}
		if e.Type == "readied" {
			for _, id := range e.IDs {
				if i, ok := at[id]; ok {
					rows[i][FStatus] = "ready"
				}
			}
			continue
		}
		i, ok := at[e.Unit]
		if !ok {
			continue
		}
		r := rows[i]
		switch e.Type {
		case "dispatched":
			r[FStatus], r[FTask], r[FWorktree], r[FBranch], r[FPID] = "dispatched", e.Task, e.Worktree, e.Branch, e.PID
		case "review":
			r[FStatus], r[FRound] = "reviewing", e.Round
		case "verdict":
			r[FStatus], r[FVerdict] = "handback", "handback"
			if e.Verdict == "pass" {
				r[FStatus], r[FVerdict] = "reviewing", "pass"
			}
			r[FRound], r[FHead] = e.Round, e.Head
		case "merged":
			r[FStatus], r[FMerge] = "merged", e.SHA
		case "blocked":
			r[FStatus] = "blocked"
		case "dropped":
			r[FStatus] = "dropped"
		}
	}
	return rows
}

// Rows replays the ledger; a missing log is os.ErrNotExist.
func (l Ledger) Rows() ([]Row, error) {
	log, err := l.Log.Read()
	if err != nil {
		return nil, err
	}
	return project(log), nil
}

// Add records a todo slice at round 1.
func (l Ledger) Add(id, goal, blockers string) error {
	_, err := l.Log.Append(func(log []events.Event) ([]events.Event, error) {
		for _, r := range project(log) {
			if r[FID] == id {
				return nil, ErrExists
			}
		}
		return []events.Event{{Type: "slice_added", Unit: id, Goal: goal, Blockers: blockers}}, nil
	})
	return err
}

// Ready moves every todo slice whose blockers are all merged or dropped to
// ready, and returns the ids it moved.
func (l Ledger) Ready() ([]string, error) {
	var moved []string
	_, err := l.Log.Append(func(log []events.Event) ([]events.Event, error) {
		rows := project(log)
		st := map[string]string{}
		for _, r := range rows {
			st[r[FID]] = r[FStatus]
		}
		for _, r := range rows {
			if r[FStatus] != "todo" {
				continue
			}
			ok := true
			for _, b := range strings.Split(r[FBlockers], ",") {
				if b == "-" || b == "" {
					continue
				}
				if s := st[b]; s != "merged" && s != "dropped" {
					ok = false
				}
			}
			if ok {
				moved = append(moved, r[FID])
			}
		}
		if len(moved) == 0 {
			return nil, nil
		}
		return []events.Event{{Type: "readied", IDs: moved}}, nil
	})
	return moved, err
}

// Record appends e for slice e.Unit. The log must exist; an unknown id
// appends nothing.
func (l Ledger) Record(e events.Event) error {
	if _, err := os.Stat(l.Log.Path); err != nil {
		return err
	}
	_, err := l.Log.Append(func(log []events.Event) ([]events.Event, error) {
		for _, r := range project(log) {
			if r[FID] == e.Unit {
				return []events.Event{e}, nil
			}
		}
		return nil, nil
	})
	return err
}

// Get returns a field of the row with id.
func (l Ledger) Get(id string, field int) (string, bool) {
	rows, _ := l.Rows()
	for _, r := range rows {
		if r[FID] == id {
			return r[field], true
		}
	}
	return "", false
}

// Live returns "id pid task" for every dispatched or reviewing slice that
// has both a pid and the finish slug its launch owes.
func (l Ledger) Live() []string {
	rows, _ := l.Rows()
	var out []string
	for _, r := range rows {
		s := r[FStatus]
		if (s == "dispatched" || s == "reviewing") && r[FPID] != "" && r[FTask] != "" {
			out = append(out, fmt.Sprintf("%s %s %s", r[FID], r[FPID], r[FTask]))
		}
	}
	return out
}

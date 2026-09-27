// Package ledger is the slice ledger: one TSV row per slice, and the only
// parser of it.
//
// Row: id, status, blockers, task, round, worktree, branch, pid, head,
// verdict, merge, goal (goal last). status: todo | ready | dispatched |
// reviewing | handback | merged | blocked | dropped.
package ledger

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/zo-ll/coordinator/internal/fsx"
)

const nfields = 12

var fieldIndex = map[string]int{
	"id": 0, "status": 1, "blockers": 2, "task": 3, "round": 4, "worktree": 5,
	"branch": 6, "pid": 7, "head": 8, "verdict": 9, "merge": 10, "goal": 11,
}

// Field returns the column index of a named field.
func Field(name string) (int, bool) {
	i, ok := fieldIndex[name]
	return i, ok
}

var ErrExists = errors.New("id already exists")

type Ledger struct{ Path string }

type Row []string

// F returns field i, empty when the row is short.
func (r Row) F(i int) string {
	if i < len(r) {
		return r[i]
	}
	return ""
}

func (r *Row) set(i int, v string) {
	for len(*r) <= i {
		*r = append(*r, "")
	}
	(*r)[i] = v
}

// Rows reads the ledger; a missing file is os.ErrNotExist.
func (l Ledger) Rows() ([]Row, error) {
	b, err := os.ReadFile(l.Path)
	if err != nil {
		return nil, err
	}
	if len(b) == 0 {
		return nil, nil
	}
	var rows []Row
	for _, line := range strings.Split(strings.TrimSuffix(string(b), "\n"), "\n") {
		rows = append(rows, Row(strings.Split(line, "\t")))
	}
	return rows, nil
}

func (l Ledger) save(rows []Row) error {
	var b strings.Builder
	for _, r := range rows {
		b.WriteString(strings.Join(r, "\t"))
		b.WriteByte('\n')
	}
	return fsx.WriteAtomic(l.Path, []byte(b.String()))
}

func (l Ledger) lock() (*os.File, error) {
	if err := os.MkdirAll(filepath.Dir(l.Path), 0o755); err != nil {
		return nil, err
	}
	return fsx.Lock(l.Path + ".lock")
}

func (l Ledger) ensure() error {
	if _, err := os.Stat(l.Path); os.IsNotExist(err) {
		return os.WriteFile(l.Path, nil, 0o644)
	}
	return nil
}

// Add appends a todo row at round 1.
func (l Ledger) Add(id, goal, blockers string) error {
	lk, err := l.lock()
	if err != nil {
		return err
	}
	defer lk.Close()
	if err := l.ensure(); err != nil {
		return err
	}
	rows, err := l.Rows()
	if err != nil {
		return err
	}
	for _, r := range rows {
		if r.F(0) == id {
			return ErrExists
		}
	}
	rows = append(rows, Row{id, "todo", blockers, "", "1", "", "", "", "", "", "", goal})
	return l.save(rows)
}

// Ready moves every todo slice whose blockers are all merged or dropped to
// ready, and returns the ids it moved.
func (l Ledger) Ready() ([]string, error) {
	lk, err := l.lock()
	if err != nil {
		return nil, err
	}
	defer lk.Close()
	if err := l.ensure(); err != nil {
		return nil, err
	}
	rows, err := l.Rows()
	if err != nil {
		return nil, err
	}
	st := map[string]string{}
	for _, r := range rows {
		st[r.F(0)] = r.F(1)
	}
	var moved []string
	for i := range rows {
		if rows[i].F(1) != "todo" {
			continue
		}
		ok := true
		for _, b := range strings.Split(rows[i].F(2), ",") {
			if b == "-" || b == "" {
				continue
			}
			if s := st[b]; s != "merged" && s != "dropped" {
				ok = false
			}
		}
		if ok {
			rows[i].set(1, "ready")
			moved = append(moved, rows[i].F(0))
		}
	}
	return moved, l.save(rows)
}

// Update applies fn to the row with id. The ledger must exist; an unknown id
// changes nothing.
func (l Ledger) Update(id string, fn func(r *Row)) error {
	if _, err := os.Stat(l.Path); err != nil {
		return err
	}
	lk, err := l.lock()
	if err != nil {
		return err
	}
	defer lk.Close()
	rows, err := l.Rows()
	if err != nil {
		return err
	}
	for i := range rows {
		if rows[i].F(0) == id {
			for len(rows[i]) < nfields {
				rows[i] = append(rows[i], "")
			}
			fn(&rows[i])
		}
	}
	return l.save(rows)
}

// Set assigns fields by index on the row with id.
func (l Ledger) Set(id string, kv map[int]string) error {
	return l.Update(id, func(r *Row) {
		for i, v := range kv {
			r.set(i, v)
		}
	})
}

// Get returns a field of the row with id.
func (l Ledger) Get(id string, field int) (string, bool) {
	rows, err := l.Rows()
	if err != nil {
		return "", false
	}
	for _, r := range rows {
		if r.F(0) == id {
			return r.F(field), true
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
		s := r.F(1)
		if (s == "dispatched" || s == "reviewing") && r.F(7) != "" && r.F(3) != "" {
			out = append(out, fmt.Sprintf("%s %s %s", r.F(0), r.F(7), r.F(3)))
		}
	}
	return out
}

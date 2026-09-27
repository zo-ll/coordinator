package main

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/zo-ll/coordinator/internal/ledger"
)

// Slice ledger: the coordinator's memory. The LLM reads these one-line
// outputs, never the TSV.
//
//	state add <id> "<goal>" [--blockers 1,2]
//	state ready                      -> unlock todo slices whose blockers are terminal
//	state next                       -> ready ids (space-separated)
//	state get <id> <field>
//	state dispatch <id> <pid> <wt> <branch> <task>
//	state review <id> <round>
//	state verdict <id> <round> <pass|handback> <head>
//	state merged <id> <sha>
//	state blocked <id>
//	state drop <id>
//	state list                       -> "id <TAB> status <TAB> pid <TAB> verdict <TAB> goal"
//	state live                       -> "id pid task" per dispatched|reviewing slice with a pid and task
//	state done                       -> exit 0 iff every slice is merged|dropped
//	state render                     -> write COORDINATION.md
func cmdState(args []string) int {
	l := ledger.Ledger{Path: ledgerPath()}
	sub, rest := arg(args, 0), args[min(1, len(args)):]
	id := arg(rest, 0)
	need := func(n int, what string) bool {
		if len(rest) < n || rest[n-1] == "" {
			fail(1, "state: %s is required", what)
			return false
		}
		return true
	}
	set := func(kv map[int]string, out string) int {
		if err := l.Set(id, kv); err != nil {
			if errors.Is(err, os.ErrNotExist) {
				return 1
			}
			return fail(1, "state: %v", err)
		}
		fmt.Println(out)
		return 0
	}

	switch sub {
	case "add":
		if !need(1, "id") {
			return 1
		}
		goal, blockers := arg(rest, 1), "-"
		if c := flags("state", rest[min(2, len(rest)):], map[string]*string{"--blockers": &blockers}, nil); c != 0 {
			return c
		}
		if err := l.Add(id, goal, blockers); err != nil {
			if errors.Is(err, ledger.ErrExists) {
				return fail(1, "state: id already exists: %s", id)
			}
			return fail(1, "state: %v", err)
		}
		fmt.Printf("ADDED %s\n", id)

	case "ready":
		moved, err := l.Ready()
		if err != nil {
			return fail(1, "state: %v", err)
		}
		if len(moved) > 0 {
			fmt.Printf("READY %s\n", strings.Join(moved, " "))
		}

	case "next":
		rows, _ := l.Rows()
		var ids []string
		for _, r := range rows {
			if r.F(1) == "ready" {
				ids = append(ids, r.F(0))
			}
		}
		if len(ids) > 0 {
			fmt.Println(strings.Join(ids, " "))
		}

	case "get":
		if !need(2, "id and field") {
			return 1
		}
		n, ok := ledger.Field(rest[1])
		if !ok {
			return fail(2, "state: unknown field: %s", rest[1])
		}
		v, ok := l.Get(id, n)
		if !ok {
			return 1
		}
		fmt.Println(v)

	case "dispatch":
		if !need(1, "id") {
			return 1
		}
		return set(map[int]string{1: "dispatched", 3: arg(rest, 4), 5: arg(rest, 2), 6: arg(rest, 3), 7: arg(rest, 1)},
			"DISPATCHED "+id)

	case "review":
		if !need(2, "id and round") {
			return 1
		}
		return set(map[int]string{1: "reviewing", 4: rest[1]}, "REVIEWING "+id)

	case "verdict":
		if !need(3, "id, round and verdict") {
			return 1
		}
		v := rest[2]
		kv := map[int]string{1: "handback", 4: rest[1], 8: arg(rest, 3), 9: "handback"}
		if v == "pass" {
			kv[1], kv[9] = "reviewing", "pass"
		}
		return set(kv, fmt.Sprintf("VERDICT %s %s", id, v))

	case "merged":
		if !need(1, "id") {
			return 1
		}
		return set(map[int]string{1: "merged", 10: arg(rest, 1)}, "MERGED "+id)

	case "blocked":
		if !need(1, "id") {
			return 1
		}
		return set(map[int]string{1: "blocked"}, "BLOCKED "+id)

	case "drop":
		if !need(1, "id") {
			return 1
		}
		return set(map[int]string{1: "dropped"}, "DROPPED "+id)

	case "list":
		rows, _ := l.Rows()
		for _, r := range rows {
			fmt.Printf("%s\t%s\t%s\t%s\t%s\n", r.F(0), r.F(1), r.F(7), r.F(9), r.F(11))
		}

	case "live":
		for _, s := range l.Live() {
			fmt.Println(s)
		}

	case "done":
		rows, _ := l.Rows()
		for _, r := range rows {
			if s := r.F(1); s != "merged" && s != "dropped" {
				return 1
			}
		}

	case "render":
		rows, err := l.Rows()
		if errors.Is(err, os.ErrNotExist) {
			return 0
		}
		dash := env("COORD_DASHBOARD", filepath.Join(cwd(), "COORDINATION.md"))
		var b strings.Builder
		b.WriteString("# COORDINATION\n\n")
		b.WriteString("| id | status | round | verdict | head | merge | goal |\n")
		b.WriteString("|---|---|---|---|---|---|---|\n")
		for _, r := range rows {
			fmt.Fprintf(&b, "| %s | %s | %s | %s | %s | %s | %s |\n", r.F(0), r.F(1), r.F(4), r.F(9), r.F(8), r.F(10), r.F(11))
		}
		if err := os.MkdirAll(filepath.Dir(dash), 0o755); err != nil {
			return fail(1, "state: %v", err)
		}
		if err := os.WriteFile(dash, []byte(b.String()), 0o644); err != nil {
			return fail(1, "state: %v", err)
		}
		fmt.Printf("RENDERED %s\n", dash)

	default:
		return fail(2, "usage: state.sh add|ready|next|get|dispatch|review|verdict|merged|blocked|drop|list|live|done|render")
	}
	return 0
}

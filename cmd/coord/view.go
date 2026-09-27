package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/zo-ll/coordinator/internal/model"
)

// The sanctioned views of a run. Read-only.
//
//	status  -> STATUS relay=<pid|-> alive=<0|1> undelivered=<n> inflight=<n>
//	           UNIT <id> <state> kind=<k> round=<n> ready=<0|1> pid=<p|-> alive=<0|1> goal=<g>
//	           LOG <id> <slug> <last line of the live launch's log>
//	           RESEARCH <slug> pid=<p> alive=<0|1> report=<path>
//	render  -> RENDERED <path>  (COORDINATION.md at the repo root)
//	log [<id>] -> "<seq> <type> <unit|-> <what>" per event
//	done    -> DONE units=<n> (exit 0) | OPEN <ids> (exit 1)
func cmdStatus(args []string) int {
	r := load()
	rpid, _ := strconv.Atoi(readTrim(runPath("relay.pid")))
	fmt.Printf("STATUS relay=%s alive=%s undelivered=%d inflight=%d\n",
		dash(readTrim(runPath("relay.pid"))), bit(alive(rpid)), len(r.Undelivered()), len(r.InFlight()))
	for _, id := range r.Order {
		u := r.Units[id]
		pid, a := "-", false
		if u.Owes != "" {
			pid, a = strconv.Itoa(u.PID), alive(u.PID)
		}
		fmt.Printf("UNIT %s %s kind=%s round=%d ready=%s pid=%s alive=%s goal=%s\n",
			id, u.State, u.Kind, u.Round, bit(r.Ready(u)), pid, bit(a), u.Goal)
		if a {
			if last := lastLine(u.Log); last != "" {
				fmt.Printf("LOG %s %s %s\n", id, u.Owes, last)
			}
		}
	}
	for _, l := range r.Research {
		fmt.Printf("RESEARCH %s pid=%d alive=%s report=%s\n", l.Slug, l.PID, bit(alive(l.PID)), l.Report)
	}
	return 0
}

func cmdRender(args []string) int {
	r := load()
	dash := env("COORD_DASHBOARD", filepath.Join(repoRoot(), "COORDINATION.md"))
	var b strings.Builder
	b.WriteString("# COORDINATION\n\n")
	b.WriteString("| id | kind | state | round | evidence | reviewed state | merge | goal |\n")
	b.WriteString("|---|---|---|---|---|---|---|---|\n")
	for _, id := range r.Order {
		u := r.Units[id]
		ev := ""
		if u.Evidence != nil {
			ev = u.Evidence.Level
		}
		state := u.PassState
		if len(state) > 12 {
			state = state[:12]
		}
		fmt.Fprintf(&b, "| %s | %s | %s | %d | %s | %s | %s | %s |\n", id, u.Kind, u.State, u.Round, ev, state, u.SHA, u.Goal)
	}
	if err := writeFile(dash, []byte(b.String())); err != nil {
		return fail(1, "render: %v", err)
	}
	fmt.Printf("RENDERED %s\n", dash)
	return 0
}

func cmdLog(args []string) int {
	id := arg(args, 0)
	log, _ := eventLog().Read()
	for _, e := range log {
		if id != "" && e.Unit != id {
			continue
		}
		fmt.Printf("%d %s %s %s\n", e.Seq, e.Type, dash(e.Unit), model.Describe(e))
	}
	return 0
}

func cmdDone(args []string) int {
	r := load()
	var open []string
	for _, id := range r.Order {
		if !r.Units[id].State.Terminal() {
			open = append(open, id)
		}
	}
	if len(open) > 0 {
		fmt.Printf("OPEN %s\n", strings.Join(open, " "))
		return 1
	}
	fmt.Printf("DONE units=%d\n", len(r.Order))
	return 0
}

// lastLine is the log's last line, carriage returns dropped, cut to 200 bytes.
func lastLine(p string) string {
	b, err := os.ReadFile(p)
	if err != nil {
		return ""
	}
	s := strings.TrimSuffix(string(b), "\n")
	if i := strings.LastIndex(s, "\n"); i >= 0 {
		s = s[i+1:]
	}
	s = strings.ReplaceAll(s, "\r", "")
	if len(s) > 200 {
		s = s[:200]
	}
	return s
}

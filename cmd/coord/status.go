package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/zo-ll/coordinator/internal/ledger"
	"github.com/zo-ll/coordinator/internal/queue"
)

// One-command view of a run: the ledger, queue depth, live pids, and the tail
// of every active role log. Read-only.
//
//	status
//	  -> STATUS relay=<pid|-> alive=<0|1>
//	     QUEUE pending=<n> inflight=<n> done=<n>
//	     SLICE <id> <status> pid=<pid|-> alive=<0|1> verdict=<v|-> goal=<...>
//	     LOG <id> <role> <last line>   (live slices only, truncated)
func cmdStatus(args []string) int {
	root := coordRoot()
	rpid := readTrim(filepath.Join(root, "relay.pid"))
	fmt.Printf("STATUS relay=%s alive=%s\n", dash(rpid), bit(alive(rpid)))

	log := eventLog()
	p, i, d := queue.Queue{Log: log}.Depth()
	fmt.Printf("QUEUE pending=%d inflight=%d done=%d\n", p, i, d)

	rows, _ := ledger.Ledger{Log: log}.Rows()
	for _, r := range rows {
		id, st, pid := r.F(0), r.F(1), r.F(7)
		a := alive(pid)
		fmt.Printf("SLICE %s %s pid=%s alive=%s verdict=%s goal=%s\n", id, st, dash(pid), bit(a), dash(r.F(9)), r.F(11))
		if !a || (st != "dispatched" && st != "reviewing") {
			continue
		}
		for _, role := range []string{"worker", "critic"} {
			if last := lastLine(filepath.Join(root, "log", role+"."+id+".log")); last != "" {
				fmt.Printf("LOG %s %s %s\n", id, role, last)
			}
		}
	}
	return 0
}

func dash(s string) string {
	if s == "" {
		return "-"
	}
	return s
}

func bit(b bool) string {
	if b {
		return "1"
	}
	return "0"
}

// lastLine is `tail -n1`, carriage returns dropped, cut to 200 bytes.
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

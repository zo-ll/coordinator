package main

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	"github.com/zo-ll/coordinator/internal/queue"
)

var (
	slugRe  = regexp.MustCompile(`^[A-Za-z0-9._-]+$`)
	roundRe = regexp.MustCompile(`\.r[0-9]`)
)

// Record completion: write the recovery marker, then enqueue the ping.
//
//	finish --event <slug> --role <worker|critic|researcher>
//	       --result <done|checkpoint|correction|pass|handback>
//	       --head <sha|-> --summary "one line"
//
// Marker: $COORD_MARKERS/<event>.done (default <cwd>/.scratch/status),
// written BEFORE the ping is enqueued so a crash between the two is recoverable.
func cmdFinish(args []string) int {
	var event, role, result, summary string
	head := "-"
	if c := flags("finish.sh", args, map[string]*string{
		"--event": &event, "--role": &role, "--result": &result, "--head": &head, "--summary": &summary,
	}, nil); c != 0 {
		return c
	}
	if event == "" || role == "" || result == "" {
		return fail(2, "finish.sh: --event, --role and --result are required")
	}
	if !slugRe.MatchString(event) {
		return fail(2, "finish.sh: invalid --event slug '%s' (use [A-Za-z0-9._-]+)", event)
	}

	// foo -> foo/r1; foo.critic -> foo/r1; foo.r2 -> foo/r2; foo.r2.critic -> foo/r2
	base := strings.TrimSuffix(event, ".critic")
	task, round := base, "1"
	if roundRe.MatchString(base) {
		round = base[strings.LastIndex(base, ".r")+2:]
		task = base[:strings.LastIndex(base, ".")]
	}

	markers := env("COORD_MARKERS", filepath.Join(cwd(), ".scratch", "status"))
	if err := os.MkdirAll(markers, 0o755); err != nil {
		return fail(1, "finish.sh: %v", err)
	}
	ts := time.Now().UTC().Format("2006-01-02T15:04:05Z")
	marker := fmt.Sprintf("done TS=%s TASK=%s ROUND=%s ROLE=%s HEAD=%s RESULT=%s SUMMARY=%s\n",
		ts, task, round, role, head, result, summary)
	if err := os.WriteFile(filepath.Join(markers, event+".done"), []byte(marker), 0o644); err != nil {
		return fail(1, "finish.sh: %v", err)
	}

	line := fmt.Sprintf("DONE %s: %s — %s", task, result, summary)
	if role == "critic" {
		line = fmt.Sprintf("VERDICT %s: %s @ %s — %s", task, result, head, summary)
	}
	q, err := queue.Open(coordRoot())
	if err != nil {
		return fail(1, "finish.sh: %v", err)
	}
	if _, _, err := q.Enqueue(event, line); err != nil {
		return fail(1, "finish.sh: %v", err)
	}
	fmt.Printf("FINISH %s task=%s round=%s\n", event, task, round)
	return 0
}

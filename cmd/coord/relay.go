package main

import (
	"fmt"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/zo-ll/coordinator/internal/cfg"
	"github.com/zo-ll/coordinator/internal/events"
	"github.com/zo-ll/coordinator/internal/fsx"
	"github.com/zo-ll/coordinator/internal/ledger"
	"github.com/zo-ll/coordinator/internal/queue"
)

// Serial queue consumer: the only thing that turns workers' pings into a
// coordinator turn.
//
//	relay [--once] [--interval N] [--max-attempts N] [--backoff N]
//
// Loop: wait for the queue to be non-empty; claim every pending event, in
// order, into one batch file; resume the coordinator with a one-line pointer
// to it; wait for the turn to exit; ack the batch. One turn at a time.
//
// Delivery is bounded: a failed resume is retried with exponential backoff up
// to --max-attempts. On exhaustion the batch is returned to the queue and the
// relay exits nonzero.
//
// Delivery is at-least-once: events stranded in .inflight by a crash are
// requeued at startup, under the single-relay lock.
//
// Liveness: each loop, every dispatched/reviewing slice whose pid is gone and
// whose owed finish slug was never enqueued becomes a `DIED <task>` event
// (slug <task>.died.<pid>, so a respawn that dies again reports again).
//
// Standing orders ($COORD_STANDING, default <config dir>/standing.md) are
// appended verbatim to every batch.
//
// The resume command is config data (never evaluated): relay.resume, a
// '|'-separated argv template with __SESSION__ and __BATCH__, and
// relay.session. Overrides: COORD_RESUME, COORD_SESSION.
func cmdRelay(args []string) int {
	var once bool
	interval := env("RELAY_INTERVAL", "1")
	attempts := env("RELAY_MAX_ATTEMPTS", "5")
	backoff := env("RELAY_BACKOFF", "2")
	if c := flags("relay.sh", args, map[string]*string{
		"--interval": &interval, "--max-attempts": &attempts, "--backoff": &backoff,
	}, map[string]*bool{"--once": &once}); c != 0 {
		return c
	}
	iv, err1 := strconv.ParseFloat(interval, 64)
	maxAttempts, err2 := strconv.Atoi(attempts)
	wait0, err3 := strconv.Atoi(backoff)
	if err1 != nil || err2 != nil || err3 != nil {
		return fail(2, "relay.sh: --interval, --max-attempts and --backoff must be numbers")
	}

	root := coordRoot()
	config := configPath()
	standing := env("COORD_STANDING", filepath.Join(filepath.Dir(config), "standing.md"))
	// the relay serves the run whose config it was started with
	logPath := os.Getenv("COORD_EVENTS")
	if logPath == "" {
		logPath = filepath.Join(filepath.Dir(config), "events.jsonl")
	}
	log := events.Log{Path: logPath}
	l, q := ledger.Ledger{Log: log}, queue.Queue{Log: log}
	for _, d := range []string{root, filepath.Join(root, "batch")} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			return fail(1, "relay: %v", err)
		}
	}
	// single relay: hold the lock for the process lifetime
	lk, ok, err := fsx.TryLock(filepath.Join(root, "relay.lock"))
	if err != nil {
		return fail(1, "relay: %v", err)
	}
	if !ok {
		return fail(1, "relay: another relay already holds %s; refusing to run two", filepath.Join(root, "relay.lock"))
	}
	defer lk.Close()
	pidfile := filepath.Join(root, "relay.pid")
	os.WriteFile(pidfile, []byte(fmt.Sprintf("%d\n", os.Getpid())), 0o644)
	defer os.Remove(pidfile)
	sigs := make(chan os.Signal, 1)
	signal.Notify(sigs, syscall.SIGTERM, syscall.SIGINT, syscall.SIGHUP)
	go func() {
		s := <-sigs
		os.Remove(pidfile)
		os.Exit(128 + int(s.(syscall.Signal)))
	}()

	// reclaim events stranded by a previous relay crash: the lock guarantees
	// no other consumer exists, so anything in .inflight is ours to requeue.
	q.Nack()

	reap := func() {
		for _, line := range l.Live() {
			f := strings.Fields(line)
			pid, task := f[1], f[2]
			if alive(pid) || q.Seen(task) {
				continue
			}
			q.Enqueue(task+".died."+pid, fmt.Sprintf("DIED %s: pid %s exited without finish.sh (log: %s)", task, pid, filepath.Join(root, "log")))
		}
	}

	deliver := func(batch string) bool {
		wait := wait0
		for attempt := 1; ; attempt++ {
			if err := resume(config, "WAKE batch="+batch); err == nil {
				q.Ack()
				return true
			}
			if attempt >= maxAttempts {
				q.Nack()
				fmt.Fprintf(os.Stderr, "relay: resume failed %d times for %s; returned the events to the queue and stopped (fix the resume recipe, then restart the relay)\n", maxAttempts, batch)
				return false
			}
			fmt.Fprintf(os.Stderr, "relay: resume failed (attempt %d/%d), retrying in %ds\n", attempt, maxAttempts, wait)
			time.Sleep(time.Duration(wait) * time.Second)
			wait = min(wait*2, 60)
		}
	}

	for {
		reap()
		if !q.Pending() {
			time.Sleep(time.Duration(iv * float64(time.Second)))
			continue
		}
		batch := filepath.Join(root, "batch", fmt.Sprintf("%d.%d.txt", time.Now().UnixNano(), os.Getpid()))
		n, err := q.PopBatch(batch)
		if err != nil {
			return fail(1, "relay: %v", err)
		}
		if n == 0 {
			continue
		}
		if nonEmpty(standing) {
			orders, _ := os.ReadFile(standing)
			f, err := os.OpenFile(batch, os.O_WRONLY|os.O_APPEND, 0o644)
			if err == nil {
				fmt.Fprintf(f, "\nSTANDING ORDERS (apply to everything you do):\n%s", orders)
				f.Close()
			}
		}
		if !deliver(batch) {
			return 1
		}
		if once {
			return 0
		}
	}
}

// resume runs the resume recipe with the pointer and session substituted,
// and waits for the coordinator's turn to exit.
func resume(config, pointer string) error {
	recipe := resumeRecipe(config)
	if recipe == "" {
		fmt.Fprintln(os.Stderr, "relay: no relay.resume recipe (set COORD_RESUME, config, or env.conf)")
		return fmt.Errorf("no recipe")
	}
	session := sessionID(config)
	argv := strings.Split(recipe, "|")
	if len(argv) > 1 && argv[len(argv)-1] == "" {
		argv = argv[:len(argv)-1]
	}
	for i := range argv {
		argv[i] = strings.ReplaceAll(argv[i], "__BATCH__", pointer)
		argv[i] = strings.ReplaceAll(argv[i], "__SESSION__", session)
	}
	c := exec.Command(argv[0], argv[1:]...)
	c.Stdin, c.Stdout, c.Stderr = os.Stdin, os.Stdout, os.Stderr
	return c.Run()
}

func resumeRecipe(config string) string {
	if v := os.Getenv("COORD_RESUME"); v != "" {
		return v
	}
	if v := cfg.Value(config, "relay.resume"); v != "" {
		return v
	}
	if cur := cfg.Value(envConf(), "current"); cur != "" {
		return cfg.Value(envConf(), "harness."+cur+".resume")
	}
	return ""
}

func sessionID(config string) string {
	if v := os.Getenv("COORD_SESSION"); v != "" {
		return v
	}
	if v := cfg.Value(config, "relay.session"); v != "" {
		return v
	}
	if p := filepath.Join(filepath.Dir(config), "session"); isFile(p) {
		return readTrim(p)
	}
	return readTrim(filepath.Join(cwd(), ".coordinator", "session"))
}

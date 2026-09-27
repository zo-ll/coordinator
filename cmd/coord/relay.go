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
	"github.com/zo-ll/coordinator/internal/model"
)

// The scheduler: the only thing that turns events into coordinator turns.
//
//	relay [--once] [--interval N] [--max-attempts N] [--backoff N]
//
// One relay per run (a lock in .coordinator/). Each tick:
//
//  1. Liveness: a live launch whose pid is gone without finishing gets
//     `died reason=exited`.
//  2. Timebox: a launch past its timebox gets SIGTERM on its process group,
//     SIGKILL after timebox.grace (config, default 30s), then `died
//     reason=timeout`. A second death in one round blocks the unit (by engine).
//  3. Delivery: undelivered wake events are written, in order, to one batch
//     file (then the standing orders) and `claimed`; the coordinator is
//     resumed with `WAKE batch=<path>`; when its turn exits they are `acked`.
//
// A failed resume is retried with exponential backoff up to --max-attempts;
// then the batch is `nacked` and the relay exits nonzero. Delivery is
// at-least-once: a batch claimed by a relay that crashed is nacked at startup.
//
// The resume command is config data (never evaluated): relay.resume, a
// '|'-separated argv template with __SESSION__ and __BATCH__, and
// relay.session. Overrides: COORD_RESUME, COORD_SESSION.
func cmdRelay(args []string) int {
	var once bool
	interval := env("RELAY_INTERVAL", "1")
	attempts := env("RELAY_MAX_ATTEMPTS", "5")
	backoff := env("RELAY_BACKOFF", "2")
	if c := flags("relay", args, map[string]*string{
		"--interval": &interval, "--max-attempts": &attempts, "--backoff": &backoff,
	}, map[string]*bool{"--once": &once}); c != 0 {
		return c
	}
	iv, err1 := strconv.ParseFloat(interval, 64)
	maxAttempts, err2 := strconv.Atoi(attempts)
	wait0, err3 := strconv.Atoi(backoff)
	if err1 != nil || err2 != nil || err3 != nil {
		return fail(2, "relay: --interval, --max-attempts and --backoff must be numbers")
	}
	config := configPath()
	grace := 30 * time.Second
	if d, err := time.ParseDuration(cfg.Value(config, "timebox.grace")); err == nil && d >= 0 {
		grace = d
	}
	if err := os.MkdirAll(runPath("batch"), 0o755); err != nil {
		return fail(1, "relay: %v", err)
	}

	// one relay per run: hold the lock for the process lifetime
	lk, ok, err := fsx.TryLock(runPath("relay.lock"))
	if err != nil {
		return fail(1, "relay: %v", err)
	}
	if !ok {
		return fail(1, "relay: another relay already holds %s; refusing to run two", runPath("relay.lock"))
	}
	defer lk.Close()
	pidfile := runPath("relay.pid")
	os.WriteFile(pidfile, []byte(fmt.Sprintf("%d\n", os.Getpid())), 0o644)
	defer os.Remove(pidfile)
	sigs := make(chan os.Signal, 1)
	signal.Notify(sigs, syscall.SIGTERM, syscall.SIGINT, syscall.SIGHUP)
	go func() {
		s := <-sigs
		os.Remove(pidfile)
		os.Exit(128 + int(s.(syscall.Signal)))
	}()

	// a batch claimed by a relay that crashed is ours to redeliver
	commit(func(r *model.Run) ([]events.Event, error) {
		if s := r.InFlight(); len(s) > 0 {
			return []events.Event{{Type: "nacked", Seqs: s}}, nil
		}
		return nil, nil
	})

	termed := map[string]time.Time{} // slug -> when SIGTERM was sent
	for {
		reap(termed, grace)
		batch, seqs, err := claim()
		if err != nil {
			return fail(1, "relay: %v", err)
		}
		if batch == "" {
			time.Sleep(time.Duration(iv * float64(time.Second)))
			continue
		}
		if !deliver(config, batch, seqs, maxAttempts, wait0) {
			return 1
		}
		if once {
			return 0
		}
	}
}

// reap reports launches that died or ran past their timebox.
func reap(termed map[string]time.Time, grace time.Duration) {
	type live struct {
		unit, slug string
		pid        int
		started    time.Time
		timebox    int
	}
	r := load()
	var ls []live
	for _, id := range r.Order {
		if u := r.Units[id]; u.Owes != "" {
			ls = append(ls, live{u.ID, u.Owes, u.PID, u.Dispatched, u.TimeboxS})
		}
	}
	for _, l := range r.Research {
		ls = append(ls, live{"", l.Slug, l.PID, l.Dispatched, l.TimeboxS})
	}
	now := time.Now()
	for _, l := range ls {
		reason := ""
		if t, ok := termed[l.slug]; ok {
			if alive(l.pid) && now.Sub(t) < grace {
				continue
			}
			killGroup(l.pid, syscall.SIGKILL)
			reason = "timeout"
		} else if !alive(l.pid) {
			reason = "exited"
		} else if l.timebox > 0 && now.Sub(l.started) > time.Duration(l.timebox)*time.Second {
			killGroup(l.pid, syscall.SIGTERM)
			termed[l.slug] = now
			continue
		}
		if reason == "" {
			continue
		}
		delete(termed, l.slug)
		commit(func(r *model.Run) ([]events.Event, error) {
			add := []events.Event{{Type: "died", Unit: l.unit, Slug: l.slug, PID: l.pid, Reason: reason}}
			if u := r.Owner(l.slug); u != nil && u.PID == l.pid && u.Deaths[u.Round]+1 >= model.MaxDeaths {
				add = append(add, events.Event{Type: "blocked", Unit: u.ID, By: "engine",
					Reason: fmt.Sprintf("died %d times in round %d", model.MaxDeaths, u.Round)})
			}
			return add, nil
		})
	}
}

// claim writes every undelivered wake event into a new batch file and
// records the claim; batch is "" when there is nothing to deliver.
func claim() (batch string, seqs []int, err error) {
	_, err = commit(func(r *model.Run) ([]events.Event, error) {
		wakes := r.Undelivered()
		if len(wakes) == 0 {
			return nil, nil
		}
		batch = runPath("batch", fmt.Sprintf("%d.txt", time.Now().UnixNano()))
		var b strings.Builder
		for _, e := range wakes {
			fmt.Fprintf(&b, "EVENT %d %s %s %s\n", e.Seq, dash(e.Unit), e.Type, model.Describe(e))
			seqs = append(seqs, e.Seq)
		}
		if p := runPath("standing.md"); nonEmpty(p) {
			orders, _ := os.ReadFile(p)
			fmt.Fprintf(&b, "\nSTANDING ORDERS (apply to everything you do):\n%s", orders)
		}
		// the batch is written before the claim: a crash in between leaves
		// the events undelivered, so they are delivered again, never lost
		if err := os.WriteFile(batch, []byte(b.String()), 0o644); err != nil {
			return nil, err
		}
		return []events.Event{{Type: "claimed", Batch: batch, Seqs: seqs}}, nil
	})
	if err != nil {
		return "", nil, err
	}
	return batch, seqs, nil
}

// deliver resumes the coordinator on batch, retrying with backoff; it acks on
// success and nacks (returning false) when the attempts run out.
func deliver(config, batch string, seqs []int, maxAttempts, wait int) bool {
	settle := func(typ string) {
		commit(func(*model.Run) ([]events.Event, error) {
			return []events.Event{{Type: typ, Seqs: seqs, Batch: batch}}, nil
		})
	}
	for attempt := 1; ; attempt++ {
		if err := resume(config, "WAKE batch="+batch); err == nil {
			settle("acked")
			return true
		}
		if attempt >= maxAttempts {
			settle("nacked")
			fmt.Fprintf(os.Stderr, "relay: resume failed %d times for %s; returned the events and stopped (fix the resume recipe, then restart the relay)\n", maxAttempts, batch)
			return false
		}
		fmt.Fprintf(os.Stderr, "relay: resume failed (attempt %d/%d), retrying in %ds\n", attempt, maxAttempts, wait)
		time.Sleep(time.Duration(wait) * time.Second)
		wait = min(wait*2, 60)
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
	c.Dir = repoRoot()
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
	return readTrim(filepath.Join(runDir(), "session"))
}

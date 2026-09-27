package main

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/zo-ll/coordinator/internal/events"
	"github.com/zo-ll/coordinator/internal/model"
)

// A run lives in <repo>/.coordinator/: the event log, config, standing
// orders, playbook overrides, and (gitignored) briefs, logs, batches,
// worktrees, and the relay's lock.

// eventsPath is the event log: $COORD_EVENTS, else the nearest
// .coordinator/events.jsonl at or above the working directory (a worktree
// under <repo>/.coordinator/worktrees finds its repo's log), else
// ./.coordinator/events.jsonl.
func eventsPath() string {
	if p := existingEventsPath(); p != "" {
		return p
	}
	return filepath.Join(cwd(), ".coordinator", "events.jsonl")
}

// existingEventsPath is eventsPath without the fallback: "" when no log is
// named or found.
func existingEventsPath() string {
	if p := os.Getenv("COORD_EVENTS"); p != "" {
		if abs, err := filepath.Abs(p); err == nil {
			return abs
		}
		return p
	}
	for d := cwd(); ; d = filepath.Dir(d) {
		if p := filepath.Join(d, ".coordinator", "events.jsonl"); isFile(p) {
			return p
		}
		if filepath.Dir(d) == d {
			return ""
		}
	}
}

func cwd() string {
	d, err := os.Getwd()
	if err != nil {
		return "."
	}
	return d
}

func eventLog() events.Log { return events.Log{Path: eventsPath()} }
func runDir() string       { return filepath.Dir(eventsPath()) }
func repoRoot() string     { return filepath.Dir(runDir()) }
func runPath(p ...string) string {
	return filepath.Join(append([]string{runDir()}, p...)...)
}
func configPath() string { return env("COORD_CONFIG", runPath("config.conf")) }

func coordHome() string { return env("COORD_HOME", filepath.Join(os.Getenv("HOME"), ".coordinator")) }
func envConf() string   { return env("COORD_ENV_CONF", filepath.Join(coordHome(), "env.conf")) }

// skillRoot is the installed skill (the repo bin/coord was built in):
// shipped playbooks, role preambles, and adapters live there.
func skillRoot() string { return env("COORD_SKILL", filepath.Dir(filepath.Dir(self()))) }
func playbookDirs() []string {
	return []string{runPath("playbooks"), filepath.Join(skillRoot(), "playbooks")}
}

// load replays the log into the run's current state.
func load() *model.Run {
	log, _ := eventLog().Read()
	return model.Fold(log)
}

// refusal is an event the state machine would not accept.
type refusal struct {
	e   events.Event
	err error
}

func (r *refusal) Error() string {
	return fmt.Sprintf("REFUSED %s %s: %v", dash(r.e.Unit), r.e.Type, r.err)
}

// commit runs build over the folded run under the log's lock, checks every
// event it returns against the state machine, and appends them atomically.
func commit(build func(r *model.Run) ([]events.Event, error)) ([]events.Event, error) {
	return eventLog().Append(func(log []events.Event) ([]events.Event, error) {
		r := model.Fold(log)
		add, err := build(r)
		if err != nil || len(add) == 0 {
			return nil, err
		}
		seq := 0
		if len(log) > 0 {
			seq = log[len(log)-1].Seq
		}
		ts := time.Now().UTC().Format(time.RFC3339Nano)
		for i := range add {
			seq++
			add[i].Seq, add[i].TS = seq, ts
			if err := r.Apply(add[i]); err != nil {
				if errors.Is(err, model.ErrDup) {
					return nil, err
				}
				return nil, &refusal{add[i], err}
			}
		}
		return add, nil
	})
}

// refused prints a refusal (or any error) as one line and returns 1.
func refused(err error) int {
	var r *refusal
	if errors.As(err, &r) {
		return fail(1, "%s", r.Error())
	}
	return fail(1, "coord: %v", err)
}

// refuse builds a refusal for commands that reject input before an event.
func refuse(unit, typ, format string, a ...any) int {
	return fail(1, "REFUSED %s %s: %s", dash(unit), typ, fmt.Sprintf(format, a...))
}

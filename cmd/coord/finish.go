package main

import (
	"errors"
	"fmt"
	"os"
	"strings"

	"github.com/zo-ll/coordinator/internal/events"
	"github.com/zo-ll/coordinator/internal/model"
	"github.com/zo-ll/coordinator/internal/playbook"
)

// Record a launch's completion.
//
//	finish --result <done|partial|pass|handback> [--evidence <level>]
//	       [--ran "<command>"]… [--flag <name>]… --summary "<one line>" [--slug <s>]
//	  -> FINISHED <slug> -> <state> | DUP <slug>
//
// The slug is the one the launch owes: --slug, else $COORD_OWES (set at
// dispatch). The log is $COORD_EVENTS or the nearest .coordinator/events.jsonl
// above the working directory; finish never creates one.
//
// A critic's pass is checked against the unit's playbook: the evidence level
// must reach the floor, at least one --ran is required unless the floor is
// none, and every required flag must be present. Otherwise the pass is
// recorded and converted to a handback, with the reason. The reviewed-state
// hash is computed here, in the unit's worktree.
func cmdFinish(args []string) int {
	var result, level, summary, slug string
	var ran, flagsSet []string
	fs := flagSet{
		vals:  map[string]*string{"--result": &result, "--evidence": &level, "--summary": &summary, "--slug": &slug},
		multi: map[string]*[]string{"--ran": &ran, "--flag": &flagsSet},
	}
	if c := fs.parse("finish", args); c != 0 {
		return c
	}
	if slug == "" {
		slug = os.Getenv("COORD_OWES")
	}
	if slug == "" || result == "" {
		return fail(2, "finish: --result and the owed slug (--slug or COORD_OWES) are required")
	}
	if existingEventsPath() == "" {
		return fail(1, "finish: no event log (set COORD_EVENTS, or run inside the repo or its worktrees)")
	}

	r := load()
	if r.Finished[slug] {
		fmt.Printf("DUP %s\n", slug)
		return 0
	}
	fin := events.Event{Type: "finished", Slug: slug, Result: result, Summary: summary}
	var conv *events.Event
	if l := r.Research[slug]; l != nil {
		fin.Role, fin.Report = "researcher", l.Report
	} else {
		u := r.Owner(slug)
		if u == nil {
			return refuse("", "finished", "slug %q is not owed by any live launch", slug)
		}
		fin.Unit, fin.Role = u.ID, u.Role
		if u.Role == "critic" && result == "pass" {
			pb, err := playbook.Load(u.Kind, playbookDirs()...)
			if err != nil {
				return refuse(u.ID, "finished", "%v", err)
			}
			if level == "" {
				level = "none"
			}
			if playbook.Rank(level) < 0 {
				return fail(2, "finish: --evidence %q is not one of %s", level, strings.Join(playbook.Levels, ","))
			}
			state, err := stateHash(u.Worktree)
			if err != nil {
				return fail(1, "finish: cannot hash the reviewed state in %s: %v", u.Worktree, err)
			}
			fin.State = state
			fin.Evidence = &events.Evidence{Level: level, Ran: ran, Flags: flagsSet}
			if reason := shortfall(pb, fin.Evidence); reason != "" {
				conv = &events.Event{Type: "converted", Unit: u.ID, Slug: slug, From: "pass", To: "handback", Reason: reason}
			}
		}
	}

	_, err := commit(func(*model.Run) ([]events.Event, error) {
		add := []events.Event{fin}
		if conv != nil {
			add = append(add, *conv)
		}
		return add, nil
	})
	if errors.Is(err, model.ErrDup) {
		fmt.Printf("DUP %s\n", slug)
		return 0
	}
	if err != nil {
		return refused(err)
	}
	switch {
	case fin.Role == "researcher":
		fmt.Printf("FINISHED %s report=%s\n", slug, fin.Report)
	case conv != nil:
		fmt.Printf("FINISHED %s -> handback (converted: %s)\n", slug, conv.Reason)
	default:
		fmt.Printf("FINISHED %s -> %s\n", slug, load().Units[fin.Unit].State)
	}
	return 0
}

// shortfall says why evidence does not meet a playbook, or "" if it does.
func shortfall(pb *playbook.Playbook, ev *events.Evidence) string {
	var why []string
	if playbook.Rank(ev.Level) < playbook.Rank(pb.Floor) {
		why = append(why, fmt.Sprintf("evidence %s is below the %s floor %s", ev.Level, pb.Kind, pb.Floor))
	}
	if pb.Floor != "none" && len(ev.Ran) == 0 {
		why = append(why, "no --ran command recorded")
	}
	for _, need := range pb.Need {
		found := false
		for _, f := range ev.Flags {
			found = found || f == need
		}
		if !found {
			why = append(why, "missing --flag "+need)
		}
	}
	return strings.Join(why, "; ")
}

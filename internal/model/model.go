// Package model is the run's state machine: units, launches, and delivery,
// folded from the event log. Apply is the transition table; every append is
// checked against it, so an illegal transition is refused, not recorded.
package model

import (
	"errors"
	"fmt"
	"regexp"
	"strings"
	"time"

	"github.com/zo-ll/coordinator/internal/events"
)

type State string

const (
	Todo      State = "todo"
	Working   State = "working"
	Built     State = "built"
	Reviewing State = "reviewing"
	Passed    State = "passed"
	Handback  State = "handback"
	Stalled   State = "stalled"
	Approved  State = "approved"
	Merged    State = "merged"
	Blocked   State = "blocked"
	Dropped   State = "dropped"
)

// Terminal states never change again.
func (s State) Terminal() bool { return s == Merged || s == Dropped }

// MaxDeaths is how many deaths one round survives before the unit blocks.
const MaxDeaths = 2

// ErrDup marks a finished event whose slug already finished: idempotent.
var ErrDup = errors.New("duplicate")

var idRe = regexp.MustCompile(`^[A-Za-z0-9_-]+$`)

// Unit is one unit of work: a kind, a goal, and its current launch.
type Unit struct {
	ID, Kind, Goal, Risk string
	Deps                 []string
	State                State
	Round                int    // last round dispatched; 0 before the first
	Role                 string // role of the current or last launch
	Owes                 string // finish slug the live launch owes; "" when none
	PID                  int
	Worktree, Branch     string
	Base                 string // commit the unit's worktree started from
	WorkerBrief          string // raw worker brief of the current round
	Log                  string
	Dispatched           time.Time
	TimeboxS             int
	Deaths               map[int]int // per round
	PassState            string      // state hash the passing critic reviewed
	Evidence             *events.Evidence
	SHA                  string
}

// Launch is an open researcher launch (researchers belong to no unit).
type Launch struct {
	Slug, Report, Log string
	PID               int
	Dispatched        time.Time
	TimeboxS          int
}

// Run is the folded state of one run.
type Run struct {
	Units    map[string]*Unit
	Order    []string
	Research map[string]*Launch
	Finished map[string]bool // slugs that finished
	Wakes    []events.Event  // wake events, in order
	claimed  map[int]string  // wake seq -> batch
	acked    map[int]bool
	seq      int
}

func New() *Run {
	return &Run{
		Units: map[string]*Unit{}, Research: map[string]*Launch{}, Finished: map[string]bool{},
		claimed: map[int]string{}, acked: map[int]bool{},
	}
}

// Fold replays a log. Events that do not apply (a hand-edited log) are
// skipped; the log only ever receives events Apply accepted.
func Fold(log []events.Event) *Run {
	r := New()
	for _, e := range log {
		r.Apply(e)
	}
	return r
}

// LastSeq is the seq of the last event applied.
func (r *Run) LastSeq() int { return r.seq }

// Slug is the finish slug a launch owes: <id>.r<round>.<role>.
func Slug(id string, round int, role string) string {
	return fmt.Sprintf("%s.r%d.%s", id, round, role)
}

// Ready reports whether a todo unit's deps are all merged or dropped.
func (r *Run) Ready(u *Unit) bool {
	if u.State != Todo {
		return false
	}
	for _, d := range u.Deps {
		if dep := r.Units[d]; dep == nil || !dep.State.Terminal() {
			return false
		}
	}
	return true
}

// Done reports whether every unit is merged or dropped.
func (r *Run) Done() bool {
	for _, u := range r.Units {
		if !u.State.Terminal() {
			return false
		}
	}
	return true
}

// NextRound is the round the next dispatch of role must carry, or an error
// saying why the unit cannot take that dispatch now.
func (r *Run) NextRound(u *Unit, role string) (int, error) {
	switch {
	case role == "worker" && u.State == Todo:
		if !r.Ready(u) {
			return 0, fmt.Errorf("not ready (deps %s)", strings.Join(u.Deps, ","))
		}
		return u.Round + 1, nil
	case role == "worker" && u.State == Handback:
		return u.Round + 1, nil
	case role == "critic" && u.State == Built:
		return u.Round, nil
	case u.State == Stalled && u.Role == role:
		if u.Deaths[u.Round] >= MaxDeaths {
			return 0, fmt.Errorf("died %d times in round %d", MaxDeaths, u.Round)
		}
		return u.Round, nil
	}
	return 0, fmt.Errorf("cannot dispatch a %s from %s", role, u.State)
}

// Wake reports whether e wakes the coordinator.
func Wake(e events.Event) bool {
	switch e.Type {
	case "finished", "converted", "died", "approved", "rejected", "msg", "verify_failed":
		return true
	case "blocked":
		return e.By == "engine"
	}
	return false
}

// Undelivered returns wake events neither delivered nor claimed, in order.
func (r *Run) Undelivered() []events.Event {
	var out []events.Event
	for _, e := range r.Wakes {
		if _, claimed := r.claimed[e.Seq]; !r.acked[e.Seq] && !claimed {
			out = append(out, e)
		}
	}
	return out
}

// InFlight returns the seqs of claimed, unacknowledged wake events.
func (r *Run) InFlight() []int {
	var out []int
	for _, e := range r.Wakes {
		if _, claimed := r.claimed[e.Seq]; claimed && !r.acked[e.Seq] {
			out = append(out, e.Seq)
		}
	}
	return out
}

func refuse(format string, a ...any) error { return fmt.Errorf(format, a...) }

func (r *Run) unit(e events.Event) (*Unit, error) {
	u := r.Units[e.Unit]
	if u == nil {
		return nil, refuse("unknown unit %q", e.Unit)
	}
	return u, nil
}

// Owner finds the unit whose live launch owes slug.
func (r *Run) Owner(slug string) *Unit {
	for _, u := range r.Units {
		if u.Owes == slug && slug != "" {
			return u
		}
	}
	return nil
}

// Apply checks e against the transition table and, if legal, applies it.
// It never partially applies: a refused event changes nothing.
func (r *Run) Apply(e events.Event) error {
	if err := r.apply(e); err != nil {
		return err
	}
	if e.Seq > r.seq {
		r.seq = e.Seq
	}
	if Wake(e) {
		r.Wakes = append(r.Wakes, e)
	}
	return nil
}

func (r *Run) apply(e events.Event) error {
	ts, _ := time.Parse(time.RFC3339Nano, e.TS)
	switch e.Type {
	case "unit_added":
		if !idRe.MatchString(e.Unit) {
			return refuse("invalid id %q (use [A-Za-z0-9_-]+)", e.Unit)
		}
		if r.Units[e.Unit] != nil {
			return refuse("id already exists")
		}
		if e.Kind == "" {
			return refuse("kind is required")
		}
		for _, d := range e.Deps {
			if d == e.Unit || r.Units[d] == nil {
				return refuse("unknown dep %q", d)
			}
		}
		r.Units[e.Unit] = &Unit{ID: e.Unit, Kind: e.Kind, Goal: e.Goal, Risk: e.Risk, Deps: e.Deps, State: Todo, Deaths: map[int]int{}}
		r.Order = append(r.Order, e.Unit)

	case "dispatched":
		if e.Role == "researcher" {
			if e.Slug == "" || r.Research[e.Slug] != nil || r.Finished[e.Slug] {
				return refuse("research slug %q unusable", e.Slug)
			}
			r.Research[e.Slug] = &Launch{Slug: e.Slug, Report: e.Report, Log: e.Log, PID: e.PID, Dispatched: ts, TimeboxS: e.TimeboxS}
			return nil
		}
		u, err := r.unit(e)
		if err != nil {
			return err
		}
		if e.Role != "worker" && e.Role != "critic" {
			return refuse("unknown role %q", e.Role)
		}
		round, err := r.NextRound(u, e.Role)
		if err != nil {
			return err
		}
		if e.Round != round {
			return refuse("round %d, want %d", e.Round, round)
		}
		if want := Slug(u.ID, round, e.Role); e.Slug != want {
			return refuse("slug %q, want %q", e.Slug, want)
		}
		u.State = Working
		if e.Role == "critic" {
			u.State = Reviewing
		} else if e.Brief != "" {
			u.WorkerBrief = e.Brief
		}
		u.Round, u.Role, u.Owes, u.PID, u.Log = round, e.Role, e.Slug, e.PID, e.Log
		u.Dispatched, u.TimeboxS = ts, e.TimeboxS
		if e.Worktree != "" {
			u.Worktree, u.Branch, u.Base = e.Worktree, e.Branch, e.Base
		}

	case "finished":
		if r.Finished[e.Slug] {
			return ErrDup
		}
		if l := r.Research[e.Slug]; l != nil {
			if e.Result != "done" {
				return refuse("researcher result %q (want done)", e.Result)
			}
			delete(r.Research, e.Slug)
			r.Finished[e.Slug] = true
			return nil
		}
		u := r.Owner(e.Slug)
		if u == nil {
			return refuse("slug %q is not owed by any live launch", e.Slug)
		}
		if e.Unit != "" && e.Unit != u.ID {
			return refuse("slug %q belongs to %s", e.Slug, u.ID)
		}
		switch {
		case u.Role == "worker" && e.Result == "done":
			u.State = Built
		case u.Role == "worker" && e.Result == "partial":
			u.State = Handback
		case u.Role == "critic" && e.Result == "pass":
			u.State, u.PassState, u.Evidence = Passed, e.State, e.Evidence
		case u.Role == "critic" && e.Result == "handback":
			u.State = Handback
		default:
			return refuse("%s result %q", u.Role, e.Result)
		}
		u.Owes = ""
		r.Finished[e.Slug] = true

	case "converted":
		u, err := r.unit(e)
		if err != nil {
			return err
		}
		if u.State != Passed {
			return refuse("cannot convert from %s", u.State)
		}
		u.State, u.PassState, u.Evidence = Handback, "", nil

	case "died":
		if l := r.Research[e.Slug]; l != nil {
			if l.PID != e.PID {
				return refuse("pid %d is not %s's launch", e.PID, e.Slug)
			}
			delete(r.Research, e.Slug)
			return nil
		}
		u := r.Owner(e.Slug)
		if u == nil || u.PID != e.PID || (u.State != Working && u.State != Reviewing) {
			return refuse("no live launch %s with pid %d", e.Slug, e.PID)
		}
		u.State, u.Owes = Stalled, ""
		u.Deaths[u.Round]++

	case "approved":
		u, err := r.unit(e)
		if err != nil {
			return err
		}
		if u.State != Passed {
			return refuse("cannot approve from %s", u.State)
		}
		u.State = Approved

	case "rejected", "verify_failed":
		u, err := r.unit(e)
		if err != nil {
			return err
		}
		if u.State != Passed && u.State != Approved {
			return refuse("%s not allowed from %s", e.Type, u.State)
		}
		u.State, u.PassState, u.Evidence = Handback, "", nil

	case "merged":
		u, err := r.unit(e)
		if err != nil {
			return err
		}
		if u.State != Passed && u.State != Approved {
			return refuse("cannot merge from %s", u.State)
		}
		u.State, u.SHA = Merged, e.SHA

	case "blocked", "dropped":
		u, err := r.unit(e)
		if err != nil {
			return err
		}
		if u.State.Terminal() || (e.Type == "blocked" && u.State == Blocked) {
			return refuse("%s not allowed from %s", e.Type, u.State)
		}
		u.State, u.Owes = Blocked, ""
		if e.Type == "dropped" {
			u.State = Dropped
		}

	case "reopened":
		u, err := r.unit(e)
		if err != nil {
			return err
		}
		if u.State != Blocked {
			return refuse("cannot reopen from %s", u.State)
		}
		u.State = Todo

	case "msg":
		if e.Unit != "" && r.Units[e.Unit] == nil {
			return refuse("unknown unit %q", e.Unit)
		}

	case "claimed":
		for _, s := range e.Seqs {
			if _, claimed := r.claimed[s]; claimed || r.acked[s] {
				return refuse("seq %d already claimed or delivered", s)
			}
		}
		for _, s := range e.Seqs {
			r.claimed[s] = e.Batch
		}

	case "acked", "nacked":
		for _, s := range e.Seqs {
			if _, claimed := r.claimed[s]; !claimed {
				return refuse("seq %d is not claimed", s)
			}
		}
		for _, s := range e.Seqs {
			if e.Type == "acked" {
				r.acked[s] = true
			}
			delete(r.claimed, s)
		}

	default:
		return refuse("unknown event type %q", e.Type)
	}
	return nil
}

// Describe renders an event as one line for batches and the log view.
func Describe(e events.Event) string {
	switch e.Type {
	case "unit_added":
		return fmt.Sprintf("kind=%s deps=%s goal=%s", e.Kind, strings.Join(e.Deps, ","), e.Goal)
	case "dispatched":
		return fmt.Sprintf("%s pid=%d timebox=%ds", e.Slug, e.PID, e.TimeboxS)
	case "finished":
		s := fmt.Sprintf("%s %s", e.Slug, e.Result)
		if e.Evidence != nil {
			s += " evidence=" + e.Evidence.Level
		}
		if e.Report != "" {
			s += " report=" + e.Report
		}
		return s + " — " + e.Summary
	case "converted":
		return fmt.Sprintf("%s -> %s: %s", e.From, e.To, e.Reason)
	case "died":
		return fmt.Sprintf("%s pid=%d %s", e.Slug, e.PID, e.Reason)
	case "verify_failed":
		return fmt.Sprintf("%q exit=%d log=%s", e.Command, e.Exit, e.Log)
	case "merged":
		return "sha=" + e.SHA
	case "claimed", "acked", "nacked":
		return fmt.Sprintf("seqs=%v %s", e.Seqs, e.Batch)
	case "msg":
		return e.Text
	}
	return strings.TrimSpace(e.Reason + " " + e.Text)
}

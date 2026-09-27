// Package queue is the ping queue — ordered, de-duplicated, single-consumer —
// as a projection of the event log:
//
//	enqueued {slug, line}   a ping is published (once per slug, ever)
//	claimed  {batch, slugs} the consumer took these into a batch file
//	acked    {slugs}        the batch was delivered
//	nacked   {slugs}        the batch was returned to the queue
package queue

import (
	"fmt"
	"os"
	"strings"

	"github.com/zo-ll/coordinator/internal/events"
)

type Queue struct{ Log events.Log }

type state int

const (
	pending state = iota
	inflight
	done
)

type ping struct {
	seq   int
	slug  string
	line  string
	state state
}

// project folds the log into pings in publication order.
func project(log []events.Event) []*ping {
	var order []*ping
	by := map[string]*ping{}
	mark := func(slugs []string, s state) {
		for _, sl := range slugs {
			if p := by[sl]; p != nil {
				p.state = s
			}
		}
	}
	for _, e := range log {
		switch e.Type {
		case "enqueued":
			if by[e.Slug] == nil {
				p := &ping{seq: e.Seq, slug: e.Slug, line: e.Line}
				by[e.Slug] = p
				order = append(order, p)
			}
		case "claimed":
			mark(e.Slugs, inflight)
		case "acked":
			mark(e.Slugs, done)
		case "nacked":
			mark(e.Slugs, pending)
		}
	}
	return order
}

func (q Queue) pings() []*ping {
	log, _ := q.Log.Read()
	return project(log)
}

func in(ps []*ping, s state) []*ping {
	var out []*ping
	for _, p := range ps {
		if p.state == s {
			out = append(out, p)
		}
	}
	return out
}

func slugs(ps []*ping) []string {
	var out []string
	for _, p := range ps {
		out = append(out, p.slug)
	}
	return out
}

// Enqueue publishes line under slug. A slug already seen is a no-op (dup), so
// a retry can never double-publish.
func (q Queue) Enqueue(slug, line string) (seq int, dup bool, err error) {
	add, err := q.Log.Append(func(log []events.Event) ([]events.Event, error) {
		for _, p := range project(log) {
			if p.slug == slug {
				dup = true
				return nil, nil
			}
		}
		return []events.Event{{Type: "enqueued", Slug: slug, Line: line}}, nil
	})
	if err != nil || dup {
		return 0, dup, err
	}
	return add[0].Seq, false, nil
}

// Seen reports whether slug was ever enqueued.
func (q Queue) Seen(slug string) bool {
	for _, p := range q.pings() {
		if p.slug == slug {
			return true
		}
	}
	return false
}

type Item struct{ Seq, Slug string }

// List returns pending events in order.
func (q Queue) List() []Item {
	var items []Item
	for _, p := range in(q.pings(), pending) {
		items = append(items, Item{fmt.Sprintf("%012d", p.seq), p.slug})
	}
	return items
}

func (q Queue) Pending() bool { return len(in(q.pings(), pending)) > 0 }

func (q Queue) Depth() (p, i, d int) {
	ps := q.pings()
	return len(in(ps, pending)), len(in(ps, inflight)), len(in(ps, done))
}

// PopBatch claims every pending event, in order, into batch as
// "EVENT <slug> <line>" lines, and returns how many it claimed.
func (q Queue) PopBatch(batch string) (int, error) {
	n := 0
	_, err := q.Log.Append(func(log []events.Event) ([]events.Event, error) {
		ps := in(project(log), pending)
		var b strings.Builder
		for _, p := range ps {
			fmt.Fprintf(&b, "EVENT %s %s\n", p.slug, p.line)
		}
		// the batch file is written before the claim: a crash in between
		// leaves the events pending, so they are delivered, never lost
		if err := os.WriteFile(batch, []byte(b.String()), 0o644); err != nil {
			return nil, err
		}
		n = len(ps)
		if n == 0 {
			return nil, nil
		}
		return []events.Event{{Type: "claimed", Batch: batch, Slugs: slugs(ps)}}, nil
	})
	return n, err
}

func (q Queue) settle(typ string) error {
	_, err := q.Log.Append(func(log []events.Event) ([]events.Event, error) {
		ps := in(project(log), inflight)
		if len(ps) == 0 {
			return nil, nil
		}
		return []events.Event{{Type: typ, Slugs: slugs(ps)}}, nil
	})
	return err
}

// Ack marks claimed events delivered; Nack returns them to the queue.
func (q Queue) Ack() error  { return q.settle("acked") }
func (q Queue) Nack() error { return q.settle("nacked") }

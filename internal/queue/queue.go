// Package queue is the ping queue: ordered, de-duplicated, single-consumer.
//
// Layout under <root>/queue:
//
//	*.ping          pending events, named <seq>.<slug>.ping (seq sorts in arrival order)
//	.inflight/      events claimed by the consumer, awaiting ack
//	.done/          acknowledged events
//	.seen/<slug>    de-dup marker, created at enqueue
//	.seq, .seq.lock sequence counter; enqueue's check/alloc/publish/seen runs
//	                as ONE transaction under this lock
package queue

import (
	"fmt"
	"math/rand"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"

	"github.com/zo-ll/coordinator/internal/fsx"
)

type Queue struct {
	Dir      string
	inflight string
	done     string
	seen     string
}

// Open returns the queue under root, creating its directories.
func Open(root string) (*Queue, error) {
	d := filepath.Join(root, "queue")
	q := &Queue{Dir: d, inflight: filepath.Join(d, ".inflight"), done: filepath.Join(d, ".done"), seen: filepath.Join(d, ".seen")}
	for _, p := range []string{q.Dir, q.inflight, q.done, q.seen} {
		if err := os.MkdirAll(p, 0o755); err != nil {
			return nil, err
		}
	}
	return q, nil
}

// Enqueue publishes line under slug. A slug already seen is a no-op (dup),
// so a retry can never double-publish, and publication order equals sequence
// order: a crash before publish leaves a gap, never a reorder.
func (q *Queue) Enqueue(slug, line string) (file string, dup bool, err error) {
	lk, err := fsx.Lock(filepath.Join(q.Dir, ".seq.lock"))
	if err != nil {
		return "", false, err
	}
	defer lk.Close()
	if q.Seen(slug) {
		return "", true, nil
	}
	n := 0
	if b, err := os.ReadFile(filepath.Join(q.Dir, ".seq")); err == nil {
		if n, err = strconv.Atoi(strings.TrimSpace(string(b))); err != nil {
			return "", false, fmt.Errorf("corrupt sequence file: %w", err)
		}
	}
	n++
	if err := os.WriteFile(filepath.Join(q.Dir, ".seq"), []byte(fmt.Sprintf("%d\n", n)), 0o644); err != nil {
		return "", false, err
	}
	file = fmt.Sprintf("%012d.%s.ping", n, slug)
	tmp := filepath.Join(q.Dir, fmt.Sprintf(".tmp.%d.%d", os.Getpid(), rand.Int()))
	if err := os.WriteFile(tmp, []byte(line+"\n"), 0o644); err != nil {
		return "", false, err
	}
	if err := os.Rename(tmp, filepath.Join(q.Dir, file)); err != nil {
		return "", false, err
	}
	if err := os.WriteFile(filepath.Join(q.seen, slug), nil, 0o644); err != nil {
		return "", false, err
	}
	return file, false, nil
}

// Seen reports whether slug was ever enqueued.
func (q *Queue) Seen(slug string) bool {
	_, err := os.Stat(filepath.Join(q.seen, slug))
	return err == nil
}

func pings(dir string) []string {
	ents, _ := os.ReadDir(dir)
	var out []string
	for _, e := range ents {
		n := e.Name()
		if !strings.HasPrefix(n, ".") && strings.HasSuffix(n, ".ping") {
			out = append(out, filepath.Join(dir, n))
		}
	}
	sort.Strings(out)
	return out
}

type Item struct{ Seq, Slug, Path string }

// List returns pending events in order.
func (q *Queue) List() []Item {
	var items []Item
	for _, p := range pings(q.Dir) {
		b := strings.TrimSuffix(filepath.Base(p), ".ping")
		seq, slug, _ := strings.Cut(b, ".")
		items = append(items, Item{seq, slug, p})
	}
	return items
}

func (q *Queue) Pending() bool { return len(pings(q.Dir)) > 0 }

func (q *Queue) Depth() (pending, inflight, done int) {
	return len(pings(q.Dir)), len(pings(q.inflight)), len(pings(q.done))
}

// PopBatch claims every pending event, in order, into batch as
// "EVENT <slug> <line>" lines, and returns how many it claimed.
func (q *Queue) PopBatch(batch string) (int, error) {
	var b strings.Builder
	items := q.List()
	for _, it := range items {
		data, err := os.ReadFile(it.Path)
		if err != nil {
			return 0, err
		}
		line, _, _ := strings.Cut(string(data), "\n")
		fmt.Fprintf(&b, "EVENT %s %s\n", it.Slug, line)
	}
	if err := os.WriteFile(batch, []byte(b.String()), 0o644); err != nil {
		return 0, err
	}
	for _, it := range items {
		if err := os.Rename(it.Path, filepath.Join(q.inflight, filepath.Base(it.Path))); err != nil {
			return 0, err
		}
	}
	return len(items), nil
}

func moveAll(from, to string) error {
	for _, p := range pings(from) {
		if err := os.Rename(p, filepath.Join(to, filepath.Base(p))); err != nil {
			return err
		}
	}
	return nil
}

// Ack moves claimed events to done; Nack returns them to the queue.
func (q *Queue) Ack() error  { return moveAll(q.inflight, q.done) }
func (q *Queue) Nack() error { return moveAll(q.inflight, q.Dir) }

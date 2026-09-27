package main

import (
	"fmt"

	"github.com/zo-ll/coordinator/internal/queue"
)

// queue enqueue <slug> <line>   -> ENQUEUED <slug> <file> | DUP <slug>
// queue list                    -> "<seq> <slug> <file>" per pending event, in order
// queue pending                 -> exit 0 if any pending, else 1
// queue depth                   -> QUEUE pending=<n> inflight=<n> done=<n>
// queue pop-batch <batchfile>   -> claim all pending into <batchfile>, in order
// queue ack | nack              -> claimed events to done / back to the queue
func cmdQueue(args []string) int {
	q := queue.Queue{Log: eventLog()}
	switch arg(args, 0) {
	case "enqueue":
		slug, line := arg(args, 1), arg(args, 2)
		if slug == "" || line == "" {
			return fail(1, "queue: enqueue needs <slug> <line>")
		}
		seq, dup, err := q.Enqueue(slug, line)
		if err != nil {
			return fail(1, "queue: %v", err)
		}
		if dup {
			fmt.Printf("DUP %s\n", slug)
		} else {
			fmt.Printf("ENQUEUED %s seq=%d\n", slug, seq)
		}
	case "list":
		for _, it := range q.List() {
			fmt.Printf("%s %s\n", it.Seq, it.Slug)
		}
	case "pending":
		if !q.Pending() {
			return 1
		}
	case "depth":
		p, i, d := q.Depth()
		fmt.Printf("QUEUE pending=%d inflight=%d done=%d\n", p, i, d)
	case "pop-batch":
		batch := arg(args, 1)
		if batch == "" {
			return fail(1, "queue: pop-batch needs <batchfile>")
		}
		n, err := q.PopBatch(batch)
		if err != nil {
			return fail(1, "queue: %v", err)
		}
		fmt.Printf("POP n=%d batch=%s\n", n, batch)
		if n == 0 {
			return 1
		}
	case "ack":
		if err := q.Ack(); err != nil {
			return fail(1, "queue: %v", err)
		}
	case "nack":
		if err := q.Nack(); err != nil {
			return fail(1, "queue: %v", err)
		}
	default:
		return fail(2, "usage: queue.sh enqueue|list|pending|depth|pop-batch|ack|nack")
	}
	return 0
}

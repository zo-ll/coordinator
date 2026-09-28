# watch.awk: the event log as filo watch reads it. One record per line,
# tab-separated, first field the record type:
#   S ts                           first event (the run's start)
#   F ts sentence                  one feed line per event worth telling
#   R unit reason                  the latest reason a unit was sent back or blocked
#   C unit round level summary     the latest critic pass
#   W ts sentence                  the latest claimed batch: when, and what woke it
#   A ts                           the latest acknowledged batch (a finished turn)
#   P slug report ts summary       a finished research report
# Sentences carry watch's markup: \001 style \002 text \003.

function role_of(slug) { return slug ~ /\.critic$/ ? "critic" : slug ~ /\.worker$/ ? "worker" : "researcher" }
function feed(s) { print "F\t" int(E["ts"]) "\t" s; SENT[E["seq"]] = s }

{
    if (!parse()) next
    shown()
    t = E["type"]; u = E["unit"]
    if (!started) { print "S\t" int(E["ts"]); started = 1 }

    if (t == "unit_added") feed("coordinator added " m("b", u) m("d", " · " E["kind"]))
    else if (t == "dispatched") {
        if (E["role"] == "researcher") feed("researcher started " m("d", E["slug"]))
        else {
            RND[u] = E["round"]
            feed(E["role"] " started on " m("b", u) m("d", " · round " E["round"]))
        }
    }
    else if (t == "finished") {
        r = role_of(E["slug"])
        if (r == "researcher") {
            feed("research report ready: " E["summary"])
            print "P\t" E["slug"] "\t" E["report"] "\t" int(E["ts"]) "\t" E["summary"]
        } else if (r == "worker" && E["result"] == "done") feed("worker finished " m("b", u) m("d", " · round " RND[u]))
        else if (r == "worker") {
            feed(m("y", "↩") " worker handed " m("b", u) " back: " E["summary"])
            print "R\t" u "\t" E["summary"]
        } else if (E["result"] == "pass") {
            feed("critic passed " m("b", u) m("d", " · round " RND[u] " · " E["level"]))
            print "C\t" u "\t" RND[u] "\t" E["level"] "\t" E["summary"]
        } else {
            feed(m("y", "↩") " critic sent " m("b", u) " back: \"" E["summary"] "\"")
            print "R\t" u "\t" E["summary"]
        }
    }
    else if (t == "converted") {
        feed(m("y", "↩") " " m("b", u) "'s pass lacked evidence: " E["reason"])
        print "R\t" u "\t" E["reason"]
    }
    else if (t == "died") {
        r = role_of(E["slug"])
        why = E["reason"] == "timeout" ? "killed at its time limit" : "exited without finishing"
        feed(m("r", "✗") " " r " for " m("b", u == "" ? E["slug"] : u) " " why)
    }
    else if (t == "approved") feed("you approved " m("b", u) m("d", " · round " RND[u]))
    else if (t == "rejected") {
        if (E["by"] == "engine") { feed(m("r", "✗") " merge of " m("b", u) " conflicted, sent back"); print "R\t" u "\tthe merge conflicted with the base" }
        else { feed("you sent " m("b", u) " back: \"" E["text"] "\""); print "R\t" u "\t" E["text"] }
    }
    else if (t == "verify_failed") {
        feed(m("r", "✗") " merge re-ran the checks: " E["reason"] ", sent " m("b", u) " back")
        print "R\t" u "\tthe merge's checks failed (" E["command"] ")"
    }
    else if (t == "merged") feed("merged " m("b", u) m("d", " · " substr(E["sha"], 1, 7)))
    else if (t == "blocked") {
        if (E["by"] == "engine") feed(m("r", "✗") " engine blocked " m("b", u) ": " E["reason"])
        else feed(m("b", u) " blocked: " E["reason"])
        print "R\t" u "\t" E["reason"]
    }
    else if (t == "reopened") feed(m("b", u) " reopened")
    else if (t == "dropped") feed(m("b", u) " dropped" (E["reason"] == "" ? "" : ": " E["reason"]))
    else if (t == "msg") feed((u == "" ? "message to the coordinator" : "message about " m("b", u)) ": " E["text"])
    else if (t == "claimed") {
        split(E["seqs"], s, ",")
        CLTS = int(E["ts"]); CLS = s[1]
    }
    else if (t == "acked") ACK = int(E["ts"])
    else if (t == "nacked") feed(m("r", "✗") " a wake could not be delivered to the coordinator")
}

END {
    if (CLTS) print "W\t" CLTS "\t" (CLS in SENT ? SENT[CLS] : "")
    if (ACK) print "A\t" ACK
}

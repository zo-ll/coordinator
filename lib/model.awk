# model.awk: the run's state machine, folded from the event log.
#
# The log is one event per line: tab-separated key=value fields, starting
# with seq= and ending with a lone "." field. A line without the terminator
# (a torn write) is ignored. Repeated keys (ran=, flags=) are lists.
#
#   awk -f model.awk -v mode=<mode> [-v cand=FILE] [-v unit=ID] [-v slug=S] LOG [FILE]
#
# mode=check   apply LOG leniently, then the events in cand strictly: prints
#              OK, DUP (a finished slug that already finished), or
#              "REFUSED<TAB>unit<TAB>type<TAB>reason" and exits 1.
# mode=units   one line per unit (fields joined by \037, see END)
# mode=research, undelivered, inflight, owner, log, lastseq: see END.

BEGIN { FS = "\t"; US = "\037"; MAXD = 2 }

function parse(   i, p, k, v) {
    delete E
    if ($NF != "." || substr($1, 1, 4) != "seq=") return 0
    for (i = 1; i < NF; i++) {
        p = index($i, "="); if (!p) continue
        k = substr($i, 1, p - 1); v = substr($i, p + 1)
        if (k in E) E[k] = E[k] US v; else E[k] = v
    }
    return ("type" in E)
}

function terminal(s) { return s == "merged" || s == "dropped" }

function isready(id,   n, i, a) {
    if (ST[id] != "todo") return 0
    n = split(DEPS[id], a, ",")
    for (i = 1; i <= n; i++) {
        if (a[i] == "") continue
        if (!(a[i] in ST) || !terminal(ST[a[i]])) return 0
    }
    return 1
}

# nextround returns the round a dispatch of role must carry; NRERR says why not.
function nextround(id, role) {
    NRERR = ""
    if (role == "worker" && ST[id] == "todo") {
        if (!isready(id)) { NRERR = "not ready (deps " DEPS[id] ")"; return 0 }
        return ROUND[id] + 1
    }
    if (role == "worker" && ST[id] == "handback") return ROUND[id] + 1
    if (role == "critic" && ST[id] == "built") return ROUND[id]
    if (ST[id] == "stalled" && ROLE[id] == role) {
        if (DEATHS[id, ROUND[id]] >= MAXD) { NRERR = "died " MAXD " times in round " ROUND[id]; return 0 }
        return ROUND[id]
    }
    NRERR = "cannot dispatch a " role " from " ST[id]
    return 0
}

function owner(s,   id) {
    if (s == "") return ""
    for (id in ST) if (OWES[id] == s) return id
    return ""
}

function wake(t) {
    return t == "finished" || t == "converted" || t == "died" || t == "approved" || \
           t == "rejected" || t == "msg" || t == "verify_failed" || (t == "blocked" && E["by"] == "engine")
}

function q(s) { return "\"" s "\"" }

# apply checks E against the transition table and applies it: "" when legal,
# "DUP" for a repeated finish, else the reason. A refusal changes nothing.
function apply(   t, u, id, r, want, n, i, a, s, ns) {
    t = E["type"]; u = E["unit"]
    if (t == "unit_added") {
        if (u !~ /^[A-Za-z0-9_-]+$/) return "invalid id " q(u) " (use [A-Za-z0-9_-]+)"
        if (u in ST) return "id already exists"
        if (E["kind"] == "") return "kind is required"
        n = split(E["deps"], a, ",")
        for (i = 1; i <= n; i++) if (a[i] != "" && (a[i] == u || !(a[i] in ST))) return "unknown dep " q(a[i])
        ST[u] = "todo"; KIND[u] = E["kind"]; GOAL[u] = E["goal"]; RISK[u] = E["risk"]
        DEPS[u] = E["deps"]; ROUND[u] = 0; ORDER[++NU] = u
        return ""
    }
    if (t == "dispatched") {
        if (E["role"] == "researcher") {
            s = E["slug"]
            if (s == "" || (s in RPID) || (s in FIN)) return "research slug " q(s) " unusable"
            RPID[s] = E["pid"]; RREP[s] = E["report"]; RLOG[s] = E["log"]
            RDISP[s] = E["ts"]; RTB[s] = E["timebox"]; RORD[++NRS] = s
            return ""
        }
        if (!(u in ST)) return "unknown unit " q(u)
        if (E["role"] != "worker" && E["role"] != "critic") return "unknown role " q(E["role"])
        r = nextround(u, E["role"]); if (NRERR != "") return NRERR
        if (E["round"] + 0 != r) return "round " E["round"] ", want " r
        want = u ".r" r "." E["role"]
        if (E["slug"] != want) return "slug " q(E["slug"]) ", want " q(want)
        ST[u] = (E["role"] == "critic") ? "reviewing" : "working"
        if (E["role"] == "worker" && E["brief"] != "") WBRIEF[u] = E["brief"]
        ROUND[u] = r; ROLE[u] = E["role"]; OWES[u] = E["slug"]; PID[u] = E["pid"]
        LOGF[u] = E["log"]; DISP[u] = E["ts"]; TB[u] = E["timebox"]
        if (E["worktree"] != "") { WT[u] = E["worktree"]; BR[u] = E["branch"]; BASE[u] = E["base"] }
        return ""
    }
    if (t == "finished") {
        s = E["slug"]
        if (s in FIN) return "DUP"
        if (s in RPID) {
            if (E["result"] != "done") return "researcher result " q(E["result"]) " (want done)"
            delete RPID[s]; FIN[s] = 1
            return ""
        }
        id = owner(s)
        if (id == "") return "slug " q(s) " is not owed by any live launch"
        if (u != "" && u != id) return "slug " q(s) " belongs to " id
        ns = ""
        if (ROLE[id] == "worker" && E["result"] == "done") ns = "built"
        else if (ROLE[id] == "worker" && E["result"] == "partial") ns = "handback"
        else if (ROLE[id] == "critic" && E["result"] == "pass") ns = "passed"
        else if (ROLE[id] == "critic" && E["result"] == "handback") ns = "handback"
        else return ROLE[id] " result " q(E["result"])
        ST[id] = ns
        if (ns == "passed") { PASS[id] = E["state"]; EVL[id] = E["level"] }
        OWES[id] = ""; FIN[s] = 1
        return ""
    }
    if (t == "died") {
        s = E["slug"]
        if (s in RPID) {
            if (RPID[s] != E["pid"]) return "pid " E["pid"] " is not " s "'s launch"
            delete RPID[s]
            return ""
        }
        id = owner(s)
        if (id == "" || PID[id] != E["pid"] || (ST[id] != "working" && ST[id] != "reviewing"))
            return "no live launch " s " with pid " E["pid"]
        ST[id] = "stalled"; OWES[id] = ""; DEATHS[id, ROUND[id]]++
        return ""
    }
    if (t == "msg") {
        if (u != "" && !(u in ST)) return "unknown unit " q(u)
        return ""
    }
    if (t == "claimed") {
        n = split(E["seqs"], a, ",")
        for (i = 1; i <= n; i++) if ((a[i] in CL) || (a[i] in AK)) return "seq " a[i] " already claimed or delivered"
        for (i = 1; i <= n; i++) CL[a[i]] = E["batch"]
        return ""
    }
    if (t == "acked" || t == "nacked") {
        n = split(E["seqs"], a, ",")
        for (i = 1; i <= n; i++) if (!(a[i] in CL)) return "seq " a[i] " is not claimed"
        for (i = 1; i <= n; i++) { if (t == "acked") AK[a[i]] = 1; delete CL[a[i]] }
        return ""
    }
    if (t != "converted" && t != "approved" && t != "rejected" && t != "verify_failed" && \
        t != "merged" && t != "blocked" && t != "dropped" && t != "reopened")
        return "unknown event type " q(t)
    if (!(u in ST)) return "unknown unit " q(u)
    if (t == "converted") {
        if (ST[u] != "passed") return "cannot convert from " ST[u]
        ST[u] = "handback"; PASS[u] = ""; EVL[u] = ""
    } else if (t == "approved") {
        if (ST[u] != "passed") return "cannot approve from " ST[u]
        ST[u] = "approved"
    } else if (t == "rejected" || t == "verify_failed") {
        if (ST[u] != "passed" && ST[u] != "approved") return t " not allowed from " ST[u]
        ST[u] = "handback"; PASS[u] = ""; EVL[u] = ""
    } else if (t == "merged") {
        if (ST[u] != "passed" && ST[u] != "approved") return "cannot merge from " ST[u]
        ST[u] = "merged"; SHA[u] = E["sha"]
    } else if (t == "blocked" || t == "dropped") {
        if (terminal(ST[u]) || (t == "blocked" && ST[u] == "blocked")) return t " not allowed from " ST[u]
        ST[u] = (t == "dropped") ? "dropped" : "blocked"; OWES[u] = ""
    } else if (t == "reopened") {
        if (ST[u] != "blocked") return "cannot reopen from " ST[u]
        ST[u] = "todo"
    }
    return ""
}

function trimsp(s) { gsub(/^ +| +$/, "", s); return s }

# describe renders the event in E as one line (batches and the log view).
function describe(   t, s, lst) {
    t = E["type"]
    if (t == "unit_added") return "kind=" E["kind"] " deps=" E["deps"] " goal=" E["goal"]
    if (t == "dispatched") return E["slug"] " pid=" E["pid"] " timebox=" E["timebox"] "s"
    if (t == "finished") {
        s = E["slug"] " " E["result"]
        if (E["level"] != "") s = s " evidence=" E["level"]
        if (E["report"] != "") s = s " report=" E["report"]
        return s " — " E["summary"]
    }
    if (t == "converted") return E["from"] " -> " E["to"] ": " E["reason"]
    if (t == "died") return E["slug"] " pid=" E["pid"] " " E["reason"]
    if (t == "verify_failed") return q(E["command"]) " exit=" E["exit"] " log=" E["log"]
    if (t == "merged") return "sha=" E["sha"]
    if (t == "claimed" || t == "acked" || t == "nacked") return trimsp("seqs=" E["seqs"] " " E["batch"])
    if (t == "msg") return E["text"]
    return trimsp(E["reason"] " " E["text"])
}

function dash(s) { return s == "" ? "-" : s }

{
    if (!parse()) next
    if (mode == "log") {
        if (unit == "" || E["unit"] == unit)
            print E["seq"] " " E["type"] " " dash(E["unit"]) " " describe()
        next
    }
    LAST = E["seq"]
    if (cand != "" && FILENAME == cand) {
        err = apply()
        if (err == "DUP") { print "DUP"; stop = 1; exit 3 }
        if (err != "") { print "REFUSED\t" dash(E["unit"]) "\t" E["type"] "\t" err; stop = 1; exit 1 }
    } else if (apply() != "") next
    if (wake(E["type"])) {
        WK[++NW] = E["seq"]
        WLINE[E["seq"]] = E["seq"] " " dash(E["unit"]) " " E["type"] " " describe()
    }
}

END {
    if (stop) exit
    if (mode == "check") { print "OK"; exit }
    if (mode == "lastseq") { print LAST + 0; exit }
    if (mode == "units") {
        # id state kind round role owes pid worktree branch base workerbrief
        # log dispatched timebox deaths(current round) pass level sha ready deps risk goal
        for (i = 1; i <= NU; i++) {
            u = ORDER[i]
            print u US ST[u] US KIND[u] US ROUND[u] US ROLE[u] US OWES[u] US PID[u] US WT[u] US BR[u] US \
                  BASE[u] US WBRIEF[u] US LOGF[u] US DISP[u] US TB[u] US (DEATHS[u, ROUND[u]] + 0) US \
                  PASS[u] US EVL[u] US SHA[u] US isready(u) US DEPS[u] US RISK[u] US GOAL[u]
        }
        exit
    }
    if (mode == "research") {
        for (i = 1; i <= NRS; i++) { s = RORD[i]; if (s in RPID) print s US RPID[s] US RREP[s] US RLOG[s] US RDISP[s] US RTB[s] }
        exit
    }
    if (mode == "undelivered") {
        for (i = 1; i <= NW; i++) { s = WK[i]; if (!(s in AK) && !(s in CL)) print WLINE[s] }
        exit
    }
    if (mode == "inflight") {
        out = ""
        for (i = 1; i <= NW; i++) { s = WK[i]; if ((s in CL) && !(s in AK)) out = out (out == "" ? "" : ",") s }
        print out
        exit
    }
    if (mode == "owner") {
        # a live launch owing slug: "unit" US id, "research" US slug, "finished", or "none"
        if (slug in FIN) { print "finished"; exit }
        if (slug in RPID) { print "research" US slug US RREP[slug]; exit }
        id = owner(slug)
        print (id == "" ? "none" : "unit" US id)
        exit
    }
}

# events.awk: the event log's line format, for every awk that reads it
# (awk -f lib/events.awk -f <program>).
#
# One event per line: tab-separated key=value fields, starting with seq= and
# ending with a lone "." field; a line without the terminator is a torn write.
# A repeated key (ran=, flags=) is a list, joined by \037.

BEGIN { FS = "\t"; US = "\037" }

# parse: the line's fields into E; 0 when the line is not a complete event
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

# q: a field as display text, its control characters spaces (lists keep \037)
function q(s) { gsub(/[\001-\036]/, " ", s); return s }
# m: watch's markup, \001 style \002 text \003
function m(k, s) { return "\001" k "\002" s "\003" }

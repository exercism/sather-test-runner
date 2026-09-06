#!/usr/bin/gawk -f
# Convert the harness's record stream into JSON, one object per test.
#
# exercism_test.sa writes machine-readable records to stderr, one per line:
#
#     ##EX|<name>|<pass|fail>|<expected>|<actual>|##      one per test
#     ##EXDONE|<total>|<failures>|##                      once, from finish
#
# Inside a field, '\' is written '\\', '|' is '\p', newline is '\n' and
# carriage return is '\r', so a raw '|' can only be a field separator and a
# record always fits on one line.
#
# Reads the captured stderr on stdin; anything that is not a record is
# ignored. Writes one JSON object per test to stdout, for jq --slurpfile.
# When SUMMARY names a file, also writes a single JSON object
# {"tests":N,"failures":N,"finished":B} there, so the caller can tell a
# suite that ran to completion from one that died partway through.
#
# Run under LC_ALL=C: fields are treated as bytes, whatever the solution
# printed.

BEGIN {
    SUMMARY = SUMMARY ""    # initialise without disturbing a -v value
    tests = 0
    failures = 0
    finished = 0
    for (i = 0; i < 256; i++) BYTE[sprintf("%c", i)] = i
}

# Undo the harness escaping in one pass. Sequential gsub calls would be
# wrong: in "\\p" the backslash is data and the 'p' must stay a 'p'.
function unescape(s,        out, pos, c) {
    out = ""
    pos = 1
    while (pos <= length(s)) {
        c = substr(s, pos, 1)
        if (c != "\\" || pos == length(s)) {
            out = out c
            pos++
            continue
        }
        c = substr(s, pos + 1, 1)
        if      (c == "p") out = out "|"
        else if (c == "n") out = out "\n"
        else if (c == "r") out = out "\r"
        else if (c == "\\") out = out "\\"
        else                out = out "\\" c    # not an escape we emit; keep
        pos += 2
    }
    return out
}

function json_string(s,        out, pos, c, code) {
    out = "\""
    for (pos = 1; pos <= length(s); pos++) {
        c = substr(s, pos, 1)
        code = BYTE[c]
        if      (c == "\"" || c == "\\") out = out "\\" c
        else if (c == "\n")              out = out "\\n"
        else if (c == "\r")              out = out "\\r"
        else if (c == "\t")              out = out "\\t"
        else if (code < 32)              out = out sprintf("\\u%04x", code)
        else                             out = out c
    }
    return out "\""
}

/^##EXDONE\|/ {
    finished = 1
    next
}

# A well-formed record ends in "|##"; a line that merely starts like one is
# ignored rather than half-parsed.
/^##EX\|/ && /\|##$/ {
    n = split(substr($0, 6, length($0) - 8), field, "|")
    if (n < 4) next
    name   = unescape(field[1])
    status = field[2]
    tests++
    if (status == "pass") {
        print "{\"name\":" json_string(name) ",\"status\":\"pass\"}"
    } else {
        failures++
        message = "expected: " unescape(field[3]) "\nactual:   " unescape(field[4])
        print "{\"name\":" json_string(name) ",\"status\":\"fail\"," \
              "\"message\":" json_string(message) "}"
    }
}

END {
    if (SUMMARY != "")
        printf "{\"tests\":%d,\"failures\":%d,\"finished\":%s}\n", \
               tests, failures, (finished ? "true" : "false") > SUMMARY
}

#!/usr/bin/gawk -f

# Synopsis:
# Read a Sather test file and list its tests statically, in file order, as
# one JSON object per line: {"name", "test_code", "task_id"?}.
#
# The running program can only report the tests it reached, and never its
# own source, so this is where test_code comes from and how tests that never
# ran (after a crash) are still known by name.
#
# The test file is read as a sequence of statements in `main`. A statement
# at block depth 0 that contains a call to test(...) closes a test; it and
# the statements gathered since the previous test (setup such as a loop
# building a value, or the variable a protect block checks) form that test's
# test_code. A protect ... when ... end block with a test( call in each arm
# is therefore one test, as it is at runtime. The name is the first string
# literal passed to test(.
#
# A comment line of the form "-- Task N" sets the task_id of the tests that
# follow it. Without one, task_id is left out.
#
# Whole-line comments and blank lines are left out of test_code; class_name
# is not part of any test. The scan stops at `finish`.

# code_of(line): the line with string and character literals blanked and any
# -- comment removed, so that keywords and punctuation can be counted.
function code_of(line,    out, i, n, c, q) {
    out = ""
    n = length(line)
    for (i = 1; i <= n; i++) {
        c = substr(line, i, 1)
        if (c == "\"" || c == "'") {
            q = c
            out = out " "
            for (i++; i <= n; i++) {
                c = substr(line, i, 1)
                if (c == "\\") { i++; continue }
                if (c == q) break
            }
            out = out " "
            continue
        }
        if (c == "-" && substr(line, i + 1, 1) == "-") break
        out = out c
    }
    return out
}

# first_test_name(text): the first string literal after "test(", unescaped,
# or "" when there is none.
function first_test_name(text,    start, rest, out, i, n, c, e) {
    if (!match(text, /(^|[^A-Za-z0-9_])test[ \t]*\([ \t\n]*"/)) return ""
    rest = substr(text, RSTART + RLENGTH)
    out = ""
    n = length(rest)
    for (i = 1; i <= n; i++) {
        c = substr(rest, i, 1)
        if (c == "\"") return out
        if (c == "\\") {
            e = substr(rest, ++i, 1)
            if (e == "n") out = out "\n"
            else if (e == "t") out = out "\t"
            else if (e == "r") out = out "\r"
            else out = out e
            continue
        }
        out = out c
    }
    return ""
}

function json_string(s,    out, i, n, c, code) {
    out = "\""
    n = length(s)
    for (i = 1; i <= n; i++) {
        c = substr(s, i, 1)
        code = ord[c]
        if      (c == "\"")              out = out "\\\""
        else if (c == "\\")              out = out "\\\\"
        else if (c == "\n")              out = out "\\n"
        else if (c == "\r")              out = out "\\r"
        else if (c == "\t")              out = out "\\t"
        else if (code < 32 || code == 127) out = out sprintf("\\u%04x", code)
        else                             out = out c
    }
    return out "\""
}

function reset_chunk() {
    n_lines = 0
    has_test = 0
}

function emit_chunk(    i, indent, min_indent, text, name) {
    min_indent = -1
    for (i = 1; i <= n_lines; i++) {
        match(chunk[i], /^[ ]*/)
        if (min_indent < 0 || RLENGTH < min_indent) min_indent = RLENGTH
    }
    text = ""
    for (i = 1; i <= n_lines; i++)
        text = text (i > 1 ? "\n" : "") substr(chunk[i], min_indent + 1)
    name = first_test_name(text)
    if (name != "") {
        printf "{\"name\":%s,\"test_code\":%s", json_string(name), json_string(text)
        if (task > 0) printf ",\"task_id\":%d", task
        print "}"
    }
    reset_chunk()
}

BEGIN {
    for (i = 0; i < 256; i++) ord[sprintf("%c", i)] = i
    in_main = 0
    task = 0
    depth = 0
    parens = 0
    reset_chunk()
}

{ sub(/\r$/, "") }

!in_main {
    if ($0 ~ /^[ \t]*main[ \t]+is([ \t]|$)/) in_main = 1
    next
}

/^[ \t]*--[ \t]*Task[ \t]+[0-9]+[ \t]*$/ {
    match($0, /[0-9]+/)
    task = substr($0, RSTART, RLENGTH) + 0
    next
}

/^[ \t]*(--.*)?$/ { next }

{
    code = code_of($0)

    if (depth == 0 && parens == 0 && n_lines == 0) {
        if (code ~ /^[ \t]*finish[ \t]*;?[ \t]*$/) exit
        if (code ~ /^[ \t]*class_name[ \t]*\(/) next
    }

    gsub(/\t/, "   ")
    chunk[++n_lines] = $0
    if (code ~ /(^|[^A-Za-z0-9_])test[ \t]*\(/) has_test = 1

    # Block depth from keywords, statement continuation from parentheses.
    nw = split(code, word, /[^A-Za-z0-9_]+/)
    for (w = 1; w <= nw; w++) {
        if (word[w] ~ /^(loop|protect|if|case|typecase)$/) depth++
        else if (word[w] == "end") depth--
    }
    parens += gsub(/\(/, "(", code) - gsub(/\)/, ")", code)

    if (depth <= 0 && parens <= 0 && code ~ /;[ \t]*$/) {
        depth = 0
        parens = 0
        if (has_test) emit_chunk()
    }
}

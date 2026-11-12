#!/usr/bin/env bash

# Synopsis:
# Run the test runner on a solution.

# Arguments:
# $1: exercise slug
# $2: path to solution folder
# $3: path to output directory

# Output:
# Writes the test results to a results.json file in the passed-in output
# directory. The test results are formatted according to the specifications at
# https://github.com/exercism/docs/blob/main/building/tooling/test-runners/interface.md

# Example:
# ./bin/run.sh two-fer path/to/solution/folder/ path/to/output/directory/

set -uo pipefail

# The platform reads results.json as an unprivileged user; this script runs
# as root in the container. Nothing here may create root-only files.
umask 022

# Byte semantics for gawk and stable behaviour everywhere else, whatever
# bytes the solution decides to print.
export LC_ALL=C

: "${SATHER_HOME:=/opt/sather}"
export SATHER_HOME

# Wall-clock limits, in seconds.
: "${COMPILE_TIMEOUT:=60}"
: "${RUN_TIMEOUT:=15}"

# Cap on the message field of results.json.
: "${MAX_MESSAGE_BYTES:=65535}"

# Cap on any single file the test program writes, enforced with ulimit so a
# print loop hits a limit rather than filling the tmpfs.
: "${MAX_OUTPUT_BYTES:=8388608}"

usage() {
    echo "usage: $0 exercise-slug path/to/solution/folder/ path/to/output/directory/" >&2
    exit 1
}

[[ -z "${1:-}" || -z "${2:-}" || -z "${3:-}" ]] && usage

slug="$1"
solution_dir=$(realpath "${2%/}")
output_dir=$(realpath "${3%/}")

[[ -d "${solution_dir}" ]] || usage
mkdir -p "${output_dir}"

results_file="${output_dir}/results.json"
snake_slug="${slug//-/_}"

# Assigned before die can run, so it can always expand them; build_dir is
# created in main.
work_dir=""
build_dir=""

# A fault in the runner itself is still reported through results.json when
# possible: an empty output directory tells the platform nothing.
die() {
    echo "$*" >&2
    if [[ -n "${work_dir}" ]]; then
        printf '%s\n' "$*" > "${work_dir}/died"
        finish_with error "${work_dir}/died"
    fi
    exit 1
}

# capped <file>: copy at most MAX_MESSAGE_BYTES of a capture to stdout,
# noting the cut. Callers redirect this into a file, which is what jq's
# --rawfile reads to build the message.
capped() {
    local file="$1"
    head -c "${MAX_MESSAGE_BYTES}" "${file}"
    if (( $(wc -c < "${file}") > MAX_MESSAGE_BYTES )); then
        printf '\n[output truncated]\n'
    fi
}

# finish_with <pass|fail|error> <message-file>: results.json without
# per-test entries, for everything that stops before tests can be reported.
finish_with() {
    local status="$1" message_file="$2"
    if ! grep -q '[^[:space:]]' "${message_file}" 2>/dev/null; then
        printf 'The test run produced no output.\n' > "${message_file}"
    fi
    capped "${message_file}" > "${message_file}.capped"
    jq -n --arg status "${status}" --rawfile message "${message_file}.capped" \
        '{version: 3, status: $status,
          message: ($message | sub("^\n+"; "") | sub("\\s+$"; ""))}' \
        > "${results_file}"
    echo "${slug}: done"
}

work_dir=$(mktemp -d) || die "Cannot create a work directory."
trap 'rm -rf "${work_dir}" "${build_dir}"' EXIT

runner_dir=$(dirname "$(realpath "$0")")
records_to_json="${runner_dir}/records-to-json.awk"
extract_tests="${runner_dir}/extract-tests.awk"
bundled_harness="${runner_dir}/../harness/exercism_test.sa"
for runner_file in "${records_to_json}" "${extract_tests}" "${bundled_harness}"; do
    [[ -f "${runner_file}" ]] || die "The test runner is missing ${runner_file}."
done

# The compiled test program has to run from the build directory, and in
# production the container filesystem is read-only with /tmp a noexec
# tmpfs, so writability alone is not enough. Prove execution with a probe.
allows_exec() {
    local probe
    probe=$(mktemp "$1/.exec-probe.XXXXXX" 2>/dev/null) || return 1
    printf '#!/bin/sh\nexit 0\n' > "${probe}"
    chmod +x "${probe}"
    "${probe}" 2>/dev/null
    local verdict=$?
    rm -f "${probe}"
    return "${verdict}"
}

main() {
    echo "${slug}: testing..."

    # Building needs a directory that is writable and executable. The work
    # directory (under /tmp) is preferred; the output and solution
    # directories are bind mounts that stay writable in production, so one
    # of them takes over when /tmp is mounted noexec.
    local candidate
    for candidate in "${work_dir}" "${output_dir}" "${solution_dir}"; do
        if allows_exec "${candidate}"; then
            build_dir=$(mktemp -d "${candidate}/.sather-build.XXXXXX") || continue
            break
        fi
    done
    if [[ -z "${build_dir}" || ! -d "${build_dir}" ]]; then
        printf 'No writable directory that permits execution was found.\nTried /tmp, the output directory and the solution directory.\n' \
            > "${work_dir}/message"
        finish_with error "${work_dir}/message"
        return 0
    fi

    # Stage a copy: sacomp writes generated C and the executable next to
    # its output name, and a student's solution directory is not ours to
    # build in. The copy also brings any data files the exercise ships.
    # tar rather than cp: when the build directory had to be placed inside
    # the solution or output directory (the mounts may be the only
    # executable locations), the copy must not descend into itself, and
    # anything a torn-down earlier run left behind must not come along.
    tar -C "${solution_dir}" \
        --exclude='./.sather-build.*' --exclude='./.tests*' \
        -cf - . | tar -C "${build_dir}" -xf - \
        || die "Cannot stage the solution."
    cd "${build_dir}" || die "Cannot enter the build directory."

    # The track config names the test file: "%{snake_slug}_test.sa".
    local tests_file="${snake_slug}_test.sa"
    if [[ ! -f "${tests_file}" ]]; then
        printf 'The test file %s was not found.\n' "${tests_file}" \
            > "${work_dir}/message"
        finish_with error "${work_dir}/message"
        return 0
    fi

    # The tests as the test file lists them: test_code and task_id come
    # from here, and so do the names of tests a crash kept from running.
    # A file the extractor cannot read yields an empty list, and the
    # results then fall back to what the program reported.
    gawk -f "${extract_tests}" < "${tests_file}" > "${work_dir}/static.jsonl" \
        2>/dev/null || : > "${work_dir}/static.jsonl"

    # The harness ships with each exercise as an editor file; the copy in
    # the image covers a solution assembled without one.
    if [[ ! -f exercism_test.sa ]]; then
        cp "${bundled_harness}" exercism_test.sa || die "Cannot stage the harness."
    fi

    # The main class is named after the test file, so the two cannot
    # disagree: two_fer_test.sa tests class TWO_FER_TEST.
    local main_class
    main_class=$(basename "${tests_file}" .sa | tr '[:lower:]' '[:upper:]')

    # The output name is dot-prefixed so no staged solution file can
    # collide with it: the stage copied what * does not match.
    rm -rf ./.tests ./.tests.code

    # Compile every Sather file in the solution, with runtime checking on:
    # a student's failed assertion or void access should surface as a
    # named Sather error, not undefined behaviour. The glob is deliberately
    # bare: sacomp repeats a file name as given in its diagnostics, and a
    # student should read "two_fer.sa:6:1", not "./two_fer.sa:6:1".
    # shellcheck disable=SC2035 # sacomp rejects --, and slug-derived names cannot start with -
    timeout "${COMPILE_TIMEOUT}" sacomp -chk *.sa \
        -main "${main_class}" -o .tests > "${work_dir}/compile" 2>&1
    local compile_status=$?

    # sacomp can report failure through its output alone, so test for the
    # executable rather than trusting the exit status.
    if [[ ! -x ./.tests ]]; then
        if (( compile_status == 124 )); then
            printf '\nCompilation timed out after %d seconds.\n' \
                "${COMPILE_TIMEOUT}" >> "${work_dir}/compile"
        fi
        finish_with error "${work_dir}/compile"
        return 0
    fi

    # Run with the two output streams apart: the harness writes records to
    # stderr and the human-readable report to stdout, and only stderr is
    # parsed, so a solution printing record-shaped text with #OUT cannot
    # manufacture results.
    (
        ulimit -f $(( MAX_OUTPUT_BYTES / 512 )) 2>/dev/null
        timeout "${RUN_TIMEOUT}" ./.tests \
            > "${work_dir}/report" 2> "${work_dir}/records"
    )
    if (( $? == 124 )); then
        printf '\nThe tests timed out after %d seconds.\n' "${RUN_TIMEOUT}" \
            >> "${work_dir}/report"
    fi

    gawk -v SUMMARY="${work_dir}/summary" -f "${records_to_json}" \
        < "${work_dir}/records" > "${work_dir}/tests.jsonl"

    # Anything on stderr that is not a record is part of what the student
    # should see, alongside the report.
    grep -v '^##EX' "${work_dir}/records" >> "${work_dir}/report" || true

    local n_tests=0 finished=false
    if [[ -s "${work_dir}/summary" ]]; then
        read -r n_tests _ finished < <(
            jq -r '"\(.tests) \(.failures) \(.finished)"' "${work_dir}/summary")
    fi

    if (( n_tests == 0 )); then
        # The program never reported a test: it died first, or was never a
        # test program to begin with.
        finish_with error "${work_dir}/report"
        return 0
    fi

    capped "${work_dir}/report" > "${work_dir}/report.capped"
    if ! grep -q '[^[:space:]]' "${work_dir}/report.capped"; then
        printf 'The test program produced no output.\n' > "${work_dir}/report.capped"
    fi

    # Line the reported tests up against the test file. When the reported
    # names are exactly the first tests of the file, each gains its
    # test_code and task_id; if the run stopped early, the first test the
    # program never reported is the one it stopped in, and the rest never
    # ran. When they do not line up (a name built at runtime, a file the
    # extractor misread), the reported tests stand alone, as they are.
    # Field order is fixed so the output is stable.
    jq -n --argjson finished "${finished}" \
          --rawfile report "${work_dir}/report.capped" \
          --slurpfile static "${work_dir}/static.jsonl" \
          --slurpfile tests "${work_dir}/tests.jsonl" '
        ($report | sub("^\n+"; "") | sub("\\s+$"; "")) as $report
        | ($tests | length) as $ran
        | ($static | length) as $listed
        | (($static[0:$ran] | map(.name)) == ($tests | map(.name))
           and (if $finished then $listed == $ran else $listed > $ran end))
          as $aligned
        | if $aligned then
            [ $static | to_entries[] | .key as $i | .value as $s
              | (if $i < $ran then $tests[$i]
                 elif $i == $ran then
                   {name: $s.name, status: "error",
                    message: ("The test program stopped while running this test; later tests did not run.\n\n" + $report)}
                 else
                   {name: $s.name, status: "error",
                    message: "Not run: an earlier test stopped the test program."}
                 end)
              | {name, status} + (if .message then {message} else {} end)
                + {test_code: $s.test_code}
                + (if $s.task_id then {task_id: $s.task_id} else {} end) ]
            | {version: 3,
               status: (if all(.[]; .status == "pass") then "pass" else "fail" end),
               tests: .}
          elif $finished then
            {version: 3,
             status: (if all($tests[]; .status == "pass") then "pass" else "fail" end),
             tests: $tests}
          else
            # Tests were reported but the terminating record never came:
            # the run stopped early, and silence about that would read as
            # success.
            {version: 3, status: "fail",
             message: ("The test program stopped before the suite finished; later tests did not run.\n\n"
                       + $report),
             tests: $tests}
          end' \
        > "${results_file}" || die "Cannot encode the test results."
    echo "${slug}: done"
}

main "$@"

# Invoked with mode (cleanup|install), harness, archive path, sha256, and the
# embedded Python program. Library skills are best-effort: never fail the job.
if ! command -v python3 >/dev/null 2>&1; then
    [ "$1" = install ] && [ -n "$3" ] && echo 'Library skills: skipped (python3 is not installed on this machine).' >&2
    exit 0
fi
python3 -c "$5" "$1" "$2" "$3" "$4" || echo 'Library skills: preparation failed; continuing without them.' >&2
exit 0

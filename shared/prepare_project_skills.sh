# Invoked with source, harness, embedded Python program, optional cwd.
# Keep projects without skills working even when Python is not installed.
if [ -n "${4:-}" ]; then
    cd -- "$4" || exit 78
fi
need_skills=0
if [ -n "$1" ]; then
    for skill in "$1"/skills/*/SKILL.md; do
        if [ -f "$skill" ] || [ -L "$skill" ]; then need_skills=1; break; fi
    done
fi
skill_parent="$PWD"
while :; do
    if [ -e "$skill_parent/.orb-project-skills.json" ] || [ -L "$skill_parent/.orb-project-skills.json" ]; then
        need_skills=1
        break
    fi
    [ "$skill_parent" = / ] && break
    skill_parent="${skill_parent%/*}"
    [ -n "$skill_parent" ] || skill_parent=/
done
[ "$need_skills" = 0 ] && exit 0
if ! command -v python3 >/dev/null 2>&1; then
    echo 'Prepare project skills requires Python 3. Install it on the execution machine and retry; your draft is kept.' >&2
    exit 78
fi
exec python3 -c "$3" "$1" "$2"

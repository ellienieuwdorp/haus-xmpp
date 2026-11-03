#!/usr/bin/env python3
"""SwiftLint with a ratchet baseline.

    python3 -I Tools/lint-ratchet.py [--write | --shrink] [FILE...]

Runs SwiftLint from the repository root and fails on any violation that .swiftlint-baseline.json does not list.
A baselined size or complexity violation passes while its number stays at or below the recorded one, so a long
function may shrink but not grow. (SwiftLint's own --baseline matches the reason text, which contains the number,
so it fails a function that got shorter.) Without FILEs it lints the paths .swiftlint.yml includes.

--write records every current violation; run it through `Tools/check.sh baseline`. --shrink drops or lowers the
entries of the checked files that no longer need them and never adds one.
"""
import json
import os
import re
import subprocess
import sys
from collections import defaultdict

BASELINE = ".swiftlint-baseline.json"
# Keep in step with SWIFTLINT_VERSION in .github/workflows/checks.yml: other versions report different violations.
PINNED_VERSION = "0.65.1"
MEASURED = {"file_length", "type_body_length", "function_body_length", "closure_body_length",
            "cyclomatic_complexity", "function_parameter_count"}
CONFIG_ERRORS = ("Cannot parse", "Invalid configuration", "invalid key", "not a valid rule", "Could not read")


def swiftlint(*args):
    try:
        return subprocess.run(["swiftlint", *args], capture_output=True, text=True)
    except FileNotFoundError:
        sys.exit(f"swiftlint is not installed; install SwiftLint {PINNED_VERSION} (brew install swiftlint)")


def lint(files):
    result = swiftlint("lint", "--quiet", "--force-exclude", "--reporter", "json", *files)
    broken = [line for line in result.stderr.splitlines() if any(e in line for e in CONFIG_ERRORS)]
    if broken or (result.returncode not in (0, 2) and not result.stdout.strip()):
        sys.exit("SwiftLint failed or its configuration is broken:\n"
                 + "\n".join(broken or result.stderr.splitlines()[:20]))
    return json.loads(result.stdout or "[]")


def relative(path):
    return os.path.relpath(os.path.realpath(path), os.path.realpath("."))


def keyed(violations):
    """(violation, path, rule, line text, measured value) for each violation."""
    lines = {}
    out = []
    for v in violations:
        path, rule = relative(v["file"]), v["rule_id"]
        text = ""
        if rule != "file_length":
            if path not in lines:
                with open(path, encoding="utf-8") as f:
                    lines[path] = f.read().split("\n")
            number = v.get("line") or 1
            text = lines[path][number - 1].strip() if 0 < number <= len(lines[path]) else ""
        value = int(re.findall(r"\d+", v["reason"])[-1]) if rule in MEASURED else 0
        out.append((v, path, rule, text, value))
    return out


def save(entries):
    with open(BASELINE, "w", encoding="utf-8") as f:
        json.dump(entries, f, indent=1, sort_keys=True)
        f.write("\n")


def write(violations):
    version = swiftlint("version").stdout.strip()
    if version != PINNED_VERSION:
        sys.exit(f"the baseline must be written by SwiftLint {PINNED_VERSION}, the version CI runs; this is {version}")
    out = defaultdict(lambda: defaultdict(list))
    for _, path, rule, text, value in keyed(violations):
        out[path][rule].append([text, value])
    save({p: {r: sorted(e) for r, e in rules.items()} for p, rules in out.items()})
    print(f"wrote {BASELINE}: {len(violations)} violations in {len(out)} files")


def compare(violations, baseline):
    pool = {p: {r: [list(e) for e in entries] for r, entries in rules.items()} for p, rules in baseline.items()}
    new, kept = [], defaultdict(lambda: defaultdict(list))
    for v, path, rule, text, value in keyed(violations):
        entries = pool.get(path, {}).get(rule, [])
        same = [e for e in entries if e[0] == text]
        match = next((e for e in same if value <= e[1]), None)
        if match:
            entries.remove(match)
            kept[path][rule].append([text, value])
            continue
        hint = ""
        if same:
            # Still over its allowance: keep the entry, so --shrink cannot drop it while it fails.
            entries.remove(same[0])
            kept[path][rule].append(same[0])
            hint = f" (the baseline allows {same[0][1]}; get back to {same[0][1]} or lower)"
        new.append(f"{path}:{v.get('line') or 1}:{v.get('character') or 1}: error: {v['reason']}{hint} ({rule})")
    return new, kept, pool


def main():
    args = sys.argv[1:]
    files = [relative(a) for a in args if not a.startswith("--")]
    violations = lint(files)
    if "--write" in args:
        write(violations)
        return 0
    try:
        with open(BASELINE, encoding="utf-8") as f:
            baseline = json.load(f)
    except FileNotFoundError:
        baseline = {}
    new, kept, pool = compare(violations, baseline)
    checked = set(files) if files else set(baseline) | set(kept)
    fixed = sum(len(e) for p, rules in pool.items() if p in checked for e in rules.values())
    if "--shrink" in args:
        nxt = {p: rules for p, rules in baseline.items() if p not in checked}
        nxt.update({p: {r: sorted(e) for r, e in rules.items()} for p, rules in kept.items()})
        if nxt != baseline:
            save(nxt)
    elif fixed:
        print(f"note: {fixed} baselined SwiftLint violations are gone; lock that in with Tools/check.sh shrink")
    for line in new:
        print(line)
    if new:
        print(f"\n{len(new)} SwiftLint violation(s) the baseline does not cover. Change the code; a disable needs"
              " a reason: // swiftlint:disable:next rule_id - why the rule does not apply")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

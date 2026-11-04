#!/usr/bin/env python3
"""Fail if the checks were loosened since BASE: python3 -I Tools/baseline-guard.py BASE [HEAD]

Baselines only ever lose entries: a new file, rule or entry, or a larger recorded size, fails. So does a new line
in the crypto import allowlist, any change to the checks themselves (.swiftlint.yml, Tools/, the Checks workflow)
once BASE has them. In project.yml, the Xcode project, Config/*.xcconfig and Packages/*/Package.swift, so does a
strict compiler setting line (warnings as errors, upcoming features, OTHER_SWIFT_FLAGS) removed or changed, a
target's `swiftSettings: swiftSettings` dropped, or a line added that undoes strictness: -no-warnings-as-errors,
-Wwarning, -disable-upcoming-feature, SWIFT_SUPPRESS_WARNINGS or GCC_WARN_INHIBIT_ALL_WARNINGS set to YES, or a
warning group or all warnings treated `as: .warning`. A renamed file keeps its entries under the new path. A person who
agrees with the change labels the pull request `baseline-growth-approved`, saying why in the description. Exit 2
means BASE or HEAD is not a commit, or a baseline does not parse.
"""
import json
import re
import subprocess
import sys

SWIFTLINT = ".swiftlint-baseline.json"
SLOP = ".slop-baseline.json"
ALLOWLIST = "Tools/crypto-imports.txt"
GATE = ("Tools/", ".swiftlint.yml", ".github/workflows/checks.yml")
BUILD_SETTINGS = re.compile(r"^(project\.yml|HausXMPP\.xcodeproj/project\.pbxproj|Config/[^/]+\.xcconfig|"
                            r"Packages/[^/]+/Package\.swift)$")
STRICT_LINE = re.compile(r"TREAT_WARNINGS_AS_ERRORS|SWIFT_UPCOMING_FEATURE_|OTHER_SWIFT_FLAGS|treatAllWarnings|"
                         r"UpcomingFeature|ExperimentalFeature|unsafeFlags")
UNDOING_LINE = re.compile(r"-no-warnings-as-errors|-Wwarning|-disable-upcoming-feature|as:\s*\.warning\b|"
                          r"(SWIFT_SUPPRESS_WARNINGS|GCC_WARN_INHIBIT_ALL_WARNINGS)\S*\s*[:=]\s*[\"']?(?i:yes|true)")
SHARED_SETTINGS = "swiftSettings: swiftSettings"
# The one slop-check rule whose entry is a recorded value rather than a fingerprint.
SLOP_MEASURED = {"comment.density"}


def git(*args):
    return subprocess.run(["git", "-c", "core.quotePath=false", *args], capture_output=True, text=True)


def fail(message):
    print(f"baseline-guard: {message}", file=sys.stderr)
    sys.exit(2)


def commit(ref):
    result = git("rev-parse", "--verify", "--quiet", f"{ref}^{{commit}}")
    if result.returncode != 0:
        fail(f"{ref} is not a commit")
    return result.stdout.strip()


def show(ref, path):
    if git("cat-file", "-e", f"{ref}:{path}").returncode != 0:
        return None
    return git("show", f"{ref}:{path}").stdout


def load(ref, path):
    text = show(ref, path)
    if text is None:
        return None
    try:
        return json.loads(text)
    except json.JSONDecodeError as error:
        fail(f"{ref}:{path} does not parse: {error}")


def changes(base, head):
    """(status, paths) per changed file; a rename's paths are (old, new)."""
    fields = git("diff", "--find-renames", "--name-status", "-z", base, head).stdout.split("\0")
    out, i = [], 0
    while i < len(fields) and fields[i]:
        status = fields[i]
        count = 2 if status[0] in "RC" else 1
        out.append((status, fields[i + 1:i + 1 + count]))
        i += 1 + count
    return out


def rekeyed(baseline, renames):
    for old, new in renames:
        if old in baseline:
            moved = baseline.pop(old)
            for rule, entries in moved.items():
                baseline.setdefault(new, {}).setdefault(rule, []).extend(entries)
    return baseline


def gained(old_texts, new_texts):
    for text in set(new_texts):
        if new_texts.count(text) > old_texts.count(text):
            return f"'{text[:60]}' gained an entry"
    return None


# SwiftLint entries are [line text, value]; the value is 0 except for size and complexity rules.
def grown_swiftlint(rule, old, new):
    for text in {t for t, _ in new}:
        new_values = sorted((v for t, v in new if t == text), reverse=True)
        old_values = sorted((v for t, v in old if t == text), reverse=True)
        if len(new_values) > len(old_values):
            return f"'{text[:60]}' gained an entry"
        if any(n > o for n, o in zip(new_values, old_values)):
            return f"'{text[:60]}' raised to {new_values[0]}"
    return None


def grown_slop(rule, old, new):
    if rule in SLOP_MEASURED:
        return int(new[0]) > int(old[0]) and f"raised from {old[0]} to {new[0]}"
    return gained(old, new)


def check_baseline(path, grown, base, head, renames):
    old_baseline, new_baseline = load(base, path), load(head, path)
    if old_baseline is None or new_baseline is None:
        return []
    old_baseline = rekeyed(old_baseline, renames)
    problems = []
    for file, rules in new_baseline.items():
        for rule, entries in rules.items():
            old = old_baseline.get(file, {}).get(rule)
            if old is None:
                problems.append(f"{path}: new entry for {file} {rule}")
            elif reason := grown(rule, old, entries):
                problems.append(f"{path}: {file} {rule} {reason}")
    return problems


def allowlist_additions(base, head):
    old, new = show(base, ALLOWLIST), show(head, ALLOWLIST)
    if old is None or new is None:
        return []
    added = set(new.splitlines()) - set(old.splitlines())
    return sorted(line for line in added if line.strip() and not line.startswith("#"))


def check_gate(base, changed, additions):
    # Before the checks exist on BASE there is nothing to loosen.
    if show(base, "Tools/baseline-guard.py") is None:
        return []
    problems = []
    for status, paths in changed:
        for path in paths:
            if path == ALLOWLIST and not additions:
                continue
            if path.startswith(GATE):
                problems.append(f"{path}: the checks themselves changed ({status[0]})")
    return problems


# A strict line may be added, which only makes the build stricter or covers a new target; removing or editing one
# may not. A line that undoes strictness may not be added, in a new file either.
def strict_settings_loosened(base, head, changed):
    if show(base, "Tools/baseline-guard.py") is None:
        return []
    problems = []
    for status, paths in changed:
        path = paths[-1]
        if status[0] == "D" or not BUILD_SETTINGS.match(path):
            continue
        old_text, new_text = show(base, paths[0]) or "", show(head, path) or ""
        old_undoing = [line.strip() for line in old_text.splitlines() if UNDOING_LINE.search(line)]
        new_undoing = [line.strip() for line in new_text.splitlines() if UNDOING_LINE.search(line)]
        for text in sorted(set(new_undoing)):
            if new_undoing.count(text) > old_undoing.count(text):
                problems.append(f"{path}: added a setting that undoes strictness: '{text[:80]}'")
        if not old_text:
            continue
        old = [line.strip() for line in old_text.splitlines() if STRICT_LINE.search(line)]
        new = [line.strip() for line in new_text.splitlines() if STRICT_LINE.search(line)]
        for text in sorted(set(old)):
            if old.count(text) > new.count(text):
                problems.append(f"{path}: strict compiler setting removed or changed: '{text[:80]}'")
        if old_text.count(SHARED_SETTINGS) > new_text.count(SHARED_SETTINGS):
            problems.append(f"{path}: a target no longer takes `{SHARED_SETTINGS}`")
    return problems


def main():
    if len(sys.argv) not in (2, 3):
        print(__doc__, file=sys.stderr)
        return 2
    base, head = commit(sys.argv[1]), commit(sys.argv[2] if len(sys.argv) == 3 else "HEAD")
    changed = changes(base, head)
    renames = [tuple(paths) for status, paths in changed if status.startswith("R")]
    additions = allowlist_additions(base, head)
    problems = (check_baseline(SWIFTLINT, grown_swiftlint, base, head, renames)
                + check_baseline(SLOP, grown_slop, base, head, renames)
                + [f"{ALLOWLIST}: added {line}" for line in additions]
                + check_gate(base, changed, additions)
                + strict_settings_loosened(base, head, changed))
    if problems:
        print("The checks may only get stricter:\n" + "\n".join(problems))
        print("\nFix the new violations instead of recording them. If the change is right, a maintainer adds the"
              " baseline-growth-approved label to the pull request.")
        return 1
    print("baselines did not grow and the checks are unchanged")
    return 0


if __name__ == "__main__":
    sys.exit(main())

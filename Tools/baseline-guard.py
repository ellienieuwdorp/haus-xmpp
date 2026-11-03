#!/usr/bin/env python3
"""Fail if a baseline grew since BASE: python3 -I Tools/baseline-guard.py BASE [HEAD]

Baselines only ever lose entries. A new file, rule or entry, a larger recorded size, or a new line in the crypto
import allowlist fails, and a person who agrees with the growth labels the pull request
`baseline-growth-approved`, saying why in the description.
"""
import json
import subprocess
import sys

SWIFTLINT = ".swiftlint-baseline.json"
SLOP = ".slop-baseline.json"
ALLOWLIST = "Tools/crypto-imports.txt"
SWIFTLINT_MEASURED = {"file_length", "type_body_length", "function_body_length", "closure_body_length",
                      "cyclomatic_complexity", "function_parameter_count"}
SLOP_MEASURED = {"comment.density"}


def show(ref, path):
    result = subprocess.run(["git", "show", f"{ref}:{path}"], capture_output=True, text=True)
    return result.stdout if result.returncode == 0 else None


def load(ref, path):
    text = show(ref, path)
    return json.loads(text) if text is not None else None


def gained(old_texts, new_texts):
    for text in set(new_texts):
        if new_texts.count(text) > old_texts.count(text):
            return f"'{text[:60]}' gained an entry"
    return None


def grown_swiftlint(rule, old, new):
    if rule not in SWIFTLINT_MEASURED:
        return gained([t for t, _ in old], [t for t, _ in new])
    # The same line text can occur more than once (`NavigationStack {`), so compare sorted values per text.
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


def check_baseline(path, grown, base, head):
    problems = []
    old_baseline, new_baseline = load(base, path), load(head, path)
    if old_baseline is None or new_baseline is None:
        return problems
    for file, rules in new_baseline.items():
        for rule, entries in rules.items():
            old = old_baseline.get(file, {}).get(rule)
            if old is None:
                problems.append(f"{path}: new entry for {file} {rule}")
            elif reason := grown(rule, old, entries):
                problems.append(f"{path}: {file} {rule} {reason}")
    return problems


def check_allowlist(base, head):
    old, new = show(base, ALLOWLIST), show(head, ALLOWLIST)
    if old is None or new is None:
        return []
    added = set(new.splitlines()) - set(old.splitlines())
    return [f"{ALLOWLIST}: added {line}" for line in sorted(added) if line.strip() and not line.startswith("#")]


def main():
    if len(sys.argv) not in (2, 3):
        sys.exit(__doc__)
    base, head = sys.argv[1], sys.argv[2] if len(sys.argv) == 3 else "HEAD"
    problems = (check_baseline(SWIFTLINT, grown_swiftlint, base, head)
                + check_baseline(SLOP, grown_slop, base, head) + check_allowlist(base, head))
    if problems:
        print("Baselines may only shrink:\n" + "\n".join(problems))
        print("\nFix the new violations instead of recording them. If the growth is right, a maintainer adds the"
              " baseline-growth-approved label to the pull request.")
        return 1
    print("baselines did not grow")
    return 0


if __name__ == "__main__":
    sys.exit(main())

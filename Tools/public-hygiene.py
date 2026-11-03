#!/usr/bin/env python3
"""Check what the index would publish: python3 -I Tools/public-hygiene.py

- No coding-assistant instruction files (AGENTS.md, CLAUDE.md, .claude/, .agents/, .codex/, .cursor/ and the like).
- No Config/Local.xcconfig, which holds machine settings.
- No development team in project.yml, a tracked .xcconfig or a .pbxproj; it belongs in Config/Local.xcconfig.
- Every workflow job runs on a GitHub-hosted runner.
It reads the index, so the pre-commit hook checks what is about to be committed.
"""
import re
import subprocess
import sys

AGENT_FILES = {"AGENTS.md", "CLAUDE.md", "GEMINI.md", ".cursorrules", ".windsurfrules", "copilot-instructions.md"}
AGENT_DIRS = {".claude", ".agents", ".codex", ".cursor", ".windsurf", ".gemini"}
LOCAL_SETTINGS = "Config/Local.xcconfig"
TEAM_FILES = ("project.yml", "*.xcconfig", "*.pbxproj")
# `DEVELOPMENT_TEAM = X`, `DEVELOPMENT_TEAM: X` (project.yml) or `DevelopmentTeam = X;` (pbxproj target attributes).
TEAM = re.compile(r"""^\s*"?(?:DEVELOPMENT_TEAM|DevelopmentTeam)"?\s*[:=](.*)$""")
# Standard GitHub-hosted images only: no self-hosted runners and no paid larger runners.
HOSTED = re.compile(r"^(ubuntu|macos|windows)-(latest|\d[\d.]*)(-arm)?$|^xcode-\d+$")
RUNS_ON = re.compile(r"^\s*(?:-\s*)?runs-on:\s*(.*?)\s*(?:#.*)?$")


def git(*args):
    return subprocess.run(["git", "-c", "core.quotePath=false", *args], capture_output=True, text=True, check=True).stdout


def agent_files(paths):
    problems = []
    for path in paths:
        parts = path.split("/")
        if parts[-1] in AGENT_FILES or AGENT_DIRS.intersection(parts[:-1]):
            problems.append(f"{path}: coding-assistant instructions are not published; untrack it (git rm --cached)")
    return problems


def development_team():
    out = subprocess.run(["git", "-c", "core.quotePath=false", "grep", "--cached", "-n", "-I", "-E", "DEVELOPMENT_TEAM|DevelopmentTeam", "--",
                          *TEAM_FILES], capture_output=True, text=True).stdout
    problems = []
    for hit in out.splitlines():
        path, number, line = hit.split(":", 2)
        match = TEAM.match(line)
        value = match.group(1).strip().rstrip(";").strip().strip("\"'") if match else ""
        # Empty, or a reference to a setting defined elsewhere such as $(HAUS_TEAM).
        if not value or value.startswith("$("):
            continue
        problems.append(f"{path}:{number}: a development team is set; leave it empty here and set it in"
                        f" {LOCAL_SETTINGS}, which is not committed")
    return problems


def runners(paths):
    problems = []
    for path in paths:
        if not (path.startswith(".github/workflows/") and path.endswith((".yml", ".yaml"))):
            continue
        for number, line in enumerate(git("show", f":{path}").splitlines(), 1):
            match = RUNS_ON.match(line)
            if match and not HOSTED.match(match.group(1).strip("'\"")):
                problems.append(f"{path}:{number}: runs-on {match.group(1) or '(a list or group)'} is not a"
                                " GitHub-hosted runner label; use one such as ubuntu-latest or xcode-27")
    return problems


def main():
    paths = git("ls-files", "--cached").splitlines()
    problems = agent_files(paths) + development_team() + runners(paths)
    if LOCAL_SETTINGS in paths:
        problems.append(f"{LOCAL_SETTINGS}: machine settings are not published; untrack it (git rm --cached)")
    for problem in problems:
        print(problem)
    if problems:
        print(f"\n{len(problems)} public hygiene problem(s).")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

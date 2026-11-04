#!/usr/bin/env python3
"""Check that every target builds with the strict compiler settings: python3 -I Tools/compiler-strictness.py

Xcode (project.yml and the HausXMPP project it generates): the project's Debug and Release configurations treat
Swift and C warnings as errors and enable the ExistentialAny, MemberImportVisibility and ImmutableWeakCaptures
upcoming features, and no target or xcconfig turns any of that off: a target's OTHER_SWIFT_FLAGS keeps
$(inherited). Packages (every Packages/*/Package.swift, read through `swift package dump-package`): each Swift target
sets treatAllWarnings(as: .error) and the three upcoming features unconditionally, and each C target other than the
vendored library treats warnings as errors. Nowhere, conditions included, may a flag (-no-warnings-as-errors,
-Wwarning, -disable-upcoming-feature), SWIFT_SUPPRESS_WARNINGS or GCC_WARN_INHIBIT_ALL_WARNINGS set to YES, or a
treatWarning or treatAllWarnings(as: .warning) setting undo that. Needs macOS (plutil) and a Swift toolchain.
"""
import glob
import json
import os
import re
import subprocess
import sys

PROJECT_YML = "project.yml"
PBXPROJ = "HausXMPP.xcodeproj/project.pbxproj"
FEATURES = ("ExistentialAny", "MemberImportVisibility", "ImmutableWeakCaptures")
WEAK_CAPTURES_FLAG = "-enable-upcoming-feature ImmutableWeakCaptures"
XCODE_SETTINGS = {
    "SWIFT_TREAT_WARNINGS_AS_ERRORS": "YES",
    "GCC_TREAT_WARNINGS_AS_ERRORS": "YES",
    "SWIFT_UPCOMING_FEATURE_EXISTENTIAL_ANY": "YES",
    "SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY": "YES",
}
# Xcode has no build setting for ImmutableWeakCaptures, so it comes through OTHER_SWIFT_FLAGS.
FLAGS = "OTHER_SWIFT_FLAGS"
SUPPRESSING = ("SWIFT_SUPPRESS_WARNINGS", "GCC_WARN_INHIBIT_ALL_WARNINGS")
GATED = (*XCODE_SETTINGS, FLAGS)
SCANNED = (*GATED, *SUPPRESSING)
# Compiler flags that turn warnings-as-errors or an upcoming feature back off.
UNDOING = re.compile(r"(?<![\w-])(-no-warnings-as-errors|-Wwarning|-disable-upcoming-feature)(?![\w-])")
# Upstream C, compiled as it ships.
VENDORED_C = {("OMEMOCrypto", "CLibOMEMO")}
FIX = {
    "xcode": "set them in project.yml's top-level settings.base, as on main, and regenerate the project",
    "package": "give the target `swiftSettings: swiftSettings` (the shared list at the top of its Package.swift)",
    "c": "give the target `cSettings: [.treatAllWarnings(as: .error)]`",
}


def setting_value(value):
    """A build setting as one string; a list is joined, a YAML boolean read as YES or NO."""
    value = " ".join(value) if isinstance(value, list) else str(value)
    return {"true": "YES", "false": "NO"}.get(value.lower(), value.upper() if value.lower() in ("yes", "no") else value)


def settings_problems(where, settings, project_level):
    """Problems with one configuration's build settings; a target may leave a setting to the project."""
    problems = []
    for key, raw in settings.items():
        name, value = key.split("[")[0], setting_value(raw)
        if name in SUPPRESSING and value == "YES":
            problems.append(f"{where}: {key} = YES hides warnings")
        if name == FLAGS and (undoing := UNDOING.findall(value)):
            problems.append(f"{where}: {key} has {', '.join(undoing)}")
        if name in XCODE_SETTINGS and value != XCODE_SETTINGS[name]:
            problems.append(f"{where}: {key} = {value}")
        if name == FLAGS and project_level and WEAK_CAPTURES_FLAG not in value:
            problems.append(f"{where}: {key} lacks {WEAK_CAPTURES_FLAG}")
        if name == FLAGS and not project_level and "$(inherited)" not in value and WEAK_CAPTURES_FLAG not in value:
            problems.append(f"{where}: {key} replaces the project's flags without $(inherited)")
    if project_level:
        problems += [f"{where}: {key} is not set" for key in GATED if key not in settings]
    return problems


def xcconfig_settings(path, seen=None):
    """The gated settings an xcconfig and the files it includes assign, as {key: value}."""
    seen = seen if seen is not None else set()
    if path in seen or not os.path.exists(path):
        return {}
    seen.add(path)
    out = {}
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.split("//")[0].strip()
            if include := re.match(r'#include\??\s+"([^"]+)"', line):
                out.update(xcconfig_settings(os.path.join(os.path.dirname(path), include[1]), seen))
            elif "=" in line and line.split("=")[0].strip().split("[")[0] in SCANNED:
                key, value = (part.strip() for part in line.split("=", 1))
                out[key] = value
    return out


def xcode_problems():
    result = subprocess.run(["plutil", "-convert", "json", "-o", "-", PBXPROJ], capture_output=True, text=True)
    if result.returncode != 0:
        return [f"{PBXPROJ}: plutil could not read it: {result.stderr.strip()}"]
    data = json.loads(result.stdout)
    objects = data["objects"]
    root = objects[data["rootObject"]]

    def configurations(owner):
        return [objects[c] for c in objects[owner["buildConfigurationList"]]["buildConfigurations"]]

    def xcconfig_problems(where, config):
        if not (reference := config.get("baseConfigurationReference")):
            return []
        path = objects[reference].get("path", "")
        xcconfig = path if os.path.exists(path) else os.path.join("Config", os.path.basename(path))
        # The configuration's own settings sit above the xcconfig, so only the rules a target follows apply to it.
        return settings_problems(f"{where} ({xcconfig})", xcconfig_settings(xcconfig), False)

    problems = []
    for config in configurations(root):
        where = f"{PBXPROJ} project {config['name']}"
        problems += settings_problems(where, config["buildSettings"], True) + xcconfig_problems(where, config)
    for target in (objects[t] for t in root["targets"]):
        for config in configurations(target):
            where = f"{PBXPROJ} target {target['name']} {config['name']}"
            problems += settings_problems(where, config["buildSettings"], False) + xcconfig_problems(where, config)
    return problems


def yaml_scalar(text):
    """A plain, quoted or commented YAML scalar's value."""
    text = text.strip()
    if text[:1] in ("'", '"') and text[0] in text[1:]:
        return text[1:text.index(text[0], 1)]
    return re.sub(r"\s+#.*$", "", text).strip()


def yaml_value(lines, index):
    """The value of the key on lines[index]: an inline scalar or the block list below it, joined."""
    inline = yaml_scalar(lines[index].split(":", 1)[1])
    if inline:
        return inline[1:-1].replace(",", " ") if inline.startswith("[") else inline
    indent, items = len(lines[index]) - len(lines[index].lstrip()), []
    for line in lines[index + 1:]:
        if line.strip() and (len(line) - len(line.lstrip()) <= indent or not line.strip().startswith("- ")):
            break
        if line.strip():
            items.append(yaml_scalar(line.strip()[2:]))
    return " ".join(items)


# The project-level settings.base must hold every setting; a setting anywhere else follows the rules a target does.
def project_yml_problems():
    with open(PROJECT_YML, encoding="utf-8") as f:
        lines = f.read().split("\n")
    problems, section, found = [], None, {}
    for index, line in enumerate(lines):
        if re.match(r"\S", line):
            section = line.rstrip(":")
        key = line.strip().split(":")[0]
        if key not in SCANNED:
            continue
        if section == "settings" and line.startswith("    " + key):
            found[key] = yaml_value(lines, index)
        else:
            problems += settings_problems(f"{PROJECT_YML}:{index + 1}", {key: yaml_value(lines, index)}, False)
    problems += settings_problems(f"{PROJECT_YML} settings.base", found, True)
    return problems


def swift_sources(package, target):
    default = "Tests" if target["type"] == "test" else "Sources"
    root = os.path.join(package, target.get("path") or os.path.join(default, target["name"]))
    return any(glob.iglob(os.path.join(root, "**", "*.swift"), recursive=True))


def undoing_settings(target):
    """Settings, conditional ones included, that turn warnings-as-errors or an upcoming feature back off."""
    problems = []
    for setting in target.get("settings", []):
        kind = setting["kind"]
        if flags := kind.get("unsafeFlags", {}).get("_0"):
            problems += [f"unsafeFlags has {flag}" for flag in UNDOING.findall(" ".join(flags))]
        if kind.get("treatWarning", {}).get("_1") == "warning":
            problems.append(f"treatWarning(\"{kind['treatWarning']['_0']}\", as: .warning)")
        if kind.get("treatAllWarnings", {}).get("_0") == "warning":
            problems.append("treatAllWarnings(as: .warning)")
    return problems


def package_problems(manifest):
    package = os.path.dirname(manifest)
    result = subprocess.run(["swift", "package", "dump-package", "--package-path", package],
                            capture_output=True, text=True)
    if result.returncode != 0:
        return [f"{manifest}: swift package dump-package failed: {result.stderr.strip()[:500]}"]
    problems = []
    for target in json.loads(result.stdout)["targets"]:
        if target["type"] in ("binary", "system"):
            continue
        name = target["name"]
        problems += [f"{manifest} target {name}: {problem}" for problem in undoing_settings(target)]
        settings = [s for s in target.get("settings", []) if not s.get("condition")]
        kinds = {(s["tool"], json.dumps(s["kind"], sort_keys=True)) for s in settings}
        if swift_sources(package, target):
            wanted = [("swift", {"treatAllWarnings": {"_0": "error"}})]
            wanted += [("swift", {"enableUpcomingFeature": {"_0": feature}}) for feature in FEATURES]
            fix = FIX["package"]
        elif (os.path.basename(package), name) in VENDORED_C:
            continue
        else:
            wanted, fix = [("c", {"treatAllWarnings": {"_0": "error"}})], FIX["c"]
        missing = [json.dumps(kind) for tool, kind in wanted if (tool, json.dumps(kind, sort_keys=True)) not in kinds]
        if missing:
            problems.append(f"{manifest} target {name}: missing {', '.join(missing)}; {fix}")
    return problems


def main():
    xcode = project_yml_problems() + xcode_problems()
    packages = [p for manifest in sorted(glob.glob("Packages/*/Package.swift")) for p in package_problems(manifest)]
    if xcode:
        print("\n".join(xcode))
        print(f"Every app, extension and test target builds with warnings as errors and the upcoming features"
              f" {', '.join(FEATURES)}; {FIX['xcode']}.\n")
    if packages:
        print("\n".join(packages))
        print("Every package target builds with warnings as errors and the same upcoming features.")
    return 1 if xcode or packages else 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Check the package layering over `import` lines: python3 -I Tools/import-boundaries.py [FILE...]

A file under Packages/<P>/ may import only P's own modules and the repository modules P's Package.swift declares
as dependencies; SwiftPM would also let it import their dependencies, which skips a layer. App and extension code
may not reach under OMEMO to the crypto adapters, the C bridge or SQLite. CryptoKit and CommonCrypto may be
imported only by the files in Tools/crypto-imports.txt. Without FILEs every tracked Swift file is checked.
"""
import re
import subprocess
import sys

# A hand-kept copy of the target dependencies in each Packages/*/Package.swift, executables and test targets
# included. A package missing here fails the check.
PACKAGE_IMPORTS = {
    "XMPPProtocol": {"XMPPProtocol"},
    "MessageStore": {"MessageStore", "XMPPProtocol", "CSQLite"},
    "OMEMOCrypto": {"OMEMOCrypto", "COMEMOBridge"},
    "OMEMO": {"OMEMO", "OMEMOCrypto", "XMPPProtocol", "MessageStore"},
    "MessagingCore": {"MessagingCore", "MessageStore", "XMPPProtocol", "OMEMO"},
}
REPOSITORY_MODULES = set().union(*PACKAGE_IMPORTS.values()) | {"CLibOMEMO", "MessagingCore", "HausXMPP"}
APP_FORBIDDEN = {"OMEMOCrypto", "COMEMOBridge", "CLibOMEMO", "CSQLite"}
SYSTEM_CRYPTO = {"CryptoKit", "CommonCrypto"}
ALLOWLIST = "Tools/crypto-imports.txt"
VENDORED = "Packages/OMEMOCrypto/Sources/CLibOMEMO/"
IMPORT = re.compile(r"^\s*(?:@[\w.]+(?:\([^)]*\))?\s+)*(?:(?:public|package|internal|fileprivate|private)\s+)?"
                    r"import\s+(?:(?:typealias|struct|class|enum|protocol|let|var|func)\s+)?([\w]+)")


def tracked_swift_files():
    out = subprocess.run(["git", "-c", "core.quotePath=false", "ls-files", "--cached", "--others", "--exclude-standard",
                          "*.swift"],
                         capture_output=True, text=True, check=True).stdout
    return out.splitlines()


def package_of(path):
    parts = path.split("/")
    return parts[1] if parts[0] == "Packages" and len(parts) > 2 else None


def check(path, crypto_allowed):
    problems = []
    try:
        with open(path, encoding="utf-8") as f:
            lines = f.read().splitlines()
    except FileNotFoundError:
        return problems
    package = package_of(path)
    if package is not None and package not in PACKAGE_IMPORTS:
        return [f"{path}: error: Packages/{package} is not in PACKAGE_IMPORTS in Tools/import-boundaries.py; add it"
                " with the dependencies its Package.swift declares"]
    allowed = PACKAGE_IMPORTS.get(package)
    for number, line in enumerate(lines, 1):
        match = IMPORT.match(line)
        if not match:
            continue
        module = match.group(1)
        where = f"{path}:{number}: error:"
        if allowed is not None and module in REPOSITORY_MODULES and module not in allowed:
            problems.append(f"{where} {package} may not import {module}; it may import {', '.join(sorted(allowed))}."
                            " Move the code to the layer that owns it, or pass what it needs in")
        elif allowed is None and module in APP_FORBIDDEN:
            problems.append(f"{where} app code may not import {module}; go through the OMEMO and MessageStore APIs")
        if module in SYSTEM_CRYPTO and path not in crypto_allowed:
            problems.append(f"{where} {module} is imported only by the files in {ALLOWLIST}; use the existing"
                            " crypto helpers in those files, or ask a maintainer to extend the list")
    return problems


def main():
    with open(ALLOWLIST, encoding="utf-8") as f:
        crypto_allowed = {line.strip() for line in f if line.strip() and not line.startswith("#")}
    files = sys.argv[1:] or tracked_swift_files()
    problems = []
    for path in files:
        if path.endswith(".swift") and not path.startswith(VENDORED) and "/.build/" not in path:
            problems += check(path, crypto_allowed)
    for problem in problems:
        print(problem)
    if problems:
        print(f"\n{len(problems)} import boundary violation(s).")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

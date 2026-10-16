#!/usr/bin/env bash
# Prints the Swift packages a CI run should test, as a JSON array such as ["OMEMO","MessagingCore"].
#
# Run from the repository root:
#   changed-packages.sh pull_request <base sha>   the packages the pull request changes
#   changed-packages.sh push <before sha>         the packages the push changes
#   changed-packages.sh <any other event>         every package (a manual run)
# A push whose previous commit isn't known (a new branch, a rewritten history) tests every package too.
# A package's dependents are tested with it, and a change to the CI itself tests everything.
set -euo pipefail

event=${1:-}
since=${2:-}
all="XMPPProtocol MessageStore MessagingCore OMEMOCrypto OMEMO"

if [ "$event" = pull_request ]; then
  changed=$(git diff --name-only "$since...HEAD")
elif [ "$event" = push ] && [ -n "$since" ] && git cat-file -e "$since^{commit}" 2>/dev/null; then
  changed=$(git diff --name-only "$since" HEAD)
else
  changed=.github/workflows/swift-packages.yml
fi

want=" "
add() { for p in "$@"; do case "$want" in *" $p "*) ;; *) want="$want$p ";; esac; done; }
while IFS= read -r f; do
  case "$f" in
    .github/workflows/swift-packages.yml | .github/scripts/changed-packages.sh) add $all ;;
    Packages/XMPPProtocol/*) add XMPPProtocol MessageStore OMEMO MessagingCore ;;
    Packages/MessageStore/*) add MessageStore OMEMO MessagingCore ;;
    Packages/OMEMOCrypto/*) add OMEMOCrypto OMEMO MessagingCore ;;
    Packages/OMEMO/*) add OMEMO MessagingCore ;;
    Packages/MessagingCore/*) add MessagingCore ;;
  esac
done <<< "$changed"

json=""
for p in $all; do case "$want" in *" $p "*) json="$json${json:+,}\"$p\"" ;; esac; done
echo "[$json]"

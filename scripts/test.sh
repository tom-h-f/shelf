#!/bin/zsh
set -euo pipefail
source ${0:A:h}/env.sh
cd ${0:A:h}/..
swift test -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing "$@"

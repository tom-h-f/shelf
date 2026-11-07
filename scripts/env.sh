# Sourced by the build scripts. The macOS 27 SDK declares SwiftUI's @State as a macro whose plugin ships only
# with Xcode, not the Command Line Tools, so build against the newest SDK where State is still a property wrapper.
for sdk in /Library/Developer/CommandLineTools/SDKs/MacOSX26*.sdk(NOn); do
  export SDKROOT=$sdk
  break
done
if [[ -z "${SDKROOT:-}" ]]; then
  echo "No macOS 26 SDK in the Command Line Tools; install Xcode or a CLT that includes MacOSX26.x.sdk" >&2
  exit 1
fi

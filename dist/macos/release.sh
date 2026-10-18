#!/usr/bin/env bash
# Builds Coastty.app for the version tag on HEAD and stamps its version and build number into Info.plist.
#
# Usage: tag the release commit (git tag v0.1.0), then run dist/macos/release.sh from anywhere in the repo.
#
# Environment:
#   RELEASE_DIR  where the stamped Coastty.app is written (default: zig-out/release)
#   ZIG          the zig binary to build with (default: zig on PATH)
#
# The build number is YYYYMMDD.N and must only ever increase, so the last release's is kept in
# dist/macos/last-build-number. Commit that file with the release.
set -euo pipefail

repo=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
last_build_file="$repo/dist/macos/last-build-number"
release_dir="${RELEASE_DIR:-$repo/zig-out/release}"
zig="${ZIG:-zig}"

# Prints a message to stderr and stops the release.
fail() {
  echo "release: $*" >&2
  exit 1
}

# Prints the single vX.Y.Z tag on HEAD.
release_tag() {
  local tags
  tags=$(git -C "$repo" tag --points-at HEAD --list 'v[0-9]*')

  if [[ -z $tags ]]; then
    fail "HEAD has no vX.Y.Z tag"
  fi

  if [[ $(wc -l <<<"$tags") -ne 1 ]]; then
    fail "HEAD has more than one version tag: $(tr '\n' ' ' <<<"$tags")"
  fi

  echo "$tags"
}

# Prints today's build number: .N counts up from the last release when it was made the same day.
next_build_number() {
  local last=$1 today=$2

  if [[ ${last%.*} == "$today" ]]; then
    echo "$today.$((10#${last#*.} + 1))"
    return
  fi

  echo "$today.1"
}

# Succeeds when build number $1 is higher than $2. The date and N compare as integers, never as one decimal (20261019.10 > 20261019.9).
is_higher() {
  local new_date=$((10#${1%.*})) new_n=$((10#${1#*.}))
  local old_date=$((10#${2%.*})) old_n=$((10#${2#*.}))

  if ((new_date != old_date)); then
    ((new_date > old_date))
    return
  fi

  ((new_n > old_n))
}

# Prints the build number for this release, refusing one that is not higher than the last release's.
build_number() {
  local today last build
  today=$(date +%Y%m%d)

  # The first release has nothing to be higher than
  if [[ ! -f $last_build_file ]]; then
    echo "$today.1"
    return
  fi

  last=$(tr -d '[:space:]' <"$last_build_file")
  if [[ ! $last =~ ^[0-9]{8}\.[0-9]+$ ]]; then
    fail "$last_build_file holds '$last', not a YYYYMMDD.N build number"
  fi

  build=$(next_build_number "$last" "$today")
  if ! is_higher "$build" "$last"; then
    fail "build $build would not be higher than the last release's $last"
  fi

  echo "$build"
}

main() {
  local tag version file_version build app plist

  # The tag names the version; VERSION must agree so dev builds count up from the same number
  tag=$(release_tag)
  version=${tag#v}
  file_version=$(tr -d '[:space:]' <"$repo/VERSION")
  if [[ $version != "$file_version" ]]; then
    fail "tag $tag does not match VERSION ($file_version)"
  fi

  build=$(build_number)
  echo "release: building Coastty $version, build $build"

  # zig's install step merges into an existing bundle, so clear it to keep stale files out of the release
  rm -rf "$repo/zig-out/Coastty.app"
  (cd "$repo" && "$zig" build -Doptimize=ReleaseFast -Dcoastty-version="$version")

  app="$release_dir/Coastty.app"
  rm -rf "$app"
  mkdir -p "$release_dir"
  ditto "$repo/zig-out/Coastty.app" "$app"

  # Stamp the version and build number, as Ghostty's release workflow does after xcodebuild
  plist="$app/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build" "$plist"

  # Editing Info.plist breaks the bundle's signature; sign it again ad hoc until there is a Developer ID
  codesign --force --sign - --preserve-metadata=entitlements,requirements,flags,runtime "$app"

  echo "$build" >"$last_build_file"
  echo "release: $app is Coastty $version, build $build"
  echo "release: commit dist/macos/last-build-number with this release"
}

main "$@"

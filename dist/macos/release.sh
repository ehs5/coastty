#!/usr/bin/env bash
# Builds Coastty.app for the version tag on HEAD, stamps its version and build number, and packages it as Coastty.dmg.
#
# Usage: tag the release commit (git tag v0.1.0), then run from anywhere in the repo:
#   dist/macos/release.sh            build Coastty.dmg and print the cask values, uploading nothing
#   dist/macos/release.sh --publish  the same, then upload Coastty.dmg to a draft GitHub release
#
# Environment:
#   RELEASE_DIR  where the stamped Coastty.app and Coastty.dmg are written (default: zig-out/release)
#   ZIG          the zig binary to build with (default: zig on PATH)
#
# The build number is YYYYMMDD.N and must only ever increase, so the last published release's is kept in dist/macos/last-build-number.
# --publish updates that file; commit it after the release.
set -euo pipefail

repo=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
last_build_file="$repo/dist/macos/last-build-number"
notes_dir="$repo/dist/macos/release-notes"
release_dir="${RELEASE_DIR:-$repo/zig-out/release}"
zig="${ZIG:-zig}"
create_dmg="create-dmg@8.1.0"

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

# Refuses uncommitted changes, which would ship in a build the tag does not describe.
check_clean_tree() {
  if [[ -n $(git -C "$repo" status --porcelain) ]]; then
    fail "the working tree has uncommitted changes"
  fi
}

# Refuses a tag that origin already has: a published version is never rebuilt under the same number.
check_tag_unpublished() {
  local tag=$1 status=0
  git -C "$repo" ls-remote --exit-code --tags origin "refs/tags/$tag" >/dev/null || status=$?

  if ((status == 0)); then
    fail "tag $tag already exists on origin"
  fi

  # ls-remote exits 2 only when it reached origin and found no such tag
  if ((status != 2)); then
    fail "could not ask origin whether $tag exists"
  fi
}

# Refuses what would stop a draft release from being created for the tag on HEAD.
check_publishable() {
  local tag=$1 notes=$2

  if [[ ! -f $notes ]]; then
    fail "write the release notes in ${notes#"$repo/"} first"
  fi

  # A logged-out or offline gh would pass the release check below and fail only after the whole build
  if ! gh auth status >/dev/null 2>&1; then
    fail "gh cannot reach GitHub as a logged-in user; check gh auth status"
  fi

  if gh release view "$tag" >/dev/null 2>&1; then
    fail "a GitHub release for $tag already exists"
  fi

  # gh creates the tag on GitHub when the draft is published, so the commit must already be there
  if [[ -z $(git -C "$repo" branch -r --contains HEAD) ]]; then
    fail "HEAD is not on origin yet; push the release commit first"
  fi
}

# Builds the app into $1 and stamps version $2 and build $3 into it, with the licence texts its code requires.
build_app() {
  local app=$1 version=$2 build=$3 plist

  # zig's install step merges into an existing bundle, so clear it to keep stale files out of the release
  rm -rf "$repo/zig-out/Coastty.app"
  (cd "$repo" && "$zig" build -Doptimize=ReleaseFast -Dcoastty-version="$version")

  rm -rf "$app"
  ditto "$repo/zig-out/Coastty.app" "$app"

  # Stamp the version and build number, as Ghostty's release workflow does after xcodebuild
  plist="$app/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build" "$plist"

  # MIT wants Ghostty's notice in all copies and Apache 2.0 wants herdr's licence given to every recipient, so both ship inside the app
  cp "$repo/LICENSE" "$app/Contents/Resources/LICENSE"
  cp "$repo/src/agent-detection/LICENSE-herdr" "$app/Contents/Resources/LICENSE-herdr"

  # Editing the bundle breaks its signature; sign it again ad hoc until there is a Developer ID
  codesign --force --sign - --preserve-metadata=entitlements,requirements,flags,runtime "$app"
}

# Wraps app $1 in dmg $2, unsigned until there is a Developer ID.
make_dmg() {
  local app=$1 dmg=$2 staging="$release_dir/dmg"

  rm -rf "$staging" "$dmg"
  mkdir -p "$staging"

  # create-dmg turns a license.txt in its working directory into a click-through agreement, so run it from the empty staging folder
  (cd "$staging" && npx --yes "$create_dmg" --no-version-in-filename --no-code-sign "$app" "$staging")

  mv "$staging/Coastty.dmg" "$dmg"
  rm -rf "$staging"
}

# Prints the values Casks/coastty.rb needs for this release.
print_cask_values() {
  local version=$1 sha=$2

  echo "release: values for Casks/coastty.rb:"
  echo "  version \"$version\""
  echo "  sha256 \"$sha\""
  echo "release: the cask builds its url from the version: https://github.com/ehs5/coastty/releases/download/v$version/Coastty.dmg"
}

# Uploads the dmg to a draft release for the tag, which stays unpublished until it is reviewed on GitHub.
publish() {
  local tag=$1 dmg=$2 notes=$3 version=${1#v}

  gh release create "$tag" "$dmg" --draft --target "$(git -C "$repo" rev-parse HEAD)" --title "Coastty $version" --notes-file "$notes"
}

# Builds, stamps and packages the release for the tag on HEAD, and uploads it with --publish.
main() {
  local mode=${1:-} tag version file_version build app dmg sha notes

  if [[ -n $mode && $mode != "--publish" ]]; then
    fail "unknown argument '$mode'; the only option is --publish"
  fi

  check_clean_tree

  # The tag names the version; COASTTY_VERSION must agree so dev builds count up from the same number
  tag=$(release_tag)
  version=${tag#v}
  file_version=$(tr -d '[:space:]' <"$repo/COASTTY_VERSION")

  if [[ $version != "$file_version" ]]; then
    fail "tag $tag does not match COASTTY_VERSION ($file_version)"
  fi

  check_tag_unpublished "$tag"
  notes="$notes_dir/$tag.md"

  if [[ $mode == "--publish" ]]; then
    check_publishable "$tag" "$notes"
  fi

  build=$(build_number)
  echo "release: building Coastty $version, build $build"

  mkdir -p "$release_dir"
  app="$release_dir/Coastty.app"
  dmg="$release_dir/Coastty.dmg"
  build_app "$app" "$version" "$build"
  make_dmg "$app" "$dmg"

  sha=$(shasum -a 256 "$dmg" | cut -d ' ' -f 1)
  echo "release: $dmg is Coastty $version, build $build"
  echo "release: SHA-256 $sha"
  print_cask_values "$version" "$sha"

  if [[ $mode != "--publish" ]]; then
    echo "release: nothing uploaded; run with --publish to create the draft release"
    return
  fi

  publish "$tag" "$dmg" "$notes"
  echo "$build" >"$last_build_file"
  echo "release: draft release $tag created; review and publish it on GitHub"
  echo "release: then update Casks/coastty.rb and commit it with dist/macos/last-build-number"
}

main "$@"

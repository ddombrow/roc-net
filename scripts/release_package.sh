#!/usr/bin/env bash
# Release one package from packages/NAME as its own bundle:
#
#   scripts/release_package.sh NAME VERSION            # check, bundle, upload, tag
#   DRY_RUN=1 scripts/release_package.sh NAME VERSION  # check and bundle only
#
# The bundle goes to the project's generic package registry at
# .../packages/generic/NAME/VERSION/<hash>.tar.zst (Roc reads the version
# from that path, and checks the hash), with a GitLab release tagged
# NAME-vVERSION whose notes are the package's CHANGELOG.md section.
set -euo pipefail
name=${1:?usage: release_package.sh NAME VERSION}
version=${2:?usage: release_package.sh NAME VERSION}
project=86936101
dir="packages/$name"
cd "$(dirname "$0")/.."

[ -f "$dir/main.roc" ] || { echo "No package at $dir." >&2; exit 1; }
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Version must be MAJOR.MINOR.PATCH, not $version." >&2; exit 1; }
notes=$(awk -v v="## $version" '$0 == v {on=1; next} /^## / {on=0} on' "$dir/CHANGELOG.md")
[ -n "$notes" ] || { echo "$dir/CHANGELOG.md has no '## $version' section." >&2; exit 1; }

# A published bundle can't refer outside itself, so relative dependencies
# (another package, or the platform) would have to be rewritten to released
# URLs first. Not needed yet: refuse rather than publish something broken.
if sed -n '/^package/,/}/p' "$dir/main.roc" | grep -q '"\.'; then
    echo "$dir/main.roc has relative dependencies; rewriting them to released URLs isn't implemented yet." >&2
    exit 1
fi

if [ -z "${DRY_RUN:-}" ]; then
    [ -z "$(git status --porcelain)" ] || { echo "Commit or stash your changes first." >&2; exit 1; }
    git fetch -q gitlab --tags
    [ "$(git rev-parse HEAD)" = "$(git rev-parse gitlab/main)" ] || { echo "Push HEAD to gitlab/main first." >&2; exit 1; }
    ! git rev-parse -q --verify "refs/tags/$name-v$version" >/dev/null || { echo "Tag $name-v$version exists already." >&2; exit 1; }
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
# The package's .roc files, and the license.
cp "$dir"/*.roc "$work/"
cp LICENSE "$work/LICENSE"
mkdir "$work/out"
(cd "$work" && roc bundle *.roc LICENSE --output-dir "$work/out" >/dev/null)
bundle=$(ls "$work"/out/*.tar.zst)
file=$(basename "$bundle")

# The bundle must work by itself: unpack it elsewhere and run its tests.
mkdir "$work/check"
(cd "$work/check" && roc unbundle "$bundle" >/dev/null)
roc test "$work/check/${file%.tar.zst}/main.roc" >/dev/null || { echo "The bundle's own tests fail:" >&2; roc test "$work/check/${file%.tar.zst}/main.roc"; exit 1; }

url="https://gitlab.com/api/v4/projects/$project/packages/generic/$name/$version/$file"
echo "$name $version: $file ($(du -h "$bundle" | cut -f1)), its tests pass from the bundle"
echo "URL: $url"
if [ -n "${DRY_RUN:-}" ]; then
    mkdir -p target/packages && cp "$bundle" "target/packages/$name-$version-$file"
    echo "Dry run: bundle kept at target/packages/$name-$version-$file, nothing uploaded."
    exit 0
fi

read -r -p "Upload it and create the release? [y/N] " answer
[ "$answer" = y ] || exit 1
glab api --method PUT "projects/$project/packages/generic/$name/$version/$file" --input "$bundle" >/dev/null
# Roc checks the hash, so the URL must serve exactly this bundle.
curl -fsSL "$url" | cmp -s - "$bundle" || { echo "Downloading $url didn't return the bundle." >&2; exit 1; }
mkdir -p target
printf '%s\n\n## Using it\n\n```roc\napp [main!] {\n    pf: platform "...",\n    %s: "%s",\n}\n```\n' "$notes" "$name" "$url" > target/package-release-notes.md
glab release create "$name-v$version" --ref "$(git rev-parse HEAD)" --name "$name $version" --notes-file target/package-release-notes.md
echo "Released $name $version: $url"

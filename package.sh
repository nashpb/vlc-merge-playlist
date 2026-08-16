#!/bin/sh
# Build the VLC addon package (dist/merge-playlist.vlp).
#
# A VLC addon is a plain zip holding manifest.xml at the root alongside the
# files it lists as <resource>. The layout mirrors the packages served by
# api-addons.videolan.org, which is what the Add-ons tab of
# Tools > Plugins and extensions installs from.
set -eu

cd "$(dirname "$0")"

name=merge-playlist
out="dist/$name.vlp"

# Keep the manifest's declared version and the extension's descriptor in step:
# the addons manager shows the manifest's, users see the descriptor's.
manifest_version=$(sed -n 's/.*<addon [^>]*version="\([^"]*\)".*/\1/p' manifest.xml)
script_version=$(sed -n 's/.*version *= *"\([^"]*\)".*/\1/p' merge_playlist.lua | head -1)

if [ "$manifest_version" != "$script_version" ]; then
    echo "version mismatch: manifest.xml says $manifest_version," \
         "merge_playlist.lua says $script_version" >&2
    exit 1
fi

# Every <resource> must actually be in the archive, or VLC installs a broken addon.
for resource in $(sed -n 's/.*<resource[^>]*>\(.*\)<\/resource>.*/\1/p' manifest.xml); do
    [ -f "$resource" ] || { echo "manifest lists a missing file: $resource" >&2; exit 1; }
done

rm -rf dist
mkdir -p dist
zip -q -X "$out" manifest.xml merge_playlist.lua

echo "built $out (version $manifest_version)"
unzip -l "$out"

#!/bin/sh
# Build the VLC add-on package (dist/merge-playlist.vlp) for upload to
# addons.videolan.org.
#
# A VLC add-on is a plain zip holding manifest.xml at the root alongside the
# files it lists as <resource>. The layout mirrors the packages served by
# api-addons.videolan.org, which is what the Add-ons tab of
# Tools > Plugins and extensions installs from.
#
# This is the only channel most users will ever see, and a bad package installs
# silently and then misbehaves, so everything checkable is checked here.
set -eu

cd "$(dirname "$0")"

out="dist/merge-playlist.vlp"

# Keep the manifest's declared version and the extension's descriptor in step:
# the add-ons manager shows the manifest's, the user sees the descriptor's.
manifest_version=$(sed -n 's/.*<addon [^>]*version="\([^"]*\)".*/\1/p' manifest.xml)
script_version=$(sed -n 's/.*version *= *"\([^"]*\)".*/\1/p' merge_playlist.lua | head -1)

if [ "$manifest_version" != "$script_version" ]; then
    echo "version mismatch: manifest.xml says $manifest_version," \
         "merge_playlist.lua says $script_version" >&2
    exit 1
fi

# Every <resource> must really be in the archive, or VLC installs a broken add-on.
resources=$(sed -n 's/.*<resource[^>]*>\(.*\)<\/resource>.*/\1/p' manifest.xml)
for resource in $resources; do
    [ -f "$resource" ] || { echo "manifest lists a missing file: $resource" >&2; exit 1; }
done

# The Lua has to at least parse; VLC reports a broken extension as nothing at all.
if command -v luac5.2 >/dev/null 2>&1; then
    luac5.2 -p merge_playlist.lua || exit 1
    rm -f luac.out
else
    echo "note: luac5.2 not found, skipping the syntax check" >&2
fi

# ...and it has to survive being loaded before the vlc API is fully present,
# or it vanishes from the View menu without a word. See test_load.lua.
if command -v lua5.2 >/dev/null 2>&1; then
    lua5.2 test_load.lua || exit 1
else
    echo "note: lua5.2 not found, skipping the load test" >&2
fi

rm -rf dist
mkdir -p dist

# Embed the icon. It lives in the package rather than in manifest.xml so the
# manifest stays readable and the two cannot drift apart.
python3 - "$manifest_version" <<'EOF'
import base64, sys, re

manifest = open("manifest.xml", encoding="utf-8").read()
icon = base64.b64encode(open("icon.png", "rb").read()).decode("ascii")
image = "      <image format=\"png\">%s</image>\n" % icon

# Look at markup only: the manifest's own comment mentions <image>.
if "<image" in re.sub(r"<!--.*?-->", "", manifest, flags=re.S):
    sys.exit("manifest.xml already carries an <image>; remove it")

# The add-ons schema expects <image> after <description>.
manifest, count = re.subn(r"(</description>\n)", r"\1" + image, manifest, count=1)
if count != 1:
    sys.exit("could not find </description> to anchor the icon to")

open("dist/manifest.xml", "w", encoding="utf-8").write(manifest)
EOF

( cd dist && zip -q -X "merge-playlist.vlp" manifest.xml )
zip -q -X "$out" $resources
rm -f dist/manifest.xml

echo "built $out (version $manifest_version)"
unzip -l "$out"

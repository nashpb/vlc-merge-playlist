# Merge Playlist into one File

A VLC 3.x Lua extension that joins every track of a playlist — honouring the
per-track `start-time` / `stop-time` set through `#EXTVLCOPT` — into a single
M4A file, from the GUI.

It is the GUI counterpart to:

```sh
vlc -I dummy --play-and-exit --sout-keep \
  --sout '#transcode{acodec=mp4a,ab=128,channels=2,samplerate=48000}:gather:std{access=file,mux=mp4,dst=out.m4a}' \
  playlist.m3u8
```

## Install

Copy `merge_playlist.lua` into VLC's extensions directory and restart VLC:

| OS      | Path                                                             |
|---------|------------------------------------------------------------------|
| Linux   | `~/.local/share/vlc/lua/extensions/`                             |
| Windows | `%APPDATA%\vlc\lua\extensions\`                                  |
| macOS   | `~/Library/Application Support/org.videolan.vlc/lua/extensions/`  |

Then: **View → Merge Playlist into one File**

## Use

1. Open the playlist in VLC as usual.
2. View → Merge Playlist into one File.
3. Check the output path and quality, press **Convert**.
4. Wait — roughly one minute per hour of audio. To abort, press **Cancel merge**.

VLC cannot play anything else while it works.

## Why M4A and not MP3

VLC's stream output has no MP3 muxer — `mux=raw` writes a bare frame stream with
no Xing header, no duration, and no tags, which makes players estimate the length
and seek by guesswork. The MP4 muxer writes a real duration and seek index.
Ogg and Opus were tested and rejected: `gather` and the Ogg muxer together drop
everything after the first track.

## Known limitations

- **Menu placement is fixed.** VLC 3's Qt interface builds its own menus and
  lists every extension under *View*. Putting this next to *Media → Save Playlist
  to File…* would require patching and shipping a forked VLC.
- **Progress updates only as often as VLC raises playback events.** There is no
  timer in the Lua API, so the merge is advanced by the input/playing/meta
  listener callbacks. The extension thread must never block: while it is busy,
  Qt cannot build or paint the dialog's widgets and the window renders blank.
- **Aborting discards the output.** An interrupted MP4 never gets its `moov` atom
  written and is unplayable, so the partial file is deleted.
- **Stopping early and a failed track look identical** from inside the extension,
  so the message covers both.
- **The output carries no tags.** VLC's stream output cannot write metadata.
- **VLC 3.x only.** VLC 4 rewrote the Lua playlist API.

## Diagnosing

VLC swallows extension errors: the dialog simply stops reacting and nothing is
shown. Every step is therefore mirrored to `merge_playlist.log` in VLC's cache
directory (`~/.cache/vlc/` on Linux), which is the first place to look.

## Development notes

`merge_playlist.lua` is deliberately written against a small, verified slice of
the VLC 3 Lua API. Nearly every constraint below was found by a failure that
gave no error message, so read the comments in the source before rearranging
anything.

**The conversion sequence**

- Playback must start on the first **child** of the expanded playlist node, not
  on the node itself, or track 1 is dropped with no error at all.
- Starting requires `gotoitem(id)` *then* `play()`. Neither alone works.
- A `vlc://nop` item must be played afterwards or the MP4 `moov` atom is never
  written and the output is unplayable. `playlist.stop()` does not release a
  kept stream output; nor does clearing `sout-keep`.
- Track durations must be snapshotted **before** playback: a playing track
  reports its source file's full length, not the trimmed segment.
- Identify the current track by matching its URI against that snapshot. Counting
  change events over-reports — transient inputs at startup each look like a new
  track, and a track's name changes mid-play when its ID3 title replaces the
  playlist's.
- Always quote `dst=` in the sout chain. Unquoted, an apostrophe in the path
  (`Al-Qur'an`) swallows the chain's closing brace and the file is written as
  `out.m4a}`. Backslashes must be doubled — that is every separator on Windows.

**The dialog**

- Never block the extension thread. While it is busy Qt cannot build or paint
  widgets, and the window renders as an empty rectangle. This is why the merge
  is driven by listener callbacks rather than a loop.
- Never call `dlg:delete()` from a listener callback: it deadlocks against the
  Qt thread and VLC has to be killed. Only build dialogs from button handlers;
  from a callback, restrict yourself to `set_text` and `update`.
- A deleted dialog's handle must be retained forever. Once collected, its
  finaliser throws `Can't get pointer to dialog` inside whatever unrelated
  callback happened to trigger the collection.
- The old dialog *must* be deleted before a new one will display. Hiding alone
  leaves the next page invisible.
- `widget:get_value()` returns **two** values, the id and its label, so
  `tonumber(w:get_value())` passes the label as a numeric base.
- Dropdowns return the first added value by default regardless of what they
  appear to show, so the recommended default has to be listed first.

**The sandbox**

The extension sandbox is not the interface sandbox. `vlc.misc` — the clock and
the sleep — is absent from extensions though present in `--lua-intf` scripts, so
a harness built on a Lua interface will happily pass code that cannot run. Strip
`vlc.misc` and `vlc.object` in any test harness. `os.time()` works for wall
clock; `os.clock()` does **not** (it is process CPU time and races ahead while
transcoding threads run). Never bound a loop by the clock alone — with no clock
it never exits and wedges VLC.

Verified against VLC 3.0.23 (Lua 5.2) on Linux. Windows and macOS are untested.

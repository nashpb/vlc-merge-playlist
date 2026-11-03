# Merge Playlist into one Video

A VLC 3.x Lua extension that joins every **video, image and audio file** of a playlist — in playlist order, honouring per-item `start-time` / `stop-time` / `image-duration` set through `#EXTVLCOPT` — into a single **MP4** file, from the GUI.

It is the video counterpart of [vlc-merge-playlist](https://github.com/amireh/vlc-merge-playlist) (audio-only, by Ahmad Amireh), whose dialog code and VLC quirk notes it builds on.

**Requires [ffmpeg](https://ffmpeg.org) to be installed.** VLC does the playlist and dialog; ffmpeg does the joining.

## Install

Copy `merge_playlist.lua` into VLC's extensions directory and restart VLC:

| OS      | Path                                                             |
|---------|------------------------------------------------------------------|
| Linux   | `~/.local/share/vlc/lua/extensions/`                             |
| Windows | `%APPDATA%\vlc\lua\extensions\`                                  |
| macOS   | `~/Library/Application Support/org.videolan.vlc/lua/extensions/` |

It then appears under **View → Merge Playlist into one Video**. `./package.sh` also builds `dist/merge-playlist-video.vlp`, the format VLC's add-on manager installs.

## Use

1. Open your playlist in VLC (or add the files to VLC's playlist).
2. View → Merge Playlist into one Video.
3. **To keep trims and per-item image durations**, type the path of the `.m3u8` file in *Playlist file*. VLC does not expose `#EXTVLCOPT` values of items already in its playlist, so without this the dialog merges the items in order with no trims.
4. Check *Save as*, *Picture size*, *Quality*, *Seconds per image* and the *ffmpeg* path (found automatically if it is on your PATH or in a common install folder).
5. Press **Merge**, then **Refresh** to see progress. VLC stays usable meanwhile.

## What it does with each kind of item

| Item | Result |
|---|---|
| Video with sound | Kept, trimmed if `start-time` / `stop-time` are set |
| Video without sound | Kept, with silence |
| Different size, shape or frame rate | Scaled to fit the chosen size with black bars, converted to 30 fps; phone rotation is applied |
| Image (jpg, png, bmp, webp, tif) | Shown for *Seconds per image*, or its own `image-duration`, with silence |
| Audio file | Played over its embedded cover art, or black if it has none |
| Animated GIF | Played once, silent |
| Missing files, web URLs, `vlc://` items | Skipped, and listed in `merge_playlist.log` |

Output: H.264 + AAC (192 kbps) MP4, with the index at the front so it can start playing while it downloads.

## How it works, and why ffmpeg

Each item is first turned into a short intermediate clip with the same size, frame rate and audio format, **with picture and sound made exactly the same length** (rounded to a whole number of frames). The clips are then joined without re-encoding the picture, and only the audio is encoded to AAC at the end. Equal lengths matter: a few milliseconds of mismatch per clip adds up to visibly drifting sound over a long playlist.

VLC's own stream output (`transcode` + `gather` + MP4 mux, which the audio-only version uses) was tried first with mixed videos and images and rejected:

- With H.264 the MP4 muxer loses the boundary marker between items, producing a wrong edit list so the video plays short.
- Trims are not sample-accurate under transcoding, and audio and picture lengths differ per file, so sync drifts further with each item.
- Images and silent videos need a made-up audio track, and some audio formats failed to join silently.

The extension writes a small shell script (`job.sh`, or `job.bat` on Windows) into VLC's cache folder (`…/merge_video_job`), starts it in the background, and reads its status files when you press Refresh (or whenever VLC raises a playback event). Nothing is changed in your source files.

## Known limitations

- **Progress is not live.** VLC's Lua API has no timer; press Refresh.
- **Preparing can freeze the dialog briefly** on very long playlists: each file is inspected once before the job starts, and Qt cannot repaint while that runs.
- **Cancel on Windows** stops after the current clip rather than instantly. On Linux/macOS it stops at once.
- **Disk space:** intermediate clips are uncompressed-audio and high-quality video and are deleted at the end; allow a few times the final size while it runs.
- Menu placement is fixed under *View* (VLC 3's Qt interface lists all extensions there). **VLC 3.x only**; VLC 4 rewrote the Lua playlist API.
- Tags and chapters are not written.

## Tested

Linux, VLC 3.0.20 (Qt) and ffmpeg 6.1: dialog opened from the View menu, merge run and finished from inside VLC, output checked with ffprobe (length matches the sum of the clips, picture and sound equal length, sound only where the source had it, every clip in the right place). The test set covered images, a trimmed video, a 4:3 video, a portrait video, a video without sound, an MP3 with cover art, a phone-rotated video, an animated GIF, and a filename containing `'` and `%`.

**Windows and macOS are untested.** The Windows launcher (`job.bat`, `start /B`) and the macOS ffmpeg search paths are written from documentation only; check the log (`merge_playlist.log` in VLC's cache folder) first if something does not start.

## Development notes

- VLC's extension sandbox lacks some standard Lua functions (for example `rawget`); a script using one fails to load and **silently disappears from the View menu**. `test_load.lua` cannot catch that, so load the script in real VLC (run `vlc -vv` and look for `Error loading script`).
- `test_load.lua` proves the script loads and describes itself against an empty `vlc` table; `package.sh` refuses to build if it fails, and also checks the manifest version, the declared resources and the Lua syntax.
- A looped cover image needs `setpts=N/(fps*TB)` after `loop`, or ffmpeg never reaches the end of the clip.
- Inherited from the audio version: never call `dlg:delete()` from a listener callback, keep deleted dialog handles alive forever, `widget:get_value()` returns two values, and the first dropdown entry is the default.
- `manifest.xml` carries this add-on's permanent `id`; never regenerate it.

## Licence

This is derived from vlc-merge-playlist, which does not state a licence in the repository. Check with the original author before publishing this elsewhere.

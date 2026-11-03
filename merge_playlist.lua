--[[
  Merge Playlist into one Video
  A VLC 3.x Lua extension that joins every video, image and audio file of a
  playlist -- in playlist order, honouring #EXTVLCOPT start-time / stop-time /
  image-duration -- into a single MP4 file.

  VLC's own stream output cannot do this reliably (see README), so the actual
  joining is done by ffmpeg, which must be installed. The extension builds a
  small script, starts it in the background and shows its progress.

  Install:
    Linux    ~/.local/share/vlc/lua/extensions/merge_playlist.lua
    Windows  %APPDATA%\vlc\lua\extensions\merge_playlist.lua
    macOS    ~/Library/Application Support/org.videolan.vlc/lua/extensions/merge_playlist.lua

  Then: View -> Merge Playlist into one Video

  Derived from vlc-merge-playlist (audio-only version) by Ahmad Amireh; the
  dialog plumbing and the VLC quirks documented below come from that work.

  Constraints inherited from VLC 3's Lua API (all fail silently):
    * Nothing at the top level of this file may touch the `vlc` table.
    * Never block the extension thread for long: Qt cannot paint while it is busy.
    * Never call dlg:delete() from a listener callback; only from button handlers.
    * widget:get_value() returns two values; wrap it in parentheses.
]]

--=============================================================================
-- configuration
--=============================================================================

local PLAYLIST_EXTS = { m3u = true, m3u8 = true, xspf = true, pls = true, asx = true, wpl = true }
local IMAGE_EXTS = { jpg = true, jpeg = true, jfif = true, png = true, bmp = true,
                     webp = true, tif = true, tiff = true }

-- The first entry of each list is what a dropdown returns unless the user picks
-- another, so the recommended default has to lead.
local SIZES = {
    { label = "1280 x 720  (HD)",        w = 1280, h = 720 },
    { label = "1920 x 1080  (Full HD)",  w = 1920, h = 1080 },
    { label = "854 x 480  (small file)", w = 854,  h = 480 },
}
local QUALITIES = {
    { label = "Good  (recommended)", crf = 22 },
    { label = "High  (bigger file)", crf = 18 },
    { label = "Smaller file",        crf = 27 },
}
local FPS = 30
local DEFAULT_IMAGE_SECONDS = 5
local AUDIO_KBPS = 192
local BAR_WIDTH = 28

local IS_WINDOWS = (package and package.config and package.config:sub(1, 1) == "\\") or false
local SEP = IS_WINDOWS and "\\" or "/"

--=============================================================================
-- state
--=============================================================================

local dlg = nil
local ui = {}
local sources = {}
local pending = nil     -- merge awaiting overwrite confirmation
local job = nil         -- the merge in flight
local trace_path = nil
local retained_dialogs = {}

--=============================================================================
-- helpers
--=============================================================================

--- Resolved on first use: vlc.config may not exist when VLC loads the script.
local function resolve_trace_path()
    if trace_path then return trace_path end
    trace_path = IS_WINDOWS and "merge_playlist.log" or "/tmp/merge_playlist.log"
    local ok, dir = pcall(function()
        if vlc and vlc.config and vlc.config.cachedir then return vlc.config.cachedir() end
    end)
    if ok and dir and dir ~= "" then trace_path = dir .. SEP .. "merge_playlist.log" end
    return trace_path
end

local function log(msg)
    pcall(function() vlc.msg.info("[merge_playlist] " .. tostring(msg)) end)
    pcall(function()
        local f = io.open(resolve_trace_path(), "a")
        if f then f:write(tostring(msg) .. "\n"); f:close() end
    end)
end

local function now() return os.time() end

local function basename(path) return (path or ""):match("([^/\\]+)$") or path or "" end
local function dirname(path)  return (path or ""):match("^(.*)[/\\][^/\\]*$") or "." end
local function extension(path) return ((path or ""):match("%.([%w]+)$") or ""):lower() end
local function value_of(widget) return (widget:get_value()) end

local function to_path(p)
    if not p or p == "" then return nil end
    if p:match("^%a[%w+.-]*://") then
        if not p:match("^[Ff][Ii][Ll][Ee]://") then return nil end   -- http, vlc://, dvd://...
        local ok, path = pcall(vlc.strings.make_path, p)
        if ok and path then return path end
        return (vlc.strings.decode_uri(p):gsub("^file://", ""))
    end
    return p
end

local function format_time(seconds)
    if not seconds or seconds < 0 then return "--:--" end
    seconds = math.floor(seconds)
    local h, m = math.floor(seconds / 3600), math.floor((seconds % 3600) / 60)
    if h > 0 then return string.format("%d:%02d:%02d", h, m, seconds % 60) end
    return string.format("%d:%02d", m, seconds % 60)
end

local function progress_bar(fraction)
    local filled = math.floor((fraction or 0) * BAR_WIDTH + 0.5)
    filled = math.max(0, math.min(BAR_WIDTH, filled))
    return string.rep("\226\150\136", filled) .. string.rep("\226\150\145", BAR_WIDTH - filled)
end

local function read_file(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local text = f:read("*a"); f:close()
    return text
end

local function write_file(path, text)
    local f, err = io.open(path, "wb")
    if not f then return false, err end
    f:write(text); f:close()
    return true
end

local function file_size(path)
    local f = io.open(path, "rb")
    if not f then return 0 end
    local n = f:seek("end") or 0
    f:close()
    return n
end

local function delete_file(path)
    pcall(function() os.remove(path) end)
    pcall(function() vlc.io.unlink(path) end)
end

local function escape_pattern(s) return (s:gsub("[^%w]", "%%%0")) end

--- Quote a value for the shell that will run it. `in_script` doubles % for .bat
--- files, where cmd.exe would otherwise expand it.
local function quote(s, in_script)
    s = tostring(s)
    if IS_WINDOWS then
        s = s:gsub('"', '""')
        if in_script then s = s:gsub("%%", "%%%%") end
        return '"' .. s .. '"'
    end
    return "'" .. s:gsub("'", "'\\''") .. "'"
end

local function shell_ok(cmd)
    local ok, _, code = os.execute(cmd)
    return ok == true or ok == 0 or code == 0
end

local function popen_read(cmd)
    if IS_WINDOWS then cmd = '"' .. cmd .. '"' end    -- cmd /c quote-stripping rule
    local f = io.popen(cmd, "r")
    if not f then return "" end
    local out = f:read("*a") or ""
    f:close()
    return out
end

--=============================================================================
-- ffmpeg
--=============================================================================

local function ffmpeg_works(path)
    if not path or path == "" then return false end
    local cmd = quote(path) .. " -version"
    cmd = cmd .. (IS_WINDOWS and " >NUL 2>&1" or " >/dev/null 2>&1")
    if IS_WINDOWS then cmd = '"' .. cmd .. '"' end
    return shell_ok(cmd)
end

--- GUI applications (macOS especially) often lack the shell's PATH, so also try
--- the places package managers install to.
local function find_ffmpeg()
    local candidates = { "ffmpeg" }
    if IS_WINDOWS then
        candidates[#candidates + 1] = "C:\\ffmpeg\\bin\\ffmpeg.exe"
        candidates[#candidates + 1] = "C:\\Program Files\\ffmpeg\\bin\\ffmpeg.exe"
    else
        for _, p in ipairs({ "/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg",
                             "/usr/bin/ffmpeg", "/snap/bin/ffmpeg" }) do
            candidates[#candidates + 1] = p
        end
    end
    for _, c in ipairs(candidates) do
        if ffmpeg_works(c) then return c end
    end
    return nil
end

--- Ask ffmpeg what a file contains. Images are not probed: a still has no
--- duration, and its length comes from the settings instead.
local function probe(ffmpeg, path)
    local out = popen_read(quote(ffmpeg) .. " -hide_banner -nostdin -i " .. quote(path) .. " 2>&1")
    local info = { video = false, cover = false, audio = false, duration = nil }
    for line in out:gmatch("[^\r\n]+") do
        if line:find("Stream #[%d:]+[^:]*: Video:") then
            if line:find("attached pic", 1, true) then info.cover = true else info.video = true end
        elseif line:find("Stream #[%d:]+[^:]*: Audio:") then
            info.audio = true
        end
    end
    local h, m, s = out:match("Duration:%s*(%d+):(%d+):([%d.]+)")
    if h then info.duration = tonumber(h) * 3600 + tonumber(m) * 60 + tonumber(s) end
    return info
end

--=============================================================================
-- reading the playlist
--=============================================================================

local function resolve_entry(raw, dir)
    if raw:match("^[Ff][Ii][Ll][Ee]://") then return to_path(raw) end
    if raw:match("^%a[%w+.-]*://") then return nil end
    if raw:match("^/") or raw:match("^%a:[/\\]") or raw:match("^\\\\") then return raw end
    return dir .. SEP .. raw
end

--- Parse an .m3u/.m3u8 ourselves: VLC does not expose the #EXTVLCOPT trims of
--- the playlist's entries to Lua. Returns items, number_skipped.
local function read_m3u(path)
    local text = read_file(path)
    if not text then return nil, 0 end
    text = text:gsub("^\239\187\191", "")
    local dir = dirname(path)
    local items, skipped, opts = {}, 0, {}
    for line in text:gmatch("[^\r\n]+") do
        line = line:gsub("^%s+", ""):gsub("%s+$", "")
        if line == "" then
            -- blank
        elseif line:sub(1, 1) == "#" then
            local k, v = line:match("^#EXTVLCOPT:([%w%-]+)=(.*)$")
            if k then opts[k] = v end
        else
            local p = resolve_entry(line, dir)
            if p then
                items[#items + 1] = {
                    path = p,
                    start = tonumber(opts["start-time"]),
                    stop = tonumber(opts["stop-time"]),
                    image_seconds = tonumber(opts["image-duration"]),
                }
            else
                skipped = skipped + 1
            end
            opts = {}
        end
    end
    return items, skipped
end

local function root_children()
    local ok, root = pcall(vlc.playlist.get, "playlist", false)
    if not ok or not root then return {} end
    return root.children or {}
end

local function collect_tree(list, out, skipped)
    for _, item in ipairs(list) do
        if item.children and #item.children > 0 then
            collect_tree(item.children, out, skipped)
        else
            local p = to_path(item.path)
            if p and not PLAYLIST_EXTS[extension(p)] then
                out[#out + 1] = { path = p }
            elseif not p then
                skipped.n = skipped.n + 1
            end
        end
    end
end

local function find_sources()
    local found = {}
    for _, item in ipairs(root_children()) do
        local path = to_path(item.path)
        local ext = extension(path)
        if ext == "m3u" or ext == "m3u8" then
            found[#found + 1] = { kind = "m3u", path = path, label = basename(path) }
        elseif item.children and #item.children > 0 then
            found[#found + 1] = { kind = "tree", list = item.children,
                                  label = (basename(path) ~= "" and basename(path)) or item.name or "playlist" }
        end
    end
    local everything = { n = 0 }
    local all = {}
    collect_tree(root_children(), all, everything)
    if #all > 0 then
        found[#found + 1] = { kind = "all", label = "Everything in the VLC playlist", count = #all }
    end
    return found
end

local function load_items(source)
    if source.kind == "m3u" then return read_m3u(source.path) end
    local out, skipped = {}, { n = 0 }
    if source.kind == "tree" then collect_tree(source.list, out, skipped)
    else collect_tree(root_children(), out, skipped) end
    return out, skipped.n
end

local function default_output_for(source, items)
    if source.kind == "m3u" then return (source.path:gsub("%.[%w]+$", "")) .. ".mp4" end
    local first = items and items[1] and items[1].path
    return (first and dirname(first) or ".") .. SEP .. "merged.mp4"
end

--=============================================================================
-- building the job
--=============================================================================

-- Every clip is normalised to the same picture size, frame rate and audio
-- format, with video and audio lengths made exactly equal, then the clips are
-- joined without re-encoding the picture. Exact lengths matter: a few
-- milliseconds of error per clip would otherwise add up to visible drift.
local function video_filters(o)
    return table.concat({
        "scale=w=iw*sar:h=ih", "setsar=1",
        string.format("scale=%d:%d:force_original_aspect_ratio=decrease:force_divisible_by=2", o.w, o.h),
        string.format("pad=%d:%d:(ow-iw)/2:(oh-ih)/2:color=black", o.w, o.h),
        "setsar=1", "fps=" .. FPS, "format=yuv420p",
    }, ",")
end

local AUDIO_FILTERS = "aresample=48000,aformat=sample_fmts=s16:channel_layouts=stereo"
local SILENCE = "-f lavfi -i anullsrc=channel_layout=stereo:sample_rate=48000"

local function seconds(n) return string.format("%.6f", n) end

--- Describe how to turn one playlist item into a normalised clip. Returns nil
--- and a reason when the item cannot be used.
local function plan_item(ffmpeg, item, o)
    local ext = extension(item.path)
    if file_size(item.path) == 0 then return nil, "file not found" end

    local plan = { name = basename(item.path), item = item }
    if IMAGE_EXTS[ext] then
        plan.kind = "image"
        plan.length = item.image_seconds or o.image_seconds
    else
        local info = probe(ffmpeg, item.path)
        if not (info.video or info.cover or info.audio) then return nil, "not a media file" end
        plan.kind = info.video and "video" or "audio"
        plan.info = info
        local stop = item.stop
        if info.duration and (not stop or stop > info.duration) then stop = info.duration end
        if stop then plan.length = stop - (item.start or 0) end
    end

    if plan.length then
        if plan.length <= 0 then return nil, "empty time range" end
        plan.frames = math.max(1, math.floor(plan.length * FPS + 0.5))
        plan.length = plan.frames / FPS
    end
    return plan
end

local function segment_command(ffmpeg, plan, index, o)
    local inputs, vlabel, alabel = {}, nil, nil
    local exact = plan.length ~= nil
    local vpre = ""
    local ss = plan.item.start and ("-ss " .. seconds(plan.item.start) .. " ") or ""

    if plan.kind == "image" then
        inputs[1] = string.format("-f image2 -pattern_type none -loop 1 -framerate %d -i %s",
                                  FPS, quote(plan.item.path, true))
        inputs[2] = SILENCE
        vlabel, alabel = "[0:v]", "[1:a]"
    elseif plan.kind == "video" then
        inputs[1] = ss .. "-i " .. quote(plan.item.path, true)
        vlabel = "[0:v:0]"
        if plan.info.audio then alabel = "[0:a:0]" else inputs[2] = SILENCE; alabel = "[1:a]" end
    else   -- audio only: show the cover art if there is one, black otherwise
        inputs[1] = ss .. "-i " .. quote(plan.item.path, true)
        alabel = "[0:a:0]"
        if plan.info.cover then
            vlabel = "[0:v:0]"
            -- A looped single frame keeps its timestamp unless it is renumbered.
            vpre = "loop=loop=-1:size=1,setpts=N/(" .. FPS .. "*TB),"
        else
            inputs[2] = string.format("-f lavfi -i color=c=black:s=%dx%d:r=%d", o.w, o.h, FPS)
            vlabel = "[1:v]"
        end
    end

    local vf = vpre .. video_filters(o)
    local af = AUDIO_FILTERS
    if exact then
        vf = vf .. ",tpad=stop=-1:stop_mode=clone"
        af = af .. ",apad"
    end
    vf = vf .. ",setpts=PTS-STARTPTS"
    af = af .. ",asetpts=PTS-STARTPTS"

    local out = string.format("seg%04d.mov", index)
    local limit = exact and ("-t " .. seconds(plan.length)) or "-shortest"
    local cmd = table.concat({
        quote(ffmpeg, true), "-nostdin -hide_banner -loglevel error -y",
        table.concat(inputs, " "),
        "-filter_complex", quote(vlabel .. vf .. "[v];" .. alabel .. af .. "[a]", true),
        "-map [v] -map [a]", limit,
        string.format("-c:v libx264 -preset veryfast -crf %d -pix_fmt yuv420p -r %d", o.crf, FPS),
        "-c:a pcm_s16le -ar 48000 -ac 2", out,
    }, " ")
    return cmd, out
end

--- Produce the shell script for the whole job. Pure text generation, so it can
--- be tested without VLC.
local function build_script(ffmpeg, plans, o)
    local lines, list = {}, {}
    local function add(s) lines[#lines + 1] = s end
    local total = #plans + 1
    local partial = o.output .. ".partial.mp4"

    if IS_WINDOWS then
        add("@echo off")
        add("cd /d " .. quote(o.dir, true))
        add("echo running> status.txt")
    else
        add("#!/bin/sh")
        add("cd " .. quote(o.dir) .. " || exit 1")
        add("echo $$ > pid")
        add("echo running > status.txt")
    end

    for i, plan in ipairs(plans) do
        local cmd, seg = segment_command(ffmpeg, plan, i, o)
        list[#list + 1] = "file '" .. seg .. "'"
        if IS_WINDOWS then
            add("if exist cancel.flag goto cancelled")
            add(cmd .. " 2>> log.txt")
            add("if errorlevel 1 goto failed")
            add("echo " .. i .. "> progress.txt")
        else
            add("[ -e cancel.flag ] && { echo cancelled > status.txt; exit 0; }")
            add(cmd .. " 2>> log.txt || { echo failed > status.txt; exit 1; }")
            add("echo " .. i .. " > progress.txt")
        end
    end

    local final = table.concat({
        quote(ffmpeg, true), "-nostdin -hide_banner -loglevel error -y",
        "-f concat -safe 0 -i list.txt -map 0:v:0 -map 0:a:0",
        string.format("-c:v copy -c:a aac -b:a %dk -movflags +faststart -f mp4", AUDIO_KBPS),
        quote(partial, true),
    }, " ")
    if IS_WINDOWS then
        add("if exist cancel.flag goto cancelled")
        add(final .. " 2>> log.txt")
        add("if errorlevel 1 goto failed")
        add("move /Y " .. quote(partial, true) .. " " .. quote(o.output, true) .. " >NUL")
        add("if errorlevel 1 goto failed")
        add("echo done> status.txt")
        add("exit /b 0")
        add(":cancelled")
        add("del " .. quote(partial, true) .. " 2>NUL")
        add("echo cancelled> status.txt")
        add("exit /b 0")
        add(":failed")
        add("del " .. quote(partial, true) .. " 2>NUL")
        add("echo failed> status.txt")
        add("exit /b 1")
    else
        add("[ -e cancel.flag ] && { echo cancelled > status.txt; exit 0; }")
        add(final .. " 2>> log.txt || { rm -f " .. quote(partial) .. "; echo failed > status.txt; exit 1; }")
        add("mv -f " .. quote(partial) .. " " .. quote(o.output) .. " || { echo failed > status.txt; exit 1; }")
        add("echo done > status.txt")
    end
    return table.concat(lines, IS_WINDOWS and "\r\n" or "\n") .. (IS_WINDOWS and "\r\n" or "\n"),
           table.concat(list, "\n") .. "\n", total
end

--=============================================================================
-- dialog pages
--=============================================================================

local on_convert, start_merge, on_cancel_merge, on_refresh, show_setup

local function reset_dialog()
    if dlg then
        pcall(function() dlg:hide() end)
        pcall(function() dlg:delete() end)
        retained_dialogs[#retained_dialogs + 1] = dlg    -- see README: never let it be collected
    end
    dlg = vlc.dialog("Merge Playlist into one Video")
    ui = {}
end

local function guarded(name, fn)
    return function(...)
        local ok, err = pcall(fn, ...)
        if not ok then
            log("!! " .. name .. " failed: " .. tostring(err))
            pcall(function()
                reset_dialog()
                ui.title = dlg:add_label("<b>Something went wrong</b>", 1, 1, 3, 1)
                ui.detail = dlg:add_label("<b>" .. name .. "</b> failed:<br><br>" .. tostring(err)
                    .. "<br><br>A copy is in " .. resolve_trace_path(), 1, 2, 3, 1)
                ui.back = dlg:add_button("Back", function() show_setup() end, 2, 3, 1, 1)
                ui.close = dlg:add_button("Close", function() vlc.deactivate() end, 3, 3, 1, 1)
                dlg:show()
            end)
        end
    end
end

local function show_message(headline, detail)
    reset_dialog()
    ui.title = dlg:add_label("<b>" .. headline .. "</b>", 1, 1, 3, 1)
    ui.detail = dlg:add_label(detail or "", 1, 2, 3, 1)
    ui.back = dlg:add_button("Back", function() show_setup() end, 2, 3, 1, 1)
    ui.close = dlg:add_button("Close", function() vlc.deactivate() end, 3, 3, 1, 1)
    dlg:show()
end

local ffmpeg_guess = nil

show_setup = function()
    reset_dialog()
    sources = find_sources()

    if #sources == 0 then
        dlg:add_label("<b>Nothing to merge.</b><br>Open a playlist file (.m3u8) or add your "
            .. "videos and images to VLC's playlist first, then run this again.", 1, 1, 3, 1)
        dlg:add_button("Close", function() vlc.deactivate() end, 3, 2, 1, 1)
        dlg:show()
        return
    end
    if ffmpeg_guess == nil then ffmpeg_guess = find_ffmpeg() or false end

    local row = 1
    dlg:add_label("<b>Playlist</b>", 1, row, 1, 1)
    ui.src = dlg:add_dropdown(2, row, 2, 1)
    for index, source in ipairs(sources) do
        local text = source.label
        if source.count then text = string.format("%s  (%d items)", text, source.count) end
        ui.src:add_value(text, index)
    end

    row = row + 1
    dlg:add_label("<b>Playlist file</b>", 1, row, 1, 1)
    ui.file = dlg:add_text_input("", 2, row, 2, 1)

    row = row + 1
    dlg:add_label("<b>Save as</b>", 1, row, 1, 1)
    local first_items = nil
    if sources[1].kind ~= "m3u" then first_items = load_items(sources[1]) end
    ui.out = dlg:add_text_input(default_output_for(sources[1], first_items), 2, row, 2, 1)

    row = row + 1
    dlg:add_label("<b>Picture size</b>", 1, row, 1, 1)
    ui.size = dlg:add_dropdown(2, row, 2, 1)
    for i, s in ipairs(SIZES) do ui.size:add_value(s.label, i) end

    row = row + 1
    dlg:add_label("<b>Quality</b>", 1, row, 1, 1)
    ui.quality = dlg:add_dropdown(2, row, 2, 1)
    for i, q in ipairs(QUALITIES) do ui.quality:add_value(q.label, i) end

    row = row + 1
    dlg:add_label("<b>Seconds per image</b>", 1, row, 1, 1)
    ui.secs = dlg:add_text_input(tostring(DEFAULT_IMAGE_SECONDS), 2, row, 1, 1)

    row = row + 1
    dlg:add_label("<b>ffmpeg</b>", 1, row, 1, 1)
    ui.ffmpeg = dlg:add_text_input(ffmpeg_guess or "ffmpeg", 2, row, 2, 1)

    row = row + 1
    local hint = "Videos, images and audio files are joined in playlist order into one MP4.<br>"
              .. "To keep start-time / stop-time trims and per-item image-duration, type the path "
              .. "of the .m3u8 playlist file in <b>Playlist file</b> (VLC does not pass those on "
              .. "for items already in its playlist)."
    if not ffmpeg_guess then
        hint = "<b>ffmpeg was not found.</b> Install it (ffmpeg.org) or type its full path above.<br>" .. hint
    end
    dlg:add_label(hint, 1, row, 3, 1)

    row = row + 1
    ui.convert = dlg:add_button("Merge", guarded("Merge", function() on_convert() end), 2, row, 1, 1)
    dlg:add_button("Close", function() vlc.deactivate() end, 3, row, 1, 1)
    dlg:show()
end

local function confirm_overwrite(output)
    reset_dialog()
    dlg:add_label("<b>" .. basename(output) .. " already exists</b>", 1, 1, 3, 1)
    dlg:add_label("Merging will replace it. The existing file cannot be recovered "
        .. "afterwards.<br><br>" .. output, 1, 2, 3, 1)
    dlg:add_button("Replace", guarded("Replace", function() start_merge() end), 2, 3, 1, 1)
    dlg:add_button("Back", function() show_setup() end, 3, 3, 1, 1)
    dlg:show()
end

local function show_progress_page(source_label, output)
    reset_dialog()
    ui.title = dlg:add_label("<b>Merging " .. source_label .. "</b>", 1, 1, 3, 1)
    ui.track = dlg:add_label("Starting\226\128\166", 1, 2, 3, 1)
    ui.bar = dlg:add_label(progress_bar(0), 1, 3, 3, 1)
    ui.eta = dlg:add_label("", 1, 4, 3, 1)
    dlg:add_label("\226\134\146 " .. output, 1, 5, 3, 1)
    ui.note = dlg:add_label("<i>Press Refresh to update. You can keep using VLC meanwhile.</i>", 1, 6, 3, 1)
    ui.refresh = dlg:add_button("Refresh", guarded("Refresh", function() on_refresh() end), 1, 7, 1, 1)
    ui.stop = dlg:add_button("Cancel merge", guarded("Cancel", function() on_cancel_merge() end), 2, 7, 1, 1)
    dlg:show()
end

--=============================================================================
-- running the job
--=============================================================================

local function job_file(name) return job.dir .. SEP .. name end

local function read_status()
    local s = read_file(job_file("status.txt"))
    return s and s:match("%a+") or nil
end

local function read_progress()
    local p = read_file(job_file("progress.txt"))
    return tonumber(p and p:match("%d+")) or 0
end

local function pid_alive()
    if IS_WINDOWS then return true end
    local pid = (read_file(job_file("pid")) or ""):match("%d+")
    if not pid then return true end     -- not written yet
    return shell_ok("kill -0 " .. pid .. " >/dev/null 2>&1")
end

local function cleanup_job_dir(dir)
    local ok, entries = pcall(vlc.io.readdir, dir)
    if not ok or not entries then return end
    for _, name in ipairs(entries) do
        if name ~= "log.txt" and name ~= "." and name ~= ".." then
            delete_file(dir .. SEP .. name)
        end
    end
end

--- Update the progress page in place. Only set_text/update are safe from the
--- listener callbacks that also call this.
local function set_result(headline, detail, fraction)
    if not (dlg and ui.title and ui.track) then return end
    pcall(function() ui.title:set_text("<b>" .. headline .. "</b>") end)
    pcall(function() ui.track:set_text(detail or "") end)
    pcall(function() ui.bar:set_text(string.format("%s  %d%%", progress_bar(fraction), math.floor(fraction * 100))) end)
    pcall(function() ui.eta:set_text("") end)
    pcall(function() ui.note:set_text("") end)
    pcall(function() ui.stop:set_text("Close") end)
    pcall(function() dlg:update() end)
end

local function refresh()
    if not job or job.finished then return end
    local status = read_status()
    local done_steps = read_progress()
    local total = job.total

    if status == "running" and not pid_alive() then status = "failed" end

    if status == "done" or status == "failed" or status == "cancelled" then
        job.finished = true
        local output, dir, skipped = job.output, job.dir, job.skipped
        local log_note = ""
        if status == "failed" then
            local tail = (read_file(dir .. SEP .. "log.txt") or ""):gsub("%s+$", "")
            tail = tail:sub(-400)
            log_note = "<br><br>ffmpeg said:<br>" .. tail:gsub("\n", "<br>")
                    .. "<br><br>Full log: " .. dir .. SEP .. "log.txt"
        end
        local elapsed = format_time(now() - job.t0)
        local plans = #job.plans
        if status == "done" then
            local extra = skipped > 0 and string.format("<br>%d item(s) were skipped (see merge_playlist.log).", skipped) or ""
            set_result("Done", string.format("Saved <b>%s</b><br>%d clips \226\128\148 %.0f MB \226\128\148 took %s.%s",
                basename(output), plans, file_size(output) / (1024 * 1024), elapsed, extra), 1)
        elseif status == "cancelled" then
            set_result("Cancelled", "The merge was stopped and no file was written.", 0)
        else
            set_result("The merge failed", "ffmpeg stopped with an error." .. log_note, done_steps / total)
        end
        cleanup_job_dir(dir)
        job = nil
        return
    end

    local fraction = math.min(done_steps / total, 0.99)
    local label
    if done_steps >= #job.plans then label = "Joining everything together\226\128\166"
    else label = string.format("Clip %d of %d \226\128\148 %s", done_steps + 1, #job.plans,
                                job.plans[done_steps + 1].name) end
    pcall(function() ui.track:set_text(label) end)
    pcall(function() ui.bar:set_text(string.format("%s  %d%%", progress_bar(fraction), math.floor(fraction * 100))) end)
    local elapsed = now() - job.t0
    local eta = ""
    if done_steps > 0 then
        eta = string.format("Elapsed %s \226\128\148 about %s left", format_time(elapsed),
                            format_time(elapsed / done_steps * (total - done_steps)))
    else
        eta = "Elapsed " .. format_time(elapsed)
    end
    pcall(function() ui.eta:set_text(eta) end)
    pcall(function() dlg:update() end)
end

on_refresh = function() refresh() end

on_cancel_merge = function()
    if not job then return vlc.deactivate() end
    log("cancelled by the user")
    write_file(job_file("cancel.flag"), "1")
    if not IS_WINDOWS then
        -- The job's scripts and ffmpeg commands all mention the job directory.
        os.execute("pkill -f " .. quote(escape_pattern(job.dir)) .. " >/dev/null 2>&1")
        write_file(job_file("status.txt"), "cancelled\n")
        delete_file(job.output .. ".partial.mp4")
    else
        pcall(function() ui.track:set_text("Stopping after the current clip\226\128\166") end)
        pcall(function() dlg:update() end)
        return          -- the script notices cancel.flag and stops by itself
    end
    refresh()
end

start_merge = function()
    if job or not pending then return end
    local p = pending
    pending = nil

    show_progress_page(p.source.label, p.output)
    delete_file(p.output)

    local items, skipped = load_items(p.source)
    if not items or #items == 0 then
        return show_message("Nothing to merge", "The playlist has no usable entries.")
    end

    local plans = {}
    for _, item in ipairs(items) do
        local plan, why = plan_item(p.ffmpeg, item, p)
        if plan then plans[#plans + 1] = plan
        else skipped = skipped + 1; log("skipped " .. item.path .. ": " .. tostring(why)) end
    end
    if #plans == 0 then
        return show_message("Nothing to merge", "None of the playlist's entries could be read.")
    end

    local base = (function()
        local ok, dir = pcall(function() return vlc.config.cachedir() end)
        return (ok and dir and dir ~= "") and dir or dirname(p.output)
    end)()
    local dir = base .. SEP .. "merge_video_job"
    pcall(vlc.io.mkdir, dir, "0700")
    cleanup_job_dir(dir)
    delete_file(dir .. SEP .. "log.txt")

    p.dir = dir
    local script, list, total = build_script(p.ffmpeg, plans, p)
    local script_path = dir .. SEP .. (IS_WINDOWS and "job.bat" or "job.sh")
    local ok1 = write_file(script_path, script)
    local ok2 = write_file(dir .. SEP .. "list.txt", list)
    if not (ok1 and ok2) then
        return show_message("Could not start", "Could not write the working files in " .. dir)
    end
    write_file(dir .. SEP .. "status.txt", "running\n")
    write_file(dir .. SEP .. "progress.txt", "0\n")

    job = { dir = dir, plans = plans, total = total, output = p.output, skipped = skipped,
            t0 = now(), finished = false }
    log(string.format("merging %d clips into %s", #plans, p.output))

    if IS_WINDOWS then
        os.execute('start "" /B ' .. quote(script_path))
    else
        os.execute("sh " .. quote(script_path) .. " >/dev/null 2>&1 &")
    end
    refresh()
end

on_convert = function()
    if job then return end
    local source = sources[tonumber(value_of(ui.src))]
    local file = (ui.file:get_text() or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if file ~= "" then
        if file_size(file) == 0 then
            return show_message("Playlist file not found", "Could not open <b>" .. file .. "</b>.")
        end
        source = { kind = "m3u", path = file, label = basename(file) }
    end
    local output = ui.out:get_text()
    local size = SIZES[tonumber(value_of(ui.size))] or SIZES[1]
    local quality = QUALITIES[tonumber(value_of(ui.quality))] or QUALITIES[1]
    local image_seconds = tonumber(ui.secs:get_text())
    local ffmpeg = ui.ffmpeg:get_text()

    if not source then return show_message("Nothing to merge", "Could not resolve the selected playlist.") end
    if not output or output == "" then return show_message("No output file", "Please choose where to save the video.") end
    if not image_seconds or image_seconds <= 0 then
        return show_message("Seconds per image", "Please enter a number greater than zero.")
    end
    if not ffmpeg_works(ffmpeg) then
        return show_message("ffmpeg not found", "Could not run <b>" .. tostring(ffmpeg) .. "</b>.<br><br>"
            .. "Install ffmpeg (ffmpeg.org) or type its full path on the previous page.")
    end
    if extension(output) ~= "mp4" then output = output .. ".mp4" end

    pending = { source = source, output = output, w = size.w, h = size.h, crf = quality.crf,
                image_seconds = image_seconds, ffmpeg = ffmpeg }
    if file_size(output) > 0 then return confirm_overwrite(output) end
    return start_merge()
end

--=============================================================================
-- extension entry points
--=============================================================================

function descriptor()
    return {
        title = "Merge Playlist into one Video",
        version = "2.0",
        author = "",
        shortdesc = "Merge Playlist into one Video",
        description = "Joins the videos, images and audio files of a playlist, in order, "
                   .. "into a single MP4. Needs ffmpeg.",
        -- Playback events are the only clock available, so they refresh the progress page.
        capabilities = { "input-listener", "playing-listener", "meta-listener" },
    }
end

function activate() show_setup() end

function deactivate()
    if dlg then pcall(function() dlg:hide() end) end
end

function close() vlc.deactivate() end

local function on_event(name)
    local ok, err = pcall(refresh)
    if not ok then log("!! " .. name .. ": " .. tostring(err)) end
end

function input_changed() on_event("input_changed") end
function playing_changed() on_event("playing_changed") end
function meta_changed() on_event("meta_changed") end

-- Test hook: lets test harnesses reach the pure parts. Never set inside VLC.
if MERGE_PLAYLIST_TEST then
    return { read_m3u = read_m3u, plan_item = plan_item, build_script = build_script,
             find_ffmpeg = find_ffmpeg, probe = probe, quote = quote }
end

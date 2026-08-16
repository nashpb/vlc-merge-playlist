--[[
  Merge Playlist into one File
  A VLC 3.x Lua extension that concatenates every track of a playlist -- honouring
  the per-track start-time/stop-time set via #EXTVLCOPT -- into a single M4A file.

  Install:
    Linux    ~/.local/share/vlc/lua/extensions/merge_playlist.lua
    Windows  %APPDATA%\vlc\lua\extensions\merge_playlist.lua
    macOS    ~/Library/Application Support/org.videolan.vlc/lua/extensions/merge_playlist.lua

  Then: View -> Merge Playlist into one File

  The merge is driven by VLC's listener callbacks rather than by a loop. That is
  not a stylistic choice: while the extension thread is busy, Qt cannot build or
  paint the dialog's widgets, so a polling loop leaves the user staring at an
  empty window. Every callback must therefore return promptly.

  Other behaviours worked around here fail silently -- see README.
]]

--=============================================================================
-- configuration
--=============================================================================

local PLAYLIST_EXTS = {
    m3u = true, m3u8 = true, xspf = true, pls = true, asx = true, wpl = true,
}

-- The first entry is what the dropdown shows and returns unless the user picks
-- another, so the recommended default has to lead.
local BITRATES = { "128", "192", "256", "96" }
local DEFAULT_BITRATE = 128

local EXPAND_TIMEOUT = 10   -- seconds to wait for the playlist to expand
local START_TIMEOUT = 10    -- seconds to wait for playback to begin
local POLL = 0.25
local BAR_WIDTH = 28

--- Where the diagnostic trace goes. Extension errors are otherwise invisible,
--- so this file is the only way to find out what happened. /tmp does not exist
--- on Windows, so ask VLC where its cache lives.
local TRACE_PATH = (function()
    local separator = (package and package.config and package.config:sub(1, 1)) or "/"
    local ok, dir = pcall(vlc.config.cachedir)
    if ok and dir and dir ~= "" then
        return dir .. separator .. "merge_playlist.log"
    end
    return "/tmp/merge_playlist.log"
end)()

--=============================================================================
-- state
--=============================================================================

local dlg = nil
local ui = {}          -- widgets of the current dialog page
local sources = {}     -- playlist-file candidates found in the playlist
local pending = nil    -- job awaiting overwrite confirmation
local job = nil        -- the merge in flight

--=============================================================================
-- helpers
--=============================================================================

-- Extension errors are invisible by default: VLC swallows them and the dialog
-- simply stops reacting. Mirror everything to a file as well as the log.
local function log(msg)
    vlc.msg.info("[merge_playlist] " .. tostring(msg))
    pcall(function()
        local f = io.open(TRACE_PATH, "a")
        if f then
            f:write(tostring(msg) .. "\n")
            f:close()
        end
    end)
end

--- Wall-clock seconds. Deliberately not os.clock(), which is process CPU time
--- and races ahead of real time while the transcoding threads are busy.
local function now()
    if vlc.misc and vlc.misc.mdate then return vlc.misc.mdate() / 1000000 end
    if os and os.time then return os.time() end
    return nil
end

--- vlc.misc, which owns the real sleep, is absent from the extension sandbox.
local function sleep(seconds)
    if vlc.misc and vlc.misc.mwait then
        vlc.misc.mwait(vlc.misc.mdate() + seconds * 1000000)
    elseif os and os.clock then
        local deadline = os.clock() + seconds
        while os.clock() < deadline do end
    end
end

local function is_playing()
    if vlc.input and vlc.input.is_playing then
        local ok, playing = pcall(vlc.input.is_playing)
        if ok then return playing end
    end
    if vlc.object and vlc.object.input then return vlc.object.input() ~= nil end
    return false
end

local function playlist_stopped()
    local ok, status = pcall(vlc.playlist.status)
    return ok and status == "stopped"
end

local function to_path(p)
    if not p or p == "" then return nil end
    if p:match("^%a[%w+.-]*://") then
        local ok, path = pcall(vlc.strings.make_path, p)
        if ok and path then return path end
        return (vlc.strings.decode_uri(p):gsub("^file://", ""))
    end
    return p
end

--- The parentheses matter: get_value() returns the id AND its label, so passing
--- the call straight into tonumber() hands the label over as a numeric base.
local function value_of(widget)
    return (widget:get_value())
end

local function basename(path)
    return (path or ""):match("([^/\\]+)$") or path
end

local function format_time(seconds)
    if not seconds or seconds < 0 then return "--:--" end
    seconds = math.floor(seconds)
    local h = math.floor(seconds / 3600)
    local m = math.floor((seconds % 3600) / 60)
    if h > 0 then return string.format("%d:%02d:%02d", h, m, seconds % 60) end
    return string.format("%d:%02d", m, seconds % 60)
end

local function progress_bar(fraction)
    local filled = math.floor((fraction or 0) * BAR_WIDTH + 0.5)
    if filled < 0 then filled = 0 end
    if filled > BAR_WIDTH then filled = BAR_WIDTH end
    return string.rep("\226\150\136", filled)
        .. string.rep("\226\150\145", BAR_WIDTH - filled)
end

--- Output size so far, used for the percentage: more reliable than input
--- position, which is relative to the untrimmed source file.
local function file_size(path)
    local ok, size = pcall(function()
        local f = io.open(path, "rb")
        if not f then return 0 end
        local n = f:seek("end") or 0
        f:close()
        return n
    end)
    return ok and size or 0
end

local function delete_file(path)
    pcall(function() os.remove(path) end)
    pcall(function() vlc.io.unlink(path) end)
end

local function root_children()
    local ok, root = pcall(vlc.playlist.get, "playlist", false)
    if not ok or not root then return {} end
    return root.children or {}
end

local function find_item(id)
    for _, item in ipairs(root_children()) do
        if item.id == id then return item end
    end
    return nil
end

local function find_sources()
    local found = {}
    for _, item in ipairs(root_children()) do
        local path = to_path(item.path)
        local ext = ((path or ""):match("%.([%w]+)$") or ""):lower()
        local expanded = item.children and #item.children > 0
        if PLAYLIST_EXTS[ext] or expanded then
            found[#found + 1] = {
                id = item.id,
                path = path,
                label = basename(path) or item.name,
                tracks = expanded and #item.children or nil,
            }
        end
    end
    return found
end

local function default_output_for(path)
    return ((path or ""):gsub("%.[%w]+$", "")) .. ".m4a"
end

--- One-off record of what this build puts in the extension sandbox. It differs
--- from the interface sandbox and the difference is documented nowhere.
local function probe_sandbox()
    local names = {}
    for key, value in pairs(vlc) do names[#names + 1] = key .. ":" .. type(value) end
    table.sort(names)
    log("SANDBOX vlc = " .. table.concat(names, " "))
    log("SANDBOX os=" .. type(os) .. " io=" .. type(io)
     .. " os.time=" .. type(os and os.time))
end

--=============================================================================
-- dialog pages
--=============================================================================

local on_convert, on_confirm_overwrite, on_cancel_merge, show_setup

-- Deleted dialogs are parked here forever, never dropped. See reset_dialog.
local retained_dialogs = {}

--- Build a fresh dialog page.
---
--- The old dialog must be deleted, not merely hidden: VLC will not display a
--- new dialog while a previous one is alive, and hiding alone makes the next
--- page silently fail to appear.
---
--- But a deleted dialog's collector throws "Can't get pointer to dialog", and
--- that error lands inside whatever unrelated callback happens to trigger the
--- collection -- once aborting the merge's own teardown. Keeping a reference
--- forever means the collector never runs. A few stale handles per session is a
--- cheap price for removing an error that can strike anywhere.
---
--- Only ever call this from a button handler. dlg:delete() from a listener
--- callback deadlocks against the Qt thread and VLC has to be killed.
local function reset_dialog()
    if dlg then
        pcall(function() dlg:hide() end)
        pcall(function() dlg:delete() end)
        retained_dialogs[#retained_dialogs + 1] = dlg
    end
    dlg = vlc.dialog("Merge Playlist into one File")
    ui = {}
end

--- Report the outcome by rewriting the progress page in place. A merge can
--- finish inside a listener callback, where building a new dialog is unsafe,
--- and set_text/update are the only dialog calls proven to work there.
local function show_result_in_place(headline, detail, fraction)
    if not (dlg and ui.title and ui.track) then return false end
    pcall(function() ui.title:set_text("<b>" .. headline .. "</b>") end)
    pcall(function() ui.track:set_text(detail or "") end)
    pcall(function() ui.bar:set_text(string.format("%s  %d%%",
        progress_bar(fraction), math.floor(fraction * 100))) end)
    pcall(function() ui.eta:set_text("") end)
    pcall(function() ui.note:set_text("") end)
    pcall(function() ui.stop:set_text("Close") end)
    pcall(function() dlg:update() end)
    return true
end

local function show_result(headline, detail)
    reset_dialog()
    ui.title = dlg:add_label("<b>" .. headline .. "</b>", 1, 1, 3, 1)
    ui.detail = dlg:add_label(detail or "", 1, 2, 3, 1)
    ui.again = dlg:add_button("Back", function() show_setup() end, 2, 3, 1, 1)
    ui.close = dlg:add_button("Close", function() vlc.deactivate() end, 3, 3, 1, 1)
    dlg:show()
end

--- Wrap a callback so a Lua error reaches the dialog instead of vanishing.
local function guarded(name, fn)
    return function(...)
        local ok, err = pcall(fn, ...)
        if not ok then
            log("!! " .. name .. " failed: " .. tostring(err))
            pcall(show_result, "Something went wrong",
                  "<b>" .. name .. "</b> failed:<br><br>" .. tostring(err)
               .. "<br><br>A copy of this is in " .. TRACE_PATH)
        end
    end
end

show_setup = function()
    reset_dialog()
    sources = find_sources()

    if #sources == 0 then
        ui.msg = dlg:add_label(
            "<b>No playlist found.</b><br>Open a playlist file (.m3u8, .xspf, "
         .. "...) in VLC first, then run this again.", 1, 1, 3, 1)
        ui.close = dlg:add_button("Close", function() vlc.deactivate() end, 3, 2, 1, 1)
        dlg:show()
        return
    end

    ui.src_label = dlg:add_label("<b>Playlist</b>", 1, 1, 1, 1)
    ui.src = dlg:add_dropdown(2, 1, 2, 1)
    for index, source in ipairs(sources) do
        local text = source.label
        if source.tracks then
            text = string.format("%s  (%d tracks)", text, source.tracks)
        end
        ui.src:add_value(text, index)
    end

    ui.out_label = dlg:add_label("<b>Save as</b>", 1, 2, 1, 1)
    ui.out = dlg:add_text_input(default_output_for(sources[1].path), 2, 2, 2, 1)

    ui.rate_label = dlg:add_label("<b>Quality</b>", 1, 3, 1, 1)
    ui.rate = dlg:add_dropdown(2, 3, 1, 1)
    for _, rate in ipairs(BITRATES) do
        ui.rate:add_value(rate .. " kbps stereo", tonumber(rate))
    end

    ui.hint = dlg:add_label(
        "The tracks are joined into one AAC/M4A file, keeping each track's "
     .. "start and stop times.<br>VLC cannot play anything else while it works "
     .. "(roughly one minute per hour of audio).", 1, 4, 3, 1)

    ui.convert = dlg:add_button("Convert", guarded("Convert", function() on_convert() end), 2, 5, 1, 1)
    ui.cancel = dlg:add_button("Close", function() vlc.deactivate() end, 3, 5, 1, 1)
    dlg:show()
end

local function confirm_overwrite(output)
    reset_dialog()
    ui.title = dlg:add_label("<b>" .. basename(output) .. " already exists</b>", 1, 1, 3, 1)
    ui.detail = dlg:add_label(
        "Merging will replace it. The existing file cannot be recovered "
     .. "afterwards.<br><br>" .. output, 1, 2, 3, 1)
    ui.ok = dlg:add_button("Replace",
        guarded("Replace", function() on_confirm_overwrite() end), 2, 3, 1, 1)
    ui.back = dlg:add_button("Back", function() show_setup() end, 3, 3, 1, 1)
    dlg:show()
end

local function show_progress_page(source_label, output)
    reset_dialog()
    ui.title = dlg:add_label("<b>Merging " .. source_label .. "</b>", 1, 1, 3, 1)
    ui.track = dlg:add_label("Starting\226\128\166", 1, 2, 3, 1)
    ui.bar = dlg:add_label(progress_bar(0), 1, 3, 3, 1)
    ui.eta = dlg:add_label("", 1, 4, 3, 1)
    ui.out = dlg:add_label("\226\134\146 " .. output, 1, 5, 3, 1)
    ui.note = dlg:add_label(
        "<i>Progress steps forward as each track finishes.</i>", 1, 6, 3, 1)
    ui.stop = dlg:add_button("Cancel merge",
        guarded("Cancel", function() on_cancel_merge() end), 2, 7, 1, 1)
    dlg:show()
end

local function update_progress()
    if not job or not ui.track then return end

    -- Two independent estimates, whichever is further along. Bytes written give
    -- movement within a track; completed track durations keep the bar honest if
    -- the output cannot be measured at all.
    local fraction = 0
    if job.expected_bytes and job.expected_bytes > 0 then
        fraction = file_size(job.output) / job.expected_bytes
    end
    if job.total_seconds > 0 then
        local done = 0
        for index = 1, math.min(job.index - 1, #job.tracks) do
            done = done + job.tracks[index].duration
        end
        fraction = math.max(fraction, done / job.total_seconds)
    end
    if fraction > 0.99 then fraction = 0.99 end

    ui.track:set_text(string.format("Track %d of %d \226\128\148 %s",
        math.max(job.index, 1), #job.tracks, job.name or "?"))
    ui.bar:set_text(string.format("%s  %d%%",
        progress_bar(fraction), math.floor(fraction * 100)))

    local elapsed = job.t0 and now() and (now() - job.t0) or nil
    if elapsed and fraction > 0.02 and elapsed > 2 then
        ui.eta:set_text(string.format("Elapsed %s \226\128\148 about %s left",
            format_time(elapsed), format_time(elapsed / fraction - elapsed)))
    elseif elapsed then
        ui.eta:set_text("Elapsed " .. format_time(elapsed))
    end
    dlg:update()
end

--=============================================================================
-- the merge
--=============================================================================

--- Quote a path for a sout chain. An unquoted value ends at the first special
--- character, so an apostrophe -- as in Al-Qur'an -- swallows the chain's
--- closing brace and the file is written as "wird-3.m4a}". Backslashes have to
--- be doubled, which is every separator in a Windows path.
local function sout_quote(path)
    return '"' .. (path:gsub("\\", "\\\\"):gsub('"', '\\"')) .. '"'
end

local function build_sout(output, bitrate)
    return string.format(
        "#transcode{acodec=mp4a,ab=%d,channels=2,samplerate=48000}"
     .. ":gather:std{access=file,mux=mp4,dst=%s}", bitrate, sout_quote(output))
end

--- Add our own copy of the playlist file carrying the sout options, leaving the
--- user's own entry untouched. Returns the new node's id.
local function add_conversion_item(source_path, sout)
    local before = {}
    for _, item in ipairs(root_children()) do before[item.id] = true end

    vlc.playlist.add({{
        path = vlc.strings.make_uri(source_path),
        options = { ":sout=" .. sout, ":sout-keep" },
    }})

    for _, item in ipairs(root_children()) do
        if not before[item.id] then return item.id end
    end
    return nil
end

--- Wait for VLC to preparse the playlist file into children, and snapshot their
--- durations now: once a track plays, its reported duration becomes the source
--- file's full length rather than the trimmed segment.
local function await_expansion(node_id)
    for _ = 1, math.ceil(EXPAND_TIMEOUT / POLL) do
        sleep(POLL)
        local node = find_item(node_id)
        if node and node.children and #node.children > 0 then
            local tracks, total = {}, 0
            for index, child in ipairs(node.children) do
                local duration = math.max(child.duration or 0, 0)
                -- Keep each track's location: the current track is identified by
                -- matching against these, never by counting change events.
                tracks[index] = {
                    id = child.id,
                    duration = duration,
                    key = to_path(child.path) or child.path,
                }
                total = total + duration
            end
            return tracks, total
        end
    end
    return nil, 0
end

--- Play a throwaway item so VLC tears down the kept stream output. Without it
--- the MP4 moov atom is never written and the file is unplayable. Note that
--- playlist.stop() does NOT have this effect.
local function flush_sout()
    local before = {}
    for _, item in ipairs(root_children()) do before[item.id] = true end

    log("flush: add vlc://nop")
    vlc.playlist.add({{ path = "vlc://nop" }})

    local nop_id
    for _, item in ipairs(root_children()) do
        if not before[item.id] then nop_id = item.id end
    end
    if not nop_id then log("flush: no nop item"); return end

    log("flush: gotoitem " .. tostring(nop_id))
    vlc.playlist.gotoitem(nop_id)
    sleep(0.3)
    log("flush: play")
    vlc.playlist.play()
    sleep(2)
    log("flush: delete nop")
    pcall(function() vlc.playlist.delete(nop_id) end)
    log("flush: done")
end

--- Tear down and report. Called once, from whichever callback notices the end.
local function finish_merge(reason)
    if not job or job.state ~= "running" then return end
    job.state = "finishing"

    local tracks, reached, output = #job.tracks, job.index, job.output
    local total_seconds, node_id = job.total_seconds, job.node_id
    local matched = job.matched
    log(string.format("finishing (%s): reached track %d of %d (matched=%s)",
        reason, reached, tracks, tostring(matched)))

    -- Wrapped: an error escaping here would skip the flush, and without the
    -- flush the MP4 has no moov atom and the whole merge is unplayable. That
    -- already happened once, via a stray collector error.
    log("finish: entering flush_sout (context=" .. tostring(reason) .. ")")
    local flushed, flush_err = pcall(flush_sout)
    if not flushed then log("!! flush_sout failed: " .. tostring(flush_err)) end
    log("finish: deleting conversion node " .. tostring(node_id))
    pcall(function() vlc.playlist.delete(node_id) end)
    log("finish: node deleted")
    job = nil

    -- Only discard when we are sure it is incomplete. If no track ever matched
    -- the snapshot we cannot judge, and keeping a possibly-short file beats
    -- deleting a good one.
    if reason == "cancelled" or (matched and reached < tracks) then
        delete_file(output)
        local detail = string.format(
            "Only %d of %d tracks were merged, so the partial file was "
         .. "discarded \226\128\148 an interrupted M4A is not playable.",
            reached, tracks)
        if not show_result_in_place("Stopped early", detail, 0) then
            log("could not report in place: " .. detail)
        end
        return
    end

    local detail = string.format(
        "Saved <b>%s</b><br>%s of audio \226\128\148 %.0f MB \226\128\148 "
     .. "%d tracks merged.",
        basename(output), format_time(total_seconds),
        file_size(output) / (1024 * 1024), tracks)
    if not show_result_in_place("Done", detail, 1) then
        log("could not report in place: " .. detail)
    end
end

--- Advance the merge. Called from VLC's listener callbacks, and must return
--- promptly: while this thread is busy, Qt cannot paint the dialog.
local function tick()
    if not job or job.state ~= "running" then return end

    if is_playing() then
        job.started = true
        job.misses = 0

        local item = vlc.input.item()
        local name = (item and item:name()) or "?"

        -- Look the current track up in the snapshot rather than counting
        -- change events. Counting over-reported badly: transient inputs at
        -- startup each looked like a new track, and a track's name changes
        -- part-way through when its ID3 title replaces the playlist's.
        local ok, uri = pcall(function() return item and item:uri() end)
        local key = ok and uri and (to_path(uri) or uri) or nil
        if key then
            for index, track in ipairs(job.tracks) do
                if track.key == key then
                    job.matched = true
                    if index ~= job.index then
                        job.index = index
                        log(string.format("track %d/%d: %s", index, #job.tracks, name))
                    end
                    break
                end
            end
        end

        job.name = name
        update_progress()
        return
    end

    if not job.started then
        job.misses = (job.misses or 0) + 1
        if job.misses > 40 then
            log("playback never started")
            finish_merge("never started")
        end
        return
    end

    -- Playback also drops out briefly between tracks, so only a stopped
    -- playlist means the run is over.
    if playlist_stopped() then finish_merge("end of playlist") end
end

local function start_merge()
    if job then return end
    if not pending then return end

    local source, output = pending.source, pending.output
    local bitrate = pending.bitrate
    pending = nil

    show_progress_page(source.label, output)
    delete_file(output)

    local node_id = add_conversion_item(source.path, build_sout(output, bitrate))
    if not node_id then
        return show_result("Could not start",
            "VLC would not accept the playlist for conversion.")
    end

    local tracks, total_seconds = await_expansion(node_id)
    if not tracks then
        pcall(function() vlc.playlist.delete(node_id) end)
        return show_result("Could not read the playlist",
            "VLC did not expand " .. source.label .. " into tracks.")
    end

    job = {
        state = "running",
        node_id = node_id,
        tracks = tracks,
        total_seconds = total_seconds,
        output = output,
        expected_bytes = (bitrate * 1000 / 8) * total_seconds,
        index = 0,
        matched = false,
        misses = 0,
        started = false,
        t0 = now(),
    }
    log(string.format("merging %d tracks, %s of audio, into %s at %dk",
        #tracks, format_time(total_seconds), output, bitrate))

    vlc.playlist.gotoitem(tracks[1].id)
    sleep(0.3)
    vlc.playlist.play()
    update_progress()
    -- Return now: the listener callbacks drive the rest, and the dialog can
    -- only be painted while this thread is idle.
end

on_convert = function()
    if job then return end

    local source = sources[tonumber(value_of(ui.src))]
    local output = ui.out:get_text()
    local bitrate = tonumber(value_of(ui.rate)) or DEFAULT_BITRATE

    if not source then
        return show_result("Nothing to merge", "Could not resolve the selected playlist.")
    end
    if not output or output == "" then
        return show_result("No output file", "Please choose where to save the merged file.")
    end

    pending = { source = source, output = output, bitrate = bitrate }
    if file_size(output) > 0 then return confirm_overwrite(output) end
    return start_merge()
end

on_confirm_overwrite = function()
    return start_merge()
end

on_cancel_merge = function()
    -- Once the merge is over this button has been relabelled "Close", so it
    -- must close rather than bounce the user back to the setup prompt.
    if not job then return vlc.deactivate() end

    -- Escape hatch: if every track has already been converted and playback has
    -- stopped, the end-of-playlist event simply never reached us. Finish the
    -- file rather than throwing away a complete merge.
    if not is_playing() and job.matched and job.index >= #job.tracks then
        log("finishing on request; the end-of-playlist event never arrived")
        return finish_merge("end of playlist")
    end

    log("cancelled by the user")
    pcall(vlc.playlist.stop)
    sleep(0.5)
    finish_merge("cancelled")
end

--=============================================================================
-- extension entry points
--=============================================================================

function descriptor()
    return {
        title = "Merge Playlist into one File",
        version = "0.2",
        author = "",
        shortdesc = "Merge Playlist into one File",
        description = "Joins every track of a playlist into a single M4A audio "
                   .. "file, keeping each track's start/stop times.",
        -- These listeners are the extension's only clock: there is no timer in
        -- the Lua API, so the merge is advanced by playback events.
        capabilities = { "input-listener", "playing-listener", "meta-listener" },
    }
end

function activate()
    pcall(probe_sandbox)
    show_setup()
end

function deactivate()
    if job then pcall(on_cancel_merge) end
    if dlg then pcall(function() dlg:hide() end) end
end

function close()
    vlc.deactivate()
end

--- Listener errors are only logged. Rebuilding the dialog from here is what
--- deadlocked VLC: an error in one callback triggered a dialog rebuild, and
--- dlg:delete() never returned.
local function on_event(name)
    local ok, err = pcall(tick)
    if not ok then log("!! " .. name .. ": " .. tostring(err)) end
end

function input_changed() on_event("input_changed") end
function playing_changed() on_event("playing_changed") end
function meta_changed() on_event("meta_changed") end

--[[
  Load-time safety test. Run with: lua5.2 test_load.lua

  VLC loads an extension script to read its descriptor() before the full API is
  necessarily in place. Anything at the top level of the script that touches the
  vlc table can therefore throw, and a script that throws while loading does not
  fail loudly -- it silently disappears from the View menu, with no message in
  the log and nothing to click. That happened once and cost a release.

  So: prove the script loads and describes itself even against an empty vlc
  table. package.sh runs this and refuses to build if it fails.
]]

local SCRIPT = "merge_playlist.lua"

-- Progressively poorer environments, worst last.
local environments = {
    { name = "config present", vlc = {
        msg = { info = function() end },
        config = { cachedir = function() return "/tmp" end },
    } },
    { name = "no vlc.config", vlc = { msg = { info = function() end } } },
    { name = "empty vlc table", vlc = {} },
}

local failures = 0

for _, env in ipairs(environments) do
    vlc = env.vlc

    local chunk, load_err = loadfile(SCRIPT)
    if not chunk then
        print(string.format("FAIL  %-16s cannot be parsed: %s", env.name, load_err))
        failures = failures + 1
    else
        local ran, run_err = pcall(chunk)
        if not ran then
            print(string.format("FAIL  %-16s top-level error: %s", env.name, run_err))
            failures = failures + 1
        else
            local ok, d = pcall(descriptor)
            if not ok then
                print(string.format("FAIL  %-16s descriptor() error: %s", env.name, d))
                failures = failures + 1
            elseif type(d) ~= "table" or not d.title or not d.version then
                print(string.format("FAIL  %-16s descriptor() is incomplete", env.name))
                failures = failures + 1
            else
                print(string.format("ok    %-16s %s %s", env.name, d.title, d.version))
            end
        end
    end
end

if failures > 0 then
    print(failures .. " failure(s): the extension would vanish from the View menu")
    os.exit(1)
end
print("all load environments ok")

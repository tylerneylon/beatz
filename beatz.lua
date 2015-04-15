--[[ beatz/beatz.lua

This is a command-line audio track playing and editing module.

It is designed to work as both a stand-alone app and to
provide a programmatic interface to working with tracks and loops.

A *note* is a single sound.  A *loop* is a finite set of notes, along
with rhythmic data; musically, this is a finite set of measures.
A loop may optionally include the specification of which instrument
is meant to be used to play it.
A *track* is a collection of loops, along with optional instrumentation
and repeating data.

TODO Finalize this usage comment.

Projected usage:
  local beatz = require 'beatz'

  beatz.play('my_file.beatz')

  -- or
  
  my_track = beatz.load('my_file.beatz')
  my_track:play()

--]]

require 'strict'  -- Enforce careful global variable usage.

local beatz = {}


--------------------------------------------------------------------------------
-- Require modules.
--------------------------------------------------------------------------------

local events     = require 'events'
local instrument = require 'instrument'
local usleep     = require 'usleep'


--------------------------------------------------------------------------------
-- The environment used to load beatz files.
--------------------------------------------------------------------------------

local load_env = {}

function load_env.add_notes(track)
  local chars_per_beat = track.chars_per_beat
  if chars_per_beat == nil then error('Missing chars_per_beat value') end

  local track_str = track[1]
  if track_str == nil then error('Missing note data') end

  local notes = {}
  for i = 1, #track_str do
    local note = track_str:sub(i, i)
    if note ~= ' ' then
      local beat = (i - 1) / chars_per_beat
      if track.swing and beat % 1 == 0.5 then
        beat = beat + 0.1
      end
      notes[#notes + 1] = {beat, note}
    end
  end

  track.notes = notes

  track.num_beats = #track_str / chars_per_beat
end

function load_env.new_track(track)
  add_notes(track)
  table.insert(tracks, track)
end

-- Let all load_env functions easily call each other.
for _, f in pairs(load_env) do
  setfenv(f, load_env)
end
load_env.table = table


--------------------------------------------------------------------------------
-- Public functions.
--------------------------------------------------------------------------------

function beatz.load(filename)
  -- Load and parse the file.
  local file_fn, err_msg = loadfile(filename)
  if file_fn == nil then error(err_msg) end

  -- Process the file contents.
  load_env.tracks = {}
  setfenv(file_fn, load_env)
  file_fn()

  return load_env.tracks  -- Return the table of loaded tracks.
end

function beatz.play(filename)
  local tracks = beatz.load(filename)


  local track = tracks[1]
  if track == nil then error('No track to play') end

  local inst_name = track.instrument
  if inst_name == nil then error('No instrument assigned with track') end

  local inst = instrument.load(inst_name)

  local track     = tracks[1]
  local notes     = track.notes
  local num_beats = track.num_beats

  local ind = 1
  local loops_done = 0

  local play_at_beat = notes[ind][1]

  local i = 0
  while true do

    if i % 3 == 0 then
      local this_beat = i / 23
      --print('this_beat =', this_beat)

      if this_beat >= play_at_beat then
        inst:play(notes[ind][2])
        ind = ind + 1
        if ind > #notes then
          ind = 1
          loops_done = loops_done + 1
        end
        play_at_beat = notes[ind][1] + loops_done * num_beats
        --print('play_at_beat =', play_at_beat)
      end

    end

    usleep(10 * 1000) -- Operate at 100 hz.
    i = i + 1
  end
end


--------------------------------------------------------------------------------
-- Support stand-alone usage.
--------------------------------------------------------------------------------

if arg then
  local filename = arg[#arg]
  if filename and #arg >= 2 then
    beatz.play(filename)
  end
end


--------------------------------------------------------------------------------
-- Return.
--------------------------------------------------------------------------------

return beatz

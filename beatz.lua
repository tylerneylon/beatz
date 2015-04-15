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





  -- TEMP
  print('Main track is:')
  print(string.format('"%s"', tracks[1][1]))

  local notes = tracks[1].notes
  for _, note in ipairs(notes) do
    print(note[1], note[2])
  end

end

function beatz.old_play(filename)
  
  -- TEMP For now, we'll just play a hard-coded loop.

  local s = {'a', 'e', 'f', 'b'}

  local track = {
    { 0, 'a'},
    { 1, 'b'},
    { 2, 'e'},
    { 3.6, 'c'},

    { 4   , 'd'},
    { 4.6, 'c'},
    { 5,  'd'},
    { 6,    'e'},
    { 7,   'f'},
    
    { 8, 'a'},
    { 9, 'b'},
    { 10, 'e'},
    { 11.6, 'c'},
    { 12  , 'd'},
    { 14,   'f'},

    --[[
    { 3, 'e'},
    { 4, 'a'},
    { 5, 'b'},
    { 6, 'e'},
    { 7, 'e'},
    { 8, 'a'},
    {12, 'f'}
    --]]
  }
  local num_beats = 16
  local ind = 1
  local loops_done = 0
  
  local play_at_beat = track[ind][1]

  local drums = instrument.load('human_drumkit')
  local i = 0
  while true do

    if i % 3 == 0 then
      local this_beat = i / 23
      --print('this_beat =', this_beat)

      if this_beat >= play_at_beat then
        drums:play(track[ind][2])
        ind = ind + 1
        if ind > #track then
          ind = 1
          loops_done = loops_done + 1
        end
        play_at_beat = track[ind][1] + loops_done * num_beats
        --print('play_at_beat =', play_at_beat)
      end

    end

    usleep(10 * 1000) -- Operate at 100 hz.
    i = i + 1
  end
end


--------------------------------------------------------------------------------
-- Return.
--------------------------------------------------------------------------------

return beatz

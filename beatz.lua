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

local events     = require 'events'
local instrument = require 'instrument'

local beatz = {}


--------------------------------------------------------------------------------
-- Require modules.
--------------------------------------------------------------------------------

-- TODO

--------------------------------------------------------------------------------
-- Public functions.
--------------------------------------------------------------------------------

function beatz.play(filename)
  -- TEMP For now, we'll just play a hard-coded loop.
  local drums = instrument.load('human_drumkit')
end


--------------------------------------------------------------------------------
-- Return.
--------------------------------------------------------------------------------

return beatz

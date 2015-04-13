--[[ beatz/instrument.lua

A class to capture a single instrument.

On disk, an instrument is a set of sound files kept together in a single subdir
of the instruments dir.

TODO Clarify actual usage.

Projected usage:

  -- This is to load audio files in the dir instruments/my_drumkit.
  instrument = require 'instrument'
  drums = instrument.load('my_drumkit')
  drums:play('a')

--]]

require 'strict'  -- Enforce careful global variable usage.

local sounds = require 'sounds'


local instrument = {}

-------------------------------------------------------------------------------
-- Internal variables and functions.
-------------------------------------------------------------------------------


-------------------------------------------------------------------------------
-- Class interface.
-------------------------------------------------------------------------------

function instrument:new()
  local new_inst = {}
  return setmetatable(new_inst, {__index = self})
end


-------------------------------------------------------------------------------
-- Public functions.
-------------------------------------------------------------------------------

function instrument.load(inst_name)
  
end


return instrument

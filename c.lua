sounds = require 'sounds'
a = sounds.load('instruments/practice/a.wav')
a:play()

mt = getmetatable(a)
print('a =', a)
if mt.playing == nil then
  print('mt.playing == nil')
else
  print('#mt.playing =', #mt.playing)
end

function sleep(n)
  local end_time = os.time() + n
  while os.time() < end_time do end
end

sounds = require 'sounds'
a = sounds.load('instruments/practice/a.wav')
a:play()
a = nil
collectgarbage()
sleep(3)


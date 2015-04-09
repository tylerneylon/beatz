// beatz/c/sounds.m
//

#include "sounds.h"

#include "luajit/lauxlib.h"
#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>


// This is the Lua registry key for the sounds metatable.
#define sounds_mt "sounds_mt"


///////////////////////////////////////////////////////////////////////////////
// Internal globals and types.
///////////////////////////////////////////////////////////////////////////////

static int next_index = 1;

typedef struct {
  AudioQueueRef               queue;
  char *                      bytes;
  size_t                      num_bytes;
  char *                      cursor;
  int                         index;  // Index in the sounds_mt.playing table.
  int                         is_running;
  AudioStreamBasicDescription audioDesc;
  int                         do_stop;
} Sound;


///////////////////////////////////////////////////////////////////////////////
// Internal function declarations.
///////////////////////////////////////////////////////////////////////////////

static void setup_queue_for_sound(lua_State *L, Sound *sound);

void running_status_changed(void *userData, AudioQueueRef audioQueue,
                            AudioQueuePropertyID property);
void sound_play_callback(void *userData, AudioQueueRef inAQ,
                         AudioQueueBufferRef buffer);

static int delete_sound(lua_State* L);
static int play_sound(lua_State *L);
static int stop_sound(lua_State *L);


///////////////////////////////////////////////////////////////////////////////
// Internal utility functions.
///////////////////////////////////////////////////////////////////////////////


// This assumes lua_State *L is in scope, which I consider good practice anyway.
#define jump_out_if_bad(status, fmt, ...) \
        if (status) { luaL_error(L, fmt, ##__VA_ARGS__); }

// For debugging.
static void print_stack_types(lua_State *L) {
  printf("Stack types: [");
  int n = lua_gettop(L);
  for (int i = 1; i <= n; ++i) {
    printf(i == 1 ? "" : ", ");
    int tp = lua_type(L, i);
    const char *typename = lua_typename(L, tp);
    printf("%s", typename);
    if (tp == LUA_TTABLE || tp == LUA_TUSERDATA) {
      lua_pushvalue(L, i);
      const void *ptr = lua_topointer(L, -1);
      lua_pop(L, 1);
      printf("(%p)", ptr);
    }
  }
  printf("]\n");
}

// TODO Move this into a separate objective-C file for reference on
//      how to extract specific error information.
static void print_err_if_bad(OSStatus status, NSString *whence) {
  if (status == 0) return;
  
  NSError *error = [NSError errorWithDomain:NSOSStatusErrorDomain code:status userInfo:nil];
  
  NSLog(@"Error from %@", whence);
  NSLog(@"The error is %@", error);
}

static void read_entire_file(lua_State *L, const char *filename, Sound *sound) {
  // Open the file.
  NSString *fileName = [NSString stringWithUTF8String:filename];
  NSURL *   fileURL  = [NSURL URLWithString:fileName];
  ExtAudioFileRef audioFile;
  OSStatus status    = ExtAudioFileOpenURL((__bridge CFURLRef)fileURL,
                                           &audioFile);
  jump_out_if_bad(status, "Failed to open file: '%s'", filename);
  
  UInt32 audioDescSize = sizeof(sound->audioDesc);
  status = ExtAudioFileGetProperty(audioFile,
                                   kExtAudioFileProperty_FileDataFormat,
                                   &audioDescSize,
                                   &sound->audioDesc);
  jump_out_if_bad(status, "Unable to read properties of audio file '%s'", filename);

  // Prepare initial buffer structure before we start reading.
  const size_t chunk_size = 8192;
  size_t full_size        = 0;
  char * full_ptr         = NULL;
  int bytes_per_frame     = sound->audioDesc.mBytesPerFrame;
  AudioBuffer audioBuffer = {
    .mNumberChannels = 2,
    .mDataByteSize   = chunk_size };
  AudioBufferList bufferList = { .mNumberBuffers = 1, .mBuffers = audioBuffer };
  UInt32 numFrames, totalFrames = 0;

  do {
    // Update the buffer and numFrames to receive new data.
    AudioBuffer *buffer = &bufferList.mBuffers[0];
    full_size    += chunk_size;
    full_ptr      = realloc(full_ptr, full_size);
    buffer->mData = full_ptr + full_size - chunk_size;
    numFrames     = chunk_size / bytes_per_frame;

    // Receive new data.
    OSStatus status = ExtAudioFileRead(audioFile, &numFrames, &bufferList);
    jump_out_if_bad(status, "Error while reading file '%s'", filename);

    totalFrames += numFrames;
  } while (numFrames);

  sound->bytes     = full_ptr;
  sound->num_bytes = totalFrames * bytes_per_frame;
  sound->cursor    = full_ptr;

  status = ExtAudioFileDispose(audioFile);
  if (status != 0) {
    // Non-fatal error; report but keep going anyway.
    printf("Warning: failed to close the file '%s'\n", filename);
  }
}

// This pushes the sounds_mt.playing table to the top of the stack. It creates
// the table if it doesn't exist yet.
static void get_playing_table(lua_State *L) {
  luaL_getmetatable(L, sounds_mt);   // -> [sounds_mt]
  lua_getfield(L, -1, "playing");    // -> [sounds_mt, sounds_mt.playing]
  if (lua_isnil(L, -1)) {
    lua_pop(L, 1);                   // -> [sounds_mt]
    lua_newtable(L);                 // -> [sounds_mt, playing]
    lua_pushvalue(L, -1);            // -> [sounds_mt, playing, playing]
    lua_setfield(L, -3, "playing");  // -> [sounds_mt, playing]
  }
  lua_remove(L, -2);                 // -> [sounds_mt.playing ~= nil]
}

// Function to load an audio file.
static int load_file(lua_State *L) {
  // TEMP TODO Remove debug stuff and clean up this fn.
  //printf("start of %s\n", __FUNCTION__);

  // TODO Test behavior when no param or a nonstring is given.
  const char *filename = luaL_checkstring(L, 1);

  //printf("Got the filename '%s'\n", filename);

  // push new_obj = {}
  Sound *sound = lua_newuserdata(L, sizeof(Sound));
  *sound = (Sound) {
    .queue      = NULL,
    .bytes      = NULL,
    .num_bytes  = 0,
    .cursor     = NULL,
    .index      = next_index++,
    .is_running = 0,
    .do_stop    = 0
  };
  //printf("is_running set to 0\n");

  // push sounds_mt = {__gc = delete_sound}
  if (luaL_newmetatable(L, sounds_mt)) {
    lua_pushcfunction(L, delete_sound);
    lua_setfield(L, -2, "__gc");

    lua_pushvalue(L, -1);
    lua_setfield(L, -2, "__index");

    lua_pushcfunction(L, play_sound);
    lua_setfield(L, -2, "play");

    lua_pushcfunction(L, stop_sound);
    lua_setfield(L, -2, "stop");
  }

  // setmetatable(new_obj, sounds_mt)
  lua_setmetatable(L, -2);

  read_entire_file(L, filename, sound);

  setup_queue_for_sound(L, sound);

  //sound->queue = load_queue_for_file(filename);

  //printf("end of %s\n", __FUNCTION__);

  return 1;
}

static void setup_queue_for_sound(lua_State *L, Sound *sound) {
  // TEMP
  //printf("%s\n", __FUNCTION__);

  //printf("AudioQueueNewOutput start\n");
  OSStatus status = AudioQueueNewOutput(&sound->audioDesc,
                                        sound_play_callback,
                                        sound,  // user data
                                        NULL, /* CFRunLoopGetCurrent(), */
                                        kCFRunLoopCommonModes,
                                        0,     // reserved flags; must be 0
                                        &sound->queue);
  //printf("AudioQueueNewOutput done\n");
  jump_out_if_bad(status, "Error creating new audio output stream.");
  
  for (int i = 0; i < 2; ++i) {
    UInt32 bufferByteSize = 4 * 1024;
    AudioQueueBufferRef buffer;
    //printf("AudioQueueAllocateBuffer start\n");
    status = AudioQueueAllocateBuffer(sound->queue,
                                      bufferByteSize,
                                      &buffer);
    //printf("AudioQueueAllocateBuffer done\n");
    jump_out_if_bad(status, "Error priming audio buffers for playback.");
    sound_play_callback(sound,  // user data
                        sound->queue,
                        buffer);
  }

  // 0 --> decode all buffers; NULL --> no need for #decoded frames.
  status = AudioQueuePrime(sound->queue, 0, NULL);
  jump_out_if_bad(status, "Error priming audio queue.");
  
  //printf("AudioQueueAddPropertyListener start\n");
  status = AudioQueueAddPropertyListener(sound->queue,
                                         kAudioQueueProperty_IsRunning,
                                         running_status_changed,
                                         sound);  // user data
  //printf("AudioQueueAddPropertyListener done\n");
  jump_out_if_bad(status, "Error attaching play/stop listener to playback stream.");
}


///////////////////////////////////////////////////////////////////////////////
// Internal Lua functions.
///////////////////////////////////////////////////////////////////////////////

// We want to avoid deleting an object that's actively being played. To ensure
// that, we add a sound to sound_mt.playing when it starts playing, and remove
// it from that table when it stops.
static int delete_sound(lua_State* L) {

  // TEMP
  //printf("%s start\n", __FUNCTION__);

  Sound *sound = (Sound *)luaL_checkudata(L, 1, sounds_mt);

  // We dispose of the queue synchronously, which is designed to never actually
  // stop a sound from playing, since the sounds_mt.playing table holds every
  // sound until it's done playing (so it won't be collected till then).
  sound->do_stop = true;
  //OSStatus status = AudioQueueStop(sound->queue, true);
  //printf("%s after stop, status = %d\n", __FUNCTION__, status);
  //printf("AudioQueueDispose start\n");
  AudioQueueDispose(sound->queue, false);
  //printf("AudioQueueDispose done\n");
  //printf("%s after dispose\n", __FUNCTION__);

  free(sound->bytes);

  //printf("%s end\n", __FUNCTION__);

  return 0;
}

// Check for any sound objects in sounds_mt.playing that are done playing, and
// remove them.
static int update(lua_State *L) {
  get_playing_table(L);

  lua_pushnil(L);
  while (lua_next(L, -2)) {
    Sound *sound = (Sound *)lua_touserdata(L, -1);
    lua_pop(L, 1);  // Pop the value.
    if (!sound->is_running) {
      // Save a copy of the key for the following lua_next call.
      lua_pushvalue(L, -1);
      lua_pushnil(L);
      lua_settable(L, -4);
    }
  }

  return 0;
}

// Function to play a loaded sound.
static int play_sound(lua_State *L) {
  Sound *sound = (Sound *)luaL_checkudata(L, 1, sounds_mt);

  // Don't do anything if the sound is already playing.
  if (sound->is_running && !sound->do_stop) return 0;

  sound->do_stop = 0;
  sound->is_running = 1;
  //printf("is_running set to 1\n");

  //printf("AudioQueueStart start\n");
  OSStatus status = AudioQueueStart(sound->queue, NULL);  // NULL --> start now
  //printf("AudioQueueStart done\n");
  jump_out_if_bad(status, "Error starting playback.");

  // Save another reference to the sound so it doesn't get garbage collected early.
  get_playing_table(L);
  lua_pushinteger(L, sound->index);
  lua_pushvalue(L, 1);  // -> [self, sounds_mt.playing, self.index, self]
  lua_settable(L, 2);   // Sets playing[self.index] = self.

  return 0;
}

static int stop_sound(lua_State *L) {
  Sound *sound = (Sound *)luaL_checkudata(L, 1, sounds_mt);
  if (sound->is_running) {
    sound->do_stop = true;
    sound->cursor = sound->bytes;
  }
  return 0;  // Number of return values.
}


///////////////////////////////////////////////////////////////////////////////
// Internal callbacks.
///////////////////////////////////////////////////////////////////////////////

void sound_play_callback(void *userData, AudioQueueRef inAQ,
                         AudioQueueBufferRef buffer) {

  //printf("%s\n", __FUNCTION__);

  Sound *sound = (Sound *)userData;

  int bytes_per_frame = sound->audioDesc.mBytesPerFrame;

  UInt32 bytes_capacity = buffer->mAudioDataBytesCapacity;
  UInt32 num_bytes_left = sound->bytes + sound->num_bytes - sound->cursor;

  assert(num_bytes_left >= 0);

  int do_stop  = (num_bytes_left == 0 || sound->do_stop);
  if (do_stop) {
    //printf("About to stop the sound from within the callback.\n");
    //printf("AudioQueueStop start\n");
    // 2nd param may request an immediate stop.
    OSStatus status = AudioQueueStop(inAQ, sound->do_stop);
    //printf("AudioQueueStop done\n");
    if (status != 0) {
      printf("Warning: error while stopping a sound.\n");  // Non-fatal error.
    }
    //printf("Callback: setting do_stop = is_running = 0.\n");
    sound->is_running = 0;
    sound->do_stop    = 0;
    sound->cursor     = sound->bytes;
    num_bytes_left    = sound->num_bytes;
    //return;
  }

  UInt32 bytes_to_copy = bytes_capacity;
  if (num_bytes_left < bytes_capacity) bytes_to_copy = num_bytes_left;

  //printf("Copying starting at point %p\n", sound->cursor);

  memcpy(buffer->mAudioData, sound->cursor, bytes_to_copy);
  buffer->mAudioDataByteSize = bytes_to_copy;
  sound->cursor += bytes_to_copy;

  // TEMP
  //printf("About to enqueue %u bytes.\n", bytes_to_copy);

  //printf("AudioQueueEnqueueBuffer start\n");
  OSStatus status = AudioQueueEnqueueBuffer(inAQ,
                                            buffer,
                                            0,
                                            NULL);
  //printf("AudioQueueEnqueueBuffer done\n");
  if (status != 0) {
    printf("Error: playback error passing audio data to system.\n");
  }
}

void running_status_changed(void *userData, AudioQueueRef audioQueue,
                            AudioQueuePropertyID property) {
  // TEMP
  //printf("%s\n", __FUNCTION__);

  UInt32 is_running = 0;
  UInt32 property_size = sizeof(is_running);
  //printf("AudioQueueGetProperty start\n");
  OSStatus status = AudioQueueGetProperty(audioQueue,
                                          kAudioQueueProperty_IsRunning,
                                          &is_running,
                                          &property_size);
  //printf("AudioQueueGetProperty done\n");
  if (status != 0) {
    // Non-fatal error.
    printf("Warning: error reading sound properties on play/stop update.\n");
  }

  //printf("Got is_running (not in sound) = %d\n", is_running);
  
  // TODO This is bad! This is running Lua stuff concurrently in another thread!

  if (!is_running) {
    Sound *sound = (Sound *)userData;
    sound->is_running = 0;
    //printf("is_running set to %d\n", sound->is_running);
  }
}


///////////////////////////////////////////////////////////////////////////////
// Public functions, and data for them.
///////////////////////////////////////////////////////////////////////////////

// Data for the exported sounds table.
static const struct luaL_Reg sounds[] = {
  {"load", load_file},
  {"update", update},
  {NULL, NULL}
};

int luaopen_sounds(lua_State *L) {
  luaL_register(L, "sounds", sounds);
  return 1;
}


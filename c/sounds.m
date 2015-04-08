// beatz/c/sounds.m
//

#include "sounds.h"

#include "luajit/lauxlib.h"
#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>


// This is the Lua registry key for the sounds metatable.
#define sounds_mt "sounds_mt"


// Internal globals and types.

static int next_index = 1;

typedef struct {
  AudioQueueRef               queue;  // TODO Is this used?
  char *                      bytes;
  size_t                      num_bytes;
  char *                      cursor;
  int                         index;  // Index in the sounds_mt.playing table.
  lua_State *                 L;      // This is useful for callback user data.
  int                         is_running;
  AudioStreamBasicDescription audioDesc;
} Sound;


// Internal functions.

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
  if (status != 0) {
    luaL_error(L, "Failed to open file: '%s'", filename);  // Doesn't return.
  }
  
  UInt32 audioDescSize = sizeof(sound->audioDesc);
  status = ExtAudioFileGetProperty(audioFile,
                                   kExtAudioFileProperty_FileDataFormat,
                                   &audioDescSize,
                                   &sound->audioDesc);
  if (status != 0) {
    // Doesn't return.
    luaL_error(L, "Unable to read properties of audio file '%s'", filename);
  }

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
    if (status != 0) {
      // Doesn't return.
      luaL_error(L, "Error while reading file '%s'", filename);
    }
    print_err_if_bad(status, @"ExtAudioFileRead");

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

void sound_play_callback(void *userData, AudioQueueRef inAQ, AudioQueueBufferRef buffer) {

  Sound *sound = (Sound *)userData;
  
  int bytes_per_frame = sound->audioDesc.mBytesPerFrame;

  UInt32 bytes_capacity = buffer->mAudioDataBytesCapacity;
  UInt32 num_bytes_left = sound->bytes + sound->num_bytes - sound->cursor;

  assert(num_bytes_left >= 0);

  if (num_bytes_left == 0) {
    OSStatus status = AudioQueueStop(inAQ, false);  // false --> not immediately
    if (status != 0) {
      printf("Warning: error while stopping a sound.\n");  // Non-fatal error.
    }
    return;
  }

  UInt32 bytes_to_copy = bytes_capacity;
  if (num_bytes_left < bytes_capacity) bytes_to_copy = num_bytes_left;

  memcpy(buffer->mAudioData, sound->cursor, bytes_to_copy);
  buffer->mAudioDataByteSize = bytes_to_copy;
  sound->cursor += bytes_to_copy;

  OSStatus status = AudioQueueEnqueueBuffer(inAQ,
                                            buffer,
                                            0,
                                            NULL);
  if (status != 0) {
    // Doesn't return.
    luaL_error(sound->L, "Playback error passing audio data to system.");
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

void running_status_changed(void *userData, AudioQueueRef audioQueue,
                            AudioQueuePropertyID property) {
  UInt32 is_running = 0;
  UInt32 property_size = sizeof(is_running);
  OSStatus status = AudioQueueGetProperty(audioQueue,
                                          kAudioQueueProperty_IsRunning,
                                          &is_running,
                                          &property_size);
  if (status != 0) {
    // Non-fatal error.
    printf("Warning: error reading sound properties on play/stop update.\n");
  }

  if (!is_running) {
    // Remove the sound from sounds_mt.playing to allow garbage collection.
    Sound *sound = (Sound *)userData;
    lua_State *L = sound->L;
    get_playing_table(L);              // -> [playing]
    lua_pushinteger(L, sound->index);  // -> [playing, self.index]
    lua_pushnil(L);                    // -> [playing, self.index, nil]
    lua_settable(L, -3);               // -> [playing]

    // Enable the sound to be played again.
    sound->cursor = sound->bytes;

    sound->is_running = 0;
  }
}

// We want to avoid deleting an object that's actively being played. To ensure
// that, we add a sound to sound_mt.playing when it starts playing, and remove
// it from that table when it stops.
static int delete_sound_obj(lua_State* L) {
  Sound *sound = (Sound *)luaL_checkudata(L, 1, sounds_mt);

  // We dispose of the queue synchronously, which is designed to never actually
  // stop a sound from playing, since the sounds_mt.playing table holds every
  // sound until it's done playing (so it won't be collected till then).
  AudioQueueDispose(sound->queue, true);

  free(sound->bytes);
  return 0;
}

// Function to play a loaded sound.
static int play_sound(lua_State *L) {
  Sound *sound = (Sound *)luaL_checkudata(L, 1, sounds_mt);

  // Don't do anything if the sound is already playing.
  if (sound->is_running) return 0;

  AudioQueueRef audioQueue;
  
  OSStatus status = AudioQueueNewOutput(&sound->audioDesc,
                                        sound_play_callback,
                                        sound,  // user data
                                        NULL, /* CFRunLoopGetCurrent(), */
                                        kCFRunLoopCommonModes,
                                        0,     // reserved flags; must be 0
                                        &audioQueue);
  if (status != 0) {
    // Doesn't return.
    luaL_error(L, "Error creating new audio output stream.");
  }
  
  for (int i = 0; i < 2; ++i) {
    UInt32 bufferByteSize = 4 * 1024;
    AudioQueueBufferRef buffer;
    status = AudioQueueAllocateBuffer(audioQueue,
                                      bufferByteSize,
                                      &buffer);
    if (status != 0) {
      // Doesn't return.
      luaL_error(L, "Error priming audio buffers for playback.");
    }
    
    sound_play_callback(sound,  // user data
                        audioQueue,
                        buffer);
  }
  
  status = AudioQueueAddPropertyListener(audioQueue,
                                         kAudioQueueProperty_IsRunning,
                                         running_status_changed,
                                         sound);  // user data
  if (status != 0) {
    // Doesn't return.
    luaL_error(L, "Error attaching play/stop listener to playback stream.");
  }
  
  status = AudioQueueStart(audioQueue, NULL);  // NULL --> start as soon as possible
  if (status != 0) {
    luaL_error(L, "Error starting playback.\n");  // Doesn't return.
  }

  // Save another reference to the sound so it doesn't get garbage collected early.
  get_playing_table(L);
  lua_pushinteger(L, sound->index);
  lua_pushvalue(L, 1);  // -> [self, sounds_mt.playing, self.index, self]
  lua_settable(L, 2);   // Sets playing[self.index] = self.

  sound->is_running = 1;

  return 0;
}

// Function to load an audio file.
static int load_file(lua_State *L) {
  // TEMP TODO Remove debug stuff and clean up this fn.
  printf("start of %s\n", __FUNCTION__);

  // TODO Test behavior when no param or a nonstring is given.
  const char *filename = luaL_checkstring(L, 1);

  printf("Got the filename '%s'\n", filename);

  // push new_obj = {}
  Sound *sound = lua_newuserdata(L, sizeof(Sound));
  *sound = (Sound) {
    .bytes      = NULL,
    .num_bytes  = 0,
    .cursor     = NULL,
    .index      = next_index++,
    .L          = L,
    .is_running = 0
  };

  // push sounds_mt = {__gc = delete_sound_obj}
  if (luaL_newmetatable(L, sounds_mt)) {
    lua_pushcfunction(L, delete_sound_obj);
    lua_setfield(L, -2, "__gc");

    lua_pushvalue(L, -1);
    lua_setfield(L, -2, "__index");

    lua_pushcfunction(L, play_sound);
    lua_setfield(L, -2, "play");
  }

  // setmetatable(new_obj, sounds_mt)
  lua_setmetatable(L, -2);

  read_entire_file(L, filename, sound);
  //sound->queue = load_queue_for_file(filename);

  printf("end of %s\n", __FUNCTION__);

  return 1;
}

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


// Data for the exported sounds table.

static const struct luaL_Reg sounds[] = {
  {"load", load_file},
  {NULL, NULL}
};


// Public functions.

int luaopen_sounds(lua_State *L) {
  luaL_register(L, "sounds", sounds);
  return 1;
}


// beatz/c/sounds.m
//

#include "sounds.h"

#include "luajit/lauxlib.h"
#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>
#include <pthread.h>

// This is the Lua registry key for the sounds metatable.
#define sounds_mt "sounds_mt"


// Internal globals and types.

static int next_index = 1;

typedef struct {
  AudioQueueRef   queue;  // TODO Is this used?
  // TODO Either remove audioFile by using it entirely within read_entire_file
  //      or garbage collect it properly. Either way, make sure it's closed.
  ExtAudioFileRef audioFile;
  char *          bytes;
  size_t          num_bytes;
  char *          cursor;
  int             index;  // Index in the sounds_mt.playing table.
} Sound;


// Internal functions.

static void print_err_if_bad(OSStatus status, NSString *whence) {
  if (status == 0) return;
  
  NSError *error = [NSError errorWithDomain:NSOSStatusErrorDomain code:status userInfo:nil];
  
  NSLog(@"Error from %@", whence);
  NSLog(@"The error is %@", error);
}

static void read_entire_file(const char *filename, Sound *sound) {
  // Open the file.
  NSString *fileName = [NSString stringWithUTF8String:filename];
  NSURL *   fileURL  = [NSURL URLWithString:fileName];
  OSStatus status    = ExtAudioFileOpenURL((__bridge CFURLRef)fileURL,
                                           &sound->audioFile);
  print_err_if_bad(status, @"ExtAudioFileOpenURL");
  
  // Prepare initial buffer structure before we start reading.
  const size_t chunk_size = 8192;
  size_t full_size        = 0;
  char * full_ptr         = NULL;
  const int bytesPerFrame = 4;  // TODO Figure this out from the file.
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
    numFrames     = chunk_size / bytesPerFrame;

    // Receive new data.
    OSStatus status = ExtAudioFileRead(sound->audioFile, &numFrames, &bufferList);
    print_err_if_bad(status, @"ExtAudioFileRead");

    totalFrames += numFrames;
  } while (numFrames);

  sound->bytes     = full_ptr;
  sound->num_bytes = totalFrames * bytesPerFrame;
  sound->cursor    = full_ptr;
}

void file_play_callback(void *userData, AudioQueueRef inAQ, AudioQueueBufferRef buffer) {

  printf("%s\n", __FUNCTION__);
  
  // TODO Set this in a more file-respecting manner.
  const int bytesPerFrame = 4;
  
  UInt32 numFramesCapacity, numFrames;
  numFramesCapacity = numFrames = buffer->mAudioDataBytesCapacity / bytesPerFrame;
  
  ExtAudioFileRef audioFile = (ExtAudioFileRef)userData;
  assert(audioFile);
  
  AudioBuffer audioBuffer = {
    .mNumberChannels = 2,
    .mDataByteSize = buffer->mAudioDataBytesCapacity,
    .mData = buffer->mAudioData };
  AudioBufferList bufferList = { .mNumberBuffers = 1, .mBuffers = audioBuffer };
  
  OSStatus status = ExtAudioFileRead(audioFile, &numFrames, &bufferList);
  print_err_if_bad(status, @"ExtAudioFileRead");
  
  buffer->mAudioDataByteSize = numFrames * bytesPerFrame;
  
  if (numFrames > 0) {

    //printf("numFrames = %d\n", numFrames);
    
    status = AudioQueueEnqueueBuffer(inAQ,
                                     buffer,
                                     0,
                                     NULL);
    print_err_if_bad(status, @"AudioQueueEnqueueBuffer");
  }
  
  if (numFrames < numFramesCapacity) {
    
    status = AudioQueueStop(inAQ, false);  // false --> not immediately
    print_err_if_bad(status, @"AudioQueueStop");
    
  }
}

void sound_play_callback(void *userData, AudioQueueRef inAQ, AudioQueueBufferRef buffer) {

  Sound *sound = (Sound *)userData;
  
  // TODO Set this in a more file-respecting manner.
  const int bytesPerFrame = 4;

  UInt32 bytes_capacity = buffer->mAudioDataBytesCapacity;
  UInt32 num_bytes_left = sound->bytes + sound->num_bytes - sound->cursor;

  assert(num_bytes_left >= 0);

  if (num_bytes_left == 0) {
    OSStatus status = AudioQueueStop(inAQ, false);  // false --> not immediately
    print_err_if_bad(status, @"AudioQueueStop");
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
  print_err_if_bad(status, @"AudioQueueEnqueueBuffer");
}

static Boolean is_playing = true;

void running_status_changed(void *userData, AudioQueueRef audioQueue,
                            AudioQueuePropertyID property) {
  UInt32 is_running;
  UInt32 property_size = sizeof(is_running);
  OSStatus status = AudioQueueGetProperty(audioQueue,
                                          kAudioQueueProperty_IsRunning,
                                          &is_running,
                                          &property_size);
  print_err_if_bad(status, @"AudioQueueGetProperty");
  
  is_playing = !!is_running;

  // TEMP
  if (!is_playing) {
    printf("A sound ended.\n");
  }
}

static void open_and_play_a_sound() {
  NSURL *fileURL = [NSURL URLWithString:@"instruments/practice/a.wav"];
  
  ExtAudioFileRef audioFile;
  OSStatus status = ExtAudioFileOpenURL((__bridge CFURLRef)fileURL, &audioFile);
  print_err_if_bad(status, @"ExtAudioFileOpenURL");
  
  AudioStreamBasicDescription audioDesc;
  UInt32 audioDescSize = sizeof(audioDesc);
  
  status = ExtAudioFileGetProperty(audioFile,
                                   kExtAudioFileProperty_FileDataFormat,
                                   &audioDescSize,
                                   &audioDesc);
  print_err_if_bad(status, @"ExtAudioFileGetProperty");
  
  AudioQueueRef audioQueue;
  
  status = AudioQueueNewOutput(&audioDesc,
                               file_play_callback,
                               audioFile,  // user data
                               NULL, /* CFRunLoopGetCurrent(), */
                               kCFRunLoopCommonModes,
                               0,     // reserved flags; must be 0
                               &audioQueue);
  print_err_if_bad(status, @"AudioQueueNewOutput");
  
  for (int i = 0; i < 2; ++i) {
    UInt32 bufferByteSize = 4 * 1024;
    AudioQueueBufferRef buffer;
    status = AudioQueueAllocateBuffer(audioQueue,
                                      bufferByteSize,
                                      &buffer);
    print_err_if_bad(status, @"AudioQueueAllocateBuffer");
    
    file_play_callback(audioFile,  // user data
                       audioQueue,
                       buffer);
  }
  
  status = AudioQueueAddPropertyListener(audioQueue,
                                         kAudioQueueProperty_IsRunning,
                                         running_status_changed,
                                         NULL);  // user data
  print_err_if_bad(status, @"AudioQueueAddPropertyListener");
  
  status = AudioQueueStart(audioQueue, NULL);  // NULL --> start as soon as possible
  print_err_if_bad(status, @"AudioQueueStart");

  

}

// Load and prime the file.
// TODO Be sure that we do something appropriate if there's an error.
static AudioQueueRef load_queue_for_file(const char *filename) {
  NSString *fileName = [NSString stringWithUTF8String:filename];
  NSURL *fileURL = [NSURL URLWithString:fileName];
  
  ExtAudioFileRef audioFile;
  OSStatus status = ExtAudioFileOpenURL((__bridge CFURLRef)fileURL, &audioFile);
  print_err_if_bad(status, @"ExtAudioFileOpenURL");
  
  AudioStreamBasicDescription audioDesc;
  UInt32 audioDescSize = sizeof(audioDesc);
  
  status = ExtAudioFileGetProperty(audioFile,
                                   kExtAudioFileProperty_FileDataFormat,
                                   &audioDescSize,
                                   &audioDesc);
  print_err_if_bad(status, @"ExtAudioFileGetProperty");
  
  AudioQueueRef audioQueue;
  
  status = AudioQueueNewOutput(&audioDesc,
                               file_play_callback,
                               audioFile,  // user data
                               NULL, /* CFRunLoopGetCurrent(), */
                               kCFRunLoopCommonModes,
                               0,     // reserved flags; must be 0
                               &audioQueue);
  print_err_if_bad(status, @"AudioQueueNewOutput");
  
  for (int i = 0; i < 2; ++i) {
    UInt32 bufferByteSize = 4 * 1024;
    AudioQueueBufferRef buffer;
    status = AudioQueueAllocateBuffer(audioQueue,
                                      bufferByteSize,
                                      &buffer);
    print_err_if_bad(status, @"AudioQueueAllocateBuffer");
    
    file_play_callback(audioFile,  // user data
                       audioQueue,
                       buffer);
  }
  
  status = AudioQueueAddPropertyListener(audioQueue,
                                         kAudioQueueProperty_IsRunning,
                                         running_status_changed,
                                         NULL);  // user data
  print_err_if_bad(status, @"AudioQueueAddPropertyListener");
  
  //status = AudioQueueStart(audioQueue, NULL);  // NULL --> start as soon as possible
  //print_err_if_bad(status, @"AudioQueueStart");

  return audioQueue;
}

void *sounds_thread(void *arg) {
  @autoreleasepool {
    while (1) {
      CFRunLoopRunInMode(kCFRunLoopDefaultMode,
                         0.25,     // run time
                         false);   // run for full run time
    }
  }
  return 0;
}

static int sayhi(lua_State *L) {
  printf("why hello from sayhi\n");
  return 0;
}

// TODO cleanup


// We want to avoid deleting an object that's actively being played. To ensure
// that, we add a sound to sound_mt.playing when it starts playing, and remove
// it from that table when it stops.
static int delete_sound_obj(lua_State* L) {
  // TODO Free up all resources allocated for the sound object.
  //      (I think it will be the only value on the stack.)
  printf("***** %s\n", __FUNCTION__);

  Sound *sound = (Sound *)luaL_checkudata(L, 1, sounds_mt);

  free(sound->bytes);

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
  sound->index = next_index++;

  // push sounds_mt = {__gc = delete_sound_obj}
  if (luaL_newmetatable(L, sounds_mt)) {
    lua_pushcfunction(L, delete_sound_obj);
    lua_setfield(L, -2, "__gc");
    lua_getglobal(L, "sounds");
    lua_setfield(L, -2, "__index");
  }

  // setmetatable(new_obj, sounds_mt)
  lua_setmetatable(L, -2);

  read_entire_file(filename, sound);
  //sound->queue = load_queue_for_file(filename);

  printf("end of %s\n", __FUNCTION__);

  return 1;
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
    lua_setfield(L, -2, "playing");  // -> [sounds_mt, playing]
  }
  lua_remove(L, -2);                 // -> [sounds_mt.playing ~= nil]
}

// Function to play a loaded sound.
static int play_sound(lua_State *L) {
  Sound *sound = (Sound *)luaL_checkudata(L, 1, sounds_mt);

  AudioStreamBasicDescription audioDesc;
  UInt32 audioDescSize = sizeof(audioDesc);
  
  OSStatus status = ExtAudioFileGetProperty(sound->audioFile,
                                            kExtAudioFileProperty_FileDataFormat,
                                            &audioDescSize,
                                            &audioDesc);
  print_err_if_bad(status, @"ExtAudioFileGetProperty");
  
  AudioQueueRef audioQueue;
  
  status = AudioQueueNewOutput(&audioDesc,
                               sound_play_callback,
                               sound,  // user data
                               NULL, /* CFRunLoopGetCurrent(), */
                               kCFRunLoopCommonModes,
                               0,     // reserved flags; must be 0
                               &audioQueue);
  print_err_if_bad(status, @"AudioQueueNewOutput");
  
  for (int i = 0; i < 2; ++i) {
    UInt32 bufferByteSize = 4 * 1024;
    AudioQueueBufferRef buffer;
    status = AudioQueueAllocateBuffer(audioQueue,
                                      bufferByteSize,
                                      &buffer);
    print_err_if_bad(status, @"AudioQueueAllocateBuffer");
    
    sound_play_callback(sound,  // user data
                        audioQueue,
                        buffer);
  }
  
  status = AudioQueueAddPropertyListener(audioQueue,
                                         kAudioQueueProperty_IsRunning,
                                         running_status_changed,
                                         NULL);  // user data
  print_err_if_bad(status, @"AudioQueueAddPropertyListener");
  
  status = AudioQueueStart(audioQueue, NULL);  // NULL --> start as soon as possible
  print_err_if_bad(status, @"AudioQueueStart");

  // Save another reference to the sound so it doesn't get garbage collected early.
  get_playing_table(L);
  lua_pushinteger(L, sound->index);
  lua_pushvalue(L, 1);  // -> [self, sounds_mt.playing, self.index, self]
  lua_settable(L, 2);   // Sets playing[self.index] = self.

  return 0;
}


// Data for the exported sounds table.

static const struct luaL_Reg sounds[] = {
  {"sayhi", sayhi},
  {"load", load_file},
  {"play", play_sound},
  {NULL, NULL}
};


// Public functions.

int luaopen_sounds(lua_State *L) {

  pthread_t pthread;
  int err = pthread_create(&pthread,       // receive thread id
                           NULL,           // NULL --> use default attributes
                           sounds_thread,  // init function
                           NULL);          // init function arg

  luaL_register(L, "sounds", sounds);
  return 1;
}


// beatz/c/sounds.m
//

#include "sounds.h"

#include "luajit/lauxlib.h"
#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>
#include <pthread.h>

// This is the Lua registry key for the sounds metatable.
#define sounds_mt "sounds_mt"

typedef struct {
  AudioQueueRef   queue;  // TODO Is this used?
  ExtAudioFileRef audioFile;
  char *          bytes;
  size_t          num_bytes;
  char *          cursor;
} Sound;


////////////////////////////////////////////////////////////
// Begin caudio copy-over.
////////////////////////////////////////////////////////////

static void print_err_if_bad(OSStatus status, NSString *whence) {
  if (status == 0) return;
  
  NSError *error = [NSError errorWithDomain:NSOSStatusErrorDomain code:status userInfo:nil];
  
  NSLog(@"Error from %@", whence);
  NSLog(@"The error is %@", error);
}

static void print_some_frames(void *data, int num_frames) {
  const int cols = 175;
  const int rows = 50;

  const float range = INT16_MAX - INT16_MIN;

  int16_t *samples = (int16_t *)data;

  int y[cols];

  // We use cols + 1 to give room for newlines; the final + 1 is for the NULL
  // terminator.
  char print_buffer[rows * (cols + 1) + 1];

  float current_col = 0;
  float col_delta = (float)cols / num_frames;

  float sum = 0.0;
  int num_samples = 0;

  for (int i = 0; i < num_frames; ++i) {

    // Our sample value here is in the range [0, 1].
    float sample = ((float)*(samples + 2 * i) - INT16_MIN) / range;

    //printf("sample = %g\n", sample);

    // It seems most samples are smallish, so lets tweak them
    // a bit for visibility.

    float s = (sample - 0.5) * 20.0 + 0.5;
    if (s < 0.0) s = 0.0;
    if (s > 1.0) s = 1.0;

    sum += s;
    num_samples++;

    float next_col = current_col + col_delta;
    if (floor(next_col) > floor(current_col)) {

      float avg = sum / num_samples;

      //printf("avg = %g\n", avg);

      y[(int)floor(current_col)] = (int)(avg * (rows - 1));

      sum = 0.0;
      num_samples = 0;
    }

    current_col = next_col;
  }

  char *print_c = print_buffer;
  for (int r = 0; r < rows; ++r) {
    for (int c = 0; c < cols; ++c) {
      *print_c++ = (y[c] == r ? '*' : ' ');
    }
    *print_c++ = '\n';
  }
  *print_c = '\0';

  printf("%s", print_buffer);
}

static void read_entire_file(const char *filename, Sound *sound) {
  NSString *fileName = [NSString stringWithUTF8String:filename];
  NSURL *   fileURL  = [NSURL URLWithString:fileName];
  
  OSStatus status = ExtAudioFileOpenURL((__bridge CFURLRef)fileURL,
                                        &sound->audioFile);
  print_err_if_bad(status, @"ExtAudioFileOpenURL");
  
  const size_t chunk_size = 8192;

  size_t full_size = 0;
  char * full_ptr  = NULL;

  const int bytesPerFrame = 4;  // TODO Figure this out from the file.

  printf("%s:%d\n", __FILE__, __LINE__);

  AudioBuffer audioBuffer = {
    .mNumberChannels = 2,
    .mDataByteSize   = chunk_size,
    .mData           = malloc(chunk_size) };
  AudioBufferList bufferList = { .mNumberBuffers = 1, .mBuffers = audioBuffer };
  UInt32 numFrames, totalFrames = 0;
  printf("%s:%d\n", __FILE__, __LINE__);

  int num_iters = 0;

  do {

    AudioBuffer *buffer = &bufferList.mBuffers[0];

    full_size += chunk_size;
    printf("full_size = %zu\n", full_size);
    full_ptr   = realloc(full_ptr, full_size);
    buffer->mData = full_ptr + full_size - chunk_size;

    // TEMP
    memset(buffer->mData, 3, chunk_size);

    char *c = (char *)buffer->mData;
    printf("First 3 bytes = 0x%02X 0x%02X 0x%02X\n", c[0], c[1], c[2]);

    printf("full_ptr = %p\n", full_ptr);
    printf("buffer->mData = %p\n", buffer->mData);
    fflush(stdout);

    numFrames = chunk_size / bytesPerFrame;

    printf("%s:%d\n", __FILE__, __LINE__);
    fflush(stdout);

    OSStatus status = ExtAudioFileRead(sound->audioFile, &numFrames, &bufferList);
    print_err_if_bad(status, @"ExtAudioFileRead");

    printf("%s:%d\n", __FILE__, __LINE__);
    fflush(stdout);

    printf("numFrames (read) is %d\n", numFrames);
    fflush(stdout);

    c = (char *)buffer->mData;
    printf("First 3 bytes = 0x%02X 0x%02X 0x%02X\n", c[0], c[1], c[2]);

    printf("%s:%d\n", __FILE__, __LINE__);
    fflush(stdout);

    /////

    const float range = INT16_MAX - INT16_MIN;
    int16_t *samples = (int16_t *)buffer->mData;
    int i = 3;
    float sample = ((float)*(samples + 2 * i) - INT16_MIN) / range;
    printf("a sample = %g\n", sample);

    /////


    print_some_frames(buffer->mData, numFrames);

    totalFrames += numFrames;

    //exit(0);

    //num_iters++;
    //if (num_iters == 100) exit(0);

  } while (numFrames);

  printf("%s:%d\n", __FILE__, __LINE__);

  sound->bytes     = full_ptr;
  sound->num_bytes = totalFrames * bytesPerFrame;
  sound->cursor    = full_ptr;

  // TEMP
  printf("Read in %d frames for %zu bytes.\n", totalFrames, sound->num_bytes);
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

  printf("%s\n", __FUNCTION__);

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

void file_ended_callback(void *userData, AudioQueueRef audioQueue, AudioQueuePropertyID property) {
  
  UInt32 is_running;
  UInt32 property_size = sizeof(is_running);
  OSStatus status = AudioQueueGetProperty(audioQueue,
                                          kAudioQueueProperty_IsRunning,
                                          &is_running,
                                          &property_size);
  print_err_if_bad(status, @"AudioQueueGetProperty");
  
  is_playing = !!is_running;
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
                                         file_ended_callback,
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
                                         file_ended_callback,
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

////////////////////////////////////////////////////////////
// End caudio copy-over.
////////////////////////////////////////////////////////////


// Internal functions.

static int sayhi(lua_State *L) {
  printf("why hello from sayhi\n");
  return 0;
}

// TODO cleanup

static int delete_sound_obj(lua_State* L) {
  // TODO Free up all resources allocated for the sound object.
  //      (I think it will be the only value on the stack.)
  printf("***** %s\n", __FUNCTION__);
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
                                         file_ended_callback,
                                         NULL);  // user data
  print_err_if_bad(status, @"AudioQueueAddPropertyListener");
  
  status = AudioQueueStart(audioQueue, NULL);  // NULL --> start as soon as possible
  print_err_if_bad(status, @"AudioQueueStart");

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


// beatz/c/sounds.m
//

#include "sounds.h"

#include "luajit/lauxlib.h"
#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>
#include <pthread.h>


////////////////////////////////////////////////////////////
// Begin caudio copy-over.
////////////////////////////////////////////////////////////

static void print_err_if_bad(OSStatus status, NSString *whence) {
  if (status == 0) return;
  
  NSError *error = [NSError errorWithDomain:NSOSStatusErrorDomain code:status userInfo:nil];
  
  NSLog(@"Error from %@", whence);
  NSLog(@"The error is %@", error);
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

typedef struct {
  AudioQueueRef queue;
} Audio;

static int delete_sound_obj(lua_State* L) {
  // TODO Free up all resources allocated for the sound object.
  //      (I think it will be the only value on the stack.)
  printf("***** %s\n", __FUNCTION__);
  return 0;
}

// Function to load an audio file.
static int loadfile(lua_State *L) {
  // TEMP TODO Remove debug stuff and clean up this fn.
  printf("start of %s\n", __FUNCTION__);

  // TODO Test behavior when no param or a nonstring is given.
  const char *filename = luaL_checkstring(L, 1);

  printf("Got the filename '%s'\n", filename);

  // push new_obj = {}
  Audio *audio = lua_newuserdata(L, sizeof(Audio));

  // push mt = {__gc = delete_sound_obj}
  lua_newtable(L);
  lua_pushcfunction(L, delete_sound_obj);
  lua_setfield(L, -2, "__gc");

  // setmetatable(new_obj, mt)
  lua_setmetatable(L, -2);

  audio->queue = load_queue_for_file(filename);

  printf("end of %s\n", __FUNCTION__);

  return 1;
}


// Data for the exported sounds table.

static const struct luaL_Reg sounds[] = {
  {"sayhi", sayhi},
  {"load", loadfile},
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


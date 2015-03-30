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

  //printf("%s\n", __FUNCTION__);
  
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

    const int cols = 175;
    const int rows = 50;

    const float range = INT16_MAX - INT16_MIN;

    int16_t *samples = (int16_t *)buffer->mAudioData;

    int y[cols];

    // We use cols + 1 to give room for newlines; the final + 1 is for the NULL
    // terminator.
    char print_buffer[rows * (cols + 1) + 1];

    float current_col = 0;
    float col_delta = (float)cols / numFrames;

    float sum = 0.0;
    int num_samples = 0;

    for (int i = 0; i < numFrames; ++i) {

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

void *sounds_thread(void *arg) {
  @autoreleasepool {
    
    //open_an_audio_file();
    
    //play_a_sound();
    
    open_and_play_a_sound();
    
    //sleep(10);
    
    do {
      CFRunLoopRunInMode(kCFRunLoopDefaultMode,
                         0.25,     // run time
                         false);   // run for full run time
    } while (is_playing);
    
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


// Data for the exported sounds table.

static const struct luaL_Reg sounds[] = {
  {"sayhi", sayhi},
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


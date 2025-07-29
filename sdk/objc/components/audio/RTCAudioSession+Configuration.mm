/*
 *  Copyright 2016 The WebRTC Project Authors. All rights reserved.
 *
 *  Use of this source code is governed by a BSD-style license
 *  that can be found in the LICENSE file in the root of the source
 *  tree. An additional intellectual property rights grant can be found
 *  in the file PATENTS.  All contributing project authors may
 *  be found in the AUTHORS file in the root of the source tree.
 */

#import "RTCAudioSession+Private.h"
#import "RTCAudioSessionConfiguration.h"

#import "base/RTCLogging.h"

@implementation RTC_OBJC_TYPE (RTCAudioSession)
(Configuration)

    - (BOOL)setConfiguration : (RTC_OBJC_TYPE(RTCAudioSessionConfiguration) *)configuration error
    : (NSError **)outError {
  return [self setConfiguration:configuration
                         active:NO
                shouldSetActive:NO
                          error:outError];
}

- (BOOL)setConfiguration:(RTC_OBJC_TYPE(RTCAudioSessionConfiguration) *)configuration
                  active:(BOOL)active
                   error:(NSError **)outError {
  return [self setConfiguration:configuration
                         active:active
                shouldSetActive:YES
                          error:outError];
}

#pragma mark - Private

- (BOOL)setConfiguration:(RTC_OBJC_TYPE(RTCAudioSessionConfiguration) *)configuration
                  active:(BOOL)active
         shouldSetActive:(BOOL)shouldSetActive
                   error:(NSError **)outError {
  NSLog(@"🎧 [WebRTC] setConfiguration (Configuration category) called - DISABLED (preserving SDK configuration)");
  NSParameterAssert(configuration);
  if (outError) {
    *outError = nil;
  }

  // COMPLETELY DISABLED: Let SDK handle all audio session management
  // This method would normally call setCategory, setMode, setPreferredSampleRate, 
  // setPreferredIOBufferDuration, setActive, and channel configuration - all now disabled
  NSLog(@"🎧 [WebRTC] setConfiguration (Configuration category) completed (no actual changes made)");
  return YES;
}

@end

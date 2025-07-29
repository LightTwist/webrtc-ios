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

#import <UIKit/UIKit.h>

#include <atomic>
#include <vector>

#include "absl/base/attributes.h"
#include "rtc_base/checks.h"
#include "rtc_base/synchronization/mutex.h"

#import "RTCAudioSessionConfiguration.h"
#import "base/RTCLogging.h"

#if !defined(ABSL_HAVE_THREAD_LOCAL)
#error ABSL_HAVE_THREAD_LOCAL should be defined for MacOS / iOS Targets.
#endif

NSString *const RTC_CONSTANT_TYPE(RTCAudioSessionErrorDomain) = @"org.webrtc.RTC_OBJC_TYPE(RTCAudioSession)";
NSInteger const RTC_CONSTANT_TYPE(RTCAudioSessionErrorLockRequired) = -1;
NSInteger const RTC_CONSTANT_TYPE(RTCAudioSessionErrorConfiguration) = -2;
NSString * const RTC_CONSTANT_TYPE(RTCAudioSessionOutputVolumeSelector) = @"outputVolume";

namespace {
// Since webrtc::Mutex is not a reentrant lock and cannot check if the mutex is locked,
// we need a separate variable to check that the mutex is locked in the RTCAudioSession.
ABSL_CONST_INIT thread_local bool mutex_locked = false;
}  // namespace

@interface RTC_OBJC_TYPE (RTCAudioSession)
() @property(nonatomic,
             readonly) std::vector<__weak id<RTC_OBJC_TYPE(RTCAudioSessionDelegate)> > delegates;

@end

// This class needs to be thread-safe because it is accessed from many threads.
// TODO(tkchin): Consider more granular locking. We're not expecting a lot of
// lock contention so coarse locks should be fine for now.
@implementation RTC_OBJC_TYPE (RTCAudioSession) {
  webrtc::Mutex _mutex;
  AVAudioSession *_session;
  std::atomic<int> _activationCount;
  std::atomic<int> _webRTCSessionCount;
  BOOL _isActive;
  BOOL _useManualAudio;
  BOOL _isAudioEnabled;
  BOOL _canPlayOrRecord;
  BOOL _isInterrupted;
}

@synthesize session = _session;
@synthesize delegates = _delegates;
@synthesize ignoresPreferredAttributeConfigurationErrors =
    _ignoresPreferredAttributeConfigurationErrors;

+ (instancetype)sharedInstance {
  NSLog(@"🎧 [WebRTC] sharedInstance called");
  static dispatch_once_t onceToken;
  static RTC_OBJC_TYPE(RTCAudioSession) *sharedInstance = nil;
  dispatch_once(&onceToken, ^{
    sharedInstance = [[self alloc] init];
  });
  return sharedInstance;
}

- (instancetype)init {
  NSLog(@"🎧 [WebRTC] init called");
  return [self initWithAudioSession:[AVAudioSession sharedInstance]];
}

/** This initializer provides a way for unit tests to inject a fake/mock audio session. */
- (instancetype)initWithAudioSession:(AVAudioSession *)session {
  NSLog(@"🎧 [WebRTC] initWithAudioSession called");
  if (self = [super init]) {
    _session = session;

    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserver:self
               selector:@selector(handleInterruptionNotification:)
                   name:AVAudioSessionInterruptionNotification
                 object:nil];
    [center addObserver:self
               selector:@selector(handleRouteChangeNotification:)
                   name:AVAudioSessionRouteChangeNotification
                 object:nil];
    [center addObserver:self
               selector:@selector(handleMediaServicesWereLost:)
                   name:AVAudioSessionMediaServicesWereLostNotification
                 object:nil];
    [center addObserver:self
               selector:@selector(handleMediaServicesWereReset:)
                   name:AVAudioSessionMediaServicesWereResetNotification
                 object:nil];
    if (@available(iOS 14.5, *)) {
      [center addObserver:self
                 selector:@selector(handleSilenceSecondaryAudioHintNotification:)
                     name:AVAudioSessionSilenceSecondaryAudioHintNotification
                   object:nil];
    }
    [center addObserver:self
               selector:@selector(handleApplicationDidBecomeActive:)
                   name:UIApplicationDidBecomeActiveNotification
                 object:nil];
    
    // Listen for manual device refresh requests from Swift
    [center addObserver:self
               selector:@selector(handleManualDeviceRefresh:)
                   name:@"RTCAudioSessionRefreshDevices"
                 object:nil];

    // Populates _delegates.
    _delegates = std::vector<__weak id<RTC_OBJC_TYPE(RTCAudioSessionDelegate)> >();

    _activationCount = 0;
    _webRTCSessionCount = 0;
    _isActive = session.isOtherAudioPlaying;
    _useManualAudio = NO;
    _isAudioEnabled = YES;
    _canPlayOrRecord = NO;
    _isInterrupted = NO;
  }
  return self;
}

- (void)dealloc {
  NSLog(@"🎧 [WebRTC] dealloc called");
  [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (NSString *)description {
  NSString *format =
      @"RTCAudioSession: {\n"
       "  category: %@\n"
       "  categoryOptions: %ld\n"
       "  mode: %@\n"
       "  isActive: %d\n"
       "  sampleRate: %.2f\n"
       "  IOBufferDuration: %f\n"
       "  outputNumberOfChannels: %ld\n"
       "  inputNumberOfChannels: %ld\n"
       "  outputLatency: %f\n"
       "  inputLatency: %f\n"
       "  outputVolume: %f\n"
       "}";
  NSString *description = [NSString stringWithFormat:format,
          self.category, (long)self.categoryOptions, self.mode,
          self.isActive, self.sampleRate, self.IOBufferDuration,
          self.outputNumberOfChannels, self.inputNumberOfChannels,
          self.outputLatency, self.inputLatency, self.outputVolume];
  return description;
}

- (void)setIsActive:(BOOL)isActive {
  @synchronized(self) {
    _isActive = isActive;
  }
}

- (BOOL)isActive {
  @synchronized(self) {
    return _isActive;
  }
}

- (void)setUseManualAudio:(BOOL)useManualAudio {
  NSLog(@"🎧 [WebRTC] setUseManualAudio: %d", useManualAudio);
  @synchronized(self) {
    if (_useManualAudio == useManualAudio) {
      return;
    }
    _useManualAudio = useManualAudio;
  }
  [self updateCanPlayOrRecord];
}

- (BOOL)useManualAudio {
  @synchronized(self) {
    return _useManualAudio;
  }
}

- (void)setIsAudioEnabled:(BOOL)isAudioEnabled {
  NSLog(@"🎧 [WebRTC] setIsAudioEnabled: %d", isAudioEnabled);
  @synchronized(self) {
    if (_isAudioEnabled == isAudioEnabled) {
      return;
    }
    _isAudioEnabled = isAudioEnabled;
  }
  [self updateCanPlayOrRecord];
}

- (BOOL)isAudioEnabled {
  @synchronized(self) {
    return _isAudioEnabled;
  }
}

- (void)setIgnoresPreferredAttributeConfigurationErrors:
    (BOOL)ignoresPreferredAttributeConfigurationErrors {
  @synchronized(self) {
    if (_ignoresPreferredAttributeConfigurationErrors ==
        ignoresPreferredAttributeConfigurationErrors) {
      return;
    }
    _ignoresPreferredAttributeConfigurationErrors = ignoresPreferredAttributeConfigurationErrors;
  }
}

- (BOOL)ignoresPreferredAttributeConfigurationErrors {
  @synchronized(self) {
    return _ignoresPreferredAttributeConfigurationErrors;
  }
}

// TODO(tkchin): Check for duplicates.
- (void)addDelegate:(id<RTC_OBJC_TYPE(RTCAudioSessionDelegate)>)delegate {
  NSLog(@"🎧 [WebRTC] addDelegate called");
  if (!delegate) {
    return;
  }
  @synchronized(self) {
    _delegates.push_back(delegate);
    [self removeZeroedDelegates];
  }
}

- (void)removeDelegate:(id<RTC_OBJC_TYPE(RTCAudioSessionDelegate)>)delegate {
  NSLog(@"🎧 [WebRTC] removeDelegate called");
  if (!delegate) {
    return;
  }
  @synchronized(self) {
    _delegates.erase(std::remove(_delegates.begin(),
                                 _delegates.end(),
                                 delegate),
                     _delegates.end());
    [self removeZeroedDelegates];
  }
}

- (void)lockForConfiguration {
  NSLog(@"🎧 [WebRTC] lockForConfiguration called");
  _mutex.Lock();
  mutex_locked = true;
}

- (void)unlockForConfiguration {
  NSLog(@"🎧 [WebRTC] unlockForConfiguration called");
  mutex_locked = false;
  _mutex.Unlock();
}

#pragma mark - AVAudioSession proxy methods

- (NSString *)category {
  return self.session.category;
}

- (AVAudioSessionCategoryOptions)categoryOptions {
  return self.session.categoryOptions;
}

- (NSString *)mode {
  return self.session.mode;
}

- (BOOL)secondaryAudioShouldBeSilencedHint {
  return self.session.secondaryAudioShouldBeSilencedHint;
}

- (AVAudioSessionRouteDescription *)currentRoute {
  return self.session.currentRoute;
}

- (NSInteger)maximumInputNumberOfChannels {
  return self.session.maximumInputNumberOfChannels;
}

- (NSInteger)maximumOutputNumberOfChannels {
  return self.session.maximumOutputNumberOfChannels;
}

- (float)inputGain {
  return self.session.inputGain;
}

- (BOOL)inputGainSettable {
  return self.session.inputGainSettable;
}

- (BOOL)inputAvailable {
  return self.session.inputAvailable;
}

- (NSArray<AVAudioSessionDataSourceDescription *> *)inputDataSources {
  return self.session.inputDataSources;
}

- (AVAudioSessionDataSourceDescription *)inputDataSource {
  return self.session.inputDataSource;
}

- (NSArray<AVAudioSessionDataSourceDescription *> *)outputDataSources {
  return self.session.outputDataSources;
}

- (AVAudioSessionDataSourceDescription *)outputDataSource {
  return self.session.outputDataSource;
}

- (double)sampleRate {
  return self.session.sampleRate;
}

- (double)preferredSampleRate {
  return self.session.preferredSampleRate;
}

- (NSInteger)inputNumberOfChannels {
  return self.session.inputNumberOfChannels;
}

- (NSInteger)outputNumberOfChannels {
  return self.session.outputNumberOfChannels;
}

- (float)outputVolume {
  return self.session.outputVolume;
}

- (NSTimeInterval)inputLatency {
  return self.session.inputLatency;
}

- (NSTimeInterval)outputLatency {
  return self.session.outputLatency;
}

- (NSTimeInterval)IOBufferDuration {
  return self.session.IOBufferDuration;
}

- (NSTimeInterval)preferredIOBufferDuration {
  return self.session.preferredIOBufferDuration;
}

- (BOOL)setActive:(BOOL)active
            error:(NSError **)outError {
  NSLog(@"🎧 [WebRTC] setActive: %d called - DISABLED (preserving SDK configuration)", active);
  
  if (![self checkLock:outError]) {
    return NO;
  }
  
  // COMPLETELY DISABLED: Let SDK handle all audio session management
  // Just update our internal state without touching AVAudioSession
  
  if (active) {
    [self incrementActivationCount];
    [self notifyDidSetActive:active];
  } else {
    [self decrementActivationCount];
    [self notifyDidSetActive:active];
  }
  
  NSLog(@"🎧 [WebRTC] setActive: %d completed (no actual changes made)", active);
  return YES; // Always return success
}

- (BOOL)setCategory:(AVAudioSessionCategory)category
               mode:(AVAudioSessionMode)mode
            options:(AVAudioSessionCategoryOptions)options
              error:(NSError **)outError {
  NSLog(@"🎧 [WebRTC] setCategory called - DISABLED (preserving SDK configuration)");
  if (![self checkLock:outError]) {
    return NO;
  }
  
  // COMPLETELY DISABLED: Let SDK handle all audio session management
  // Don't touch AVAudioSession - just log and return success
  NSLog(@"🎧 [WebRTC] setCategory completed (no actual changes made)");
  return YES;
}

- (BOOL)setCategory:(AVAudioSessionCategory)category
        withOptions:(AVAudioSessionCategoryOptions)options
              error:(NSError **)outError {
  NSLog(@"🎧 [WebRTC] setCategory (with options) called - DISABLED (preserving SDK configuration)");
  if (![self checkLock:outError]) {
    return NO;
  }
  
  // COMPLETELY DISABLED: Let SDK handle all audio session management
  NSLog(@"🎧 [WebRTC] setCategory (with options) completed (no actual changes made)");
  return YES;
}

- (BOOL)setMode:(AVAudioSessionMode)mode error:(NSError **)outError {
  NSLog(@"🎧 [WebRTC] setMode called - DISABLED (preserving SDK configuration)");
  if (![self checkLock:outError]) {
    return NO;
  }
  
  // COMPLETELY DISABLED: Let SDK handle all audio session management
  NSLog(@"🎧 [WebRTC] setMode completed (no actual changes made)");
  return YES;
}

- (BOOL)setInputGain:(float)gain error:(NSError **)outError {
  NSLog(@"🎧 [WebRTC] setInputGain called");
  if (![self checkLock:outError]) {
    return NO;
  }
  return [self.session setInputGain:gain error:outError];
}

- (BOOL)setPreferredSampleRate:(double)sampleRate error:(NSError **)outError {
  NSLog(@"🎧 [WebRTC] setPreferredSampleRate called - DISABLED (preserving SDK configuration)");
  if (![self checkLock:outError]) {
    return NO;
  }
  // COMPLETELY DISABLED: Let SDK handle all audio session management
  NSLog(@"🎧 [WebRTC] setPreferredSampleRate completed (no actual changes made)");
  return YES;
}

- (BOOL)setPreferredIOBufferDuration:(NSTimeInterval)duration error:(NSError **)outError {
  NSLog(@"🎧 [WebRTC] setPreferredIOBufferDuration called - DISABLED (preserving SDK configuration)");
  if (![self checkLock:outError]) {
    return NO;
  }
  // COMPLETELY DISABLED: Let SDK handle all audio session management
  NSLog(@"🎧 [WebRTC] setPreferredIOBufferDuration completed (no actual changes made)");
  return YES;
}

- (BOOL)setPreferredInputNumberOfChannels:(NSInteger)count error:(NSError **)outError {
  NSLog(@"🎧 [WebRTC] setPreferredInputNumberOfChannels called - DISABLED (preserving SDK configuration)");
  if (![self checkLock:outError]) {
    return NO;
  }
  // COMPLETELY DISABLED: Let SDK handle all audio session management
  NSLog(@"🎧 [WebRTC] setPreferredInputNumberOfChannels completed (no actual changes made)");
  return YES;
}

- (BOOL)setPreferredOutputNumberOfChannels:(NSInteger)count error:(NSError **)outError {
  NSLog(@"🎧 [WebRTC] setPreferredOutputNumberOfChannels called - DISABLED (preserving SDK configuration)");
  if (![self checkLock:outError]) {
    return NO;
  }
  // COMPLETELY DISABLED: Let SDK handle all audio session management
  NSLog(@"🎧 [WebRTC] setPreferredOutputNumberOfChannels completed (no actual changes made)");
  return YES;
}

- (BOOL)overrideOutputAudioPort:(AVAudioSessionPortOverride)portOverride error:(NSError **)outError {
  NSLog(@"🎧 [WebRTC] overrideOutputAudioPort called - DISABLED (preserving SDK configuration)");
  if (![self checkLock:outError]) {
    return NO;
  }
  // COMPLETELY DISABLED: Let SDK handle all audio session management
  NSLog(@"🎧 [WebRTC] overrideOutputAudioPort completed (no actual changes made)");
  return YES;
}

- (BOOL)setPreferredInput:(AVAudioSessionPortDescription *)inPort error:(NSError **)outError {
  NSLog(@"🎧 [WebRTC] setPreferredInput called - DISABLED (preserving SDK configuration)");
  if (![self checkLock:outError]) {
    return NO;
  }
  // COMPLETELY DISABLED: Let SDK handle all audio session management
  NSLog(@"🎧 [WebRTC] setPreferredInput completed (no actual changes made)");
  return YES;
}

- (BOOL)setInputDataSource:(AVAudioSessionDataSourceDescription *)dataSource
                     error:(NSError **)outError {
  NSLog(@"🎧 [WebRTC] setInputDataSource called");
  if (![self checkLock:outError]) {
    return NO;
  }
  return [self.session setInputDataSource:dataSource error:outError];
}

- (BOOL)setOutputDataSource:(AVAudioSessionDataSourceDescription *)dataSource
                      error:(NSError **)outError {
  NSLog(@"🎧 [WebRTC] setOutputDataSource called");
  if (![self checkLock:outError]) {
    return NO;
  }
  return [self.session setOutputDataSource:dataSource error:outError];
}

#pragma mark - Notifications

- (void)handleInterruptionNotification:(NSNotification *)notification {
  NSLog(@"🎧 [WebRTC] handleInterruptionNotification called");
  NSNumber* typeNumber =
      notification.userInfo[AVAudioSessionInterruptionTypeKey];
  AVAudioSessionInterruptionType type =
      (AVAudioSessionInterruptionType)typeNumber.unsignedIntegerValue;
  switch (type) {
    case AVAudioSessionInterruptionTypeBegan:
      RTCLog(@"Audio session interruption began.");
      self.isActive = NO;
      self.isInterrupted = YES;
      [self notifyDidBeginInterruption];
      break;
    case AVAudioSessionInterruptionTypeEnded: {
      RTCLog(@"Audio session interruption ended.");
      self.isInterrupted = NO;
      [self updateAudioSessionAfterEvent];
      NSNumber *optionsNumber =
          notification.userInfo[AVAudioSessionInterruptionOptionKey];
      AVAudioSessionInterruptionOptions options =
          optionsNumber.unsignedIntegerValue;
      BOOL shouldResume =
          options & AVAudioSessionInterruptionOptionShouldResume;
      [self notifyDidEndInterruptionWithShouldResumeSession:shouldResume];
      break;
    }
  }
}

- (void)handleRouteChangeNotification:(NSNotification *)notification {
  NSLog(@"🎧 [WebRTC] handleRouteChangeNotification called");
  
  // Get reason for current route change.
  NSNumber* typeNumber =
      notification.userInfo[AVAudioSessionRouteChangeReasonKey];
  AVAudioSessionRouteChangeReason reason =
      (AVAudioSessionRouteChangeReason)typeNumber.unsignedIntegerValue;
      
  RTCLog(@"Audio route changed:");
  
  // Check for USB devices on EVERY route change, not just NewDeviceAvailable
  BOOL hasUSBDevice = [self hasUSBDeviceConnected];
  NSLog(@"🎧 [WebRTC] Route change - USB device present: %@", hasUSBDevice ? @"YES" : @"NO");
  
  if (hasUSBDevice) {
    NSLog(@"🎧 [WebRTC] USB device detected in route change - posting device refresh notification");
    // Post notification for device refresh
    [[NSNotificationCenter defaultCenter] postNotificationName:@"WebRTCAudioDeviceRefresh" 
                                                        object:self 
                                                      userInfo:nil];
  }
  
  switch (reason) {
    case AVAudioSessionRouteChangeReasonUnknown:
      RTCLog(@"Audio route changed: ReasonUnknown");
      break;
    case AVAudioSessionRouteChangeReasonNewDeviceAvailable: {
      RTCLog(@"Audio route changed: New device available.");
      break;
    }
    case AVAudioSessionRouteChangeReasonOldDeviceUnavailable:
      RTCLog(@"Audio route changed: Old device unavailable.");
      break;
    case AVAudioSessionRouteChangeReasonCategoryChange:
      RTCLog(@"Audio route changed: Category change to :%@", self.session.category);
      // Don't update audio session state for category changes since we don't
      // want WebRTC to restart audio when category is changed while active.
      return;
    case AVAudioSessionRouteChangeReasonOverride:
      RTCLog(@"Audio route changed: Override.");
      break;
    case AVAudioSessionRouteChangeReasonWakeFromSleep:
      RTCLog(@"Audio route changed: Wake from sleep.");
      break;
    case AVAudioSessionRouteChangeReasonNoSuitableRouteForCategory:
      RTCLog(@"Audio route changed: No suitable route for category.");
      break;
    case AVAudioSessionRouteChangeReasonRouteConfigurationChange:
      RTCLog(@"Audio route changed: Route configuration change.");
      break;
    default:
      RTCLog(@"Audio route changed: Unknown reason.");
      break;
  }
  
  AVAudioSessionRouteDescription* previousRoute =
      notification.userInfo[AVAudioSessionRouteChangePreviousRouteKey];
  // Log previous route configuration.
  RTCLog(@"Previous route: %@\nCurrent route:%@",
         previousRoute, self.session.currentRoute);
  [self notifyDidChangeRouteWithReason:reason previousRoute:previousRoute];

  [self updateAudioSessionAfterEvent];
}

- (void)handleMediaServicesWereLost:(NSNotification *)notification {
  NSLog(@"🎧 [WebRTC] handleMediaServicesWereLost called");
  RTCLog(@"Media services were lost.");
  [self updateAudioSessionAfterEvent];
  [self notifyMediaServicesWereLost];
}

- (void)handleMediaServicesWereReset:(NSNotification *)notification {
  NSLog(@"🎧 [WebRTC] handleMediaServicesWereReset called");
  RTCLog(@"Media services were reset.");
  [self updateAudioSessionAfterEvent];
  [self notifyMediaServicesWereReset];
}

- (void)handleSilenceSecondaryAudioHintNotification:(NSNotification *)notification {
  NSLog(@"🎧 [WebRTC] handleSilenceSecondaryAudioHintNotification called");
  // TODO(henrika): Add support for kAudioSessionSilenceSecondaryAudioHintNotification.
  RTCLog(@"Secondary audio hint notification.");
}

- (void)handleApplicationDidBecomeActive:(NSNotification *)notification {
  NSLog(@"🎧 [WebRTC] handleApplicationDidBecomeActive called");
  RTCLog(@"Application became active.");
  [self updateCanPlayOrRecord];
}

- (void)handleManualDeviceRefresh:(NSNotification *)notification {
  NSLog(@"🎧 [WebRTC] Manual device refresh requested from Swift");
  
  // Post a different notification name to prevent infinite loops
  // This will be handled by WebRTC's AudioDeviceIOS class
  [[NSNotificationCenter defaultCenter] postNotificationName:@"WebRTCAudioDeviceRefresh" 
                                                      object:self 
                                                    userInfo:nil];
  
  NSLog(@"🎧 [WebRTC] Posted WebRTCAudioDeviceRefresh notification");
}

#pragma mark - Private

+ (NSError *)lockError {
  NSDictionary *userInfo =
      @{NSLocalizedDescriptionKey : @"Must call lockForConfiguration before calling this method."};
  NSError *error = [[NSError alloc] initWithDomain:RTC_CONSTANT_TYPE(RTCAudioSessionErrorDomain)
                                              code:RTC_CONSTANT_TYPE(RTCAudioSessionErrorLockRequired)
                                          userInfo:userInfo];
  return error;
}

- (BOOL)hasUSBDeviceConnected {
  // Check available inputs for USB devices
  for (AVAudioSessionPortDescription *input in self.session.availableInputs) {
    if ([input.portType isEqualToString:AVAudioSessionPortUSBAudio] ||
        [input.portType isEqualToString:AVAudioSessionPortThunderbolt]) {
      NSLog(@"🎧 [WebRTC] USB device detected: %@ (type: %@)", input.portName, input.portType);
      return YES;
    }
  }
  
  // Also check current route inputs
  for (AVAudioSessionPortDescription *input in self.session.currentRoute.inputs) {
    if ([input.portType isEqualToString:AVAudioSessionPortUSBAudio] ||
        [input.portType isEqualToString:AVAudioSessionPortThunderbolt]) {
      NSLog(@"🎧 [WebRTC] USB device detected in route: %@ (type: %@)", input.portName, input.portType);
      return YES;
    }
  }
  
  return NO;
}

- (std::vector<__weak id<RTC_OBJC_TYPE(RTCAudioSessionDelegate)> >)delegates {
  @synchronized(self) {
    // Note: this returns a copy.
    return _delegates;
  }
}

// TODO(tkchin): check for duplicates.
- (void)pushDelegate:(id<RTC_OBJC_TYPE(RTCAudioSessionDelegate)>)delegate {
  @synchronized(self) {
    _delegates.insert(_delegates.begin(), delegate);
  }
}

- (void)removeZeroedDelegates {
  @synchronized(self) {
    _delegates.erase(
        std::remove_if(_delegates.begin(),
                       _delegates.end(),
                       [](id delegate) -> bool { return delegate == nil; }),
        _delegates.end());
  }
}

- (int)activationCount {
  return _activationCount.load();
}

- (int)incrementActivationCount {
  RTCLog(@"Incrementing activation count.");
  return _activationCount.fetch_add(1) + 1;
}

- (NSInteger)decrementActivationCount {
  RTCLog(@"Decrementing activation count.");
  return _activationCount.fetch_sub(1) - 1;
}

- (int)webRTCSessionCount {
  return _webRTCSessionCount.load();
}

- (BOOL)canPlayOrRecord {
  return !self.useManualAudio || self.isAudioEnabled;
}

- (BOOL)isInterrupted {
  @synchronized(self) {
    return _isInterrupted;
  }
}

- (void)setIsInterrupted:(BOOL)isInterrupted {
  @synchronized(self) {
    if (_isInterrupted == isInterrupted) {
      return;
    }
    _isInterrupted = isInterrupted;
  }
}

- (BOOL)checkLock:(NSError **)outError {
  if (!mutex_locked) {
    if (outError) {
      *outError = [RTC_OBJC_TYPE(RTCAudioSession) lockError];
    }
    return NO;
  }
  return YES;
}

- (BOOL)beginWebRTCSession:(NSError **)outError {
  NSLog(@"🎧 [WebRTC] beginWebRTCSession called");
  @synchronized(self) {
    if (_webRTCSessionCount.load() == 0) {
      [self lockForConfiguration];
      BOOL success = [self configureWebRTCSession:outError];
      [self unlockForConfiguration];
      if (!success) {
        return NO;
      }
    }
    _webRTCSessionCount.fetch_add(1);
  }
  [self notifyDidStartPlayOrRecord];
  return YES;
}

- (BOOL)endWebRTCSession:(NSError **)outError {
  NSLog(@"🎧 [WebRTC] endWebRTCSession called");
  @synchronized(self) {
    if (_webRTCSessionCount.load() <= 0) {
      return NO;
    }
    _webRTCSessionCount.fetch_sub(1);
    if (_webRTCSessionCount.load() == 0) {
      [self lockForConfiguration];
      BOOL success = [self unconfigureWebRTCSession:outError];
      [self unlockForConfiguration];
      if (!success) {
        return NO;
      }
    }
  }
  [self notifyDidStopPlayOrRecord];
  return YES;
}

- (BOOL)configureWebRTCSession:(NSError **)outError {
  NSLog(@"🎧 [WebRTC] configureWebRTCSession called");
  if (outError) {
    *outError = nil;
  }
  if (![self checkLock:outError]) {
    return NO;
  }
  RTCLog(@"Configuring audio session for WebRTC.");
  
  // Configure the AVAudioSession and activate it.
  // Provide an error even if there isn't one so we can log it.
  NSError *error = nil;
  RTC_OBJC_TYPE(RTCAudioSessionConfiguration) *webRTCConfig =
      [RTC_OBJC_TYPE(RTCAudioSessionConfiguration) webRTCConfiguration];
  if (![self setConfiguration:webRTCConfig active:YES error:&error]) {
    RTCLogError(@"Failed to set WebRTC audio configuration: %@",
                error.localizedDescription);
    [self unconfigureWebRTCSession:nil];
    if (outError) {
      *outError = error;
    }
    return NO;
  }
  
  // Ensure that the device currently supports audio input.
  // TODO(tkchin): Figure out if this is really necessary.
  if (!self.inputAvailable) {
    RTCLogError(@"No audio input path is available!");
    [self unconfigureWebRTCSession:nil];
    if (outError) {
      *outError = [self configurationErrorWithDescription:@"No input path."];
    }
    return NO;
  }
  
  // It can happen (e.g. in combination with BT devices) that the attempt to set
  // the preferred sample rate for WebRTC (48kHz) fails. If so, make a new
  // configuration attempt using the sample rate that worked using the active
  // audio session. A typical case is that only 8 or 16kHz can be set, e.g. in
  // combination with BT headsets. Using this "trick" seems to avoid a state
  // where Core Audio asks for a different number of audio frames than what the
  // session's I/O buffer duration corresponds to.
  // TODO(henrika): this fix resolves bugs.webrtc.org/6004 but it has only been
  // tested on a limited set of iOS devices and BT devices.
  double sessionSampleRate = self.sampleRate;
  double preferredSampleRate = webRTCConfig.sampleRate;
  if (sessionSampleRate != preferredSampleRate) {
    RTCLogWarning(
        @"Current sample rate (%.2f) is not the preferred rate (%.2f)",
        sessionSampleRate, preferredSampleRate);
    if (![self setPreferredSampleRate:sessionSampleRate
                                error:&error]) {
      RTCLogError(@"Failed to set preferred sample rate: %@",
                  error.localizedDescription);
      if (outError) {
        *outError = error;
      }
    }
  }
  
  return YES;
}

- (BOOL)unconfigureWebRTCSession:(NSError **)outError {
  NSLog(@"🎧 [WebRTC] unconfigureWebRTCSession called");
  if (outError) {
    *outError = nil;
  }
  if (![self checkLock:outError]) {
    return NO;
  }
  RTCLog(@"Unconfiguring audio session for WebRTC.");
  [self setActive:NO error:outError];
  return YES;
}

- (NSError *)configurationErrorWithDescription:(NSString *)description {
  NSDictionary* userInfo = @{
    NSLocalizedDescriptionKey: description,
  };
  return [[NSError alloc] initWithDomain:RTC_CONSTANT_TYPE(RTCAudioSessionErrorDomain)
                                    code:RTC_CONSTANT_TYPE(RTCAudioSessionErrorConfiguration)
                                userInfo:userInfo];
}

- (void)updateAudioSessionAfterEvent {
  BOOL shouldActivate = self.activationCount > 0;
  AVAudioSessionSetActiveOptions options = shouldActivate ?
      0 : AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation;
  NSError *error = nil;
  if ([self.session setActive:shouldActivate
                  withOptions:options
                        error:&error]) {
    self.isActive = shouldActivate;
  } else {
    RTCLogError(@"Failed to set session active to %d. Error:%@",
                shouldActivate, error.localizedDescription);
  }
}

- (void)updateCanPlayOrRecord {
  BOOL canPlayOrRecord = NO;
  BOOL shouldNotify = NO;
  @synchronized(self) {
    canPlayOrRecord = !self.useManualAudio || self.isAudioEnabled;
    if (_canPlayOrRecord == canPlayOrRecord) {
      return;
    }
    _canPlayOrRecord = canPlayOrRecord;
    shouldNotify = YES;
  }
  if (shouldNotify) {
    [self notifyDidChangeCanPlayOrRecord:canPlayOrRecord];
  }
}

- (void)audioSessionDidActivate:(AVAudioSession *)session {
  if (_session != session) {
    RTCLog(@"audioSessionDidActivate called on different AVAudioSession");
  }
  RTCLog(@"Audio session was externally activated.");
  [self incrementActivationCount];
  self.isActive = YES;
  // When a CallKit call begins, it's possible that we receive an interruption
  // begin immediately after the audio session was activated. In this case we
  // will receive the interruption notification before the audio session
  // activation observation, so isInterrupted will be YES even though
  // CallKit "ended" the interruption. Because of this, we don't want to send
  // an interruption end event.
  if (self.isInterrupted) {
    self.isInterrupted = NO;
  }
}

- (void)audioSessionDidDeactivate:(AVAudioSession *)session {
  if (_session != session) {
    RTCLog(@"audioSessionDidDeactivate called on different AVAudioSession");
  }
  RTCLog(@"Audio session was externally deactivated.");
  self.isActive = NO;
  [self decrementActivationCount];
}

- (void)notifyDidBeginInterruption {
  for (auto delegate : self.delegates) {
    SEL sel = @selector(audioSessionDidBeginInterruption:);
    if ([delegate respondsToSelector:sel]) {
      [delegate audioSessionDidBeginInterruption:self];
    }
  }
}

- (void)notifyDidEndInterruptionWithShouldResumeSession:
    (BOOL)shouldResumeSession {
  for (auto delegate : self.delegates) {
    SEL sel = @selector(audioSessionDidEndInterruption:shouldResumeSession:);
    if ([delegate respondsToSelector:sel]) {
      [delegate audioSessionDidEndInterruption:self
                           shouldResumeSession:shouldResumeSession];
    }
  }
}

- (void)notifyDidChangeRouteWithReason:(AVAudioSessionRouteChangeReason)reason
                         previousRoute:(AVAudioSessionRouteDescription *)previousRoute {
  for (auto delegate : self.delegates) {
    SEL sel = @selector(audioSessionDidChangeRoute:reason:previousRoute:);
    if ([delegate respondsToSelector:sel]) {
      [delegate audioSessionDidChangeRoute:self
                                    reason:reason
                             previousRoute:previousRoute];
    }
  }
}

- (void)notifyMediaServicesWereLost {
  for (auto delegate : self.delegates) {
    SEL sel = @selector(audioSessionMediaServerTerminated:);
    if ([delegate respondsToSelector:sel]) {
      [delegate audioSessionMediaServerTerminated:self];
    }
  }
}

- (void)notifyMediaServicesWereReset {
  for (auto delegate : self.delegates) {
    SEL sel = @selector(audioSessionMediaServerReset:);
    if ([delegate respondsToSelector:sel]) {
      [delegate audioSessionMediaServerReset:self];
    }
  }
}

- (void)notifyDidChangeCanPlayOrRecord:(BOOL)canPlayOrRecord {
  for (auto delegate : self.delegates) {
    SEL sel = @selector(audioSession:didChangeCanPlayOrRecord:);
    if ([delegate respondsToSelector:sel]) {
      [delegate audioSession:self didChangeCanPlayOrRecord:canPlayOrRecord];
    }
  }
}

- (void)notifyDidStartPlayOrRecord {
  for (auto delegate : self.delegates) {
    SEL sel = @selector(audioSessionDidStartPlayOrRecord:);
    if ([delegate respondsToSelector:sel]) {
      [delegate audioSessionDidStartPlayOrRecord:self];
    }
  }
}

- (void)notifyDidStopPlayOrRecord {
  for (auto delegate : self.delegates) {
    SEL sel = @selector(audioSessionDidStopPlayOrRecord:);
    if ([delegate respondsToSelector:sel]) {
      [delegate audioSessionDidStopPlayOrRecord:self];
    }
  }
}

- (void)notifyDidChangeOutputVolume:(float)outputVolume {
  for (auto delegate : self.delegates) {
    SEL sel = @selector(audioSession:didChangeOutputVolume:);
    if ([delegate respondsToSelector:sel]) {
      [delegate audioSession:self didChangeOutputVolume:outputVolume];
    }
  }
}

- (void)notifyDidDetectPlayoutGlitch:(int64_t)totalNumberOfGlitches {
  for (auto delegate : self.delegates) {
    SEL sel = @selector(audioSession:didDetectPlayoutGlitch:);
    if ([delegate respondsToSelector:sel]) {
      [delegate audioSession:self didDetectPlayoutGlitch:totalNumberOfGlitches];
    }
  }
}

- (void)notifyWillSetActive:(BOOL)active {
  for (id delegate : self.delegates) {
    SEL sel = @selector(audioSession:willSetActive:);
    if ([delegate respondsToSelector:sel]) {
      [delegate audioSession:self willSetActive:active];
    }
  }
}

- (void)notifyDidSetActive:(BOOL)active {
  for (id delegate : self.delegates) {
    SEL sel = @selector(audioSession:didSetActive:);
    if ([delegate respondsToSelector:sel]) {
      [delegate audioSession:self didSetActive:active];
    }
  }
}

- (void)notifyFailedToSetActive:(BOOL)active error:(NSError *)error {
  for (id delegate : self.delegates) {
    SEL sel = @selector(audioSession:failedToSetActive:error:);
    if ([delegate respondsToSelector:sel]) {
      [delegate audioSession:self failedToSetActive:active error:error];
    }
  }
}

- (BOOL)setConfiguration:(RTC_OBJC_TYPE(RTCAudioSessionConfiguration) *)configuration
                 active:(BOOL)active
                 error:(NSError **)outError {
  NSLog(@"🎧 [WebRTC] setConfiguration called - DISABLED (preserving SDK configuration)");
  if (![self checkLock:outError]) {
    return NO;
  }
  
  // COMPLETELY DISABLED: Let SDK handle all audio session management
  // This method would normally call setCategory, setPreferredSampleRate, 
  // setPreferredIOBufferDuration, and setActive - all now disabled
  NSLog(@"🎧 [WebRTC] setConfiguration completed (no actual changes made)");
  return YES;
}

@end

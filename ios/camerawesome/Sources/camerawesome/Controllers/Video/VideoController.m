//
//  VideoController.m
//  camerawesome
//
//  Created by Dimitri Dessus on 17/12/2020.
//

#import "VideoController.h"

FourCharCode const videoFormat = kCVPixelFormatType_32BGRA;

@implementation VideoController

- (instancetype)init {
  self = [super init];
  _isRecording = NO;
  _isAudioEnabled = YES;
  _isPaused = NO;
  
  return self;
}

# pragma mark - User video interactions

/// Start recording video at given path
- (void)recordVideoAtPath:(NSString *)path captureDevice:(AVCaptureDevice *)device orientation:(NSInteger)orientation audioSetupCallback:(OnAudioSetup)audioSetupCallback videoWriterCallback:(OnVideoWriterSetup)videoWriterCallback options:(CupertinoVideoOptions *)options quality:(VideoRecordingQuality)quality completion:(nonnull void (^)(FlutterError * _Nullable))completion {
  _options = options;
  _recordingQuality = quality;
  
  // Create audio & video writer
  if (![self setupWriterForPath:path audioSetupCallback:audioSetupCallback options:options completion:completion]) {
    completion([FlutterError errorWithCode:@"VIDEO_ERROR" message:@"impossible to write video at path" details:path]);
    return;
  }
  // Call parent to add delegates for video & audio (if needed)
  videoWriterCallback();
  
  _isRecording = YES;
  _videoTimeOffset = CMTimeMake(0, 1);
  _audioTimeOffset = CMTimeMake(0, 1);
  _videoIsDisconnected = NO;
  _audioIsDisconnected = NO;
  _orientation = orientation;
  _captureDevice = device;
  
  // Change video FPS if provided
  if (_options && _options.fps != nil && _options.fps > 0) {
    int targetFPS = [_options.fps intValue];
    
    // Check device support first
    if (![self deviceSupportsFrameRate:targetFPS]) {
      NSLog(@"⚠️ Device doesn't support %dfps, using default frame rate", targetFPS);
    } else {
      // Use appropriate method based on frame rate
      if (targetFPS > 60) {
        BOOL success = [self setupHighFrameRateFormat:_options.fps];
        if (!success) {
          NSLog(@"⚠️ Failed to set high frame rate, falling back to standard method");
          [self adjustCameraFPS:_options.fps];
        }
      } else {
        [self adjustCameraFPS:_options.fps];
      }
    }
  }
}

/// Stop recording video
- (void)stopRecordingVideo:(nonnull void (^)(NSNumber * _Nullable, FlutterError * _Nullable))completion {
  if (_options && _options.fps != nil && _options.fps > 0) {
    // Reset camera FPS
    [self adjustCameraFPS:@(30)];
  }
  
  if (_isRecording) {
    _isRecording = NO;
    if (_videoWriter.status != AVAssetWriterStatusUnknown) {
      [_videoWriter finishWritingWithCompletionHandler:^{
        if (self->_videoWriter.status == AVAssetWriterStatusCompleted) {
          completion(@(YES), nil);
        } else {
          completion(@(NO), [FlutterError errorWithCode:@"VIDEO_ERROR" message:@"impossible to completely write video" details:@""]);
        }
      }];
    }
  } else {
    completion(@(NO), [FlutterError errorWithCode:@"VIDEO_ERROR" message:@"video is not recording" details:@""]);
  }
}

- (void)pauseVideoRecording {
  _isPaused = YES;
}

- (void)resumeVideoRecording {
  _isPaused = NO;
}

# pragma mark - Audio & Video writers

/// Setup video channel & write file on path
- (BOOL)setupWriterForPath:(NSString *)path audioSetupCallback:(OnAudioSetup)audioSetupCallback options:(CupertinoVideoOptions *)options completion:(nonnull void (^)(FlutterError * _Nullable))completion {
  NSError *error = nil;
  NSURL *outputURL;
  if (path != nil) {
    outputURL = [NSURL fileURLWithPath:path];
  } else {
    return NO;
  }
  if (_isAudioEnabled && !_isAudioSetup) {
    audioSetupCallback();
  }
  
  // Read from options if available
  AVVideoCodecType codecType = [self getBestCodecTypeAccordingOptions:options];
  AVFileType fileType = [self getBestFileTypeAccordingOptions:options];
  CGSize videoSize = [self getBestVideoSizeAccordingQuality: _recordingQuality];
  
  // Create video settings dictionary
  NSMutableDictionary *videoSettings = [@{
    AVVideoCodecKey   : codecType,
    AVVideoWidthKey   : @(videoSize.height),
    AVVideoHeightKey  : @(videoSize.width),
  } mutableCopy];
  
  // Enhanced settings for high frame rate videos
//  if (options && options.fps && [options.fps intValue] > 60) {
//    int fps = [options.fps intValue];
//    
//    // Calculate bitrate based on resolution and frame rate
//    // Base bitrate: resolution * fps * quality factor
//    double baseBitrate = videoSize.width * videoSize.height * fps * 0.5;
//    
//    // Adjust bitrate based on frame rate
//    double bitrate;
//    if (fps >= 240) {
//      bitrate = baseBitrate * 0.8; // Slightly reduce for very high frame rates
//    } else if (fps >= 120) {
//      bitrate = baseBitrate * 0.9;
//    } else {
//      bitrate = baseBitrate;
//    }
//    
//    // Set minimum and maximum bitrates
//    double minBitrate = bitrate * 0.5;
//    double maxBitrate = bitrate * 1.5;
//    
//    NSDictionary *compressionProperties = @{
//      AVVideoAverageBitRateKey: @(bitrate),
//      AVVideoMaxKeyFrameIntervalKey: @(fps * 2), // Key frame every 2 seconds
//      AVVideoMaxKeyFrameIntervalDurationKey: @(2.0),
//      AVVideoAllowFrameReorderingKey: @(NO), // Disable frame reordering for real-time
//      AVVideoH264EntropyModeKey: AVVideoH264EntropyModeCABAC, // Better compression
//      AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel, // High profile for better quality
//    };
//    
//    videoSettings[AVVideoCompressionPropertiesKey] = compressionProperties;
//    
//    NSLog(@"🎬 High frame rate video settings:");
//    NSLog(@"   📊 Bitrate: %.0f kbps (min: %.0f, max: %.0f)",
//          bitrate/1000, minBitrate/1000, maxBitrate/1000);
//    NSLog(@"   📐 Resolution: %.0fx%.0f", videoSize.width, videoSize.height);
//    NSLog(@"   🎥 Frame rate: %d fps", fps);
//  }
  
  _videoWriterInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:videoSettings];
  [_videoWriterInput setTransform:[self getVideoOrientation]];
  
  _videoAdaptor = [AVAssetWriterInputPixelBufferAdaptor
                   assetWriterInputPixelBufferAdaptorWithAssetWriterInput:_videoWriterInput
                   sourcePixelBufferAttributes:@{
    (NSString *)kCVPixelBufferPixelFormatTypeKey: @(videoFormat)
  }];
  
  NSParameterAssert(_videoWriterInput);
  _videoWriterInput.expectsMediaDataInRealTime = YES;
  
  _videoWriter = [[AVAssetWriter alloc] initWithURL:outputURL
                                           fileType:fileType
                                              error:&error];
  NSParameterAssert(_videoWriter);
  if (error) {
    completion([FlutterError errorWithCode:@"VIDEO_ERROR" message:@"impossible to create video writer, check your options" details:error.description]);
    return NO;
  }
  
  [_videoWriter addInput:_videoWriterInput];
  
  if (_isAudioEnabled) {
    AudioChannelLayout acl;
    bzero(&acl, sizeof(acl));
    acl.mChannelLayoutTag = kAudioChannelLayoutTag_Mono;
    NSDictionary *audioOutputSettings = nil;
    
    audioOutputSettings = [NSDictionary
                           dictionaryWithObjectsAndKeys:[NSNumber numberWithInt:kAudioFormatMPEG4AAC], AVFormatIDKey,
                           [NSNumber numberWithFloat:44100.0], AVSampleRateKey,
                           [NSNumber numberWithInt:1], AVNumberOfChannelsKey,
                           [NSData dataWithBytes:&acl length:sizeof(acl)],
                           AVChannelLayoutKey, nil];
    _audioWriterInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeAudio
                                                           outputSettings:audioOutputSettings];
    _audioWriterInput.expectsMediaDataInRealTime = YES;
    
    [_videoWriter addInput:_audioWriterInput];
  }
  
  return YES;
}

- (CGAffineTransform)getVideoOrientation {
  CGAffineTransform transform;
  
  switch (_orientation) {
    case UIDeviceOrientationLandscapeLeft:
      transform = CGAffineTransformMakeRotation(M_PI_2);
      break;
    case UIDeviceOrientationLandscapeRight:
      transform = CGAffineTransformMakeRotation(-M_PI_2);
      break;
    case UIDeviceOrientationPortraitUpsideDown:
      transform = CGAffineTransformMakeRotation(M_PI);
      break;
    default:
      transform = CGAffineTransformIdentity;
      break;
  }
  
  return transform;
}

/// Append audio data
- (void)newAudioSample:(CMSampleBufferRef)sampleBuffer {
  if (_videoWriter.status != AVAssetWriterStatusWriting) {
    if (_videoWriter.status == AVAssetWriterStatusFailed) {
      //      *error = [FlutterError errorWithCode:@"VIDEO_ERROR" message:@"writing video failed" details:_videoWriter.error];
    }
    return;
  }
  if (_audioWriterInput.readyForMoreMediaData) {
    if (![_audioWriterInput appendSampleBuffer:sampleBuffer]) {
      //      *error = [FlutterError errorWithCode:@"VIDEO_ERROR" message:@"adding audio channel failed" details:_videoWriter.error];
    }
  }
}

/// Adjust time to sync audio & video
- (CMSampleBufferRef)adjustTime:(CMSampleBufferRef)sample by:(CMTime)offset CF_RETURNS_RETAINED {
  CMItemCount count;
  CMSampleBufferGetSampleTimingInfoArray(sample, 0, nil, &count);
  CMSampleTimingInfo *pInfo = malloc(sizeof(CMSampleTimingInfo) * count);
  CMSampleBufferGetSampleTimingInfoArray(sample, count, pInfo, &count);
  for (CMItemCount i = 0; i < count; i++) {
    pInfo[i].decodeTimeStamp = CMTimeSubtract(pInfo[i].decodeTimeStamp, offset);
    pInfo[i].presentationTimeStamp = CMTimeSubtract(pInfo[i].presentationTimeStamp, offset);
  }
  CMSampleBufferRef sout;
  CMSampleBufferCreateCopyWithNewTiming(nil, sample, count, pInfo, &sout);
  free(pInfo);
  return sout;
}

/// Adjust video preview & recording to specified FPS
- (void)adjustCameraFPS:(NSNumber *)fps {
  NSArray *frameRateRanges = _captureDevice.activeFormat.videoSupportedFrameRateRanges;
  
  if (frameRateRanges.count > 0) {
    AVFrameRateRange *frameRateRange = frameRateRanges.firstObject;
    NSError *error = nil;
    
    if ([_captureDevice lockForConfiguration:&error]) {
      CMTime frameDuration = CMTimeMake(1, [fps intValue]);
      if (CMTIME_COMPARE_INLINE(frameDuration, <=, frameRateRange.maxFrameDuration) && CMTIME_COMPARE_INLINE(frameDuration, >=, frameRateRange.minFrameDuration)) {
        _captureDevice.activeVideoMinFrameDuration = frameDuration;
        _captureDevice.activeVideoMaxFrameDuration = frameDuration;
      }
      [_captureDevice unlockForConfiguration];
    }
  }
}

/// Check if device supports the specified frame rate
- (BOOL)deviceSupportsFrameRate:(int)fps {
  for (AVCaptureDeviceFormat *format in [_captureDevice formats]) {
    for (AVFrameRateRange *range in format.videoSupportedFrameRateRanges) {
      if (range.maxFrameRate >= fps) {
        return YES;
      }
    }
  }
  return NO;
}

/// Setup high frame rate format for fps > 60
- (BOOL)setupHighFrameRateFormat:(NSNumber *)fps {
  int targetFPS = [fps intValue];
  
  // Only for high frame rate (>60fps)
  if (targetFPS <= 60) {
    [self adjustCameraFPS:fps];
    return YES;
  }
  
  NSLog(@"Setting up high frame rate: %dfps", targetFPS);
  
  NSError *error = nil;
  if ([_captureDevice lockForConfiguration:&error]) {
    // Find format supporting high frame rate
    AVCaptureDeviceFormat *bestFormat = nil;
    AVFrameRateRange *bestRange = nil;
    int bestScore = 0;
    
    for (AVCaptureDeviceFormat *format in [_captureDevice formats]) {
      CMVideoDimensions dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription);
      
      // Check if this is a video format (not photo)
      CMFormatDescriptionRef formatDescription = format.formatDescription;
      CMMediaType mediaType = CMFormatDescriptionGetMediaType(formatDescription);
      if (mediaType != kCMMediaType_Video) {
        continue;
      }
      
      for (AVFrameRateRange *range in format.videoSupportedFrameRateRanges) {
        if (range.maxFrameRate >= targetFPS) {
          // Calculate score based on resolution and frame rate support
          int score = 0;
          
          
          // For 240fps, prefer formats with reasonable resolution
          if (targetFPS >= 240) {
            // Prefer 720p for 240fps
            if (dimensions.width <= 1280 && dimensions.height <= 720) {
              score += 100;
            } else if (dimensions.width > 1920 || dimensions.height > 1080) {
              continue; // Skip too high resolution formats for 240fps
            }
          } else if (targetFPS >= 120) {
            // For 120fps, allow up to 1080p
            if (dimensions.width <= 1920 && dimensions.height <= 1080) {
              score += 80;
            }
          }
          
          // Prefer exact frame rate match
          if (range.maxFrameRate == targetFPS) {
            score += 50;
          } else if (range.maxFrameRate > targetFPS) {
            score += 30;
          }
          
          // Prefer higher resolution within limits--not use
          // score += (dimensions.width * dimensions.height) / 10000;
          
          if (score > bestScore || bestFormat == nil) {
            bestFormat = format;
            bestRange = range;
            bestScore = score;
          }
        }
      }
    }
    
    
    if (bestFormat && bestRange) {
      // Set the best format
      _captureDevice.activeFormat = bestFormat;
      
      // Set frame rate
      CMTime frameDuration = CMTimeMake(1, targetFPS);
      _captureDevice.activeVideoMinFrameDuration = frameDuration;
      _captureDevice.activeVideoMaxFrameDuration = frameDuration;
      
      [_captureDevice unlockForConfiguration];
      
      CMVideoDimensions dims = CMVideoFormatDescriptionGetDimensions(bestFormat.formatDescription);
      NSLog(@"✅ High frame rate setup successful: %dfps at %dx%d", targetFPS, dims.width, dims.height);
      NSLog(@"📊 Format details - MediaSubType: %d, Range: %.0f-%.0f fps",
            CMFormatDescriptionGetMediaSubType(bestFormat.formatDescription),
            bestRange.minFrameRate, bestRange.maxFrameRate);
      
      return YES;
    } else {
      [_captureDevice unlockForConfiguration];
      NSLog(@"❌ No format supports %dfps", targetFPS);
      
      // Log available formats for debugging
      NSLog(@"📋 Available formats:");
      for (AVCaptureDeviceFormat *format in [_captureDevice formats]) {
        CMVideoDimensions dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription);
        NSLog(@"   📐 %dx%d", dims.width, dims.height);
        for (AVFrameRateRange *range in format.videoSupportedFrameRateRanges) {
          NSLog(@"      🎬 %.0f-%.0f fps", range.minFrameRate, range.maxFrameRate);
        }
      }
      
      return NO;
    }
  } else {
    NSLog(@"❌ Failed to lock device for configuration: %@", error.localizedDescription);
    return NO;
  }
}

# pragma mark - Camera Delegates
- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection captureVideoOutput:(AVCaptureVideoDataOutput *)captureVideoOutput {
  
  if (self.isPaused) {
    return;
  }
  
  if (_videoWriter.status == AVAssetWriterStatusFailed) {
    //    _result([FlutterError errorWithCode:@"VIDEO_ERROR" message:@"impossible to write video " details:_videoWriter.error]);
    return;
  }
  
  CFRetain(sampleBuffer);
  CMTime currentSampleTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
  
  if (_videoWriter.status != AVAssetWriterStatusWriting) {
    [_videoWriter startWriting];
    [_videoWriter startSessionAtSourceTime:currentSampleTime];
  }
  
  if (output == captureVideoOutput) {
    if (_videoIsDisconnected) {
      _videoIsDisconnected = NO;
      
      if (_videoTimeOffset.value == 0) {
        _videoTimeOffset = CMTimeSubtract(currentSampleTime, _lastVideoSampleTime);
      } else {
        CMTime offset = CMTimeSubtract(currentSampleTime, _lastVideoSampleTime);
        _videoTimeOffset = CMTimeAdd(_videoTimeOffset, offset);
      }
      
      return;
    }
    
    _lastVideoSampleTime = currentSampleTime;
    
    CVPixelBufferRef nextBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    CMTime nextSampleTime = CMTimeSubtract(_lastVideoSampleTime, _videoTimeOffset);
    [_videoAdaptor appendPixelBuffer:nextBuffer withPresentationTime:nextSampleTime];
  } else {
    CMTime dur = CMSampleBufferGetDuration(sampleBuffer);
    
    if (dur.value > 0) {
      currentSampleTime = CMTimeAdd(currentSampleTime, dur);
    }
    if (_audioIsDisconnected) {
      _audioIsDisconnected = NO;
      
      if (_audioTimeOffset.value == 0) {
        _audioTimeOffset = CMTimeSubtract(currentSampleTime, _lastAudioSampleTime);
      } else {
        CMTime offset = CMTimeSubtract(currentSampleTime, _lastAudioSampleTime);
        _audioTimeOffset = CMTimeAdd(_audioTimeOffset, offset);
      }
      
      return;
    }
    
    _lastAudioSampleTime = currentSampleTime;
    
    if (_audioTimeOffset.value != 0) {
      CFRelease(sampleBuffer);
      sampleBuffer = [self adjustTime:sampleBuffer by:_audioTimeOffset];
    }
    
    [self newAudioSample:sampleBuffer];
  }
  
  CFRelease(sampleBuffer);
}

# pragma mark - Settings converters

- (AVFileType)getBestFileTypeAccordingOptions:(CupertinoVideoOptions *)options {
  AVFileType fileType = AVFileTypeQuickTimeMovie;
  
  if (options && options != (id)[NSNull null]) {
    CupertinoFileType type = options.fileType;
    switch (type) {
      case CupertinoFileTypeQuickTimeMovie:
        fileType = AVFileTypeQuickTimeMovie;
        break;
      case CupertinoFileTypeMpeg4:
        fileType = AVFileTypeMPEG4;
        break;
      case CupertinoFileTypeAppleM4V:
        fileType = AVFileTypeAppleM4V;
        break;
      case CupertinoFileTypeType3GPP:
        fileType = AVFileType3GPP;
        break;
      case CupertinoFileTypeType3GPP2:
        fileType = AVFileType3GPP2;
        break;
      default:
        break;
    }
  }
  
  return fileType;
}

- (AVVideoCodecType)getBestCodecTypeAccordingOptions:(CupertinoVideoOptions *)options {
  AVVideoCodecType codecType = AVVideoCodecTypeH264;
  if (options && options != (id)[NSNull null]) {
    CupertinoCodecType codec = options.codec;
    switch (codec) {
      case CupertinoCodecTypeH264:
        codecType = AVVideoCodecTypeH264;
        break;
      case CupertinoCodecTypeHevc:
        codecType = AVVideoCodecTypeHEVC;
        break;
      case CupertinoCodecTypeHevcWithAlpha:
        codecType = AVVideoCodecTypeHEVCWithAlpha;
        break;
      case CupertinoCodecTypeJpeg:
        codecType = AVVideoCodecTypeJPEG;
        break;
      case CupertinoCodecTypeAppleProRes4444:
        codecType = AVVideoCodecTypeAppleProRes4444;
        break;
      case CupertinoCodecTypeAppleProRes422:
        codecType = AVVideoCodecTypeAppleProRes422;
        break;
      case CupertinoCodecTypeAppleProRes422HQ:
        codecType = AVVideoCodecTypeAppleProRes422HQ;
        break;
      case CupertinoCodecTypeAppleProRes422LT:
        codecType = AVVideoCodecTypeAppleProRes422LT;
        break;
      case CupertinoCodecTypeAppleProRes422Proxy:
        codecType = AVVideoCodecTypeAppleProRes422Proxy;
        break;
      default:
        break;
    }
  }
  return codecType;
}

// 这里 高帧率拍摄 分辨率 可能最多到 (1280, 720)
- (CGSize)getBestVideoSizeAccordingQuality:(VideoRecordingQuality)quality {
  CGSize size;
  switch (quality) {
    case VideoRecordingQualityUhd:
    case VideoRecordingQualityHighest:
      if (@available(iOS 9.0, *)) {
        if ([_captureDevice supportsAVCaptureSessionPreset:AVCaptureSessionPreset3840x2160]) {
          size = CGSizeMake(3840, 2160);
        } else {
          size = CGSizeMake(1920, 1080);
        }
      } else {
        return CGSizeMake(1920, 1080);
      }
      break;
    case VideoRecordingQualityFhd:
      size = CGSizeMake(1920, 1080);
      break;
    case VideoRecordingQualityHd:
      size = CGSizeMake(1280, 720);
      break;
    case VideoRecordingQualitySd:
    case VideoRecordingQualityLowest:
      size = CGSizeMake(960, 540);
      break;
  }
    
  // ensure video output size does not exceed capture session size
  if (size.width > _previewSize.width) {
    size = _previewSize;
  }
  
  return size;
}

# pragma mark - Setter
- (void)setIsAudioEnabled:(bool)isAudioEnabled {
  _isAudioEnabled = isAudioEnabled;
}
- (void)setIsAudioSetup:(bool)isAudioSetup {
  _isAudioSetup = isAudioSetup;
}

- (void)setPreviewSize:(CGSize)previewSize {
  _previewSize = previewSize;
}

- (void)setVideoIsDisconnected:(bool)videoIsDisconnected {
  _videoIsDisconnected = videoIsDisconnected;
}

- (void)setAudioIsDisconnected:(bool)audioIsDisconnected {
  _audioIsDisconnected = audioIsDisconnected;
}

@end

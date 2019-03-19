/*
  This file is part of the Structure SDK.
  Copyright © 2016 Occipital, Inc. All rights reserved.
  http://structure.io
*/

#import "ViewController.h"
#import "ViewController+Camera.h"
#import "ViewController+Sensor.h"
#import "ViewController+SLAM.h"
#import "Endian.h"
#import "ObjectDetection.h"

#import <Structure/Structure.h>
#import <Structure/StructureSLAM.h>

#import <objc/runtime.h>
#define clamp(a) (a>255?255:(a<0?0:a));

ObjectDetection *detect;
UIImage *cameraIMG;

@implementation ViewController (Camera)

#pragma mark -  Color Camera

- (bool)queryCameraAuthorizationStatusAndNotifyUserIfNotGranted
{
    const NSUInteger numCameras = [[AVCaptureDevice devicesWithMediaType:AVMediaTypeVideo] count];
    
    if (0 == numCameras)
        return false; // This can happen even on devices that include a camera, when camera access is restricted globally.

    AVAuthorizationStatus authStatus = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
    
    if (authStatus != AVAuthorizationStatusAuthorized)
    {
        NSLog(@"Not authorized to use the camera!");
        
        [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo
                                 completionHandler:^(BOOL granted)
         {
             // This block fires on a separate thread, so we need to ensure any actions here
             // are sent to the right place.
             
             // If the request is granted, let's try again to start an AVFoundation session.
             // Otherwise, alert the user that things won't go well.
             if (granted)
             {
                 dispatch_async(dispatch_get_main_queue(), ^(void) {
                     
                     [self startColorCamera];
                     
                     _appStatus.colorCameraIsAuthorized = true;
                     [self updateAppStatusMessage];
                     
                 });
             }
         }];
        
        return false;
    }
    
    return true;
}

- (void)setupColorCamera
{
    // If already setup, skip it
    if (self.avCaptureSession)
        return;
    
    bool cameraAccessAuthorized = [self queryCameraAuthorizationStatusAndNotifyUserIfNotGranted];
    
    if (!cameraAccessAuthorized)
    {
        _appStatus.colorCameraIsAuthorized = false;
        [self updateAppStatusMessage];
        return;
    }
    
    // Use VGA color.
    NSString *sessionPreset = AVCaptureSessionPreset640x480;
    
    // Set up Capture Session.
    self.avCaptureSession = [[AVCaptureSession alloc] init];
    [self.avCaptureSession beginConfiguration];
    
    // Set preset session size.
    [self.avCaptureSession setSessionPreset:sessionPreset];
    
    // Create a video device and input from that Device.  Add the input to the capture session.
    self.videoDevice = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
    if (self.videoDevice == nil)
        assert(0);
    
    // Configure Focus, Exposure, and White Balance
    NSError *error;
    
    // Use auto-exposure, and auto-white balance and set the focus to infinity.
    if([self.videoDevice lockForConfiguration:&error])
    {
        // Allow exposure to initially change
        if ([self.videoDevice isExposureModeSupported:AVCaptureExposureModeContinuousAutoExposure])
            [self.videoDevice setExposureMode:AVCaptureExposureModeContinuousAutoExposure];
        
        // Allow white balance to initially change
        if ([self.videoDevice isWhiteBalanceModeSupported:AVCaptureWhiteBalanceModeContinuousAutoWhiteBalance])
            [self.videoDevice setWhiteBalanceMode:AVCaptureWhiteBalanceModeContinuousAutoWhiteBalance];
        
        // We need to keep focus fixed during tracking.
        [self.videoDevice setFocusModeLockedWithLensPosition:_options.colorCameraLensPosition completionHandler:nil];
        
        [self.videoDevice unlockForConfiguration];
    }
    
    //  Add the device to the session.
    AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:self.videoDevice error:&error];
    if (error)
    {
        NSLog(@"Cannot initialize AVCaptureDeviceInput");
        assert(0);
    }
    
    [self.avCaptureSession addInput:input]; // After this point, captureSession captureOptions are filled.
    
    //  Create the output for the capture session.
    AVCaptureVideoDataOutput* dataOutput = [[AVCaptureVideoDataOutput alloc] init];
    
    // We don't want to process late frames.
    [dataOutput setAlwaysDiscardsLateVideoFrames:YES];
    
    // Use  YCbCr pixel format.
    [dataOutput setVideoSettings:[NSDictionary
                                  dictionaryWithObject:[NSNumber numberWithInt:kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
                                  forKey:(id)kCVPixelBufferPixelFormatTypeKey]];
    
    // Set dispatch to be on the main thread so OpenGL can do things with the data
    [dataOutput setSampleBufferDelegate:self queue:dispatch_get_main_queue()];
    
    [self.avCaptureSession addOutput:dataOutput];
    
    if([self.videoDevice lockForConfiguration:&error])
    {
        [self.videoDevice setActiveVideoMaxFrameDuration:CMTimeMake(1, 30)];
        [self.videoDevice setActiveVideoMinFrameDuration:CMTimeMake(1, 30)];
        [self.videoDevice unlockForConfiguration];
    }

    // Read in Apple Intrinsics, if required
    AVCaptureConnection *conn = [dataOutput connectionWithMediaType:AVMediaTypeVideo];
    conn.preferredVideoStabilizationMode = AVCaptureVideoStabilizationModeOff;
#if __IPHONE_OS_VERSION_MAX_ALLOWED >= 110000
    if (@available(iOS 11_0, *))
    {
        if (conn.isCameraIntrinsicMatrixDeliverySupported)
            conn.cameraIntrinsicMatrixDeliveryEnabled = YES;
    }
#endif

    [self.avCaptureSession commitConfiguration];
}

- (void)startColorCamera
{
    detect = [[ObjectDetection alloc] init];
    [detect initCascade];
    if (self.avCaptureSession && [self.avCaptureSession isRunning])
        return;
    
    // Re-setup so focus is lock even when back from background
    if (self.avCaptureSession == nil)
        [self setupColorCamera];
    
    // Start streaming color images.
    [self.avCaptureSession startRunning];
}

- (void)stopColorCamera
{
    if ([self.avCaptureSession isRunning])
    {
        // Stop the session
        [self.avCaptureSession stopRunning];
    }
    
    self.avCaptureSession = nil;
    self.videoDevice = nil;
}

- (void)setColorCameraParametersForInit
{
    NSError *error;
    
    [self.videoDevice lockForConfiguration:&error];
    
    // Auto-exposure
    if ([self.videoDevice isExposureModeSupported:AVCaptureExposureModeContinuousAutoExposure])
        [self.videoDevice setExposureMode:AVCaptureExposureModeContinuousAutoExposure];
    
    // Auto-white balance.
    if ([self.videoDevice isWhiteBalanceModeSupported:AVCaptureWhiteBalanceModeContinuousAutoWhiteBalance])
        [self.videoDevice setWhiteBalanceMode:AVCaptureWhiteBalanceModeContinuousAutoWhiteBalance];
    
    [self.videoDevice unlockForConfiguration];
    
}

- (void)setColorCameraParametersForScanning
{
    NSError *error;
    
    [self.videoDevice lockForConfiguration:&error];
    
    // Exposure locked to its current value.
    if([self.videoDevice isExposureModeSupported:AVCaptureExposureModeLocked])
        [self.videoDevice setExposureMode:AVCaptureExposureModeLocked];
    
    // White balance locked to its current value.
    if([self.videoDevice isWhiteBalanceModeSupported:AVCaptureWhiteBalanceModeLocked])
        [self.videoDevice setWhiteBalanceMode:AVCaptureWhiteBalanceModeLocked];
    
    [self.videoDevice unlockForConfiguration];
}


// Quelle: https://stackoverrun.com/de/q/3552648
- (void)captureOutput:(AVCaptureOutput *)captureOutput didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection
{
    // Pass color buffers directly to the driver, which will then produce synchronized depth/color pairs.
    [_sensorController frameSyncNewColorBuffer:sampleBuffer];
    
    // Create autorelease pool because we are not in the main_queue
    @autoreleasepool {
        
        CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
        
        //Lock the imagebuffer
        CVPixelBufferLockBaseAddress(imageBuffer,0);
        
        // Get information about the image
        uint8_t *baseAddress = (uint8_t *)CVPixelBufferGetBaseAddress(imageBuffer);
        
        // size_t bytesPerRow = CVPixelBufferGetBytesPerRow(imageBuffer);
        size_t width = CVPixelBufferGetWidth(imageBuffer);
        size_t height = CVPixelBufferGetHeight(imageBuffer);
        size_t bytesPerRow = CVPixelBufferGetBytesPerRow(imageBuffer);
        
        CVPlanarPixelBufferInfo_YCbCrBiPlanar *bufferInfo = (CVPlanarPixelBufferInfo_YCbCrBiPlanar *)baseAddress;
        //get the cbrbuffer base address
        uint8_t* cbrBuff = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(imageBuffer, 1);
        // This just moved the pointer past the offset
        baseAddress = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(imageBuffer, 0);
        
        //ImageManager *manager = [ImageManager sharedImageManager];
        // convert the image
        cameraIMG = [self makeUIImage:baseAddress cBCrBuffer:cbrBuff bufferInfo:bufferInfo width:width height:height bytesPerRow:bytesPerRow];
        
        CVPixelBufferUnlockBaseAddress(imageBuffer, kCVPixelBufferLock_ReadOnly);
        
        // Update the display with the captured image for DEBUG purposes
        dispatch_async(dispatch_get_main_queue(), ^{
            if([self isStateDiminish])
            {
                if([self switch1State])
                {
                    if(![self switch2State])
                    {
                        UIImage *meshIMG = [self getMeshImage];
                        UIImage *temp = [detect colorDetection:cameraIMG secondImg:meshIMG];
                        if(temp != NULL){
                            dispatch_async(dispatch_get_main_queue(), ^{
                                [self setViewImage: temp];
                            });
                        }
                    }
                    else
                    {
                        UIImage *meshIMG = [self getMeshImage];
                        UIImage *temp = [detect faceDetection:cameraIMG secondImg:meshIMG];
                        if(temp != NULL){
                            dispatch_async(dispatch_get_main_queue(), ^{
                                [self setViewImage: temp];
                            });
                        }
                    }
                }
                else{
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [self setViewImage:[self getMeshImage]];
                    });
                }
            }
        });
    }
}

// Quelle: https://stackoverrun.com/de/q/3552648
- (UIImage *)makeUIImage:(uint8_t *)inBaseAddress cBCrBuffer:(uint8_t*)cbCrBuffer bufferInfo:(CVPlanarPixelBufferInfo_YCbCrBiPlanar *)inBufferInfo width:(size_t)inWidth height:(size_t)inHeight bytesPerRow:(size_t)inBytesPerRow {
    
    NSUInteger yPitch = EndianU32_BtoN(inBufferInfo->componentInfoY.rowBytes);
    uint8_t *rgbBuffer = (uint8_t *)malloc(inWidth * inHeight * 4);
    NSUInteger cbCrPitch = EndianU32_BtoN(inBufferInfo->componentInfoCbCr.rowBytes);
    uint8_t *yBuffer = (uint8_t *)inBaseAddress;
    //uint8_t *cbCrBuffer = inBaseAddress + cbCrOffset;
    uint8_t val;
    int bytesPerPixel = 4;
    
    for(int y = 0; y < inHeight; y++)
    {
        uint8_t *rgbBufferLine = &rgbBuffer[y * inWidth * bytesPerPixel];
        uint8_t *yBufferLine = &yBuffer[y * yPitch];
        uint8_t *cbCrBufferLine = &cbCrBuffer[(y >> 1) * cbCrPitch];
        
        for(int x = 0; x < inWidth; x++)
        {
            int16_t y = yBufferLine[x];
            int16_t cb = cbCrBufferLine[x & ~1] - 128;
            int16_t cr = cbCrBufferLine[x | 1] - 128;
            
            uint8_t *rgbOutput = &rgbBufferLine[x*bytesPerPixel];
            
            int16_t r = (int16_t)roundf(y + cr * 1.4);
            int16_t g = (int16_t)roundf(y + cb * -0.343 + cr * -0.711);
            int16_t b = (int16_t)roundf(y + cb * 1.765);
            
            //ABGR
            rgbOutput[0] = 0xff;
            rgbOutput[1] = clamp(b);
            rgbOutput[2] = clamp(g);
            rgbOutput[3] = clamp(r);
        }
    }
    
    // Create a device-dependent RGB color space
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    NSLog(@"ypitch:%lu inHeight:%zu bytesPerPixel:%d",(unsigned long)yPitch,inHeight,bytesPerPixel);
    NSLog(@"cbcrPitch:%lu",cbCrPitch);
    CGContextRef context = CGBitmapContextCreate(rgbBuffer, inWidth, inHeight, 8,
                                                 inWidth*bytesPerPixel, colorSpace, kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedLast);
    
    CGImageRef quartzImage = CGBitmapContextCreateImage(context);
    
    CGContextRelease(context);
    CGColorSpaceRelease(colorSpace);
    
    UIImage *image = [UIImage imageWithCGImage:quartzImage];
    
    CGImageRelease(quartzImage);
    free(rgbBuffer);
    return image;
}

-(UIImage *) getLastOut
{
    return cameraIMG;
}

@end

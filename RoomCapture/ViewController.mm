/*
 This file is part of the Structure SDK.
 Copyright © 2016 Occipital, Inc. All rights reserved.
 http://structure.io
 */

#import "ViewController.h"
#import "ViewController+Camera.h"
#import "ViewController+OpenGL.h"
#import "ViewController+Sensor.h"
#import "ViewController+SLAM.h"
#import "ObjectDetection.h"
#import "EAGLView.h"

#import <Structure/Structure.h>
#import <Structure/StructureSLAM.h>

#import "CustomUIKitStyles.h"

#include <cmath>

bool dmished = false;

@implementation ViewController

#pragma mark - ViewController Setup

+ (instancetype) viewController
{
    return [[ViewController alloc] initWithNibName:@"ViewController" bundle:nil];
}

- (void)dealloc
{
    [self.avCaptureSession stopRunning];
    
    if ([EAGLContext currentContext] == _display.context)
    {
        [EAGLContext setCurrentContext:nil];
    }
}

- (void)viewDidLoad
{
    _cdect = [[ObjectDetection alloc] init];
    
    [super viewDidLoad];
    
    [self setupGL];
    
    [self setupUserInterface];
    
    [self setupIMU];
    
    [self setupSLAM];
    
    [self setupStructureSensor];
    
    // Make sure we get notified when the app becomes active to start/restore the sensor state if necessary.
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(appDidBecomeActive)
                                                 name:UIApplicationDidBecomeActiveNotification
                                               object:nil];
    
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    
    // The framebuffer will only be really ready with its final size after the view appears.
    [(EAGLView *)self.view setFramebuffer];
    
    [self setupGLViewport];
    
    // We will connect to the sensor when we receive appDidBecomeActive.
}

- (void)viewWillDisappear:(BOOL)animated
{
    [super viewWillDisappear:animated];
}

- (void)appDidBecomeActive
{
    // Try to connect to the Structure Sensor and stream if necessary.
    if ([self currentStateNeedsSensor])
        [self connectToStructureSensorAndStartStreaming];
    
    // Abort the current scan if we were still scanning before going into background since we
    // are not likely to recover well.
    if (_slamState.appState == StateScanning)
    {
        [self resetButtonPressed:self];
    }
}

- (void)didReceiveMemoryWarning
{
    [super didReceiveMemoryWarning];
}

- (void)setupUserInterface
{
    // Make sure the status bar is hidden.
    [[UIApplication sharedApplication] setStatusBarHidden:YES withAnimation:UIStatusBarAnimationSlide];
    
    // make round button
    //self.showImageButton.layer.cornerRadius = 5.0;
    
    _switch1.hidden = YES;
    _switch2.hidden = YES;
    _switch3.hidden = YES;
    _switch1Label.hidden = YES;
    _switch2Label.hidden = YES;
    _switch3Label.hidden = YES;
    
    // Fully transparent message label, initially.
    self.appStatusMessageLabel.alpha = 0;
    
    // Make sure the label is on top of everything else.
    self.appStatusMessageLabel.layer.zPosition = 100;
    
    // Apply our custom style to the tracking status label.
    [self.trackingMessageLabel applyCustomStyleWithBackgroundColor:blackLabelColorWithLightAlpha];
    
    // Apply our custom style to the roomSize label.
    [self.roomSizeLabel applyCustomStyleWithBackgroundColor:blackLabelColorWithLightAlpha];
    
    // Setup the roomSize slider range. It represents a scale factor, applied to the initial size.
    self.roomSizeSlider.value = 1.0;
    self.roomSizeSlider.minimumValue = 1.0/3.0;
    self.roomSizeSlider.maximumValue = 5.0/3.0;
    self.roomSizeLabel.hidden = true;
    
    _calibrationOverlay = nil;
    
    UIAlertView *alertView = [[UIAlertView alloc] initWithTitle:@"Welcome to Diminished Room Reality!" message:@"First scan your room, after that you can make objects disappear, either faces or green colored objects!" delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil];
    [alertView show];
}

// Make sure the status bar is disabled (iOS 7+)
- (BOOL)prefersStatusBarHidden
{
    return YES;
}

- (void)enterPoseInitializationState
{
    // Switch to the Scan button.
    self.scanButton.hidden = NO;
    self.doneButton.hidden = YES;
    self.resetButton.hidden = YES;
    
    // Show the room size controls.
    self.roomSizeSlider.hidden = NO;
    
    // Cannot be lost in cube placement mode.
    _trackingMessageLabel.hidden = YES;
    
    // We leave exposure unlock during init.
    [self setColorCameraParametersForInit];
    
    _slamState.appState = StatePoseInitialization;
    
    [self updateIdleTimer];
}

- (void)enterScanningState
{
    // Switch to the Done button.
    self.scanButton.hidden = YES;
    self.doneButton.hidden = NO;
    self.resetButton.hidden = NO;
    
    // Hide the room size controls.
    self.roomSizeLabel.hidden = YES;
    self.roomSizeSlider.hidden = YES;
    
    // Create a mapper.
    [self setupMapper];
    
    // Set the initial tracker camera pose.
    _slamState.tracker.initialCameraPose = _slamState.cameraPoseInitializer.cameraPose;
    
    // We will lock exposure during scanning to ensure better coloring.
    [self setColorCameraParametersForScanning];
    
    _slamState.appState = StateScanning;
}

// gets triggered by diminish button
- (void) enterDiminishedState
{
    // Cannot be lost if not scanning anymore.
    [self hideTrackingErrorMessage];
    
    // Hide the Scan/Done/Reset button.
    self.scanButton.hidden = YES;
    self.doneButton.hidden = YES;
    self.resetButton.hidden = YES;
    
    // save lastPose before stopping the sensors
    _slamState.lastPose = [_slamState.tracker lastFrameCameraPose];
    
    // Stop the sensors, we don't need them.
    [_sensorController stopStreaming];
    [self stopColorCamera];
    
    // Tell the mapper to compute a final triangle mesh from its data. Will also stop background processing.
    [_slamState.mapper finalizeTriangleMesh];
    
    _slamState.appState = StateDiminish;
    
    // Colorize the mesh in a background queue.
    [self colorizeMeshInBackground];
}

- (void)colorizeMeshInBackground
{
    // Take a copy of the scene mesh to safely modify it.
    _colorizedMesh = [[STMesh alloc] initWithMesh:[_slamState.scene lockAndGetSceneMesh]];
    [_slamState.scene unlockSceneMesh];
    
    _appStatus.backgroundProcessingStatus = AppStatus::BackgroundProcessingStatusFinalizing;
    [self updateAppStatusMessage];
    
    STBackgroundTask* colorizeTask = [STColorizer
                                      newColorizeTaskWithMesh:_colorizedMesh
                                      scene:_slamState.scene
                                      keyframes:[_slamState.keyFrameManager getKeyFrames]
                                      completionHandler: ^(NSError *error)
                                      {
                                          if (error != nil) {
                                              NSLog(@"Error during colorizing: %@", [error localizedDescription]);
                                          }
                                          
                                          dispatch_async(dispatch_get_main_queue(), ^{
                                              
                                              _appStatus.backgroundProcessingStatus = AppStatus::BackgroundProcessingStatusIdle;
                                              _appStatus.statusMessageDisabled = true;
                                              [self updateAppStatusMessage];
                                              [self initializeDiminishedState];
                                              
                                          });
                                      }
                                      options:@{kSTColorizerTypeKey: @(STColorizerTextureMapForRoom) }
                                      error:nil];
    
    [colorizeTask start];
    
}

-(void) fillHoles{
    STMesh* sceneMesh = [_slamState.scene lockAndGetSceneMesh];
    STMesh* sceneMeshCopy = [[STMesh alloc] initWithMesh:sceneMesh];
    [_slamState.scene unlockSceneMesh];
    
    _appStatus.backgroundProcessingStatus = AppStatus::BackgroundProcessingStatusFinalizing;
    [self updateAppStatusMessage];
    
    STBackgroundTask* holeFillingTask = [STMesh newFillHolesTaskWithMesh:sceneMeshCopy completionHandler:^(STMesh* result, NSError *error) {
        
        _holeFilledMesh = result;
        
        _holeFillingTask = nil;
        
        // Now colorize the hole filled mesh.
        STBackgroundTask* colorizeTask = [STColorizer
                                          newColorizeTaskWithMesh:_holeFilledMesh
                                          scene:_slamState.scene
                                          keyframes:[_slamState.keyFrameManager getKeyFrames]
                                          completionHandler:^(NSError *error)
                                          {
                                              dispatch_async(dispatch_get_main_queue(), ^{
                                                  _colorizeTask = nil; // release the handle on the completed task.
                                                  _appStatus.backgroundProcessingStatus = AppStatus::BackgroundProcessingStatusIdle;
                                                  _appStatus.statusMessageDisabled = true;
                                                  [self updateAppStatusMessage];
                                                  [self initializeDiminishedState];
                                              });
                                              
                                          }
                                          options:@{kSTColorizerTypeKey: @(STColorizerTextureMapForRoom) }
                                          error:nil];
        _colorizeTask = colorizeTask;
        _colorizeTask.delegate = self;
        [_colorizeTask start];
        
        
    }];
    
    // Keep a reference so we can monitor progress
    _holeFillingTask = holeFillingTask;
    _holeFillingTask.delegate = self;
    
    [_holeFillingTask start];
    
}

- (void) initializeDiminishedState
{
    meshRef = [[STMesh alloc] initWithMesh:_colorizedMesh];
    _meshRenderer = new MeshRenderer;
    _meshRenderer->initializeGL();
    _meshRenderer->uploadMesh(meshRef);
    
    // reset everything and start streaming again
    _slamState.appState = StateDiminish;
    // Restart the sensor.
    [self connectToStructureSensorAndStartStreaming];
    
    _appStatus.statusMessageDisabled = false;
    [self updateAppStatusMessage];
    
    // Reset the tracker, mapper, etc.
    [self resetSLAMKeepMeshes];
    
    _slamState.tracker.initialCameraPose = _slamState.lastPose;

    [self updateIdleTimer];
    
    dmished = true;
    
    //self.resetButton.hidden = NO;
    _switch1.hidden = NO;
    _switch2.hidden = NO;
    _switch3.hidden = NO;
    _switch1Label.hidden = NO;
    _switch2Label.hidden = NO;
    _switch3Label.hidden = NO;
}

- (void)adjustVolumeSize:(GLKVector3)volumeSize
{
    _slamState.volumeSizeInMeters = volumeSize;
    _slamState.cameraPoseInitializer.volumeSizeInMeters = volumeSize;
}

- (UIImage *)getMeshImage
{
    NSDate *startM = [NSDate date];
    // 4:3 resolution
    const int width = 640;
    const int height = 480;
    
    GLint currentFrameBuffer;
    glGetIntegerv(GL_FRAMEBUFFER_BINDING, &currentFrameBuffer);
    
    // Create temp texture, framebuffer, renderbuffer
    glViewport(0, 0, width, height);
    
    // We are going to render the preview to a texture.
    GLuint outputTexture;
    glActiveTexture(GL_TEXTURE0);
    glGenTextures(1, &outputTexture);
    glBindTexture(GL_TEXTURE_2D, outputTexture);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, width, height, 0, GL_RGBA, GL_UNSIGNED_BYTE, NULL);
    
    // Create the offscreen framebuffers and attach the outputTexture to them.
    GLuint colorFrameBuffer, depthRenderBuffer;
    glGenFramebuffers(1, &colorFrameBuffer);
    glBindFramebuffer(GL_FRAMEBUFFER, colorFrameBuffer);
    glGenRenderbuffers(1, &depthRenderBuffer);
    glBindRenderbuffer(GL_RENDERBUFFER, depthRenderBuffer);
    glRenderbufferStorage(GL_RENDERBUFFER, GL_DEPTH_COMPONENT16, width, height);
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_RENDERBUFFER, depthRenderBuffer);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, outputTexture, 0);
    
    float fovXRadians = 90.f/350.f * M_PI;
    float aspectRatio = 4.f/3.f;
    
    // Take the screenshot from the initial viewpoint, before user interactions.
    bool isInvertible = false;
    GLKMatrix4 modelViewMatrix = GLKMatrix4Invert([_slamState.tracker lastFrameCameraPose], &isInvertible);
    GLKMatrix4 projectionMatrix = [self getCameraGLProjection];
    
    // Keep the current render mode
    MeshRenderer::RenderingMode previousRenderingMode = _meshRenderer->getRenderingMode();
    
    // Screenshot rendering mode, always use colors if possible.
    if ([meshRef hasPerVertexColors])
    {
        _meshRenderer->setRenderingMode( MeshRenderer::RenderingModePerVertexColor );
    }
    else if ([self->meshRef hasPerVertexUVTextureCoords] && [self->meshRef meshYCbCrTexture])
    {
        _meshRenderer->setRenderingMode( MeshRenderer::RenderingModeTextured );
    }
    else
    {
        _meshRenderer->setRenderingMode( MeshRenderer::RenderingModeLightedGray );
    }
    
    // Render the mesh at the given viewpoint.
    _meshRenderer->clear();
    _meshRenderer->render(projectionMatrix, modelViewMatrix);
    
    // back to current render mode
    _meshRenderer->setRenderingMode( previousRenderingMode );
    
    struct RgbaPixel { uint8_t rgba[4]; };
    std::vector<RgbaPixel> screenShotRgbaBuffer (width*height);
    glReadPixels(0, 0, width, height, GL_RGBA, GL_UNSIGNED_BYTE, screenShotRgbaBuffer.data());
    
    // We need to flip the vertice axis, because OpenGL reads out the buffer from the bottom.
    std::vector<RgbaPixel> rowBuffer (width);
    for (int h = 0; h < height/2; ++h)
    {
        RgbaPixel* screenShotDataTopRow    = screenShotRgbaBuffer.data() + h * width;
        RgbaPixel* screenShotDataBottomRow = screenShotRgbaBuffer.data() + (height - h - 1) * width;
        
        // Swap the top and bottom rows, using rowBuffer as a temporary placeholder.
        memcpy(rowBuffer.data(), screenShotDataTopRow, width * sizeof(RgbaPixel));
        memcpy(screenShotDataTopRow, screenShotDataBottomRow, width * sizeof (RgbaPixel));
        memcpy(screenShotDataBottomRow, rowBuffer.data(), width * sizeof (RgbaPixel));
    }
    
    CGColorSpaceRef colorSpace;
    CGImageAlphaInfo alphaInfo;
    CGContextRef context;
    
    colorSpace = CGColorSpaceCreateDeviceRGB();
    alphaInfo = kCGImageAlphaNoneSkipLast;
    context = CGBitmapContextCreate(reinterpret_cast<uint8_t*>(screenShotRgbaBuffer.data()), width, height, 8, width * 4, colorSpace, alphaInfo);

    CGImageRef rgbImage = CGBitmapContextCreateImage(context);
    
    UIImage *newImage = [UIImage imageWithCGImage:rgbImage];
    
    CGImageRelease(rgbImage);
    CGContextRelease(context);
    CGColorSpaceRelease(colorSpace);
    
    glBindFramebuffer(GL_FRAMEBUFFER, currentFrameBuffer);
    
    // Release the rendering buffers.
    glDeleteTextures(1, &outputTexture);
    glDeleteFramebuffers(1, &colorFrameBuffer);
    glDeleteRenderbuffers(1, &depthRenderBuffer);
    
    NSDate *endM = [NSDate date];
    NSTimeInterval executionTime = [endM timeIntervalSinceDate:startM];
    NSLog(@"Meshimage exec Time: %f", executionTime);
    
    return newImage;
}

-(BOOL)currentStateNeedsSensor
{
    switch (_slamState.appState)
    {
            // Initialization and scanning need the sensor.
        case StatePoseInitialization:
        case StateScanning:
        case StateDiminish:
            return TRUE;
            
            // Other states don't need the sensor.
        default:
            return FALSE;
    }
}

#pragma mark - IMU

- (void)setupIMU
{
    _lastCoreMotionGravity = GLKVector3Make (0,0,0);
    
    // 60 FPS is responsive enough for motion events.
    const float fps = 60.0;
    _motionManager = [[CMMotionManager alloc] init];
    _motionManager.accelerometerUpdateInterval = 1.0/fps;
    _motionManager.gyroUpdateInterval = 1.0/fps;
    
    // Limiting the concurrent ops to 1 is a simple way to force serial execution
    _imuQueue = [[NSOperationQueue alloc] init];
    [_imuQueue setMaxConcurrentOperationCount:1];
    
    __weak ViewController *weakSelf = self;
    CMDeviceMotionHandler dmHandler = ^(CMDeviceMotion *motion, NSError *error)
    {
        // Could be nil if the self is released before the callback happens.
        if (weakSelf) {
            [weakSelf processDeviceMotion:motion withError:error];
        }
    };
    
    [_motionManager startDeviceMotionUpdatesToQueue:_imuQueue withHandler:dmHandler];
}

- (void)processDeviceMotion:(CMDeviceMotion *)motion withError:(NSError *)error
{
    if (_slamState.appState == StatePoseInitialization)
    {
        // Update our gravity vector, it will be used by the cube placement initializer.
        _lastCoreMotionGravity = GLKVector3Make (motion.gravity.x, motion.gravity.y, motion.gravity.z);
    }
    
    if (_slamState.appState == StatePoseInitialization || _slamState.appState == StateScanning || _slamState.appState == StateDiminish)
    {
        // The tracker is more robust to fast moves if we feed it with motion data.
        [_slamState.tracker updateCameraPoseWithMotion:motion];
    }
    
    if (_slamState.appState == StateDiminish)
    {
        [_slamState.tracker updateCameraPoseWithMotion:motion];
    }
}

#pragma mark - Message Display

- (void)showTrackingMessage:(NSString*)message
{
    self.trackingMessageLabel.text = message;
    self.trackingMessageLabel.hidden = NO;
}

- (void)hideTrackingErrorMessage
{
    self.trackingMessageLabel.hidden = YES;
}

- (void)showAppStatusMessage:(NSString *)msg
{
    _appStatus.needsDisplayOfStatusMessage = true;
    [self.view.layer removeAllAnimations];
    
    [self.appStatusMessageLabel setText:msg];
    [self.appStatusMessageLabel setHidden:NO];
    
    // Progressively show the message label.
    [self.view setUserInteractionEnabled:false];
    [UIView animateWithDuration:0.5f animations:^{
        self.appStatusMessageLabel.alpha = 1.0f;
    }completion:nil];
}

- (void)hideAppStatusMessage
{
    if (!_appStatus.needsDisplayOfStatusMessage)
        return;
    
    _appStatus.needsDisplayOfStatusMessage = false;
    [self.view.layer removeAllAnimations];
    
    __weak ViewController *weakSelf = self;
    [UIView animateWithDuration:0.5f
                     animations:^{
                         weakSelf.appStatusMessageLabel.alpha = 0.0f;
                     }
                     completion:^(BOOL finished) {
                         // If nobody called showAppStatusMessage before the end of the animation, do not hide it.
                         if (!_appStatus.needsDisplayOfStatusMessage)
                         {
                             // Could be nil if the self is released before the callback happens.
                             if (weakSelf) {
                                 [weakSelf.appStatusMessageLabel setHidden:YES];
                                 [weakSelf.view setUserInteractionEnabled:true];
                             }
                         }
                     }];
}

-(void)updateAppStatusMessage
{
    // Skip everything if we should not show app status messages (e.g. in viewing state).
    if (_appStatus.statusMessageDisabled)
    {
        [self hideAppStatusMessage];
        return;
    }
    
    // First show sensor issues, if any.
    switch (_appStatus.sensorStatus)
    {
        case AppStatus::SensorStatusOk:
        {
            break;
        }
            
        case AppStatus::SensorStatusNeedsUserToConnect:
        {
            [self showAppStatusMessage:_appStatus.pleaseConnectSensorMessage];
            return;
        }
            
        case AppStatus::SensorStatusNeedsUserToCharge:
        {
            [self showAppStatusMessage:_appStatus.pleaseChargeSensorMessage];
            return;
        }
    }
    
    // Color camera without calibration (e.g. not iPad).
    if (!_appStatus.colorCameraIsCalibrated)
    {
        [self showAppStatusMessage:_appStatus.needCalibratedColorCameraMessage];
        return;
    }
    
    // Color camera permission issues.
    if (!_appStatus.colorCameraIsAuthorized)
    {
        [self showAppStatusMessage:_appStatus.needColorCameraAccessMessage];
        return;
    }
    
    // Finally background processing feedback.
    switch (_appStatus.backgroundProcessingStatus)
    {
        case AppStatus::BackgroundProcessingStatusIdle:
        {
            break;
        }
            
        case AppStatus::BackgroundProcessingStatusFinalizing:
        {
            [self showAppStatusMessage:_appStatus.finalizingMeshMessage];
            return;
        }
    }
    
    // If we reach this point, no status to show.
    [self hideAppStatusMessage];
}

#pragma mark - UI Callbacks

// Manages whether we can let the application sleep.
-(void)updateIdleTimer
{
    if ([self isStructureConnectedAndCharged] && [self currentStateNeedsSensor])
    {
        // Do not let the application sleep if we are currently using the sensor data.
        [[UIApplication sharedApplication] setIdleTimerDisabled:YES];
    }
    else
    {
        // Let the application sleep if we are only viewing the mesh or if no sensors are connected.
        [[UIApplication sharedApplication] setIdleTimerDisabled:NO];
    }
}

- (IBAction)roomSizeSliderValueChanged:(id)sender
{
    float scale = self.roomSizeSlider.value;
    
    GLKVector3 newVolumeSize = GLKVector3MultiplyScalar(_options.initialVolumeSizeInMeters, scale);
    newVolumeSize.y = std::max (newVolumeSize.y, _options.minVerticalVolumeSize);
    
    // Helper function.
    auto keepInRange = [](float value, float minValue, float maxValue)
    {
        if (value > maxValue) return maxValue;
        if (value < minValue) return minValue;
        return value;
    };
    
    // Make sure the volume size remains between 3 meters and 10 meters.
    newVolumeSize.x = keepInRange (newVolumeSize.x, 3.f, 10.f);
    newVolumeSize.y = keepInRange (newVolumeSize.y, 3.f, 10.f);
    newVolumeSize.z = keepInRange (newVolumeSize.z, 3.f, 10.f);
    
    [self.roomSizeLabel setText:[NSString stringWithFormat:@"%.1f x %.1f x %.1f meters", newVolumeSize.x, newVolumeSize.y, newVolumeSize.z]];
    
    [self adjustVolumeSize:newVolumeSize];
}

- (IBAction)scanButtonPressed:(id)sender
{
    _colorizedMesh = nil;
    [self enterScanningState];
}

- (IBAction)resetButtonPressed:(id)sender
{
    // Handles simultaneous press of Done & Reset.
    if(self.doneButton.hidden) return;
    
    [self resetSLAM];
    [self enterPoseInitializationState];
}

- (IBAction)doneButtonPressed:(id)sender
{
    // Handles simultaneous press of Done & Reset.
    if(self.doneButton.hidden) return;
    
    [self enterDiminishedState];
}

- (IBAction)roomSizeSliderTouchDown:(id)sender {
    self.roomSizeLabel.hidden = NO;
}

- (IBAction)roomSizeSliderTouchUpInside:(id)sender {
    self.roomSizeLabel.hidden = YES;
}

- (IBAction)roomSizeSliderTouchUpOutside:(id)sender {
    self.roomSizeLabel.hidden = YES;
}

- (IBAction)switch2StateChange:(id)sender {
    if([_switch2 isOn]){
        _switch2Label.text = @"FaceDetection";
    }
    else{
        _switch2Label.text = @"ColorDetection";
    }
}

- (IBAction)switch1StateChange:(id)sender {
    if([_switch1 isOn]){
        _switch1Label.text = @"ObjectDetection";
    }
    else{
        _switch1Label.text = @"ShowMeshOnly";
    }
}

- (IBAction)switch3StateChange:(id)sender {
    if([_switch3 isOn]){
        _imageView1.image = NULL;
    }
    else {
        _imageView2.image = NULL;
    }
}

-(void) setViewImage: (UIImage *) image
{
    if([_switch3 isOn]){
        _imageView2.image = image;
    }
    else{
        _imageView1.image = image;
    }
}



-(bool) isStateDiminish
{
    return dmished;
}

-(bool) switch1State
{
    return [_switch1 isOn];
}

-(bool) switch2State
{
    return [_switch2 isOn];
}

#pragma mark - MeshViewController delegates


@end

/*
  This file is part of the Structure SDK.
  Copyright © 2016 Occipital, Inc. All rights reserved.
  http://structure.io
*/

#import "ViewController.h"

@interface ViewController (Sensor) <STSensorControllerDelegate>

- (void)setupStructureSensor;
- (BOOL)isStructureConnectedAndCharged;
- (STSensorControllerInitStatus)connectToStructureAndStartStreaming;

@end

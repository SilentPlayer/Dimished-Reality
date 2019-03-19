//
//  ColorDetection.h
//  DiminishedRoom
//
//  Created by erwin andre on 12.12.18.
//  Copyright © 2018 Occipital. All rights reserved.
//


NS_ASSUME_NONNULL_BEGIN

@interface ObjectDetection : NSObject


-(UIImage *)colorDetection: (UIImage *) img1 secondImg: (UIImage *) img2;
-(UIImage *) imageProcessing;
//cv::Mat alignImage(cv::Mat img_1, cv::Mat img_2);
-(cv::Mat)createMask:(cv::Mat) imgOriginal;
- (cv::Mat)cvMatFromUIImage:(UIImage *)image;
-(UIImage *)UIImageFromCVMat:(cv::Mat)cvMat;
-(UIImage *) faceDetection: (UIImage *) img1 secondImg: (UIImage *) img2;
-(void) initCascade;

@end

NS_ASSUME_NONNULL_END

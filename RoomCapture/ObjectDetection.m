//
//  ColorDetection.m
//  DiminishedRoom
//
//  Created by erwin andre on 12.12.18.
//  Copyright © 2018 Occipital. All rights reserved.
//

#import "ObjectDetection.h"

const int MAX_FEATURES = 500;
const float GOOD_MATCH_PERCENT = 0.2f;
cv::Mat img_1, img_2, mask, faceMask;

cv::CascadeClassifier face_cascade;
cv::String face_cascade_name = "haarcascade_frontalface_alt.xml";

@implementation ObjectDetection

-(void) initCascade
{
    NSString *pathFile = [[NSBundle mainBundle] bundlePath];
    NSString *path = [[NSString alloc] initWithString:[pathFile stringByAppendingPathComponent:@"haarcascade_frontalface_alt.xml"]];
    if( !face_cascade.load( path.UTF8String ) ){ printf("--(!)Error loading\n"); return; };
}

// img1 from camera and img2 from ModelMesh
-(UIImage *)colorDetection: (UIImage *) img1 secondImg: (UIImage *) img2
{
    img_1 = [self cvMatFromUIImage:img1];
    img_2 = [self cvMatFromUIImage:img2];
    //cv::resize(img_1, img_1, cv::Size(), 0.75, 0.75, cv::INTER_NEAREST);
    //cv::resize(img_2, img_2, cv::Size(), 0.75, 0.75, cv::INTER_NEAREST);
    mask = [self createMask:img_1];
    
    if(cv::countNonZero(mask) == 0)
    {
        return NULL;
    }
    else
    {
        return [self imageProcessing];
    }
}

-(UIImage *) imageProcessing
{
    cv::Mat blendedImage, blendedImage2, finalEND;
    UIImage *endImg;
    
    cv::Mat img_2Aligned = alignImage();
    if(img_2Aligned.empty()){
        return NULL;
    }
    //cv::Mat brighter;
    //img_2Aligned.convertTo(brighter, -1, 1.05, 5);
    //brighter.copyTo(blendedImage, mask);
    img_2Aligned.copyTo(blendedImage, mask);
    
    //img_2.copyTo(blendedImage, mask);
    img_1.copyTo(blendedImage2, cv::Scalar::all(1.0)-mask);
    cv::add(blendedImage2, blendedImage, finalEND);
    endImg = [self UIImageFromCVMat:finalEND];
    return endImg;
}

-(UIImage *) faceDetection: (UIImage *) img1 secondImg: (UIImage *) img2
{
    img_1 = [self cvMatFromUIImage:img1];
    // erstes image von camera ist in ycbcr und muss nach rgb konvertiert werden
    
    img_2 = [self cvMatFromUIImage:img2];
    [self createFaceMask:img_1];
    
    
    if(cv::countNonZero(faceMask) == 0)
    {
        return NULL;
    }
    else
    {
        cv::Mat blendedImage, blendedImage2, finalEND;
        UIImage *endImg;
        
        cv::Mat img_2Aligned = alignImage();
        if(img_2Aligned.empty()){
            return NULL;
        }
        img_2Aligned.copyTo(blendedImage, faceMask);
        img_1.copyTo(blendedImage2, cv::Scalar::all(1.0)-faceMask);
        cv::add(blendedImage2, blendedImage, finalEND);
        endImg = [self UIImageFromCVMat:finalEND];
        return endImg;
    }
}

// Quelle: https://www.learnopencv.com/image-alignment-feature-based-using-opencv-c-python/
// img_1 = Frame von VideoKamera, img_2 = Bild von meinem Modell
cv::Mat alignImage()
{
    cv::Mat h, img_2Reg;
    // Convert images to grayscale
    cv::Mat img_1Gray, img_2Gray;
    cv::cvtColor(img_1, img_1Gray, CV_RGB2GRAY);
    cv::cvtColor(img_2, img_2Gray, CV_RGB2GRAY);
    
    // Variables to store keypoints and descriptors
    std::vector<cv::KeyPoint> keypoints1, keypoints2;
    cv::Mat descriptors1, descriptors2;
    
    // Detect ORB features and compute descriptors.
    cv::Ptr<cv::Feature2D> orb = cv::ORB::create(MAX_FEATURES);
    orb->detectAndCompute(img_1Gray, cv::Mat(), keypoints1, descriptors1);
    orb->detectAndCompute(img_2Gray, cv::Mat(), keypoints2, descriptors2);
    
    if(keypoints1.empty() || keypoints2.empty()){
        return img_2Reg;
    }
    
    // Match features.
    std::vector<cv::DMatch> matches;
    cv::BFMatcher matcher(cv::NORM_HAMMING2);
    matcher.match( descriptors1, descriptors2, matches );
    
    // Sort matches by score
    std::sort(matches.begin(), matches.end());
    
    // Remove not so good matches
    const int numGoodMatches = matches.size() * GOOD_MATCH_PERCENT;
    matches.erase(matches.begin()+numGoodMatches, matches.end());
    
    // Extract location of good matches
    std::vector<cv::Point2f> points1, points2;
    
    for( size_t i = 0; i < matches.size(); i++ )
    {
        points1.push_back( keypoints1[ matches[i].queryIdx ].pt );
        points2.push_back( keypoints2[ matches[i].trainIdx ].pt );
    }
    
    if(matches.empty()){
        return img_2Reg;
    }
    // Find homography
    h = findHomography( points2, points1, cv::RANSAC );
    
    if(h.empty()){
        return img_2Reg;
    }
    
    // Use homography to warp image
    warpPerspective(img_2, img_2Reg, h, img_2.size());
    return img_2Reg;
}

-(void)createFaceMask:(cv::Mat) frame
{
    std::vector<cv::Rect> faces;
    cv::Mat frame_gray;
    
    cv::cvtColor( frame, frame_gray, CV_RGB2GRAY );
    //cv::equalizeHist( frame_gray, frame_gray );
    faceMask = cv::Mat::zeros(frame_gray.size(), frame_gray.type());
    
    
    //-- Detect faces
    face_cascade.detectMultiScale( frame_gray, faces, 1.1, 2, 0|CV_HAAR_SCALE_IMAGE, cv::Size(30,30) );
    
    
    for( size_t i = 0; i < faces.size(); i++ )
    {
        cv::Point center( faces[i].x + faces[i].width*0.5, faces[i].y + faces[i].height*0.5 );
        int rad = cvRound( (faces[i].width + faces[i].height)*0.45 );
        cv::circle( faceMask, center, rad, cv::Scalar( 255, 0, 0 ), -1, 8, 0 );
    }
}

// Quelle: https://www.opencv-srf.com/2010/09/object-detection-using-color-seperation.html
-(cv::Mat)createMask:(cv::Mat) imgOriginal
{
    NSDate *start4 = [NSDate date];
    cv::Mat imgHSV, imgThresholded;
    cv::cvtColor(imgOriginal, imgHSV, cv::COLOR_RGB2HSV);
    cv::resize(imgHSV, imgHSV, cv::Size(), 0.5, 0.5, cv::INTER_NEAREST);

    cv::inRange(imgHSV, cv::Scalar(39, 112, 80), cv::Scalar(79, 245, 245), imgThresholded);
    //cv::inRange(imgHSV, cv::Scalar(_slider1.value, _slider2.value, _slider3.value), cv::Scalar(_slider4.value, _slider5.value, _slider6.value), imgThresholded);
    
    //morphological opening (remove small objects from the foreground)
    cv::erode(imgThresholded, imgThresholded, getStructuringElement(cv::MORPH_ELLIPSE, cv::Size(5, 5)) );
    cv::dilate( imgThresholded, imgThresholded, getStructuringElement(cv::MORPH_ELLIPSE, cv::Size(5, 5)) );
    
    //morphological closing (fill small holes in the foreground)
    cv::dilate(imgThresholded, imgThresholded, cv::getStructuringElement(cv::MORPH_ELLIPSE, cv::Size(5, 5)) );
    cv::erode(imgThresholded, imgThresholded, cv::getStructuringElement(cv::MORPH_ELLIPSE, cv::Size(5, 5)) );
    
    cv::dilate(imgThresholded, imgThresholded, cv::getStructuringElement(cv::MORPH_ELLIPSE, cv::Size(5, 5)) );
    cv::resize(imgThresholded, imgThresholded, cv::Size(), 2, 2, cv::INTER_NEAREST);
    
    NSDate *end4 = [NSDate date];
    NSTimeInterval executionTime4 = [end4 timeIntervalSinceDate:start4];
    NSLog(@"color mask exec Time: %f", executionTime4);
    return imgThresholded;
}

// Quelle: https://docs.opencv.org/master/d3/def/tutorial_image_manipulation.html
- (cv::Mat)cvMatFromUIImage:(UIImage *)image
{
    CGColorSpaceRef colorSpace = CGImageGetColorSpace(image.CGImage);
    CGFloat cols = image.size.width;
    CGFloat rows = image.size.height;
    cv::Mat cvMat(rows, cols, CV_8UC4); // 8 bits per component, 4 channels (color channels + alpha)
    CGContextRef contextRef = CGBitmapContextCreate(cvMat.data,                 // Pointer to  data
                                                    cols,                       // Width of bitmap
                                                    rows,                       // Height of bitmap
                                                    8,                          // Bits per component
                                                    cvMat.step[0],              // Bytes per row
                                                    colorSpace,                 // Colorspace
                                                    kCGImageAlphaNoneSkipLast |
                                                    kCGBitmapByteOrderDefault); // Bitmap info flags
    CGContextDrawImage(contextRef, CGRectMake(0, 0, cols, rows), image.CGImage);
    CGContextRelease(contextRef);
    return cvMat;
}

// Quelle: https://docs.opencv.org/master/d3/def/tutorial_image_manipulation.html
-(UIImage *)UIImageFromCVMat:(cv::Mat)cvMat
{
    NSData *data = [NSData dataWithBytes:cvMat.data length:cvMat.elemSize()*cvMat.total()];
    CGColorSpaceRef colorSpace;
    if (cvMat.elemSize() == 1) {
        colorSpace = CGColorSpaceCreateDeviceGray();
    } else {
        colorSpace = CGColorSpaceCreateDeviceRGB();
    }
    CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)data);
    // Creating CGImage from cv::Mat
    CGImageRef imageRef = CGImageCreate(cvMat.cols,                                 //width
                                        cvMat.rows,                                 //height
                                        8,                                          //bits per component
                                        8 * cvMat.elemSize(),                       //bits per pixel
                                        cvMat.step[0],                            //bytesPerRow
                                        colorSpace,                                 //colorspace
                                        kCGImageAlphaNone|kCGBitmapByteOrderDefault,// bitmap info
                                        provider,                                   //CGDataProviderRef
                                        NULL,                                       //decode
                                        false,                                      //should interpolate
                                        kCGRenderingIntentDefault                   //intent
                                        );
    // Getting UIImage from CGImage
    UIImage *finalImage = [UIImage imageWithCGImage:imageRef];
    CGImageRelease(imageRef);
    CGDataProviderRelease(provider);
    CGColorSpaceRelease(colorSpace);
    return finalImage;
}


@end

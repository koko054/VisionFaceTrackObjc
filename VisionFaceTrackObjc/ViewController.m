//
//  ViewController.m
//  VisionFaceTrackObjc
//
//  Created by 김도범 on 18/03/2019.
//  Copyright © 2019 Noah. All rights reserved.
//

#import "ViewController.h"
#import <AVKit/AVKit.h>
#import <Vision/Vision.h>

typedef struct InputDevice {
  AVCaptureDevice *device;
  CGSize resolution;
} InputDevice;

@interface ViewController ()<AVCaptureVideoDataOutputSampleBufferDelegate>

@property(nonatomic, strong) UIView *previewView;

@property(nonatomic, strong) AVCaptureSession *session;
@property(nonatomic, strong) AVCaptureVideoPreviewLayer *previewLayer;

@property(nonatomic, strong) AVCaptureVideoDataOutput *videoDataOutput;
@property(nonatomic, assign) dispatch_queue_t videoDataOutputQueue;

@property(nonatomic, strong) AVCaptureDevice *captureDevice;
@property(nonatomic, assign) CGSize captureDeviceResolution;

@property(nonatomic, strong) CALayer *rootLayer;
@property(nonatomic, strong) CALayer *detectionOverlayLayer;
@property(nonatomic, strong) CAShapeLayer *detectedFaceRectangleShapeLayer;
@property(nonatomic, strong) CAShapeLayer *detectedFaceLandmarksShapeLayer;

@property(nonatomic, strong) NSArray<VNDetectFaceRectanglesRequest *> *detectionRequests;
@property(nonatomic, strong) NSMutableArray<VNTrackObjectRequest *> *trackingRequests;

@property(nonatomic, strong) VNSequenceRequestHandler *sequenceRequestHandler;

@end

@implementation ViewController

- (void)viewDidLoad {
  [super viewDidLoad];
  
  [self.view addSubview:self.previewView];

  // 캡쳐세션을 생성한다.
  self.session = [self setupAVCaptureSession];
  
  // 비전리퀘스트를 준비
  [self prepareVisionRequest];
  
  // 세션 생성이 성공한 경우 세션을 시작한다.
  if (self.session) {
    [self.session startRunning];
  }
}

- (UIView *)previewView {
  if (!_previewView) {
    _previewView = [[UIView alloc] initWithFrame:self.view.bounds];
  }
  return _previewView;
}

- (void)didReceiveMemoryWarning {
  [super didReceiveMemoryWarning];
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
  return UIInterfaceOrientationMaskPortrait;
}

- (UIInterfaceOrientation)preferredInterfaceOrientationForPresentation {
  return UIInterfaceOrientationPortrait;
}

- (VNSequenceRequestHandler *)sequenceRequestHandler {
  if (!_sequenceRequestHandler) {
    _sequenceRequestHandler = [[VNSequenceRequestHandler alloc] init];
  }
  return _sequenceRequestHandler;
}

- (AVCaptureSession *)setupAVCaptureSession {
  // 캡쳐세션 생성
  AVCaptureSession *captureSession = [[AVCaptureSession alloc] init];
  CGSize resolution;
  
  // 전면카메라디바이스 생성 및 캡쳐세션에 입력연결, 해당 전면카메라디바이스의 해상도를 가져온다.
  AVCaptureDevice *inputDevice = [self configureFrontCamera:captureSession getResolution:&resolution];
  
  // 비디오출력을 세션에 연결하고 생성된 카메라디바이스와 해상도 정보를 설정한다.
  [self configureVideoDataOutput:inputDevice resolution:resolution captureSession:captureSession];
  
  // 카메라화면 설정
  [self designatePreviewLayer:captureSession];
  
  // 캡쳐세션 생성에 실패했거나 카메라 입력 해상도가 0.0 인경우 실패로 간주한다.
  if (!captureSession || resolution.width <= 0.0 || resolution.height <= 0.0) {
    [self teardownAVCapture];
    return nil;
  }
  
  return captureSession;
}

- (AVCaptureDevice *)configureFrontCamera:(AVCaptureSession *)captureSession getResolution:(CGSize *)resolution {
  AVCaptureDeviceDiscoverySession *deviceDiscoverySession =
      [AVCaptureDeviceDiscoverySession discoverySessionWithDeviceTypes:@[ AVCaptureDeviceTypeBuiltInWideAngleCamera ]
                                                             mediaType:AVMediaTypeVideo
                                                              position:AVCaptureDevicePositionFront];
  AVCaptureDevice *device = deviceDiscoverySession.devices.firstObject;
  AVCaptureDeviceInput *deviceInput = [AVCaptureDeviceInput deviceInputWithDevice:device error:nil];
  if ([captureSession canAddInput:deviceInput]) {
    [captureSession addInput:deviceInput];
  }
  AVCaptureDeviceFormat *highestResolution = [self highestResolution420Format:device getResolution:resolution];
  if ([device lockForConfiguration:nil]) {
    device.activeFormat = highestResolution;
    [device unlockForConfiguration];
  }
  return device;
}

- (AVCaptureDeviceFormat *)highestResolution420Format:(AVCaptureDevice *)device getResolution:(CGSize *)resolution {
  __block AVCaptureDeviceFormat *highestResolutionFormat = nil;
  __block CMVideoDimensions highestResolutionDimensions;
  [device.formats
      enumerateObjectsUsingBlock:^(AVCaptureDeviceFormat *_Nonnull deviceFormat, NSUInteger idx, BOOL *_Nonnull stop) {
        if (CMFormatDescriptionGetMediaSubType(deviceFormat.formatDescription) ==
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) {
          CMVideoDimensions candidateDimension = CMVideoFormatDescriptionGetDimensions(deviceFormat.formatDescription);
          if (highestResolutionFormat == nil || candidateDimension.width > highestResolutionDimensions.width) {
            highestResolutionFormat = deviceFormat;
            highestResolutionDimensions = candidateDimension;
          }
        }
      }];

  if (highestResolutionFormat != nil) {
    *resolution = CGSizeMake((CGFloat)highestResolutionDimensions.width, (CGFloat)highestResolutionDimensions.height);
    return highestResolutionFormat;
  }
  return nil;
}

- (void)configureVideoDataOutput:(AVCaptureDevice *)inputDevice
                      resolution:(CGSize)resolution
                  captureSession:(AVCaptureSession *)captureSession {
  
  // 비디오출력 생성
  AVCaptureVideoDataOutput *videoDataOutput = [[AVCaptureVideoDataOutput alloc] init];
  // 기존 프레임을 처리하는 동안 다음 프레임을 처리하지 못하는 경우 다음 프레임을 사용하지않도록 설정
  // (결국 프레임 처리가 완료될때까지 그 다음 프레임들을 사용하지 않는다.)
  videoDataOutput.alwaysDiscardsLateVideoFrames = YES;

  // 비디오출력 처리 큐를 생성
  dispatch_queue_t videoDataOutputQueue = dispatch_queue_create("com.example.jp-brothers.VisionFaceTrack", nil);
  // 비디오출력에서 나오는 프레임을 받아올 딜리게이트와 비디오출력을 처리할 큐를 설정한다.
  [videoDataOutput setSampleBufferDelegate:self queue:videoDataOutputQueue];

  // 캡쳐세션에 생성된 비디오출력을 연결한다.
  if ([captureSession canAddOutput:videoDataOutput]) {
    [captureSession addOutput:videoDataOutput];
  }

  // 비디오연결에서 cameraIntrinsicMatrixDeliveryEnabled 이 사용가능한 경우 활성화
  AVCaptureConnection *captureConnection = [videoDataOutput connectionWithMediaType:AVMediaTypeVideo];
  if (captureConnection && captureConnection.isEnabled) {
    if (captureConnection.isCameraIntrinsicMatrixDeliverySupported) {
      captureConnection.cameraIntrinsicMatrixDeliveryEnabled = YES;
    }
  }

  self.videoDataOutput = videoDataOutput;
  self.videoDataOutputQueue = videoDataOutputQueue;
  self.captureDevice = inputDevice;
  self.captureDeviceResolution = resolution;
}

- (void)designatePreviewLayer:(AVCaptureSession *)captureSession {
  // 캡쳐세션의 화면 출력용 레이어를 생성한다.
  AVCaptureVideoPreviewLayer *videoPreviewLayer = [AVCaptureVideoPreviewLayer layerWithSession:captureSession];
  self.previewLayer = videoPreviewLayer;

  videoPreviewLayer.name = @"CameraPreview";
  videoPreviewLayer.backgroundColor = UIColor.blackColor.CGColor;
  videoPreviewLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;

  // 위에서 생성돈 출력용 레이어를 UI 뷰의 레이어의 하위레이어로 추가한다.
  CALayer *previewRootLayer = self.previewView.layer;
  if (previewRootLayer) {
    self.rootLayer = previewRootLayer;
    previewRootLayer.masksToBounds = YES;
    videoPreviewLayer.frame = previewRootLayer.bounds;
    [previewRootLayer addSublayer:videoPreviewLayer];
  }
}

- (void)teardownAVCapture {
  self.videoDataOutput = nil;
  self.videoDataOutputQueue = nil;

  [self.previewLayer removeFromSuperlayer];
  self.previewLayer = nil;
}

- (CGFloat)radianForDegrees:(CGFloat)degrees {
  return degrees * M_PI / 180.0;
}

- (CGImagePropertyOrientation)exifOrientationForDeviceOrientation:(UIDeviceOrientation)deviceOrientation {
  switch (deviceOrientation) {
    case UIDeviceOrientationPortraitUpsideDown:
      return kCGImagePropertyOrientationRightMirrored;
      break;
    case UIDeviceOrientationLandscapeLeft:
      return kCGImagePropertyOrientationDownMirrored;
      break;
    case UIDeviceOrientationLandscapeRight:
      return kCGImagePropertyOrientationUpMirrored;
      break;
    default:
      return kCGImagePropertyOrientationLeftMirrored;
      break;
  }
}

- (CGImagePropertyOrientation)exifOrientationForCurrentDeviceOrientation {
  return [self exifOrientationForDeviceOrientation:UIDevice.currentDevice.orientation];
}

- (void)prepareVisionRequest {
  // 얼굴트래킹리퀘스트를 저장할 배열 생성
  NSMutableArray<VNTrackObjectRequest *> *requests = [NSMutableArray array];
  
  // 얼굴인식 리퀘스트생성
  VNDetectFaceRectanglesRequest *faceDetectionRequest = [[VNDetectFaceRectanglesRequest alloc]
      initWithCompletionHandler:^(VNRequest *_Nonnull request, NSError *_Nullable error) {
        // 최초로 얼굴인식이 완료된 경우 호출되는 코드블럭
        if (error) {
          NSLog(@"FaceDetection error : %@", error.description);
        }

        // 반환된 request객체가 VNDetectFaceRectanglesRequest 객체인경우 해당 결과값을 가져온다.
        NSArray<VNFaceObservation *> *results;
        if ([request isKindOfClass:[VNDetectFaceRectanglesRequest class]]) {
          results = ((VNDetectFaceRectanglesRequest *)request).results;
        } else {
          return;
        }

        dispatch_async(dispatch_get_main_queue(), ^{
          // 가져온 결과값에서 얼굴트랙킹리퀘스트를 생성하여 저장한다.
          [results enumerateObjectsUsingBlock:^(VNFaceObservation *_Nonnull obj, NSUInteger idx, BOOL *_Nonnull stop) {
            VNTrackObjectRequest *faceTrackingRequest =
                [[VNTrackObjectRequest alloc] initWithDetectedObjectObservation:obj];
            [requests addObject:faceTrackingRequest];
          }];
          self.trackingRequests = requests;
        });
      }];

  // 위에서 생성된 얼굴인식리퀘스트를 배열로 저장한다.
  self.detectionRequests = @[ faceDetectionRequest ];
  
  // 시퀜스리퀘스트핸들러를 생성
  [self sequenceRequestHandler];
  
  // 얼굴인식&트랙킹 레이어설정
  [self setupVisionDrawingLayers];
}

- (void)setupVisionDrawingLayers {
  CGSize captureDeviceResolution = self.captureDeviceResolution;
  CGRect captureDeviceBounds = CGRectMake(0.0, 0.0, captureDeviceResolution.width, captureDeviceResolution.height);
  CGPoint captureDeviceBoundsCenterPoint =
      CGPointMake(CGRectGetMidX(captureDeviceBounds), CGRectGetMidY(captureDeviceBounds));

  CALayer *rootLayer = self.rootLayer;
  if (!rootLayer) {
    NSLog(@"view was not peroperty initialized");
    return;
  }

  CALayer *overlayLayer = [CALayer layer];
  overlayLayer.name = @"DetectionOverlay";
  overlayLayer.masksToBounds = YES;
  overlayLayer.bounds = captureDeviceBounds;
  overlayLayer.position = CGPointMake(CGRectGetMidX(rootLayer.bounds), CGRectGetMidY(rootLayer.bounds));

  CAShapeLayer *faceRectangleShapeLayer = [CAShapeLayer layer];
  faceRectangleShapeLayer.name = @"RectangleOutlineLayer";
  faceRectangleShapeLayer.bounds = captureDeviceBounds;
  faceRectangleShapeLayer.position = captureDeviceBoundsCenterPoint;
  faceRectangleShapeLayer.fillColor = nil;
  faceRectangleShapeLayer.strokeColor = [UIColor colorWithRed:0.0 green:1.0 blue:0.0 alpha:0.7].CGColor;
  faceRectangleShapeLayer.lineWidth = 5;
  faceRectangleShapeLayer.shadowOpacity = 0.7;
  faceRectangleShapeLayer.shadowRadius = 5;

  CAShapeLayer *faceLandmarksShapeLayer = [CAShapeLayer layer];
  faceLandmarksShapeLayer.name = @"FaceLandmarksLayer";
  faceLandmarksShapeLayer.bounds = captureDeviceBounds;
  faceLandmarksShapeLayer.position = captureDeviceBoundsCenterPoint;
  faceLandmarksShapeLayer.fillColor = nil;
  faceLandmarksShapeLayer.strokeColor = [UIColor colorWithRed:0.0 green:1.0 blue:1.0 alpha:0.7].CGColor;
  faceLandmarksShapeLayer.lineWidth = 3;
  faceLandmarksShapeLayer.shadowOpacity = 0.7;
  faceLandmarksShapeLayer.shadowRadius = 5;

  [overlayLayer addSublayer:faceRectangleShapeLayer];
  [faceRectangleShapeLayer addSublayer:faceLandmarksShapeLayer];
  [rootLayer addSublayer:overlayLayer];

  self.detectionOverlayLayer = overlayLayer;
  self.detectedFaceRectangleShapeLayer = faceRectangleShapeLayer;
  self.detectedFaceLandmarksShapeLayer = faceLandmarksShapeLayer;

  [self updateLayerGeometry];
}

- (void)updateLayerGeometry {
  CALayer *overlayLayer = self.detectionOverlayLayer;
  CALayer *rootLayer = self.rootLayer;
  AVCaptureVideoPreviewLayer *previewLayer = self.previewLayer;

  if (!overlayLayer || !rootLayer || !previewLayer) {
    return;
  }

  [CATransaction setValue:@(YES) forKey:kCATransactionDisableActions];

  CGRect videoPreviewRect = [previewLayer rectForMetadataOutputRectOfInterest:CGRectMake(0.0, 0.0, 1.0, 1.0)];
  CGFloat rotation;
  CGFloat scaleX;
  CGFloat scaleY;

  switch (UIDevice.currentDevice.orientation) {
    case UIDeviceOrientationPortraitUpsideDown:
      rotation = 180.0;
      scaleX = videoPreviewRect.size.width / self.captureDeviceResolution.width;
      scaleY = videoPreviewRect.size.height / self.captureDeviceResolution.height;
      break;
    case UIDeviceOrientationLandscapeLeft:
      rotation = 90.0;
      scaleX = videoPreviewRect.size.height / self.captureDeviceResolution.width;
      scaleY = scaleX;
      break;
    case UIDeviceOrientationLandscapeRight:
      rotation = -90.0;
      scaleX = videoPreviewRect.size.height / self.captureDeviceResolution.width;
      scaleY = scaleX;
    default:
      rotation = 0.0;
      scaleX = videoPreviewRect.size.width / self.captureDeviceResolution.width;
      scaleY = videoPreviewRect.size.height / self.captureDeviceResolution.height;
      break;
  }

  CGAffineTransform affineTransform = CGAffineTransformMakeRotation([self radianForDegrees:rotation]);
  affineTransform = CGAffineTransformScale(affineTransform, scaleX, -scaleY);
  overlayLayer.affineTransform = affineTransform;

  CGRect rootLayerBounds = rootLayer.bounds;
  overlayLayer.position = CGPointMake(CGRectGetMidX(rootLayerBounds), CGRectGetMidY(rootLayerBounds));
}

- (void)addPoints:(VNFaceLandmarkRegion2D *)landmarkRegion
               path:(CGMutablePathRef)path
    affineTransform:(CGAffineTransform)affineTransform
          closePath:(BOOL)closePath {
  NSUInteger pointCount = landmarkRegion.pointCount;
  if (pointCount > 1) {
    CGPoint *points = (CGPoint *)landmarkRegion.normalizedPoints;
    CGPathMoveToPoint(path, &affineTransform, points[0].x, points[0].y);
    CGPathAddLines(path, &affineTransform, points, pointCount);
    if (closePath) {
      CGPathAddLineToPoint(path, &affineTransform, points[0].x, points[0].y);
      CGPathCloseSubpath(path);
    }
  }
}

- (void)addIndicators:(CGMutablePathRef)faceRectanglePath
     faceLandmarkPath:(CGMutablePathRef)faceLandmarkPath
      faceObservation:(VNFaceObservation *)faceObservation {
  CGSize displaySize = self.captureDeviceResolution;
  CGRect faceBounds = VNImageRectForNormalizedRect(faceObservation.boundingBox, (NSInteger)displaySize.width, (NSInteger)displaySize.height);
  CGPathAddRect(faceRectanglePath, nil, faceBounds);

  VNFaceLandmarks2D *landmarks = faceObservation.landmarks;
  if (landmarks) {
    CGAffineTransform affineTransform = CGAffineTransformMakeTranslation(faceBounds.origin.x, faceBounds.origin.y);
    affineTransform = CGAffineTransformScale(affineTransform, faceBounds.size.width, faceBounds.size.height);

    NSMutableArray<VNFaceLandmarkRegion2D *> *openLandmarkRegions = [NSMutableArray array];
    if (landmarks.leftEyebrow) {
      [openLandmarkRegions addObject:landmarks.leftEyebrow];
    }
    if (landmarks.rightEyebrow) {
      [openLandmarkRegions addObject:landmarks.rightEyebrow];
    }
    if (landmarks.faceContour) {
      [openLandmarkRegions addObject:landmarks.faceContour];
    }
    if (landmarks.noseCrest) {
      [openLandmarkRegions addObject:landmarks.noseCrest];
    }
    if (landmarks.medianLine) {
      [openLandmarkRegions addObject:landmarks.medianLine];
    }
    
    [openLandmarkRegions
        enumerateObjectsUsingBlock:^(VNFaceLandmarkRegion2D *_Nonnull obj, NSUInteger idx, BOOL *_Nonnull stop) {
          [self addPoints:obj path:faceLandmarkPath affineTransform:affineTransform closePath:NO];
        }];

    NSMutableArray<VNFaceLandmarkRegion2D *> *closeLandmarkRegions = [NSMutableArray array];
    if (landmarks.leftEye) {
      [closeLandmarkRegions addObject:landmarks.leftEye];
    }
    if (landmarks.rightEye) {
      [closeLandmarkRegions addObject:landmarks.rightEye];
    }
    if (landmarks.outerLips) {
      [closeLandmarkRegions addObject:landmarks.outerLips];
    }
    if (landmarks.innerLips) {
      [closeLandmarkRegions addObject:landmarks.innerLips];
    }
    if (landmarks.nose) {
      [closeLandmarkRegions addObject:landmarks.nose];
    }
    
    [closeLandmarkRegions
        enumerateObjectsUsingBlock:^(VNFaceLandmarkRegion2D *_Nonnull obj, NSUInteger idx, BOOL *_Nonnull stop) {
          [self addPoints:obj path:faceLandmarkPath affineTransform:affineTransform closePath:YES];
        }];
  }
}

- (void)drawFaceObservations:(NSArray<VNFaceObservation *> *)faceObservations {
  CAShapeLayer *faceRectangleShapeLayer = self.detectedFaceRectangleShapeLayer;
  CAShapeLayer *faceLandmarksShapeLayer = self.detectedFaceLandmarksShapeLayer;
  if (!faceRectangleShapeLayer || !faceLandmarksShapeLayer) {
    return;
  }
  
  [CATransaction begin];
  [CATransaction setValue:@(YES) forKey:kCATransactionDisableActions];
  
  CGMutablePathRef faceRectanglePath = CGPathCreateMutable();
  CGMutablePathRef faceLandmarksPath = CGPathCreateMutable();
  
  [faceObservations enumerateObjectsUsingBlock:^(VNFaceObservation * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
    [self addIndicators:faceRectanglePath faceLandmarkPath:faceLandmarksPath faceObservation:obj];
  }];
  
  faceRectangleShapeLayer.path = faceRectanglePath;
  faceLandmarksShapeLayer.path = faceLandmarksPath;
  
  [self updateLayerGeometry];
  [CATransaction commit];
}

- (void)captureOutput:(AVCaptureOutput *)output
    didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
           fromConnection:(AVCaptureConnection *)connection {
  NSError *error;
  // sampleBuffer에서 intrinsic data 를 가져온다.
  // AVCaptureConnection의 cameraIntrinsicMatrixDeliveryEnabled 활성화된 경우 sampleBuffer에 추가되어 나온다.
  NSMutableDictionary<VNImageOption,id> *requestHandlerOptions = [NSMutableDictionary dictionary];
  id cameraIntrinsicData = CMGetAttachment(sampleBuffer, kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix, nil);
  if (cameraIntrinsicData != nil) { // 데이터가 있는 경우에만 설정
    [requestHandlerOptions setObject:cameraIntrinsicData forKey:VNImageOptionCameraIntrinsics];
  }
  
  // CMSampleBuffer에서 픽셀버퍼형식으로 가져온다.
  CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
  if (pixelBuffer == nil) {
    NSLog(@"Failed to obtain a CVPixelBuffer for the current output frame.");
    return;
  }
  
  // 현재 디바이스방향에 따라 이미지방향을 결정한다.
  CGImagePropertyOrientation exifOrientation = [self exifOrientationForCurrentDeviceOrientation];
  
  // 얼굴트래킹리퀘스트 정보를 가져온다.
  NSArray<VNTrackObjectRequest *> *requests = self.trackingRequests;
  
  // 얼굴트래킹리퀘스트가 없는 경우
  if (requests.count == 0) {
    // 이미지리퀘스트핸들러를 생성한다.
    VNImageRequestHandler *imageRequestHandler =
        [[VNImageRequestHandler alloc] initWithCVPixelBuffer:pixelBuffer
                                                 orientation:exifOrientation
                                                     options:requestHandlerOptions];
    
    // viewDidLoad에서 비전리퀘스트를 준비하며 생성된 얼굴인식리퀘스트를 가져온다.
    NSArray *detectRequests = self.detectionRequests;
    if (!detectRequests || detectRequests.count == 0) {
      return;
    }
    
    // 이미지리퀘스트핸들러로 얼굴인식리퀘스트를 수행한다.
    // 얼굴이 인식되면 얼굴인식리퀘스트를 생성시 입력한 인굴인식 완료 코드블럭이 실행되며
    // 해상 코드블럭은 얼굴트래킹리퀘스트를 생성하여 저장한다.
    [imageRequestHandler performRequests:detectRequests error:&error];
    if (error) {
      NSLog(@"Failed to perform FaceRectangleRequest : %@",error);
    }
    return;
  }
  
  // 얼굴트래킹리퀘스트가 있는 경우
  // 얼굴트래킹리퀘스트를 시퀸스핸들러에서 실행하여 인식된 얼굴을 추적한다.
  [self.sequenceRequestHandler performRequests:requests onCVPixelBuffer:pixelBuffer orientation:exifOrientation error:&error];
  if (error) {
    NSLog(@"Failed to perform SequenceRequest : %@",error);
  }
  
  // 새로운 트래킹리퀘스트를 저장할 배열생성
  NSMutableArray<VNTrackObjectRequest *> *newTrackingRequests = [NSMutableArray array];
  
  for (VNTrackObjectRequest *trackingRequest in requests) {
    // 트래킹한 리퀘스트 결과를 가져오기
    NSArray *results = trackingRequest.results;
    
    // 결과가 없거나 결과내용이 VNDetectedObjectObservation가 아닌경우 종료
    if (!results) {
      return;
    }
    if (![results.firstObject isKindOfClass:[VNDetectedObjectObservation class]]) {
      return;
    }
    
    VNDetectedObjectObservation *observation = results.firstObject;
    // 마지막프레임의 트래킹리퀘스트가 아닌경우
    if (!trackingRequest.isLastFrame) {
      if (observation.confidence > 0.3) { // confidence가 0.3이상만 설정
        trackingRequest.inputObservation = observation;
      } else { // 아니면 마지막 프레임이라고 표시
        trackingRequest.lastFrame = YES;
      }
      // 새 트래킹리퀘스트 배열에 추가
      [newTrackingRequests addObject:trackingRequest];
    }
  }
  
  // 트래킹리퀘스트정보 새로 설정
  self.trackingRequests = newTrackingRequests;
  
  // 새로 설정된 트래킹리퀘스트정보가 없는 경우 종료
  if (newTrackingRequests.count == 0) {
    return;
  }

  // 얼굴랜드마크리퀘스트 배열생성
  NSMutableArray<VNDetectFaceLandmarksRequest *> *faceLandmarkRequests = [NSMutableArray array];
  
  for (VNTrackObjectRequest *trackingRequest in newTrackingRequests) {
    // 얼굴 랜드마크 리퀘스트생성, 랜드마크가 인식되면 호출될 코드블럭 구현
    VNDetectFaceLandmarksRequest *faceLandmarkReqeust = [[VNDetectFaceLandmarksRequest alloc]
        initWithCompletionHandler:^(VNRequest *_Nonnull request, NSError *_Nullable error){
          if (error) {
            NSLog(@"FaceLandmarks error : %@",error);
          }
          
          if (![request isKindOfClass:[VNDetectFaceLandmarksRequest class]]) {
            return;
          }
          NSArray *results = ((VNDetectFaceLandmarksRequest *)request).results;
          dispatch_async(dispatch_get_main_queue(), ^{
            // 얼굴 랜드마크 리퀘스트가 완료되어 랜드마크가 인식되었다면 그려준다.
            [self drawFaceObservations:results];
          });
        }];
    
    NSArray *trackingResults = trackingRequest.results;
    if (!trackingResults || trackingResults.count == 0) {
      return;
    }
    
    if (![trackingResults.firstObject isKindOfClass:[VNDetectedObjectObservation class]]) {
      return;
    }
    
    // 얼굴 랜드마크 리퀘스트에 얼굴영역을 알려주는 객체를 설정
    VNDetectedObjectObservation *observation = trackingResults.firstObject;
    VNFaceObservation *faceObservation = [VNFaceObservation observationWithBoundingBox:observation.boundingBox];
    faceLandmarkReqeust.inputFaceObservations = @[faceObservation];
    
    // 얼굴 랜드마크 리퀘스트 저장
    [faceLandmarkRequests addObject:faceLandmarkReqeust];
    
    // 이미지리퀘스트핸들러를 생성한다.
    VNImageRequestHandler *imageRequesthandler =
    [[VNImageRequestHandler alloc] initWithCVPixelBuffer:pixelBuffer
                                             orientation:exifOrientation
                                                 options:requestHandlerOptions];
    
    // 이미지리퀘스트핸들러가 얼굴 랜드마크 리퀘스트들을 처리한다.
    // 처리가 완료되어 랜드마크인식이 되면 리퀘스트 생성시 구현한 코드블럭이 실행된다.
    [imageRequesthandler performRequests:faceLandmarkRequests error:&error];
    if (error) {
      NSLog(@"Failed to perform FaceLandmarkRequest : %@",error);
    }
  }
}

@end

#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <substrate.h>
#import "MediaManager.h"

#pragma mark 悬浮穿透窗口 前置定义解决类型未识别报错
@interface VCamOverlayWindow : UIWindow
@property (nonatomic, assign) BOOL isShowingAlert;
@end
@implementation VCamOverlayWindow
- (BOOL)isPointHitButtonArea:(CGPoint)point {
    if (!self.rootViewController) return NO;
    UIView *rootV = self.rootViewController.view;
    for (UIView *sub in rootV.subviews) {
        CGRect winRect = [sub convertRect:sub.bounds toView:self];
        if (CGRectContainsPoint(winRect, point)) return YES;
    }
    return NO;
}
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (self.isShowingAlert) return [super hitTest:point withEvent:event];
    if (![self isPointHitButtonArea:point]) return nil;
    return [super hitTest:point withEvent:event];
}
@end

@interface VCamRootView : UIView
@end
@implementation VCamRootView
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    for (UIView *sub in self.subviews) {
        CGPoint innerP = [self convertPoint:point toView:sub];
        if ([sub pointInside:innerP withEvent:event]) return sub;
    }
    return nil;
}
@end

@interface VCamFloatButton : UIButton
@property (nonatomic, assign) CGPoint initialCenter;
@end
@implementation VCamFloatButton
@end

#pragma mark 全局变量
static NSMutableArray* g_allVideoDelegates = nil;
static BOOL g_vcamEnabled = NO;
static VCamOverlayWindow *g_overlayWindow = nil;
static UIButton *g_floatButton = nil;
static AVPlayerLayer *g_maskPlayerLayer = nil;
static AVPlayer *g_maskPlayer = nil;
static NSURL *g_selectedVideoUrl = nil;

static void setupFloatButton(void);
static void handlePanGesture(UIPanGestureRecognizer *gesture);
static void handleTapGesture(UITapGestureRecognizer *gesture);
static void createFullScreenMask(NSURL *videoUrl);
static void destroyMask();

#pragma mark 兼容iOS13+ 获取前台活跃窗口（废弃keyWindow替代方案）
static UIWindow *getActiveKeyWindow(void) {
    UIWindow *targetWin = nil;
    for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (scene.activationState == UISceneActivationStateForegroundActive) {
            for (UIWindow *win in scene.windows) {
                if (win.isKeyWindow && win.isHidden == NO) {
                    targetWin = win;
                    break;
                }
            }
            if (targetWin) break;
        }
    }
    return targetWin;
}

static void createFullScreenMask(NSURL *videoUrl) {
    dispatch_async(dispatch_get_main_queue(), ^{
        destroyMask();
        AVPlayerItem *item = [AVPlayerItem playerItemWithURL:videoUrl];
        g_maskPlayer = [AVPlayer playerWithPlayerItem:item];
        g_maskPlayer.actionAtItemEnd = AVPlayerActionAtItemEndNone;
        [g_maskPlayer play];
        
        g_maskPlayerLayer = [AVPlayerLayer playerLayerWithPlayer:g_maskPlayer];
        UIWindow *keyWin = getActiveKeyWindow();
        if (!keyWin) return;
        
        g_maskPlayerLayer.frame = keyWin.bounds;
        g_maskPlayerLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
        g_maskPlayerLayer.zPosition = 9998;
        [keyWin.layer addSublayer:g_maskPlayerLayer];
        NSLog(@"[VCam] 全屏视频遮罩创建完成，覆盖相机预览");
    });
}

static void destroyMask() {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (g_maskPlayer) {
            [g_maskPlayer pause];
            g_maskPlayer = nil;
        }
        if (g_maskPlayerLayer) {
            [g_maskPlayerLayer removeFromSuperlayer];
            g_maskPlayerLayer = nil;
        }
    });
}

static void setupFloatButton() {
    if (g_floatButton) return;
    CGFloat btnSize = 50;
    CGRect screen = [UIScreen mainScreen].bounds;

    g_floatButton = [VCamFloatButton buttonWithType:UIButtonTypeSystem];
    g_floatButton.frame = CGRectMake(screen.size.width - btnSize - 15, 100, btnSize, btnSize);
    g_floatButton.layer.cornerRadius = btnSize / 2.0;
    g_floatButton.layer.shadowColor = [UIColor blackColor].CGColor;
    g_floatButton.layer.shadowOffset = CGSizeMake(0, 2);
    g_floatButton.layer.shadowOpacity = 0.3;
    g_floatButton.layer.shadowRadius = 4;
    g_floatButton.backgroundColor = g_vcamEnabled
        ? [UIColor colorWithRed:0.2 green:0.8 blue:0.4 alpha:0.9]
        : [UIColor colorWithRed:0.4 green:0.4 blue:0.4 alpha:0.9];
    [g_floatButton setTitle:@"📷" forState:UIControlStateNormal];
    g_floatButton.titleLabel.font = [UIFont systemFontOfSize:24];
    g_floatButton.layer.zPosition = 9999;

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:g_floatButton action:@selector(handlePan:)];
    [g_floatButton addGestureRecognizer:pan];
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:g_floatButton action:@selector(handleTap:)];
    [g_floatButton addGestureRecognizer:tap];

    g_overlayWindow = [[VCamOverlayWindow alloc] initWithFrame:screen];
    g_overlayWindow.windowLevel = UIWindowLevelStatusBar - 1;
    g_overlayWindow.isShowingAlert = NO;
    g_overlayWindow.hidden = NO;
    g_overlayWindow.backgroundColor = [UIColor clearColor];

    VCamRootView *rootView = [[VCamRootView alloc] initWithFrame:g_overlayWindow.bounds];
    rootView.backgroundColor = [UIColor clearColor];
    [rootView addSubview:g_floatButton];
    UIViewController *rootVC = [[UIViewController alloc] init];
    rootVC.view = rootView;
    g_overlayWindow.rootViewController = rootVC;

    class_addMethod([g_floatButton class], @selector(handlePan:), (IMP)handlePanGesture, "v@:@");
    class_addMethod([g_floatButton class], @selector(handleTap:), (IMP)handleTapGesture, "v@:@");
}

static void handlePanGesture(UIPanGestureRecognizer *gesture) {
    UIView *btn = gesture.view;
    CGPoint translation = [gesture translationInView:btn.superview];
    btn.center = CGPointMake(btn.center.x + translation.x, btn.center.y + translation.y);
    [gesture setTranslation:CGPointZero inView:btn.superview];
    if (gesture.state == UIGestureRecognizerStateEnded) {
        CGRect screen = [UIScreen mainScreen].bounds;
        CGFloat x = btn.center.x < screen.size.width / 2 ? 35 : screen.size.width - 35;
        [UIView animateWithDuration:0.2 animations:^{
            btn.center = CGPointMake(x, btn.center.y);
        }];
    }
}

static UIViewController *findTopViewController(void) {
    UIViewController *topVC = nil;
    for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (scene.activationState == UISceneActivationStateForegroundActive) {
            for (UIWindow *w in scene.windows) {
                if (w.isKeyWindow) {
                    topVC = w.rootViewController;
                    break;
                }
            }
        }
    }
    while (topVC && topVC.presentedViewController) {
        topVC = topVC.presentedViewController;
    }
    return topVC;
}

#pragma mark 相册选择代理
@interface VCamImagePickerControllerDelegate : NSObject <UINavigationControllerDelegate, UIImagePickerControllerDelegate>
@end
@implementation VCamImagePickerControllerDelegate
- (void)imagePickerController:(UIImagePickerController *)picker didFinishPickingMediaWithInfo:(NSDictionary<UIImagePickerControllerInfoKey, id> *)info {
    [picker dismissViewControllerAnimated:YES completion:nil];
    NSURL *srcUrl = info[UIImagePickerControllerMediaURL];
    if (!srcUrl) {
        NSLog(@"[VCam] 未选择视频文件");
        return;
    }
    g_selectedVideoUrl = srcUrl;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{
        [[MediaManager sharedManager] loadMediaFromURL:srcUrl];
        dispatch_async(dispatch_get_main_queue(), ^{
            g_vcamEnabled = YES;
            [[MediaManager sharedManager] start];
            createFullScreenMask(srcUrl);
            if (g_floatButton) g_floatButton.backgroundColor = [UIColor colorWithRed:0.2 green:0.8 blue:0.4 alpha:0.9];
            NSLog(@"[VCam] 视频加载完成，遮罩已生成");
        });
    });
}
- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker {
    [picker dismissViewControllerAnimated:YES completion:nil];
}
@end
static VCamImagePickerControllerDelegate *g_pickerDelegate = nil;

static void handleTapGesture(UITapGestureRecognizer *gesture) {
    UIViewController *topVC = findTopViewController();
    if (!topVC) return;
    g_overlayWindow.isShowingAlert = YES;
    g_overlayWindow.windowLevel = UIWindowLevelAlert + 1;

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"VCam" message:g_vcamEnabled ? @"虚拟相机已启用" : @"虚拟相机已关闭" preferredStyle:UIAlertControllerStyleActionSheet];

    [alert addAction:[UIAlertAction actionWithTitle:@"选择视频" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        if (![UIImagePickerController isSourceTypeAvailable:UIImagePickerControllerSourceTypeSavedPhotosAlbum]) return;
        UIImagePickerController *picker = [[UIImagePickerController alloc] init];
        picker.sourceType = UIImagePickerControllerSourceTypeSavedPhotosAlbum;
        picker.mediaTypes = @[@"public.movie"];
        picker.delegate = g_pickerDelegate;
        [topVC presentViewController:picker animated:YES completion:nil];
    }]];

    [alert addAction:[UIAlertAction actionWithTitle:g_vcamEnabled ? @"关闭虚拟相机" : @"开启虚拟相机" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        g_vcamEnabled = !g_vcamEnabled;
        if (g_floatButton) g_floatButton.backgroundColor = g_vcamEnabled ? [UIColor colorWithRed:0.2 green:0.8 blue:0.4 alpha:0.9] : [UIColor colorWithRed:0.4 green:0.4 blue:0.4 alpha:0.9];
        if (g_vcamEnabled) {
            [[MediaManager sharedManager] start];
            if (g_selectedVideoUrl) createFullScreenMask(g_selectedVideoUrl);
        } else {
            [[MediaManager sharedManager] stop];
            destroyMask();
        }
        NSLog(@"[VCam] 虚拟相机开关切换：%d", g_vcamEnabled);
    }]];

    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) {
        g_overlayWindow.isShowingAlert = NO;
        g_overlayWindow.windowLevel = UIWindowLevelStatusBar - 1;
    }]];

    if (alert.popoverPresentationController) {
        alert.popoverPresentationController.sourceView = gesture.view;
        alert.popoverPresentationController.sourceRect = gesture.view.bounds;
    }
    [topVC presentViewController:alert animated:YES completion:nil];
}

#pragma mark Hook分组（无私有框架）
%group VCamHooks
%hook AVCaptureVideoDataOutput
- (void)setSampleBufferDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)delegate queue:(dispatch_queue_t)queue {
    %orig;
    if (!g_allVideoDelegates) g_allVideoDelegates = [NSMutableArray array];
    if (delegate && ![g_allVideoDelegates containsObject:delegate]) {
        [g_allVideoDelegates addObject:delegate];
    }
}
%end

%hook NSObject
- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection {
    if (g_vcamEnabled && [[MediaManager sharedManager] isRunning]) {
        CMSampleBufferRef fakeFrame = [[MediaManager sharedManager] nextVideoFrame];
        if (fakeFrame) {
            for (id del in g_allVideoDelegates) {
                if ([del respondsToSelector:@selector(captureOutput:didOutputSampleBuffer:fromConnection:)]) {
                    [del captureOutput:output didOutputSampleBuffer:fakeFrame fromConnection:connection];
                }
            }
            return;
        }
    }
    %orig;
}
%end

%hook AVCaptureSession
- (void)startRunning { %orig; }
- (void)stopRunning { %orig; }
%end

%hook AVCapturePhotoOutput
- (void)capturePhotoWithSettings:(AVCapturePhotoSettings *)settings delegate:(id<AVCapturePhotoCaptureDelegate>)delegate { %orig; }
%end
%end

#pragma mark 入口构造函数
%ctor {
    @autoreleasepool {
        g_pickerDelegate = [[VCamImagePickerControllerDelegate alloc] init];
        g_allVideoDelegates = nil;
        g_selectedVideoUrl = nil;
        destroyMask();
        NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
        if (![bundleID isEqualToString:@"com.apple.springboard"]) {
            %init(VCamHooks);
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            @autoreleasepool {
                setupFloatButton();
            }
        });
    }
}

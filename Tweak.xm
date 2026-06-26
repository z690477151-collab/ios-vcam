#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <substrate.h>
#import "MediaManager.h"

#pragma mark - 全局缓存相机代理、预览层会话
static NSMutableArray* g_allVideoDelegates = nil;
static AVCaptureSession *g_captureSession = nil;

#pragma mark - 悬浮穿透窗口
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

#pragma mark 全局状态
static BOOL g_vcamEnabled = NO;
static VCamOverlayWindow *g_overlayWindow = nil;
static UIButton *g_floatButton = nil;

@interface VCamFloatButton : UIButton
@property (nonatomic, assign) CGPoint initialCenter;
@end
@implementation VCamFloatButton
@end

static void setupFloatButton(void);
static void handlePanGesture(UIPanGestureRecognizer *gesture);
static void handleTapGesture(UITapGestureRecognizer *gesture);

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

#pragma mark 相册选择代理（无BOOL编译错误版）
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
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{
        [[MediaManager sharedManager] loadMediaFromURL:srcUrl];
        dispatch_async(dispatch_get_main_queue(), ^{
            g_vcamEnabled = YES;
            [[MediaManager sharedManager] start];
            if (g_floatButton) g_floatButton.backgroundColor = [UIColor colorWithRed:0.2 green:0.8 blue:0.4 alpha:0.9];
            NSLog(@"[VCam] 视频加载完成，虚拟相机启用");
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
        if (g_vcamEnabled) [[MediaManager sharedManager] start];
        else [[MediaManager sharedManager] stop];
        NSLog(@"[VCam] 开关状态：%d", g_vcamEnabled);
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

#pragma mark 核心Hook分组 路线B：双管线劫持（预览层+数据输出）
%group VCamHooks

// 1、捕获全局CaptureSession实例
%hook AVCaptureSession
- (void)setSessionPreset:(AVCaptureSessionPreset)preset {
    %orig;
    g_captureSession = self;
    NSLog(@"[VCam] 捕获CaptureSession");
}
- (void)startRunning { %orig; }
- (void)stopRunning { %orig; }
%end

// 2、劫持视频输出，缓存所有业务代理
%hook AVCaptureVideoDataOutput
- (void)setSampleBufferDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)delegate queue:(dispatch_queue_t)queue {
    %orig;
    if (!g_allVideoDelegates) g_allVideoDelegates = [NSMutableArray array];
    if (delegate && ![g_allVideoDelegates containsObject:delegate]) {
        [g_allVideoDelegates addObject:delegate];
        NSLog(@"[VCam] 缓存业务代理 %@", delegate);
    }
}
%end

// 3、劫持预览层setSession，拦截硬件渲染管线（路线B核心）
%hook AVCaptureVideoPreviewLayer
- (void)setSession:(AVCaptureSession *)session {
    // 先执行原生绑定
    %orig;
    if (!session) return;
    g_captureSession = session;
    NSLog(@"[VCam] 劫持预览层渲染管线");
}
%end

// 4、拦截所有captureOutput，阻断原生真实帧，下发虚拟帧（业务层替换）
%hook NSObject
- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection {
    if (g_vcamEnabled && [[MediaManager sharedManager] isRunning]) {
        CMSampleBufferRef fakeFrame = [[MediaManager sharedManager] nextVideoFrame];
        if (fakeFrame) {
            // 阻断原生相机真实帧下发
            for (id del in g_allVideoDelegates) {
                if ([del respondsToSelector:@selector(captureOutput:didOutputSampleBuffer:fromConnection:)]) {
                    [del captureOutput:output didOutputSampleBuffer:fakeFrame fromConnection:connection];
                }
            }
            NSLog(@"[VCam] 业务帧替换成功");
            return;
        }
    }
    // 虚拟相机关闭才走原生画面
    %orig;
}
%end

// 拍照输出保留原生逻辑
%hook AVCapturePhotoOutput
- (void)capturePhotoWithSettings:(AVCapturePhotoSettings *)settings delegate:(id<AVCapturePhotoCaptureDelegate>)delegate {
    %orig;
}
%end

%end

#pragma mark 入口构造函数
%ctor {
    @autoreleasepool {
        g_pickerDelegate = [[VCamImagePickerControllerDelegate alloc] init];
        g_allVideoDelegates = nil;
        NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
        NSLog(@"[VCam] 系统版本:%@ 进程:%@", [[UIDevice currentDevice] systemVersion], bundleID);
        if (![bundleID isEqualToString:@"com.apple.springboard"]) {
            %init(VCamHooks);
            NSLog(@"[VCam] 相机双管线Hook加载完成");
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            @autoreleasepool {
                setupFloatButton();
            }
        });
    }
}

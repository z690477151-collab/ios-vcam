#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <substrate.h>
#import "MediaManager.h"

#pragma mark - 全局保存所有App原始相机代理
static id g_originalVideoDelegate = nil;

#pragma mark - 自定义顶层悬浮窗口类（触摸穿透逻辑不变）
@interface VCamOverlayWindow : UIWindow
@property (nonatomic, assign) BOOL isShowingAlert;
@end
@implementation VCamOverlayWindow
- (BOOL)isPointHitButtonArea:(CGPoint)point {
    if (!self.rootViewController) return NO;
    UIView *rootV = self.rootViewController.view;
    for (UIView *sub in rootV.subviews) {
        CGRect winRect = [sub convertRect:sub.bounds toView:self];
        if (CGRectContainsPoint(winRect, point)) {
            return YES;
        }
    }
    return NO;
}
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (self.isShowingAlert) {
        return [super hitTest:point withEvent:event];
    }
    if (![self isPointHitButtonArea:point]) {
        return nil;
    }
    return [super hitTest:point withEvent:event];
}
@end

#pragma mark - 悬浮窗口根视图兜底穿透
@interface VCamRootView : UIView
@end
@implementation VCamRootView
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    for (UIView *sub in self.subviews) {
        CGPoint innerP = [self convertPoint:point toView:sub];
        if ([sub pointInside:innerP withEvent:event]) {
            return sub;
        }
    }
    return nil;
}
@end

#pragma mark - 全局静态状态
static BOOL g_vcamEnabled = NO;
static VCamOverlayWindow *g_overlayWindow = nil;
static UIButton *g_floatButton = nil;

#pragma mark - 悬浮按钮自定义类
@interface VCamFloatButton : UIButton
@property (nonatomic, assign) CGPoint initialCenter;
@end
@implementation VCamFloatButton
@end

#pragma mark - 前置函数声明
static void setupFloatButton(void);
static void handlePanGesture(UIPanGestureRecognizer *gesture);
static void handleTapGesture(UITapGestureRecognizer *gesture);

#pragma mark - 创建悬浮窗口与按钮
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

#pragma mark - 拖拽吸附逻辑
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

#pragma mark - 获取顶层控制器
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

#pragma mark - 相册视频选择代理
@interface VCamImagePickerControllerDelegate : NSObject <UINavigationControllerDelegate, UIImagePickerControllerDelegate>
@end
@implementation VCamImagePickerControllerDelegate
- (void)imagePickerController:(UIImagePickerController *)picker didFinishPickingMediaWithInfo:(NSDictionary<UIImagePickerControllerInfoKey, id> *)info {
    [picker dismissViewControllerAnimated:YES completion:nil];
    NSURL *url = info[UIImagePickerControllerMediaURL];
    if (!url) return;
    NSURL *tempURL = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:@"vcam_input.mp4"]];
    [[NSFileManager defaultManager] removeItemAtURL:tempURL error:nil];
    [[NSFileManager defaultManager] copyItemAtURL:url toURL:tempURL error:nil];

    // 延迟加载等待视频解码
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [[MediaManager sharedManager] loadMediaFromURL:tempURL];
        g_vcamEnabled = YES;
        [[MediaManager sharedManager] start];
        if (g_floatButton) {
            g_floatButton.backgroundColor = [UIColor colorWithRed:0.2 green:0.8 blue:0.4 alpha:0.9];
        }
        NSLog(@"[VCam] 视频加载完成，虚拟相机开启");
    });
}
- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker {
    [picker dismissViewControllerAnimated:YES completion:nil];
}
@end
static VCamImagePickerControllerDelegate *g_pickerDelegate = nil;

#pragma mark - 悬浮按钮点击弹出菜单
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
        if (g_floatButton) {
            g_floatButton.backgroundColor = g_vcamEnabled ? [UIColor colorWithRed:0.2 green:0.8 blue:0.4 alpha:0.9] : [UIColor colorWithRed:0.4 green:0.4 blue:0.4 alpha:0.9];
        }
        g_vcamEnabled ? [[MediaManager sharedManager] start] : [[MediaManager sharedManager] stop];
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

#pragma mark - 核心Hook分组（iOS16 兼容写法）
%group VCamHooks

// 1、拦截所有AVCaptureVideoDataOutput，捕获App原始代理（关键修复）
%hook AVCaptureVideoDataOutput
- (void)setSampleBufferDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)delegate queue:(dispatch_queue_t)queue {
    %orig;
    // 保存业务App原生代理
    g_originalVideoDelegate = delegate;
    NSLog(@"[VCam] 捕获相机原始代理 %@", delegate);
}
%end

// 2、兜底拦截所有对象的captureOutput（iOS16唯一通用兼容方案，废弃协议hook）
%hook NSObject
- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection {
    // 虚拟相机开启且媒体管理器正常运行
    if (g_vcamEnabled && [[MediaManager sharedManager] isRunning]) {
        CMSampleBufferRef fakeFrame = [[MediaManager sharedManager] nextVideoFrame];
        if (fakeFrame) {
            NSLog(@"[VCam] 成功替换相机帧");
            // 把伪造帧传给App原始代理
            if (g_originalVideoDelegate && [g_originalVideoDelegate respondsToSelector:@selector(captureOutput:didOutputSampleBuffer:fromConnection:)]) {
                [g_originalVideoDelegate captureOutput:output didOutputSampleBuffer:fakeFrame fromConnection:connection];
            }
            return;
        } else {
            NSLog(@"[VCam] MediaManager无有效视频帧");
        }
    }
    // 虚拟相机关闭，执行原生逻辑
    %orig;
}
%end

// 无用钩子保留不改动
%hook AVCaptureSession
- (void)startRunning { %orig; }
- (void)stopRunning { %orig; }
%end

%hook AVCapturePhotoOutput
- (void)capturePhotoWithSettings:(AVCapturePhotoSettings *)settings delegate:(id<AVCapturePhotoCaptureDelegate>)delegate { %orig; }
%end

%hook AVCaptureVideoPreviewLayer
- (void)setSession:(AVCaptureSession *)session { %orig; }
%end

%end // VCamHooks 分组结束

#pragma mark - Tweak入口
%ctor {
    @autoreleasepool {
        g_pickerDelegate = [[VCamImagePickerControllerDelegate alloc] init];
        NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
        // 所有非桌面进程加载相机钩子
        if (![bundleID isEqualToString:@"com.apple.springboard"]) {
            %init(VCamHooks);
            NSLog(@"[VCam] 已加载相机Hook，进程：%@", bundleID);
        }
        // 延迟创建悬浮UI
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            @autoreleasepool {
                setupFloatButton();
            }
        });
    }
}

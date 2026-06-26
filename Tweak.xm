#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <substrate.h>
#import "MediaManager.h"

#pragma mark - 自定义顶层悬浮窗口类（核心：触摸穿透逻辑）
/**
 自定义UIWindow，重写hitTest实现两套触摸规则：
 1. 弹出弹窗菜单时：全屏接收触摸，保证弹窗按钮可点击
 2. 无弹窗正常状态：仅悬浮按钮可点击，屏幕空白触摸全部透传给底层App
 */
@interface VCamOverlayWindow : UIWindow
@property (nonatomic, assign) BOOL isShowingAlert; // 标记：当前是否弹出了VCam菜单弹窗
@end

@implementation VCamOverlayWindow
/// 判断当前点击坐标是否落在悬浮按钮范围内
- (BOOL)isPointHitButtonArea:(CGPoint)point {
    // 无根控制器直接返回false
    if (!self.rootViewController) return NO;
    UIView *rootV = self.rootViewController.view;
    // 遍历窗口根视图所有子视图（只有悬浮按钮）
    for (UIView *sub in rootV.subviews) {
        // 将按钮坐标转换为窗口全局坐标
        CGRect winRect = [sub convertRect:sub.bounds toView:self];
        // 判断点击点是否在按钮框内
        if (CGRectContainsPoint(winRect, point)) {
            return YES;
        }
    }
    return NO;
}

/// iOS触摸分发核心方法，系统每次点击屏幕都会优先调用window的hitTest
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    // 分支1：弹窗菜单正在显示，不拦截任何触摸，交给系统弹窗处理
    if (self.isShowingAlert) {
        return [super hitTest:point withEvent:event];
    }
    // 分支2：无弹窗，点击不在按钮区域 → 返回nil，触摸穿透到底层APP
    if (![self isPointHitButtonArea:point]) {
        return nil;
    }
    // 分支3：无弹窗，点击落在按钮上 → 正常响应按钮触摸（拖拽、点击）
    return [super hitTest:point withEvent:event];
}
@end

#pragma mark - 悬浮窗口根视图兜底穿透（辅助防护）
@interface VCamRootView : UIView
@end
@implementation VCamRootView
/// 视图层二级hitTest兜底，仅按钮响应触摸
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

#pragma mark - 全局静态变量（全局单例状态）
static BOOL g_vcamEnabled = NO;          // 虚拟相机总开关标记
static VCamOverlayWindow *g_overlayWindow = nil; // 全局悬浮窗口单例
static UIButton *g_floatButton = nil;    // 全局悬浮圆球按钮单例

#pragma mark - 悬浮按钮自定义类（仅占位，动态绑定手势方法）
@interface VCamFloatButton : UIButton
@property (nonatomic, assign) CGPoint initialCenter; // 预留：拖拽起始坐标（本代码未使用）
@end
@implementation VCamFloatButton
@end

#pragma mark - 前置函数声明
static void setupFloatButton(void);                              // 创建悬浮窗口+按钮
static void handlePanGesture(UIPanGestureRecognizer *gesture);   // 按钮拖拽手势回调
static void handleTapGesture(UITapGestureRecognizer *gesture);  // 按钮点击手势回调

#pragma mark - 创建悬浮顶层窗口、悬浮圆球按钮、绑定手势
static void setupFloatButton() {
    // 防止重复创建窗口/按钮，单例保护
    if (g_floatButton) return;
    
    CGFloat btnSize = 50; // 悬浮圆球尺寸
    CGRect screen = [UIScreen mainScreen].bounds; // 获取屏幕尺寸
    
    // 1. 初始化自定义悬浮按钮
    g_floatButton = [VCamFloatButton buttonWithType:UIButtonTypeSystem];
    // 初始位置：屏幕右上角
    g_floatButton.frame = CGRectMake(screen.size.width - btnSize - 15, 100, btnSize, btnSize);
    g_floatButton.layer.cornerRadius = btnSize / 2.0; // 圆形圆角
    // 阴影美化
    g_floatButton.layer.shadowColor = [UIColor blackColor].CGColor;
    g_floatButton.layer.shadowOffset = CGSizeMake(0, 2);
    g_floatButton.layer.shadowOpacity = 0.3;
    g_floatButton.layer.shadowRadius = 4;
    // 根据虚拟相机开关状态切换背景色：绿色启用 / 灰色关闭
    g_floatButton.backgroundColor = g_vcamEnabled 
        ? [UIColor colorWithRed:0.2 green:0.8 blue:0.4 alpha:0.9]
        : [UIColor colorWithRed:0.4 green:0.4 blue:0.4 alpha:0.9];
    
    [g_floatButton setTitle:@"📷" forState:UIControlStateNormal]; // 相机图标文字
    g_floatButton.titleLabel.font = [UIFont systemFontOfSize:24];
    
    // 2. 添加拖拽手势
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] 
        initWithTarget:g_floatButton action:@selector(handlePan:)];
    [g_floatButton addGestureRecognizer:pan];
    
    // 3. 添加点击手势（弹出菜单）
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] 
        initWithTarget:g_floatButton action:@selector(handleTap:)];
    [g_floatButton addGestureRecognizer:tap];
    
    // 4. 创建自定义穿透顶层窗口
    g_overlayWindow = [[VCamOverlayWindow alloc] initWithFrame:screen];
    // 默认窗口层级：低于状态栏，不抢占系统弹窗，空白区域自动穿透
    g_overlayWindow.windowLevel = UIWindowLevelStatusBar - 1;
    g_overlayWindow.isShowingAlert = NO; // 初始无弹窗标记
    g_overlayWindow.hidden = NO;         // 窗口立即显示
    g_overlayWindow.backgroundColor = [UIColor clearColor]; // 完全透明
    
    // 5. 创建根视图承载悬浮按钮
    VCamRootView *rootView = [[VCamRootView alloc] initWithFrame:g_overlayWindow.bounds];
    rootView.backgroundColor = [UIColor clearColor];
    [rootView addSubview:g_floatButton];
    
    // 6. 绑定窗口根控制器
    UIViewController *rootVC = [[UIViewController alloc] init];
    rootVC.view = rootView;
    g_overlayWindow.rootViewController = rootVC;
    
    // 动态给按钮类注入手势处理函数（Theos Tweak动态绑定IMP）
    class_addMethod([g_floatButton class], @selector(handlePan:), 
                    (IMP)handlePanGesture, "v@:@");
    class_addMethod([g_floatButton class], @selector(handleTap:), 
                    (IMP)handleTapGesture, "v@:@");
}

#pragma mark - 悬浮按钮拖拽逻辑：拖动松手自动吸附屏幕左右边缘
static void handlePanGesture(UIPanGestureRecognizer *gesture) {
    UIView *btn = gesture.view;
    // 获取拖拽偏移量
    CGPoint translation = [gesture translationInView:btn.superview];
    // 更新按钮坐标
    btn.center = CGPointMake(btn.center.x + translation.x, btn.center.y + translation.y);
    // 重置拖拽偏移，避免叠加
    [gesture setTranslation:CGPointZero inView:btn.superview];
    
    // 拖拽结束松手触发吸附动画
    if (gesture.state == UIGestureRecognizerStateEnded) {
        CGRect screen = [UIScreen mainScreen].bounds;
        // 判断靠左/靠右，自动贴边
        CGFloat x = btn.center.x < screen.size.width / 2 ? 35 : screen.size.width - 35;
        [UIView animateWithDuration:0.2 animations:^{
            btn.center = CGPointMake(x, btn.center.y);
        }];
    }
}

#pragma mark - 工具函数：获取当前顶层弹出控制器（用于弹窗展示）
static UIViewController *findTopViewController(void) {
    UIViewController *topVC = nil;
    // 遍历所有屏幕场景，找到前台激活窗口
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
    // 递归找到最顶层presented弹窗控制器
    while (topVC && topVC.presentedViewController) {
        topVC = topVC.presentedViewController;
    }
    return topVC;
}

#pragma mark - 相册选取视频代理：接收选中视频并加载到虚拟相机
@interface VCamImagePickerControllerDelegate : NSObject <UINavigationControllerDelegate, UIImagePickerControllerDelegate>
@end

@implementation VCamImagePickerControllerDelegate
/// 选中视频文件回调
- (void)imagePickerController:(UIImagePickerController *)picker 
        didFinishPickingMediaWithInfo:(NSDictionary<UIImagePickerControllerInfoKey, id> *)info {
    [picker dismissViewControllerAnimated:YES completion:nil];
    
    // 获取选中视频本地URL
    NSURL *url = info[UIImagePickerControllerMediaURL];
    if (!url) return;
    
    // 复制视频到临时目录固定路径，供MediaManager读取
    NSURL *tempURL = [NSURL fileURLWithPath:[NSTemporaryDirectory() 
        stringByAppendingPathComponent:@"vcam_input.mp4"]];
    [[NSFileManager defaultManager] removeItemAtURL:tempURL error:nil];
    [[NSFileManager defaultManager] copyItemAtURL:url toURL:tempURL error:nil];
    
    // 修复：主线程延迟0.3s等待视频解码加载完成，避免start提前执行无帧
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [[MediaManager sharedManager] loadMediaFromURL:tempURL];
        g_vcamEnabled = YES;
        [[MediaManager sharedManager] start];
        // 按钮切换为绿色启用状态
        if (g_floatButton) {
            g_floatButton.backgroundColor = [UIColor colorWithRed:0.2 green:0.8 blue:0.4 alpha:0.9];
        }
    });
}
/// 点击相册取消回调
- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker {
    [picker dismissViewControllerAnimated:YES completion:nil];
}
@end

static VCamImagePickerControllerDelegate *g_pickerDelegate = nil; // 相册代理全局单例

#pragma mark - 悬浮按钮点击回调：弹出VCam操作菜单ActionSheet
static void handleTapGesture(UITapGestureRecognizer *gesture) {
    UIViewController *topVC = findTopViewController();
    if (!topVC) return;
    
    // 关键：标记弹窗开启，提升窗口层级，允许弹窗全部按钮点击
    g_overlayWindow.isShowingAlert = YES;
    g_overlayWindow.windowLevel = UIWindowLevelAlert + 1;
    
    // 创建底部弹出操作菜单
    UIAlertController *alert = [UIAlertController 
        alertControllerWithTitle:@"VCam" 
        message:g_vcamEnabled ? @"虚拟相机已启用" : @"虚拟相机已关闭"
        preferredStyle:UIAlertControllerStyleActionSheet];
    
    // 选项1：打开相册选择视频素材
    [alert addAction:[UIAlertAction actionWithTitle:@"选择视频" 
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        // 判断相册是否可用
        if (![UIImagePickerController isSourceTypeAvailable:UIImagePickerControllerSourceTypeSavedPhotosAlbum]) {
            return;
        }
        // 初始化相册选择器，仅允许视频
        UIImagePickerController *picker = [[UIImagePickerController alloc] init];
        picker.sourceType = UIImagePickerControllerSourceTypeSavedPhotosAlbum;
        picker.mediaTypes = @[@"public.movie"];
        picker.delegate = g_pickerDelegate;
        [topVC presentViewController:picker animated:YES completion:nil];
    }]];
    
    // 选项2：开启/关闭虚拟相机总开关
    [alert addAction:[UIAlertAction actionWithTitle:g_vcamEnabled ? @"关闭虚拟相机" : @"开启虚拟相机" 
        style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        // 切换全局开关状态
        g_vcamEnabled = !g_vcamEnabled;
        // 更新按钮颜色
        if (g_floatButton) {
            g_floatButton.backgroundColor = g_vcamEnabled 
                ? [UIColor colorWithRed:0.2 green:0.8 blue:0.4 alpha:0.9]
                : [UIColor colorWithRed:0.4 green:0.4 blue:0.4 alpha:0.9];
        }
        // 启动/停止媒体帧输出
        if (g_vcamEnabled) {
            [[MediaManager sharedManager] start];
        } else {
            [[MediaManager sharedManager] stop];
        }
    }]];
    
    // 选项3：取消菜单，单独在这里重置窗口穿透状态
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) {
        // 弹窗关闭：恢复低层级、开启屏幕触摸穿透
        g_overlayWindow.isShowingAlert = NO;
        g_overlayWindow.windowLevel = UIWindowLevelStatusBar - 1;
    }]];
    
    // iPad弹窗适配：弹出锚点绑定悬浮按钮
    if (alert.popoverPresentationController) {
        alert.popoverPresentationController.sourceView = gesture.view;
        alert.popoverPresentationController.sourceRect = gesture.view.bounds;
    }
    
    // 展示操作菜单，无统一收尾回调
    [topVC presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Theos Hook分组：拦截系统相机帧输出，替换虚拟视频画面
%group VCamHooks

/// 拦截相机会话启停（仅保留原逻辑，无修改）
%hook AVCaptureSession
- (void)startRunning { %orig; }
- (void)stopRunning { %orig; }
%end

/// 拦截相机视频输出代理绑定（仅保留原逻辑，无修改）
%hook AVCaptureVideoDataOutput
- (void)setSampleBufferDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)delegate 
                          queue:(dispatch_queue_t)queue {
    %orig;
}
%end

// ====================== 修复核心：不再hook NSObject，专门hook代理协议接收类 ======================
%hook AVCaptureVideoDataOutputSampleBufferDelegate
- (void)captureOutput:(AVCaptureOutput *)output 
    didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer 
           fromConnection:(AVCaptureConnection *)connection {
    // 虚拟相机开启且媒体管理器正常运行时，替换帧
    if (g_vcamEnabled && [[MediaManager sharedManager] isRunning]) {
        CMSampleBufferRef fakeFrame = [[MediaManager sharedManager] nextVideoFrame];
        if (fakeFrame) {
            NSLog(@"VCam: 成功替换虚拟视频帧");
            // 传入自定义视频帧替代原生相机画面
            %orig(output, fakeFrame, connection);
            // 修复：注释掉手动CFRelease，交由MediaManager管理帧生命周期，防止野指针失效
            // CFRelease(fakeFrame);
            return;
        } else {
            NSLog(@"VCam: MediaManager无可用视频帧，使用原生相机");
        }
    }
    // 虚拟相机关闭：执行原生逻辑，使用真实相机画面
    %orig;
}
%end

/// 拦截拍照接口（保留原生逻辑）
%hook AVCapturePhotoOutput
- (void)capturePhotoWithSettings:(AVCapturePhotoSettings *)settings 
                        delegate:(id<AVCapturePhotoCaptureDelegate>)delegate {
    %orig;
}
%end

/// 拦截相机预览层绑定会话（保留原生逻辑）
%hook AVCaptureVideoPreviewLayer
- (void)setSession:(AVCaptureSession *)session {
    %orig;
}
%end

%end // VCamHooks 钩子分组结束

#pragma mark - Tweak入口构造函数 %ctor（插件加载自动执行）
%ctor {
    @autoreleasepool {
        // 初始化相册选取代理
        g_pickerDelegate = [[VCamImagePickerControllerDelegate alloc] init];
        
        // 仅在非SpringBoard进程加载相机钩子（避免全局冲突）
        NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
        if (![bundleID isEqualToString:@"com.apple.springboard"]) {
            %init(VCamHooks);
        }
        
        // 延迟1秒在主线程创建悬浮窗口，避免进程启动UI冲突
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), 
            dispatch_get_main_queue(), ^{
                @autoreleasepool {
                    setupFloatButton();
                }
            });
    }
}

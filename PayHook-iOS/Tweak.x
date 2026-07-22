//
//  Tweak.x
//  PayHook v3.0 — 微信收款监控（白黑版 / yZFAIU）
//
//  改造要点 (by yZFAIU):
//    1. 设置入口：在「我 → 设置」页面顶部注入独立按钮
//    2. 检测方式：仅识别「微信收款助手」来源（白名单精确匹配），不再走 XML/关键词/模糊匹配兜底
//    3. 设置页面：独立 UI（白黑主题）+ 作者 by yZFAIU
//    4. 首次加载提示：白底卡片，简洁干净
//    5. 取消弹窗模式：点击按钮进入全新设置界面（白底卡片）
//    6. 订单匹配成功：改为系统通知（非弹窗）
//    7. 收款识别提示：白底卡片优化 UI
//

#import <Foundation/Foundation.h>

// [AUTO] 中文运行时还原 (规避 L1ghtmann clang UTF-8 字面量 bug)
static inline NSString *xj_ls(NSString *b64) {
    if (!b64) return @"";
    NSData *d = [[NSData alloc] initWithBase64EncodedString:b64 options:0];
    return d ? ([[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] ?: @"") : @"";
}
#define XJ_T(b64) xj_ls(b64)
// [/AUTO]
#import <UIKit/UIKit.h>

// 状态栏样式辅助函数前向声明（定义在文件末尾，提前声明以保证各 VC 可调用）
static UIStatusBarStyle XJStatusBarStyleForTrait(UITraitCollection *t);
// 导航栏统一样式辅助函数前向声明
static void XJApplyNavBarStyleForTrait(UINavigationBar *bar, UITraitCollection *trait, BOOL translucent);

// [FIX] 提前类接口声明 (放在 UIKit import 之后, 避免找不到 UIViewController/协议)
@interface XJOrderListViewController : UIViewController <UITableViewDataSource, UITableViewDelegate>
@end

@interface XJOrderStore : NSObject
+ (instancetype)sharedInstance;
- (void)addOrderWithAmount:(NSString *)amount tradeNo:(NSString *)tradeNo matched:(BOOL)matched time:(NSDate *)time;
- (NSArray<NSDictionary *> *)allOrders;
- (NSInteger)count;
- (void)clear;
@end
// [/FIX]
#import <objc/runtime.h>
#import <UserNotifications/UserNotifications.h>

// ============================================================
// MARK: - Import Enhanced Modules
// ============================================================

#import "XJPaymentXMLParser.h"
#import "XJRemoteConfig.h"
#import "XJPaySourceConfig.h"
#import "XJMessageDedup.h"

// ============================================================
// MARK: - Configuration
// ============================================================

static NSString *kServerURL     = nil;
static NSString *kMonitorSecret = nil;
static NSString *kMonitorName   = nil;
static BOOL      kDebugEnabled  = YES;
static NSTimeInterval kDedupWindow = 30.0;
static BOOL      kVisualFeedback = YES;

static NSMutableDictionary *sReportedAmounts = nil;

static NSInteger sHookFiredCount    = 0;
static NSInteger sPaymentDetected   = 0;
static NSInteger sReportSent        = 0;
static NSInteger sReportMatched     = 0;
static NSInteger sReportFailed      = 0;
static NSInteger sMessageWrapFired  = 0;
static NSInteger sCMessageMgrFired  = 0;
static NSInteger sDedupSkipped      = 0;
static NSInteger sXMLParsed         = 0;
static NSInteger sSourceMatched     = 0;
static NSString *sLastMatchTradeNo  = nil;
static NSString *sLastMatchAmount   = nil;
static NSTimeInterval sLastReportTime = 0;
static NSString *sLastDetectionMethod = nil;

static NSString *const kXJAuthor = @"by yZFAIU";

// ============================================================
// MARK: - 前向声明
// ============================================================

static void XJSaveConfig(void);
static void XJReportPaymentEnhanced(NSString *amount, NSString *rawText, NSDictionary *extraFields);
static NSDictionary<NSString*,NSString*> *XJBuildStatusDict(void);

// 自适应配色辅助（定义于文件后部，此处前向声明以便前置使用）
static UIColor *XJAdaptiveTextColor(void);
static UIColor *XJAdaptiveSubColor(void);

// ============================================================
// MARK: - Recent Message Log
// ============================================================

typedef struct {
    NSTimeInterval timestamp;
    unsigned int   msgType;
    unsigned int   appMsgInnerType;
    char           fromUser[64];
    char           contentPreview[200];
    BOOL           isPayment;
    char           amount[16];
    char           detectionMethod[32];
    char           paysubtype[8];
    char           transcationid[64];
} XJMessageLogEntry;

#define kMaxMsgLogEntries 20
static XJMessageLogEntry sMsgLog[kMaxMsgLogEntries];
static int sMsgLogCount = 0;
static int sMsgLogIndex = 0;

static void XJLogMessage(unsigned int msgType,
                         unsigned int appMsgInnerType,
                         NSString *fromUser,
                         NSString *content,
                         BOOL isPayment,
                         NSString *amount,
                         NSString *detectionMethod,
                         NSString *paysubtype,
                         NSString *transcationid) {
    int idx = sMsgLogIndex;
    sMsgLog[idx].timestamp = [[NSDate date] timeIntervalSince1970];
    sMsgLog[idx].msgType = msgType;
    sMsgLog[idx].appMsgInnerType = appMsgInnerType;
    sMsgLog[idx].isPayment = isPayment;

    const char *from = fromUser ? [fromUser UTF8String] : "";
    strncpy(sMsgLog[idx].fromUser, from, 63);
    sMsgLog[idx].fromUser[63] = '\0';

    NSString *preview = content;
    if (preview.length > 199) preview = [preview substringToIndex:199];
    preview = [preview stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
    const char *cstr = [preview UTF8String];
    strncpy(sMsgLog[idx].contentPreview, cstr, 199);
    sMsgLog[idx].contentPreview[199] = '\0';

    const char *amt = amount ? [amount UTF8String] : "";
    strncpy(sMsgLog[idx].amount, amt, 15);
    sMsgLog[idx].amount[15] = '\0';

    const char *dm = detectionMethod ? [detectionMethod UTF8String] : "";
    strncpy(sMsgLog[idx].detectionMethod, dm, 31);
    sMsgLog[idx].detectionMethod[31] = '\0';

    const char *ps = paysubtype ? [paysubtype UTF8String] : "";
    strncpy(sMsgLog[idx].paysubtype, ps, 7);
    sMsgLog[idx].paysubtype[7] = '\0';

    const char *tx = transcationid ? [transcationid UTF8String] : "";
    strncpy(sMsgLog[idx].transcationid, tx, 63);
    sMsgLog[idx].transcationid[63] = '\0';

    sMsgLogIndex = (sMsgLogIndex + 1) % kMaxMsgLogEntries;
    if (sMsgLogCount < kMaxMsgLogEntries) sMsgLogCount++;
}

// ============================================================
// MARK: - WeChat Private Class Declarations
// ============================================================

@interface CMessageWrap : NSObject
@property (retain, nonatomic) NSString     *m_nsContent;
@property (retain, nonatomic) NSString     *m_nsTitle;
@property (retain, nonatomic) NSString     *m_nsDesc;
@property (retain, nonatomic) NSString     *m_nsFromUsr;
@property (retain, nonatomic) NSString     *m_nsToUsr;
@property (retain, nonatomic) NSString     *m_nsMsgSource;
@property (assign, nonatomic) unsigned int  m_uiMessageType;
@property (assign, nonatomic) NSInteger     m_nMsgStatus;
@property (assign, nonatomic) long long     m_n64MesSvrID;
@property (assign, nonatomic) NSUInteger    m_uiCreateTime;
@property (assign, nonatomic) NSUInteger    m_uiAppMsgInnerType;
@property (retain, nonatomic) NSString     *m_nsRealChatUsr;
@property (retain, nonatomic) id            m_oWCPayInfoItem;
@end

@interface WCPayInfoItem : NSObject
@property (retain, nonatomic) NSString *m_c2cNativeUrl;
@end

@interface CMessageMgr : NSObject
- (void)AsyncOnAddMsg:(NSString *)msg MsgWrap:(CMessageWrap *)wrap;
@end

@interface MMServiceCenter : NSObject
+ (instancetype)defaultCenter;
- (id)getService:(Class)service;
@end

@interface CContact : NSObject
@property (retain, nonatomic) NSString *m_nsUsrName;
@property (retain, nonatomic) NSString *m_nsNickName;
@property (retain, nonatomic) NSString *m_nsHeadImgUrl;
- (id)getContactDisplayName;
@end

@interface CContactMgr : NSObject
- (CContact *)getSelfContact;
- (id)getContactByName:(NSString *)name;
@end

// ============================================================
// MARK: - View / Window Helpers
// ============================================================

static UIWindow *XJGetActiveWindow(void) {
    UIWindow *topWindow = nil;
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (scene.activationState != UISceneActivationStateForegroundActive) continue;
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in ((UIWindowScene *)scene).windows) {
            if (!w.hidden && w.windowLevel == UIWindowLevelNormal) {
                topWindow = w;
                break;
            }
        }
        if (topWindow) break;
    }
    if (!topWindow) {
        for (UIWindow *w in [UIApplication sharedApplication].windows) {
            if (!w.hidden && w.windowLevel == UIWindowLevelNormal) {
                topWindow = w;
                break;
            }
        }
    }
    return topWindow;
}

static UIViewController *XJGetTopVC(void) {
    UIWindow *w = XJGetActiveWindow();
    if (!w) return nil;
    UIViewController *vc = w.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    return vc;
}

// ============================================================
// MARK: - 顶部胶囊提示 (深色半透明，简洁单行)
// ============================================================

static void XJShowCard(NSString *title, NSString *message) {
    if (!kVisualFeedback) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *w = XJGetActiveWindow();
        if (!w) return;

        // 合并为单行文本：标题 + 正文（若两者都有）
        NSString *text = nil;
        if (title.length > 0 && message.length > 0) {
            text = [NSString stringWithFormat:@"%@  %@", title, message];
        } else {
            text = title.length > 0 ? title : message;
        }
        if (!text) return;

        CGFloat sw = [UIScreen mainScreen].bounds.size.width;
        CGFloat padX = 16.0, padY = 10.0;
        UIFont *font = [UIFont systemFontOfSize:14];

        CGSize textSize = [text boundingRectWithSize:CGSizeMake(sw - padX * 2 - 24, CGFLOAT_MAX)
                                             options:NSStringDrawingUsesLineFragmentOrigin
                                          attributes:@{NSFontAttributeName: font}
                                             context:nil].size;
        CGFloat cardW = ceil(textSize.width) + padX * 2;
        CGFloat cardH = ceil(textSize.height) + padY * 2;
        cardW = MIN(cardW, sw - 24);   // 不超出屏幕

        CGFloat topInset = 0;
        if (@available(iOS 11.0, *)) topInset = w.safeAreaInsets.top;
        CGFloat cardX = (sw - cardW) / 2.0;
        CGFloat cardY = topInset + 10;

        UIView *card = [[UIView alloc] initWithFrame:CGRectMake(cardX, cardY, cardW, cardH)];
        card.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.78]; // 深色半透明胶囊
        card.layer.cornerRadius = cardH / 2.0;
        card.layer.masksToBounds = YES;
        card.alpha = 0.0;

        UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(padX, padY, cardW - padX * 2, cardH - padY * 2)];
        label.text = text;
        label.textColor = [UIColor whiteColor];
        label.font = font;
        label.textAlignment = NSTextAlignmentCenter;
        label.numberOfLines = 0;
        [card addSubview:label];

        [w addSubview:card];
        // 下滑进入 + 上滑消失
        card.transform = CGAffineTransformMakeTranslation(0, -(cardH + topInset));
        [UIView animateWithDuration:0.28 delay:0
                               options:UIViewAnimationOptionCurveEaseOut
                            animations:^{
            card.alpha = 1.0;
            card.transform = CGAffineTransformIdentity;
        } completion:nil];

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [UIView animateWithDuration:0.3 animations:^{
                card.alpha = 0.0;
                card.transform = CGAffineTransformMakeTranslation(0, -(cardH + topInset));
            } completion:^(BOOL f){ [card removeFromSuperview]; }];
        });
    });
}

// ============================================================
// MARK: - 微信自带提示框（首屏加载提示）
// ============================================================

// 专用的透明提示窗，与微信主窗口/设置页窗口完全隔离，避免触发布局干扰导航栏外观
static __strong UIWindow *xj_toast_window = nil;

static void XJShowWeChatToast(NSString *message) {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            // 微信本体风格：顶部下滑轻提示横幅，数秒后自动滑出消失
            // 关键修复：使用独立 UIWindow（最高层级、透明、不接管 keyWindow），
            // 不再 addSubview 到微信主窗口，避免 [win layoutIfNeeded] 打断设置页导航栏外观提交导致变黑。
            CGFloat bannerH = 52.0;

            if (!xj_toast_window) {
                UIWindow *baseWin = nil;
                if (@available(iOS 13.0, *)) {
                    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
                        if ([scene isKindOfClass:[UIWindowScene class]] &&
                            ((UIWindowScene *)scene).activationState == UISceneActivationStateForegroundActive) {
                            baseWin = ((UIWindowScene *)scene).windows.firstObject;
                            break;
                        }
                    }
                }
                if (!baseWin) baseWin = UIApplication.sharedApplication.keyWindow;

                xj_toast_window = [[UIWindow alloc] initWithFrame:baseWin ? baseWin.bounds : UIScreen.mainScreen.bounds];
                xj_toast_window.backgroundColor = [UIColor clearColor];
                xj_toast_window.windowLevel = UIWindowLevelAlert + 1; // 高于所有页面
                xj_toast_window.userInteractionEnabled = NO;          // 不拦截任何触摸
                xj_toast_window.hidden = NO;
                xj_toast_window.rootViewController = [[UIViewController alloc] init];
                xj_toast_window.rootViewController.view.backgroundColor = [UIColor clearColor];
            }

            UIViewController *root = xj_toast_window.rootViewController;
            UIWindow *win = xj_toast_window;
            CGFloat safeTop = 8.0;
            if (@available(iOS 11.0, *)) safeTop += win.safeAreaInsets.top;

            UIView *banner = [[UIView alloc] init];
            banner.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.78]; // 深色半透明胶囊
            banner.layer.cornerRadius = bannerH / 2.0;
            banner.layer.masksToBounds = YES;
            banner.translatesAutoresizingMaskIntoConstraints = NO;
            [root.view addSubview:banner];

            UILabel *label = [[UILabel alloc] init];
            label.text = message;
            label.font = [UIFont systemFontOfSize:14];
            label.textColor = [UIColor whiteColor];
            label.textAlignment = NSTextAlignmentCenter;
            label.numberOfLines = 0;
            label.lineBreakMode = NSLineBreakByWordWrapping;
            label.translatesAutoresizingMaskIntoConstraints = NO;
            [banner addSubview:label];

            [NSLayoutConstraint activateConstraints:@[
                [banner.leadingAnchor constraintEqualToAnchor:win.leadingAnchor constant:16],
                [banner.trailingAnchor constraintEqualToAnchor:win.trailingAnchor constant:-16],
                [banner.heightAnchor constraintEqualToConstant:bannerH],
                [banner.topAnchor constraintEqualToAnchor:win.topAnchor constant:-(bannerH + safeTop + 16)],
                [label.leadingAnchor constraintEqualToAnchor:banner.leadingAnchor constant:12],
                [label.trailingAnchor constraintEqualToAnchor:banner.trailingAnchor constant:-12],
                [label.topAnchor constraintEqualToAnchor:banner.topAnchor],
                [label.bottomAnchor constraintEqualToAnchor:banner.bottomAnchor],
            ]];

            CGFloat showY = safeTop + 8.0; // 停在状态栏下方
            [UIView animateWithDuration:0.35 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
                banner.transform = CGAffineTransformMakeTranslation(0, bannerH + safeTop + 16 + showY);
            } completion:nil];

            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                [UIView animateWithDuration:0.3 delay:0 options:UIViewAnimationOptionCurveEaseIn animations:^{
                    banner.transform = CGAffineTransformIdentity;
                } completion:^(BOOL f){ [banner removeFromSuperview]; }];
            });
        } @catch (NSException *e) {
            NSLog(@"[PayHook] toast failed: %@", e);
        }
    });
}

// ============================================================
// MARK: - 本地通知 (订单匹配成功等使用)
// ============================================================

@interface XJNotificationDelegate : NSObject <UNUserNotificationCenterDelegate>
@end
@implementation XJNotificationDelegate
- (void)userNotificationCenter:(UNUserNotificationCenter *)center
       willPresentNotification:(UNNotification *)notification
         withCompletionHandler:(void (^)(UNNotificationPresentationOptions))completionHandler {
    if (@available(iOS 14.0, *)) {
        completionHandler(UNNotificationPresentationOptionBanner | UNNotificationPresentationOptionSound | UNNotificationPresentationOptionList);
    } else {
        completionHandler(UNNotificationPresentationOptionAlert | UNNotificationPresentationOptionSound);
    }
}
@end
static XJNotificationDelegate *sNotifDelegate = nil;

static void XJPostLocalNotification(NSString *title, NSString *body) {
    if (@available(iOS 10.0, *)) {
        UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
        UNMutableNotificationContent *content = [[UNMutableNotificationContent alloc] init];
        content.title = title ?: @"";
        content.body = body ?: @"";
        content.sound = [UNNotificationSound defaultSound];
        content.threadIdentifier = @"payhook";
        UNTimeIntervalNotificationTrigger *trigger = [UNTimeIntervalNotificationTrigger triggerWithTimeInterval:1 repeats:NO];
        static int sNid = 0;
        NSString *ident = [NSString stringWithFormat:@"payhook_%d_%lld",
                           sNid++, (long long)([[NSDate date] timeIntervalSince1970] * 1000)];
        UNNotificationRequest *req = [UNNotificationRequest requestWithIdentifier:ident
                                                                         content:content
                                                                         trigger:trigger];
        [center addNotificationRequest:req withCompletionHandler:nil];
    } else {
        XJShowCard(title, body);
    }
}

// ============================================================
// MARK: - 白黑主题通用卡片
// ============================================================

static UIView *XJCard(void) {
    UIView *c = [[UIView alloc] init];
    c.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    c.layer.cornerRadius = 14;
    c.layer.shadowColor = [UIColor blackColor].CGColor;
    c.layer.shadowOpacity = 0.06;
    c.layer.shadowRadius = 8;
    c.layer.shadowOffset = CGSizeMake(0, 2);
    c.translatesAutoresizingMaskIntoConstraints = NO;
    return c;
}

static UIView *XJCardWithStack(UIStackView **outStack) {
    UIView *c = XJCard();
    UIStackView *s = [[UIStackView alloc] init];
    s.axis = UILayoutConstraintAxisVertical;
    s.spacing = 12;
    s.translatesAutoresizingMaskIntoConstraints = NO;
    [c addSubview:s];
    [NSLayoutConstraint activateConstraints:@[
        [s.topAnchor constraintEqualToAnchor:c.topAnchor constant:16],
        [s.leadingAnchor constraintEqualToAnchor:c.leadingAnchor constant:16],
        [s.trailingAnchor constraintEqualToAnchor:c.trailingAnchor constant:-16],
        [s.bottomAnchor constraintEqualToAnchor:c.bottomAnchor constant:-16],
    ]];
    if (outStack) *outStack = s;
    return c;
}

// 浅色清爽风强调色：黑 (白黑配，纯黑强调)
static UIColor *XJAccent(void) {
    return [UIColor blackColor];
}

// ============================================================
// MARK: - 设置页面 (独立 UIViewController, 浅色清爽风)
// ============================================================

@interface XJSettingsViewController : UIViewController <UITextFieldDelegate>
@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) UIStackView  *stack;
@property (nonatomic, strong) UITextField  *urlField;
@property (nonatomic, strong) UITextField  *nameField;
@property (nonatomic, strong) UITextField  *secretField;
@property (nonatomic, strong) UISwitch     *debugSwitch;
@property (nonatomic, strong) UISwitch     *visualSwitch;
@property (nonatomic, strong) NSMutableDictionary<NSString*,UILabel*> *xjStatLabels;
- (UIView *)xj_statUnitWithLabel:(NSString *)label key:(NSString *)key;
- (UIView *)xj_kvRowToStack:(UIStackView *)stack key:(NSString *)key label:(NSString *)label;
- (UIView *)xj_hairline;
- (void)xj_refreshStatus;
@end

@interface XJAuthorViewController : UIViewController
@end

@implementation XJSettingsViewController

- (void)xj_applyNavBarStyle {
    // 非透明导航栏：浅色=纯白底+黑字，深色=深灰底+白字（由 barStyle 决定状态栏文字）
    if (self.navigationController && self.navigationController.navigationBar) {
        XJApplyNavBarStyleForTrait(self.navigationController.navigationBar, self.traitCollection, NO);
    }
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self xj_applyNavBarStyle];
    [self setNeedsStatusBarAppearanceUpdate];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self xj_applyNavBarStyle]; // 兜底：布局完成后再次确认，防止状态栏/外观刷新导致闪黑
}

- (void)viewDidLoad {
    [super viewDidLoad];
    // 跟随系统深浅色：背景/文字全部使用 adaptive 系统色，不再强制 overrideUserInterfaceStyle。
    // 微信深色模式下页面自动变深、浅色模式自动变浅。
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
    // 导航栏即头部：自定义 titleView（品牌名 + 副标题），与下方卡片合并
    UIView *tv = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 220, 38)];
    tv.backgroundColor = [UIColor clearColor];
    UILabel *t1 = [[UILabel alloc] init];
    t1.text = XJ_T(@"UGF5SG9vayDorr7nva4=");
    t1.font = [UIFont boldSystemFontOfSize:17];
    t1.textColor = [UIColor labelColor];
    t1.textAlignment = NSTextAlignmentCenter;
    t1.translatesAutoresizingMaskIntoConstraints = NO;
    UILabel *t2 = [[UILabel alloc] init];
    t2.text = [NSString stringWithFormat:XJ_T(@"5b6u5L+h5pS25qy+55uR5o6nIMK3ICVA"), kXJAuthor];
    t2.font = [UIFont systemFontOfSize:11];
    t2.textColor = XJAdaptiveSubColor();
    t2.textAlignment = NSTextAlignmentCenter;
    t2.translatesAutoresizingMaskIntoConstraints = NO;
    [tv addSubview:t1];
    [tv addSubview:t2];
    [NSLayoutConstraint activateConstraints:@[
        [t1.topAnchor constraintEqualToAnchor:tv.topAnchor],
        [t1.leadingAnchor constraintEqualToAnchor:tv.leadingAnchor],
        [t1.trailingAnchor constraintEqualToAnchor:tv.trailingAnchor],
        [t2.topAnchor constraintEqualToAnchor:t1.bottomAnchor constant:1],
        [t2.leadingAnchor constraintEqualToAnchor:tv.leadingAnchor],
        [t2.trailingAnchor constraintEqualToAnchor:tv.trailingAnchor],
        [t2.bottomAnchor constraintEqualToAnchor:tv.bottomAnchor],
    ]];
    self.navigationItem.titleView = tv;

    UIBarButtonItem *close = [[UIBarButtonItem alloc] initWithTitle:XJ_T(@"5YWz6Zet")
                                                              style:UIBarButtonItemStyleDone
                                                             target:self
                                                             action:@selector(closeSettings)];
    self.navigationItem.leftBarButtonItem = close;

    UIScrollView *scroll = [[UIScrollView alloc] init];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.alwaysBounceVertical = YES;
    scroll.backgroundColor = [UIColor clearColor];
    [self.view addSubview:scroll];
    self.scrollView = scroll;

    UIStackView *stack = [[UIStackView alloc] init];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 14;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:stack];
    self.stack = stack;

    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [stack.topAnchor constraintEqualToAnchor:scroll.topAnchor constant:16],
        [stack.leadingAnchor constraintEqualToAnchor:scroll.leadingAnchor constant:16],
        [stack.trailingAnchor constraintEqualToAnchor:scroll.trailingAnchor constant:-16],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.bottomAnchor constant:-16],
        [stack.widthAnchor constraintEqualToAnchor:scroll.widthAnchor constant:-32],
    ]];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self
                                                                          action:@selector(dismissKeyboard)];
    [scroll addGestureRecognizer:tap];

    [self buildUI];
}

- (void)dismissKeyboard { [self.view endEditing:YES]; }

- (void)closeSettings {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (UIStatusBarStyle)preferredStatusBarStyle {
    if (@available(iOS 13.0, *)) {
        return XJStatusBarStyleForTrait(self.traitCollection);
    }
    return UIStatusBarStyleDefault;
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    if (@available(iOS 13.0, *)) {
        if ([self.traitCollection hasDifferentColorAppearanceComparedToTraitCollection:previousTraitCollection]) {
            [self setNeedsStatusBarAppearanceUpdate];
            [self xj_applyNavBarStyle];
        }
    }
}

- (BOOL)prefersStatusBarHidden { return NO; }

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    // 已按需求取消「加载配置提示框」：该 toast 会触发布局时序问题，且
    // overrideUserInterfaceStyle + modalPresentationCapturesStatusBarAppearance 在微信环境下
    // 会导致导航栏底色回落为黑色。不再弹提示。
    // 兜底：微信可能在 present 完成后才写入自己的 navBar appearance，
    // 这里在 viewDidAppear 再锁一次，确保不被覆盖成黑底。
    if (self.navigationController && self.navigationController.navigationBar) {
        XJApplyNavBarStyleForTrait(self.navigationController.navigationBar, self.traitCollection, NO);
    }
}

#pragma mark - UI Build

- (void)buildUI {
    // 头部已合并进导航栏（自定义 titleView），此处不再单独放“PayHook”卡片

    // 订单列表 入口（查看插件已捕获的收款订单）
    [self.stack addArrangedSubview:[self orderEntryRow]];

    // 运行状态卡片
    UIStackView *statStack = nil;
    UIView *statCard = XJCardWithStack(&statStack);
    UILabel *statTitle = [[UILabel alloc] init];
    statTitle.text = XJ_T(@"6L+Q6KGM54q25oCB");
    statTitle.font = [UIFont boldSystemFontOfSize:15];
    statTitle.textColor = [UIColor labelColor];
    statTitle.translatesAutoresizingMaskIntoConstraints = NO;
    [statStack addArrangedSubview:statTitle];

    // 运行状态：两列统计网格 + 下方明细行（服务器地址单行省略号截断）
    self.xjStatLabels = [NSMutableDictionary dictionary];

    UIStackView *colA = [[UIStackView alloc] init];
    colA.axis = UILayoutConstraintAxisVertical; colA.spacing = 14; colA.distribution = UIStackViewDistributionFill;
    UIStackView *colB = [[UIStackView alloc] init];
    colB.axis = UILayoutConstraintAxisVertical; colB.spacing = 14; colB.distribution = UIStackViewDistributionFill;
    [colA addArrangedSubview:[self xj_statUnitWithLabel:XJ_T(@"6K+G5Yir5qyh5pWw") key:@"detected"]];
    [colA addArrangedSubview:[self xj_statUnitWithLabel:XJ_T(@"5LiK5oql5oiQ5Yqf") key:@"sent"]];
    [colA addArrangedSubview:[self xj_statUnitWithLabel:XJ_T(@"5Yy56YWN") key:@"matched"]];
    [colB addArrangedSubview:[self xj_statUnitWithLabel:XJ_T(@"5aSx6LSl") key:@"failed"]];
    [colB addArrangedSubview:[self xj_statUnitWithLabel:XJ_T(@"5Y676YeN6Lez6L+H") key:@"dedup"]];
    [colB addArrangedSubview:[self xj_statUnitWithLabel:XJ_T(@"WE1M6Kej5p6Q") key:@"xml"]];

    UIStackView *grid = [[UIStackView alloc] initWithArrangedSubviews:@[colA, colB]];
    grid.axis = UILayoutConstraintAxisHorizontal;
    grid.distribution = UIStackViewDistributionFillEqually;
    grid.spacing = 18;
    [statStack addArrangedSubview:grid];

    [statStack addArrangedSubview:[self xj_hairline]];

    [self xj_kvRowToStack:statStack key:@"source"   label:XJ_T(@"5qOA5rWL5p2l5rqQ")];
    [self xj_kvRowToStack:statStack key:@"recent"   label:XJ_T(@"5pyA6L+R5LiK5oql")];
    [self xj_kvRowToStack:statStack key:@"lastmatch" label:XJ_T(@"5pyA6L+R5Yy56YWN")];
    [self xj_kvRowToStack:statStack key:@"server"   label:XJ_T(@"5pyN5Yqh5Zmo")];
    [self xj_kvRowToStack:statStack key:@"monitor"  label:XJ_T(@"55uR5o6n5ZCN")];
    [self xj_kvRowToStack:statStack key:@"flags"    label:XJ_T(@"6LCD6K+VL+W8ueeqly/ljrvph40=")];
    [self xj_kvRowToStack:statStack key:@"remote"   label:XJ_T(@"6L+c56iL6YWN572uL+WFs+mUruivjQ==")];

    [self xj_refreshStatus];
    [self.stack addArrangedSubview:statCard];

    // 服务器配置卡片
    UIStackView *cfgStack = nil;
    UIView *cfgCard = XJCardWithStack(&cfgStack);
    UILabel *cfgTitle = [[UILabel alloc] init];
    cfgTitle.text = XJ_T(@"5pyN5Yqh5Zmo6YWN572u");
    cfgTitle.font = [UIFont boldSystemFontOfSize:15];
    cfgTitle.textColor = [UIColor labelColor];
    cfgTitle.translatesAutoresizingMaskIntoConstraints = NO;
    [cfgStack addArrangedSubview:cfgTitle];

    [cfgStack addArrangedSubview:[self configRowWithIcon:@"globe" label:XJ_T(@"5pyN5Yqh5Zmo5Zyw5Z2A") placeholder:@"http://..." text:kServerURL field:&_urlField secure:NO]];
    [cfgStack addArrangedSubview:[self separator]];
    [cfgStack addArrangedSubview:[self configRowWithIcon:@"iphone" label:XJ_T(@"55uR5o6n56uv5ZCN56ew") placeholder:@"iOS-Hook-01" text:kMonitorName field:&_nameField secure:NO]];
    [cfgStack addArrangedSubview:[self separator]];
    [cfgStack addArrangedSubview:[self configRowWithIcon:@"key" label:XJ_T(@"55uR5o6n5a+G6ZKl") placeholder:@"monitor_secret" text:kMonitorSecret field:&_secretField secure:YES]];
    [self.stack addArrangedSubview:cfgCard];

    // 偏好设置卡片
    UIStackView *tgStack = nil;
    UIView *tgCard = XJCardWithStack(&tgStack);
    [tgStack addArrangedSubview:[self toggleRow:XJ_T(@"6LCD6K+V5pel5b+X") on:kDebugEnabled switchRef:&_debugSwitch]];
    [tgStack addArrangedSubview:[self separator]];
    [tgStack addArrangedSubview:[self toggleRow:XJ_T(@"5by556qX5o+Q56S6") on:kVisualFeedback switchRef:&_visualSwitch]];
    [self.stack addArrangedSubview:tgCard];

    // 操作版块（收进一个卡片）
    UIStackView *opStack = nil;
    UIView *opCard = XJCardWithStack(&opStack);
    UILabel *opTitle = [[UILabel alloc] init];
    opTitle.text = XJ_T(@"5pON5L2c");
    opTitle.font = [UIFont boldSystemFontOfSize:15];
    opTitle.textColor = [UIColor labelColor];
    opTitle.translatesAutoresizingMaskIntoConstraints = NO;
    [opStack addArrangedSubview:opTitle];
    [opStack addArrangedSubview:[self actionButton:XJ_T(@"5L+d5a2Y6YWN572u") primary:YES action:@selector(saveConfig)]];
    [opStack addArrangedSubview:[self separator]];
    [opStack addArrangedSubview:[self actionButton:XJ_T(@"5Y+R6YCB5rWL6K+V5LiK5oqlICgwLjAx5YWDKQ==") primary:NO action:@selector(sendTest)]];
    [opStack addArrangedSubview:[self separator]];
    [opStack addArrangedSubview:[self actionButton:XJ_T(@"5by65Yi25Yi35paw6L+c56iL6YWN572u") primary:NO action:@selector(refreshRemote)]];
    [opStack addArrangedSubview:[self separator]];
    [opStack addArrangedSubview:[self actionButton:XJ_T(@"5riF56m65raI5oGv6K6w5b2V") primary:NO action:@selector(clearLog)]];
    [opStack addArrangedSubview:[self separator]];
    [opStack addArrangedSubview:[self actionButton:XJ_T(@"6YeN572u57uf6K6h5pWw5o2u") primary:NO action:@selector(resetStats)]];
    [opStack addArrangedSubview:[self separator]];
    [opStack addArrangedSubview:[self actionButton:XJ_T(@"5YWz5LqO5L2c6ICF") primary:NO subtitle:kXJAuthor action:@selector(openAuthor)]];
    [self.stack addArrangedSubview:opCard];

    UILabel *foot = [[UILabel alloc] init];
    foot.text = [NSString stringWithFormat:XJ_T(@"UGF5SG9vayB2My4wIMK3ICVA"), kXJAuthor];
    foot.font = [UIFont systemFontOfSize:11];
    foot.textColor = [UIColor colorWithRed:0.70 green:0.70 blue:0.72 alpha:1];
    foot.textAlignment = NSTextAlignmentCenter;
    foot.translatesAutoresizingMaskIntoConstraints = NO;
    [self.stack addArrangedSubview:foot];
}

// 通用入口行工厂（卡片 + 头像 + 文字 + 箭头）
- (UIView *)xj_makeEntryIcon:(NSString *)icon title:(NSString *)title subtitle:(NSString *)subtitle action:(SEL)action {
    UIButton *card = [UIButton buttonWithType:UIButtonTypeCustom];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    card.layer.cornerRadius = 14;
    card.layer.masksToBounds = NO;
    card.layer.shadowColor = [UIColor blackColor].CGColor;
    card.layer.shadowOpacity = 0.06;
    card.layer.shadowRadius = 8;
    card.layer.shadowOffset = CGSizeMake(0, 2);
    [card addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [card addTarget:card action:@selector(xj_touchDown:) forControlEvents:UIControlEventTouchDown];
    [card addTarget:card action:@selector(xj_touchUp:) forControlEvents:(UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel)];

    CGFloat iconSize = 32;
    UIView *iconBg = [[UIView alloc] init];
    iconBg.translatesAutoresizingMaskIntoConstraints = NO;
    iconBg.backgroundColor = XJAccent();
    iconBg.layer.cornerRadius = iconSize / 2.0;
    iconBg.layer.masksToBounds = YES;
    [card addSubview:iconBg];
    UILabel *iconLabel = [[UILabel alloc] init];
    iconLabel.text = icon;
    iconLabel.font = [UIFont boldSystemFontOfSize:18];
    iconLabel.textColor = [UIColor whiteColor];
    iconLabel.textAlignment = NSTextAlignmentCenter;
    iconLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [iconBg addSubview:iconLabel];
    [NSLayoutConstraint activateConstraints:@[
        [iconBg.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:14],
        [iconBg.centerYAnchor constraintEqualToAnchor:card.centerYAnchor],
        [iconBg.widthAnchor constraintEqualToConstant:iconSize],
        [iconBg.heightAnchor constraintEqualToConstant:iconSize],
        [iconLabel.topAnchor constraintEqualToAnchor:iconBg.topAnchor],
        [iconLabel.leadingAnchor constraintEqualToAnchor:iconBg.leadingAnchor],
        [iconLabel.trailingAnchor constraintEqualToAnchor:iconBg.trailingAnchor],
        [iconLabel.bottomAnchor constraintEqualToAnchor:iconBg.bottomAnchor],
    ]];

    UILabel *mainLabel = [[UILabel alloc] init];
    mainLabel.text = title;
    mainLabel.font = [UIFont boldSystemFontOfSize:15];
    mainLabel.textColor = [UIColor labelColor];
    mainLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:mainLabel];

    UILabel *subLabel = [[UILabel alloc] init];
    subLabel.text = subtitle;
    subLabel.font = [UIFont systemFontOfSize:12];
    subLabel.textColor = [UIColor colorWithRed:0.55 green:0.55 blue:0.57 alpha:1];
    subLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:subLabel];

    [NSLayoutConstraint activateConstraints:@[
        [mainLabel.leadingAnchor constraintEqualToAnchor:iconBg.trailingAnchor constant:12],
        [mainLabel.topAnchor constraintEqualToAnchor:card.topAnchor constant:14],
        [mainLabel.trailingAnchor constraintLessThanOrEqualToAnchor:card.trailingAnchor constant:-30],
        [subLabel.leadingAnchor constraintEqualToAnchor:mainLabel.leadingAnchor],
        [subLabel.topAnchor constraintEqualToAnchor:mainLabel.bottomAnchor constant:2],
        [subLabel.trailingAnchor constraintLessThanOrEqualToAnchor:card.trailingAnchor constant:-30],
        [card.heightAnchor constraintEqualToConstant:60],
    ]];

    UIImageView *chevron = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"chevron.right"]];
    if (!chevron.image) {
        UILabel *chevLbl = [[UILabel alloc] init];
        chevLbl.text = XJ_T(@"4oC6");
        chevLbl.font = [UIFont systemFontOfSize:20 weight:UIFontWeightLight];
        chevLbl.textColor = [UIColor tertiaryLabelColor];
        chevLbl.textAlignment = NSTextAlignmentCenter;
        chevLbl.translatesAutoresizingMaskIntoConstraints = NO;
        [card addSubview:chevLbl];
        [NSLayoutConstraint activateConstraints:@[
            [chevLbl.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-14],
            [chevLbl.centerYAnchor constraintEqualToAnchor:card.centerYAnchor],
        ]];
    } else {
        chevron.translatesAutoresizingMaskIntoConstraints = NO;
        chevron.tintColor = [UIColor tertiaryLabelColor];
        [card addSubview:chevron];
        [NSLayoutConstraint activateConstraints:@[
            [chevron.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-14],
            [chevron.centerYAnchor constraintEqualToAnchor:card.centerYAnchor],
            [chevron.widthAnchor constraintEqualToConstant:9],
            [chevron.heightAnchor constraintEqualToConstant:14],
        ]];
    }
    return card;
}

// 订单列表 入口行
- (UIView *)orderEntryRow {
    NSInteger n = [[XJOrderStore sharedInstance] count];
    return [self xj_makeEntryIcon:XJ_T(@"8J+nvg==") title:XJ_T(@"6K6i5Y2V5YiX6KGo") subtitle:[NSString stringWithFormat:XJ_T(@"5bey5o2V6I63ICVsZCDnrJTmlLbmrL4="), (long)n] action:@selector(openOrders)];
}

- (void)openOrders {
    XJOrderListViewController *vc = [[XJOrderListViewController alloc] init];
    vc.title = XJ_T(@"6K6i5Y2V5YiX6KGo");
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)openAuthor {
    XJAuthorViewController *vc = [[XJAuthorViewController alloc] init];
    vc.title = XJ_T(@"5YWz5LqO5L2c6ICF");
    [self.navigationController pushViewController:vc animated:YES];
}

- (UIView *)separator {
    UIView *s = [[UIView alloc] init];
    s.backgroundColor = [UIColor colorWithRed:0.93 green:0.93 blue:0.95 alpha:1];
    s.translatesAutoresizingMaskIntoConstraints = NO;
    [s.heightAnchor constraintEqualToConstant:1].active = YES;
    return s;
}

- (UIView *)configRowWithIcon:(NSString *)sfSymbol label:(NSString *)label placeholder:(NSString *)ph text:(NSString *)text field:(UITextField *__strong *)outField secure:(BOOL)secure {
    UIView *row = [[UIView alloc] init];
    row.translatesAutoresizingMaskIntoConstraints = NO;

    // 左侧图标（SF Symbols 单色，失败则隐藏，不破坏布局）
    UIView *iconBox = [[UIView alloc] init];
    iconBox.translatesAutoresizingMaskIntoConstraints = NO;
    iconBox.backgroundColor = [UIColor colorWithRed:0.95 green:0.95 blue:0.96 alpha:1];
    iconBox.layer.cornerRadius = 7;
    iconBox.layer.masksToBounds = YES;
    UIImage *img = nil;
    @try {
        if ([UIImage respondsToSelector:@selector(systemImageNamed:)]) {
            img = [UIImage systemImageNamed:sfSymbol];
        }
    } @catch (NSException *e) { img = nil; }
    UIImageView *iv = [[UIImageView alloc] initWithImage:img];
    iv.contentMode = UIViewContentModeScaleAspectFit;
    iv.tintColor = [UIColor colorWithRed:0.40 green:0.40 blue:0.43 alpha:1];
    iv.translatesAutoresizingMaskIntoConstraints = NO;
    [iconBox addSubview:iv];
    [NSLayoutConstraint activateConstraints:@[
        [iv.centerXAnchor constraintEqualToAnchor:iconBox.centerXAnchor],
        [iv.centerYAnchor constraintEqualToAnchor:iconBox.centerYAnchor],
        [iv.widthAnchor constraintEqualToConstant:15],
        [iv.heightAnchor constraintEqualToConstant:15],
    ]];
    if (!img) { iconBox.hidden = YES; }

    UILabel *l = [[UILabel alloc] init];
    l.text = label;
    l.font = [UIFont systemFontOfSize:14];
    l.textColor = [UIColor colorWithRed:0.40 green:0.40 blue:0.43 alpha:1];
    l.translatesAutoresizingMaskIntoConstraints = NO;

    UITextField *tf = [[UITextField alloc] init];
    tf.placeholder = ph;
    tf.text = text;
    tf.font = [UIFont systemFontOfSize:14];
    tf.textColor = [UIColor labelColor];
    tf.borderStyle = UITextBorderStyleNone;
    tf.clearButtonMode = UITextFieldViewModeWhileEditing;
    tf.textAlignment = NSTextAlignmentRight;
    tf.delegate = self;
    tf.secureTextEntry = secure;
    tf.adjustsFontSizeToFitWidth = NO;   // 超长文本：单行，超出部分被裁剪/横向滚动隐藏，不再缩放或换行
    tf.clipsToBounds = YES;
    tf.translatesAutoresizingMaskIntoConstraints = NO;

    // 密钥行：右侧眼睛切换按钮（默认掩码，点一下看明文）
    UIButton *eye = nil;
    if (secure) {
        eye = [UIButton buttonWithType:UIButtonTypeCustom];
        eye.translatesAutoresizingMaskIntoConstraints = NO;
        UIImage *e1 = nil, *e2 = nil;
        @try {
            if ([UIImage respondsToSelector:@selector(systemImageNamed:)]) {
                e1 = [UIImage systemImageNamed:@"eye"];
                e2 = [UIImage systemImageNamed:@"eye.slash"];
            }
        } @catch (NSException *e) {}
        [eye setImage:e1 forState:UIControlStateNormal];
        [eye setImage:(e2 ?: e1) forState:UIControlStateSelected];
        eye.tintColor = [UIColor colorWithRed:0.55 green:0.55 blue:0.57 alpha:1];
        [eye addTarget:self action:@selector(xj_toggleSecret:) forControlEvents:UIControlEventTouchUpInside];
    }

    [row addSubview:iconBox];
    [row addSubview:l];
    [row addSubview:tf];
    if (eye) [row addSubview:eye];

    NSMutableArray *cons = [NSMutableArray array];
    if (img) {
        [cons addObjectsFromArray:@[
            [iconBox.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
            [iconBox.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
            [iconBox.widthAnchor constraintEqualToConstant:28],
            [iconBox.heightAnchor constraintEqualToConstant:28],
            [l.leadingAnchor constraintEqualToAnchor:iconBox.trailingAnchor constant:10],
        ]];
    } else {
        [cons addObject:[l.leadingAnchor constraintEqualToAnchor:row.leadingAnchor]];
    }
    [cons addObjectsFromArray:@[
        [l.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [l.widthAnchor constraintLessThanOrEqualToConstant:88],
        [tf.leadingAnchor constraintEqualToAnchor:l.trailingAnchor constant:12],
        [tf.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [row.heightAnchor constraintEqualToConstant:48],
    ]];
    if (eye) {
        [cons addObjectsFromArray:@[
            [eye.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
            [eye.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
            [eye.widthAnchor constraintEqualToConstant:28],
            [eye.heightAnchor constraintEqualToConstant:28],
            [tf.trailingAnchor constraintEqualToAnchor:eye.leadingAnchor constant:-8],
        ]];
    } else {
        [cons addObject:[tf.trailingAnchor constraintEqualToAnchor:row.trailingAnchor]];
    }
    [NSLayoutConstraint activateConstraints:cons];
    if (outField) *outField = tf;
    return row;
}

- (void)xj_toggleSecret:(UIButton *)sender {
    _secretField.secureTextEntry = !_secretField.secureTextEntry;
    sender.selected = !_secretField.secureTextEntry;
}

- (UIView *)toggleRow:(NSString *)title on:(BOOL)on switchRef:(UISwitch *__strong *)outSw {
    UIView *row = [[UIView alloc] init];
    row.translatesAutoresizingMaskIntoConstraints = NO;

    UILabel *l = [[UILabel alloc] init];
    l.text = title;
    l.font = [UIFont systemFontOfSize:15];
    l.textColor = [UIColor labelColor];
    l.translatesAutoresizingMaskIntoConstraints = NO;

    UISwitch *sw = [[UISwitch alloc] init];
    sw.on = on;
    sw.onTintColor = XJAccent();
    sw.translatesAutoresizingMaskIntoConstraints = NO;

    [row addSubview:l];
    [row addSubview:sw];
    [NSLayoutConstraint activateConstraints:@[
        [l.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
        [l.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [sw.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
        [sw.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [row.heightAnchor constraintEqualToConstant:44],
    ]];
    if (outSw) *outSw = sw;
    return row;
}

- (UIButton *)actionButton:(NSString *)title primary:(BOOL)primary subtitle:(NSString *)subtitle action:(SEL)action {
    // 操作版块内的列表行样式：左对齐标题 + 右侧灰色 › + 细分割线，更贴近 iOS 原生设置
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    b.translatesAutoresizingMaskIntoConstraints = NO;
    b.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    b.backgroundColor = [UIColor clearColor];
    [b setTitle:title forState:UIControlStateNormal];
    b.titleLabel.font = primary ? [UIFont boldSystemFontOfSize:16] : [UIFont systemFontOfSize:16];
    [b setTitleColor:[UIColor labelColor] forState:UIControlStateNormal];
    b.titleEdgeInsets = UIEdgeInsetsMake(0, 4, 0, 0);
    // 右侧 chevron
    UILabel *chev = [[UILabel alloc] init];
    chev.text = XJ_T(@"4oC6");
    chev.font = [UIFont systemFontOfSize:18];
    chev.textColor = [UIColor colorWithRed:0.77 green:0.77 blue:0.80 alpha:1];
    chev.translatesAutoresizingMaskIntoConstraints = NO;
    [b addSubview:chev];
    [NSLayoutConstraint activateConstraints:@[
        [chev.centerYAnchor constraintEqualToAnchor:b.centerYAnchor],
        [chev.trailingAnchor constraintEqualToAnchor:b.trailingAnchor constant:-4],
    ]];
    // 可选：右侧副标题（chevron 左侧的灰色小字）
    if (subtitle.length > 0) {
        UILabel *sub = [[UILabel alloc] init];
        sub.text = subtitle;
        sub.font = [UIFont systemFontOfSize:12];
        sub.textColor = [UIColor colorWithRed:0.55 green:0.55 blue:0.57 alpha:1];
        sub.translatesAutoresizingMaskIntoConstraints = NO;
        [b addSubview:sub];
        [NSLayoutConstraint activateConstraints:@[
            [sub.centerYAnchor constraintEqualToAnchor:b.centerYAnchor],
            [sub.trailingAnchor constraintEqualToAnchor:chev.leadingAnchor constant:-6],
        ]];
    }
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [b.heightAnchor constraintEqualToConstant:46].active = YES;
    return b;
}

// 便捷方法：无副标题
- (UIButton *)actionButton:(NSString *)title primary:(BOOL)primary action:(SEL)action {
    return [self actionButton:title primary:primary subtitle:nil action:action];
}

#pragma mark - Actions

- (void)saveConfig {
    [self dismissKeyboard];
    BOOL changed = NO;
    if (_urlField.text.length > 0 && ![_urlField.text isEqualToString:kServerURL]) { kServerURL = [_urlField.text copy]; changed = YES; }
    if (_nameField.text.length > 0 && ![_nameField.text isEqualToString:kMonitorName]) { kMonitorName = [_nameField.text copy]; changed = YES; }
    if (_secretField.text.length > 0 && ![_secretField.text isEqualToString:kMonitorSecret]) { kMonitorSecret = [_secretField.text copy]; changed = YES; }
    kDebugEnabled = _debugSwitch.on;
    kVisualFeedback = _visualSwitch.on;
    XJSaveConfig();
    [self refreshStatus];
    XJShowCard(XJ_T(@"6YWN572u5bey5L+d5a2Y"), changed ? [NSString stringWithFormat:XJ_T(@"5pyN5Yqh5ZmoOiAlQFxu6YeN5ZCv5b6u5L+h5ZCO5a6M5YWo55Sf5pWI"), kServerURL]
                                       : XJ_T(@"5omA5pyJ5a2X5q615LiO5b2T5YmN5LiA6Ie0"));
}

- (void)sendTest {
    NSDictionary *testExtra = @{ @"pay_type": @"wechat", @"detection_method": @"test", @"from_user": @"test" };
    XJReportPaymentEnhanced(@"0.01", XJ_T(@"W1RFU1RdIOW+ruS/oeaUr+S7mOaUtuasviDvv6UwLjAx"), testExtra);
    XJShowCard(XJ_T(@"5rWL6K+V5LiK5oql"), XJ_T(@"5bey5Y+R6YCBIDAuMDEg5YWD5rWL6K+V5Yiw5pyN5Yqh56uv"));
}

- (void)refreshRemote {
    [[XJRemoteConfig sharedInstance] forceRefresh];
    XJShowCard(XJ_T(@"6L+c56iL6YWN572u"), XJ_T(@"5q2j5Zyo5ZCO5Y+w5Yi35pawLi4u"));
}

- (void)clearLog {
    sMsgLogCount = 0; sMsgLogIndex = 0;
    memset(sMsgLog, 0, sizeof(sMsgLog));
    [self refreshStatus];
    XJShowCard(XJ_T(@"5bey5riF56m6"), XJ_T(@"5raI5oGv6K6w5b2V5bey5riF6Zmk"));
}

- (void)resetStats {
    sHookFiredCount = 0; sPaymentDetected = 0; sReportSent = 0;
    sReportMatched = 0; sReportFailed = 0; sMessageWrapFired = 0;
    sCMessageMgrFired = 0; sDedupSkipped = 0; sXMLParsed = 0; sSourceMatched = 0;
    [[XJMessageDedup sharedInstance] clearCache];
    [self refreshStatus];
    XJShowCard(XJ_T(@"5bey6YeN572u"), XJ_T(@"5omA5pyJ57uf6K6h5pWw5o2u5bey5riF6Zu2"));
}

- (void)refreshStatus {
    [self xj_refreshStatus];
}

#pragma mark - 运行状态卡片辅助

- (UIView *)xj_statUnitWithLabel:(NSString *)label key:(NSString *)key {
    UIStackView *unit = [[UIStackView alloc] init];
    unit.axis = UILayoutConstraintAxisVertical;
    unit.spacing = 3;
    unit.alignment = UIStackViewAlignmentLeading;
    UILabel *l = [[UILabel alloc] init];
    l.text = label;
    l.font = [UIFont systemFontOfSize:11];
    l.textColor = XJAdaptiveSubColor();
    UILabel *v = [[UILabel alloc] init];
    v.font = [UIFont boldSystemFontOfSize:17];
    v.textColor = [UIColor labelColor];
    v.adjustsFontSizeToFitWidth = YES;
    v.minimumFontSize = 12;
    [unit addArrangedSubview:l];
    [unit addArrangedSubview:v];
    if (key) self.xjStatLabels[key] = v;
    return unit;
}

- (UIView *)xj_kvRowToStack:(UIStackView *)stack key:(NSString *)key label:(NSString *)label {
    UIStackView *row = [[UIStackView alloc] init];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.alignment = UIStackViewAlignmentCenter;
    row.distribution = UIStackViewDistributionEqualSpacing;
    UILabel *l = [[UILabel alloc] init];
    l.text = label;
    l.font = [UIFont systemFontOfSize:12];
    l.textColor = XJAdaptiveSubColor();
    UILabel *v = [[UILabel alloc] init];
    v.font = [UIFont systemFontOfSize:12];
    v.textColor = [UIColor labelColor];
    v.lineBreakMode = NSLineBreakByTruncatingTail;
    v.numberOfLines = 1;
    [v setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    [row addArrangedSubview:l];
    [row addArrangedSubview:v];
    [stack addArrangedSubview:row];
    if (key) self.xjStatLabels[key] = v;
    return row;
}

- (UIView *)xj_hairline {
    UIView *sep = [[UIView alloc] init];
    sep.backgroundColor = [UIColor colorWithRed:0.93 green:0.93 blue:0.95 alpha:1];
    sep.translatesAutoresizingMaskIntoConstraints = NO;
    [sep.heightAnchor constraintEqualToConstant:1].active = YES;
    return sep;
}

- (void)xj_refreshStatus {
    if (!self.xjStatLabels.count) return;
    NSDictionary<NSString*,NSString*> *d = XJBuildStatusDict();
    for (NSString *k in d) {
        UILabel *lb = self.xjStatLabels[k];
        if (lb) lb.text = d[k];
    }
}

#pragma mark - UITextFieldDelegate

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}

@end

// ============================================================
// MARK: - 作者介绍页 (XJAuthorViewController)
// ============================================================

@implementation XJAuthorViewController

- (void)xj_applyNavBarStyle {
    // 半透明毛玻璃风格（作者页）：浅色=白半透+黑字，深色=深灰半透+白字
    if (self.navigationController && self.navigationController.navigationBar) {
        XJApplyNavBarStyleForTrait(self.navigationController.navigationBar, self.traitCollection, YES);
    }
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self xj_applyNavBarStyle];
    [self setNeedsStatusBarAppearanceUpdate];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self xj_applyNavBarStyle];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor]; // 跟随系统深浅色
    self.title = XJ_T(@"5YWz5LqO5L2c6ICF");

    UIScrollView *scroll = [[UIScrollView alloc] init];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.alwaysBounceVertical = YES;
    scroll.backgroundColor = [UIColor clearColor];
    [self.view addSubview:scroll];

    UIStackView *stack = [[UIStackView alloc] init];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 14;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:stack];

    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [stack.topAnchor constraintEqualToAnchor:scroll.topAnchor constant:16],
        [stack.leadingAnchor constraintEqualToAnchor:scroll.leadingAnchor constant:16],
        [stack.trailingAnchor constraintEqualToAnchor:scroll.trailingAnchor constant:-16],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.bottomAnchor constant:-16],
        [stack.widthAnchor constraintEqualToAnchor:scroll.widthAnchor constant:-32],
    ]];

    // 作者头像卡片（居中）
    UIStackView *avaStack = nil;
    UIView *avaCard = XJCardWithStack(&avaStack);
    avaStack.alignment = UIStackViewAlignmentCenter;
    avaStack.spacing = 10;

    CGFloat iconSize = 64;
    UIView *avatar = [[UIView alloc] init];
    avatar.translatesAutoresizingMaskIntoConstraints = NO;
    avatar.backgroundColor = XJAccent();
    avatar.layer.cornerRadius = iconSize / 2.0;
    avatar.layer.masksToBounds = YES;
    [avatar.widthAnchor constraintEqualToConstant:iconSize].active = YES;
    [avatar.heightAnchor constraintEqualToConstant:iconSize].active = YES;
    UILabel *avatarLabel = [[UILabel alloc] init];
    avatarLabel.text = XJ_T(@"wqU=");
    avatarLabel.font = [UIFont boldSystemFontOfSize:34];
    avatarLabel.textColor = [UIColor whiteColor];
    avatarLabel.textAlignment = NSTextAlignmentCenter;
    avatarLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [avatar addSubview:avatarLabel];
    [NSLayoutConstraint activateConstraints:@[
        [avatarLabel.topAnchor constraintEqualToAnchor:avatar.topAnchor],
        [avatarLabel.leadingAnchor constraintEqualToAnchor:avatar.leadingAnchor],
        [avatarLabel.trailingAnchor constraintEqualToAnchor:avatar.trailingAnchor],
        [avatarLabel.bottomAnchor constraintEqualToAnchor:avatar.bottomAnchor],
    ]];
    [avaStack addArrangedSubview:avatar];

    UILabel *name = [[UILabel alloc] init];
    name.text = @"yZFAIU";
    name.font = [UIFont boldSystemFontOfSize:22];
    name.textColor = [UIColor labelColor];
    name.translatesAutoresizingMaskIntoConstraints = NO;
    [avaStack addArrangedSubview:name];

    UILabel *tag = [[UILabel alloc] init];
    tag.text = XJ_T(@"UGF5SG9vayDkvZzogIUgwrcg5b6u5L+h5pS25qy+55uR5o6n");
    tag.font = [UIFont systemFontOfSize:13];
    tag.textColor = [UIColor colorWithRed:0.55 green:0.55 blue:0.57 alpha:1];
    tag.translatesAutoresizingMaskIntoConstraints = NO;
    [avaStack addArrangedSubview:tag];

    [stack addArrangedSubview:avaCard];

    // 开源地址卡片
    UIStackView *gitStack = nil;
    UIView *gitCard = XJCardWithStack(&gitStack);
    UILabel *gitTitle = [[UILabel alloc] init];
    gitTitle.text = XJ_T(@"5byA5rqQ5Zyw5Z2A");
    gitTitle.font = [UIFont boldSystemFontOfSize:15];
    gitTitle.textColor = [UIColor labelColor];
    gitTitle.translatesAutoresizingMaskIntoConstraints = NO;
    [gitStack addArrangedSubview:gitTitle];

    UILabel *gitURL = [[UILabel alloc] init];
    gitURL.text = @"https://github.com/yZFAIU/PayHook";
    gitURL.font = [UIFont fontWithName:@"Menlo" size:12] ?: [UIFont systemFontOfSize:12];
    gitURL.textColor = [UIColor colorWithRed:0.20 green:0.20 blue:0.22 alpha:1];
    gitURL.numberOfLines = 1;               // 超长地址：单行截断，超出隐藏
    gitURL.lineBreakMode = NSLineBreakByTruncatingTail;
    gitURL.translatesAutoresizingMaskIntoConstraints = NO;
    [gitStack addArrangedSubview:gitURL];
    [stack addArrangedSubview:gitCard];

    // 操作按钮
    [stack addArrangedSubview:[self repoButton:XJ_T(@"5ZyoIFNhZmFyaSDmiZPlvIA=") primary:YES action:@selector(openRepo)]];
    [stack addArrangedSubview:[self repoButton:XJ_T(@"5aSN5Yi25byA5rqQ5Zyw5Z2A") primary:NO action:@selector(copyRepo)]];

    UILabel *foot = [[UILabel alloc] init];
    foot.text = [NSString stringWithFormat:XJ_T(@"UGF5SG9vayB2My4wIMK3ICVA"), kXJAuthor];
    foot.font = [UIFont systemFontOfSize:11];
    foot.textColor = [UIColor colorWithRed:0.70 green:0.70 blue:0.72 alpha:1];
    foot.textAlignment = NSTextAlignmentCenter;
    foot.translatesAutoresizingMaskIntoConstraints = NO;
    [stack addArrangedSubview:foot];
}

// 磨砂按钮（与设置页 actionButton 风格一致）
- (UIButton *)repoButton:(NSString *)title primary:(BOOL)primary action:(SEL)action {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    b.translatesAutoresizingMaskIntoConstraints = NO;
    [b setTitle:title forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont boldSystemFontOfSize:15];
    b.layer.cornerRadius = 12;
    b.layer.masksToBounds = YES;
    if (primary) {
        b.backgroundColor = XJAccent();
        [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    } else {
        b.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
        [b setTitleColor:XJAccent() forState:UIControlStateNormal];
        b.layer.borderWidth = 1;
        b.layer.borderColor = [UIColor separatorColor].CGColor;
    }
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [b.heightAnchor constraintEqualToConstant:48].active = YES;
    return b;
}

- (void)openRepo {
    NSURL *url = [NSURL URLWithString:@"https://github.com/yZFAIU/PayHook"];
    if (!url) return;
    if (@available(iOS 10.0, *)) {
        [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
    } else {
        [[UIApplication sharedApplication] openURL:url];
    }
}

- (void)copyRepo {
    [UIPasteboard generalPasteboard].string = @"https://github.com/yZFAIU/PayHook";
    XJShowCard(XJ_T(@"5bey5aSN5Yi2"), XJ_T(@"5byA5rqQ5Zyw5Z2A5bey5aSN5Yi25Yiw5Ymq6LS05p2/"));
}

- (UIStatusBarStyle)preferredStatusBarStyle {
    if (@available(iOS 13.0, *)) {
        return XJStatusBarStyleForTrait(self.traitCollection);
    }
    return UIStatusBarStyleDefault;
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    if (@available(iOS 13.0, *)) {
        if ([self.traitCollection hasDifferentColorAppearanceComparedToTraitCollection:previousTraitCollection]) {
            [self setNeedsStatusBarAppearanceUpdate];
            [self xj_applyNavBarStyle];
        }
    }
}

@end

// ============================================================
// MARK: - 订单列表页 (XJOrderListViewController)
// ============================================================

@implementation XJOrderListViewController {
    UITableView *_table;
    NSMutableArray<NSDictionary *> *_items;
}

- (void)xj_applyNavBarStyle {
    // 半透明毛玻璃风格（订单页）：浅色=白半透+黑字，深色=深灰半透+白字
    if (self.navigationController && self.navigationController.navigationBar) {
        XJApplyNavBarStyleForTrait(self.navigationController.navigationBar, self.traitCollection, YES);
    }
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self xj_applyNavBarStyle];
    [self setNeedsStatusBarAppearanceUpdate];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self xj_applyNavBarStyle];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor]; // 跟随系统深浅色
    self.title = XJ_T(@"6K6i5Y2V5YiX6KGo");

    UIBarButtonItem *refresh = [[UIBarButtonItem alloc] initWithTitle:XJ_T(@"6I635Y+W5bey5pyJ6K6i5Y2V")
                                                                  style:UIBarButtonItemStylePlain
                                                                 target:self
                                                                 action:@selector(fetchOrders)];
    self.navigationItem.rightBarButtonItem = refresh;

    _items = [NSMutableArray array];

    _table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    _table.translatesAutoresizingMaskIntoConstraints = NO;
    _table.backgroundColor = [UIColor clearColor];
    _table.separatorStyle = UITableViewCellSeparatorStyleNone;
    _table.dataSource = self;
    _table.delegate = self;
    _table.rowHeight = UITableViewAutomaticDimension;
    _table.estimatedRowHeight = 76;
    [self.view addSubview:_table];

    [NSLayoutConstraint activateConstraints:@[
        [_table.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [_table.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_table.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_table.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];

    [self reloadOrders];
}

- (void)reloadOrders {
    NSArray *all = [[XJOrderStore sharedInstance] allOrders];
    _items = [NSMutableArray arrayWithArray:all];
    [_table reloadData];
}

- (void)fetchOrders {
    // 方案 A：从本地订单存储重新载入（插件已捕获的收款）
    [self reloadOrders];
    NSInteger c = [[XJOrderStore sharedInstance] count];
    XJShowWeChatToast([NSString stringWithFormat:XJ_T(@"5bey6I635Y+WICVsZCDnrJTorqLljZU="), (long)c]);
}

- (UIStatusBarStyle)preferredStatusBarStyle {
    if (@available(iOS 13.0, *)) {
        return XJStatusBarStyleForTrait(self.traitCollection);
    }
    return UIStatusBarStyleDefault;
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    if (@available(iOS 13.0, *)) {
        if ([self.traitCollection hasDifferentColorAppearanceComparedToTraitCollection:previousTraitCollection]) {
            [self setNeedsStatusBarAppearanceUpdate];
            [self xj_applyNavBarStyle];
        }
    }
}

#pragma mark - UITableView

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return _items.count ? _items.count : 1; // 空状态占一行
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (_items.count == 0) {
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"empty"];
        if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"empty"];
        cell.textLabel.text = XJ_T(@"5pqC5peg6K6i5Y2VXG7ov5vlhaXorr7nva7lkI7vvIzmj5Lku7bnm5HmjqfliLDnmoTmlLbmrL7kvJroh6rliqjorrDlvZXlnKjmraQ=");
        cell.textLabel.textColor = [UIColor colorWithRed:0.55 green:0.55 blue:0.57 alpha:1];
        cell.textLabel.font = [UIFont systemFontOfSize:13];
        cell.textLabel.numberOfLines = 0;
        cell.textLabel.textAlignment = NSTextAlignmentCenter;
        cell.backgroundColor = [UIColor clearColor];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }
    NSDictionary *o = _items[indexPath.row];
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"order"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"order"];
        cell.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
        cell.textLabel.font = [UIFont boldSystemFontOfSize:17];
        cell.textLabel.textColor = [UIColor labelColor];
        cell.detailTextLabel.font = [UIFont systemFontOfSize:12];
        cell.detailTextLabel.textColor = [UIColor colorWithRed:0.55 green:0.55 blue:0.57 alpha:1];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    NSString *amount = [o[@"amount"] description] ?: @"?";
    BOOL matched = [o[@"matched"] boolValue];
    cell.textLabel.text = [NSString stringWithFormat:XJ_T(@"77+lJUAgIMK3ICAlQA=="), amount, matched ? XJ_T(@"5bey5Yy56YWN") : XJ_T(@"5pyq5Yy56YWN")];
    NSString *tradeNo = [o[@"tradeNo"] description] ?: @"";
    NSDate *t = o[@"time"];
    NSString *timeStr = @"";
    if ([t isKindOfClass:[NSDate class]]) {
        NSDateFormatter *f = [[NSDateFormatter alloc] init];
        f.dateFormat = @"MM-dd HH:mm";
        timeStr = [f stringFromDate:t];
    }
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%@    %@", timeStr, tradeNo];
    return cell;
}

@end

// ============================================================
// MARK: - 打开设置界面
// ============================================================

static void XJOpenSettings(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        XJSettingsViewController *vc = [[XJSettingsViewController alloc] init];
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
        nav.modalPresentationStyle = UIModalPresentationFullScreen;
        // nav 接管状态栏外观，由 barStyle 决定状态栏文字色（浅色=黑字/深色=白字）
        nav.modalPresentationCapturesStatusBarAppearance = YES;
        // 用统一函数锁死导航栏外观（纯色背景 + barStyle），避免微信 trait 干扰
        XJApplyNavBarStyleForTrait(nav.navigationBar, nav.traitCollection, NO);
        UIViewController *top = XJGetTopVC();
        if (top) [top presentViewController:nav animated:YES completion:nil];
    });
}

@interface UIViewController (PayHook)
- (void)payhook_openSettings;
@end
@implementation UIViewController (PayHook)
- (void)payhook_openSettings { XJOpenSettings(); }
@end

// ============================================================
// MARK: - 配置读写
// ============================================================

static NSString *kPrefsPath = @"/var/mobile/Library/Preferences/com.xj.wechatpay.plist";

static void XJLoadConfig(void) {
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:kPrefsPath];
    kServerURL     = prefs[@"server_url"]      ?: @"http://pay.yzfaiu.xyz";
    kMonitorSecret = prefs[@"monitor_secret"]  ?: @"mapay_monitor_2024";
    kMonitorName   = prefs[@"monitor_name"]    ?: @"iOS-Hook-01";
    if (prefs[@"debug"] != nil) kDebugEnabled = [prefs[@"debug"] boolValue];
    if (prefs[@"visual_feedback"] != nil) kVisualFeedback = [prefs[@"visual_feedback"] boolValue];
    if (prefs[@"dedup_window"] != nil) kDedupWindow = [prefs[@"dedup_window"] doubleValue];
    if (kDedupWindow < 5.0) kDedupWindow = 30.0;
    if (!sReportedAmounts) sReportedAmounts = [[NSMutableDictionary alloc] init];
}

static void XJSaveConfig(void) {
    NSMutableDictionary *prefs = [NSMutableDictionary dictionary];
    prefs[@"server_url"]      = kServerURL;
    prefs[@"monitor_secret"]  = kMonitorSecret;
    prefs[@"monitor_name"]    = kMonitorName;
    prefs[@"debug"]           = @(kDebugEnabled);
    prefs[@"visual_feedback"] = @(kVisualFeedback);
    prefs[@"dedup_window"]    = @(kDedupWindow);
    [prefs writeToFile:kPrefsPath atomically:YES];
    NSLog(@"[PayHook] Config saved to %@", kPrefsPath);
}

// ============================================================
// MARK: - 增强收款检测
// ============================================================

static NSString *XJExtractAmountEnhanced(NSString *content,
                                          XJPaymentXMLResult *xmlResult,
                                          id payItemObj);
static NSString *XJExtractAmountLegacy(NSString *content);

/// 收款检测（仅识别「微信收款助手」单一来源，杜绝误判）：
/// 只走白名单精确匹配（gh_f0a92aa7146c），不再使用 XML/关键词/模糊匹配兜底，
/// 避免把普通转账、群收款、红包等消息误判为收款到账。
static BOOL XJIsPaymentNotificationEnhanced(NSString *content,
                                            NSString *fromUser,
                                            XJPaymentXMLResult *xmlResult) {
    if (!content || content.length == 0) return NO;

    // 仅识别「微信收款助手」公众号来源（唯一检测来源）
    if (fromUser && [[XJPaySourceConfig sharedInstance] isPaymentSource:fromUser]) {
        return YES;
    }

    return NO;
}

// 通用金额扫描：在整段文本中查找人民币金额，覆盖尽可能多的写法。
// 支持：¥/￥X.XX、X.XX元、收款金额 X.XX、转账 X.XX、<amount>分</amount> 等。
// 返回第一个落在合理区间 [0.01, 100000) 的金额字符串（%.2f）。
static NSString *XJScanAmountUniversal(NSString *text) {
    if (!text || text.length == 0) return nil;
    NSArray *patterns = @[
        // 带货币符号：[￥¥]\s*数字
        XJ_T(@"W++/pcKlXVxccyooWzAtOSxdK1xcLj9bMC05XXswLDJ9KQ=="),
        // 数字+元（必须有小数，避免误抓手机号等）
        XJ_T(@"KFswLTldK1xcLlswLTldezEsMn0pXFxzKuWFgw=="),
        // 收款/到账/成功 金额/到账户 + 数字
        XJ_T(@"5pS25qy+KD866YeR6aKdfOWIsOi0pnzmiJDlip8pWzrvvJpcXHNdKlvvv6XCpV0/XFxzKihbMC05XStcXC4/WzAtOV17MCwyfSlcXHMq5YWDPw=="),
        // 转账/收款 数字（无单位，救援模式）
        XJ_T(@"KD866L2s6LSmfOaUtuasvilbXjAtOV17MCw4fT8oWzAtOV0rXC5bMC05XXsxLDJ9KQ=="),  // 转账/收款 数字（无单位救援，已修复 base64 损坏）
        XJ_T(@"5pS25Yiw6L2s6LSmXFxzKihbMC05XStcXC4/WzAtOV17MCwyfSlcXHMq"),
        // 任意「数字.数字 元」兜底（已修复括号不配对）
        XJ_T(@"KFswLTldK1wuP1swLTldezAsMn0pXHMq5YWD"),
        // 新增：原生对象字段 =小数（抓 m_nsPayAmount=0.01 类无单位金额）
        XJ_T(@"Wz06XVxzKihbMC05XStcLlswLTldezEsMn0p"),
    ];
    for (NSString *p in patterns) {
        NSError *e = nil;
        NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:p
                                                                           options:NSRegularExpressionCaseInsensitive
                                                                             error:&e];
        if (e || !re) continue;
        NSTextCheckingResult *m = [re firstMatchInString:text options:0 range:NSMakeRange(0, text.length)];
        if (m && m.numberOfRanges > 1) {
            NSString *s = [text substringWithRange:[m rangeAtIndex:1]];
            s = [s stringByReplacingOccurrencesOfString:@"," withString:@""];
            double v = [s doubleValue];
            if (v >= 0.01 && v < 100000.0) return [NSString stringWithFormat:@"%.2f", v];
        }
    }
    // 最终兜底：<amount>整数分</amount> → 除以 100 得到元
    NSRegularExpression *fenRe = [NSRegularExpression
        regularExpressionWithPattern:XJ_T(@"PGFtb3VudD4oWzAtOV0rKTwvYW1vdW50Pg==")
                              options:NSRegularExpressionCaseInsensitive error:nil];
    if (fenRe) {
        NSTextCheckingResult *fm = [fenRe firstMatchInString:text options:0 range:NSMakeRange(0, text.length)];
        if (fm && fm.numberOfRanges > 1) {
            NSString *s = [text substringWithRange:[fm rangeAtIndex:1]];
            double v = [s doubleValue];
            if (v > 0 && v < 10000000.0) {
                double yuan = v / 100.0;
                if (yuan >= 0.01 && yuan < 100000.0) return [NSString stringWithFormat:@"%.2f", yuan];
            }
        }
    }
    return nil;
}

static NSString *XJExtractAmountEnhanced(NSString *content,
                                          XJPaymentXMLResult *xmlResult,
                                          id payItemObj) {
    // 1) 优先用 XML 结构化字段 feedesc / des
    if (xmlResult && xmlResult.feedesc.length > 0) {
        NSString *feedesc = xmlResult.feedesc;
        NSRegularExpression *feedescRegex = [NSRegularExpression
            regularExpressionWithPattern:XJ_T(@"W++/pcKlXVxccyooWzAtOSxdK1xcLj9bMC05XXswLDJ9KQ==") options:0 error:nil];
        NSTextCheckingResult *match = [feedescRegex firstMatchInString:feedesc
                                                               options:0
                                                                 range:NSMakeRange(0, feedesc.length)];
        if (match && match.numberOfRanges > 1) {
            NSString *amountStr = [feedesc substringWithRange:[match rangeAtIndex:1]];
            amountStr = [amountStr stringByReplacingOccurrencesOfString:@"," withString:@""];
            double value = [amountStr doubleValue];
            if (value >= 0.01 && value < 100000.0) return [NSString stringWithFormat:@"%.2f", value];
        }
    }

    if (xmlResult && xmlResult.des.length > 0) {
        NSString *desc = xmlResult.des;
        NSRegularExpression *descRegex = [NSRegularExpression
            regularExpressionWithPattern:XJ_T(@"KFswLTldK1xcLlswLTldezEsMn0pXFxzKuWFgw==") options:0 error:nil];
        NSTextCheckingResult *match = [descRegex firstMatchInString:desc options:0 range:NSMakeRange(0, desc.length)];
        if (match && match.numberOfRanges > 1) {
            NSString *amountStr = [desc substringWithRange:[match rangeAtIndex:1]];
            double value = [amountStr doubleValue];
            if (value >= 0.01 && value < 100000.0) return [NSString stringWithFormat:@"%.2f", value];
        }
    }

    // 1.5) 直接读取 WCPayInfoItem 的已知金额字段（不同微信版本命名不同）
    //      这是新版微信金额最可靠的来源：常以 m_nsPayAmount="0.01"（元）出现，
    //      也可能以 m_uiPayAmount=1234（分）等 NSInteger 字段出现。
    if (payItemObj) {
        // 字符串金额：通常为带小数的元，如 "0.01"
        NSArray *amountKeys = @[@"m_nsPayAmount", @"m_nsAmount",
                                  @"m_nsPayMoney", @"m_nsMoney"];
        for (NSString *k in amountKeys) {
            id v = [payItemObj valueForKey:k];
            if (![v isKindOfClass:[NSString class]] || [v length] == 0) continue;
            NSString *s = [(NSString *)v stringByReplacingOccurrencesOfString:@"," withString:@""];
            NSRegularExpression *re = [NSRegularExpression
                regularExpressionWithPattern:@"[0-9]+\\.?[0-9]{0,2}" options:0 error:nil];
            if (!re) continue;
            NSTextCheckingResult *m = [re firstMatchInString:s options:0 range:NSMakeRange(0, s.length)];
            if (m) {
                NSString *ms = [s substringWithRange:[m range]];
                double val = [ms doubleValue];
                // 只认带小数点的（如 0.01）；无小数整数疑似“分”交给下一段
                if ([ms rangeOfString:@"."].location != NSNotFound &&
                    val >= 0.01 && val < 100000.0) {
                    return [NSString stringWithFormat:@"%.2f", val];
                }
            }
        }
        // 整数“分”：m_uiPayAmount / m_iPayAmount 等 NSInteger 字段（如 1234 → 12.34）
        NSArray *centKeys = @[@"m_uiPayAmount", @"m_iPayAmount", @"m_lPayAmount",
                              @"m_uiAmount", @"m_iAmount"];
        for (NSString *k in centKeys) {
            id v = [payItemObj valueForKey:k];
            if (!v) continue;
            NSString *sv = [v description];
            double c = [sv doubleValue];
            if (c >= 100.0 && c < 10000000.0 &&
                [sv rangeOfString:@"."].location == NSNotFound) {
                double yuan = c / 100.0;
                if (yuan >= 0.01 && yuan < 100000.0) {
                    return [NSString stringWithFormat:@"%.2f", yuan];
                }
            }
        }
    }

    // 2) 合并所有可读取的文本内容做通用扫描：
    //    - 原始 content（XML 或通知文本）
    //    - XML 结构化字段 title / payMemo / des / feedesc
    //    - WCPayInfoItem 的全部字符串属性（金额常藏在这里，如 m_nsPayAmount、m_nsTitle 等）
    NSMutableString *allText = [NSMutableString string];
    if (content) [allText appendString:content];
    if (xmlResult.title.length > 0) [allText appendFormat:@"\n%@", xmlResult.title];
    if (xmlResult.payMemo.length > 0) [allText appendFormat:@"\n%@", xmlResult.payMemo];
    if (xmlResult.des.length > 0) [allText appendFormat:@"\n%@", xmlResult.des];
    if (xmlResult.feedesc.length > 0) [allText appendFormat:@"\n%@", xmlResult.feedesc];
    if (payItemObj) {
        @try {
            unsigned int pc = 0;
            objc_property_t *props = class_copyPropertyList([payItemObj class], &pc);
            for (unsigned int i = 0; i < pc; i++) {
                NSString *pname = [NSString stringWithUTF8String:property_getName(props[i])];
                id val = [payItemObj valueForKey:pname];
                if ([val isKindOfClass:[NSString class]] && [val length] > 0) {
                    [allText appendFormat:@"\n%@=%@", pname, val];
                }
            }
            if (props) free(props);
        } @catch (NSException *e) {}
    }

    NSString *universal = XJScanAmountUniversal(allText);
    if (universal) return universal;

    // 3) 最后兜底：用配置里的旧正则扫原始 XML 文本
    return XJExtractAmountLegacy(content);
}

static NSString *XJExtractAmountLegacy(NSString *content) {
    if (!content || content.length == 0) return nil;
    XJRemoteConfig *config = [XJRemoteConfig sharedInstance];
    for (NSString *pattern in config.amountRegexes) {
        NSError *err = nil;
        NSRegularExpression *regex = [NSRegularExpression
            regularExpressionWithPattern:pattern options:NSRegularExpressionCaseInsensitive error:&err];
        if (err || !regex) continue;
        NSTextCheckingResult *match = [regex firstMatchInString:content options:0 range:NSMakeRange(0, content.length)];
        if (match && match.numberOfRanges > 1) {
            NSString *amountStr = [content substringWithRange:[match rangeAtIndex:1]];
            double value = [amountStr doubleValue];
            if ([pattern containsString:@"<amount>"]) value = value / 100.0;
            if (value >= 0.01 && value < 100000.0) return [NSString stringWithFormat:@"%.2f", value];
        }
    }
    return nil;
}

static BOOL XJShouldReport(NSString *amount) {
    @synchronized(sReportedAmounts) {
        NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
        NSMutableArray *expired = [NSMutableArray array];
        [sReportedAmounts enumerateKeysAndObjectsUsingBlock:^(NSString *k, NSNumber *t, BOOL *stop){
            if ((now - [t doubleValue]) > kDedupWindow) [expired addObject:k];
        }];
        for (NSString *k in expired) [sReportedAmounts removeObjectForKey:k];
        if (sReportedAmounts[amount]) return NO;
        sReportedAmounts[amount] = @(now);
        return YES;
    }
}

// ============================================================
// MARK: - 联系人信息
// ============================================================

static NSDictionary *XJGetContactInfo(NSString *userName) {
    if (!userName || userName.length == 0) return nil;
    @try {
        Class contactMgrClass = objc_getClass("CContactMgr");
        Class serviceCenterClass = objc_getClass("MMServiceCenter");
        if (!contactMgrClass || !serviceCenterClass) return nil;
        id contactMgr = [[serviceCenterClass defaultCenter] getService:contactMgrClass];
        if (!contactMgr) return nil;
        id contact = [contactMgr getContactByName:userName];
        if (!contact) return nil;
        NSMutableDictionary *info = [NSMutableDictionary dictionary];
        NSString *nick = [contact valueForKey:@"m_nsNickName"];
        NSString *headImg = [contact valueForKey:@"m_nsHeadImgUrl"];
        id displayName = [contact getContactDisplayName];
        if (nick) info[@"nick_name"] = nick;
        if (headImg) info[@"head_img_url"] = headImg;
        if (displayName) info[@"display_name"] = [displayName description];
        return info.count > 0 ? info : nil;
    } @catch (NSException *e) {
        return nil;
    }
}

// ============================================================
// MARK: - 上报
// ============================================================

static void XJReportPaymentEnhanced(NSString *amount,
                                     NSString *rawText,
                                     NSDictionary *extraFields) {
    if (!XJShouldReport(amount)) {
        NSLog(@"[PayHook] SKIP (dedup) amount=%@", amount);
        return;
    }

    sReportSent++;
    sLastReportTime = [[NSDate date] timeIntervalSince1970];

    NSMutableDictionary *params = [NSMutableDictionary dictionaryWithDictionary:@{
        @"amount":         @([amount doubleValue]),
        @"pay_type":       extraFields[@"pay_type"] ?: @"wechat",
        @"raw_text":       rawText.length > 500 ? [rawText substringToIndex:500] : rawText,
        @"timestamp":      [NSString stringWithFormat:@"%ld", (long)sLastReportTime],
        @"monitor":        kMonitorName ?: @"iOS-Hook-01",
        @"source":         @"ios_hook",
        @"monitor_secret": kMonitorSecret ?: @"mapay_monitor_2024",
    }];

    NSArray *extraKeys = @[@"msg_type", @"app_msg_inner_type", @"from_user", @"to_user",
                           @"real_sender", @"svr_msg_id", @"server_timestamp",
                           @"paysubtype", @"transcationid", @"transferid", @"pay_memo",
                           @"native_url", @"detection_method", @"contact_nick",
                           @"contact_head_img", @"contact_display_name"];
    for (NSString *key in extraKeys) {
        id val = extraFields[key];
        if (val) params[key] = val;
    }

    NSString *urlStr = [NSString stringWithFormat:@"%@/api.php?action=monitor_report",
                        kServerURL ?: @"http://pay.yzfaiu.xyz"];
    NSURL *url = [NSURL URLWithString:urlStr];

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"POST";
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    request.timeoutInterval = 10.0;

    NSError *jsonErr = nil;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:params options:0 error:&jsonErr];
    if (jsonErr) {
        sReportFailed++;
        XJShowCard(XJ_T(@"UGF5SG9vayDplJnor68="), XJ_T(@"SlNPTiDluo/liJfljJblpLHotKU="));
        return;
    }
    request.HTTPBody = jsonData;

    NSLog(@"[PayHook] >>> report amount=%@ method=%@ txid=%@", amount,
          params[@"detection_method"], params[@"transcationid"]);

    // 识别到收款：白底卡片提示 (Req 7)
    XJShowCard(XJ_T(@"5pS25qy+6K+G5Yir5oiQ5Yqf"), [NSString stringWithFormat:XJ_T(@"6YeR6aKdOiAlQCDlhYM="), amount]);

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0), ^{
        NSURLSessionDataTask *task = [[NSURLSession sharedSession]
            dataTaskWithRequest:request
              completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
                if (error) {
                    sReportFailed++;
                    XJShowCard(XJ_T(@"UGF5SG9vayDkuIrmiqXlpLHotKU="), error.localizedDescription);
                    return;
                }
                NSDictionary *result = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                if (!result) {
                    sReportFailed++;
                    XJShowCard(XJ_T(@"UGF5SG9vayDplJnor68="), XJ_T(@"5pyN5Yqh56uv6L+U5Zue6Z2eIEpTT04g5pWw5o2u"));
                    return;
                }
                NSInteger code = [result[@"code"] integerValue];
                BOOL matched = [result[@"matched"] boolValue];
                NSString *tradeNo = result[@"trade_no"] ?: @"";
                NSString *respMsg = result[@"msg"] ?: @"";

                if (code == 200 && matched) {
                    sReportMatched++;
                    sLastMatchTradeNo = [tradeNo copy];
                    sLastMatchAmount = [amount copy];
                    [[XJOrderStore sharedInstance] addOrderWithAmount:amount tradeNo:tradeNo matched:YES time:[NSDate date]];
                    // 订单匹配成功：改为系统通知 (Req 6)
                    XJPostLocalNotification(XJ_T(@"5pSv5LuY5oiQ5Yqf"),
                        [NSString stringWithFormat:XJ_T(@"5pS25qy+ICVAIOWFgyDCtyDorqLljZXlt7LljLnphY1cbuiuouWNleWPtzogJUA="), amount, tradeNo]);
                } else if (code == 200 && !matched) {
                    XJShowCard(XJ_T(@"5bey5LiK5oql"), [NSString stringWithFormat:XJ_T(@"JUAg5YWDIC0g5pqC5peg5Yy56YWN6K6i5Y2V"), amount]);
                    [[XJOrderStore sharedInstance] addOrderWithAmount:amount tradeNo:tradeNo matched:NO time:[NSDate date]];
                } else if (code == 200) {
                    // 服务端去重
                } else {
                    sReportFailed++;
                    XJShowCard(XJ_T(@"5pyN5Yqh56uv6ZSZ6K+v"), [NSString stringWithFormat:@"code=%ld %@", (long)code, respMsg]);
                }
            }];
        [task resume];
    });
}

// ============================================================
// MARK: - 订单存储 (XJOrderStore) —— 记录插件已捕获的收款订单
// ============================================================

@implementation XJOrderStore {
    NSMutableArray<NSDictionary *> *_orders;
}

+ (instancetype)sharedInstance {
    static XJOrderStore *s = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ s = [[XJOrderStore alloc] init]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) {
        _orders = [NSMutableArray array];
        [self loadFromDisk];
    }
    return self;
}

- (void)addOrderWithAmount:(NSString *)amount tradeNo:(NSString *)tradeNo matched:(BOOL)matched time:(NSDate *)time {
    if (!amount) amount = @"?";
    if (!tradeNo) tradeNo = @"";
    @synchronized (self) {
        if (tradeNo.length) {
            for (NSMutableDictionary *o in _orders) {
                if ([[o[@"tradeNo"] description] isEqualToString:tradeNo]) {
                    [o setObject:@(matched) forKey:@"matched"];
                    [self saveToDisk];
                    return;
                }
            }
        }
        NSMutableDictionary *o = [NSMutableDictionary dictionary];
        [o setObject:amount forKey:@"amount"];
        [o setObject:tradeNo forKey:@"tradeNo"];
        [o setObject:@(matched) forKey:@"matched"];
        NSDate *t = time ? time : [NSDate date];
        [o setObject:t forKey:@"time"];
        [_orders insertObject:o atIndex:0];
        if (_orders.count > 200) [_orders removeLastObject];
    }
    [self saveToDisk];
}

- (NSArray<NSDictionary *> *)allOrders {
    @synchronized (self) { return [NSArray arrayWithArray:_orders]; }
}

- (NSInteger)count {
    @synchronized (self) { return _orders.count; }
}

- (void)clear {
    @synchronized (self) { [_orders removeAllObjects]; }
    [self saveToDisk];
}

- (void)saveToDisk {
    @try {
        NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
        NSMutableArray *arr = [NSMutableArray array];
        @synchronized (self) {
            for (NSDictionary *o in _orders) [arr addObject:[o copy]];
        }
        [ud setObject:arr forKey:@"com.xj.wechatpay.orders"];
        [ud synchronize];
    } @catch (NSException *e) {}
}

- (void)loadFromDisk {
    @try {
        NSArray *arr = [[NSUserDefaults standardUserDefaults] arrayForKey:@"com.xj.wechatpay.orders"];
        if ([arr isKindOfClass:[NSArray class]]) {
            @synchronized (self) {
                [_orders removeAllObjects];
                for (NSDictionary *o in arr) {
                    if ([o isKindOfClass:[NSDictionary class]]) [_orders addObject:[o mutableCopy]];
                }
            }
        }
    } @catch (NSException *e) {}
}

@end

// ============================================================
// MARK: - 调试落盘：识别到收款但金额提取失败时，把原始消息写到文件
// 路径：/var/mobile/Documents/payhook_debug.txt （用 Filza 直接打开即可）
// 目的：无需折腾 syslog，拿到真实消息样本后照此对正金额位置。
// ============================================================

static void XJDumpRawMessageForDebug(id rawMsg, NSString *fromUser,
                                     XJPaymentXMLResult *xmlResult, id payItemObj) {
    @try {
        NSMutableString *dump = [NSMutableString string];
        [dump appendFormat:@"===== PayHook 调试样本 @ %@ =====\n", [NSDate date]];
        [dump appendFormat:@"fromUser : %@\n", fromUser ?: @""];

        // 1) 原始消息对象的常见字段
        NSArray *msgKeys = @[@"m_nsContent", @"m_nsDesc", @"m_nsTitle", @"m_nsPushContent",
                             @"m_nsFromUsr", @"m_nsToUsr", @"m_nsRealChatUsr", @"m_nsMsgSource",
                             @"m_uiMessageType", @"m_uiAppMsgInnerType", @"m_n64MesSvrID",
                             @"m_uiCreateTime"];
        for (NSString *k in msgKeys) {
            id v = [rawMsg valueForKey:k];
            if (v) [dump appendFormat:@"msg.%@ = %@\n", k, v];
        }

        // 2) WCPayInfoItem 的全部字符串属性（金额常藏于此）
        if (payItemObj) {
            unsigned int pc = 0;
            objc_property_t *props = class_copyPropertyList([payItemObj class], &pc);
            for (unsigned int i = 0; i < pc; i++) {
                NSString *pname = [NSString stringWithUTF8String:property_getName(props[i])];
                id val = [payItemObj valueForKey:pname];
                if ([val isKindOfClass:[NSString class]] && [val length] > 0) {
                    [dump appendFormat:@"payItem.%@ = %@\n", pname, val];
                }
            }
            if (props) free(props);
        }

        // 3) XML 解析结果
        if (xmlResult) {
            [dump appendFormat:@"xml.feedesc  = %@\n", xmlResult.feedesc ?: @""];
            [dump appendFormat:@"xml.des      = %@\n", xmlResult.des ?: @""];
            [dump appendFormat:@"xml.title    = %@\n", xmlResult.title ?: @""];
            [dump appendFormat:@"xml.payMemo  = %@\n", xmlResult.payMemo ?: @""];
            [dump appendFormat:@"xml.paysub   = %@\n", xmlResult.paysubtype ?: @""];
            [dump appendFormat:@"xml.txid     = %@\n", xmlResult.transcationid ?: @""];
        }

        // 4) 整个对象描述（兜底，可能暴露其它字段名）
        [dump appendFormat:@"\n--- rawMsg description ---\n%@\n", rawMsg];
        [dump appendString:@"\n"];

        // 多路径回退写入：优先写到微信自身沙盒 Documents（任何微信版本都可写），
        // 失败再依次尝试系统级可读目录，确保 Filza 一定能找到文件。
        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *docDir = nil;
        @try {
            NSArray *urls = [fm URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask];
            if (urls.count > 0) docDir = [[urls.firstObject path] stringByAppendingPathComponent:@"payhook_debug.txt"];
        } @catch (NSException *e) {}
        NSArray *candidateDirs = @[
            docDir ?: @"",
            @"/var/mobile/Media",
            @"/var/mobile",
            @"/tmp",
            @"/var/mobile/Documents"
        ];
        NSString *finalPath = nil;
        NSData *dumpData = [dump dataUsingEncoding:NSUTF8StringEncoding];
        for (NSString *dir in candidateDirs) {
            if (dir.length == 0) continue;
            NSString *p = [dir stringByAppendingPathComponent:@"payhook_debug.txt"];
            BOOL isDir = NO;
            if (![fm fileExistsAtPath:dir isDirectory:&isDir]) {
                [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
            }
            BOOL ok = NO;
            if (![fm fileExistsAtPath:p]) {
                ok = [dump writeToFile:p atomically:YES];
            } else {
                NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:p];
                if (fh) {
                    [fh seekToEndOfFile];
                    [fh writeData:dumpData];
                    [fh closeFile];
                    ok = YES;
                }
            }
            if (ok && [fm fileExistsAtPath:p]) { finalPath = p; break; }
        }
        NSLog(@"[PayHook] 调试样本写入%@: %@", finalPath ? @"成功" : @"失败", finalPath ?: @"所有路径均失败");
    } @catch (NSException *e) {
        NSLog(@"[PayHook] dump failed: %@", e.reason);
    }
}

// ============================================================
// MARK: - 统一消息处理
// ============================================================

static void XJProcessMessageEnhanced(id rawMsg, NSString *caller) {
    @try {
        NSString *content    = [rawMsg valueForKey:@"m_nsContent"];
        unsigned int msgType = [[rawMsg valueForKey:@"m_uiMessageType"] unsignedIntValue];
        NSString *fromUser   = [rawMsg valueForKey:@"m_nsFromUsr"];
        NSString *toUser     = [rawMsg valueForKey:@"m_nsToUsr"];
        NSString *desc       = [rawMsg valueForKey:@"m_nsDesc"];
        NSString *title      = [rawMsg valueForKey:@"m_nsTitle"];

        long long svrMsgId         = [[rawMsg valueForKey:@"m_n64MesSvrID"] longLongValue];
        NSUInteger createTime      = [[rawMsg valueForKey:@"m_uiCreateTime"] unsignedIntegerValue];
        NSUInteger appMsgInnerType = [[rawMsg valueForKey:@"m_uiAppMsgInnerType"] unsignedIntegerValue];
        NSString *realChatUsr      = [rawMsg valueForKey:@"m_nsRealChatUsr"];
        NSString *msgSource        = [rawMsg valueForKey:@"m_nsMsgSource"];
        id payItemObj              = [rawMsg valueForKey:@"m_oWCPayInfoItem"];
        NSString *nativeUrl        = [payItemObj valueForKey:@"m_c2cNativeUrl"];
        // 额外可能携带金额的字段（不同微信版本/消息类型放在不同位置）
        id pushContent = [rawMsg valueForKey:@"m_nsPushContent"];
        if (!pushContent) pushContent = [rawMsg valueForKey:@"m_nsPushContent"];

        NSMutableString *allContent = [NSMutableString string];
        if (content) [allContent appendString:content];
        if (desc && desc.length > 0) [allContent appendFormat:@"|DESC:%@", desc];
        if (title && title.length > 0) [allContent appendFormat:@"|TITLE:%@", title];
        if (pushContent && [pushContent isKindOfClass:[NSString class]] && [pushContent length] > 0)
            [allContent appendFormat:@"|PUSH:%@", pushContent];
        // 把 WCPayInfoItem 所有字符串属性也拼进来（金额常藏在其中，如 m_nsPayAmount/m_nsTitle 等）
        if (payItemObj) {
            @try {
                unsigned int pc = 0;
                objc_property_t *props = class_copyPropertyList([payItemObj class], &pc);
                for (unsigned int i = 0; i < pc; i++) {
                    NSString *pname = [NSString stringWithUTF8String:property_getName(props[i])];
                    id val = [payItemObj valueForKey:pname];
                    if ([val isKindOfClass:[NSString class]] && [val length] > 0) {
                        [allContent appendFormat:@"|PAYITEM:%@=%@", pname, val];
                    }
                }
                if (props) free(props);
            } @catch (NSException *e) {}
        }
        if (allContent.length == 0) return;

        if (svrMsgId > 0) {
            if ([[XJMessageDedup sharedInstance] isDuplicate:svrMsgId]) {
                sDedupSkipped++;
                return;
            }
            [[XJMessageDedup sharedInstance] recordMessage:svrMsgId];
        }

        XJPaymentXMLResult *xmlResult = nil;
        if ([XJPaymentXMLParser isPaymentXML:content]) {
            xmlResult = [XJPaymentXMLParser parse:content];
            if (xmlResult && xmlResult.hasPayInfo) sXMLParsed++;
        }

        BOOL isPayment = XJIsPaymentNotificationEnhanced(allContent, fromUser, xmlResult);
        NSString *amount = isPayment ? XJExtractAmountEnhanced(allContent, xmlResult, payItemObj) : nil;

        NSString *detectionMethod = @"none";
        if (isPayment) {
            // 仅「微信收款助手」白名单命中，不再有 xml_parse/keyword 分支
            if ([[XJPaySourceConfig sharedInstance] isPaymentSource:fromUser]) {
                detectionMethod = @"source_whitelist";
                sSourceMatched++;
            } else {
                detectionMethod = @"source_whitelist";
            }
        }

        NSString *payType = @"wechat";
        if (xmlResult && xmlResult.paysubtype) {
            XJRemoteConfig *cfg = [XJRemoteConfig sharedInstance];
            NSString *mapped = cfg.payTypeMapping[xmlResult.paysubtype];
            if (mapped) payType = mapped;
        }

        NSDictionary *contactInfo = nil;
        if (isPayment && fromUser.length > 0) contactInfo = XJGetContactInfo(fromUser);

        XJLogMessage(msgType, appMsgInnerType, fromUser, allContent,
                     isPayment, amount, detectionMethod,
                     xmlResult.paysubtype, xmlResult.transcationid);

        if (kDebugEnabled) {
            NSLog(@"[PayHook] MSG from=%@ payment=%d method=%@ amount=%@ caller=%@",
                  fromUser, isPayment, detectionMethod, amount, caller);
        }

        if (isPayment) {
            sPaymentDetected++;
            if (amount) {
                NSMutableDictionary *extra = [NSMutableDictionary dictionary];
                extra[@"msg_type"]           = @(msgType);
                extra[@"app_msg_inner_type"] = @(appMsgInnerType);
                extra[@"from_user"]          = fromUser ?: @"";
                extra[@"to_user"]            = toUser ?: @"";
                extra[@"real_sender"]        = realChatUsr ?: @"";
                extra[@"svr_msg_id"]         = @(svrMsgId);
                extra[@"server_timestamp"]   = @(createTime);
                extra[@"paysubtype"]         = xmlResult.paysubtype ?: @"";
                extra[@"transcationid"]      = xmlResult.transcationid ?: @"";
                extra[@"transferid"]         = xmlResult.transferid ?: @"";
                extra[@"pay_memo"]           = xmlResult.payMemo ?: @"";
                extra[@"native_url"]         = nativeUrl ?: @"";
                extra[@"detection_method"]   = detectionMethod;
                extra[@"pay_type"]           = payType;
                if (contactInfo) {
                    extra[@"contact_nick"]         = contactInfo[@"nick_name"] ?: @"";
                    extra[@"contact_head_img"]     = contactInfo[@"head_img_url"] ?: @"";
                    extra[@"contact_display_name"] = contactInfo[@"display_name"] ?: @"";
                }
                XJReportPaymentEnhanced(amount, allContent, extra);
            } else {
                // 已确认是收款消息但未能提取金额：把原始消息落盘到文件便于排查
                XJDumpRawMessageForDebug(rawMsg, fromUser, xmlResult, payItemObj);
                NSLog(@"[PayHook] 金额提取失败 from=%@ xmlFeedesc=%@ xmlDes=%@ title=%@ payMemo=%@ content=%@",
                      fromUser, xmlResult.feedesc, xmlResult.des,
                      xmlResult.title, xmlResult.payMemo, allContent);
                XJShowCard(XJ_T(@"5pS25qy+6K+G5Yir5oiQ5Yqf"), XJ_T(@"5L2G5peg5rOV5o+Q5Y+W6YeR6aKd77yM6K+35qOA5p+l5pel5b+X"));
            }
        }
    } @catch (NSException *e) {
        NSLog(@"[PayHook] Exception: %@ - %@", e.name, e.reason);
    }
}

// ============================================================
// MARK: - 状态文本 (用于设置页)
// ============================================================

static NSString *XJFormatTime(NSTimeInterval ts) {
    NSDate *date = [NSDate dateWithTimeIntervalSince1970:ts];
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateFormat = @"HH:mm:ss";
    return [fmt stringFromDate:date];
}

static NSDictionary<NSString*,NSString*> *XJBuildStatusDict(void) {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"detected"] = [NSString stringWithFormat:@"%ld", (long)sPaymentDetected];
    d[@"sent"]      = [NSString stringWithFormat:@"%ld", (long)sReportSent];
    d[@"matched"]   = [NSString stringWithFormat:@"%ld", (long)sReportMatched];
    d[@"failed"]    = [NSString stringWithFormat:@"%ld", (long)sReportFailed];
    d[@"dedup"]     = [NSString stringWithFormat:@"%ld", (long)sDedupSkipped];
    d[@"xml"]       = [NSString stringWithFormat:@"%ld", (long)sXMLParsed];
    d[@"source"]    = XJ_T(@"5b6u5L+h5pS25qy+5Yqp5omLKOS7hSk=");
    d[@"recent"]    = (sLastReportTime > 0) ? XJFormatTime(sLastReportTime) : @"-";
    d[@"lastmatch"] = sLastMatchTradeNo
        ? [NSString stringWithFormat:XJ_T(@"JUAg5YWDIC8gJUA="), sLastMatchAmount ?: @"?", sLastMatchTradeNo]
        : @"-";
    d[@"server"]    = (kServerURL && kServerURL.length) ? kServerURL : @"-";
    d[@"monitor"]   = (kMonitorName && kMonitorName.length) ? kMonitorName : @"-";
    d[@"flags"]     = [NSString stringWithFormat:XJ_T(@"JUAgLyAlQCAvICUuMGbnp5I="),
                           kDebugEnabled ? XJ_T(@"5byA") : XJ_T(@"5YWz"),
                           kVisualFeedback ? XJ_T(@"5byA") : XJ_T(@"5YWz"),
                           kDedupWindow];
    XJRemoteConfig *cfg = [XJRemoteConfig sharedInstance];
    d[@"remote"]    = [NSString stringWithFormat:@"%@ / %lu",
                           cfg.configVersion ?: XJ_T(@"5pyq5Yqg6L29"),
                           (unsigned long)cfg.paymentKeywords.count];
    return d;
}

// ============================================================
// MARK: - CMessageMgr Hook Groups
// ============================================================

static void XJSafeProcessMsg(id msg) {
    if (!msg) return;
    @try {
        id fromUser = [msg valueForKey:@"m_nsFromUsr"];
        id content = [msg valueForKey:@"m_nsContent"];
        if (!fromUser || !content) return;
        sCMessageMgrFired++;
        XJProcessMessageEnhanced(msg, @"CMessageMgr");
    } @catch (NSException *e) { }
}

%group HookOnNewMessage
%hook CMessageMgr
- (void)onNewMessage:(NSArray *)messages {
    %orig;
    if (messages && messages.count > 0) {
        for (id msg in messages) XJSafeProcessMsg(msg);
    }
}
%end
%end

%group HookOnRecvMsg
%hook CMessageMgr
- (void)onRecvMsg:(id)msg {
    %orig;
    XJSafeProcessMsg(msg);
}
%end
%end

%group HookAsyncOnAddMsgWrap
%hook CMessageMgr
- (void)AsyncOnAddMsg:(id)msg MsgWrap:(id)wrap {
    %orig;
    XJSafeProcessMsg(wrap);
}
%end
%end

%group HookAsyncOnAddMsgType
%hook CMessageMgr
- (void)AsyncOnAddMsg:(id)msg MsgType:(int)type {
    %orig;
    XJSafeProcessMsg(msg);
}
%end
%end

%group HookSyncProcess
%hook CMessageMgr
- (void)MessageSyncDidProcess:(NSArray *)messages {
    %orig;
    if (messages && messages.count > 0) {
        for (id msg in messages) XJSafeProcessMsg(msg);
    }
}
%end
%end

%group HookMainDispatcher
%hook CMessageMgr
- (void)MainDispatcherOnAddMsg:(id)msg {
    %orig;
    XJSafeProcessMsg(msg);
}
%end
%end

// ============================================================
// MARK: - 设置入口：在「我 → 设置」顶部注入独立按钮 (Req 1)
// ============================================================

static BOOL XJIsMainSettingsVC(NSString *cls) {
    if (![cls containsString:@"Setting"]) return NO;
    // 排除子设置页面，仅主设置页注入按钮
    NSArray *exclude = @[@"Group", @"Chat", @"Room", @"Contact", @"Friend", @"Member",
                         @"Privacy", @"Account", @"About", @"General", @"Notification",
                         @"Message", @"Help", @"Label", @"Device", @"Security", @"Wallet"];
    for (NSString *e in exclude) {
        if ([cls containsString:e]) return NO;
    }
    return YES;
}

static UITableView *XJFindTableView(UIView *view) {
    if (!view) return nil;
    if ([view isKindOfClass:[UITableView class]]) return (UITableView *)view;
    for (UIView *sub in view.subviews) {
        UITableView *t = XJFindTableView(sub);
        if (t) return t;
    }
    return nil;
}

// ============================================================
// MARK: - 设置入口按钮 UI（v6 — 跟随系统深浅色 + 对称边距 + 紧凑间距）
// ============================================================

// 固定浅色方案颜色：插件设置页已统一为浅色背景，不再跟随微信深色模式
// （overrideUserInterfaceStyle 在微信托管环境会导致导航栏变黑），故这里也写死浅色值，
// 避免动态颜色在微信深色 trait 下返回白字/黑底，造成文字看不清或卡片不可见。
static UIColor *XJAdaptiveTextColor(void) {
    if (@available(iOS 13.0, *)) { return [UIColor labelColor]; }
    return [UIColor darkGrayColor];
}

static UIColor *XJAdaptiveSubColor(void) {
    if (@available(iOS 13.0, *)) { return [[UIColor labelColor] colorWithAlphaComponent:0.55]; }
    return [[UIColor darkGrayColor] colorWithAlphaComponent:0.55];
}

// 状态栏文字样式：跟随当前 trait 深浅。
// 深色模式 -> 白色文字(LightContent)，浅色模式 -> 黑色文字(DarkContent)。
static UIStatusBarStyle XJStatusBarStyleForTrait(UITraitCollection *t) {
    if (@available(iOS 13.0, *)) {
        if (t.userInterfaceStyle == UIUserInterfaceStyleDark) {
            return UIStatusBarStyleLightContent;
        }
        if (@available(iOS 13.0, *)) {
            return UIStatusBarStyleDarkContent; // 浅色模式：黑色状态栏文字
        }
    }
    return UIStatusBarStyleDefault;
}

// 统一导航栏样式（v6 重写）：
// iOS 13+ 导航栏由 standardAppearance / scrollEdgeAppearance 控制，微信会全局通过
// appearance 代理设置这两个对象并强制黑色导航栏。早期用 setBackgroundImage: + barStyle
// 的方式会被微信的 appearance 覆盖而失效（始终黑底）。因此这里直接构造
// UINavigationBarAppearance 并赋值给 standardAppearance / scrollEdgeAppearance，
// 设置 backgroundColor + titleTextAttributes；状态栏文字色由 barStyle 决定。
// 这样无论微信的全局 appearance 如何，弹出的设置页导航栏都能按系统深浅色正确显示。
static void XJApplyNavBarStyleForTrait(UINavigationBar *bar, UITraitCollection *trait, BOOL translucent) {
    if (!bar) return;

    if (@available(iOS 13.0, *)) {
        UIColor *bg = nil;
        UIColor *titleColor = [UIColor labelColor];
        BOOL dark = (trait && trait.userInterfaceStyle == UIUserInterfaceStyleDark);

        if (dark) {
            // 深色：深灰底 + 白色状态栏文字（barStyle=Black 让状态栏文字变白）
            bg = [UIColor colorWithWhite:0.11 alpha:1.0]; // ~#1C1C1E
            bar.barStyle = UIBarStyleBlack;
        } else {
            // 浅色：纯白底 + 黑色状态栏文字（barStyle=Default 让状态栏文字变黑）
            bg = [UIColor whiteColor];
            bar.barStyle = UIBarStyleDefault;
        }

        UINavigationBarAppearance *ap = [[UINavigationBarAppearance alloc] init];
        [ap configureWithOpaqueBackground];
        ap.backgroundColor = bg;
        // 去掉默认分隔阴影线（深色下是黑线，难看）
        ap.shadowColor = [UIColor clearColor];
        ap.shadowImage = nil;
        ap.titleTextAttributes = @{
            NSForegroundColorAttributeName: titleColor,
            NSFontAttributeName: [UIFont boldSystemFontOfSize:17]
        };
        // 大标题外观也一并设置，保持一致
        ap.largeTitleTextAttributes = @{
            NSForegroundColorAttributeName: titleColor,
            NSFontAttributeName: [UIFont boldSystemFontOfSize:17]
        };

        if (translucent) {
            // 半透明页（作者/订单）：用半透明背景，保留毛玻璃观感
            UINavigationBarAppearance *apT = [[UINavigationBarAppearance alloc] init];
            [apT configureWithTransparentBackground];
            apT.backgroundColor = [bg colorWithAlphaComponent:0.7];
            apT.backgroundEffect = [UIBlurEffect effectWithStyle:(dark ? UIBlurEffectStyleDark : UIBlurEffectStyleLight)];
            apT.titleTextAttributes = ap.titleTextAttributes;
            apT.largeTitleTextAttributes = ap.largeTitleTextAttributes;
            apT.shadowColor = [UIColor clearColor];
            bar.standardAppearance = apT;
            bar.scrollEdgeAppearance = apT;
            bar.compactAppearance = apT;
            bar.translucent = YES;
        } else {
            bar.standardAppearance = ap;
            bar.scrollEdgeAppearance = ap;
            bar.compactAppearance = ap;
            bar.translucent = NO;
        }
        // 让 appearance 中的颜色随系统深浅色自动切换的关键：
        // backgroundColor / titleTextAttributes 使用的是动态系统色（labelColor / systemWhite），
        // 因此切换深浅模式时无需重建。traitCollectionDidChange 仍会再次调用本函数兜底。
        bar.tintColor = XJAccent();
    } else {
        // iOS 12 及以下：老接口
        UIColor *bg = [UIColor whiteColor];
        bar.barStyle = UIBarStyleDefault;
        [bar setBackgroundImage:[UIImage new] forBarMetrics:UIBarMetricsDefault];
        bar.barTintColor = bg;
        bar.shadowImage = [UIImage new];
        bar.tintColor = XJAccent();
        [bar setTitleTextAttributes:@{
            NSForegroundColorAttributeName: [UIColor blackColor],
            NSFontAttributeName: [UIFont boldSystemFontOfSize:17]
        }];
    }
}

// 创建简洁设置入口卡片（单行：图标 + 标题 + 箭头，宽度跟随 table 自适应）
static void XJInjectSettingsButton(UIViewController *vc) {
    if (objc_getAssociatedObject(vc, "payhook_injected")) return;
    if (!vc.isViewLoaded || !vc.view.window) return;

    UITableView *tv = XJFindTableView(vc.view);
    if (!tv) return;
    objc_setAssociatedObject(vc, "payhook_injected", @(1), OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    CGFloat cardH = 48;   // 紧凑单行高度
    CGFloat iconSize = 22;

    // 外层容器（tableHeaderView），高度包裹卡片，宽度跟随 table
    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, tv.bounds.size.width, cardH + 8)];
    header.backgroundColor = [UIColor clearColor];

    // 主卡片按钮（用 AutoLayout 适配左右边距与宽度）
    UIButton *card = [UIButton buttonWithType:UIButtonTypeCustom];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    card.layer.cornerRadius = 10;
    card.layer.masksToBounds = YES;
    [card addTarget:vc action:@selector(payhook_openSettings) forControlEvents:UIControlEventTouchUpInside];

    // 按下时轻微缩放反馈
    [card addTarget:card action:@selector(xj_touchDown:) forControlEvents:UIControlEventTouchDown];
    [card addTarget:card action:@selector(xj_touchUp:) forControlEvents:(UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel)];

    [header addSubview:card];
    [header addConstraints:@[
        [card.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:16],
        [card.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-16],
        [card.topAnchor constraintEqualToAnchor:header.topAnchor constant:4],
        [card.heightAnchor constraintEqualToConstant:cardH],
    ]];

    // 左侧 ¥ 图标（单字符，无圆形容器，更简洁）
    UILabel *iconLabel = [[UILabel alloc] init];
    iconLabel.translatesAutoresizingMaskIntoConstraints = NO;
    iconLabel.text = XJ_T(@"wqU=");
    iconLabel.font = [UIFont boldSystemFontOfSize:16];
    iconLabel.textColor = XJAdaptiveTextColor();
    iconLabel.textAlignment = NSTextAlignmentCenter;
    [card addSubview:iconLabel];

    // 中间标题（单行）
    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    titleLabel.text = XJ_T(@"UGF5SG9vayDmlLbmrL7nm5Hmjqc=");
    titleLabel.font = [UIFont systemFontOfSize:15];
    titleLabel.textColor = XJAdaptiveTextColor();
    [card addSubview:titleLabel];

    // 右侧箭头
    UIImageView *chevron = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"chevron.right"]];
    if (chevron.image) {
        chevron.translatesAutoresizingMaskIntoConstraints = NO;
        chevron.tintColor = [UIColor tertiaryLabelColor];
        chevron.contentMode = UIViewContentModeScaleAspectFit;
        [card addSubview:chevron];
        [NSLayoutConstraint activateConstraints:@[
            [chevron.centerYAnchor constraintEqualToAnchor:card.centerYAnchor],
            [chevron.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-12],
            [chevron.widthAnchor constraintEqualToConstant:9],
            [chevron.heightAnchor constraintEqualToConstant:14],
        ]];
    } else {
        // iOS < 13 fallback：用文字箭头
        UILabel *chevLbl = [[UILabel alloc] init];
        chevLbl.translatesAutoresizingMaskIntoConstraints = NO;
        chevLbl.text = XJ_T(@"4oC6");
        chevLbl.font = [UIFont systemFontOfSize:18 weight:UIFontWeightLight];
        chevLbl.textColor = [UIColor tertiaryLabelColor];
        chevLbl.textAlignment = NSTextAlignmentCenter;
        [card addSubview:chevLbl];
        [NSLayoutConstraint activateConstraints:@[
            [chevLbl.centerYAnchor constraintEqualToAnchor:card.centerYAnchor],
            [chevLbl.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-12],
        ]];
    }

    // 图标与标题布局
    [NSLayoutConstraint activateConstraints:@[
        [iconLabel.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:12],
        [iconLabel.centerYAnchor constraintEqualToAnchor:card.centerYAnchor],
        [iconLabel.widthAnchor constraintEqualToConstant:iconSize],
        [titleLabel.leadingAnchor constraintEqualToAnchor:iconLabel.trailingAnchor constant:8],
        [titleLabel.centerYAnchor constraintEqualToAnchor:card.centerYAnchor],
        [titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:card.trailingAnchor constant:-28],
    ]];

    // 监听 table 尺寸变化，同步 header 宽度（旋转/分屏等场景）
    objc_setAssociatedObject(vc, "payhook_header", header, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    tv.tableHeaderView = header;
    // 强制布局，确保 header 宽度立即跟随 table 宽度
    [tv layoutIfNeeded];
}

// 按钮触摸反馈（缩放动画）
@interface UIButton (XJTouchFeedback)
- (void)xj_touchDown:(id)sender;
- (void)xj_touchUp:(id)sender;
@end
@implementation UIButton (XJTouchFeedback)
- (void)xj_touchDown:(id)sender {
    [UIView animateWithDuration:0.12 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
        self.transform = CGAffineTransformMakeScale(0.97, 0.97);
        self.alpha = 0.9;
    } completion:nil];
}
- (void)xj_touchUp:(id)sender {
    [UIView animateWithDuration:0.2 delay:0 usingSpringWithDamping:0.6 initialSpringVelocity:0.5 options:UIViewAnimationOptionCurveEaseInOut animations:^{
        self.transform = CGAffineTransformIdentity;
        self.alpha = 1.0;
    } completion:nil];
}
@end

%hook UIViewController
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    NSString *cls = NSStringFromClass([self class]);
    if (XJIsMainSettingsVC(cls)) {
        XJInjectSettingsButton(self);
    }
}
%end

// ============================================================
// MARK: - Constructor
// ============================================================

%ctor {
    @autoreleasepool {
        XJLoadConfig();

        NSLog(@"[PayHook] ============================================");
        NSLog(@"[PayHook]   PayHook v3.0 Loaded (%@)", kXJAuthor);
        NSLog(@"[PayHook]   Server:  %@", kServerURL);
        NSLog(@"[PayHook]   Monitor: %@", kMonitorName);
        NSLog(@"[PayHook] ============================================");

        %init(HookOnNewMessage);
        %init(HookOnRecvMsg);
        %init(HookAsyncOnAddMsgWrap);
        %init(HookAsyncOnAddMsgType);
        %init(HookSyncProcess);
        %init(HookMainDispatcher);
        %init;

        // 通知授权 (用于订单匹配成功通知)
        if (@available(iOS 10.0, *)) {
            sNotifDelegate = [[XJNotificationDelegate alloc] init];
            UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
            center.delegate = sNotifDelegate;
            [center requestAuthorizationWithOptions:(UNAuthorizationOptionAlert | UNAuthorizationOptionSound | UNAuthorizationOptionBadge)
                                  completionHandler:^(BOOL granted, NSError *e){
                NSLog(@"[PayHook] Notification auth granted=%d", granted);
            }];
        }

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)),
                       dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
            @try {
                [[XJRemoteConfig sharedInstance] loadLocalCache];
                [[XJRemoteConfig sharedInstance] fetchRemoteConfig];
                // 注意：检测来源强制仅「微信收款助手」，不再用远程白名单覆盖
                Class mgrClass = objc_getClass("CMessageMgr");
                if (mgrClass) {
                    unsigned int mc = 0;
                    Method *methods = class_copyMethodList(mgrClass, &mc);
                    NSMutableArray *msgMethods = [NSMutableArray array];
                    for (unsigned int i = 0; i < mc && i < 200; i++) {
                        NSString *sel = NSStringFromSelector(method_getName(methods[i]));
                        if ([sel containsString:@"Msg"] || [sel containsString:@"Message"]) [msgMethods addObject:sel];
                    }
                    free(methods);
                    NSLog(@"[PayHook] CMessageMgr Msg methods: %@", msgMethods);
                }
            } @catch (NSException *e) {
                NSLog(@"[PayHook] Init error: %@", e);
            }

            dispatch_async(dispatch_get_main_queue(), ^{
                XJRemoteConfig *cfg = [XJRemoteConfig sharedInstance];
                // 首次进入：改用微信自带提示框（不再用自定义卡片）
                static NSString *const kXJFirstLaunchKey = @"com.xj.wechatpay.firstlaunch";
                NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
                if (![ud boolForKey:kXJFirstLaunchKey] && kVisualFeedback) {
                    XJShowWeChatToast(XJ_T(@"UGF5SG9vayDlt7LliqDovb1cbuaUtuasvuebkeaOp+W3suWwsee7qg=="));
                    [ud setBool:YES forKey:kXJFirstLaunchKey];
                    [ud synchronize];
                }
            });
        });
    }
}

//
//  XJRemoteConfig.m
//  XJWeChatPay — 远程配置实现
//

#import "XJRemoteConfig.h"

// [AUTO] 中文运行时还原 (规避 L1ghtmann clang UTF-8 字面量 bug)
static inline NSString *xj_ls(NSString *b64) {
    if (!b64) return @"";
    NSData *d = [[NSData alloc] initWithBase64EncodedString:b64 options:0];
    return d ? ([[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] ?: @"") : @"";
}
#define XJ_T(b64) xj_ls(b64)
// [/AUTO]

/// 远程配置 URL（可从本地 plist 覆盖）
static NSString *kRemoteConfigURL = @"https://raw.githubusercontent.com/curtinlv/XJWeChatPay-config/main/config.json";

/// 本地缓存路径
static NSString *kLocalCachePath = @"/var/mobile/Library/Preferences/com.xj.wechatpay.remote.plist";

/// 默认更新间隔：1 小时
static NSTimeInterval kDefaultUpdateInterval = 3600.0;

@interface XJRemoteConfig ()
@property (nonatomic, strong) NSArray<NSString *> *paymentKeywords;
@property (nonatomic, strong) NSArray<NSString *> *amountRegexes;
@property (nonatomic, strong) NSArray<NSString *> *paySourceIds;
@property (nonatomic, strong) NSDictionary<NSString *, NSString *> *payTypeMapping;
@property (nonatomic, assign) NSTimeInterval lastUpdateTime;
@property (nonatomic, copy) NSString *configVersion;
@end

@implementation XJRemoteConfig

+ (instancetype)sharedInstance {
    static XJRemoteConfig *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[XJRemoteConfig alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        [self loadDefaults];
    }
    return self;
}

#pragma mark - Defaults

- (void)loadDefaults {
    // 内置默认配置 — 即使远程拉取失败也能正常工作
    self.paymentKeywords = @[
        XJ_T(@"5pS25qy+5Yiw6LSm6YCa55+l"), XJ_T(@"5pS25qy+6YeR6aKd"), XJ_T(@"5Yiw6LSm6YeR6aKd"), XJ_T(@"5pS25qy+5oiQ5Yqf"),
        XJ_T(@"5b6u5L+h5pSv5LuY5pS25qy+"), XJ_T(@"5pyL5Y+L5Yiw5bqX5LuY5qy+"), XJ_T(@"5bey5a2Y5YWl6Zu26ZKx"),
        XJ_T(@"5Liq5Lq65pS25qy+56CB5Yiw6LSm"), XJ_T(@"5LqM57u056CB5pS25qy+5Yiw6LSm"), XJ_T(@"5pS25qy+5bCP6LSm5pys"),
        @"paymsg", @"delpaymsg", @"wxpay", XJ_T(@"5b6u5L+h6L2s6LSm"),
        XJ_T(@"5pS25Yiw6L2s6LSm"), XJ_T(@"5bey5pS25qy+"), XJ_T(@"5LuY5qy+5oiQ5Yqf")
    ];

    self.amountRegexes = @[
        XJ_T(@"5pS25qy+KD866YeR6aKdfOWIsOi0pnzmiJDlip8pWzrvvJpcXHNdKlvvv6XCpV0/XFxzKihbMC05XStcXC4/WzAtOV17MCwyfSlcXHMq5YWDPw=="),
        XJ_T(@"5Yiw6LSm6YeR6aKdWzrvvJpcXHNdKlvvv6XCpV0/XFxzKihbMC05XStcXC4/WzAtOV17MCwyfSlcXHMq5YWDPw=="),
        XJ_T(@"5a6e5pS26YeR6aKdWzrvvJpcXHNdKlvvv6XCpV0/XFxzKihbMC05XStcXC4/WzAtOV17MCwyfSk="),
        @"<amount>([0-9]+)</amount>",
        XJ_T(@"PGRlcz5bXjxdKj8oWzAtOV0rXFwuP1swLTldezAsMn0pXFxzKuWFg1tePF0qPzwvZGVzPg=="),
        XJ_T(@"5LuY5qy+XFxzKihbMC05XStcXC4/WzAtOV17MCwyfSlcXHMq5YWD"),
        XJ_T(@"KFswLTldK1xcLlswLTldezEsMn0pXFxzKuWFgw=="),
        XJ_T(@"W++/pcKlXVxccyooWzAtOV0rXFwuP1swLTldezAsMn0p"),
        XJ_T(@"5pS25Yiw6L2s6LSmXFxzKihbMC05XStcXC4/WzAtOV17MCwyfSlcXHMq5YWD"),
    ];

    self.paySourceIds = @[
        @"gh_f0a92aa7146c",   // 微信收款助手（唯一检测来源）
    ];

    self.payTypeMapping = @{
        @"1":    @"transfer",              // 转账
        @"3":    @"receive_confirm",       // 收款回执
        @"2000": @"transfer",              // appmsg type=2000 转账
    };
}

#pragma mark - Local Cache

- (void)loadLocalCache {
    NSDictionary *cache = [NSDictionary dictionaryWithContentsOfFile:kLocalCachePath];
    if (!cache) return;

    [self applyConfig:cache];
    NSLog(@"[XJPay][Config] Loaded local cache, version=%@", self.configVersion);
}

- (void)saveLocalCache:(NSDictionary *)config {
    [config writeToFile:kLocalCachePath atomically:YES];
}

#pragma mark - Remote Fetch

- (void)fetchRemoteConfig {
    // 读取本地 plist 中配置的 URL（允许用户自定义）
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:
                           @"/var/mobile/Library/Preferences/com.xj.wechatpay.plist"];
    NSString *urlStr = prefs[@"remote_config_url"];
    if (!urlStr || urlStr.length == 0) {
        urlStr = kRemoteConfigURL;
    }

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSURL *url = [NSURL URLWithString:urlStr];
        NSURLRequest *request = [NSURLRequest requestWithURL:url
                                                 cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                             timeoutInterval:15.0];

        NSURLSessionDataTask *task = [[NSURLSession sharedSession]
            dataTaskWithRequest:request
              completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {

            if (error || !data) {
                NSLog(@"[XJPay][Config] Remote fetch failed: %@, using local cache",
                      error.localizedDescription);
                return;
            }

            NSError *jsonErr = nil;
            NSDictionary *config = [NSJSONSerialization JSONObjectWithData:data
                                                                   options:0
                                                                     error:&jsonErr];
            if (jsonErr || !config) {
                NSLog(@"[XJPay][Config] JSON parse failed: %@", jsonErr.localizedDescription);
                return;
            }

            // 版本检查：跳过旧版本
            NSString *remoteVersion = config[@"version"];
            if (remoteVersion && self.configVersion) {
                if ([remoteVersion compare:self.configVersion options:NSNumericSearch] != NSOrderedDescending) {
                    // 已经是最新或更新版本，但允许覆盖
                }
            }

            [self applyConfig:config];
            [self saveLocalCache:config];

            NSLog(@"[XJPay][Config] Remote config loaded: version=%@, keywords=%lu, sources=%lu",
                  remoteVersion,
                  (unsigned long)self.paymentKeywords.count,
                  (unsigned long)self.paySourceIds.count);
        }];

        [task resume];
    });
}

- (void)forceRefresh {
    self.configVersion = nil;
    self.lastUpdateTime = 0;
    [self fetchRemoteConfig];
}

#pragma mark - Config Application

- (void)applyConfig:(NSDictionary *)config {
    // 关键词
    NSArray *keywords = config[@"payment_keywords"];
    if (keywords && [keywords isKindOfClass:[NSArray class]] && keywords.count > 0) {
        self.paymentKeywords = keywords;
    }

    // 金额正则
    NSArray *regexes = config[@"amount_regexes"];
    if (regexes && [regexes isKindOfClass:[NSArray class]] && regexes.count > 0) {
        self.amountRegexes = regexes;
    }

    // 公众号白名单
    NSArray *sources = config[@"pay_source_ids"];
    if (sources && [sources isKindOfClass:[NSArray class]] && sources.count > 0) {
        self.paySourceIds = sources;
    }

    // payType 映射
    NSDictionary *mapping = config[@"pay_type_mapping"];
    if (mapping && [mapping isKindOfClass:[NSDictionary class]] && mapping.count > 0) {
        self.payTypeMapping = mapping;
    }

    // 元信息
    self.configVersion = config[@"version"];
    self.lastUpdateTime = [[NSDate date] timeIntervalSince1970];
}

@end

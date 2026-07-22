//
//  XJPaymentXMLParser.m
//  XJWeChatPay — NSXMLParser 实现
//

#import "XJPaymentXMLParser.h"

#pragma mark - XJPaymentXMLResult

@implementation XJPaymentXMLResult

- (BOOL)hasPayInfo {
    return self.paysubtype.length > 0 || self.feedesc.length > 0;
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<XJPaymentXMLResult: type=%@ sub=%@ amount=%@ txid=%@>",
            self.appmsgType, self.paysubtype, self.feedesc, self.transcationid];
}

@end


#pragma mark - XJPaymentXMLParser

@interface XJPaymentXMLParser () <NSXMLParserDelegate>
@property (nonatomic, strong) XJPaymentXMLResult *result;
@property (nonatomic, strong) NSMutableString *currentElementValue;
@property (nonatomic, copy) NSString *currentElementName;
@property (nonatomic, assign) BOOL inWCPayInfo;
@property (nonatomic, assign) BOOL inAppMsg;
@property (nonatomic, assign) BOOL foundPayment;
@end

@implementation XJPaymentXMLParser

+ (BOOL)isPaymentXML:(NSString *)xmlString {
    if (xmlString.length == 0) return NO;
    // 容错：去前后空白，放宽根节点（<msg>/<sysmsg>/<?xml 均可）
    NSString *s = [xmlString stringByTrimmingCharactersInSet:
                   [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (s.length == 0) return NO;
    BOOL hasPayNode = [s containsString:@"<wcpayinfo>"] ||
                      [s containsString:@"<type>2000</type>"] ||
                      [s containsString:@"<wcpayinfo "];
    if (!hasPayNode) return NO;
    return [s hasPrefix:@"<msg>"] || [s hasPrefix:@"<sysmsg>"] || [s hasPrefix:@"<?xml"];
}

+ (BOOL)isPaymentContent:(NSString *)text {
    // 结尾兜底：即使 root 标签不匹配，只要含 wcpayinfo 关键节点也认为是支付 XML
    if (text.length == 0) return NO;
    return [text containsString:@"<wcpayinfo>"] || [text containsString:@"<type>2000</type>"];
}

+ (XJPaymentXMLResult *)parse:(NSString *)xmlString {
    if (xmlString.length == 0) return nil;
    // 放宽：只要含支付节点即尝试解析（不再强制 <msg> 前缀）
    if (![self isPaymentContent:xmlString]) return nil;

    XJPaymentXMLParser *parser = [[XJPaymentXMLParser alloc] init];
    NSData *data = [xmlString dataUsingEncoding:NSUTF8StringEncoding];
    if (!data) return nil;

    NSXMLParser *xmlParser = [[NSXMLParser alloc] initWithData:data];
    xmlParser.delegate = parser;
    xmlParser.shouldProcessNamespaces = NO;
    xmlParser.shouldReportNamespacePrefixes = NO;
    xmlParser.shouldResolveExternalEntities = NO;

    [xmlParser parse];

    if (parser.foundPayment && parser.result.hasPayInfo) {
        return parser.result;
    }
    return nil;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _result = [[XJPaymentXMLResult alloc] init];
        _currentElementValue = [[NSMutableString alloc] init];
    }
    return self;
}

#pragma mark - NSXMLParserDelegate

- (void)parser:(NSXMLParser *)parser
didStartElement:(NSString *)elementName
  namespaceURI:(NSString *)namespaceURI
 qualifiedName:(NSString *)qName
    attributes:(NSDictionary<NSString *,NSString *> *)attributeDict {

    self.currentElementName = elementName;
    [self.currentElementValue setString:@""];

    if ([elementName isEqualToString:@"appmsg"]) {
        self.inAppMsg = YES;
    } else if ([elementName isEqualToString:@"wcpayinfo"]) {
        self.inWCPayInfo = YES;
        self.foundPayment = YES;
    }
}

- (void)parser:(NSXMLParser *)parser foundCharacters:(NSString *)string {
    [self.currentElementValue appendString:string];
}

- (void)parser:(NSXMLParser *)parser
 didEndElement:(NSString *)elementName
  namespaceURI:(NSString *)namespaceURI
 qualifiedName:(NSString *)qName {

    NSString *value = [self.currentElementValue stringByTrimmingCharactersInSet:
                       [NSCharacterSet whitespaceAndNewlineCharacterSet]];

    if ([elementName isEqualToString:@"appmsg"]) {
        self.inAppMsg = NO;
    } else if ([elementName isEqualToString:@"wcpayinfo"]) {
        self.inWCPayInfo = NO;
    }
    // --- appmsg 层级字段 ---
    else if (self.inAppMsg && !self.inWCPayInfo) {
        if ([elementName isEqualToString:@"type"]) {
            self.result.appmsgType = value;
        } else if ([elementName isEqualToString:@"title"]) {
            self.result.title = value;
        } else if ([elementName isEqualToString:@"des"]) {
            self.result.des = value;
        }
    }
    // --- wcpayinfo 层级字段 ---
    else if (self.inWCPayInfo) {
        if ([elementName isEqualToString:@"paysubtype"]) {
            self.result.paysubtype = value;
        } else if ([elementName isEqualToString:@"feedesc"]) {
            self.result.feedesc = value;
        } else if ([elementName isEqualToString:@"transcationid"]) {
            self.result.transcationid = value;
        } else if ([elementName isEqualToString:@"transferid"]) {
            self.result.transferid = value;
        } else if ([elementName isEqualToString:@"invalidtime"]) {
            self.result.invalidtime = value;
        } else if ([elementName isEqualToString:@"begintransfertime"]) {
            self.result.begintransfertime = value;
        } else if ([elementName isEqualToString:@"effectivedate"]) {
            self.result.effectivedate = value;
        } else if ([elementName isEqualToString:@"pay_memo"]) {
            self.result.payMemo = value;
        }
    }

    self.currentElementName = nil;
}

- (void)parser:(NSXMLParser *)parser parseErrorOccurred:(NSError *)parseError {
    // XML 解析错误静默处理，返回已解析的部分
    NSLog(@"[XJPay][XML] Parse error: %@", parseError.localizedDescription);
}

@end

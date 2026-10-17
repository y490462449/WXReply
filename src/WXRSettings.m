#import "WXRSettings.h"
#import "WXRSettingsEntry.h"
#import "WXRAutoReply.h"
#import "WXRSendProbe.h"
#import "WXRGroupMonitor.h"
#import "WXROverrides.h"
#import "WXRWeChat.h"
#import "WXRPrefs.h"
#import "WXRLog.h"
#import "WXRCommon.h"

typedef NS_ENUM(NSInteger, WXRRowKind) {
    WXRRowKindSwitch,
    WXRRowKindText,
    WXRRowKindNumber,
    WXRRowKindAction,
    WXRRowKindInfo,
};

@interface WXRRow : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *detail;
@property (nonatomic, copy) NSString *key;
@property (nonatomic, assign) WXRRowKind kind;
@property (nonatomic, copy) void (^action)(void);
+ (instancetype)row:(NSString *)title kind:(WXRRowKind)kind key:(NSString *)key;
@end

@implementation WXRRow
+ (instancetype)row:(NSString *)title kind:(WXRRowKind)kind key:(NSString *)key {
    WXRRow *row = [[WXRRow alloc] init];
    row.title = title;
    row.kind = kind;
    row.key = key;
    return row;
}
@end

/* ================= 多行/单行文本编辑页 ================= */

@interface WXRTextEditorViewController : UIViewController <UITextViewDelegate>
@property (nonatomic, copy) NSString *configKey;
@property (nonatomic, copy) NSString *initialText;
@property (nonatomic, copy) NSString *hint;
@property (nonatomic, assign) BOOL isNumber;
@property (nonatomic, copy) void (^onSaved)(void);
@end

@implementation WXRTextEditorViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
    self.title = self.hint.length ? self.hint : @"编辑";

    UITextView *textView = [[UITextView alloc] initWithFrame:CGRectInset(self.view.bounds, 12, 12)];
    textView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    textView.font = [UIFont systemFontOfSize:15];
    textView.text = self.initialText ?: @"";
    textView.keyboardType = self.isNumber ? UIKeyboardTypeNumbersAndPunctuation : UIKeyboardTypeDefault;
    textView.tag = 0x5754;
    textView.delegate = self;
    [self.view addSubview:textView];
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemSave
                                                      target:self
                                                      action:@selector(save)];
}

- (void)save {
    UITextView *textView = [self.view viewWithTag:0x5754];
    NSString *text = textView.text ?: @"";
    if (self.isNumber) {
        [[WXRPrefs shared] setObject:@([text integerValue]) forKey:self.configKey];
    } else {
        [[WXRPrefs shared] setObject:text forKey:self.configKey];
    }
    WXRLog(@"[settings] 保存 %@（%lu 字）", self.configKey, (unsigned long)text.length);
    if (self.onSaved) {
        self.onSaved();
    }
    [self.navigationController popViewControllerAnimated:YES];
}

@end

/* ================= 只读文本页 ================= */

@interface WXRTextPageViewController : UIViewController
@property (nonatomic, copy) NSString *body;
@property (nonatomic, copy) NSString *pageTitle;
@end

@implementation WXRTextPageViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.title = self.pageTitle;

    UITextView *textView = [[UITextView alloc] initWithFrame:self.view.bounds];
    textView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    textView.editable = NO;
    textView.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    textView.text = self.body ?: @"";
    [self.view addSubview:textView];

    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAction
                                                      target:self
                                                      action:@selector(share)];
}

- (void)share {
    UIActivityViewController *activity =
        [[UIActivityViewController alloc] initWithActivityItems:@[self.body ?: @""] applicationActivities:nil];
    [self presentViewController:activity animated:YES completion:nil];
}

@end

/* ================= 设置主界面 ================= */

@interface WXRSettingsViewController : UITableViewController
@property (nonatomic, strong) NSArray<NSArray<WXRRow *> *> *sections;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSString *> *switchKeys;
@property (nonatomic, assign) NSInteger nextSwitchTag;
- (void)close;
- (void)buildSections;
- (void)switchChanged:(UISwitch *)sender;
- (void)editRow:(WXRRow *)row;
- (void)runAITest;
- (void)testSend;
- (void)showMessage:(NSString *)text;
- (void)showLog;
- (void)showDiagnostics;
- (void)resetAll;
@end

@implementation WXRSettingsViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"自动回复";
    self.switchKeys = [NSMutableDictionary dictionary];
    self.tableView.rowHeight = 48;
    [self buildSections];
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                      target:self
                                                      action:@selector(close)];
}

- (void)close {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)buildSections {
    WXRPrefs *prefs = [WXRPrefs shared];
    NSMutableArray<NSArray<WXRRow *> *> *sections = [NSMutableArray array];

    /* ---- 1. 自动回复 ---- */
    NSMutableArray<WXRRow *> *basic = [NSMutableArray array];
    WXRRow *enable = [WXRRow row:@"自动回复" kind:WXRRowKindSwitch key:WXRKeyEnabled];
    [basic addObject:enable];
    [basic addObject:[WXRRow row:@"只回私聊" kind:WXRRowKindSwitch key:WXRKeyPrivateOnly]];
    [basic addObject:[WXRRow row:@"群里仅在 @我 时回复" kind:WXRRowKindSwitch key:WXRKeyGroupMentionOnly]];
    WXRRow *cooldown = [WXRRow row:@"同会话冷却" kind:WXRRowKindNumber key:WXRKeyCooldown];
    cooldown.detail = [NSString stringWithFormat:@"%ld 秒", (long)[prefs integerForKey:WXRKeyCooldown]];
    [basic addObject:cooldown];
    [sections addObject:basic];

    /* ---- 2. 回复内容 ---- */
    NSMutableArray<WXRRow *> *content = [NSMutableArray array];
    WXRRow *def = [WXRRow row:@"默认回复" kind:WXRRowKindText key:WXRKeyDefaultReply];
    NSString *defText = [prefs stringForKey:WXRKeyDefaultReply];
    def.detail = defText.length > 12 ? [[defText substringToIndex:12] stringByAppendingString:@"…"] : defText;
    [content addObject:def];
    WXRRow *rules = [WXRRow row:@"关键词规则" kind:WXRRowKindText key:WXRKeyRules];
    rules.detail = [NSString stringWithFormat:@"%ld 条", (long)[self ruleCount]];
    [content addObject:rules];
    [sections addObject:content];

    /* ---- 3. AI（可选） ---- */
    NSMutableArray<WXRRow *> *ai = [NSMutableArray array];
    [ai addObject:[WXRRow row:@"用 AI 生成回复" kind:WXRRowKindSwitch key:WXRKeyAIEnabled]];
    WXRRow *baseURL = [WXRRow row:@"接口地址" kind:WXRRowKindText key:WXRKeyAIBaseURL];
    baseURL.detail = [self shortDetail:[prefs stringForKey:WXRKeyAIBaseURL]];
    [ai addObject:baseURL];
    NSString *key = [prefs stringForKey:WXRKeyAIAPIKey];
    WXRRow *apiKey = [WXRRow row:@"API Key" kind:WXRRowKindText key:WXRKeyAIAPIKey];
    apiKey.detail = key.length ? @"已填写" : @"未填写";
    [ai addObject:apiKey];
    WXRRow *model = [WXRRow row:@"模型名" kind:WXRRowKindText key:WXRKeyAIModel];
    model.detail = [self shortDetail:[prefs stringForKey:WXRKeyAIModel]];
    [ai addObject:model];
    [ai addObject:[WXRRow row:@"系统提示词" kind:WXRRowKindText key:WXRKeyAISystemPrompt]];
    WXRRow *maxLen = [WXRRow row:@"回复最大字数" kind:WXRRowKindNumber key:WXRKeyAIMaxLength];
    maxLen.detail = [NSString stringWithFormat:@"%ld", (long)[prefs integerForKey:WXRKeyAIMaxLength]];
    [ai addObject:maxLen];
    WXRRow *temp = [WXRRow row:@"温度（AI 随机性，0~2）" kind:WXRRowKindNumber key:WXRKeyAITemperature];
    temp.detail = [NSString stringWithFormat:@"%.1f（越大越发散，0.7 合适）",
                   [prefs doubleForKey:WXRKeyAITemperature]];
    [ai addObject:temp];
    WXRRow *ctx = [WXRRow row:@"带入上下文条数（读取会话历史）" kind:WXRRowKindNumber key:WXRKeyAIContextMessages];
    ctx.detail = [NSString stringWithFormat:@"%ld 条（回复前读最近几条真实消息）",
                  (long)[prefs integerForKey:WXRKeyAIContextMessages]];
    [ai addObject:ctx];
    WXRRow *test = [WXRRow row:@"测试 AI 连接" kind:WXRRowKindAction key:nil];
    __weak typeof(self) weakSelf = self;
    test.action = ^{ [weakSelf runAITest]; };
    [ai addObject:test];
    [sections addObject:ai];

    /* ---- 4. 群消息监控 ---- */
    NSMutableArray<WXRRow *> *monitor = [NSMutableArray array];
    [monitor addObject:[WXRRow row:@"监控群消息关键词" kind:WXRRowKindSwitch key:WXRKeyMonitorEnabled]];
    WXRRow *keywords = [WXRRow row:@"关键词（每行一个）" kind:WXRRowKindText key:WXRKeyMonitorKeywords];
    keywords.detail = [self shortDetail:[prefs stringForKey:WXRKeyMonitorKeywords]];
    [monitor addObject:keywords];
    [monitor addObject:[WXRRow row:@"命中后转发给我" kind:WXRRowKindSwitch key:WXRKeyMonitorForward]];
    [monitor addObject:[WXRRow row:@"记录命中" kind:WXRRowKindSwitch key:WXRKeyMonitorRecord]];
    WXRRow *monitorStatus = [WXRRow row:@"监控状态" kind:WXRRowKindInfo key:nil];
    monitorStatus.detail = [WXRGroupMonitor statusLine];
    [monitor addObject:monitorStatus];
    WXRRow *hitsRow = [WXRRow row:@"查看最近命中" kind:WXRRowKindAction key:nil];
    hitsRow.action = ^{
        [WXRSettings presentTextPageWithTitle:@"群关键词命中记录"
                                         text:[WXRGroupMonitor recentHitsText]];
    };
    [monitor addObject:hitsRow];
    WXRRow *forwardTestRow = [WXRRow row:@"转发测试（发给我自己）" kind:WXRRowKindAction key:nil];
    forwardTestRow.action = ^{
        [WXRGroupMonitor testForwardLastHit];
        [weakSelf showMessage:@"已尝试转发一条测试消息到你自己，请看你自己那个聊天窗口。"];
    };
    [monitor addObject:forwardTestRow];
    [sections addObject:monitor];

    /* ---- 5. 入口与诊断 ---- */
    NSMutableArray<WXRRow *> *diag = [NSMutableArray array];
    [diag addObject:[WXRRow row:@"长按标签栏打开设置" kind:WXRRowKindSwitch key:WXRKeyTabBarLongPress]];
    WXRRow *status = [WXRRow row:@"运行状态" kind:WXRRowKindInfo key:nil];
    status.detail = [NSString stringWithFormat:@"%@ ｜ %@", [WXRAutoReply statusLine], [WXRSendProbe summary]];
    [diag addObject:status];
    WXRRow *tryAllRow = [WXRRow row:@"试遍所有发送方式（每个 3 秒）" kind:WXRRowKindAction key:nil];
    tryAllRow.action = ^{
        NSString *session = [WXRAutoReply lastPrivateSession];
        if (!session.length) {
            [weakSelf showMessage:@"还没有收到过私聊消息，先让人给你发一条。"];
            return;
        }
        WXRLog(@"[settings] 开始试遍所有发送方式，会话=%@", session);
        [WXRWeChat tryAllSendAttemptsForSession:session text:@"测试"];
        [weakSelf showMessage:@"已开始依次尝试所有发送方式（每种等 3 秒），请看日志里的 [send] 行。"];
    };
    [diag addObject:tryAllRow];
    WXRRow *testSendRow = [WXRRow row:@"测试发送（上一条私聊会话）" kind:WXRRowKindAction key:nil];
    testSendRow.action = ^{ [weakSelf testSend]; };
    [diag addObject:testSendRow];
    WXRRow *logRow = [WXRRow row:@"查看日志" kind:WXRRowKindAction key:nil];
    logRow.action = ^{ [weakSelf showLog]; };
    [diag addObject:logRow];
    WXRRow *diagRow = [WXRRow row:@"诊断报告（含候选名）" kind:WXRRowKindAction key:nil];
    diagRow.action = ^{ [weakSelf showDiagnostics]; };
    [diag addObject:diagRow];
    WXRRow *clearRow = [WXRRow row:@"清空会话冷却" kind:WXRRowKindAction key:nil];
    clearRow.action = ^{ [WXRAutoReply clearCooldown]; };
    [diag addObject:clearRow];
    [diag addObject:[WXRRow row:@"详细日志" kind:WXRRowKindSwitch key:WXRKeyVerboseLog]];
    [diag addObject:[WXRRow row:@"日志记录消息正文" kind:WXRRowKindSwitch key:WXRKeyLogContent]];
    WXRRow *overrideRow = [WXRRow row:@"候选名覆盖" kind:WXRRowKindText key:WXRKeyOverrideText];
    overrideRow.detail = [NSString stringWithFormat:@"%ld 条", (long)[WXROverrides overrideCount]];
    [diag addObject:overrideRow];
    WXRRow *resetRow = [WXRRow row:@"重置全部配置" kind:WXRRowKindAction key:nil];
    resetRow.action = ^{ [weakSelf resetAll]; };
    [diag addObject:resetRow];
    [sections addObject:diag];

    self.sections = sections;
    [self.tableView reloadData];
}

- (NSInteger)ruleCount {
    __block NSInteger count = 0;
    NSString *text = [[WXRPrefs shared] stringForKey:WXRKeyRules];
    for (NSString *line in [text componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (trimmed.length && ![trimmed hasPrefix:@"#"] &&
            ([trimmed rangeOfString:@"=>"].location != NSNotFound || [trimmed rangeOfString:@"="].location != NSNotFound)) {
            count++;
        }
    }
    return count;
}

- (NSString *)shortDetail:(NSString *)text {
    if (!text.length) {
        return @"未填写";
    }
    return text.length > 18 ? [[text substringToIndex:18] stringByAppendingString:@"…"] : text;
}

/* ---------------- 表格 ---------------- */

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return (NSInteger)self.sections.count;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)self.sections[(NSUInteger)section].count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    NSArray<NSString *> *titles = @[@"自动回复", @"回复内容", @"AI 回复（可选）", @"群消息监控", @"入口与诊断"];
    return section < (NSInteger)titles.count ? titles[(NSUInteger)section] : nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    WXRRow *row = self.sections[(NSUInteger)indexPath.section][(NSUInteger)indexPath.row];
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1
                                                  reuseIdentifier:nil];
    cell.textLabel.text = row.title;
    cell.detailTextLabel.text = row.detail;
    cell.detailTextLabel.textColor = [UIColor grayColor];

    if (row.kind == WXRRowKindSwitch) {
        BOOL on = [[WXRPrefs shared] boolForKey:row.key];
        UISwitch *toggle = [[UISwitch alloc] init];
        toggle.on = on;
        toggle.onTintColor = [UIColor colorWithRed:0.13 green:0.62 blue:0.28 alpha:1.0];
        NSInteger tag = self.nextSwitchTag++;
        self.switchKeys[@(tag)] = row.key;
        toggle.tag = tag;
        [toggle addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = toggle;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else if (row.kind == WXRRowKindAction || row.kind == WXRRowKindText || row.kind == WXRRowKindNumber) {
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else {
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.detailTextLabel.numberOfLines = 2;
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    WXRRow *row = self.sections[(NSUInteger)indexPath.section][(NSUInteger)indexPath.row];
    if (row.kind == WXRRowKindAction) {
        if (row.action) {
            row.action();
        }
        return;
    }
    if (row.kind == WXRRowKindText || row.kind == WXRRowKindNumber) {
        [self editRow:row];
    }
}

/* ---------------- 行为 ---------------- */

- (void)switchChanged:(UISwitch *)sender {
    NSString *key = self.switchKeys[@(sender.tag)];
    if (!key.length) {
        return;
    }
    [[WXRPrefs shared] setBool:sender.isOn forKey:key];
    WXRLog(@"[settings] %@ = %@", key, sender.isOn ? @"开" : @"关");
    [self buildSections];
    [WXRSettingsEntry refreshRowState];
}

- (void)editRow:(WXRRow *)row {
    WXRTextEditorViewController *editor = [[WXRTextEditorViewController alloc] init];
    editor.configKey = row.key;
    editor.hint = row.title;
    editor.isNumber = (row.kind == WXRRowKindNumber);
    editor.initialText = [[WXRPrefs shared] stringForKey:row.key] ?: @"";
    __weak typeof(self) weakSelf = self;
    editor.onSaved = ^{
        [weakSelf buildSections];
        [WXRSettingsEntry refreshRowState];
    };
    [self.navigationController pushViewController:editor animated:YES];
}

- (void)runAITest {
    WXRLog(@"[settings] 测试 AI 连接");
    [WXRAutoReply testAIConnection:^(BOOL ok, NSString *message) {
        dispatch_async(dispatch_get_main_queue(), ^{
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:ok ? @"连接正常" : @"连接失败"
                                                                          message:message
                                                                   preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:alert animated:YES completion:nil];
        });
    }];
}

- (void)testSend {
    NSString *session = [WXRAutoReply lastPrivateSession];
    if (!session.length) {
        [self showMessage:@"还没有收到过私聊消息。先让人给你发一条，让插件记下会话再测。"];
        return;
    }
    __weak typeof(self) weakSelf = self;
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"测试发送"
                         message:[NSString stringWithFormat:@"发到：%@", session]
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.text = @"测试";
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"发送" style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        NSString *text = alert.textFields.firstObject.text ?: @"测试";
        WXRLog(@"[settings] 测试发送到 %@：%@", session, text);
        BOOL called = [WXRWeChat sendText:text toSession:session];
        [weakSelf showMessage:called
            ? @"已调用发送接口。请看日志里的 [send] 行确认到底有没有真的发出去。"
            : @"没有可用的发送接口，请看日志里的 [send] 行。"];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)showMessage:(NSString *)text {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"提示"
                                                                  message:text
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)showLog {
    NSArray<NSString *> *lines = WXRLogSnapshot();
    [WXRSettings presentTextPageWithTitle:@"WXReply 日志"
                                     text:[lines componentsJoinedByString:@"\n"]];
}

- (void)showDiagnostics {
    NSArray<NSString *> *lines = WXRLogSnapshot();
    NSString *tail = lines.count > 120
        ? [[lines subarrayWithRange:NSMakeRange(lines.count - 120, 120)] componentsJoinedByString:@"\n"]
        : [lines componentsJoinedByString:@"\n"];
    NSString *text = [NSString stringWithFormat:@"%@\n\n%@\n\n===== 日志尾部 =====\n%@",
                      [WXRWeChat diagnosticReport],
                      [WXRWeChat candidateReport],
                      tail];
    [WXRSettings presentTextPageWithTitle:@"WXReply 诊断" text:text];
}

- (void)resetAll {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"重置全部配置？"
                                                                  message:@"所有设置都会回到默认值。"
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"重置" style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *action) {
        [[WXRPrefs shared] resetAll];
        [self buildSections];
        [WXRSettingsEntry refreshRowState];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end

/* ================= 对外入口 ================= */

@interface WXRSettings ()
+ (UIViewController *)topViewController;
@end

@implementation WXRSettings

+ (void)present {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *top = [self topViewController];
        if (!top) {
            WXRLog(@"[settings] 找不到可展示的控制器");
            return;
        }
        if ([top isKindOfClass:[UINavigationController class]] &&
            [[(UINavigationController *)top topViewController] isKindOfClass:[WXRSettingsViewController class]]) {
            return;   // 已经开着了
        }
        WXRSettingsViewController *settings =
            [[WXRSettingsViewController alloc] initWithStyle:UITableViewStyleGrouped];
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:settings];
        [top presentViewController:nav animated:YES completion:nil];
    });
}

+ (void)presentTextPageWithTitle:(NSString *)title text:(NSString *)text {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *top = [self topViewController];
        if (!top) {
            return;
        }
        WXRTextPageViewController *page = [[WXRTextPageViewController alloc] init];
        page.pageTitle = title;
        page.body = text;
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:page];
        [top presentViewController:nav animated:YES completion:nil];
    });
}

+ (UIViewController *)topViewController {
    UIWindow *key = nil;
    for (UIWindow *window in UIApplication.sharedApplication.windows.reverseObjectEnumerator) {
        if (window.isKeyWindow) {
            key = window;
            break;
        }
    }
    if (!key) {
        key = UIApplication.sharedApplication.windows.firstObject;
    }
    UIViewController *top = key.rootViewController;
    while (top.presentedViewController) {
        top = top.presentedViewController;
    }
    return top;
}

@end

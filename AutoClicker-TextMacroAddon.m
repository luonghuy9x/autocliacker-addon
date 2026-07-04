/**
 * AutoClicker-TextMacroAddon.m
 * ─────────────────────────────────────────────────────────────────────────────
 * Addon dylib cho AutoClicker TrollFools.
 * Gộp toàn bộ vào 1 file: hook keyboard input để ghi/replay văn bản
 * song song với touch recorder gốc (acp_recording.bin).
 *
 * Kỹ thuật hook:
 *   - Hook recorderRecordFromMenu / recorderStopFromMenu /
 *     recorderPlayFromMenu / recorderClearFromMenu (selectors có trong binary gốc)
 *     bằng MSHookMessageEx (CydiaSubstrate — đã có trong binary gốc).
 *   - Hook UITextField / UITextView insertText: + deleteBackward
 *     bằng method swizzle (không cần Substrate).
 *
 * Build (macOS + Xcode):
 *   clang -shared -fmodules -fobjc-arc \
 *     -isysroot $(xcrun --sdk iphoneos --show-sdk-path) \
 *     -miphoneos-version-min=14.0 \
 *     -arch arm64 -arch arm64e \
 *     -framework Foundation -framework UIKit \
 *     -o AutoClicker-TextMacroAddon.dylib \
 *     AutoClicker-TextMacroAddon.m
 *
 * Deploy: TrollFools → inject cùng lúc với AutoClicker-TrollFools.dylib.
 * ─────────────────────────────────────────────────────────────────────────────
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - Substrate / ElleKit shim
// ═══════════════════════════════════════════════════════════════════════════════

// MSHookMessageEx prototype — Cydia Substrate / ElleKit đều export symbol này
typedef void (*MSHookMessageEx_t)(Class cls, SEL sel, IMP imp, IMP *result);
static MSHookMessageEx_t _MSHookMessageEx = NULL;

static BOOL loadSubstrate(void) {
    // Thử các đường dẫn phổ biến (TrollFools, Dopamine, Unc0ver, Sideloadly)
    const char *paths[] = {
        "@loader_path/CydiaSubstrate.framework/CydiaSubstrate",
        "/var/jb/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate",
        "/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate",
        "@loader_path/libsubstrate.dylib",
        "/usr/lib/libsubstrate.dylib",
        "/var/jb/usr/lib/libsubstrate.dylib",
        // ElleKit (thay thế mới)
        "/var/jb/usr/lib/libsubstitute.dylib",
        NULL
    };
    for (int i = 0; paths[i]; i++) {
        void *h = dlopen(paths[i], RTLD_LAZY | RTLD_NOLOAD);
        if (!h) h = dlopen(paths[i], RTLD_LAZY);
        if (h) {
            _MSHookMessageEx = (MSHookMessageEx_t)dlsym(h, "MSHookMessageEx");
            if (_MSHookMessageEx) {
                NSLog(@"[TextMacro] Substrate loaded from %s", paths[i]);
                return YES;
            }
        }
    }
    NSLog(@"[TextMacro] Substrate not found — using pure swizzle fallback");
    return NO;
}

// Hook method: dùng Substrate nếu có, fallback về method_exchangeImplementations
static void hookMethod(Class cls, SEL sel, IMP newImp, IMP *oldImp) {
    if (_MSHookMessageEx) {
        _MSHookMessageEx(cls, sel, newImp, oldImp);
    } else {
        Method m = class_getInstanceMethod(cls, sel);
        if (!m) return;
        *oldImp = method_getImplementation(m);
        method_setImplementation(m, newImp);
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - Event model
// ═══════════════════════════════════════════════════════════════════════════════

typedef NS_ENUM(NSInteger, ACPTxtType) {
    ACPTxtInsert  = 0,  // gõ / paste text
    ACPTxtDelete  = 1,  // backspace
    ACPTxtClear   = 2,  // xóa hết field
    ACPTxtSetFull = 3,  // setText: trực tiếp
};

typedef struct {
    double       ts;      // giây tính từ lúc record start
    ACPTxtType   type;
    char         cls[64]; // UITextField / UITextView
    char         aid[64]; // accessibilityIdentifier
    // text theo sau struct nếu type == Insert / SetFull
} ACPTxtEventHeader;

// Lưu dưới dạng JSON để dễ debug
static NSString *gEventFile  = nil;  // path tới acp_recording_text.json
static NSMutableArray *gEvents = nil; // NSArray của NSDictionary khi recording

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - State
// ═══════════════════════════════════════════════════════════════════════════════

static BOOL   gIsRecording = NO;
static BOOL   gIsReplaying = NO;
static double gRecordStart = 0.0; // CACurrentMediaTime() khi start record

static inline double now(void) {
    extern double CACurrentMediaTime(void);
    return CACurrentMediaTime();
}

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - Record helpers
// ═══════════════════════════════════════════════════════════════════════════════

static void recordEvent(ACPTxtType type, NSString *text, UIView *view) {
    if (!gIsRecording || gIsReplaying) return;
    NSMutableDictionary *d = [@{
        @"ts":   @(now() - gRecordStart),
        @"type": @(type),
        @"cls":  NSStringFromClass([view class]) ?: @"",
        @"aid":  view.accessibilityIdentifier ?: @"",
    } mutableCopy];
    if (text) d[@"text"] = text;
    [gEvents addObject:[d copy]];
}

static void saveEvents(void) {
    if (gEvents.count == 0) return;
    NSError *err;
    NSData *data = [NSJSONSerialization dataWithJSONObject:gEvents
                                                   options:NSJSONWritingPrettyPrinted
                                                     error:&err];
    if (data) {
        [data writeToFile:gEventFile atomically:YES];
        NSLog(@"[TextMacro] Saved %lu events → %@", (unsigned long)gEvents.count, gEventFile);
    } else {
        NSLog(@"[TextMacro] Save error: %@", err);
    }
}

static NSArray<NSDictionary *> *loadEvents(void) {
    NSData *data = [NSData dataWithContentsOfFile:gEventFile];
    if (!data) return @[];
    NSError *err;
    NSArray *arr = [NSJSONSerialization JSONObjectWithData:data options:0 error:&err];
    if (!arr) { NSLog(@"[TextMacro] Load error: %@", err); return @[]; }
    return arr;
}

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - Replay helpers
// ═══════════════════════════════════════════════════════════════════════════════

static UIView *findFirstResponder(UIView *root) {
    if (root.isFirstResponder) return root;
    for (UIView *sub in root.subviews) {
        UIView *f = findFirstResponder(sub);
        if (f) return f;
    }
    return nil;
}

static UIView *findViewOfClass(Class cls, NSString *aid, UIView *root) {
    if ([root isKindOfClass:cls]) {
        if (!aid.length || [root.accessibilityIdentifier isEqualToString:aid]) return root;
    }
    for (UIView *sub in root.subviews) {
        UIView *f = findViewOfClass(cls, aid, sub);
        if (f) return f;
    }
    return nil;
}

static void injectTextEvent(NSDictionary *d) {
    ACPTxtType type = (ACPTxtType)[d[@"type"] integerValue];
    NSString  *text = d[@"text"];
    NSString  *cls  = d[@"cls"];
    NSString  *aid  = d[@"aid"];

    UIWindow *win = [UIApplication sharedApplication].keyWindow;
    UIView   *target = findFirstResponder(win);
    if (!target || (![target isKindOfClass:[UITextField class]] &&
                    ![target isKindOfClass:[UITextView class]])) {
        // Không có first responder phù hợp → tìm theo class
        Class c = NSClassFromString(cls);
        if (c) target = findViewOfClass(c, aid, win);
    }
    if (!target) {
        NSLog(@"[TextMacro] Replay: no target for cls=%@ aid=%@", cls, aid);
        return;
    }
    if (![target isFirstResponder]) [target becomeFirstResponder];

    switch (type) {
        case ACPTxtInsert:
            if ([target conformsToProtocol:@protocol(UIKeyInput)] && text)
                [(id<UIKeyInput>)target insertText:text];
            break;
        case ACPTxtDelete:
            if ([target conformsToProtocol:@protocol(UIKeyInput)])
                [(id<UIKeyInput>)target deleteBackward];
            break;
        case ACPTxtClear:
            if ([target isKindOfClass:[UITextField class]])
                ((UITextField *)target).text = @"";
            else if ([target isKindOfClass:[UITextView class]])
                ((UITextView *)target).text = @"";
            break;
        case ACPTxtSetFull:
            if ([target isKindOfClass:[UITextField class]]) {
                ((UITextField *)target).text = text ?: @"";
                [[NSNotificationCenter defaultCenter]
                    postNotificationName:UITextFieldTextDidChangeNotification object:target];
            } else if ([target isKindOfClass:[UITextView class]]) {
                ((UITextView *)target).text = text ?: @"";
                [[NSNotificationCenter defaultCenter]
                    postNotificationName:UITextViewTextDidChangeNotification object:target];
            }
            break;
    }
}

static void startReplay(double speed, NSInteger loops) {
    NSArray<NSDictionary *> *events = loadEvents();
    if (events.count == 0) {
        NSLog(@"[TextMacro] No text events to replay");
        return;
    }
    gIsReplaying = YES;
    NSLog(@"[TextMacro] Replaying %lu events speed=%.2f loops=%ld",
          (unsigned long)events.count, speed, (long)loops);

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        for (NSInteger loop = 0; loop < loops && gIsReplaying; loop++) {
            double loopStart = now();
            for (NSDictionary *d in events) {
                if (!gIsReplaying) break;
                double ts     = [d[@"ts"] doubleValue] / MAX(speed, 0.1);
                double target = loopStart + ts;
                double delta  = target - now();
                if (delta > 0) [NSThread sleepForTimeInterval:delta];

                dispatch_async(dispatch_get_main_queue(), ^{
                    injectTextEvent(d);
                });
            }
        }
        gIsReplaying = NO;
        NSLog(@"[TextMacro] Replay done");
    });
}

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - Hook: AutoClicker recorder methods
// ═══════════════════════════════════════════════════════════════════════════════
// Các selector này tồn tại trong ACPW_6fa18b (window/overlay class của gốc).
// Ta hook để biết khi nào user bấm RECORD / STOP / PLAY / CLEAR.

// --- Original IMPs (được điền bởi hookMethod) ---
static IMP orig_recorderRecordFromMenu = NULL;
static IMP orig_recorderStopFromMenu   = NULL;
static IMP orig_recorderPlayFromMenu   = NULL;
static IMP orig_recorderClearFromMenu  = NULL;

static void hook_recorderRecordFromMenu(id self, SEL _cmd) {
    // Gọi original trước
    if (orig_recorderRecordFromMenu)
        ((void(*)(id,SEL))orig_recorderRecordFromMenu)(self, _cmd);
    // Bắt đầu ghi text
    gEvents = [NSMutableArray new];
    gRecordStart = now();
    gIsRecording = YES;
    gIsReplaying = NO;
    NSLog(@"[TextMacro] Recording started");
}

static void hook_recorderStopFromMenu(id self, SEL _cmd) {
    if (orig_recorderStopFromMenu)
        ((void(*)(id,SEL))orig_recorderStopFromMenu)(self, _cmd);
    if (gIsRecording) {
        gIsRecording = NO;
        saveEvents();
    }
}

static void hook_recorderPlayFromMenu(id self, SEL _cmd) {
    if (orig_recorderPlayFromMenu)
        ((void(*)(id,SEL))orig_recorderPlayFromMenu)(self, _cmd);
    // Đọc speed/loops từ ivar nếu có, mặc định 1.0 / 1
    double speed = 1.0;
    NSInteger loops = 1;
    // Thử lấy từ CFPreferences (key giống binary gốc)
    CFPreferencesAppSynchronize(CFSTR("com.acp.prefs"));
    CFPropertyListRef sv = CFPreferencesCopyAppValue(CFSTR("recorderSpeed"), CFSTR("com.acp.prefs"));
    CFPropertyListRef lv = CFPreferencesCopyAppValue(CFSTR("recorderLoops"), CFSTR("com.acp.prefs"));
    if (sv) { speed = [(__bridge NSNumber *)sv doubleValue]; CFRelease(sv); }
    if (lv) { loops = [(__bridge NSNumber *)lv integerValue]; CFRelease(lv); }
    if (speed <= 0) speed = 1.0;
    if (loops <= 0) loops = 1;
    startReplay(speed, loops);
}

static void hook_recorderClearFromMenu(id self, SEL _cmd) {
    if (orig_recorderClearFromMenu)
        ((void(*)(id,SEL))orig_recorderClearFromMenu)(self, _cmd);
    gIsRecording = NO;
    gIsReplaying = NO;
    [gEvents removeAllObjects];
    [[NSFileManager defaultManager] removeItemAtPath:gEventFile error:nil];
    NSLog(@"[TextMacro] Events cleared");
}

// Stop replay khi user bấm STOP trong lúc đang play
static IMP orig_recorderFloatingStopPressed = NULL;
static void hook_recorderFloatingStopPressed(id self, SEL _cmd) {
    if (orig_recorderFloatingStopPressed)
        ((void(*)(id,SEL))orig_recorderFloatingStopPressed)(self, _cmd);
    gIsReplaying = NO;
}

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - Hook: UITextField keyboard input
// ═══════════════════════════════════════════════════════════════════════════════

static IMP orig_tf_insertText   = NULL;
static IMP orig_tf_deleteBackwd = NULL;
static IMP orig_tf_setText      = NULL;

static void hook_tf_insertText(UITextField *self, SEL _cmd, NSString *text) {
    recordEvent(ACPTxtInsert, text, self);
    ((void(*)(id,SEL,NSString *))orig_tf_insertText)(self, _cmd, text);
}
static void hook_tf_deleteBackward(UITextField *self, SEL _cmd) {
    recordEvent(ACPTxtDelete, nil, self);
    ((void(*)(id,SEL))orig_tf_deleteBackwd)(self, _cmd);
}
static void hook_tf_setText(UITextField *self, SEL _cmd, NSString *text) {
    if (gIsRecording) recordEvent(ACPTxtSetFull, text, self);
    ((void(*)(id,SEL,NSString *))orig_tf_setText)(self, _cmd, text);
}

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - Hook: UITextView keyboard input
// ═══════════════════════════════════════════════════════════════════════════════

static IMP orig_tv_insertText   = NULL;
static IMP orig_tv_deleteBackwd = NULL;

static void hook_tv_insertText(UITextView *self, SEL _cmd, NSString *text) {
    recordEvent(ACPTxtInsert, text, self);
    ((void(*)(id,SEL,NSString *))orig_tv_insertText)(self, _cmd, text);
}
static void hook_tv_deleteBackward(UITextView *self, SEL _cmd) {
    recordEvent(ACPTxtDelete, nil, self);
    ((void(*)(id,SEL))orig_tv_deleteBackwd)(self, _cmd);
}

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - Install hooks (chạy sau khi tất cả class đã load)
// ═══════════════════════════════════════════════════════════════════════════════

static void installHooks(void) {
    // --- UITextField ---
    hookMethod([UITextField class], @selector(insertText:),
               (IMP)hook_tf_insertText, &orig_tf_insertText);
    hookMethod([UITextField class], @selector(deleteBackward),
               (IMP)hook_tf_deleteBackward, &orig_tf_deleteBackwd);
    hookMethod([UITextField class], @selector(setText:),
               (IMP)hook_tf_setText, &orig_tf_setText);

    // --- UITextView ---
    hookMethod([UITextView class], @selector(insertText:),
               (IMP)hook_tv_insertText, &orig_tv_insertText);
    hookMethod([UITextView class], @selector(deleteBackward),
               (IMP)hook_tv_deleteBackward, &orig_tv_deleteBackwd);

    // --- AutoClicker recorder methods ---
    // Các selector này thuộc về class ACPW_6fa18b (obfuscated window class).
    // Tìm class chứa selector bằng cách scan runtime.
    SEL selRecord    = @selector(recorderRecordFromMenu);
    SEL selStop      = @selector(recorderStopFromMenu);
    SEL selPlay      = @selector(recorderPlayFromMenu);
    SEL selClear     = @selector(recorderClearFromMenu);
    SEL selFltStop   = @selector(recorderFloatingStopPressed);

    // Duyệt qua tất cả registered classes, tìm class có implement các selector này
    int numClasses = objc_getClassList(NULL, 0);
    if (numClasses > 0) {
        Class *classes = (Class *)malloc(sizeof(Class) * numClasses);
        objc_getClassList(classes, numClasses);
        for (int i = 0; i < numClasses; i++) {
            Class c = classes[i];
            if (class_getInstanceMethod(c, selRecord)) {
                NSLog(@"[TextMacro] Found recorder class: %s", class_getName(c));
                hookMethod(c, selRecord,  (IMP)hook_recorderRecordFromMenu,  &orig_recorderRecordFromMenu);
                hookMethod(c, selStop,    (IMP)hook_recorderStopFromMenu,    &orig_recorderStopFromMenu);
                hookMethod(c, selPlay,    (IMP)hook_recorderPlayFromMenu,    &orig_recorderPlayFromMenu);
                hookMethod(c, selClear,   (IMP)hook_recorderClearFromMenu,   &orig_recorderClearFromMenu);
                if (class_getInstanceMethod(c, selFltStop))
                    hookMethod(c, selFltStop, (IMP)hook_recorderFloatingStopPressed, &orig_recorderFloatingStopPressed);
                break;
            }
        }
        free(classes);
    }

    NSLog(@"[TextMacro] All hooks installed ✓");
}

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - Constructor
// ═══════════════════════════════════════════════════════════════════════════════

__attribute__((constructor))
static void ACPTextMacroInit(void) {
    @autoreleasepool {
        // Đường dẫn file lưu text events
        NSArray *docs = NSSearchPathForDirectoriesInDomains(
            NSDocumentDirectory, NSUserDomainMask, YES);
        gEventFile = [docs.firstObject
            stringByAppendingPathComponent:@"acp_recording_text.json"];
        gEvents    = [NSMutableArray new];

        NSLog(@"[TextMacro] Initializing… event file: %@", gEventFile);

        // Load Substrate/ElleKit nếu có
        loadSubstrate();

        // Hook ngay lập tức các UIKit class (luôn có sẵn)
        // Hook AutoClicker class phải chờ cho đến khi AutoClicker-TrollFools.dylib
        // đã được load và ObjC classes đã register.
        // Dùng dispatch_after 0.5s để đảm bảo.
        dispatch_after(
            dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
            dispatch_get_main_queue(),
            ^{ installHooks(); }
        );
    }
}

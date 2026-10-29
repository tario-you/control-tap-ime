#import <AppKit/AppKit.h>
#import <Carbon/Carbon.h>
#import "Core.h"
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>
#include <errno.h>

static NSString *const CTVersion = @"1.0.0";
static NSString *CTSupport(void) { return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/ControlTapIME"]; }
static NSString *CTSocket(void) { return [NSString stringWithFormat:@"/tmp/controltap-ime-%u.sock", getuid()]; }
static NSString *CTConfigPath(void) { return [CTSupport() stringByAppendingPathComponent:@"config.json"]; }
static NSDictionary *CTConfig(void) {
    NSData *data = [NSData dataWithContentsOfFile:CTConfigPath()];
    if (!data && [[NSFileManager defaultManager] fileExistsAtPath:CTConfigPath()]) CTFail(@"Could not read configuration");
    return CTValidateConfiguration(data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : @{});
}
static NSDictionary *CTError(NSString *message) { return @{@"ok": @NO, @"message": message ?: @"Unknown error"}; }
static NSString *CTString(TISInputSourceRef source, CFStringRef key) {
    void *value = TISGetInputSourceProperty(source, key);
    return value ? (__bridge NSString *)value : nil;
}
static BOOL CTBoolean(TISInputSourceRef source, CFStringRef key) {
    void *value = TISGetInputSourceProperty(source, key);
    return value && CFBooleanGetValue(value);
}
static NSDictionary *CTDescribe(TISInputSourceRef source) {
    NSArray *languages = (__bridge NSArray *)TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages) ?: @[];
    NSMutableDictionary *result = [@{@"id": CTString(source, kTISPropertyInputSourceID) ?: @"",
        @"name": CTString(source, kTISPropertyLocalizedName) ?: @"", @"languages": languages} mutableCopy];
    NSString *mode = CTString(source, kTISPropertyInputModeID);
    if (mode) result[@"inputModeID"] = mode;
    return result;
}
static NSDictionary *CTCurrent(void) {
    TISInputSourceRef source = TISCopyCurrentKeyboardInputSource();
    if (!source) CTFail(@"macOS did not return an active input source");
    NSDictionary *result = CTDescribe(source); CFRelease(source); return result;
}
static NSArray<NSDictionary *> *CTAvailable(void) {
    NSArray *all = CFBridgingRelease(TISCreateInputSourceList(NULL, false));
    NSMutableArray *result = [NSMutableArray array];
    for (id value in all) {
        TISInputSourceRef source = (__bridge TISInputSourceRef)value;
        if ([CTString(source, kTISPropertyInputSourceCategory) isEqual:(__bridge NSString *)kTISCategoryKeyboardInputSource] &&
            CTBoolean(source, kTISPropertyInputSourceIsEnabled) && CTBoolean(source, kTISPropertyInputSourceIsSelectCapable))
            [result addObject:CTDescribe(source)];
    }
    return result;
}
static void CTSelect(NSString *sourceID) {
    NSArray *all = CFBridgingRelease(TISCreateInputSourceList(NULL, false));
    for (id value in all) {
        TISInputSourceRef source = (__bridge TISInputSourceRef)value;
        if ([CTString(source, kTISPropertyInputSourceID) isEqual:sourceID] &&
            CTBoolean(source, kTISPropertyInputSourceIsEnabled) && CTBoolean(source, kTISPropertyInputSourceIsSelectCapable)) {
            OSStatus status = TISSelectInputSource(source);
            if (status != noErr) CTFail([NSString stringWithFormat:@"macOS refused input selection (%d)", (int)status]);
            return;
        }
    }
    CTFail([@"Input source is not enabled: " stringByAppendingString:sourceID]);
}

static struct sockaddr_un CTAddress(void) {
    struct sockaddr_un address = {0}; address.sun_family = AF_UNIX; address.sun_len = sizeof(address);
    const char *path = CTSocket().fileSystemRepresentation;
    if (strlen(path) >= sizeof(address.sun_path)) CTFail(@"Socket path is too long");
    strlcpy(address.sun_path, path, sizeof(address.sun_path)); return address;
}
static void CTSocketOptions(int fd) {
    int enabled = 1; struct timeval timeout = {3, 0};
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, sizeof(enabled));
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
}
static NSDictionary *CTReadJSON(int fd) {
    NSMutableData *data = [NSMutableData data]; uint8_t buffer[1024];
    while (data.length < 16384) {
        ssize_t count = read(fd, buffer, MIN(sizeof(buffer), 16384 - data.length));
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) CTFail(@"Socket timed out or closed before replying");
        uint8_t *newline = memchr(buffer, '\n', (size_t)count);
        [data appendBytes:buffer length:newline ? (NSUInteger)(newline - buffer) : (NSUInteger)count];
        if (newline) {
            id result = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if (![result isKindOfClass:NSDictionary.class]) CTFail(@"Expected a JSON object");
            return result;
        }
    }
    CTFail(@"Socket message exceeds 16 KiB"); return nil;
}
static void CTWriteJSON(int fd, NSDictionary *object) {
    NSMutableData *data = [[NSJSONSerialization dataWithJSONObject:object options:NSJSONWritingSortedKeys error:nil] mutableCopy];
    if (!data || data.length > 16383) CTFail(@"Invalid or oversized response");
    [data appendBytes:"\n" length:1];
    NSUInteger offset = 0;
    while (offset < data.length) {
        ssize_t count = write(fd, (const uint8_t *)data.bytes + offset, data.length - offset);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) CTFail(@"Could not write socket message");
        offset += (NSUInteger)count;
    }
}
static NSDictionary *CTSend(NSDictionary *request) {
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) CTFail(@"Could not create socket");
    @try {
        CTSocketOptions(fd); struct sockaddr_un address = CTAddress();
        if (connect(fd, (struct sockaddr *)&address, sizeof(address)) != 0)
            CTFail(@"ControlTapIME is not running. Start the app or run scripts/install.py");
        uid_t uid; gid_t gid;
        if (getpeereid(fd, &uid, &gid) != 0 || uid != getuid()) CTFail(@"Socket server has a different owner");
        CTWriteJSON(fd, request); return CTReadJSON(fd);
    } @finally { close(fd); }
}

@interface CTRefreshWindow : NSWindow
@end
@implementation CTRefreshWindow
- (BOOL)canBecomeKeyWindow { return YES; }
- (BOOL)canBecomeMainWindow { return YES; }
@end

typedef void (^CTReply)(NSDictionary *);
@interface CTJob : NSObject
@property NSDictionary *request;
@property (copy) CTReply reply;
@end
@implementation CTJob
@end

@interface CTController : NSObject <NSApplicationDelegate>
@property NSStatusItem *statusItem;
@property CTRefreshWindow *refreshWindow;
@property NSRunningApplication *previousApplication;
@property NSMutableArray<CTJob *> *queue;
@property BOOL processing;
@property int serverFD;
@property int lockFD;
- (void)handle:(NSDictionary *)request reply:(CTReply)reply;
@end

@implementation CTController
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    self.queue = [NSMutableArray array]; self.serverFD = -1; self.lockFD = -1;
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    self.statusItem = [NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
    NSMenu *menu = [NSMenu new];
    NSMenuItem *toggle = [menu addItemWithTitle:@"Switch language" action:@selector(toggleFromMenu:) keyEquivalent:@""];
    toggle.target = self; [menu addItem:NSMenuItem.separatorItem];
    NSMenuItem *config = [menu addItemWithTitle:@"Open configuration" action:@selector(openConfiguration:) keyEquivalent:@""];
    config.target = self; self.statusItem.menu = menu; [self updateIndicator];
    [NSDistributedNotificationCenter.defaultCenter addObserver:self selector:@selector(sourceChanged:)
        name:(__bridge NSString *)kTISNotifySelectedKeyboardInputSourceChanged object:nil];
    @try { [self startServer]; }
    @catch (NSException *error) { fprintf(stderr, "%s\n", error.reason.UTF8String); exit(1); }
}
- (void)startServer {
    struct stat support;
    if (lstat(CTSupport().fileSystemRepresentation, &support) == 0) {
        if (!S_ISDIR(support.st_mode) || support.st_uid != getuid()) CTFail(@"Unsafe application-support directory");
    } else {
        NSError *error = nil;
        if (![NSFileManager.defaultManager createDirectoryAtPath:CTSupport() withIntermediateDirectories:YES
            attributes:@{NSFilePosixPermissions: @0700} error:&error]) CTFail(error.localizedDescription);
    }
    NSString *lock = [CTSupport() stringByAppendingPathComponent:@"server.lock"];
    self.lockFD = open(lock.fileSystemRepresentation, O_CREAT | O_RDWR | O_NOFOLLOW, 0600);
    if (self.lockFD < 0 || flock(self.lockFD, LOCK_EX | LOCK_NB) != 0) CTFail(@"Another ControlTapIME server is running");
    struct stat existing;
    if (lstat(CTSocket().fileSystemRepresentation, &existing) == 0) {
        if (!S_ISSOCK(existing.st_mode) || existing.st_uid != getuid()) CTFail(@"Refusing to replace an unrelated socket path");
        if (unlink(CTSocket().fileSystemRepresentation) != 0) CTFail(@"Could not remove stale socket");
    }
    self.serverFD = socket(AF_UNIX, SOCK_STREAM, 0);
    if (self.serverFD < 0) CTFail(@"Could not create server socket");
    struct sockaddr_un address = CTAddress(); mode_t mask = umask(0077);
    int result = bind(self.serverFD, (struct sockaddr *)&address, sizeof(address)); umask(mask);
    if (result != 0 || chmod(CTSocket().fileSystemRepresentation, 0600) != 0 || listen(self.serverFD, 16) != 0)
        CTFail(@"Could not bind private socket");
    int serverFD = self.serverFD;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
        while (YES) {
            int client = accept(serverFD, NULL, NULL);
            if (client < 0) { if (errno == EINTR) continue; break; }
            CTSocketOptions(client);
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
                @autoreleasepool {
                    uid_t uid; gid_t gid;
                    if (getpeereid(client, &uid, &gid) != 0 || uid != getuid()) { close(client); return; }
                    @try {
                        NSDictionary *request = CTReadJSON(client);
                        dispatch_async(dispatch_get_main_queue(), ^{
                            [self handle:request reply:^(NSDictionary *response) {
                                @try { CTWriteJSON(client, response); } @catch (NSException *error) { (void)error; }
                                close(client);
                            }];
                        });
                    } @catch (NSException *error) {
                        @try { CTWriteJSON(client, CTError(error.reason)); } @catch (NSException *nested) { (void)nested; }
                        close(client);
                    }
                }
            });
        }
    });
}
- (void)handle:(NSDictionary *)request reply:(CTReply)reply {
    NSString *command = request[@"command"];
    if ([@[@"status", @"list"] containsObject:command ?: @""]) {
        @try { reply(@{@"ok": @YES, @"message": @"ready", @"currentSource": CTCurrent(),
            @"sources": CTAvailable(), @"configuration": CTConfig()}); }
        @catch (NSException *error) { reply(CTError(error.reason)); }
        return;
    }
    if (![@[@"toggle", @"set"] containsObject:command ?: @""]) { reply(CTError(@"Unknown command")); return; }
    if (self.queue.count >= 16) { reply(CTError(@"Too many pending switches")); return; }
    CTJob *job = [CTJob new]; job.request = request; job.reply = reply;
    [self.queue addObject:job]; [self drain];
}
- (void)drain {
    if (self.processing || !self.queue.count) return;
    self.processing = YES;
    CTJob *job = self.queue.firstObject; [self.queue removeObjectAtIndex:0];
    NSTimeInterval started = NSProcessInfo.processInfo.systemUptime;
    CTReply completion = ^(NSDictionary *response) {
        NSMutableDictionary *result = [response mutableCopy];
        result[@"elapsedMilliseconds"] = @((int)((NSProcessInfo.processInfo.systemUptime - started) * 1000));
        job.reply(result); self.processing = NO; [self updateIndicator]; [self drain];
    };
    @try {
        // Never switch or borrow focus while a secure keyboard-input guard is active.
        if (IsSecureEventInputEnabled()) CTFail(@"Secure keyboard input is active; switch skipped");
        NSDictionary *config = CTConfig(), *target = nil;
        NSArray *available = CTAvailable();
        if ([job.request[@"command"] isEqual:@"set"]) {
            for (NSDictionary *source in available) if ([source[@"id"] isEqual:job.request[@"sourceID"]]) { target = source; break; }
            if (!target) CTFail(@"Requested input source is not enabled");
        } else target = CTNextSource(CTCurrent()[@"id"], CTSourceGroup(available, config));
        CTSelect(target[@"id"]);
        if (CTNeedsRefresh(target)) {
            [self refreshForMilliseconds:[config[@"refreshMilliseconds"] integerValue] completion:^{
                [self verify:target retry:YES refreshed:YES completion:completion];
            }];
        } else {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
                [self verify:target retry:YES refreshed:NO completion:completion];
            });
        }
    } @catch (NSException *error) { completion(CTError(error.reason)); }
}
- (void)verify:(NSDictionary *)target retry:(BOOL)retry refreshed:(BOOL)refreshed completion:(CTReply)completion {
    @try {
        NSDictionary *current = CTCurrent();
        if ([current[@"id"] isEqual:target[@"id"]]) {
            completion(@{@"ok": @YES, @"message": @"switched", @"currentSource": current, @"refreshApplied": @(refreshed)}); return;
        }
        if (!retry || IsSecureEventInputEnabled()) {
            completion(@{@"ok": @NO, @"message": @"macOS did not keep the requested source",
                @"currentSource": current, @"refreshApplied": @(refreshed)}); return;
        }
        CTSelect(target[@"id"]);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            [self verify:target retry:NO refreshed:refreshed completion:completion];
        });
    } @catch (NSException *error) { completion(CTError(error.reason)); }
}
- (void)refreshForMilliseconds:(NSInteger)milliseconds completion:(dispatch_block_t)completion {
    NSScreen *screen = NSScreen.mainScreen ?: NSScreen.screens.firstObject;
    if (!screen || IsSecureEventInputEnabled()) { completion(); return; }
    self.previousApplication = NSWorkspace.sharedWorkspace.frontmostApplication;
    NSRect frame = NSMakeRect(NSMinX(screen.visibleFrame) + 8, NSMinY(screen.visibleFrame) + 8, 3, 3);
    CTRefreshWindow *window = [[CTRefreshWindow alloc] initWithContentRect:frame
        styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
    window.releasedWhenClosed = NO; window.backgroundColor = NSColor.clearColor; window.opaque = NO;
    window.alphaValue = 0.01; window.hasShadow = NO; window.ignoresMouseEvents = YES;
    window.level = NSScreenSaverWindowLevel;
    window.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorStationary | NSWindowCollectionBehaviorFullScreenAuxiliary;
    NSTextView *text = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 3, 3)];
    window.contentView = text; self.refreshWindow = window;
    [window makeKeyAndOrderFront:nil]; [NSApp activateIgnoringOtherApps:YES]; [window makeFirstResponder:text];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, milliseconds * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        [self endRefresh]; completion();
    });
}
- (void)endRefresh {
    [self.refreshWindow orderOut:nil]; [self.refreshWindow close]; self.refreshWindow = nil;
    NSRunningApplication *previous = self.previousApplication; self.previousApplication = nil;
    // Respect a user-driven app change during the refresh instead of stealing focus back.
    if (previous && !previous.terminated && previous.processIdentifier != getpid() &&
        NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier == getpid()) [previous activateWithOptions:0];
}
- (void)sourceChanged:(NSNotification *)notification { (void)notification; [self updateIndicator]; }
- (void)updateIndicator {
    NSDictionary *source = CTCurrent(); NSString *title = @"IM";
    if ([source[@"id"] hasPrefix:@"com.apple.keylayout."]) title = @"EN";
    for (NSString *language in source[@"languages"]) if ([language hasPrefix:@"zh"]) title = @"中";
    self.statusItem.button.title = title;
    self.statusItem.button.toolTip = [@"ControlTapIME · " stringByAppendingString:source[@"name"]];
}
- (void)toggleFromMenu:(id)sender { (void)sender; [self handle:@{@"command": @"toggle"} reply:^(NSDictionary *response) { (void)response; }]; }
- (void)openConfiguration:(id)sender { (void)sender; [NSWorkspace.sharedWorkspace openURL:[NSURL fileURLWithPath:CTConfigPath()]]; }
@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSString *command = argc > 1 ? @(argv[1]) : @"serve";
        @try {
            if ([command isEqual:@"serve"]) {
                NSApplication *app = NSApplication.sharedApplication;
                CTController *controller = [CTController new]; app.delegate = controller; [app run];
            } else if ([command isEqual:@"--version"]) printf("ControlTapIME %s\n", CTVersion.UTF8String);
            else if ([@[@"--help", @"help"] containsObject:command]) {
                puts("ControlTapIME 1.0.0\n  serve           Run the menu-bar helper\n  toggle          Cycle configured languages\n  set SOURCE_ID   Select an enabled source\n  list            List enabled sources (JSON)\n  status          Read status and configuration (JSON)");
            } else {
                NSMutableDictionary *request = [@{@"command": command} mutableCopy];
                if (argc > 2) request[@"sourceID"] = @(argv[2]);
                NSDictionary *response = CTSend(request); CTWriteJSON(STDOUT_FILENO, response);
                return [response[@"ok"] boolValue] ? 0 : 1;
            }
        } @catch (NSException *error) { fprintf(stderr, "%s\n", error.reason.UTF8String); return 1; }
    }
    return 0;
}

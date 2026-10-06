#import "../Sources/Core.h"

static unsigned checks = 0;
static void check(BOOL condition, NSString *message) {
    checks++;
    if (!condition) { fprintf(stderr, "FAIL: %s\n", message.UTF8String); exit(1); }
}
static void rejects(dispatch_block_t action, NSString *message) {
    BOOL rejected = NO;
    @try { action(); } @catch (NSException *error) { rejected = [error.name isEqual:@"ControlTapIMEError"]; }
    check(rejected, message);
}
int main(void) {
    @autoreleasepool {
        NSDictionary *english = @{@"id": @"com.apple.keylayout.ABC", @"name": @"ABC", @"languages": @[@"en"]};
        NSDictionary *chinese = @{@"id": @"example.pinyin", @"name": @"Pinyin", @"languages": @[@"zh-Hans"]};
        NSDictionary *japanese = @{@"id": @"example.hiragana", @"name": @"Hiragana", @"languages": @[@"ja"]};
        NSDictionary *katakana = @{@"id": @"example.katakana", @"name": @"Katakana", @"languages": @[@"ja"]};
        NSArray *available = @[japanese, chinese, english];
        NSArray *group = CTSourceGroup(available, @{});
        check([group isEqual:@[english, chinese]], @"Default prefers ABC and Chinese over enumeration order");
        check([CTNextSource(english[@"id"], group) isEqual:chinese], @"English switches to Chinese");
        check([CTNextSource(chinese[@"id"], group) isEqual:english], @"Chinese switches to English");
        check([CTNextSource(@"unrelated", group) isEqual:english], @"External selection returns to configured group");
        check([CTSourceGroup(@[english, english, chinese, chinese], @{}) isEqual:group], @"Duplicate enumeration is harmless");
        group = CTSourceGroup(@[english, japanese, katakana], @{@"sourceIDs": @[japanese[@"id"], katakana[@"id"], english[@"id"]]});
        check([CTNextSource(japanese[@"id"], group) isEqual:katakana], @"Distinct input modes remain distinct");
        check([CTNextSource(english[@"id"], group) isEqual:japanese], @"Custom group preserves wraparound order");
        rejects(^{ CTSourceGroup(@[english], @{}); }, @"Missing CJK source fails safely");
        rejects(^{ CTSourceGroup(@[english], @{@"sourceIDs": @[english[@"id"], chinese[@"id"]]}); }, @"Removed configured source is not silently substituted");
        rejects(^{ CTValidateConfiguration(@{@"sourceIDs": @[@"a"]}); }, @"Single-source configuration rejected");
        rejects(^{ CTValidateConfiguration(@{@"sourceIDs": @[@"a", @"a"]}); }, @"Duplicate configured IDs rejected");
        rejects(^{ CTValidateConfiguration(@{@"sourceIDs": @[@1, @2]}); }, @"Non-string IDs rejected");
        rejects(^{ CTValidateConfiguration(@{@"refreshMilliseconds": @0}); }, @"Zero focus interval rejected");
        rejects(^{ CTValidateConfiguration(@{@"refreshMilliseconds": @501}); }, @"Excessive focus interval rejected");
        rejects(^{ CTValidateConfiguration(@{@"refreshMilliseconds": @80.5}); }, @"Fractional interval rejected");
        check(CTNeedsRefresh(chinese), @"Chinese uses refresh");
        check(CTNeedsRefresh(japanese), @"Japanese uses refresh");
        check(!CTNeedsRefresh(english), @"English avoids focus refresh");
        check(!CTNeedsRefresh(@{@"languages": @[@"ru"]}), @"Russian avoids unnecessary focus refresh");
        check([CTValidateConfiguration(@{})[@"refreshMilliseconds"] isEqual:@80], @"Default interval is 80 ms");
        printf("PASS: %u core checks\n", checks);
    }
    return 0;
}

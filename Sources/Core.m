#import "Core.h"

void CTFail(NSString *message) {
    @throw [NSException exceptionWithName:@"ControlTapIMEError" reason:message userInfo:nil];
}
BOOL CTNeedsRefresh(NSDictionary *source) {
    for (NSString *language in source[@"languages"]) {
        if ([language hasPrefix:@"zh"] || [@[@"ja", @"ko", @"vi"] containsObject:language]) return YES;
    }
    return NO;
}
NSDictionary *CTValidateConfiguration(NSDictionary *config) {
    if (![config isKindOfClass:NSDictionary.class]) CTFail(@"Configuration must be a JSON object");
    NSArray *ids = config[@"sourceIDs"] ?: @[];
    NSNumber *delay = config[@"refreshMilliseconds"] ?: @80;
    if (![delay isKindOfClass:NSNumber.class] || delay.doubleValue != delay.integerValue ||
        delay.integerValue < 20 || delay.integerValue > 500) CTFail(@"refreshMilliseconds must be an integer between 20 and 500");
    if (![ids isKindOfClass:NSArray.class] || ids.count == 1) CTFail(@"sourceIDs must be empty or contain at least two IDs");
    NSMutableSet *seen = [NSMutableSet set];
    for (id sourceID in ids) {
        if (![sourceID isKindOfClass:NSString.class] || ![sourceID length] ||
            [sourceID lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 512 || [seen containsObject:sourceID])
            CTFail(@"sourceIDs must contain distinct, nonempty strings");
        [seen addObject:sourceID];
    }
    return @{@"sourceIDs": ids, @"refreshMilliseconds": delay};
}
NSArray<NSDictionary *> *CTSourceGroup(NSArray<NSDictionary *> *available, NSDictionary *configuration) {
    NSDictionary *config = CTValidateConfiguration(configuration);
    NSMutableArray *unique = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    for (NSDictionary *source in available) {
        if (![seen containsObject:source[@"id"]]) { [seen addObject:source[@"id"]]; [unique addObject:source]; }
    }
    if ([config[@"sourceIDs"] count]) {
        NSMutableArray *group = [NSMutableArray array];
        for (NSString *sourceID in config[@"sourceIDs"]) {
            NSDictionary *match = nil;
            for (NSDictionary *source in unique) if ([source[@"id"] isEqual:sourceID]) { match = source; break; }
            if (!match) CTFail([@"Input source is not enabled: " stringByAppendingString:sourceID]);
            [group addObject:match];
        }
        return group;
    }
    NSDictionary *english = nil, *chinese = nil, *cjk = nil;
    for (NSDictionary *source in unique) {
        if ([source[@"id"] isEqual:@"com.apple.keylayout.ABC"]) english = source;
        if (!english && [source[@"id"] hasPrefix:@"com.apple.keylayout."] && [source[@"languages"] containsObject:@"en"]) english = source;
        if (!cjk && CTNeedsRefresh(source)) cjk = source;
        for (NSString *language in source[@"languages"]) if (!chinese && [language hasPrefix:@"zh"]) chinese = source;
    }
    if (!english || !(chinese ?: cjk)) CTFail(@"Enable an English layout and a CJK input source, or configure sourceIDs");
    return @[english, chinese ?: cjk];
}
NSDictionary *CTNextSource(NSString *currentID, NSArray<NSDictionary *> *group) {
    if (group.count < 2) CTFail(@"At least two enabled input sources are required");
    for (NSUInteger i = 0; i < group.count; i++) if ([group[i][@"id"] isEqual:currentID]) return group[(i + 1) % group.count];
    return group[0];
}

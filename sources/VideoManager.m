#import "VideoManager.h"
#import "Util.h"
#import "GonerinoLog.h"

@interface VideoManager ()
@property(nonatomic, strong) NSMutableArray<NSDictionary *> *blockedVideoArray;
@property(nonatomic, strong) NSMutableSet<NSString *> *blockedVideoIdSet;
@end

@implementation VideoManager

+ (instancetype)sharedInstance {
    static VideoManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ instance = [[self alloc] init]; });
    return instance;
}

- (void)rebuildBlockedVideoIdSet {
    [self.blockedVideoIdSet removeAllObjects];
    for (NSDictionary *videoInfo in self.blockedVideoArray) {
        NSString *videoId = videoInfo[@"id"];
        if (videoId.length) {
            [self.blockedVideoIdSet addObject:videoId];
        }
    }
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _blockedVideoArray = [[[NSUserDefaults standardUserDefaults] arrayForKey:@"GonerinoBlockedVideos"] mutableCopy]
                                 ?: [NSMutableArray array];
        _blockedVideoIdSet = [NSMutableSet set];
        [self rebuildBlockedVideoIdSet];
        GonerinoLog(@"init: loaded %lu blocked videos from UserDefaults", (unsigned long)_blockedVideoArray.count);
    }
    return self;
}

- (NSArray<NSDictionary *> *)blockedVideos {
    return [self.blockedVideoArray copy];
}

- (void)addBlockedVideo:(NSString *)videoId title:(NSString *)title channel:(NSString *)channel {
    if (!videoId.length) {
        GonerinoLog(@"addBlockedVideo: skipped empty video id (title=%@ channel=%@)",
                    title ?: @"(nil)", channel ?: @"(nil)");
        return;
    }

    if ([self.blockedVideoIdSet containsObject:videoId]) {
        GonerinoLog(@"addBlockedVideo: skipped duplicate id=%@ title=%@ channel=%@",
                    videoId, title ?: @"(nil)", channel ?: @"(nil)");
        return;
    }

    NSDictionary *videoInfo = @{@"id": videoId, @"title": title ?: @"", @"channel": channel ?: @""};

    NSUInteger beforeCount = self.blockedVideoArray.count;
    [self.blockedVideoArray addObject:videoInfo];
    [self.blockedVideoIdSet addObject:videoId];
    NSUInteger afterCount = self.blockedVideoArray.count;

    GonerinoLog(@"addBlockedVideo: id=%@ title=%@ channel=%@ before=%lu after=%lu",
                videoId, title ?: @"(nil)", channel ?: @"(nil)",
                (unsigned long)beforeCount, (unsigned long)afterCount);

    [self saveBlockedVideos];
}

- (void)removeBlockedVideo:(NSString *)videoId {
    if (!videoId.length) {
        GonerinoLog(@"removeBlockedVideo: skipped empty video id");
        return;
    }

    NSUInteger beforeCount = self.blockedVideoArray.count;
    NSIndexSet *indexes =
        [self.blockedVideoArray indexesOfObjectsPassingTest:^BOOL(NSDictionary *obj, NSUInteger idx, BOOL *stop) {
            return [obj[@"id"] isEqualToString:videoId];
        }];

    if (indexes.count > 0) {
        [self.blockedVideoArray removeObjectsAtIndexes:indexes];
        [self.blockedVideoIdSet removeObject:videoId];
        GonerinoLog(@"removeBlockedVideo: id=%@ before=%lu after=%lu",
                    videoId, (unsigned long)beforeCount, (unsigned long)self.blockedVideoArray.count);
        [self saveBlockedVideos];
    } else {
        GonerinoLog(@"removeBlockedVideo: id=%@ not found", videoId);
    }
}

- (BOOL)isVideoBlocked:(NSString *)videoId {
    if (!videoId.length) {
        return NO;
    }

    return [self.blockedVideoIdSet containsObject:videoId];
}

- (void)saveBlockedVideos {
    [[NSUserDefaults standardUserDefaults] setObject:self.blockedVideoArray forKey:@"GonerinoBlockedVideos"];
    [[NSUserDefaults standardUserDefaults] synchronize];

    NSArray *readBack = [[NSUserDefaults standardUserDefaults] arrayForKey:@"GonerinoBlockedVideos"];
    GonerinoLog(@"saveBlockedVideos: wrote %lu, readBack %lu",
                (unsigned long)self.blockedVideoArray.count, (unsigned long)readBack.count);
    [Util gonerinoInvalidateFilterCache];
}

- (void)setBlockedVideos:(NSArray<NSDictionary *> *)videos {
    NSArray *validVideos = [videos
        filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *dict, NSDictionary *bindings) {
            return [dict isKindOfClass:[NSDictionary class]] && dict[@"id"] &&
                   [dict[@"id"] isKindOfClass:[NSString class]] && [dict[@"id"] length] > 0;
        }]];

    GonerinoLog(@"setBlockedVideos: replacing with %lu videos (%lu valid)",
                (unsigned long)videos.count, (unsigned long)validVideos.count);
    self.blockedVideoArray = [validVideos mutableCopy];
    [self rebuildBlockedVideoIdSet];
    [self saveBlockedVideos];
}

@end

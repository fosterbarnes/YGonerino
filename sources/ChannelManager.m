#import "ChannelManager.h"
#import "Util.h"
#import "GonerinoLog.h"

@interface ChannelManager ()
@property(nonatomic, strong) NSMutableSet<NSString *> *blockedChannelSet;
@end

@implementation ChannelManager

+ (instancetype)sharedInstance {
    static ChannelManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ instance = [[self alloc] init]; });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        NSArray *saved = [[NSUserDefaults standardUserDefaults] arrayForKey:@"GonerinoBlockedChannels"];
        _blockedChannelSet = saved ? [NSMutableSet setWithArray:saved] : [NSMutableSet set];
        GonerinoLog(@"init: loaded %lu blocked channels from UserDefaults", (unsigned long)_blockedChannelSet.count);
    }
    return self;
}

- (NSArray<NSString *> *)blockedChannels {
    return [self.blockedChannelSet allObjects];
}

- (void)addBlockedChannel:(NSString *)channelName {
    if (channelName.length == 0) {
        GonerinoLog(@"addBlockedChannel: skipped empty channel name");
        return;
    }

    NSUInteger beforeCount = self.blockedChannelSet.count;
    BOOL isNew             = ![self.blockedChannelSet containsObject:channelName];
    [self.blockedChannelSet addObject:channelName];
    NSUInteger afterCount = self.blockedChannelSet.count;

    GonerinoLog(@"addBlockedChannel: \"%@\" before=%lu after=%lu new=%@",
                channelName, (unsigned long)beforeCount, (unsigned long)afterCount, isNew ? @"YES" : @"NO");

    if (isNew) {
        [self saveBlockedChannels];
    } else {
        GonerinoLog(@"addBlockedChannel: duplicate, save skipped");
    }
}

- (void)removeBlockedChannel:(NSString *)channelName {
    if (!channelName) {
        GonerinoLog(@"removeBlockedChannel: skipped nil channel name");
        return;
    }

    NSUInteger beforeCount = self.blockedChannelSet.count;
    [self.blockedChannelSet removeObject:channelName];
    NSUInteger afterCount = self.blockedChannelSet.count;

    GonerinoLog(@"removeBlockedChannel: \"%@\" before=%lu after=%lu",
                channelName, (unsigned long)beforeCount, (unsigned long)afterCount);

    if (beforeCount != afterCount) {
        [self saveBlockedChannels];
    }
}

- (BOOL)isChannelBlocked:(NSString *)channelName {
    return [self.blockedChannelSet containsObject:channelName];
}

- (void)saveBlockedChannels {
    NSArray *toWrite = [self.blockedChannelSet allObjects];
    [[NSUserDefaults standardUserDefaults] setObject:toWrite forKey:@"GonerinoBlockedChannels"];
    [[NSUserDefaults standardUserDefaults] synchronize];

    NSArray *readBack = [[NSUserDefaults standardUserDefaults] arrayForKey:@"GonerinoBlockedChannels"];
    GonerinoLog(@"saveBlockedChannels: wrote %lu, readBack %lu",
                (unsigned long)toWrite.count, (unsigned long)readBack.count);
    [Util gonerinoInvalidateFilterCache];
}

- (void)setBlockedChannels:(NSArray<NSString *> *)channels {
    GonerinoLog(@"setBlockedChannels: replacing with %lu channels", (unsigned long)channels.count);
    self.blockedChannelSet = [NSMutableSet setWithArray:channels];
    [self saveBlockedChannels];
}

@end

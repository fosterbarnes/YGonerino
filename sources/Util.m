#import "Util.h"
#import "UtilInternal.h"
#import "ChannelManager.h"
#import "VideoManager.h"
#import "GonerinoLog.h"

@interface YTElementsInlineMutedPlaybackView : NSObject
@property(retain, nonatomic) id asdPlayableEntry;
@end

@interface YTASDPlayableEntry : NSObject
@property(nonatomic) BOOL hasNavigationEndpoint;
@property(retain, nonatomic) id navigationEndpoint;
@end

@interface ASTextNode : NSObject
@property(nonatomic, copy, nullable) NSAttributedString *attributedText;
@end

@interface NSObject (NodeMethods)
- (nullable NSString *)channelName;
- (nullable NSString *)ownerName;
- (nullable NSArray *)subnodes;
- (nullable NSString *)accessibilityLabel;
@end

@implementation Util

static struct {
    BOOL valid;
    BOOL enabled;
    BOOL hasFilters;
    BOOL hasChannelOrVideoFilters;
    BOOL peopleWatched;
    BOOL mightLike;
} gGonerinoFilterCache;

static Class GonerinoInlinePlaybackPlayerNodeClass = Nil;
static Class GonerinoInlineMutedPlaybackViewClass    = Nil;
static Class GonerinoASTextNodeClass                 = Nil;
static Class GonerinoELMTextNodeClass                = Nil;

static void GonerinoEnsureNodeClasses(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        GonerinoInlinePlaybackPlayerNodeClass = NSClassFromString(@"YTInlinePlaybackPlayerNode");
        GonerinoInlineMutedPlaybackViewClass  = NSClassFromString(@"YTElementsInlineMutedPlaybackView");
        GonerinoASTextNodeClass               = NSClassFromString(@"ASTextNode");
        GonerinoELMTextNodeClass              = NSClassFromString(@"ELMTextNode");
    });
}

+ (void)gonerinoRefreshFilterCache {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    BOOL enabled             = [defaults objectForKey:@"GonerinoEnabled"] == nil ? YES : [defaults boolForKey:@"GonerinoEnabled"];

    gGonerinoFilterCache.enabled                    = enabled;
    gGonerinoFilterCache.peopleWatched              = [defaults boolForKey:@"GonerinoPeopleWatched"];
    gGonerinoFilterCache.mightLike                  = [defaults boolForKey:@"GonerinoMightLike"];

    BOOL hasChannels = [[ChannelManager sharedInstance] blockedChannels].count > 0;
    BOOL hasVideos   = [[VideoManager sharedInstance] blockedVideos].count > 0;
    BOOL hasWords    = [[WordManager sharedInstance] blockedWords].count > 0;

    gGonerinoFilterCache.hasChannelOrVideoFilters = hasChannels || hasVideos;
    gGonerinoFilterCache.hasFilters               = enabled && (hasChannels || hasVideos || hasWords ||
                                                    gGonerinoFilterCache.peopleWatched || gGonerinoFilterCache.mightLike);
    gGonerinoFilterCache.valid                    = YES;
}

+ (void)gonerinoInvalidateFilterCache {
    gGonerinoFilterCache.valid = NO;
}

+ (id)safeValueForKey:(NSString *)key onObject:(id)object {
    if (!object || !key.length) {
        return nil;
    }
    if (![object respondsToSelector:NSSelectorFromString(key)]) {
        return nil;
    }
    @try {
        return [object valueForKey:key];
    } @catch (NSException *exception) {
        return nil;
    }
}

+ (NSDictionary *)extractVideoInfoFromPlaybackNodeSync:(id)node {
    GonerinoEnsureNodeClasses();
    if (!GonerinoInlinePlaybackPlayerNodeClass || ![node isKindOfClass:GonerinoInlinePlaybackPlayerNodeClass]) {
        return @{};
    }

    @try {
        UIView *view = [node view];
        for (UIView *subview in view.subviews) {
            if (!GonerinoInlineMutedPlaybackViewClass || ![subview isKindOfClass:GonerinoInlineMutedPlaybackViewClass]) {
                continue;
            }

            YTElementsInlineMutedPlaybackView *playbackView = (YTElementsInlineMutedPlaybackView *)subview;
            YTASDPlayableEntry *playableEntry = (YTASDPlayableEntry *)playbackView.asdPlayableEntry;

            if (!playableEntry || !playableEntry.hasNavigationEndpoint) {
                continue;
            }

            NSString *description = [playableEntry.navigationEndpoint description];
            if (!description.length) {
                continue;
            }

            NSMutableDictionary *info = [NSMutableDictionary dictionary];
            NSError *error            = nil;

            NSArray *patterns = @[
                @[@"videoId", @"video_id: \"([^\"\\\\]*(?:\\\\.[^\"\\\\]*)*)\""],
                @[@"videoTitle", @"video_title: \"([^\"\\\\]*(?:\\\\.[^\"\\\\]*)*)\""],
                @[@"ownerName", @"owner_display_name: \"([^\"\\\\]*(?:\\\\.[^\"\\\\]*)*)\""]
            ];

            for (NSArray *entry in patterns) {
                NSString *key     = entry[0];
                NSString *pattern = entry[1];
                NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:pattern
                                                                                       options:0
                                                                                         error:&error];
                if (error) {
                    continue;
                }

                NSTextCheckingResult *match = [regex firstMatchInString:description
                                                                options:0
                                                                  range:NSMakeRange(0, description.length)];
                if (match.numberOfRanges <= 1) {
                    continue;
                }

                NSString *value = [description substringWithRange:[match rangeAtIndex:1]];
                value           = [value stringByReplacingOccurrencesOfString:@"\\\"" withString:@"\""];
                value           = [value stringByReplacingOccurrencesOfString:@"\\'" withString:@"'"];
                if (value.length) {
                    info[key] = value;
                }
            }

            id endpoint = playableEntry.navigationEndpoint;
            if (endpoint) {
                for (NSString *key in @[@"videoId", @"video_id"]) {
                    id value = [Util safeValueForKey:key onObject:endpoint];
                    if ([value isKindOfClass:[NSString class]] && [(NSString *)value length] > 0) {
                        info[@"videoId"] = value;
                        break;
                    }
                }

                id watchEndpoint = [Util safeValueForKey:@"watchEndpoint" onObject:endpoint];
                if (watchEndpoint) {
                    id watchVideoId = [Util safeValueForKey:@"videoId" onObject:watchEndpoint];
                    if ([watchVideoId isKindOfClass:[NSString class]] && [(NSString *)watchVideoId length] > 0) {
                        info[@"videoId"] = watchVideoId;
                    }
                }
            }

            NSArray *altPatterns = @[
                @[@"videoId", @"videoId[: ]+\"([^\"]+)\""],
                @[@"videoId", @"/watch\\?v=([a-zA-Z0-9_-]{11})"],
                @[@"videoId", @"v=([a-zA-Z0-9_-]{11})"]
            ];

            for (NSArray *entry in altPatterns) {
                if (info[entry[0]]) {
                    continue;
                }

                NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:entry[1]
                                                                                       options:0
                                                                                         error:nil];
                NSTextCheckingResult *match = [regex firstMatchInString:description
                                                                options:0
                                                                  range:NSMakeRange(0, description.length)];
                if (match.numberOfRanges > 1) {
                    NSString *value = [description substringWithRange:[match rangeAtIndex:1]];
                    if (value.length) {
                        info[entry[0]] = value;
                    }
                }
            }

            if (info.count > 0) {
                return info;
            }
        }
    } @catch (NSException *exception) {
        GonerinoLogError(@"Exception in extractVideoInfoFromPlaybackNodeSync: %@", exception);
    }

    return @{};
}

+ (id)findPlaybackNodeInTree:(id)node {
    GonerinoEnsureNodeClasses();
    if (GonerinoInlinePlaybackPlayerNodeClass && [node isKindOfClass:GonerinoInlinePlaybackPlayerNodeClass]) {
        return node;
    }

    if ([node respondsToSelector:@selector(subnodes)]) {
        for (id subnode in [node subnodes]) {
            id found = [self findPlaybackNodeInTree:subnode];
            if (found) {
                return found;
            }
        }
    }

    id yogaChildren = [self safeValueForKey:@"yogaChildren" onObject:node];
    if ([yogaChildren isKindOfClass:[NSArray class]]) {
        for (id child in yogaChildren) {
            id found = [self findPlaybackNodeInTree:child];
            if (found) {
                return found;
            }
        }
    }

    return nil;
}

+ (void)extractVideoInfoFromNode:(id)node
                      completion:(void (^)(NSString *videoId, NSString *videoTitle, NSString *ownerName))completion {
    if (!completion) {
        return;
    }

    if (!GonerinoInlinePlaybackPlayerNodeClass || ![node isKindOfClass:GonerinoInlinePlaybackPlayerNodeClass]) {
        GonerinoLogError(@"extractVideoInfoFromNode received incorrect node type: %@",
              NSStringFromClass([node class]));
        return;
    }

    NSDictionary *info = [self extractVideoInfoFromPlaybackNodeSync:node];
    if (info.count > 0) {
        completion(info[@"videoId"], info[@"videoTitle"], info[@"ownerName"]);
    }
}

+ (BOOL)gonerinoIsEnabled {
    if (!gGonerinoFilterCache.valid) {
        [self gonerinoRefreshFilterCache];
    }
    return gGonerinoFilterCache.enabled;
}

+ (BOOL)gonerinoHasActiveBlockFilters {
    if (!gGonerinoFilterCache.valid) {
        [self gonerinoRefreshFilterCache];
    }
    return gGonerinoFilterCache.hasFilters;
}

+ (BOOL)gonerinoBlockPeopleWatched {
    if (!gGonerinoFilterCache.valid) {
        [self gonerinoRefreshFilterCache];
    }
    return gGonerinoFilterCache.peopleWatched;
}

+ (BOOL)gonerinoBlockMightLike {
    if (!gGonerinoFilterCache.valid) {
        [self gonerinoRefreshFilterCache];
    }
    return gGonerinoFilterCache.mightLike;
}

+ (BOOL)gonerinoHasChannelOrVideoBlockFilters {
    if (!gGonerinoFilterCache.valid) {
        [self gonerinoRefreshFilterCache];
    }
    return gGonerinoFilterCache.hasChannelOrVideoFilters;
}

+ (BOOL)nodeContainsBlockedVideo:(id)node {
    if (![self gonerinoIsEnabled]) {
        return NO;
    }

    if ([node respondsToSelector:@selector(accessibilityLabel)]) {
        NSString *accessibilityLabel = [node accessibilityLabel];
        if (accessibilityLabel) {
            if ([[WordManager sharedInstance] isWordBlocked:accessibilityLabel]) {
                GonerinoLog(@"Blocking video because of blocked word: %@", accessibilityLabel);
                return YES;
            }
        }
    }

    GonerinoEnsureNodeClasses();
    if ((GonerinoASTextNodeClass && [node isKindOfClass:GonerinoASTextNodeClass]) ||
        (GonerinoELMTextNodeClass && [node isKindOfClass:GonerinoELMTextNodeClass])) {
        ASTextNode *textNode               = (ASTextNode *)node;
        NSAttributedString *attributedText = textNode.attributedText;
        NSString *text                     = [attributedText string];

        if ([self gonerinoBlockPeopleWatched] && [text isEqualToString:@"People also watched this video"]) {
            GonerinoLog(@"Blocking 'People also watched' section");
            return YES;
        }

        if ([self gonerinoBlockMightLike] && [text isEqualToString:@"You might also like this"]) {
            GonerinoLog(@"Blocking 'You might also like' section");
            return YES;
        }

        if ([[WordManager sharedInstance] isWordBlocked:text]) {
            GonerinoLog(@"Blocking content with blocked word: %@", text);
            return YES;
        }

        if ([text containsString:@" · "]) {
            NSArray *components = [text componentsSeparatedByString:@" · "];
            if (components.count >= 1) {
                NSString *potentialChannelName = components[0];
                if ([[ChannelManager sharedInstance] isChannelBlocked:potentialChannelName]) {
                    GonerinoLog(@"Blocking content from blocked channel: %@", potentialChannelName);
                    return YES;
                }
            }
        }
    }

    if ([node respondsToSelector:@selector(channelName)]) {
        NSString *nodeChannelName = [node channelName];
        if ([[ChannelManager sharedInstance] isChannelBlocked:nodeChannelName]) {
            GonerinoLog(@"Blocking content from blocked channel: %@", nodeChannelName);
            return YES;
        }
    }

    if ([node respondsToSelector:@selector(ownerName)]) {
        NSString *nodeOwnerName = [node ownerName];
        if ([[ChannelManager sharedInstance] isChannelBlocked:nodeOwnerName]) {
            GonerinoLog(@"Blocking content from blocked channel: %@", nodeOwnerName);
            return YES;
        }
    }

    if (GonerinoInlinePlaybackPlayerNodeClass && [node isKindOfClass:GonerinoInlinePlaybackPlayerNodeClass]) {
        NSDictionary *info   = [self extractVideoInfoFromPlaybackNodeSync:node];
        NSString *videoId    = info[@"videoId"];
        NSString *videoTitle = info[@"videoTitle"];
        NSString *ownerName  = info[@"ownerName"];

        if (videoId.length && [[VideoManager sharedInstance] isVideoBlocked:videoId]) {
            GonerinoLog(@"Blocking video with id: %@", videoId);
            return YES;
        }
        if (ownerName.length && [[ChannelManager sharedInstance] isChannelBlocked:ownerName]) {
            GonerinoLog(@"Blocking video with id %@: Channel %@ is blocked", videoId, ownerName);
            return YES;
        }
        if (videoTitle.length && [[WordManager sharedInstance] isWordBlocked:videoTitle]) {
            GonerinoLog(@"Blocking video with id %@: title contains blocked word", videoId);
            return YES;
        }
        if (ownerName.length && [[WordManager sharedInstance] isWordBlocked:ownerName]) {
            GonerinoLog(@"Blocking video with id %@: channel name contains blocked word", videoId);
            return YES;
        }
    }

    if ([node respondsToSelector:@selector(subnodes)]) {
        NSArray *subnodes = [node subnodes];
        for (id subnode in subnodes) {
            if ([self nodeContainsBlockedVideo:subnode]) {
                return YES;
            }
        }
    }

    id yogaChildren = [self safeValueForKey:@"yogaChildren" onObject:node];
    if ([yogaChildren isKindOfClass:[NSArray class]]) {
        for (id child in yogaChildren) {
            if ([self nodeContainsBlockedVideo:child]) {
                return YES;
            }
        }
    }

    return NO;
}

+ (UIImage *)createBlockChannelIconWithSize:(CGSize)size {
    @try {
        UIGraphicsBeginImageContextWithOptions(size, NO, [UIScreen mainScreen].scale);
        CGContextRef context = UIGraphicsGetCurrentContext();
        if (!context) {
            GonerinoLogError(@"Failed to create graphics context");
            return nil;
        }

        CGContextSetShouldAntialias(context, YES);
        CGContextSetAllowsAntialiasing(context, YES);
        CGContextSetShouldSmoothFonts(context, NO);

        [[UIColor whiteColor] setStroke];

        CGFloat noSymbolRadius   = size.width * 0.45;
        CGPoint center           = CGPointMake(size.width / 2, size.height / 2);
        UIBezierPath *circlePath = [UIBezierPath bezierPathWithArcCenter:center
                                                                  radius:noSymbolRadius
                                                              startAngle:0
                                                                endAngle:2 * M_PI
                                                               clockwise:YES];

        CGFloat bodyRadius     = size.width * 0.3;
        CGPoint bodyCenter     = CGPointMake(size.width / 2, size.height * 0.85);
        UIBezierPath *bodyPath = [UIBezierPath bezierPathWithArcCenter:bodyCenter
                                                                radius:bodyRadius
                                                            startAngle:M_PI
                                                              endAngle:2 * M_PI
                                                             clockwise:YES];

        CGFloat headRadius     = size.width * 0.15;
        CGPoint headCenter     = CGPointMake(size.width / 2, size.height * 0.35);
        UIBezierPath *headPath = [UIBezierPath bezierPathWithArcCenter:headCenter
                                                                radius:headRadius
                                                            startAngle:0
                                                              endAngle:2 * M_PI
                                                             clockwise:YES];

        UIBezierPath *linePath = [UIBezierPath bezierPath];
        CGFloat offset         = noSymbolRadius * 0.7071;
        [linePath moveToPoint:CGPointMake(center.x - offset, center.y - offset)];
        [linePath addLineToPoint:CGPointMake(center.x + offset, center.y + offset)];

        CGFloat lineWidth    = 1.5;
        circlePath.lineWidth = lineWidth;
        headPath.lineWidth   = lineWidth;
        bodyPath.lineWidth   = lineWidth;
        linePath.lineWidth   = lineWidth;

        [circlePath stroke];
        [bodyPath stroke];
        [headPath stroke];
        [linePath stroke];

        UIImage *icon = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();

        return [icon imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    } @catch (NSException *exception) {
        GonerinoLogError(@"Exception in createBlockChannelIcon: %@", exception);
        return nil;
    }
}

+ (UIImage *)createBlockVideoIconWithSize:(CGSize)size {
    @try {
        UIGraphicsBeginImageContextWithOptions(size, NO, [UIScreen mainScreen].scale);
        CGContextRef context = UIGraphicsGetCurrentContext();
        if (!context) {
            GonerinoLogError(@"Failed to create graphics context");
            return nil;
        }

        CGContextSetShouldAntialias(context, YES);
        CGContextSetAllowsAntialiasing(context, YES);
        CGContextSetShouldSmoothFonts(context, NO);

        [[UIColor whiteColor] setStroke];
        [[UIColor whiteColor] setFill];

        CGPoint center = CGPointMake(size.width / 2, size.height / 2);

        UIBezierPath *rectPath = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(size.width * 0.2, size.height * 0.3,
                                                                                    size.width * 0.6, size.height * 0.4)
                                                            cornerRadius:3.0];

        UIBezierPath *trianglePath = [UIBezierPath bezierPath];
        CGFloat triangleSize       = size.width * 0.2;
        CGPoint triangleCenter     = center;

        [trianglePath
            moveToPoint:CGPointMake(triangleCenter.x - triangleSize / 2, triangleCenter.y - triangleSize / 2)];
        [trianglePath addLineToPoint:CGPointMake(triangleCenter.x + triangleSize / 2, triangleCenter.y)];
        [trianglePath
            addLineToPoint:CGPointMake(triangleCenter.x - triangleSize / 2, triangleCenter.y + triangleSize / 2)];
        [trianglePath closePath];

        CGFloat noSymbolRadius   = size.width * 0.45;
        UIBezierPath *circlePath = [UIBezierPath bezierPathWithArcCenter:center
                                                                  radius:noSymbolRadius
                                                              startAngle:0
                                                                endAngle:2 * M_PI
                                                               clockwise:YES];

        UIBezierPath *linePath = [UIBezierPath bezierPath];
        CGFloat offset         = noSymbolRadius * 0.7071;
        [linePath moveToPoint:CGPointMake(center.x - offset, center.y - offset)];
        [linePath addLineToPoint:CGPointMake(center.x + offset, center.y + offset)];

        CGFloat lineWidth      = 1.5;
        rectPath.lineWidth     = lineWidth;
        trianglePath.lineWidth = lineWidth;
        circlePath.lineWidth   = lineWidth;
        linePath.lineWidth     = lineWidth;

        [rectPath stroke];
        [trianglePath fill];
        [circlePath stroke];
        [linePath stroke];

        UIImage *icon = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();

        return [icon imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    } @catch (NSException *exception) {
        GonerinoLogError(@"Exception in createBlockVideoIcon: %@", exception);
        return nil;
    }
}

@end

#import "Util.h"
#import "ChannelManager.h"
#import "VideoManager.h"

// Add forward declarations for missing interfaces
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

// Add category for node methods
@interface NSObject (NodeMethods)
- (nullable NSString *)channelName;
- (nullable NSString *)ownerName;
- (nullable NSArray *)subnodes;
- (nullable NSString *)accessibilityLabel;
@end

@implementation Util

+ (NSDictionary *)extractVideoInfoFromPlaybackNodeSync:(id)node {
    if (![node isKindOfClass:NSClassFromString(@"YTInlinePlaybackPlayerNode")]) {
        return @{};
    }

    @try {
        UIView *view = [node view];
        for (UIView *subview in view.subviews) {
            if (![subview isKindOfClass:NSClassFromString(@"YTElementsInlineMutedPlaybackView")]) {
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
            if ([endpoint respondsToSelector:@selector(valueForKey:)]) {
                for (NSString *key in @[@"videoId", @"video_id"]) {
                    id value = [endpoint valueForKey:key];
                    if ([value isKindOfClass:[NSString class]] && [(NSString *)value length] > 0) {
                        info[@"videoId"] = value;
                        break;
                    }
                }

                id watchEndpoint = [endpoint valueForKey:@"watchEndpoint"];
                if ([watchEndpoint respondsToSelector:@selector(valueForKey:)]) {
                    id watchVideoId = [watchEndpoint valueForKey:@"videoId"];
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
        NSLog(@"[YGonerino] Exception in extractVideoInfoFromPlaybackNodeSync: %@", exception);
    }

    return @{};
}

+ (id)findPlaybackNodeInTree:(id)node {
    if ([node isKindOfClass:NSClassFromString(@"YTInlinePlaybackPlayerNode")]) {
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

    return nil;
}

+ (NSString *)textFromNode:(id)node {
    if (![node respondsToSelector:@selector(attributedText)]) {
        return nil;
    }

    NSAttributedString *attributedText = [node attributedText];
    return attributedText.length ? [attributedText string] : nil;
}

+ (BOOL)isTextMetadataNode:(id)node {
    return [node isKindOfClass:NSClassFromString(@"ASTextNode")] ||
           [node isKindOfClass:NSClassFromString(@"ELMTextNode")];
}

+ (void)collectTextMetadataFromNode:(id)node
                        channelName:(NSMutableString *)channelName
                              title:(NSMutableString *)title {
    if ([self isTextMetadataNode:node]) {
        NSString *text = [self textFromNode:node];
        if (text.length) {
            if ([text containsString:@" · "]) {
                NSArray *components = [text componentsSeparatedByString:@" · "];
                NSString *potential = components.firstObject;
                if (potential.length && ![potential containsString:@":"] && !channelName.length) {
                    [channelName setString:potential];
                }
            } else if (!title.length && text.length > 3 && ![text containsString:@":"]) {
                [title setString:text];
            }
        }
    }

    if ([node respondsToSelector:@selector(subnodes)]) {
        for (id subnode in [node subnodes]) {
            [self collectTextMetadataFromNode:subnode channelName:channelName title:title];
        }
    }
}

+ (NSString *)findChannelNameInTree:(id)node {
    if ([node respondsToSelector:@selector(channelName)]) {
        NSString *channelName = [node channelName];
        if (channelName.length) {
            return channelName;
        }
    }

    if ([node respondsToSelector:@selector(ownerName)]) {
        NSString *ownerName = [node ownerName];
        if (ownerName.length) {
            return ownerName;
        }
    }

    if ([node respondsToSelector:@selector(subnodes)]) {
        for (id subnode in [node subnodes]) {
            NSString *found = [self findChannelNameInTree:subnode];
            if (found.length) {
                return found;
            }
        }
    }

    return nil;
}

+ (NSString *)channelNameFromVideoContextNode:(id)contextNode {
    if (![contextNode isKindOfClass:NSClassFromString(@"YTVideoWithContextNode")]) {
        return nil;
    }

    if (![contextNode respondsToSelector:@selector(video)]) {
        return nil;
    }

    id video = [contextNode performSelector:@selector(video)];
    if ([video respondsToSelector:@selector(channelName)]) {
        NSString *channelName = [video channelName];
        if (channelName.length) {
            return channelName;
        }
    }

    return nil;
}

+ (void)extractVideoInfoFromContextNode:(id)contextNode
                              completion:(void (^)(NSString *videoId, NSString *videoTitle,
                                                   NSString *ownerName))completion {
    NSLog(@"[YGonerino] extractVideoInfoFromContextNode: called with contextNode class=%@",
          contextNode ? NSStringFromClass([contextNode class]) : @"(nil)");

    if (!completion || !contextNode) {
        NSLog(@"[YGonerino] extractVideoInfoFromContextNode: bailing out, completion=%@ contextNode=%@",
              completion ? @"present" : @"(nil)", contextNode ? @"present" : @"(nil)");
        return;
    }

    NSString *videoId    = nil;
    NSString *videoTitle = nil;
    NSString *ownerName  = nil;
    NSString *strategy   = nil;

    id playbackNode = [self findPlaybackNodeInTree:contextNode];
    NSLog(@"[YGonerino] extractVideoInfoFromContextNode: navigationEndpoint strategy, playbackNode=%@",
          playbackNode ? NSStringFromClass([playbackNode class]) : @"(not found)");
    if (playbackNode) {
        NSDictionary *playbackInfo = [self extractVideoInfoFromPlaybackNodeSync:playbackNode];
        videoId                    = playbackInfo[@"videoId"];
        videoTitle                 = playbackInfo[@"videoTitle"];
        ownerName                  = playbackInfo[@"ownerName"];
        NSLog(@"[YGonerino] extractVideoInfoFromContextNode: navigationEndpoint result -> id=%@ title=%@ owner=%@",
              videoId ?: @"(none)", videoTitle ?: @"(none)", ownerName ?: @"(none)");
        if (videoId.length || videoTitle.length || ownerName.length) {
            strategy = @"navigationEndpoint";
        }
    }

    if (!ownerName.length || !videoTitle.length) {
        NSMutableString *channelFromText = [NSMutableString string];
        NSMutableString *titleFromText   = [NSMutableString string];
        [self collectTextMetadataFromNode:contextNode channelName:channelFromText title:titleFromText];
        NSLog(@"[YGonerino] extractVideoInfoFromContextNode: textNode strategy result -> channel=%@ title=%@",
              channelFromText.length ? channelFromText : @"(none)", titleFromText.length ? titleFromText : @"(none)");

        if (!ownerName.length && channelFromText.length) {
            ownerName = channelFromText.copy;
            strategy  = strategy ?: @"textNode";
        }
        if (!videoTitle.length && titleFromText.length) {
            videoTitle = titleFromText.copy;
            strategy   = strategy ?: @"textNode";
        }
    }

    if (!ownerName.length) {
        NSString *channelFromTree = [self findChannelNameInTree:contextNode];
        NSLog(@"[YGonerino] extractVideoInfoFromContextNode: channelSelector strategy result -> channel=%@",
              channelFromTree.length ? channelFromTree : @"(none)");
        if (channelFromTree.length) {
            ownerName = channelFromTree;
            strategy  = strategy ?: @"channelSelector";
        }
    }

    if (!ownerName.length) {
        NSString *channelFromVideo = [self channelNameFromVideoContextNode:contextNode];
        NSLog(@"[YGonerino] extractVideoInfoFromContextNode: videoContext strategy result -> channel=%@",
              channelFromVideo.length ? channelFromVideo : @"(none)");
        if (channelFromVideo.length) {
            ownerName = channelFromVideo;
            strategy  = strategy ?: @"videoContext";
        }
    }

    if (videoId.length || videoTitle.length || ownerName.length) {
        NSLog(@"[YGonerino] Extracted video info via %@ (id=%@, title=%@, channel=%@)", strategy ?: @"unknown",
              videoId ?: @"(none)", videoTitle ?: @"(none)", ownerName ?: @"(none)");
        completion(videoId, videoTitle, ownerName);
    } else {
        NSLog(@"[YGonerino] Failed to extract video info from context node: %@ | full debugDescription: %@",
              [contextNode class], [contextNode debugDescription]);
    }
}

+ (void)extractVideoInfoFromNode:(id)node
                      completion:(void (^)(NSString *videoId, NSString *videoTitle, NSString *ownerName))completion {
    if (!completion) {
        return;
    }

    if (![node isKindOfClass:NSClassFromString(@"YTInlinePlaybackPlayerNode")]) {
        NSLog(@"[YGonerino] Error: extractVideoInfoFromNode received incorrect node type: %@",
              NSStringFromClass([node class]));
        return;
    }

    NSDictionary *info = [self extractVideoInfoFromPlaybackNodeSync:node];
    if (info.count > 0) {
        completion(info[@"videoId"], info[@"videoTitle"], info[@"ownerName"]);
    }
}

+ (BOOL)nodeContainsBlockedVideo:(id)node {
    BOOL isEnabled = [[NSUserDefaults standardUserDefaults] objectForKey:@"GonerinoEnabled"] == nil ? 
                    YES : [[NSUserDefaults standardUserDefaults] boolForKey:@"GonerinoEnabled"];
    
    if (!isEnabled) {
        return NO;
    }
    
    if ([node respondsToSelector:@selector(accessibilityLabel)]) {
        NSString *accessibilityLabel = [node accessibilityLabel];
        if (accessibilityLabel) {
            if ([[WordManager sharedInstance] isWordBlocked:accessibilityLabel]) {
                NSLog(@"[YGonerino] Blocking video because of blocked word: %@", accessibilityLabel);
                return YES;
            }
        }
    }

    if ([node isKindOfClass:NSClassFromString(@"ASTextNode")] || [node isKindOfClass:NSClassFromString(@"ELMTextNode")]) {
        ASTextNode *textNode = (ASTextNode *)node;
        NSAttributedString *attributedText = textNode.attributedText;
        NSString *text = [attributedText string];

        if ([[NSUserDefaults standardUserDefaults] boolForKey:@"GonerinoPeopleWatched"] &&
            [text isEqualToString:@"People also watched this video"]) {
            NSLog(@"[YGonerino] Blocking 'People also watched' section");
            return YES;
        }

        if ([[NSUserDefaults standardUserDefaults] boolForKey:@"GonerinoMightLike"] &&
            [text isEqualToString:@"You might also like this"]) {
            NSLog(@"[YGonerino] Blocking 'You might also like' section");
            return YES;
        }

        if ([[WordManager sharedInstance] isWordBlocked:text]) {
            NSLog(@"[YGonerino] Blocking content with blocked word: %@", text);
            return YES;
        }

        if ([text containsString:@" · "]) {
            NSArray *components = [text componentsSeparatedByString:@" · "];
            if (components.count >= 1) {
                NSString *potentialChannelName = components[0];
                if ([[ChannelManager sharedInstance] isChannelBlocked:potentialChannelName]) {
                    NSLog(@"[YGonerino] Blocking content from blocked channel: %@", potentialChannelName);
                    return YES;
                }
            }
        }
    }

    if ([node respondsToSelector:@selector(channelName)]) {
        NSString *nodeChannelName = [node channelName];
        if ([[ChannelManager sharedInstance] isChannelBlocked:nodeChannelName]) {
            NSLog(@"[YGonerino] Blocking content from blocked channel: %@", nodeChannelName);
            return YES;
        }
    }

    if ([node respondsToSelector:@selector(ownerName)]) {
        NSString *nodeOwnerName = [node ownerName];
        if ([[ChannelManager sharedInstance] isChannelBlocked:nodeOwnerName]) {
            NSLog(@"[YGonerino] Blocking content from blocked channel: %@", nodeOwnerName);
            return YES;
        }
    }

    if ([node isKindOfClass:NSClassFromString(@"YTInlinePlaybackPlayerNode")]) {
        NSDictionary *info = [self extractVideoInfoFromPlaybackNodeSync:node];
        NSString *videoId    = info[@"videoId"];
        NSString *videoTitle = info[@"videoTitle"];
        NSString *ownerName  = info[@"ownerName"];

        if (videoId.length && [[VideoManager sharedInstance] isVideoBlocked:videoId]) {
            NSLog(@"[YGonerino] Blocking video with id: %@", videoId);
            return YES;
        }
        if (ownerName.length && [[ChannelManager sharedInstance] isChannelBlocked:ownerName]) {
            NSLog(@"[YGonerino] Blocking video with id %@: Channel %@ is blocked", videoId, ownerName);
            return YES;
        }
        if (videoTitle.length && [[WordManager sharedInstance] isWordBlocked:videoTitle]) {
            NSLog(@"[YGonerino] Blocking video with id %@: title contains blocked word", videoId);
            return YES;
        }
        if (ownerName.length && [[WordManager sharedInstance] isWordBlocked:ownerName]) {
            NSLog(@"[YGonerino] Blocking video with id %@: channel name contains blocked word", videoId);
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

    return NO;
}

+ (UIImage *)createBlockChannelIconWithSize:(CGSize)size {
    @try {
        UIGraphicsBeginImageContextWithOptions(size, NO, [UIScreen mainScreen].scale);
        CGContextRef context = UIGraphicsGetCurrentContext();
        if (!context) {
            NSLog(@"[YGonerino] Failed to create graphics context");
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
        NSLog(@"[YGonerino] Exception in createBlockChannelIcon: %@", exception);
        return nil;
    }
}

+ (UIImage *)createBlockVideoIconWithSize:(CGSize)size {
    @try {
        UIGraphicsBeginImageContextWithOptions(size, NO, [UIScreen mainScreen].scale);
        CGContextRef context = UIGraphicsGetCurrentContext();
        if (!context) {
            NSLog(@"[YGonerino] Failed to create graphics context");
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
        NSLog(@"[YGonerino] Exception in createBlockVideoIcon: %@", exception);
        return nil;
    }
}

@end

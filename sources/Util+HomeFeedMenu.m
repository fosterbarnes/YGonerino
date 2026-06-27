// Home feed context menu support for current YouTube (ELM-based UI).
//
// Flow: YTDefaultSheetController sourceView is an ELMImageNode-View whose node is
// eml.overflow_button. We walk supernodes to the video cell container, cache that node
// on the sheet, and extract video/channel metadata via ELM tree + text nodes.
// Do NOT gate on isKindOfClass:YTVideoWithContextNode — that path is legacy only.

#import "Util+HomeFeedMenu.h"
#import "UtilInternal.h"
#import "ChannelManager.h"
#import "VideoManager.h"
#import "WordManager.h"
#import "GonerinoLog.h"

#import <UIKit/UIKit.h>

@interface ASTextNode : NSObject
@property(nonatomic, copy, nullable) NSAttributedString *attributedText;
@end

@interface NSObject (HomeFeedNodeMethods)
- (nullable NSString *)channelName;
- (nullable NSString *)ownerName;
- (nullable NSArray *)subnodes;
- (nullable NSString *)accessibilityLabel;
- (nullable NSString *)accessibilityIdentifier;
@end

NSString *const GonerinoHomeFeedOverflowIdentifier = @"eml.overflow_button";

static NSArray<NSString *> *GonerinoVideoCellMarkers(void) {
    static NSArray<NSString *> *markers;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        markers = @[
            @"YTVideoWithContextNode",
            @"compact_video",
            @"rich_item",
            @"video_lockup",
            GonerinoHomeFeedOverflowIdentifier,
        ];
    });
    return markers;
}

NSSet<NSString *> *GonerinoKnownVideoMenuActionIds(void) {
    static NSSet<NSString *> *actionIds;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        actionIds = [NSSet setWithArray:@[@"1", @"3", @"5", @"12", @"31", @"58"]];
    });
    return actionIds;
}

BOOL GonerinoIsKnownVideoMenuActionId(NSString *actionId) {
    return actionId.length > 0 && [GonerinoKnownVideoMenuActionIds() containsObject:actionId];
}

static Class GonerinoVideoWithContextNodeClass = Nil;
static Class GonerinoHomeFeedASTextNodeClass     = Nil;
static Class GonerinoHomeFeedELMTextNodeClass    = Nil;
static Class GonerinoHomeFeedPlaybackNodeClass   = Nil;
static Class GonerinoAsyncCollectionViewClass    = Nil;

static void GonerinoEnsureHomeFeedClasses(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        GonerinoVideoWithContextNodeClass = NSClassFromString(@"YTVideoWithContextNode");
        GonerinoHomeFeedASTextNodeClass   = NSClassFromString(@"ASTextNode");
        GonerinoHomeFeedELMTextNodeClass  = NSClassFromString(@"ELMTextNode");
        GonerinoHomeFeedPlaybackNodeClass = NSClassFromString(@"YTInlinePlaybackPlayerNode");
        GonerinoAsyncCollectionViewClass  = NSClassFromString(@"YTAsyncCollectionView");
    });
}

@implementation Util (HomeFeedMenu)

#pragma mark - Description parsing

+ (NSDictionary *)extractVideoInfoFromDescriptionString:(NSString *)description {
    if (!description.length) {
        return @{};
    }

    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    NSArray *patterns         = @[
        @[@"videoId", @"video_id: \"([^\"\\\\]*(?:\\\\.[^\"\\\\]*)*)\""],
        @[@"videoTitle", @"video_title: \"([^\"\\\\]*(?:\\\\.[^\"\\\\]*)*)\""],
        @[@"ownerName", @"owner_display_name: \"([^\"\\\\]*(?:\\\\.[^\"\\\\]*)*)\""],
        @[@"videoId", @"videoId[: ]+\"([^\"]+)\""],
        @[@"videoId", @"/watch\\?v=([a-zA-Z0-9_-]{11})"],
        @[@"videoId", @"v=([a-zA-Z0-9_-]{11})"],
    ];

    for (NSArray *entry in patterns) {
        if (info[entry[0]]) {
            continue;
        }

        NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:entry[1] options:0 error:nil];
        NSTextCheckingResult *match = [regex firstMatchInString:description options:0
                                                          range:NSMakeRange(0, description.length)];
        if (match.numberOfRanges <= 1) {
            continue;
        }

        NSString *value = [description substringWithRange:[match rangeAtIndex:1]];
        value           = [value stringByReplacingOccurrencesOfString:@"\\\"" withString:@"\""];
        value           = [value stringByReplacingOccurrencesOfString:@"\\'" withString:@"'"];
        if (value.length) {
            info[entry[0]] = value;
        }
    }

    return info;
}

+ (void)mergeVideoInfo:(NSMutableDictionary *)target fromDescription:(NSString *)description {
    NSDictionary *parsed = [self extractVideoInfoFromDescriptionString:description];
    for (NSString *key in parsed) {
        if (!target[key]) {
            target[key] = parsed[key];
        }
    }
}

+ (NSString *)nodeDescriptionString:(id)node {
    if (!node) {
        return @"";
    }

    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    NSString *debugDescription        = [node debugDescription];
    if (debugDescription.length) {
        [parts addObject:debugDescription];
    }

    NSString *description = [node description];
    if (description.length && ![description isEqualToString:debugDescription]) {
        [parts addObject:description];
    }

    if ([node respondsToSelector:@selector(accessibilityIdentifier)]) {
        NSString *accessibilityIdentifier = [node accessibilityIdentifier];
        if (accessibilityIdentifier.length) {
            [parts addObject:accessibilityIdentifier];
        }
    }

    return [parts componentsJoinedByString:@" "];
}

+ (BOOL)descriptionReferencesVideoCell:(NSString *)description {
    if (!description.length) {
        return NO;
    }

    for (NSString *marker in GonerinoVideoCellMarkers()) {
        if ([description containsString:marker]) {
            return YES;
        }
    }

    return NO;
}

#pragma mark - ELM node traversal

+ (BOOL)isOverflowButtonNode:(id)node {
    return [[self nodeDescriptionString:node] containsString:GonerinoHomeFeedOverflowIdentifier];
}

+ (id)supernodeForNode:(id)node {
    if (!node) {
        return nil;
    }

    for (NSString *key in @[@"supernode", @"parentNode", @"_supernode"]) {
        id parent = [Util safeValueForKey:key onObject:node];
        if (parent) {
            return parent;
        }
    }

    id supernodes = [Util safeValueForKey:@"supernodes" onObject:node];
    if ([supernodes respondsToSelector:@selector(allObjects)]) {
        NSArray *allObjects = [supernodes allObjects];
        if (allObjects.count > 0) {
            return allObjects.firstObject;
        }
    }

    return nil;
}

+ (void)visitNodeTree:(id)node visitor:(void (^)(id node, BOOL *stop))visitor {
    if (!node || !visitor) {
        return;
    }

    BOOL stop = NO;
    visitor(node, &stop);
    if (stop) {
        return;
    }

    if ([node respondsToSelector:@selector(subnodes)]) {
        for (id subnode in [node subnodes]) {
            [self visitNodeTree:subnode visitor:visitor];
        }
    }

    id yogaChildren = [Util safeValueForKey:@"yogaChildren" onObject:node];
    if ([yogaChildren isKindOfClass:[NSArray class]]) {
        for (id child in yogaChildren) {
            [self visitNodeTree:child visitor:visitor];
        }
    }
}

+ (id)findVideoContextNodeInTree:(id)node {
    if (!node) {
        return nil;
    }

    GonerinoEnsureHomeFeedClasses();
    if (GonerinoVideoWithContextNodeClass && [node isKindOfClass:GonerinoVideoWithContextNodeClass]) {
        return node;
    }

    if ([node respondsToSelector:@selector(subnodes)]) {
        for (id subnode in [node subnodes]) {
            id found = [self findVideoContextNodeInTree:subnode];
            if (found) {
                return found;
            }
        }
    }

    id yogaChildren = [Util safeValueForKey:@"yogaChildren" onObject:node];
    if ([yogaChildren isKindOfClass:[NSArray class]]) {
        for (id child in yogaChildren) {
            id found = [self findVideoContextNodeInTree:child];
            if (found) {
                return found;
            }
        }
    }

    return nil;
}

+ (id)findVideoContainerNodeFromNode:(id)startNode {
    if (!startNode) {
        return nil;
    }

    id bestMatch = nil;
    for (id current = startNode; current; current = [self supernodeForNode:current]) {
        NSString *description = [self nodeDescriptionString:current];
        if ([self findVideoContextNodeInTree:current] || [Util findPlaybackNodeInTree:current]) {
            return [self findVideoContextNodeInTree:current] ?: current;
        }

        if ([description containsString:@"compact_video"] || [description containsString:@"rich_item"] ||
            [description containsString:@"video_lockup"]) {
            return current;
        }

        if ([self descriptionReferencesVideoCell:description]) {
            bestMatch = current;
        }
    }

    return bestMatch ?: startNode;
}

+ (NSDictionary *)extractVideoInfoFromNodeTree:(id)rootNode {
    NSMutableDictionary *info = [NSMutableDictionary dictionary];

    for (id current = rootNode; current; current = [self supernodeForNode:current]) {
        [self mergeVideoInfo:info fromDescription:[self nodeDescriptionString:current]];
    }

    [self visitNodeTree:rootNode
                  visitor:^(id node, BOOL *stop) {
                      [self mergeVideoInfo:info fromDescription:[self nodeDescriptionString:node]];

                      id element = [Util safeValueForKey:@"element" onObject:node];
                      if (element) {
                          [self mergeVideoInfo:info fromDescription:[element description]];
                          [self mergeVideoInfo:info fromDescription:[element debugDescription]];

                          id context = [Util safeValueForKey:@"context" onObject:element];
                          if (context) {
                              [self mergeVideoInfo:info fromDescription:[context description]];
                          }
                      }

                      NSString *videoId    = info[@"videoId"];
                      NSString *ownerName  = info[@"ownerName"];
                      if ([videoId isKindOfClass:[NSString class]] && videoId.length &&
                          [ownerName isKindOfClass:[NSString class]] && ownerName.length) {
                          *stop = YES;
                      }
                  }];

    return info;
}

+ (id)asyncDisplayKitNodeForView:(UIView *)view {
    if (!view) {
        return nil;
    }

    id node = [Util safeValueForKey:@"asyncdisplaykit_node" onObject:view];
    if (node) {
        return node;
    }

    if ([view respondsToSelector:@selector(asyncdisplaykit_node)]) {
        return [view performSelector:@selector(asyncdisplaykit_node)];
    }

    return nil;
}

+ (id)nodeForView:(UIView *)view {
    if (!view) {
        return nil;
    }

    id node = [Util safeValueForKey:@"node" onObject:view];
    if (node) {
        return node;
    }

    if ([view respondsToSelector:@selector(node)]) {
        node = [view performSelector:@selector(node)];
        if (node) {
            return node;
        }
    }

    return [self asyncDisplayKitNodeForView:view];
}

+ (BOOL)nodeReferencesVideoContext:(id)node {
    if (!node) {
        return NO;
    }

    if ([self isOverflowButtonNode:node]) {
        return YES;
    }

    if ([self findVideoContextNodeInTree:node] || [Util findPlaybackNodeInTree:node]) {
        return YES;
    }

    return [self descriptionReferencesVideoCell:[self nodeDescriptionString:node]];
}

#pragma mark - Public API

+ (id)videoContextNodeFromSheetSourceView:(UIView *)sourceView {
    if (!sourceView) {
        return nil;
    }

    for (UIView *view = sourceView; view; view = view.superview) {
        id node = [self nodeForView:view];
        if (!node) {
            continue;
        }

        if ([self isOverflowButtonNode:node]) {
            id containerNode = [self findVideoContainerNodeFromNode:node];
            return containerNode ?: node;
        }

        id contextNode = [self findVideoContextNodeInTree:node];
        if (contextNode) {
            return contextNode;
        }

        if ([self nodeReferencesVideoContext:node]) {
            return [self findVideoContainerNodeFromNode:node] ?: node;
        }
    }

    return nil;
}

+ (BOOL)isHomeFeedVideoContextMenuForSourceView:(UIView *)sourceView action:(id)action {
    id node = [self videoContextNodeFromSheetSourceView:sourceView];
    if (node && [self nodeReferencesVideoContext:node]) {
        return YES;
    }

    id directNode = [self nodeForView:sourceView];
    if ([self isOverflowButtonNode:directNode]) {
        return YES;
    }

    NSString *identifier = nil;
    if (action) {
        identifier = [Util safeValueForKey:@"_accessibilityIdentifier" onObject:action];
    }

    if (GonerinoIsKnownVideoMenuActionId(identifier)) {
        return [self isOverflowButtonNode:directNode] ||
               [self descriptionReferencesVideoCell:[self nodeDescriptionString:directNode]];
    }

    return NO;
}

#pragma mark - Metadata extraction

+ (NSString *)textFromNode:(id)node {
    if (![node respondsToSelector:@selector(attributedText)]) {
        return nil;
    }

    NSAttributedString *attributedText = [node attributedText];
    return attributedText.length ? [attributedText string] : nil;
}

+ (BOOL)isTextMetadataNode:(id)node {
    GonerinoEnsureHomeFeedClasses();
    return (GonerinoHomeFeedASTextNodeClass && [node isKindOfClass:GonerinoHomeFeedASTextNodeClass]) ||
           (GonerinoHomeFeedELMTextNodeClass && [node isKindOfClass:GonerinoHomeFeedELMTextNodeClass]);
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
            } else if (!title.length && text.length > 3 && ![text containsString:@":"] &&
                       ![text containsString:@" views"]) {
                if (!channelName.length && text.length <= 40) {
                    [channelName setString:text];
                } else if (text.length > (channelName.length ?: 0)) {
                    [title setString:text];
                }
            }
        }
    }

    if ([node respondsToSelector:@selector(accessibilityLabel)]) {
        NSString *accessibilityLabel = [node accessibilityLabel];
        if (accessibilityLabel.length && ![accessibilityLabel containsString:@" views"] && !title.length) {
            [title setString:accessibilityLabel];
        }
    }

    if ([node respondsToSelector:@selector(subnodes)]) {
        for (id subnode in [node subnodes]) {
            [self collectTextMetadataFromNode:subnode channelName:channelName title:title];
        }
    }

    id yogaChildren = [Util safeValueForKey:@"yogaChildren" onObject:node];
    if ([yogaChildren isKindOfClass:[NSArray class]]) {
        for (id child in yogaChildren) {
            [self collectTextMetadataFromNode:child channelName:channelName title:title];
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
    id resolvedNode = [self findVideoContextNodeInTree:contextNode] ?: contextNode;
    GonerinoEnsureHomeFeedClasses();
    if (!GonerinoVideoWithContextNodeClass || ![resolvedNode isKindOfClass:GonerinoVideoWithContextNodeClass]) {
        return nil;
    }

    if (![resolvedNode respondsToSelector:@selector(video)]) {
        return nil;
    }

    id video = [resolvedNode performSelector:@selector(video)];
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
    id resolvedNode = [self findVideoContextNodeInTree:contextNode] ?: contextNode;

    if (!completion || !resolvedNode) {
        GonerinoLogError(@"extractVideoInfoFromContextNode: missing completion or context node");
        return;
    }

    NSString *videoId    = nil;
    NSString *videoTitle = nil;
    NSString *ownerName  = nil;
    NSString *strategy   = nil;

    id playbackNode = [Util findPlaybackNodeInTree:resolvedNode];
    if (playbackNode) {
        NSDictionary *playbackInfo = [Util extractVideoInfoFromPlaybackNodeSync:playbackNode];
        videoId                    = playbackInfo[@"videoId"];
        videoTitle                 = playbackInfo[@"videoTitle"];
        ownerName                  = playbackInfo[@"ownerName"];
        if (videoId.length || videoTitle.length || ownerName.length) {
            strategy = @"playback";
        }
    }

    if (!ownerName.length || !videoTitle.length) {
        NSMutableString *channelFromText = [NSMutableString string];
        NSMutableString *titleFromText   = [NSMutableString string];
        [self collectTextMetadataFromNode:resolvedNode channelName:channelFromText title:titleFromText];

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
        NSString *channelFromTree = [self findChannelNameInTree:resolvedNode];
        if (channelFromTree.length) {
            ownerName = channelFromTree;
            strategy  = strategy ?: @"channelSelector";
        }
    }

    if (!ownerName.length) {
        NSString *channelFromVideo = [self channelNameFromVideoContextNode:resolvedNode];
        if (channelFromVideo.length) {
            ownerName = channelFromVideo;
            strategy  = strategy ?: @"videoContext";
        }
    }

    if (!videoId.length || !videoTitle.length || !ownerName.length) {
        NSDictionary *treeInfo = [self extractVideoInfoFromNodeTree:resolvedNode];
        if (!videoId.length) {
            videoId = treeInfo[@"videoId"];
        }
        if (!videoTitle.length) {
            videoTitle = treeInfo[@"videoTitle"];
        }
        if (!ownerName.length) {
            ownerName = treeInfo[@"ownerName"];
        }
        if (treeInfo.count > 0) {
            strategy = strategy ?: @"elmTree";
        }
    }

    if (videoId.length || videoTitle.length || ownerName.length) {
        GonerinoLog(@"extractVideoInfoFromContextNode via %@: id=%@ title=%@ channel=%@", strategy ?: @"unknown",
              videoId ?: @"(none)", videoTitle ?: @"(none)", ownerName ?: @"(none)");
        completion(videoId, videoTitle, ownerName);
    } else {
        GonerinoLogError(@"extractVideoInfoFromContextNode failed for %@", NSStringFromClass([resolvedNode class]));
        completion(nil, nil, nil);
    }
}

#pragma mark - Feed removal

+ (BOOL)nodeTreeContainsFeedVideoMarker:(id)node {
    if (!node) {
        return NO;
    }

    GonerinoEnsureHomeFeedClasses();
    if ((GonerinoVideoWithContextNodeClass && [node isKindOfClass:GonerinoVideoWithContextNodeClass]) ||
        (GonerinoHomeFeedPlaybackNodeClass && [node isKindOfClass:GonerinoHomeFeedPlaybackNodeClass])) {
        return YES;
    }

    if ([node respondsToSelector:@selector(subnodes)]) {
        for (id subnode in [node subnodes]) {
            if ([self nodeTreeContainsFeedVideoMarker:subnode]) {
                return YES;
            }
        }
    }

    id yogaChildren = [Util safeValueForKey:@"yogaChildren" onObject:node];
    if ([yogaChildren isKindOfClass:[NSArray class]]) {
        for (id child in yogaChildren) {
            if ([self nodeTreeContainsFeedVideoMarker:child]) {
                return YES;
            }
        }
    }

    return NO;
}

+ (BOOL)isFeedVideoCellNode:(id)node {
    if (!node) {
        return NO;
    }

    GonerinoEnsureHomeFeedClasses();
    if (GonerinoVideoWithContextNodeClass && [node isKindOfClass:GonerinoVideoWithContextNodeClass]) {
        return YES;
    }

    if ([self nodeTreeContainsFeedVideoMarker:node]) {
        return YES;
    }

    return [self descriptionReferencesVideoCell:[self nodeDescriptionString:node]];
}

+ (BOOL)feedCellNodeShouldBeRemoved:(id)node {
    if (!node || ![self isFeedVideoCellNode:node]) {
        return NO;
    }

    if ([Util nodeContainsBlockedVideo:node]) {
        return YES;
    }

    if (![Util gonerinoHasChannelOrVideoBlockFilters]) {
        return NO;
    }

    NSDictionary *info   = [self extractVideoInfoFromNodeTree:node];
    NSString *videoId       = info[@"videoId"];
    NSString *videoTitle    = info[@"videoTitle"];
    NSString *ownerName     = info[@"ownerName"];

    if (videoId.length && [[VideoManager sharedInstance] isVideoBlocked:videoId]) {
        return YES;
    }
    if (ownerName.length && [[ChannelManager sharedInstance] isChannelBlocked:ownerName]) {
        return YES;
    }
    if (videoTitle.length && [[WordManager sharedInstance] isWordBlocked:videoTitle]) {
        return YES;
    }
    if (ownerName.length && [[WordManager sharedInstance] isWordBlocked:ownerName]) {
        return YES;
    }

    return NO;
}

+ (void)refreshCollectionViewsInView:(UIView *)view collectionClass:(Class)collectionClass immediate:(BOOL)immediate {
    if ([view isKindOfClass:collectionClass]) {
        if (immediate && [view respondsToSelector:@selector(gonerino_removeOffendingCellsNow)]) {
            [view performSelector:@selector(gonerino_removeOffendingCellsNow)];
        } else if ([view respondsToSelector:@selector(removeOffendingCells)]) {
            [view performSelector:@selector(removeOffendingCells)];
        }
    }

    for (UIView *subview in view.subviews) {
        [self refreshCollectionViewsInView:subview collectionClass:collectionClass immediate:immediate];
    }
}

+ (void)refreshVisibleHomeFeedsRemovingBlockedContent {
    if (![Util gonerinoHasActiveBlockFilters]) {
        return;
    }

    GonerinoEnsureHomeFeedClasses();
    Class collectionClass = GonerinoAsyncCollectionViewClass;
    if (!collectionClass) {
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *keyWindow = nil;
        for (UIWindow *window in UIApplication.sharedApplication.windows) {
            if (window.isKeyWindow) {
                keyWindow = window;
                break;
            }
        }

        if (keyWindow) {
            [self refreshCollectionViewsInView:keyWindow collectionClass:collectionClass immediate:YES];
        }
    });
}

@end

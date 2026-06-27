#import "Util.h"

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const GonerinoHomeFeedOverflowIdentifier;

FOUNDATION_EXPORT NSSet<NSString *> *GonerinoKnownVideoMenuActionIds(void);

FOUNDATION_EXPORT BOOL GonerinoIsKnownVideoMenuActionId(NSString *_Nullable actionId);

@interface Util (HomeFeedMenu)

+ (nullable id)videoContextNodeFromSheetSourceView:(UIView *)sourceView;

+ (BOOL)isHomeFeedVideoContextMenuForSourceView:(UIView *)sourceView action:(nullable id)action;

+ (void)extractVideoInfoFromContextNode:(id)contextNode
                              completion:(void (^)(NSString *_Nullable videoId, NSString *_Nullable videoTitle,
                                                   NSString *_Nullable ownerName))completion;

+ (BOOL)isFeedVideoCellNode:(id)node;

+ (BOOL)feedCellNodeShouldBeRemoved:(id)node;

+ (void)refreshVisibleHomeFeedsRemovingBlockedContent;

@end

NS_ASSUME_NONNULL_END

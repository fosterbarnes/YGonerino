#import "Tweak.h"
#import "Util+HomeFeedMenu.h"
#import "GonerinoLog.h"

typedef NS_ENUM(NSInteger, GonerinoBlockActionType) {
    GonerinoBlockActionTypeChannel = 0,
    GonerinoBlockActionTypeVideo   = 1,
};

%hook YTAsyncCollectionView

static void *GonerinoRemovalWorkKey = &GonerinoRemovalWorkKey;
static const NSTimeInterval GonerinoRemovalDebounceInterval = 0.25;

static Class GonerinoASCollectionViewCellClass = Nil;

static Class GonerinoGetASCollectionViewCellClass(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ GonerinoASCollectionViewCellClass = NSClassFromString(@"_ASCollectionViewCell"); });
    return GonerinoASCollectionViewCellClass;
}

%new
- (BOOL)gonerino_isVisibleForRemoval {
    if (!self.window || self.hidden || self.alpha < 0.01) {
        return NO;
    }

    for (UIView *view = self.superview; view; view = view.superview) {
        if (view.hidden || view.alpha < 0.01) {
            return NO;
        }
    }

    return YES;
}

%new
- (void)gonerino_cancelPendingRemoval {
    dispatch_block_t block = objc_getAssociatedObject(self, GonerinoRemovalWorkKey);
    if (block) {
        dispatch_block_cancel(block);
        objc_setAssociatedObject(self, GonerinoRemovalWorkKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

%new
- (void)gonerino_removeOffendingCellsNow {
    if (![Util gonerinoHasActiveBlockFilters]) {
        return;
    }

    @try {
        NSArray *visibleCells              = [self visibleCells];
        if (visibleCells.count == 0) {
            return;
        }

        NSMutableArray *indexPathsToRemove = [NSMutableArray array];
        Class asCellClass                  = GonerinoGetASCollectionViewCellClass();

        for (UICollectionViewCell *cell in visibleCells) {
            if (asCellClass && ![cell isKindOfClass:asCellClass]) {
                continue;
            }

            _ASCollectionViewCell *asCell = (_ASCollectionViewCell *)cell;
            if (![asCell respondsToSelector:@selector(node)]) {
                continue;
            }

            id node = [asCell node];
            if (!node) {
                continue;
            }

            if ([Util feedCellNodeShouldBeRemoved:node]) {
                NSIndexPath *indexPath = [self indexPathForCell:cell];
                if (indexPath) {
                    [indexPathsToRemove addObject:indexPath];
                }
            }
        }

        if (indexPathsToRemove.count > 0) {
            [self performBatchUpdates:^{ [self deleteItemsAtIndexPaths:indexPathsToRemove]; } completion:nil];
        }
    } @catch (NSException *exception) {
        GonerinoLogError(@"Exception in gonerino_removeOffendingCellsNow: %@", exception);
    }
}

%new
- (void)gonerino_scheduleRemovalDebounced {
    if (![Util gonerinoHasActiveBlockFilters]) {
        [self gonerino_cancelPendingRemoval];
        return;
    }

    if (![self gonerino_isVisibleForRemoval]) {
        [self gonerino_cancelPendingRemoval];
        return;
    }

    [self gonerino_cancelPendingRemoval];

    __weak typeof(self) weakSelf = self;
    dispatch_block_t block = dispatch_block_create(DISPATCH_BLOCK_INHERIT_QOS_CLASS, ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }

        if (![strongSelf gonerino_isVisibleForRemoval]) {
            objc_setAssociatedObject(strongSelf, GonerinoRemovalWorkKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            return;
        }

        objc_setAssociatedObject(strongSelf, GonerinoRemovalWorkKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [strongSelf gonerino_removeOffendingCellsNow];
    });

    objc_setAssociatedObject(self, GonerinoRemovalWorkKey, block, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(GonerinoRemovalDebounceInterval * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), block);
}

- (void)layoutSubviews {
    %orig;
    [self gonerino_scheduleRemovalDebounced];
}

%new
- (void)removeOffendingCells {
    [self gonerino_scheduleRemovalDebounced];
}

%end

%hook YTDefaultSheetController

static void *GonerinoContextNodeKey       = &GonerinoContextNodeKey;
static void *GonerinoBlockActionsAddedKey = &GonerinoBlockActionsAddedKey;
static void *GonerinoHomeFeedMenuOpenedKey = &GonerinoHomeFeedMenuOpenedKey;

%new
- (void)gonerino_logHomeFeedMenuOpenedWithNode:(id)node {
    if (objc_getAssociatedObject(self, GonerinoHomeFeedMenuOpenedKey)) {
        return;
    }

    objc_setAssociatedObject(self, GonerinoHomeFeedMenuOpenedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    GonerinoLog(@"[HomeFeedMenu] Three-dots tapped on home feed (sheet=%p nodeClass=%@)",
          self, node ? NSStringFromClass([node class]) : @"(nil)");

    if (!node) {
        return;
    }

    [Util extractVideoInfoFromContextNode:node
                              completion:^(NSString *videoId, NSString *videoTitle, NSString *ownerName) {
                                  GonerinoLog(@"[HomeFeedMenu] Menu target: videoId=%@ title=%@ channel=%@",
                                        videoId.length ? videoId : @"(unknown)",
                                        videoTitle.length ? videoTitle : @"(unknown)",
                                        ownerName.length ? ownerName : @"(unknown)");
                              }];
}

%new
- (id)gonerino_cachedContextNode {
    id node = objc_getAssociatedObject(self, GonerinoContextNodeKey);
    if (!node) {
        UIView *sourceView = [self valueForKey:@"sourceView"];
        node               = [Util videoContextNodeFromSheetSourceView:sourceView];
    }
    return node;
}

%new
- (void)gonerino_performBlockAction:(GonerinoBlockActionType)actionType {
    @try {
        id node = [self gonerino_cachedContextNode];
        BOOL blockingChannel = actionType == GonerinoBlockActionTypeChannel;
        GonerinoLog(@"[HomeFeedMenu] Block %@ selected from home feed menu (nodeClass=%@)",
              blockingChannel ? @"channel" : @"video",
              node ? NSStringFromClass([node class]) : @"(nil)");

        [Util extractVideoInfoFromContextNode:node
                                    completion:^(NSString *videoId, NSString *videoTitle, NSString *ownerName) {
                                        if (blockingChannel) {
                                            if (!ownerName.length) {
                                                GonerinoLogError(@"[HomeFeedMenu] Block channel failed: could not "
                                                                 @"resolve channel name (videoId=%@ title=%@)",
                                                                 videoId ?: @"(none)", videoTitle ?: @"(none)");
                                                return;
                                            }
                                            [[ChannelManager sharedInstance] addBlockedChannel:ownerName];
                                            GonerinoLog(@"[HomeFeedMenu] Blocked channel \"%@\" from home feed "
                                                        @"(videoId=%@ title=%@)",
                                                  ownerName, videoId ?: @"(unknown)", videoTitle ?: @"(unknown)");
                                            [[%c(YTToastResponderEvent)
                                                eventWithMessage:[NSString stringWithFormat:@"Blocked %@", ownerName]
                                                  firstResponder:(UIViewController *)self] send];
                                            [Util refreshVisibleHomeFeedsRemovingBlockedContent];
                                        } else {
                                            if (!videoId.length) {
                                                GonerinoLogError(@"[HomeFeedMenu] Block video failed: could not "
                                                                 @"resolve video id (title=%@ channel=%@)",
                                                                 videoTitle ?: @"(none)", ownerName ?: @"(none)");
                                                return;
                                            }
                                            [[VideoManager sharedInstance] addBlockedVideo:videoId
                                                                                     title:videoTitle
                                                                                   channel:ownerName];
                                            GonerinoLog(@"[HomeFeedMenu] Blocked video \"%@\" (%@) from home feed "
                                                        @"(channel=%@)",
                                                  videoTitle.length ? videoTitle : @"(no title)", videoId,
                                                  ownerName.length ? ownerName : @"(unknown)");
                                            [[%c(YTToastResponderEvent)
                                                eventWithMessage:[NSString stringWithFormat:@"Blocked video: %@",
                                                                                           videoTitle ?: videoId]
                                                  firstResponder:(UIViewController *)self] send];
                                            [Util refreshVisibleHomeFeedsRemovingBlockedContent];
                                        }

                                        if ([self respondsToSelector:@selector(dismiss)]) {
                                            [self dismiss];
                                        }
                                    }];
    } @catch (NSException *exception) {
        GonerinoLogError(@"[HomeFeedMenu] Exception in gonerino_performBlockAction: %@", exception);
    }
}

- (void)addAction:(YTActionSheetAction *)action {
    %orig;

    if (objc_getAssociatedObject(self, GonerinoBlockActionsAddedKey)) {
        return;
    }

    UIView *sourceView = [self valueForKey:@"sourceView"];
    id contextNode     = [Util videoContextNodeFromSheetSourceView:sourceView];

    if (![Util isHomeFeedVideoContextMenuForSourceView:sourceView action:action]) {
        return;
    }

    if (contextNode) {
        objc_setAssociatedObject(self, GonerinoContextNodeKey, contextNode, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    [self gonerino_logHomeFeedMenuOpenedWithNode:contextNode];

    NSInteger currentActionsCount = 0;
    if ([self respondsToSelector:@selector(actions)]) {
        currentActionsCount = [[self actions] count];
    }

    NSString *actionId = action ? [action valueForKey:@"_accessibilityIdentifier"] : nil;
    if (currentActionsCount < 2 && !GonerinoIsKnownVideoMenuActionId(actionId)) {
        GonerinoLog(@"[HomeFeedMenu] Waiting for more menu actions (%ld)", (long)currentActionsCount);
        return;
    }

    GonerinoLog(@"[HomeFeedMenu] Injecting block actions into sheet %p", self);

    __weak typeof(self) weakSelf = self;
    CGSize iconSize              = CGSizeMake(24, 24);
    if (action) {
        UIImage *originalIcon = [action valueForKey:@"_iconImage"];
        if (originalIcon) {
            iconSize = originalIcon.size;
        }
    }

    YTActionSheetAction *blockChannelAction = [%c(YTActionSheetAction)
        actionWithTitle:@"Block channel"
              iconImage:[Util createBlockChannelIconWithSize:iconSize]
                  style:0
                handler:^(YTActionSheetAction *action) {
                    __strong typeof(self) strongSelf = weakSelf;
                    [strongSelf gonerino_performBlockAction:GonerinoBlockActionTypeChannel];
                }];

    YTActionSheetAction *blockVideoAction = [%c(YTActionSheetAction)
        actionWithTitle:@"Block video"
              iconImage:[Util createBlockVideoIconWithSize:iconSize]
                  style:0
                handler:^(YTActionSheetAction *action) {
                    __strong typeof(self) strongSelf = weakSelf;
                    [strongSelf gonerino_performBlockAction:GonerinoBlockActionTypeVideo];
                }];

    objc_setAssociatedObject(self, GonerinoBlockActionsAddedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [self addAction:blockChannelAction];
    [self addAction:blockVideoAction];
}

%end

%hook YTRightNavigationButtons
%property(retain, nonatomic) YTQTMButton *gonerinoButton;

- (NSMutableArray *)buttons {
    NSMutableArray *retVal = %orig.mutableCopy;

    BOOL showButton = [[NSUserDefaults standardUserDefaults] objectForKey:@"GonerinoShowButton"] == nil
                          ? YES
                          : [[NSUserDefaults standardUserDefaults] boolForKey:@"GonerinoShowButton"];

    if (showButton) {
        [self.gonerinoButton removeFromSuperview];
        [self addSubview:self.gonerinoButton];

        NSInteger pageStyle;
        Class YTPageStyleControllerClass = %c(YTPageStyleController);
        if (YTPageStyleControllerClass)
            pageStyle = [YTPageStyleControllerClass pageStyle];
        else {
            YTAppDelegate *delegate                    = (YTAppDelegate *)[UIApplication sharedApplication].delegate;
            YTAppViewControllerImpl *appViewController = [delegate valueForKey:@"_appViewController"];
            pageStyle                                  = [appViewController pageStyle];
        }

        if (!self.gonerinoButton) {
            self.gonerinoButton = [%c(YTQTMButton) iconButton];
            if ([self.gonerinoButton respondsToSelector:@selector(enableNewTouchFeedback)]) {
                [self.gonerinoButton enableNewTouchFeedback];
            }
            self.gonerinoButton.frame = CGRectMake(0, 0, 40, 40);
            [self.gonerinoButton addTarget:self
                                    action:@selector(gonerinoButtonPressed:)
                          forControlEvents:UIControlEventTouchUpInside];
            [retVal insertObject:self.gonerinoButton atIndex:0];
        }

        BOOL isEnabled = [[NSUserDefaults standardUserDefaults] objectForKey:@"GonerinoEnabled"] == nil
                             ? YES
                             : [[NSUserDefaults standardUserDefaults] boolForKey:@"GonerinoEnabled"];

        UIImage *image     = [Util createBlockVideoIconWithSize:CGSizeMake(20, 20)];
        UIColor *tintColor = pageStyle ? UIColor.whiteColor : UIColor.blackColor;

        if (!isEnabled) {
            tintColor = [tintColor colorWithAlphaComponent:0.4];
        }

        image = [%c(QTMIcon) tintImage:image color:tintColor];
        [self.gonerinoButton setImage:image forState:UIControlStateNormal];
    } else {
        if (self.gonerinoButton) {
            [self.gonerinoButton removeFromSuperview];
            self.gonerinoButton = nil;
        }
    }

    return retVal;
}

- (NSMutableArray *)visibleButtons {
    NSMutableArray *retVal = %orig.mutableCopy;

    BOOL showButton = [[NSUserDefaults standardUserDefaults] objectForKey:@"GonerinoShowButton"] == nil
                          ? YES
                          : [[NSUserDefaults standardUserDefaults] boolForKey:@"GonerinoShowButton"];

    if (showButton && self.gonerinoButton) {
        [self.gonerinoButton removeFromSuperview];
        [self addSubview:self.gonerinoButton];
        [retVal insertObject:self.gonerinoButton atIndex:0];
    }

    return retVal;
}

%new
- (void)gonerinoButtonPressed:(UIButton *)sender {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    BOOL isEnabled = [defaults objectForKey:@"GonerinoEnabled"] == nil ? YES : [defaults boolForKey:@"GonerinoEnabled"];
    BOOL newState  = !isEnabled;
    [defaults setBool:newState forKey:@"GonerinoEnabled"];
    [defaults synchronize];
    [Util gonerinoInvalidateFilterCache];

    NSInteger pageStyle;
    Class YTPageStyleControllerClass = %c(YTPageStyleController);
    if (YTPageStyleControllerClass)
        pageStyle = [YTPageStyleControllerClass pageStyle];
    else {
        YTAppDelegate *delegate                    = (YTAppDelegate *)[UIApplication sharedApplication].delegate;
        YTAppViewControllerImpl *appViewController = [delegate valueForKey:@"_appViewController"];
        pageStyle                                  = [appViewController pageStyle];
    }

    UIImage *image     = [Util createBlockVideoIconWithSize:CGSizeMake(20, 20)];
    UIColor *tintColor = pageStyle ? UIColor.whiteColor : UIColor.blackColor;

    if (!newState) {
        tintColor = [tintColor colorWithAlphaComponent:0.4];
    }

    image = [%c(QTMIcon) tintImage:image color:tintColor];
    [self.gonerinoButton setImage:image forState:UIControlStateNormal];

    UIViewController *topVC = [[UIApplication sharedApplication] delegate].window.rootViewController;
    while (topVC.presentedViewController) {
        topVC = topVC.presentedViewController;
    }

    if (topVC) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [[%c(YTToastResponderEvent)
                eventWithMessage:[NSString stringWithFormat:@"Gonerino %@", newState ? @"enabled" : @"disabled"]
                  firstResponder:topVC] send];
        });
    }
}

%end

%ctor {
    %init;
}

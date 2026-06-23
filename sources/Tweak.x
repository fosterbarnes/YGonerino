#import "Tweak.h"

%hook YTAsyncCollectionView

- (void)layoutSubviews {
    %orig;
    [self removeOffendingCells];
}

%new
- (void)removeOffendingCells {
    __weak typeof(self) weakSelf = self;

    dispatch_async(dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf)
            return;

        @try {
            NSArray *visibleCells              = [strongSelf visibleCells];
            NSMutableArray *indexPathsToRemove = [NSMutableArray array];

            for (UICollectionViewCell *cell in visibleCells) {
                if (![cell isKindOfClass:NSClassFromString(@"_ASCollectionViewCell")]) {
                    continue;
                }

                _ASCollectionViewCell *asCell = (_ASCollectionViewCell *)cell;
                if (![asCell respondsToSelector:@selector(node)]) {
                    continue;
                }

                id node = [asCell node];
                if (![node isKindOfClass:NSClassFromString(@"YTVideoWithContextNode")]) {
                    continue;
                }

                if ([Util nodeContainsBlockedVideo:node]) {
                    NSIndexPath *indexPath = [strongSelf indexPathForCell:cell];
                    if (indexPath) {
                        [indexPathsToRemove addObject:indexPath];
                    }
                }
            }

            if (indexPathsToRemove.count > 0) {
                [strongSelf
                    performBatchUpdates:^{ [strongSelf deleteItemsAtIndexPaths:indexPathsToRemove]; }
                             completion:nil];
            }
        } @catch (NSException *exception) {
            NSLog(@"[YGonerino] Exception in removeOffendingCells: %@", exception);
        }
    });
}

%end

%hook YTDefaultSheetController

- (void)addAction:(YTActionSheetAction *)action {
    %orig;

    static void *blockActionKey = &blockActionKey;
    if (objc_getAssociatedObject(self, blockActionKey)) {
        NSLog(@"[YGonerino] addAction: skipped, block actions already added for this sheet instance (self=%p)", self);
        return;
    }

    UIView *sourceView = [self valueForKey:@"sourceView"];
    id node            = [sourceView valueForKey:@"asyncdisplaykit_node"];

    NSLog(@"[YGonerino] addAction: called with action title=\"%@\" | sourceView=%@ | node class=%@ | node "
          @"debugDescription=%@",
          action ? [action valueForKey:@"_title"] : @"(nil)", sourceView, node ? NSStringFromClass([node class]) : @"(nil)",
          node ? [node debugDescription] : @"(nil)");

    if (!node || ![node debugDescription] || ![[node debugDescription] containsString:@"YTVideoWithContextNode"]) {
        NSLog(@"[YGonerino] addAction: bailing out, node missing or debugDescription does not contain "
              @"\"YTVideoWithContextNode\"");
        return;
    }

    NSInteger currentActionsCount = 3;
    if ([self respondsToSelector:@selector(actions)]) {
        currentActionsCount = [[self actions] count];
    }

    NSLog(@"[YGonerino] addAction: currentActionsCount=%ld", (long)currentActionsCount);

    if (currentActionsCount < 3) {
        NSLog(@"[YGonerino] addAction: bailing out, not enough actions yet (%ld < 3)", (long)currentActionsCount);
        return;
    }

    NSLog(@"[YGonerino] addAction: conditions met, adding Block channel / Block video actions to sheet %p", self);

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
                    NSLog(@"[YGonerino] Block channel: handler fired (strongSelf=%p)", strongSelf);
                    @try {
                        UIView *sourceView = [strongSelf valueForKey:@"sourceView"];
                        id node            = [sourceView valueForKey:@"asyncdisplaykit_node"];

                        NSLog(@"[YGonerino] Block channel: sourceView=%@ | node class=%@", sourceView,
                              node ? NSStringFromClass([node class]) : @"(nil)");

                        [Util extractVideoInfoFromContextNode:node
                                                    completion:^(NSString *videoId, NSString *videoTitle,
                                                                 NSString *ownerName) {
                                                        NSLog(@"[YGonerino] Block channel: extraction completion "
                                                              @"fired with ownerName=%@",
                                                              ownerName ?: @"(nil)");
                                                        if (ownerName.length) {
                                                            [[ChannelManager sharedInstance]
                                                                addBlockedChannel:ownerName];
                                                            NSLog(@"[YGonerino] Block channel: added \"%@\" to "
                                                                  @"ChannelManager",
                                                                  ownerName);
                                                            UIViewController *viewController =
                                                                (UIViewController *)strongSelf;
                                                            [[%c(YTToastResponderEvent)
                                                                eventWithMessage:[NSString
                                                                                     stringWithFormat:@"Blocked %@",
                                                                                                      ownerName]
                                                                  firstResponder:viewController] send];
                                                            if ([strongSelf respondsToSelector:@selector(dismiss)]) {
                                                                [strongSelf dismiss];
                                                            }
                                                        } else {
                                                            NSLog(@"[YGonerino] Block channel failed: no channel name "
                                                                  @"extracted");
                                                        }
                                                    }];
                    } @catch (NSException *e) {
                        NSLog(@"[YGonerino] Exception in block action: %@", e);
                    }
                }];

    YTActionSheetAction *blockVideoAction = [%c(YTActionSheetAction)
        actionWithTitle:@"Block video"
              iconImage:[Util createBlockVideoIconWithSize:iconSize]
                  style:0
                handler:^(YTActionSheetAction *action) {
                    __strong typeof(self) strongSelf = weakSelf;
                    NSLog(@"[YGonerino] Block video: handler fired (strongSelf=%p)", strongSelf);
                    @try {
                        UIView *sourceView = [strongSelf valueForKey:@"sourceView"];
                        id node            = [sourceView valueForKey:@"asyncdisplaykit_node"];

                        NSLog(@"[YGonerino] Block video: sourceView=%@ | node class=%@", sourceView,
                              node ? NSStringFromClass([node class]) : @"(nil)");

                        [Util extractVideoInfoFromContextNode:node
                                                    completion:^(NSString *videoId, NSString *videoTitle,
                                                                 NSString *ownerName) {
                                                        NSLog(@"[YGonerino] Block video: extraction completion "
                                                              @"fired with videoId=%@ title=%@",
                                                              videoId ?: @"(nil)", videoTitle ?: @"(nil)");
                                                        if (videoId.length) {
                                                            [[VideoManager sharedInstance] addBlockedVideo:videoId
                                                                                                     title:videoTitle
                                                                                                   channel:ownerName];
                                                            NSLog(@"[YGonerino] Block video: added \"%@\" (%@) to "
                                                                  @"VideoManager",
                                                                  videoTitle ?: @"(no title)", videoId);
                                                            UIViewController *viewController =
                                                                (UIViewController *)strongSelf;
                                                            [[%c(YTToastResponderEvent)
                                                                eventWithMessage:
                                                                    [NSString stringWithFormat:@"Blocked video: %@",
                                                                                               videoTitle ?: videoId]
                                                                  firstResponder:viewController] send];
                                                            if ([strongSelf respondsToSelector:@selector(dismiss)]) {
                                                                [strongSelf dismiss];
                                                            }
                                                        } else {
                                                            NSLog(@"[YGonerino] Block video failed: no video id "
                                                                  @"extracted");
                                                        }
                                                    }];
                    } @catch (NSException *e) {
                        NSLog(@"[YGonerino] Exception in block action: %@", e);
                    }
                }];

    objc_setAssociatedObject(self, blockActionKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [self addAction:blockChannelAction];
    [self addAction:blockVideoAction];
}

%new
- (UIViewController *)findViewControllerForView:(UIView *)view {
    UIResponder *responder = view;
    while (responder) {
        if ([responder isKindOfClass:[UIViewController class]]) {
            return (UIViewController *)responder;
        }
        responder = [responder nextResponder];
    }
    return nil;
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

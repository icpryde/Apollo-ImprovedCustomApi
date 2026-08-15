// ApolloMediaViewerInfoCard.xm
//
// Two fixes for the fullscreen media viewer's bottom furniture.
//
// 1. ORDER. Apollo stacks the video's playback controls ABOVE the post's info
//    card (title + subreddit/author caption):
//
//        ┌──────────────────────────┐        ┌──────────────────────────┐
//        │          video           │        │          video           │
//        │  ⏸ ⏪ ⏩  0:06 ──── 0:29  │   →    │  Sporting CP 2-0 …       │
//        │  Sporting CP 2-0 …       │        │  u/name · r/soccer       │
//        │  u/name · r/soccer       │        │  ⏸ ⏪ ⏩  0:06 ──── 0:29  │
//        └──────────────────────────┘        └──────────────────────────┘
//
//    Reading order and muscle memory both want the transport controls last, at
//    the bottom edge, with the descriptive text above them — every other video
//    player on the platform puts the scrubber closest to the thumb. We swap the
//    two after Apollo has laid them out, preserving each view's size and the gap
//    between them, so the change is orientation-agnostic (Apollo transform-
//    rotates this screen for landscape rather than relaying it out).
//
// 2. DISMISSAL. The info card is often the least interesting thing on screen —
//    you already know what you tapped. A small close button on the card hides
//    it, and because "I don't want this" is rarely a one-video opinion, the
//    dismissal is remembered: it writes the "Video Info Card" switch in
//    Settings → Media → Playback (default on), which is also how you get it
//    back.
//
// Both are pure post-layout geometry on views Apollo already owns
// (`videoControlsView`, `titleCaptionWrapperScrollView`) — no reparenting, no
// new constraints, and nothing to unwind if either ivar disappears in a future
// binary, in which case this module simply does nothing.

#import "ApolloCommon.h"
#import "ApolloState.h"            // sMediaViewerInfoCard
#import "UserDefaultConstants.h"

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

static const CGFloat kCloseButtonSize = 26.0;

static id MVIvar(id object, const char *name) {
    if (!object || !name) return nil;
    Class cls = object_getClass(object);
    while (cls) {
        Ivar ivar = class_getInstanceVariable(cls, name);
        if (ivar) {
            @try { return object_getIvar(object, ivar); }
            @catch (__unused NSException *e) { return nil; }
        }
        cls = class_getSuperclass(cls);
    }
    return nil;
}

#pragma mark - Close button

// Owns the tap target on the info card. A plain UIButton target would have to be
// the card itself (which we don't own) or the view controller (which would
// outlive the button), so a tiny retained handler object keeps the wiring local.
@interface ApolloMVInfoCardCloser : NSObject
@property (nonatomic, weak) UIView *infoCard;
- (void)closeTapped;
@end

@implementation ApolloMVInfoCardCloser

- (void)closeTapped {
    sMediaViewerInfoCard = NO;
    [[NSUserDefaults standardUserDefaults] setBool:NO forKey:UDKeyMediaViewerInfoCard];
    UIView *card = self.infoCard;
    ApolloLog(@"[MediaViewerInfoCard] dismissed by user - info card now off");
    [UIView animateWithDuration:0.2
                     animations:^{ card.alpha = 0.0; }
                     completion:^(__unused BOOL finished) { card.hidden = YES; }];
}

@end

static char kInfoCardCloserKey;
static char kInfoCardCloseButtonKey;

// Add the close affordance once per info card. Kept inside the card so it rides
// along with every frame change Apollo makes to it.
static void InstallCloseButton(UIView *infoCard) {
    if (!infoCard) return;
    UIButton *existing = objc_getAssociatedObject(infoCard, &kInfoCardCloseButtonKey);
    if (existing && existing.superview == infoCard) return;

    ApolloMVInfoCardCloser *closer = [[ApolloMVInfoCardCloser alloc] init];
    closer.infoCard = infoCard;

    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    UIImageSymbolConfiguration *config =
        [UIImageSymbolConfiguration configurationWithPointSize:13.0 weight:UIImageSymbolWeightBold];
    [button setImage:[UIImage systemImageNamed:@"xmark.circle.fill" withConfiguration:config]
            forState:UIControlStateNormal];
    button.tintColor = [UIColor colorWithWhite:1.0 alpha:0.75];
    button.accessibilityLabel = @"Hide info";
    [button addTarget:closer action:@selector(closeTapped) forControlEvents:UIControlEventTouchUpInside];

    [infoCard addSubview:button];
    // The handler must outlive this function; the button holds no strong ref to
    // its target, so the card does.
    objc_setAssociatedObject(infoCard, &kInfoCardCloserKey, closer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(infoCard, &kInfoCardCloseButtonKey, button, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

#pragma mark - Layout

// Put the transport controls below the info card, keeping both sizes and the
// spacing Apollo chose. Runs after every layout pass and is idempotent: once
// the controls sit lower than the card there is nothing left to swap.
static void ReorderBottomFurniture(UIViewController *viewer) {
    UIView *controls = MVIvar(viewer, "videoControlsView");
    UIView *infoCard = MVIvar(viewer, "titleCaptionWrapperScrollView");
    if (![controls isKindOfClass:[UIView class]] || ![infoCard isKindOfClass:[UIView class]]) return;

    // Images have no transport controls; nothing to reorder.
    if (controls.hidden || CGRectIsEmpty(controls.frame)) return;

    if (!sMediaViewerInfoCard) {
        if (!infoCard.hidden) {
            infoCard.hidden = YES;
            ApolloLog(@"[MediaViewerInfoCard] info card hidden (setting off)");
        }
        return;   // card is gone, so the controls keep Apollo's own position
    }

    if (infoCard.hidden) { infoCard.hidden = NO; infoCard.alpha = 1.0; }
    InstallCloseButton(infoCard);

    // Keep the close button pinned to the card's trailing top corner. The card
    // is a scroll view, so position against its bounds origin (it scrolls when
    // a long caption overflows) rather than its frame.
    UIButton *closeButton = objc_getAssociatedObject(infoCard, &kInfoCardCloseButtonKey);
    if (closeButton) {
        [infoCard bringSubviewToFront:closeButton];
        closeButton.frame = CGRectMake(CGRectGetWidth(infoCard.bounds) - kCloseButtonSize - 4.0,
                                       infoCard.bounds.origin.y + 4.0,
                                       kCloseButtonSize, kCloseButtonSize);
    }

    CGRect controlsFrame = controls.frame;
    CGRect infoFrame = infoCard.frame;
    if (CGRectIsEmpty(infoFrame)) return;
    if (CGRectGetMinY(controlsFrame) >= CGRectGetMinY(infoFrame)) return;   // already swapped

    // Preserve the gap Apollo left between the two so the spacing still looks
    // like the rest of the screen.
    CGFloat gap = CGRectGetMinY(infoFrame) - CGRectGetMaxY(controlsFrame);
    CGFloat top = CGRectGetMinY(controlsFrame);

    CGRect newInfoFrame = infoFrame;
    newInfoFrame.origin.y = top;
    CGRect newControlsFrame = controlsFrame;
    newControlsFrame.origin.y = CGRectGetMaxY(newInfoFrame) + gap;

    infoCard.frame = newInfoFrame;
    controls.frame = newControlsFrame;
}

%hook MediaViewerController

// Apollo positions both views in its own -viewDidLayoutSubviews; reorder after
// it, never during a UIView -layoutSubviews (which would risk a rotation loop).
- (void)viewDidLayoutSubviews {
    %orig;
    ReorderBottomFurniture((UIViewController *)self);
}

%end

%ctor {
    Class mediaViewerClass = objc_getClass("_TtC6Apollo21MediaViewerController");
    if (!mediaViewerClass) {
        ApolloLog(@"[MediaViewerInfoCard] ctor: MediaViewerController missing - module inactive");
        return;
    }
    %init(MediaViewerController = mediaViewerClass);
    ApolloLog(@"[MediaViewerInfoCard] module loaded (controls below info card, card dismissible)");
}

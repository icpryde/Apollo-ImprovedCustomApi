// ApolloSearchInPlace.xm
//
// Feed / subreddit search-bar behavior under iOS 26 Liquid Glass. One cohesive subsystem (the parts
// share %hook methods, so they live together):
//   - Nav-bar hide: when the search field focuses, fully translate the nav bar off-screen (default).
//   - Native glass "X" cancel button: slides in and out alongside Apollo's existing search lifecycle.
//   - Search-results offset: pin the feed inset/offset to a stable rest so results don't jump.
//   - "Keep Search Bar In Place" mode (sKeepSearchBarInPlace, Settings > Apollo Reborn > General):
//     keep the nav bar + field where they rest and fill the feed with results below.
//
// The search-results offset stabilizer runs regardless of Liquid Glass (the jump exists on stock Apollo
// too, including subreddit views with headers); the nav-bar hide, round-X cancel and in-place mode are
// Liquid Glass only. ApolloObjectIvar is duplicated from ApolloLiquidGlass.xm (which has its own
// non-search caller) so this file is self-contained.

#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>

#import "ApolloCommon.h"
#import "ApolloState.h"

// Forward ref for the setContentInset:/setContentOffset: hooks below (also declared in
// ApolloLiquidGlass.xm; a forward @interface in a second .xm is fine).
@interface ASTableView : UITableView
@end

// Runtime ivar reader; walks the superclass chain so inherited ivars resolve.
static id ApolloObjectIvar(id object, const char *name) {
    if (!object || !name) return nil;
    Class cls = object_getClass(object);
    while (cls) {
        Ivar ivar = class_getInstanceVariable(cls, name);
        if (ivar) {
            return object_getIvar(object, ivar);
        }
        cls = class_getSuperclass(cls);
    }
    return nil;
}

// MARK: - Native iOS 26 search glass
//
// Apollo's feed/comment search is custom UI (ApolloSearchToolbar + a UITextField), so merely linking
// Apollo against the iOS 26 SDK cannot give it UIKit's refreshed search appearance. Keep Apollo's actual
// field, delegate, indexing and result-reload path intact, and add only the system material underneath it.
// This is the same public UIKit recipe Apple documents for a custom control: UIVisualEffectView +
// UIGlassEffect. Runtime lookup keeps the shipped tweak's iOS 14 deployment floor clean.

static BOOL ApolloNativeSearchGlassAvailable(void) {
    return IsLiquidGlass() && NSClassFromString(@"UIGlassEffect") != Nil;
}

static UIVisualEffect *ApolloNewGlassEffect(BOOL interactive) {
    Class glassClass = NSClassFromString(@"UIGlassEffect");
    if (!glassClass) return nil;

    id effect = nil;
    SEL factory = NSSelectorFromString(@"effectWithStyle:");
    if ([glassClass respondsToSelector:factory]) {
        // UIGlassEffectStyleRegular == 0. Use the public factory dynamically so this source still builds
        // for the real device target's iOS 14 deployment floor.
        effect = ((id (*)(id, SEL, NSInteger))objc_msgSend)(glassClass, factory, 0);
    }
    if (!effect) effect = [[glassClass alloc] init];

    SEL setInteractive = NSSelectorFromString(@"setInteractive:");
    if ([effect respondsToSelector:setInteractive]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(effect, setInteractive, interactive);
    }
    return effect;
}

static void ApolloUseCapsuleCorners(UIView *view) {
    Class cornerClass = NSClassFromString(@"UICornerConfiguration");
    SEL capsuleSelector = NSSelectorFromString(@"capsuleConfiguration");
    SEL setter = NSSelectorFromString(@"setCornerConfiguration:");
    if (!view || !cornerClass || ![cornerClass respondsToSelector:capsuleSelector] ||
        ![view respondsToSelector:setter]) {
        return;
    }

    id capsule = ((id (*)(id, SEL))objc_msgSend)(cornerClass, capsuleSelector);
    ((void (*)(id, SEL, id))objc_msgSend)(view, setter, capsule);
}

// A real UIButtonConfiguration glass button. Returning id and using runtime selectors avoids importing
// iOS-15+/26-only button types into the iOS 14 device build while still letting UIKit own the pressed
// highlight, dynamic contrast and optical glass treatment on iOS 26.
static id ApolloGlassButtonConfiguration(UIImage *image) {
    Class configurationClass = NSClassFromString(@"UIButtonConfiguration");
    SEL glassSelector = NSSelectorFromString(@"glassButtonConfiguration");
    if (!configurationClass || ![configurationClass respondsToSelector:glassSelector]) return nil;

    id configuration = ((id (*)(id, SEL))objc_msgSend)(configurationClass, glassSelector);
    if (!configuration) return nil;
    [configuration setValue:image forKey:@"image"];
    [configuration setValue:[UIColor labelColor] forKey:@"baseForegroundColor"];
    [configuration setValue:@1 forKey:@"buttonSize"];  // UIButtonConfigurationSizeSmall
    [configuration setValue:@4 forKey:@"cornerStyle"]; // UIButtonConfigurationCornerStyleCapsule
    return configuration;
}

static const void *kSearchFieldGlassKey = &kSearchFieldGlassKey;
static const void *kSearchFieldGlassLoggedKey = &kSearchFieldGlassLoggedKey;

// MARK: - "Find in Comments" bar (in-thread search) — shared glass group
//
// The in-thread comments search (searchBarShouldStickToKeyboard == YES) is excluded from the feed-search
// handling above, but its docked find bar is transparent, so the comments behind it bleed through the
// Done button / chevrons. Detect it (its toolbar belongs to a CommentsViewController) and give the whole
// field/checkmark/chevron group one Liquid Glass backing while docked. A single shared surface follows
// UIKit's toolbar grouping model and avoids stacking a second glass field on top of glass.

// The CommentsViewController that owns a comment find-in-page bar (walk the responder chain), else nil.
static UIViewController *commentsVCForView(UIView *v) {
    UIResponder *r = [v nextResponder];
    int guard = 0;
    while (r && guard++ < 40) {
        if ([r isKindOfClass:[UIViewController class]]) {
            const char *cls = object_getClassName(r);
            if (cls && strstr(cls, "Comments")) return (UIViewController *)r;
        }
        r = [r nextResponder];
    }
    return nil;
}

static BOOL isCommentToolbar(UIView *v) {
    return commentsVCForView(v) != nil;
}

// The toolbar is "docked" (the active find-in-page layout) when it's been reparented off the scroll view.
static BOOL toolbarDocked(UIView *toolbar) {
    UIView *sup = [toolbar superview];
    return sup != nil && ![sup isKindOfClass:[UIScrollView class]];
}

static const CGFloat kCommentGlassInsetX = 3.0;
static const CGFloat kCommentGlassInsetY = 4.0;
static const void *kCommentGlassKey = &kCommentGlassKey;
// Retain the preceding blur fallback exactly for ordinary/non-native builds. The real glass path below
// replaces it only when UIGlassEffect is available; it must not change the existing iOS 14–25 presentation.
static UIBlurEffectStyle const kCommentFallbackBlurStyle = UIBlurEffectStyleSystemThinMaterial;
static const CGFloat kCommentFallbackBlurInsetX = 3.0;
static const CGFloat kCommentFallbackBlurInsetY = 4.0;
static const CGFloat kCommentFallbackBlurCorner = 14.0;
static const CGFloat kCommentFallbackDoneNudgeX = 14.0;
static const CGFloat kCommentFallbackDoneNudgeY = -6.0;
static const void *kCommentFallbackBlurKey = &kCommentFallbackBlurKey;
static const void *kCommentDoneStyledKey = &kCommentDoneStyledKey;
static const void *kCommentDoneOriginalTitleKey = &kCommentDoneOriginalTitleKey;
static const void *kCommentDoneOriginalImageKey = &kCommentDoneOriginalImageKey;
static const void *kCommentDoneOriginalAccessibilityLabelKey = &kCommentDoneOriginalAccessibilityLabelKey;
static const void *kCommentControlOriginalTransformKey = &kCommentControlOriginalTransformKey;
static const void *kCommentControlOriginalTintKey = &kCommentControlOriginalTintKey;
static const void *kCommentToolbarLoggedKey = &kCommentToolbarLoggedKey;

static UIImage *ApolloCommentDoneImage(void) {
    UIImageSymbolConfiguration *symbol =
        [UIImageSymbolConfiguration configurationWithPointSize:14.0 weight:UIImageSymbolWeightSemibold];
    return [[UIImage systemImageNamed:@"checkmark" withConfiguration:symbol]
            imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

// The prior non-glass fallback: keep the old frosted bar and Done-button nudge unchanged when native
// Liquid Glass is unavailable. This is deliberately separate from the iOS 26 styling below.
static void nudgeCommentFallbackDoneButton(UIView *bar) {
    UIButton *done = nil;
    for (UIView *sv in bar.subviews) {
        if ([sv isKindOfClass:[UIButton class]] &&
            (!done || CGRectGetMinX(sv.frame) < CGRectGetMinX(done.frame))) {
            done = (UIButton *)sv;
        }
    }
    if (!done) return;
    CGAffineTransform transform =
        CGAffineTransformMakeTranslation(kCommentFallbackDoneNudgeX, kCommentFallbackDoneNudgeY);
    if (!CGAffineTransformEqualToTransform(done.transform, transform)) done.transform = transform;
}

static void ensureCommentFallbackBlurBacking(UIView *bar) {
    UIVisualEffectView *blur = objc_getAssociatedObject(bar, kCommentFallbackBlurKey);
    if (!blur) {
        blur = [[UIVisualEffectView alloc]
            initWithEffect:[UIBlurEffect effectWithStyle:kCommentFallbackBlurStyle]];
        blur.userInteractionEnabled = NO;
        blur.clipsToBounds = YES;
        blur.layer.cornerCurve = kCACornerCurveContinuous;
        objc_setAssociatedObject(bar, kCommentFallbackBlurKey, blur, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (blur.superview != bar) [bar insertSubview:blur atIndex:0];
    else if (bar.subviews.firstObject != blur) [bar sendSubviewToBack:blur];
    CGRect frame = CGRectInset(bar.bounds, kCommentFallbackBlurInsetX, kCommentFallbackBlurInsetY);
    blur.frame = frame;
    blur.layer.cornerRadius = MIN(kCommentFallbackBlurCorner, CGRectGetHeight(frame) / 2.0);
    if (bar.backgroundColor != nil) bar.backgroundColor = nil;
    bar.opaque = NO;
}

static void removeCommentFallbackBlurBacking(UIView *bar) {
    UIVisualEffectView *blur = objc_getAssociatedObject(bar, kCommentFallbackBlurKey);
    if (blur.superview) [blur removeFromSuperview];
    if (bar.backgroundColor != nil) bar.backgroundColor = nil;
}

// Apollo's text "Done" is baseline-aligned for its old toolbar and lands visibly low after the bar moves
// above the keyboard. Replace only its presentation with a centered checkmark; its existing target/action,
// frame and accessibility action remain Apollo-owned.
static void styleCommentToolbarControls(UIView *bar) {
    UIButton *done = nil;
    UIButton *leftmost = nil;
    for (UIView *sv in bar.subviews) {
        if (![sv isKindOfClass:[UIButton class]]) continue;
        UIButton *button = (UIButton *)sv;
        if (!leftmost || CGRectGetMinX(button.frame) < CGRectGetMinX(leftmost.frame)) leftmost = button;

        // Prefer the real semantic control. The zero-width pre-layout pass can make every button look
        // left-aligned, so coordinates alone are not enough to distinguish Done from the two find arrows.
        NSString *title = [button titleForState:UIControlStateNormal];
        NSString *accessibilityLabel = button.accessibilityLabel;
        if ((title.length && [title caseInsensitiveCompare:@"Done"] == NSOrderedSame) ||
            (accessibilityLabel.length && [accessibilityLabel caseInsensitiveCompare:@"Done"] == NSOrderedSame)) {
            done = button;
        }
    }
    done = done ?: leftmost;
    if (!done) return;

    if (![objc_getAssociatedObject(done, kCommentDoneStyledKey) boolValue]) {
        objc_setAssociatedObject(done, kCommentDoneOriginalTitleKey,
                                 [done titleForState:UIControlStateNormal] ?: [NSNull null],
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(done, kCommentDoneOriginalImageKey,
                                 [done imageForState:UIControlStateNormal] ?: [NSNull null],
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(done, kCommentDoneOriginalAccessibilityLabelKey,
                                 done.accessibilityLabel ?: [NSNull null],
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(done, kCommentDoneStyledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    // Apollo can repopulate the title while its keyboard-transition layout settles. Reassert the visual
    // representation every pass without touching its action or accessibility semantics.
    [done setTitle:nil forState:UIControlStateNormal];
    [done setImage:ApolloCommentDoneImage() forState:UIControlStateNormal];
    done.accessibilityLabel = @"Done";

    // UIKit bar buttons use labelColor by default under Liquid Glass. Match that adaptive contrast for the
    // checkmark and Apollo's existing up/down controls, without recoloring any content outside this toolbar.
    CGFloat targetCenterY = CGRectGetMidY(bar.bounds);
    for (UIView *sv in bar.subviews) {
        if (![sv isKindOfClass:[UIButton class]]) continue;
        UIButton *button = (UIButton *)sv;
        if (!objc_getAssociatedObject(button, kCommentControlOriginalTransformKey)) {
            objc_setAssociatedObject(button, kCommentControlOriginalTransformKey,
                                     [NSValue valueWithCGAffineTransform:button.transform],
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(button, kCommentControlOriginalTintKey,
                                     button.tintColor ?: [NSNull null],
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        button.tintColor = [UIColor labelColor];
        CGAffineTransform original =
            [objc_getAssociatedObject(button, kCommentControlOriginalTransformKey) CGAffineTransformValue];
        CGAffineTransform centered =
            CGAffineTransformTranslate(original, 0.0, targetCenterY - button.center.y);
        if (!CGAffineTransformEqualToTransform(button.transform, centered)) {
            button.transform = centered;
        }
    }
}

static void restoreCommentToolbarControls(UIView *bar) {
    for (UIView *sv in bar.subviews) {
        if (![sv isKindOfClass:[UIButton class]]) continue;
        UIButton *button = (UIButton *)sv;
        NSValue *originalTransform = objc_getAssociatedObject(button, kCommentControlOriginalTransformKey);
        if (originalTransform) button.transform = originalTransform.CGAffineTransformValue;
        id originalTint = objc_getAssociatedObject(button, kCommentControlOriginalTintKey);
        if (originalTint) button.tintColor = originalTint == [NSNull null] ? nil : originalTint;
        objc_setAssociatedObject(button, kCommentControlOriginalTransformKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(button, kCommentControlOriginalTintKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (![objc_getAssociatedObject(button, kCommentDoneStyledKey) boolValue]) continue;

        id originalTitle = objc_getAssociatedObject(button, kCommentDoneOriginalTitleKey);
        id originalImage = objc_getAssociatedObject(button, kCommentDoneOriginalImageKey);
        id originalAccessibilityLabel = objc_getAssociatedObject(button, kCommentDoneOriginalAccessibilityLabelKey);
        [button setTitle:(originalTitle == [NSNull null] ? nil : originalTitle)
               forState:UIControlStateNormal];
        [button setImage:(originalImage == [NSNull null] ? nil : originalImage)
               forState:UIControlStateNormal];
        button.accessibilityLabel = originalAccessibilityLabel == [NSNull null] ? nil : originalAccessibilityLabel;
        objc_setAssociatedObject(button, kCommentDoneStyledKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(button, kCommentDoneOriginalTitleKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(button, kCommentDoneOriginalImageKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(button, kCommentDoneOriginalAccessibilityLabelKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static void ensureCommentGlassBacking(UIView *bar) {
    removeCommentFallbackBlurBacking(bar);
    UIVisualEffectView *glass = objc_getAssociatedObject(bar, kCommentGlassKey);
    if (!glass) {
        UIVisualEffect *effect = ApolloNewGlassEffect(NO);
        if (!effect) return;
        glass = [[UIVisualEffectView alloc] initWithEffect:effect];
        glass.userInteractionEnabled = NO; // never intercept Done / Find / chevron taps
        glass.accessibilityElementsHidden = YES;
        glass.frame = CGRectInset(bar.bounds, kCommentGlassInsetX, kCommentGlassInsetY);
        glass.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        ApolloUseCapsuleCorners(glass);
        objc_setAssociatedObject(bar, kCommentGlassKey, glass, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (glass.superview != bar) [bar insertSubview:glass atIndex:0];
    else if (bar.subviews.firstObject != glass) [bar sendSubviewToBack:glass];
    if (bar.backgroundColor != nil) bar.backgroundColor = nil;
    bar.opaque = NO;
    styleCommentToolbarControls(bar);

    if (![objc_getAssociatedObject(bar, kCommentToolbarLoggedKey) boolValue]) {
        objc_setAssociatedObject(bar, kCommentToolbarLoggedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        NSMutableArray<NSString *> *parts = [NSMutableArray array];
        for (UIView *sv in bar.subviews) {
            [parts addObject:[NSString stringWithFormat:@"%@ %@",
                              NSStringFromClass(sv.class), NSStringFromCGRect(sv.frame)]];
        }
        ApolloLog(@"[SearchGlass] Docked comment toolbar %@; subviews=%@",
                  NSStringFromCGRect(bar.frame), [parts componentsJoinedByString:@", "]);
    }
}

static void removeCommentGlassBacking(UIView *bar) {
    UIVisualEffectView *glass = objc_getAssociatedObject(bar, kCommentGlassKey);
    if (glass.superview) [glass removeFromSuperview];
    restoreCommentToolbarControls(bar);
    if (bar.backgroundColor != nil) bar.backgroundColor = nil;
}

// Give each resting feed/thread field its own real glass capsule. Once Find in Comments docks, the field
// joins the shared toolbar glass above instead, so there are never overlapping Liquid Glass surfaces.
static void updateNativeSearchFieldGlass(UITextField *field) {
    if (!field) return;

    UIVisualEffectView *glass = objc_getAssociatedObject(field, kSearchFieldGlassKey);
    UIView *toolbar = field.superview;
    BOOL usesSharedCommentGlass =
        toolbar && isCommentToolbar(toolbar) && toolbarDocked(toolbar);

    if (!ApolloNativeSearchGlassAvailable() || !toolbar || usesSharedCommentGlass) {
        if (glass.superview) [glass removeFromSuperview];
        return;
    }

    if (!glass) {
        UIVisualEffect *effect = ApolloNewGlassEffect(NO);
        if (!effect) return;
        glass = [[UIVisualEffectView alloc] initWithEffect:effect];
        glass.userInteractionEnabled = NO;
        glass.accessibilityElementsHidden = YES;
        ApolloUseCapsuleCorners(glass);
        objc_setAssociatedObject(field, kSearchFieldGlassKey, glass, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    if (glass.superview != toolbar) [toolbar insertSubview:glass belowSubview:field];
    else if ([toolbar.subviews indexOfObject:glass] > [toolbar.subviews indexOfObject:field]) {
        [toolbar insertSubview:glass belowSubview:field];
    }
    glass.frame = field.frame;
    field.opaque = NO;

    if (![objc_getAssociatedObject(field, kSearchFieldGlassLoggedKey) boolValue]) {
        objc_setAssociatedObject(field, kSearchFieldGlassLoggedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        ApolloLog(@"[SearchGlass] Installed native field glass in %@ (%@)",
                  NSStringFromClass(toolbar.class), NSStringFromCGRect(field.frame));
    }
}

// MARK: - Nav-bar hide
//
// Apollo's feed search bar is a custom ApolloSearchToolbar overlaid on the Texture ASTableView, not a
// UISearchController. When the field begins editing, the host (_TtC6Apollo21ASTableViewController)
// translates the whole UINavigationBar up by a hardcoded -88pt and fades it to alpha 0 (sub_1002c2b60,
// inside a 0.3s animation). The taller iOS 26 nav bar isn't fully cleared by -88, so the title/buttons
// stay partly visible. We capture the bar on focus and rewrite the hide translate to the bar's true
// off-screen extent (safe-area top + height). The comments in-thread search
// (searchBarShouldStickToKeyboard == YES) uses a different, keyboard-anchored layout and is excluded.

static __weak UINavigationBar *sFeedSearchNavBar = nil;

// Apollo's "Cancel" dismiss button, restyled as a round "X". Captured on focus; __weak so a torn-down
// view auto-nils.
static __weak UIButton *sFeedSearchCancel = nil;
// Armed on focus, consumed once: gives the round-X a clean slide-in.
static BOOL sCancelNeedsIntro = NO;
// The field starts each focus pass at Apollo's full-width resting frame. Capture that frame before the
// takeover starts, then explicitly animate the field + its glass backing to the in-place width alongside
// the X. Without this, our early in-place clamp lands in a separate layout transaction and reads as a
// one-frame flicker even though the final geometry is correct.
static BOOL sFeedSearchFieldNeedsIntro = NO;
static CGRect sFeedSearchFieldIntroStartFrame = {{0, 0}, {0, 0}};
static BOOL sFeedSearchFieldIntroStartFrameIsValid = NO;

// MARK: - Search-results offset
//
// During a feed search Apollo's contentInset.top and contentOffset on the feed table churn (the
// present/reframe path re-parks the offset, and under Liquid Glass the nav-bar transform also makes the
// VC safe-area flicker), pushing the "Search all posts for X" prompt up under the status bar and jumping
// on each keystroke. Instead of correcting after the fact, we intercept the ASTableView geometry setters
// and pin them to a stable anchor (the docked toolbar's window-space bottom). The feed uses
// contentInsetAdjustmentBehavior = .never, so adjustedContentInset.top == contentInset.top. Not gated on
// Liquid Glass — the jump happens on stock Apollo too.
static __weak UIScrollView *sFeedSearchTable     = nil;  // captured tableNode.view (ASTableView)
static __weak UIView        *sFeedSearchToolbar   = nil;  // captured upperToolbar (the rest anchor)
static BOOL sFeedSearchActive         = NO;  // YES while a feed (!stick) search is editing
static BOOL sFeedSearchDismissing     = NO;  // YES briefly during dismiss (relax clamp to a downward pull)
// YES after an in-place dismiss has finished. Apollo still repositions its upperToolbar during the
// subsequent normal-feed settle, so keep the captured toolbar at its true resting window coordinate until
// the user deliberately scrolls the feed (then normal scrolling behavior resumes).
static BOOL sFeedSearchToolbarRestPinned = NO;
static BOOL sFeedSearchScrolledByUser = NO;  // armed once the user drags → stop clamping so they can browse
static NSUInteger sFeedSearchDismissGen = 0; // bumps each dismiss / focus / disappear; the release timer ignores stale gens
static __weak UIView *sFeedSearchField    = nil; // captured searchTextField
static CGFloat sFeedSearchStandaloneRestInset = 0.0; // feed's resting top inset (Headers OFF), captured while NOT searching
// Exact pre-focus toolbar origin in window coordinates. Keeping this in window space is essential: the
// subreddit table can change its content offset while Community Highlights re-attaches on dismiss, so a
// raw origin in the toolbar's scrolling superview would later land hundreds of points too low.
static CGFloat sFeedSearchToolbarRestWindowY = 0.0;
static BOOL sFeedSearchToolbarRestWindowYIsValid = NO;

// Stable content-top rest for the feed search table: the docked toolbar's window-space bottom (where the
// first results row sits). Falls back to window safe-area top + 45 until the toolbar is docked.
static CGFloat ApolloFeedSearchRestTop(void) {
    UIView *tb = sFeedSearchToolbar;
    if (tb && tb.window) {
        CGFloat bottom = CGRectGetMaxY([tb convertRect:tb.bounds toView:nil]); // window space
        if (bottom > 1.0) return bottom;
    }
    UIWindow *w = sFeedSearchNavBar.window ?: sFeedSearchTable.window ?: tb.window;
    CGFloat safeTop = w ? w.safeAreaInsets.top : 59.0; // 59 ≈ Dynamic-Island top; transient pre-dock only
    return safeTop + 45.0;
}

// MARK: - "Keep Search Bar In Place" rest target
//
// In-place mode keeps the nav bar + field where they rest, so results start at the captured toolbar's
// original window-space bottom. Falls back to the navigation-bar calculation until it is known.
static CGFloat ApolloFeedSearchInPlaceRestTop(void) {
    if (sFeedSearchToolbarRestWindowYIsValid) return sFeedSearchToolbarRestWindowY + 45.0;
    UINavigationBar *nb = sFeedSearchNavBar;
    if (nb && nb.window) {
        CGFloat navBottom = CGRectGetMaxY([nb convertRect:nb.bounds toView:nil]); // window space
        if (navBottom > 1.0) return navBottom + 45.0; // 45 == Apollo's toolbarHeight ivar (portrait)
    }
    return ApolloFeedSearchRestTop();
}

// The active rest for whichever mode is on; the inset floor and the offset clamp both use it. In-place
// mode is Liquid Glass only, so non-LG (and LG nav-hide) always use the docked-toolbar rest.
static CGFloat ApolloFeedSearchActiveRestTop(void) {
    return (sKeepSearchBarInPlace && IsLiquidGlass()) ? ApolloFeedSearchInPlaceRestTop()
                                                      : ApolloFeedSearchRestTop();
}

// The current feed query text, or nil/empty when not searching.
static NSString *ApolloFeedSearchQueryText(void) {
    UIView *f = sFeedSearchField;
    return [f isKindOfClass:[UITextField class]] ? [(UITextField *)f text] : nil;
}

// MARK: - "Search on top" — surface results above the subreddit chrome
//
// Apollo pins the feed so its top (the tableHeaderView: banner + description + Community Highlights) sits
// just under the docked field, leaving the "Search r/X for query" row + matching posts buried ~400pt down.
// When there's a query we instead want the feed scrolled so that header is off the top and the first
// results row sits directly under the field. Returns the desired content-offset.y: rest when empty / no
// header (e.g. Home), or (headerHeight - insetTop) when there's a query.
//
// Scoped to "Keep Search Bar In Place" mode: with the toggle off, the feed keeps its original
// rest-pinned behavior (results below the chrome), so that mode is unchanged from stock Apollo.
// The surfacing only engages when the feed has a FULL subreddit header — Reborn's
// ApolloSubredditHeaderWrapperView (Subreddit Headers ON: banner + description + Community Highlights,
// ~400pt of chrome that genuinely buries the search row). When that's off, the header is either nothing
// (Home) or just the small Community Highlights carousel, which the highlights module rebuilds + re-nests
// across reloads; surfacing it both isn't worth it (little chrome to clear) and mis-positions / strands
// that rebuilt header. So those cases keep stock behavior (results below the chrome).
static BOOL ApolloFeedSearchManagedHeader(UIScrollView *sv) {
    UIView *hdr = [sv respondsToSelector:@selector(tableHeaderView)] ? [(UITableView *)sv tableHeaderView] : nil;
    return hdr && [hdr isKindOfClass:objc_getClass("ApolloSubredditHeaderWrapperView")];
}

static CGFloat ApolloFeedSearchDesiredOffsetY(UIScrollView *sv) {
    CGFloat rest = -ApolloFeedSearchActiveRestTop();
    if (!sKeepSearchBarInPlace) return rest;          // OFF mode: original, no surfacing
    if (!ApolloFeedSearchManagedHeader(sv)) return rest; // no full header to clear → stock
    if (ApolloFeedSearchQueryText().length == 0) return rest;
    UIView *hdr = [(UITableView *)sv tableHeaderView];
    CGFloat H = CGRectGetHeight(hdr.frame);
    if (H <= 1.0) return rest;
    CGFloat surfaced = H - sv.contentInset.top; // first results row just under the docked field
    return surfaced > rest ? surfaced : rest;
}

// When the chrome is surfaced off the top, its tail still sits in the band behind the translucent
// field/nav and bleeds through the Liquid Glass. Hide the header view while surfaced so the glass blurs
// the plain feed background instead of the scrolled-up Community Highlights; show it again otherwise.
// Alpha-only (no layout/offset change). Only ever runs for the managed wrapper (the only thing that
// surfaces); its setAlpha: is hooked below so the wrapper's per-pass anti-flash can't re-show it.
static void ApolloFeedSearchSetHeaderHidden(UIScrollView *sv, BOOL hidden) {
    if (!ApolloFeedSearchManagedHeader(sv)) return;
    UIView *hdr = [(UITableView *)sv tableHeaderView];
    CGFloat a = hidden ? 0.0 : 1.0;
    if (hdr.alpha != a) hdr.alpha = a;
}

// Force the captured feed's header back to visible (teardown / leaving — belt-and-suspenders against a
// header left transparent).
static void ApolloFeedSearchRestoreHeader(void) {
    if (sFeedSearchTable) ApolloFeedSearchSetHeaderHidden(sFeedSearchTable, NO);
}

// The idle in-place anchor is intentionally short-lived from the user's perspective: it only owns the
// toolbar while the feed is resting after search. The first real drag/deceleration hands it fully back to
// Apollo, preserving the original behavior once someone starts browsing the feed.
static void ApolloFeedSearchReleaseRestPinForUserScroll(UIScrollView *scrollView) {
    if (!sFeedSearchToolbarRestPinned || scrollView != sFeedSearchTable ||
        (!scrollView.isDragging && !scrollView.isDecelerating)) {
        return;
    }
    sFeedSearchToolbarRestPinned = NO;
    sFeedSearchScrolledByUser = YES;
    sFeedSearchToolbar = nil;
    sFeedSearchNavBar = nil;
}

// An ApolloSearchToolbar lives in the feed's scrolling coordinate space. Updating the table's
// contentOffset therefore moves it on screen *without* sending the toolbar another setFrame:. This is
// normally fine because Apollo lets the search bar ride the feed, but it bypasses the in-place pin while
// Community Highlights re-attaches its carousel and repeatedly scrolls back to the top on dismissal.
// Re-submit its current frame after a scroll/bounds change: the toolbar hook below converts the recorded
// window-space resting point into the new content coordinates. A guard keeps the corrective write from
// re-entering a layout-driven scroll update.
static BOOL sFeedSearchReassertingToolbarPin = NO;
static void ApolloFeedSearchReassertToolbarPin(void) {
    if (sFeedSearchReassertingToolbarPin || !IsLiquidGlass() || !sKeepSearchBarInPlace ||
        (!sFeedSearchActive && !sFeedSearchDismissing && !sFeedSearchToolbarRestPinned) ||
        sFeedSearchScrolledByUser) {
        return;
    }
    UIView *toolbar = sFeedSearchToolbar;
    if (!toolbar || !toolbar.superview || !toolbar.window) return;

    sFeedSearchReassertingToolbarPin = YES;
    [UIView performWithoutAnimation:^{
        // Routes through -[ApolloSearchToolbar setFrame:], which applies the in-place window anchor.
        [toolbar setFrame:toolbar.frame];
    }];
    sFeedSearchReassertingToolbarPin = NO;
}

// YES while the feed is holding the surfaced position (query non-empty, chrome scrolled off, not being
// dismissed or user-browsed). The single source of truth for "should the header be hidden right now".
static BOOL ApolloFeedSearchIsSurfaced(UIScrollView *sv) {
    if (!sv) return NO;
    CGFloat rest = -ApolloFeedSearchActiveRestTop();
    return sFeedSearchActive && !sFeedSearchDismissing && !sFeedSearchScrolledByUser &&
           ApolloFeedSearchQueryText().length > 0 &&
           (ApolloFeedSearchDesiredOffsetY(sv) > rest + 1.0);
}

// Exposed (non-static) to the Community Highlights module: YES while THIS feed table is mid-search with a
// non-empty query — i.e. results are showing and the standalone carousel should stay scrolled off, NOT be
// re-attached + scrolled back to the top. Excludes the dismiss window (dismissing == YES) and an empty
// query, which are exactly when the carousel SHOULD be restored. Lets the Highlights re-attach skip its
// scroll-to-top during active typing/scrolling so it can never yank the results.
BOOL ApolloFeedSearchIsActiveQuery(UIScrollView *tv) {
    return sFeedSearchActive && !sFeedSearchDismissing &&
           (UIScrollView *)tv == sFeedSearchTable &&
           ApolloFeedSearchQueryText().length > 0;
}

// MARK: - Round "X" cancel button
//
// Replaces the "Cancel" text with a neutral-gray xmark in a circle matching the search-field pill. In
// OFF mode Apollo sizes/positions it (see the sizeThatFits override below); in in-place mode we place it
// ourselves. The slide-in / slide-out / fade run as layer animations keyed "sipX*".

// These match Apollo's built-in Search tab on iOS 26: a 44pt glass control, 16pt from the trailing
// edge, with a 10pt gap to the field. Keeping that geometry exact makes the feed/subreddit transition
// land at the same endpoints as the native navigation search rather than looking like a smaller add-on.
static const CGFloat kXSize        = 44.0;
static const CGFloat kXRightMargin = 16.0;
static const CGFloat kXFieldGap    = 10.0;

// Tag (associated object) marking the feed dismissSearchBarButton so the sizeThatFits:/
// intrinsicContentSize overrides below apply to only that one button. In OFF mode Apollo reads the
// button's sizeThatFits every layout pass to size the field (sub_1002be508), place the field
// (sub_1002be378) and frame the button — returning a fixed square lets Apollo do all the geometry with
// no frame writes from us. In-place mode places the button itself instead.
static const void *kRoundXKey = &kRoundXKey;
static const void *kNativeRoundXConfiguredKey = &kNativeRoundXConfiguredKey;

// The toolbar's resting (pre-dock) height, captured on focus. OFF mode fires the round-X slide-in only
// once the toolbar grows past this (i.e. has docked), not on the resting pass.
static CGFloat sRestToolbarHeight = 45.0;

static void tagRoundXButton(UIButton *btn) {
    if ([btn isKindOfClass:[UIButton class]] && !objc_getAssociatedObject(btn, kRoundXKey)) {
        objc_setAssociatedObject(btn, kRoundXKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

// Cached template xmark. Native glass chooses adaptive foreground contrast; the old-runtime fallback
// below applies its own neutral gray explicitly.
static UIImage *roundXImage(void) {
    static UIImage *img = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        UIImageSymbolConfiguration *cfg =
            [UIImageSymbolConfiguration configurationWithPointSize:12.0 weight:UIImageSymbolWeightBold];
        img = [[UIImage systemImageNamed:@"xmark" withConfiguration:cfg]
               imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    });
    return img;
}

// Resting center of the X circle in toolbar coords: pinned to the right edge, vertically centered on the
// field so it lines up with the search pill.
static CGPoint xRestCenter(UIView *toolbar, UIView *field) {
    CGFloat cx = CGRectGetWidth(toolbar.bounds) - kXRightMargin - kXSize / 2.0;
    CGFloat cy = field ? CGRectGetMidY(field.frame) : CGRectGetMidY(toolbar.bounds);
    return CGPointMake(cx, cy);
}

// Off-right translation that parks the circle past the toolbar's right edge, from the button's current
// model frame (caller ensures the transform is identity first).
static CGFloat xParkDistance(UIView *toolbar, UIView *cancel) {
    return CGRectGetWidth(toolbar.bounds) - CGRectGetMinX(cancel.frame) + 8.0;
}

// The field's max right edge while searching, leaving kXFieldGap before the circle.
static CGFloat fieldMaxRight(UIView *toolbar) {
    return CGRectGetWidth(toolbar.bounds) - kXRightMargin - kXSize - kXFieldGap;
}

// UIKit's focus animation owns the surrounding feed layout, but the in-place override deliberately
// changes the field's final width. Animate both the text field and the effect view from the same captured
// resting frame so the glass edge, placeholder, and X all tell one continuous story.
static void animateSearchLayerFrame(CALayer *layer, CGRect startFrame) {
    if (!layer) return;

    CGRect finishBounds = layer.bounds;
    CGPoint finishPosition = layer.position;
    CGRect startBounds = CGRectMake(CGRectGetMinX(finishBounds), CGRectGetMinY(finishBounds),
                                    CGRectGetWidth(startFrame), CGRectGetHeight(startFrame));
    CGPoint startPosition = CGPointMake(CGRectGetMidX(startFrame), CGRectGetMidY(startFrame));
    if (CGSizeEqualToSize(startBounds.size, finishBounds.size) &&
        CGPointEqualToPoint(startPosition, finishPosition)) {
        return;
    }

    CABasicAnimation *position = [CABasicAnimation animationWithKeyPath:@"position"];
    position.fromValue = [NSValue valueWithCGPoint:startPosition];
    position.toValue = [NSValue valueWithCGPoint:finishPosition];

    CABasicAnimation *bounds = [CABasicAnimation animationWithKeyPath:@"bounds"];
    bounds.fromValue = [NSValue valueWithCGRect:startBounds];
    bounds.toValue = [NSValue valueWithCGRect:finishBounds];

    CAAnimationGroup *intro = [CAAnimationGroup animation];
    intro.animations = @[position, bounds];
    intro.duration = 0.36;
    intro.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
    [layer addAnimation:intro forKey:@"sipFieldIn"];
}

static void animateFeedSearchFieldIntroIfNeeded(UITextField *field) {
    if (!sFeedSearchFieldNeedsIntro || !sFeedSearchFieldIntroStartFrameIsValid ||
        field != sFeedSearchField) {
        return;
    }

    CGRect start = sFeedSearchFieldIntroStartFrame;
    CGRect finish = field.frame;
    // Wait until Apollo has actually given the field its contracted model frame. A later layout pass is
    // harmless; this guard prevents a rotation/reload from ever animating an unrelated size change.
    if (CGRectGetWidth(finish) < 1.0 || CGRectGetWidth(start) <= CGRectGetWidth(finish) + 1.0) {
        return;
    }

    sFeedSearchFieldNeedsIntro = NO;
    sFeedSearchFieldIntroStartFrameIsValid = NO;
    [field.layer removeAnimationForKey:@"sipFieldIn"];
    animateSearchLayerFrame(field.layer, start);

    UIVisualEffectView *glass = objc_getAssociatedObject(field, kSearchFieldGlassKey);
    if (glass.superview && CGRectEqualToRect(glass.frame, finish)) {
        [glass.layer removeAnimationForKey:@"sipFieldIn"];
        animateSearchLayerFrame(glass.layer, start);
    }
}

// Style the round-X each layout pass: clear the title, show the glyph in a circular fill, and (in-place
// only) force its size/center. UIKit's native material reveal is left intact while focusing; only a
// teardown gets its conflicting animation stripped.
static void styleCancelAsRoundX(UIButton *btn, UIView *toolbar, UIView *field) {
    // Appearance (idempotent): use UIKit's actual iOS 26 glass button configuration whenever available.
    // The fallback retains the previous hand-drawn circle only for a linked-glass build on a runtime that
    // somehow lacks UIGlassEffect/UIButtonConfiguration.
    BOOL usesNativeGlass = ApolloNativeSearchGlassAvailable();
    id glassConfiguration = nil;
    if (usesNativeGlass &&
        ![objc_getAssociatedObject(btn, kNativeRoundXConfiguredKey) boolValue]) {
        glassConfiguration = ApolloGlassButtonConfiguration(roundXImage());
    }
    if (glassConfiguration) {
        [btn setTitle:@"" forState:UIControlStateNormal];
        ((void (*)(id, SEL, id))objc_msgSend)(btn, NSSelectorFromString(@"setConfiguration:"),
                                              glassConfiguration);
        objc_setAssociatedObject(btn, kNativeRoundXConfiguredKey, @YES,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (usesNativeGlass) {
        btn.backgroundColor = nil;
        btn.tintColor = [UIColor labelColor];
        btn.layer.cornerRadius = 0.0;
        btn.layer.masksToBounds = NO;
    } else if (btn.currentImage == nil || btn.currentTitle.length > 0) {
        [btn setTitle:@"" forState:UIControlStateNormal];
        UIImage *fallbackImage = [roundXImage()
            imageWithTintColor:[UIColor colorWithWhite:0.62 alpha:1.0]
                 renderingMode:UIImageRenderingModeAlwaysOriginal];
        [btn setImage:fallbackImage forState:UIControlStateNormal];
        btn.backgroundColor = field.backgroundColor ?: [UIColor colorWithWhite:0.137 alpha:1.0];
        btn.layer.cornerRadius = kXSize / 2.0;
        btn.layer.masksToBounds = YES;
        btn.contentEdgeInsets = UIEdgeInsetsZero;
        btn.adjustsImageWhenHighlighted = NO;
    }
    // Apollo fades the cancel button to alpha 0 on teardown (sub_1002c3cf8). Keep it opaque while active,
    // but let an in-place dismiss fade it out (don't force it back up) so it actually goes away.
    if (btn.alpha < 1.0 && !(sKeepSearchBarInPlace && sFeedSearchDismissing)) btn.alpha = 1.0;

    // In-place: the toolbar is pinned to 45pt while Apollo positions the button for the ~99pt docked
    // geometry, so it would be clipped — re-center it into the band. OFF mode lets Apollo size/place it.
    if (sKeepSearchBarInPlace) {
        CGPoint rest = xRestCenter(toolbar, field);
        if (!CGSizeEqualToSize(btn.bounds.size, CGSizeMake(kXSize, kXSize))) {
            [UIView performWithoutAnimation:^{ btn.bounds = CGRectMake(0, 0, kXSize, kXSize); }];
        }
        if (!CGPointEqualToPoint(btn.center, rest)) {
            [UIView performWithoutAnimation:^{ btn.center = rest; }];
        }
    }

    // During teardown Apollo would otherwise pull this button through its old docked geometry. During
    // focus, however, preserving UIKit's material setup avoids cancelling the glass button's own reveal.
    if (sFeedSearchDismissing) {
        for (NSString *k in [btn.layer.animationKeys copy]) {
            if (![k hasPrefix:@"sipX"]) [btn.layer removeAnimationForKey:k];
        }
    }
}

// Dismiss the round-X by sliding the entire native glass control back through the trailing edge. Keeping
// the effect at alpha 1 lets UIKit render its glass correctly throughout the transition.
static void animateCancelOut(void) {
    UIView *toolbar = sFeedSearchToolbar;
    UIButton *cancel = sFeedSearchCancel;
    if (!toolbar || ![cancel isKindOfClass:[UIButton class]]) return;

    if ([cancel.layer animationForKey:@"sipXOut"]) return; // already sliding out
    [cancel.layer removeAnimationForKey:@"sipXIn"];
    if (!CGAffineTransformIsIdentity(cancel.transform)) cancel.transform = CGAffineTransformIdentity; // frame == model
    CGFloat dist = xParkDistance(toolbar, cancel);
    cancel.transform = CGAffineTransformMakeTranslation(dist, 0.0); // model parks off-right
    CABasicAnimation *slide = [CABasicAnimation animationWithKeyPath:@"transform.translation.x"];
    slide.fromValue = @0.0;
    slide.toValue = @(dist);
    slide.duration = 0.24;
    slide.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseIn];
    [cancel.layer addAnimation:slide forKey:@"sipXOut"];
}

// Style + place the round-X each layout pass, and run the slide-in once per activation.
static void recenterCancelButton(void) {
    UIView *toolbar = sFeedSearchToolbar;
    UIButton *cancel = sFeedSearchCancel;
    if (!toolbar || ![cancel isKindOfClass:[UIButton class]]) return;
    if (cancel.superview != toolbar) return;
    if (CGRectGetHeight(toolbar.bounds) < 1.0) return; // not laid out yet
    styleCancelAsRoundX(cancel, toolbar, sFeedSearchField);
    if (sCancelNeedsIntro) {
        // Measure against the model frame: clear any leftover parked transform from a prior dismiss.
        if (!CGAffineTransformIsIdentity(cancel.transform)) {
            [UIView performWithoutAnimation:^{ cancel.transform = CGAffineTransformIdentity; }];
        }
        // Fire once the button is at its active rest. OFF: wait for the toolbar to dock (grow past its
        // resting height). In-place: ready immediately (we force the center above).
        BOOL ready = sKeepSearchBarInPlace
                   ? YES
                   : (CGRectGetHeight(toolbar.bounds) > sRestToolbarHeight + 8.0);
        if (ready && CGRectGetWidth(cancel.bounds) > 1.0) {
            sCancelNeedsIntro = NO;
            CGFloat dist = xParkDistance(toolbar, cancel); // transform is identity here -> frame == model
            [cancel.layer removeAnimationForKey:@"sipXOut"];
            CGPoint rest = cancel.layer.position;
            CABasicAnimation *slide = [CABasicAnimation animationWithKeyPath:@"position"];
            slide.fromValue = [NSValue valueWithCGPoint:CGPointMake(rest.x + dist, rest.y)];
            slide.toValue = [NSValue valueWithCGPoint:rest];

            CABasicAnimation *fade = [CABasicAnimation animationWithKeyPath:@"opacity"];
            fade.fromValue = @0.0;
            fade.toValue = @1.0;

            CAAnimationGroup *intro = [CAAnimationGroup animation];
            intro.animations = @[slide, fade];
            intro.duration = 0.36;
            intro.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
            [cancel.layer addAnimation:intro forKey:@"sipXIn"];
        }
    }
}

// MARK: - Cancel button sizing (OFF / nav-hide mode)
//
// Apollo reads [dismissSearchBarButton sizeThatFits:] every layout pass to size the field
// (sub_1002be508: viewWidth - 17 - buttonWidth), place the field (sub_1002be378) and frame the button.
// Returning a fixed square for our tagged button lets Apollo size the field and position the round-X
// itself, with no frame writes from us. Scoped to Liquid Glass, OFF mode, and only the tagged button.
// (The %hook UIButton in ApolloPhotoPostComposerScrollFix.xm only overrides setTitle:, so no collision.)
%hook UIButton

- (CGSize)sizeThatFits:(CGSize)size {
    if (IsLiquidGlass() && !sKeepSearchBarInPlace && objc_getAssociatedObject(self, kRoundXKey)) {
        return CGSizeMake(kXSize, kXSize); // square -> circle via the corner radius; Apollo reclaims the freed width
    }
    return %orig;
}

- (CGSize)intrinsicContentSize {
    if (IsLiquidGlass() && !sKeepSearchBarInPlace && objc_getAssociatedObject(self, kRoundXKey)) {
        return CGSizeMake(kXSize, kXSize);
    }
    return %orig;
}

%end

@interface _TtC6Apollo21ASTableViewController : UIViewController
- (void)textFieldDidBeginEditing:(id)textField;
- (void)dismissSearchBarButtonTappedWithSender:(id)sender;
@end

%hook _TtC6Apollo21ASTableViewController

- (void)textFieldDidBeginEditing:(id)textField {
    // searchBarShouldStickToKeyboard == YES is the comments in-thread search (different layout). Its
    // original transition is intentionally untouched.
    if (MSHookIvar<BOOL>(self, "searchBarShouldStickToKeyboard")) {
        %orig;
        return;
    }

    // Arm our feed state *before* Apollo begins its own focus animation. The previous implementation
    // armed it after %orig, which meant Apollo first laid out the full-width field, then a follow-up pass
    // abruptly clamped it for the X. That one-frame disagreement is the visible field flicker and makes
    // the X appear to hop rather than share the native search transition.
    BOOL wasAlreadyActive = sFeedSearchActive && !sFeedSearchDismissing;
    sFeedSearchToolbarRestPinned = NO;       // a new edit owns the anchor through the active-search path
    sFeedSearchActive = YES;
    sFeedSearchDismissing = NO;
    sFeedSearchScrolledByUser = NO;
    ++sFeedSearchDismissGen;  // a re-focus during a dismiss window cancels the pending release timer
    id tableNode = ApolloObjectIvar(self, "tableNode");
    UIView *tv = [tableNode respondsToSelector:@selector(view)] ? [tableNode view] : nil;
    if ([tv isKindOfClass:objc_getClass("ASTableView")]) sFeedSearchTable = (UIScrollView *)tv;
    id upper = ApolloObjectIvar(self, "upperToolbar");
    if ([upper isKindOfClass:[UIView class]]) {
        sFeedSearchToolbar = (UIView *)upper;
        CGFloat h = CGRectGetHeight([(UIView *)upper bounds]);
        if (h > 1.0) sRestToolbarHeight = h;
    }
    id field = ApolloObjectIvar(self, "searchTextField");
    if ([field isKindOfClass:[UIView class]]) sFeedSearchField = (UIView *)field;

    // Liquid Glass only: capture the nav bar (for the hide rewrite) and arm the round-X before Apollo
    // starts asking it for size/position. This puts the field contraction and the X's slide in the same
    // UIKit transaction, just like the built-in Search tab.
    if (IsLiquidGlass()) {
        sFeedSearchNavBar = [(UIViewController *)self navigationController].navigationBar;
        if (!wasAlreadyActive) {
            sCancelNeedsIntro = YES;
            CGRect restFrame = [(UIView *)field frame];
            if (CGRectGetWidth(restFrame) > 1.0 && CGRectGetHeight(restFrame) > 1.0) {
                sFeedSearchFieldIntroStartFrame = restFrame;
                sFeedSearchFieldIntroStartFrameIsValid = YES;
                sFeedSearchFieldNeedsIntro = YES;
            } else {
                sFeedSearchFieldIntroStartFrameIsValid = NO;
                sFeedSearchFieldNeedsIntro = NO;
            }
        }
        id cancel = ApolloObjectIvar(self, "dismissSearchBarButton");
        if ([cancel isKindOfClass:[UIButton class]]) {
            sFeedSearchCancel = (UIButton *)cancel;
            tagRoundXButton((UIButton *)cancel); // tag for the sizeThatFits override
        }
    }

    %orig;
}

// Keep the captured refs current (the table/toolbar may not be ready at focus, and the docked toolbar
// changes across keystroke reloads). Idempotent; the clamp is armed by sFeedSearchActive.
- (void)viewDidLayoutSubviews {
    %orig;
    if (MSHookIvar<BOOL>(self, "searchBarShouldStickToKeyboard")) return; // feed-only; skip comments search
    // Keep the offset-stabilizer refs current (runs regardless of Liquid Glass).
    id tableNode = ApolloObjectIvar(self, "tableNode");
    UIView *tv = [tableNode respondsToSelector:@selector(view)] ? [tableNode view] : nil;
    if ([tv isKindOfClass:objc_getClass("ASTableView")]) sFeedSearchTable = (UIScrollView *)tv;
    id upper = ApolloObjectIvar(self, "upperToolbar");
    if ([upper isKindOfClass:[UIView class]]) sFeedSearchToolbar = (UIView *)upper;
    id field = ApolloObjectIvar(self, "searchTextField");
    if ([field isKindOfClass:[UIView class]]) sFeedSearchField = (UIView *)field;

    // Re-assert the surfaced-header visibility after every relayout (runs regardless of Liquid Glass).
    // setContentOffset: alone isn't enough on return: a reload there can recreate the header at full
    // alpha (and Apollo may re-park via setBounds: instead of setContentOffset:), so the scrolled-up
    // chrome bleeds back through the glass. Recompute it here so it stays hidden while surfaced.
    if (sFeedSearchTable) {
        ApolloFeedSearchSetHeaderHidden(sFeedSearchTable, ApolloFeedSearchIsSurfaced(sFeedSearchTable));
    }

    // Liquid Glass only: keep the round-X styled and run its slide-in.
    if (!IsLiquidGlass()) return;
    id cancel = ApolloObjectIvar(self, "dismissSearchBarButton");
    if ([cancel isKindOfClass:[UIButton class]]) {
        sFeedSearchCancel = (UIButton *)cancel;
        tagRoundXButton((UIButton *)cancel);
    }
    if (sFeedSearchActive || sFeedSearchDismissing) recenterCancelButton();
}

- (void)dismissSearchBarButtonTappedWithSender:(id)sender {
    // In-place: Apollo's teardown (sub_1002bf57c) animates the toolbar/field/button from the docked-top
    // geometry; since the nav bar never moved here, that reads as a "fly in from above". Keep our pins
    // live through the teardown (don't pre-clear), strip the implicit animations (in the toolbar hooks),
    // and release on a timer guarded by a generation counter against a re-focus.
    if (IsLiquidGlass() && sKeepSearchBarInPlace) {
        sFeedSearchFieldNeedsIntro = NO;
        sFeedSearchFieldIntroStartFrameIsValid = NO;
        sFeedSearchDismissing = YES;                  // pins stay armed via (active || dismissing)
        ApolloFeedSearchRestoreHeader();              // bring the chrome back as the search closes
        NSUInteger gen = ++sFeedSearchDismissGen;     // a newer dismiss / re-focus invalidates this timer
        %orig;
        animateCancelOut();                           // slide the native glass X out
        // Community Highlights may re-attach its carousel and re-pin the table for roughly 0.8 seconds
        // after the search closes. Keep the in-place geometry protected through that settle window; releasing
        // at Apollo's short button-animation duration lets the toolbar adopt the carousel's content-space y.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.05 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (gen != sFeedSearchDismissGen) return; // re-focused / re-dismissed meanwhile
            sFeedSearchActive = NO;
            sFeedSearchDismissing = NO;
            // Do not release the upperToolbar yet. Apollo continues its ordinary feed settle after the
            // search/X animation, and that late pass can otherwise relocate the field into the subreddit
            // header (with or without Community Highlights). Hold its known resting window position until
            // the user actually scrolls the feed.
            sFeedSearchToolbarRestPinned = YES;
            sFeedSearchField = nil;
            sFeedSearchCancel = nil;
            sCancelNeedsIntro = NO;
            sFeedSearchFieldNeedsIntro = NO;
            sFeedSearchFieldIntroStartFrameIsValid = NO;
            sFeedSearchScrolledByUser = NO;
            ApolloFeedSearchReassertToolbarPin();
        });
        return;
    }

    // OFF (nav-hide): release the capture up front so Apollo's restore passes through, then run a short
    // dismissing window.
    ApolloFeedSearchRestoreHeader();                 // bring the chrome back as the search closes
    sFeedSearchNavBar = nil;
    sFeedSearchActive = NO;
    sFeedSearchFieldNeedsIntro = NO;
    sFeedSearchFieldIntroStartFrameIsValid = NO;
    sFeedSearchDismissing = YES;
    %orig;
    animateCancelOut(); // slide the round-X out
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ sFeedSearchDismissing = NO; });
}

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    if (!IsLiquidGlass() || MSHookIvar<BOOL>(self, "searchBarShouldStickToKeyboard")) return;
    id field = ApolloObjectIvar(self, "searchTextField");
    NSString *txt = [field isKindOfClass:[UITextField class]] ? [(UITextField *)field text] : nil;

    // Issue 2 (in-place): returning to a feed whose search is being restored, Apollo re-runs its search
    // takeover — it hides the nav bar AND docks the search toolbar to the very top (it assumes the nav is
    // gone). In-place mode keeps the nav visible with the toolbar pinned just below it, but those pins only
    // engage once the search is "active", and the takeover fires during the restoring field's
    // becomeFirstResponder — BEFORE textFieldDidBeginEditing arms them. So without this the nav re-hides
    // (or the toolbar lands on top of it). Arm the whole in-place pin set here (capture refs + the active
    // flag) before the appear / re-focus, so the nav stays put and the toolbar docks below it from the
    // first pass. textFieldDidBeginEditing re-arms idempotently if/when the field actually focuses.
    if (sKeepSearchBarInPlace && txt.length > 0) {
        sFeedSearchNavBar = [(UIViewController *)self navigationController].navigationBar;
        if ([field isKindOfClass:[UIView class]]) sFeedSearchField = (UIView *)field;
        id upper = ApolloObjectIvar(self, "upperToolbar");
        if ([upper isKindOfClass:[UIView class]]) sFeedSearchToolbar = (UIView *)upper;
        sFeedSearchToolbarRestPinned = NO;
        sFeedSearchActive = YES;
        sFeedSearchDismissing = NO;
        sFeedSearchScrolledByUser = NO;
    }
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    if (!IsLiquidGlass() || MSHookIvar<BOOL>(self, "searchBarShouldStickToKeyboard")) return;
    UINavigationBar *nb = [(UIViewController *)self navigationController].navigationBar;

    // Issue 2 safety net: if the nav bar slipped into the hidden state before our block armed, restore
    // it (in-place mode keeps it visible), and re-assert the toolbar so it sits below the nav instead of
    // docked on top of it. Only touch the bar/toolbar we captured for this feed.
    if (sKeepSearchBarInPlace && nb && nb == sFeedSearchNavBar) {
        if (nb.transform.ty < -1.0) nb.transform = CGAffineTransformIdentity;
        if (nb.alpha < 1.0) nb.alpha = 1.0;
        // Route the toolbar back through the setFrame pin (now that the flags are armed) so it re-docks
        // below the still-visible nav rather than at the top.
        UIView *tb = sFeedSearchToolbar;
        if (tb && sFeedSearchActive && !sFeedSearchScrolledByUser) [tb setFrame:tb.frame];
    }
}

- (void)viewWillDisappear:(BOOL)animated {
    // If this controller owns the captured bar and is leaving, drop the capture so a stale reference
    // can't affect an unrelated transform later.
    if (sFeedSearchNavBar && [(UIViewController *)self navigationController].navigationBar == sFeedSearchNavBar) {
        sFeedSearchNavBar = nil;
    }
    sFeedSearchActive = NO;
    sFeedSearchDismissing = NO;
    sFeedSearchToolbarRestPinned = NO;
    sFeedSearchToolbar = nil;
    sFeedSearchField = nil;
    sFeedSearchCancel = nil;
    sCancelNeedsIntro = NO;
    sFeedSearchFieldNeedsIntro = NO;
    sFeedSearchFieldIntroStartFrameIsValid = NO;
    sFeedSearchToolbarRestWindowYIsValid = NO;
    ++sFeedSearchDismissGen; // a pending dismiss release timer can't resurrect state after we leave
    %orig;
}

%end

// MARK: - Feed table: pin the top inset/offset
//
// Intercept the geometry setters at the source. Strictly gated to the one captured feed table while a
// feed search is active/dismissing — every other ASTableView falls through to %orig (so the
// ApolloSubredditHeaders.xm UIScrollView hook still chains). Runs regardless of Liquid Glass.
%hook ASTableView

- (void)setContentInset:(UIEdgeInsets)inset {
    if ((UIScrollView *)self == sFeedSearchTable) {
        ApolloFeedSearchReleaseRestPinForUserScroll((UIScrollView *)self);
        BOOL managed = ApolloFeedSearchManagedHeader((UIScrollView *)self);
        if (!sFeedSearchActive && !sFeedSearchDismissing) {
            // Remember the feed's resting top inset (standalone / Headers OFF) so we can hold the chrome in
            // place when the field is focused with no query yet.
            if (!managed && inset.top > 1.0) sFeedSearchStandaloneRestInset = inset.top;
        } else if (sFeedSearchActive && managed) {
            CGFloat want = ApolloFeedSearchActiveRestTop();
            if (inset.top < want) inset.top = want; // FLOOR only — never lower (allow pull-to-refresh growth)
        } else if (sFeedSearchActive && !sFeedSearchDismissing && !managed &&
                   sFeedSearchStandaloneRestInset > 1.0) {
            // Standalone (Subreddit Headers OFF), focused: Apollo shrinks the top inset (~161->99) for the
            // docked-field layout, which pulls the small Community Highlights carousel up behind the field.
            // The carousel is short enough that it doesn't bury the results, so we keep it in place for the
            // WHOLE search (empty AND while typing) — Apollo's native per-query surfacing is inconsistent
            // (some letters push it up, some don't); the user wants it to always stay, results below it.
            // Hold the resting inset; releases only on dismiss (which has its own restore).
            if (inset.top < sFeedSearchStandaloneRestInset) inset.top = sFeedSearchStandaloneRestInset;
        }
    }
    %orig(inset);
    if ((UIScrollView *)self == sFeedSearchTable) ApolloFeedSearchReassertToolbarPin();
}

- (void)setContentOffset:(CGPoint)offset {
    if ((UIScrollView *)self == sFeedSearchTable) {
        ApolloFeedSearchReleaseRestPinForUserScroll((UIScrollView *)self);
    }
    // Standalone (Headers OFF) + focused: pair with the inset hold above to keep the small Community
    // Highlights carousel at its resting position throughout the search (tap AND while typing) so it stays
    // in place with results below it, instead of Apollo inconsistently pushing it up behind the field on
    // some queries. NOT during dismiss (which has its own restore). Released the instant the user drags
    // (so they can scroll down through the results), and re-armed when they settle back at the top.
    if ((UIScrollView *)self == sFeedSearchTable && sFeedSearchActive && !sFeedSearchDismissing &&
        sFeedSearchStandaloneRestInset > 1.0 &&
        !ApolloFeedSearchManagedHeader((UIScrollView *)self)) {
        UIScrollView *sv2 = (UIScrollView *)self;
        CGFloat rest = -sFeedSearchStandaloneRestInset;
        if (sv2.isDragging) sFeedSearchScrolledByUser = YES;
        else if (offset.y <= rest + 1.0) sFeedSearchScrolledByUser = NO;
        if (!sv2.isDragging && !sv2.isDecelerating && !sFeedSearchScrolledByUser) {
            if (offset.y > rest) offset.y = rest; // hold the carousel at rest
        }
        %orig(offset);
        ApolloFeedSearchReassertToolbarPin();
        return;
    }
    // Only when a FULL subreddit header is present (the managed case). Without it — Home, or just the small
    // Community Highlights carousel (Subreddit Headers off) — leave the feed's geometry stock; Apollo
    // surfaces results there natively, and the Highlights module re-attaches its carousel on dismiss.
    if ((UIScrollView *)self == sFeedSearchTable &&
        (sFeedSearchActive || sFeedSearchDismissing) &&
        ApolloFeedSearchManagedHeader((UIScrollView *)self)) {
        UIScrollView *sv = (UIScrollView *)self;
        CGFloat rest = -ApolloFeedSearchActiveRestTop();
        BOOL userScrolling = sv.isDragging || sv.isDecelerating;
        BOOL hasQuery = (ApolloFeedSearchQueryText().length > 0);
        CGFloat target = ApolloFeedSearchDesiredOffsetY(sv); // rest (empty) or surfaced (query)

        // Once the user drags, stop pinning so they can browse; re-arm when they settle back at/above
        // the target (scrolling up toward the chrome snaps back; scrolling down through results is free).
        if (sv.isDragging) sFeedSearchScrolledByUser = YES;
        else if (offset.y <= target + 1.0) sFeedSearchScrolledByUser = NO;

        if (sFeedSearchDismissing && !userScrolling) {
            if (offset.y > rest) offset.y = rest; // teardown: restore the chrome as the search dismisses
        } else if (sFeedSearchActive && !sFeedSearchDismissing && !userScrolling &&
                   !sFeedSearchScrolledByUser) {
            if (hasQuery && target > rest + 1.0) {
                offset.y = target;            // surfaced (in-place + query): hold the chrome scrolled off
            } else if (offset.y > rest) {
                offset.y = rest;              // otherwise: clamp down to rest only; keep pull-to-refresh
            }
        }

        BOOL surfaced = hasQuery && sFeedSearchActive && !sFeedSearchDismissing &&
                        !sFeedSearchScrolledByUser && (target > rest + 1.0);
        ApolloFeedSearchSetHeaderHidden(sv, surfaced);
        %orig(offset);
        ApolloFeedSearchReassertToolbarPin();
        return;
    }
    %orig;
    if ((UIScrollView *)self == sFeedSearchTable) ApolloFeedSearchReassertToolbarPin();
}

// A scroll view's bounds.origin IS its contentOffset; Texture/Apollo re-park the feed via setBounds:
// too, which setContentOffset: alone doesn't catch. Mirror the same pin here so the surfaced position
// actually holds (otherwise a setBounds: re-park to rest renders before our next setContentOffset:).
- (void)setBounds:(CGRect)bounds {
    if ((UIScrollView *)self == sFeedSearchTable) {
        UIScrollView *sv = (UIScrollView *)self;
        ApolloFeedSearchReleaseRestPinForUserScroll(sv);
        // Only while surfacing (in-place + query); OFF mode never enters here, so its bounds pass through.
        if (!sv.isDragging && !sv.isDecelerating && ApolloFeedSearchIsSurfaced(sv)) {
            CGFloat want = ApolloFeedSearchDesiredOffsetY(sv);
            if (fabs(bounds.origin.y - want) > 0.5) bounds.origin.y = want;
            // Hide the header here too: the surface often lands via setBounds: (not setContentOffset:),
            // and viewDidLayoutSubviews may not run again until the next keystroke — so without this the
            // chrome bleeds through the glass until the 2nd letter. Pair with the surface, atomically.
            ApolloFeedSearchSetHeaderHidden(sv, YES);
        }
    }
    %orig(bounds);
    if ((UIScrollView *)self == sFeedSearchTable) ApolloFeedSearchReassertToolbarPin();
}

// The header gets re-installed on reloads; hide the freshly-installed one immediately if we're surfaced.
- (void)setTableHeaderView:(UIView *)header {
    %orig;
    if ((UIScrollView *)self == sFeedSearchTable && header && ApolloFeedSearchIsSurfaced((UIScrollView *)self)) {
        ApolloFeedSearchSetHeaderHidden((UIScrollView *)self, YES);
    }
}

%end

// The subreddit header wrapper force-restores its own alpha to 1 in -layoutSubviews (anti-flash). While
// the feed search is surfaced, that re-shows the scrolled-up chrome behind the glass every layout pass
// (and wins the final frame on the first keystroke). Intercept its setAlpha: and hold it at 0 while
// surfaced, for the captured feed's header only; otherwise pass through so it shows normally.
@interface ApolloSubredditHeaderWrapperView : UIView
@end

%hook ApolloSubredditHeaderWrapperView

- (void)setAlpha:(CGFloat)alpha {
    if (alpha > 0.0 && sFeedSearchTable &&
        (UIView *)self == [(UITableView *)sFeedSearchTable tableHeaderView] &&
        ApolloFeedSearchIsSurfaced(sFeedSearchTable)) {
        %orig(0.0);
        return;
    }
    %orig;
}

%end

// MARK: - Nav-bar hide / in-place block
//
// OFF: rewrite Apollo's hardcoded -88 translate to the bar's true off-screen extent so it fully hides.
// In-place: block the slide and the alpha fade so the nav bar (title + items) stays put and visible.
%hook UINavigationBar

- (void)setTransform:(CGAffineTransform)transform {
    // Only the captured feed-search bar, only under Liquid Glass, only for an upward (hide) translate.
    // Restores (identity / ty >= 0) and every other nav bar pass through.
    if (!IsLiquidGlass() || self != sFeedSearchNavBar || transform.ty >= -1.0) {
        %orig;
        return;
    }

    // In-place: block the slide entirely so the nav bar stays where it is.
    if (sKeepSearchBarInPlace) {
        %orig(CGAffineTransformIdentity);
        return;
    }

    // OFF: push by the bar's true off-screen extent (frame origin ≈ safe-area top + height).
    CGFloat safeTop = self.window ? self.window.safeAreaInsets.top : self.safeAreaInsets.top;
    CGFloat needed = -(safeTop + self.bounds.size.height);

    CGAffineTransform corrected = transform;
    if (needed < corrected.ty) corrected.ty = needed; // only ever push further up, never less
    %orig(corrected);
}

// In-place: Apollo fades the captured bar to 0 alongside the slide; clamp it back to 1 so the title /
// items stay visible. Gated to the captured bar; OFF mode wants the fade and passes through.
- (void)setAlpha:(CGFloat)alpha {
    if (IsLiquidGlass() && sKeepSearchBarInPlace && self == sFeedSearchNavBar && alpha < 1.0) {
        %orig(1.0);
        return;
    }
    %orig;
}

%end

// MARK: - "Keep Search Bar In Place": pin the toolbar
//
// In-place only. Apollo's takeover drives the toolbar from its resting band (h=45) up to the docked
// position (h≈99). We pin it to its exact resting band, including Apollo's small overlap with the nav
// bar, so focus does not shift the field vertically. Released once the user scrolls so the toolbar rides
// content normally.
@interface _TtC6Apollo19ApolloSearchToolbar : UIView
@end

%hook _TtC6Apollo19ApolloSearchToolbar

- (void)setFrame:(CGRect)frame {
    if (!IsLiquidGlass() || !sKeepSearchBarInPlace ||
        (!sFeedSearchActive && !sFeedSearchDismissing && !sFeedSearchToolbarRestPinned) ||
        sFeedSearchScrolledByUser || (UIView *)self != sFeedSearchToolbar) {
        %orig;
        return;
    }
    UIView *sup = [(UIView *)self superview];
    UINavigationBar *nb = sFeedSearchNavBar;
    if (!sup || !nb || !nb.window) { %orig; return; }

    CGFloat windowTopY = CGRectGetMaxY([nb convertRect:nb.bounds toView:nil]); // nav bottom, window space
    if (windowTopY <= 1.0) { %orig; return; }                                  // bar not laid out yet
    CGFloat localTopY = [sup convertPoint:CGPointMake(0.0, windowTopY) fromView:nil].y;

    CGRect pinned = frame;
    // Convert the stable visual resting point back into the toolbar's *current* superview coordinates.
    // For a subreddit that superview scrolls when Community Highlights restores; reusing its old local y
    // would pin the field inside the carousel instead of directly below the nav bar.
    pinned.origin.y = sFeedSearchToolbarRestWindowYIsValid
        ? [sup convertPoint:CGPointMake(0.0, sFeedSearchToolbarRestWindowY) fromView:nil].y
        : localTopY;
    pinned.size.height = 45.0; // == Apollo's toolbarHeight ivar; never let it grow to ~99
    %orig(pinned);
}

// Each layout pass while searching (both modes): keep the round-X styled/placed and run its slide-in.
// In-place during dismiss, also strip Apollo's teardown animations off the toolbar + field so nothing
// flies in from the docked-top geometry.
- (void)layoutSubviews {
    %orig;
    UIView *toolbarView = (UIView *)self;
    // Record the *visible* resting frame before the field becomes first responder. Apollo begins moving
    // the toolbar before it calls textFieldDidBeginEditing:, so this layout-time sample is the only stable
    // source for the true "keep it in place" y-coordinate. Store window, not local, coordinates: a
    // Highlights re-attach changes the scrolling superview's coordinate system during dismissal.
    if (IsLiquidGlass() && sKeepSearchBarInPlace && !sFeedSearchActive && !sFeedSearchDismissing &&
        !sFeedSearchToolbarRestPinned &&
        !isCommentToolbar(toolbarView) && CGRectGetMinY(toolbarView.frame) >= 0.0 &&
        CGRectGetHeight(toolbarView.bounds) > 1.0) {
        BOOL fieldIsFocused = NO;
        for (UIView *subview in toolbarView.subviews) {
            if ([subview isKindOfClass:[UITextField class]] && [(UITextField *)subview isFirstResponder]) {
                fieldIsFocused = YES;
                break;
            }
        }
        if (!fieldIsFocused) {
            CGRect visible = [toolbarView convertRect:toolbarView.bounds toView:nil];
            if (CGRectGetMinY(visible) >= 0.0) {
                sFeedSearchToolbar = toolbarView;
                sFeedSearchToolbarRestWindowY = CGRectGetMinY(visible);
                sFeedSearchToolbarRestWindowYIsValid = YES;
            }
        }
    }
    // "Find in Comments" bar (in-thread search, excluded from the feed handling above): group its field,
    // centered checkmark and chevrons in one genuine Liquid Glass surface while docked.
    if (isCommentToolbar((UIView *)self)) {
        UIView *tbv = (UIView *)self;
        if (toolbarDocked(tbv)) {
            if (ApolloNativeSearchGlassAvailable()) {
                ensureCommentGlassBacking(tbv);
            } else {
                removeCommentGlassBacking(tbv);
                ensureCommentFallbackBlurBacking(tbv);
                nudgeCommentFallbackDoneButton(tbv);
            }
        } else {
            removeCommentGlassBacking(tbv);
            removeCommentFallbackBlurBacking(tbv);
        }
        // Re-evaluate the field after the toolbar is reparented. This removes its standalone glass when
        // docked and restores it when the field returns to the top of the thread.
        for (UIView *sv in tbv.subviews) {
            if ([sv isKindOfClass:NSClassFromString(@"_TtC6Apollo24ApolloSearchBarTextField")]) {
                updateNativeSearchFieldGlass((UITextField *)sv);
                break;
            }
        }
    }
    if (!IsLiquidGlass() || (UIView *)self != sFeedSearchToolbar ||
        (!sFeedSearchActive && !sFeedSearchDismissing)) {
        return;
    }
    recenterCancelButton(); // round-X styling + slide-in

    if (sKeepSearchBarInPlace && sFeedSearchDismissing) {
        CALayer *tl = [(UIView *)self layer];
        [tl removeAnimationForKey:@"position"];
        [tl removeAnimationForKey:@"bounds"];
        UIView *field = sFeedSearchField;
        if (field) {
            CALayer *fl = field.layer;
            [fl removeAnimationForKey:@"position"];
            [fl removeAnimationForKey:@"bounds"];
            [fl removeAnimationForKey:@"bounds.size"];
            [fl removeAnimationForKey:@"opacity"];
        }
    }
}

// In-place: zero the captured toolbar's top safe-area inset so the field/button row stays in the 45pt band.
- (UIEdgeInsets)safeAreaInsets {
    UIEdgeInsets insets = %orig;
    if (IsLiquidGlass() && sKeepSearchBarInPlace &&
        (sFeedSearchActive || sFeedSearchDismissing) &&
        (UIView *)self == sFeedSearchToolbar) {
        insets.top = 0.0;
    }
    return insets;
}

%end

// MARK: - Search field gap (in-place mode only)
//
// In-place we place the button by hand, so clamp the field's right edge to leave room for the circle.
// OFF mode gets the field width from Apollo's sizeThatFits-driven math, so we don't touch it here.
@interface _TtC6Apollo24ApolloSearchBarTextField : UITextField
@end

%hook _TtC6Apollo24ApolloSearchBarTextField

- (void)setBackgroundColor:(UIColor *)color {
    // Apollo (and custom themes) still supply a flat fill. The system material underneath owns the
    // background in linked-glass builds; preserve the exact old color path everywhere else.
    if (ApolloNativeSearchGlassAvailable()) {
        %orig([UIColor clearColor]);
        return;
    }
    %orig;
}

- (void)setFrame:(CGRect)frame {
    UIView *sup = [(UIView *)self superview];
    if (IsLiquidGlass() && sKeepSearchBarInPlace && sFeedSearchActive && !sFeedSearchDismissing &&
        sup && sup == sFeedSearchToolbar) {
        CGFloat maxRight = fieldMaxRight(sup);
        if (frame.origin.x < maxRight && CGRectGetMaxX(frame) > maxRight) {
            frame.size.width = maxRight - frame.origin.x;
        }
    }
    %orig(frame);
    updateNativeSearchFieldGlass((UITextField *)self);
    animateFeedSearchFieldIntroIfNeeded((UITextField *)self);
}

- (void)layoutSubviews {
    %orig;
    updateNativeSearchFieldGlass((UITextField *)self);
}

- (void)didMoveToWindow {
    %orig;
    updateNativeSearchFieldGlass((UITextField *)self);
}

%end

%ctor {
    %init;
}

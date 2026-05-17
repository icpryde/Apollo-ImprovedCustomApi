// ApolloInlineLinkPreviews.xm
//
// Replaces Apollo's basic LinkButtonNode cards with richer metadata cards when
// the target page exposes useful Open Graph / Twitter Card / first-party API
// metadata. Falls back to Apollo's native card when metadata is missing.

#import "ApolloCommon.h"
#import "ApolloLinkPreviewCache.h"
#import "ApolloLinkPreviewFetcher.h"
#import "ApolloState.h"

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

typedef NS_ENUM(unsigned char, ApolloLinkPreviewStackDirection) {
    ApolloLinkPreviewStackDirectionVertical = 0,
    ApolloLinkPreviewStackDirectionHorizontal = 1,
};
typedef NS_ENUM(unsigned char, ApolloLinkPreviewStackJustifyContent) {
    ApolloLinkPreviewStackJustifyContentStart = 0,
};
typedef NS_ENUM(unsigned char, ApolloLinkPreviewStackAlignItems) {
    ApolloLinkPreviewStackAlignItemsStart = 0,
    ApolloLinkPreviewStackAlignItemsCenter = 2,
    ApolloLinkPreviewStackAlignItemsStretch = 3,
};

@class ASLayoutSpec;
@class ASStackLayoutSpec;
@class ASInsetLayoutSpec;
@class ASRatioLayoutSpec;
@class ASBackgroundLayoutSpec;
@class ASDisplayNode;
@class ASNetworkImageNode;
@class ASTextNode;

@interface ASDisplayNode : NSObject
- (void)addSubnode:(ASDisplayNode *)subnode;
- (ASDisplayNode *)supernode;
- (id)style;
@property (nullable, nonatomic, copy) UIColor *backgroundColor;
@property (nonatomic) CGFloat cornerRadius;
@property (nonatomic) BOOL clipsToBounds;
@end

@interface ASTextNode : ASDisplayNode
@property (nonatomic, copy) NSAttributedString *attributedText;
@property (nonatomic) NSUInteger maximumNumberOfLines;
@property (nonatomic) NSLineBreakMode truncationMode;
@property (nonatomic) BOOL userInteractionEnabled;
@end

@interface ASNetworkImageNode : ASDisplayNode
@property (nullable, copy) NSURL *URL;
@property (nonatomic) UIViewContentMode contentMode;
@property (nonatomic) BOOL clipsToBounds;
@property (nonatomic) CGFloat cornerRadius;
@property (nonatomic) BOOL placeholderEnabled;
@property (nonatomic, copy) UIColor *placeholderColor;
@end

@interface ASLayoutSpec : NSObject
@property (nullable, nonatomic) NSArray *children;
- (id)style;
@end

@interface ASStackLayoutSpec : ASLayoutSpec
@property (nonatomic) ApolloLinkPreviewStackDirection direction;
@property (nonatomic) CGFloat spacing;
@property (nonatomic) ApolloLinkPreviewStackJustifyContent justifyContent;
@property (nonatomic) ApolloLinkPreviewStackAlignItems alignItems;
+ (instancetype)stackLayoutSpecWithDirection:(ApolloLinkPreviewStackDirection)direction
                                     spacing:(CGFloat)spacing
                              justifyContent:(ApolloLinkPreviewStackJustifyContent)justifyContent
                                  alignItems:(ApolloLinkPreviewStackAlignItems)alignItems
                                    children:(NSArray *)children;
@end

@interface ASInsetLayoutSpec : ASLayoutSpec
+ (instancetype)insetLayoutSpecWithInsets:(UIEdgeInsets)insets child:(id)child;
@end

@interface ASRatioLayoutSpec : ASLayoutSpec
+ (instancetype)ratioLayoutSpecWithRatio:(CGFloat)ratio child:(id)child;
@end

@interface ASBackgroundLayoutSpec : ASLayoutSpec
+ (instancetype)backgroundLayoutSpecWithChild:(id)child background:(id)background;
@end

struct CDStruct_90e057aa { CGSize min; CGSize max; };

static char kApolloLinkPreviewNodesKey;
static char kApolloLinkPreviewFetchInFlightKey;
static char kApolloLinkPreviewOriginalHostShellKey;

static Class ApolloLPClass(NSString *name) {
    return NSClassFromString(name);
}

static NSString *ApolloLPHost(NSURL *url) {
    NSString *host = url.host.lowercaseString ?: @"";
    if ([host hasPrefix:@"www."]) host = [host substringFromIndex:4];
    return host;
}

static BOOL ApolloLPHostHasSuffix(NSURL *url, NSString *suffix) {
    NSString *host = ApolloLPHost(url);
    return [host isEqualToString:suffix] || [host hasSuffix:[@"." stringByAppendingString:suffix]];
}

static BOOL ApolloLPTrustedInlineImageHost(NSURL *url) {
    NSArray<NSString *> *suffixes = @[
        @"redd.it", @"imgur.com", @"giphy.com", @"tenor.com", @"redgifs.com",
        @"twimg.com", @"discordapp.com", @"discordapp.net"
    ];
    for (NSString *suffix in suffixes) {
        if (ApolloLPHostHasSuffix(url, suffix)) return YES;
    }
    return NO;
}

static BOOL ApolloLPIsImgurAlbumOrShareURL(NSURL *url) {
    if (!ApolloLPHostHasSuffix(url, @"imgur.com")) return NO;
    if (url.pathExtension.length > 0) return NO;
    NSString *path = url.path ?: @"";
    if ([path hasPrefix:@"/a/"] || [path hasPrefix:@"/gallery/"]) return YES;

    NSArray<NSString *> *parts = [path componentsSeparatedByString:@"/"];
    NSMutableArray<NSString *> *clean = [NSMutableArray array];
    for (NSString *part in parts) {
        if (part.length > 0) [clean addObject:part];
    }
    if (clean.count != 1) return NO;
    NSCharacterSet *disallowed = [NSCharacterSet alphanumericCharacterSet].invertedSet;
    return [clean.firstObject rangeOfCharacterFromSet:disallowed].location == NSNotFound;
}

static BOOL ApolloLPShouldDeferToInlineMedia(NSURL *url) {
    if (![url isKindOfClass:[NSURL class]]) return NO;
    NSString *extension = url.pathExtension.lowercaseString ?: @"";
    NSSet<NSString *> *imageExtensions = [NSSet setWithObjects:@"png", @"jpg", @"jpeg", @"webp", @"gif", nil];

    if (ApolloLPIsImgurAlbumOrShareURL(url)) return YES;
    if ([imageExtensions containsObject:extension] && ApolloLPTrustedInlineImageHost(url)) return YES;

    NSString *host = ApolloLPHost(url);
    NSString *query = url.query.lowercaseString ?: @"";
    if (([host isEqualToString:@"preview.redd.it"] || [host isEqualToString:@"external-preview.redd.it"] || ApolloLPHostHasSuffix(url, @"redd.it"))
        && [extension isEqualToString:@"gif"]
        && [query containsString:@"format=mp4"]) {
        return YES;
    }

    NSString *absolute = url.absoluteString.lowercaseString ?: @"";
    if ([absolute containsString:@"reddit.com/"] && [absolute containsString:@"/video/"] && [absolute containsString:@"/player"]) {
        return YES;
    }
    return NO;
}

static NSString *ApolloLPBundleKey(NSURL *url, NSString *variant) {
    return [NSString stringWithFormat:@"%@|%@", url.absoluteString ?: @"", variant ?: @"default"];
}

static NSDictionary *ApolloLPNodeBundleForHost(ASDisplayNode *hostNode, NSURL *url, NSString *variant) {
    NSMutableDictionary<NSString *, NSDictionary *> *bundles = objc_getAssociatedObject(hostNode, &kApolloLinkPreviewNodesKey);
    if (!bundles) {
        bundles = [NSMutableDictionary dictionary];
        objc_setAssociatedObject(hostNode, &kApolloLinkPreviewNodesKey, bundles, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    NSString *key = ApolloLPBundleKey(url, variant);
    NSDictionary *bundle = bundles[key];
    if (bundle) return bundle;

    Class imageNodeClass = ApolloLPClass(@"ASNetworkImageNode");
    Class textNodeClass = ApolloLPClass(@"ASTextNode");
    Class displayNodeClass = ApolloLPClass(@"ASDisplayNode");
    if (!imageNodeClass || !textNodeClass || !displayNodeClass) return nil;

    ASNetworkImageNode *imageNode = [[imageNodeClass alloc] init];
    imageNode.contentMode = UIViewContentModeScaleAspectFill;
    imageNode.clipsToBounds = YES;
    imageNode.cornerRadius = 8.0;
    imageNode.placeholderEnabled = YES;
    imageNode.placeholderColor = [UIColor tertiarySystemFillColor];

    ASTextNode *siteNode = [[textNodeClass alloc] init];
    ASTextNode *titleNode = [[textNodeClass alloc] init];
    ASTextNode *descriptionNode = [[textNodeClass alloc] init];
    siteNode.maximumNumberOfLines = 1;
    titleNode.maximumNumberOfLines = 3;
    descriptionNode.maximumNumberOfLines = 4;
    siteNode.truncationMode = NSLineBreakByTruncatingTail;
    titleNode.truncationMode = NSLineBreakByTruncatingTail;
    descriptionNode.truncationMode = NSLineBreakByTruncatingTail;
    siteNode.userInteractionEnabled = NO;
    titleNode.userInteractionEnabled = NO;
    descriptionNode.userInteractionEnabled = NO;

    ASDisplayNode *backgroundNode = [[displayNodeClass alloc] init];
    backgroundNode.backgroundColor = [UIColor secondarySystemBackgroundColor];
    backgroundNode.cornerRadius = 12.0;
    backgroundNode.clipsToBounds = YES;

    [hostNode addSubnode:imageNode];
    [hostNode addSubnode:siteNode];
    [hostNode addSubnode:titleNode];
    [hostNode addSubnode:descriptionNode];
    [hostNode addSubnode:backgroundNode];

    bundle = @{
        @"image": imageNode,
        @"site": siteNode,
        @"title": titleNode,
        @"description": descriptionNode,
        @"background": backgroundNode,
    };
    bundles[key] = bundle;
    return bundle;
}

static NSAttributedString *ApolloLPAttributedString(NSString *string, UIFont *font, UIColor *color) {
    if (string.length == 0) return nil;
    NSMutableParagraphStyle *style = [NSMutableParagraphStyle new];
    style.lineBreakMode = NSLineBreakByWordWrapping;
    NSDictionary *attrs = @{
        NSFontAttributeName: font,
        NSForegroundColorAttributeName: color,
        NSParagraphStyleAttributeName: style,
    };
    return [[NSAttributedString alloc] initWithString:string attributes:attrs];
}

static void ApolloLPApplyStyleSize(id style, CGSize size) {
    if (!style) return;
    @try {
        [style setValue:[NSValue valueWithCGSize:size] forKey:@"preferredSize"];
    } @catch (__unused NSException *exception) {
    }
}

static void ApolloLPClearStyleSize(id style) {
    if (!style) return;
    @try {
        [style setValue:nil forKey:@"preferredSize"];
    } @catch (__unused NSException *exception) {
        ApolloLPApplyStyleSize(style, CGSizeZero);
    }
}

static void ApolloLPClearHostShell(ASDisplayNode *node) {
    if (!node) return;

    NSDictionary *original = objc_getAssociatedObject(node, &kApolloLinkPreviewOriginalHostShellKey);
    if (!original) {
        original = @{
            @"background": node.backgroundColor ?: [NSNull null],
            @"cornerRadius": @(node.cornerRadius),
            @"clipsToBounds": @(node.clipsToBounds),
        };
        objc_setAssociatedObject(node, &kApolloLinkPreviewOriginalHostShellKey, original, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    node.backgroundColor = [UIColor clearColor];
    node.cornerRadius = 0.0;
    node.clipsToBounds = NO;
}

static void ApolloLPRestoreHostShell(ASDisplayNode *node) {
    if (!node) return;
    NSDictionary *original = objc_getAssociatedObject(node, &kApolloLinkPreviewOriginalHostShellKey);
    if (!original) return;

    id background = original[@"background"];
    node.backgroundColor = [background isKindOfClass:[NSNull class]] ? nil : background;
    node.cornerRadius = [original[@"cornerRadius"] doubleValue];
    node.clipsToBounds = [original[@"clipsToBounds"] boolValue];
}

typedef NS_ENUM(NSUInteger, ApolloLPContext) {
    ApolloLPContextCompact = 0,
    ApolloLPContextSelfText = 1,
};

static BOOL ApolloLPShouldForceHeroForURL(NSURL *url);

static BOOL ApolloLPModeEnabled(void) {
    return sLinkPreviewMode != ApolloLinkPreviewModeOff;
}

static ApolloLPContext ApolloLPContextForMode(NSURL *url, ApolloLPContext naturalContext, ApolloLinkPreview *preview) {
    if (sLinkPreviewMode == ApolloLinkPreviewModeCompact) return ApolloLPContextCompact;
    if (preview.imageIsFallbackIcon) return ApolloLPContextCompact;
    if (ApolloLPShouldForceHeroForURL(url)) return ApolloLPContextSelfText;
    return naturalContext;
}

static id ApolloLPModelFromNodeIvar(ASDisplayNode *node, const char *ivarName) {
    if (!node || !ivarName) return nil;
    Ivar ivar = class_getInstanceVariable([node class], ivarName);
    if (!ivar) return nil;

    id model = nil;
    @try {
        model = object_getIvar(node, ivar);
    } @catch (NSException *exception) {
        ApolloLog(@"[LinkPreviews] ivar read failed node=%@ ivar=%s err=%@",
                  NSStringFromClass([node class]), ivarName, exception.reason ?: exception.name);
    }
    return model;
}

static ApolloLPContext ApolloLPContextForLinkButton(ASDisplayNode *linkButtonNode) {
    for (ASDisplayNode *node = linkButtonNode; node; node = node.supernode) {
        id comment = ApolloLPModelFromNodeIvar(node, "comment");
        if (comment) return ApolloLPContextCompact;
    }
    return ApolloLPContextSelfText;
}

// Some hosts always look better as a hero (large thumbnail on top) regardless
// of whether the link lives in a comment or a post body. YouTube is the
// obvious case: a tiny 84pt thumb with a play overlay buries the actual
// video, while the hero treatment gives the viewer the same big preview card
// they'd get on the web.
static BOOL ApolloLPShouldForceHeroForURL(NSURL *url) {
    if (!url) return NO;
    NSString *host = url.host.lowercaseString ?: @"";
    if ([host hasPrefix:@"www."]) host = [host substringFromIndex:4];
    if ([host hasPrefix:@"m."]) host = [host substringFromIndex:2];
    static NSArray<NSString *> *hosts;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        hosts = @[@"youtube.com", @"youtu.be", @"music.youtube.com"];
    });
    for (NSString *match in hosts) {
        if ([host isEqualToString:match] || [host hasSuffix:[@"." stringByAppendingString:match]]) {
            return YES;
        }
    }
    return NO;
}

static NSDictionary *ApolloLPPreparedNodeBundle(ASDisplayNode *hostNode, NSURL *url, ApolloLinkPreview *preview, NSString *variant) {
    NSDictionary *bundle = ApolloLPNodeBundleForHost(hostNode, url, variant);
    if (!bundle) return nil;

    ASNetworkImageNode *imageNode = bundle[@"image"];
    ASTextNode *siteNode = bundle[@"site"];
    ASTextNode *titleNode = bundle[@"title"];
    ASTextNode *descriptionNode = bundle[@"description"];
    ASDisplayNode *backgroundNode = bundle[@"background"];

    NSString *siteName = preview.siteName.length > 0 ? preview.siteName : ApolloLPHost(url);
    imageNode.URL = preview.imageURL;
    imageNode.backgroundColor = preview.imageURL.absoluteString.length > 0 ? nil : [UIColor tertiarySystemFillColor];
    siteNode.attributedText = ApolloLPAttributedString([siteName uppercaseString], [UIFont systemFontOfSize:11.0 weight:UIFontWeightSemibold], [UIColor secondaryLabelColor]);
    titleNode.attributedText = ApolloLPAttributedString(preview.title, [UIFont systemFontOfSize:15.0 weight:UIFontWeightSemibold], [UIColor labelColor]);
    descriptionNode.attributedText = ApolloLPAttributedString(preview.desc, [UIFont systemFontOfSize:13.0 weight:UIFontWeightRegular], [UIColor secondaryLabelColor]);
    backgroundNode.backgroundColor = [UIColor secondarySystemBackgroundColor];

    return bundle;
}

static id ApolloLPBackgroundWrappedSpec(id contentSpec, ASDisplayNode *backgroundNode, Class backgroundClass) {
    if (backgroundClass && [backgroundClass respondsToSelector:@selector(backgroundLayoutSpecWithChild:background:)]) {
        return [backgroundClass backgroundLayoutSpecWithChild:contentSpec background:backgroundNode];
    }
    return contentSpec;
}

static id ApolloLPBuildCompactCardSpec(ASDisplayNode *hostNode, NSURL *url, ApolloLinkPreview *preview) {
    NSDictionary *bundle = ApolloLPPreparedNodeBundle(hostNode, url, preview, @"compact");
    if (!bundle) return nil;

    ASNetworkImageNode *imageNode = bundle[@"image"];
    ASTextNode *siteNode = bundle[@"site"];
    ASTextNode *titleNode = bundle[@"title"];
    ASTextNode *descriptionNode = bundle[@"description"];
    ASDisplayNode *backgroundNode = bundle[@"background"];

    Class stackClass = ApolloLPClass(@"ASStackLayoutSpec");
    Class insetClass = ApolloLPClass(@"ASInsetLayoutSpec");
    Class backgroundClass = ApolloLPClass(@"ASBackgroundLayoutSpec");
    if (!stackClass || !insetClass) return nil;

    imageNode.cornerRadius = 8.0;
    ApolloLPClearStyleSize([imageNode style]);
    titleNode.maximumNumberOfLines = 3;
    descriptionNode.maximumNumberOfLines = 5;
    backgroundNode.backgroundColor = [UIColor secondarySystemBackgroundColor];
    backgroundNode.cornerRadius = 10.0;
    backgroundNode.clipsToBounds = YES;

    NSMutableArray *textChildren = [NSMutableArray array];
    if (siteNode.attributedText.length > 0) [textChildren addObject:siteNode];
    if (titleNode.attributedText.length > 0) [textChildren addObject:titleNode];
    if (descriptionNode.attributedText.length > 0) [textChildren addObject:descriptionNode];
    if (textChildren.count == 0) return nil;

    ASStackLayoutSpec *textStack = [stackClass stackLayoutSpecWithDirection:ApolloLinkPreviewStackDirectionVertical
                                                                    spacing:3.0
                                                             justifyContent:ApolloLinkPreviewStackJustifyContentStart
                                                                 alignItems:ApolloLinkPreviewStackAlignItemsStretch
                                                                   children:textChildren];
    [[textStack style] setValue:@1.0 forKey:@"flexGrow"];
    [[textStack style] setValue:@1.0 forKey:@"flexShrink"];

    NSMutableArray *rowChildren = [NSMutableArray array];
    if (preview.imageURL.absoluteString.length > 0) {
        imageNode.contentMode = UIViewContentModeScaleAspectFill;
        imageNode.cornerRadius = 8.0;
        ApolloLPApplyStyleSize([imageNode style], CGSizeMake(84.0, 84.0));
        [rowChildren addObject:imageNode];
    }
    [rowChildren addObject:textStack];

    ASStackLayoutSpec *row = [stackClass stackLayoutSpecWithDirection:ApolloLinkPreviewStackDirectionHorizontal
                                                              spacing:10.0
                                                       justifyContent:ApolloLinkPreviewStackJustifyContentStart
                                                           alignItems:ApolloLinkPreviewStackAlignItemsStart
                                                             children:rowChildren];
    ASInsetLayoutSpec *contentInset = [insetClass insetLayoutSpecWithInsets:UIEdgeInsetsMake(10.0, 10.0, 10.0, 10.0) child:row];
    id card = ApolloLPBackgroundWrappedSpec(contentInset, backgroundNode, backgroundClass);
    return [insetClass insetLayoutSpecWithInsets:UIEdgeInsetsMake(4.0, 0.0, 4.0, 0.0) child:card];
}

static id ApolloLPBuildHeroCardSpec(ASDisplayNode *hostNode, NSURL *url, ApolloLinkPreview *preview) {
    NSDictionary *bundle = ApolloLPPreparedNodeBundle(hostNode, url, preview, @"hero");
    if (!bundle) return nil;

    ASNetworkImageNode *imageNode = bundle[@"image"];
    ASTextNode *siteNode = bundle[@"site"];
    ASTextNode *titleNode = bundle[@"title"];
    ASTextNode *descriptionNode = bundle[@"description"];
    ASDisplayNode *backgroundNode = bundle[@"background"];

    Class stackClass = ApolloLPClass(@"ASStackLayoutSpec");
    Class insetClass = ApolloLPClass(@"ASInsetLayoutSpec");
    Class ratioClass = ApolloLPClass(@"ASRatioLayoutSpec");
    Class backgroundClass = ApolloLPClass(@"ASBackgroundLayoutSpec");
    if (!stackClass || !insetClass) return nil;

    imageNode.cornerRadius = 10.0;
    imageNode.contentMode = UIViewContentModeScaleAspectFill;
    ApolloLPClearStyleSize([imageNode style]);
    BOOL isYouTube = ApolloLPShouldForceHeroForURL(url);
    titleNode.maximumNumberOfLines = isYouTube ? 3 : 4;
    descriptionNode.maximumNumberOfLines = isYouTube ? 2 : 4;
    titleNode.attributedText = ApolloLPAttributedString(preview.title, [UIFont systemFontOfSize:17.0 weight:UIFontWeightSemibold], [UIColor labelColor]);
    backgroundNode.backgroundColor = [UIColor secondarySystemBackgroundColor];
    backgroundNode.cornerRadius = 10.0;
    backgroundNode.clipsToBounds = YES;

    NSMutableArray *textChildren = [NSMutableArray array];
    if (siteNode.attributedText.length > 0) [textChildren addObject:siteNode];
    if (titleNode.attributedText.length > 0) [textChildren addObject:titleNode];
    if (descriptionNode.attributedText.length > 0) [textChildren addObject:descriptionNode];
    if (textChildren.count == 0) return nil;

    NSMutableArray *cardChildren = [NSMutableArray array];
    if (preview.imageURL.absoluteString.length > 0 && ratioClass) {
        CGFloat ratio = 9.0 / 16.0;
        CGSize imageSize = preview.imageSize;
        if (!isYouTube && imageSize.width > 1.0 && imageSize.height > 1.0) {
            CGFloat naturalRatio = imageSize.height / imageSize.width;
            ratio = MAX(MIN(naturalRatio, 1.0), 0.45);
        }

        [cardChildren addObject:[ratioClass ratioLayoutSpecWithRatio:ratio child:imageNode]];
    }

    ASStackLayoutSpec *textStack = [stackClass stackLayoutSpecWithDirection:ApolloLinkPreviewStackDirectionVertical
                                                                    spacing:4.0
                                                             justifyContent:ApolloLinkPreviewStackJustifyContentStart
                                                                 alignItems:ApolloLinkPreviewStackAlignItemsStretch
                                                                   children:textChildren];
    // 12pt left/right/bottom inset keeps site/title/description from sitting
    // flush against the screen edges underneath the image.
    UIEdgeInsets textInsets = isYouTube ? UIEdgeInsetsMake(8.0, 12.0, 10.0, 12.0) : UIEdgeInsetsMake(10.0, 12.0, 12.0, 12.0);
    ASInsetLayoutSpec *paddedText = [insetClass insetLayoutSpecWithInsets:textInsets child:textStack];
    [cardChildren addObject:paddedText];

    ASStackLayoutSpec *cardStack = [stackClass stackLayoutSpecWithDirection:ApolloLinkPreviewStackDirectionVertical
                                                                    spacing:0.0
                                                             justifyContent:ApolloLinkPreviewStackJustifyContentStart
                                                                 alignItems:ApolloLinkPreviewStackAlignItemsStretch
                                                                   children:cardChildren];
    id card = ApolloLPBackgroundWrappedSpec(cardStack, backgroundNode, backgroundClass);
    return [insetClass insetLayoutSpecWithInsets:UIEdgeInsetsMake(6.0, 0.0, 6.0, 0.0) child:card];
}

static id ApolloLPBuildPlaceholderSpec(ASDisplayNode *hostNode, NSURL *url, ApolloLPContext context) {
    ApolloLinkPreview *preview = [ApolloLinkPreview new];
    preview.siteName = ApolloLPHost(url);
    preview.title = @" ";
    preview.desc = context == ApolloLPContextSelfText ? @" " : nil;

    NSDictionary *bundle = ApolloLPPreparedNodeBundle(hostNode, url, preview, context == ApolloLPContextSelfText ? @"placeholder-hero" : @"placeholder-compact");
    if (!bundle) return nil;

    ASNetworkImageNode *imageNode = bundle[@"image"];
    ASTextNode *siteNode = bundle[@"site"];
    ASTextNode *titleNode = bundle[@"title"];
    ASTextNode *descriptionNode = bundle[@"description"];
    ASDisplayNode *backgroundNode = bundle[@"background"];

    Class stackClass = ApolloLPClass(@"ASStackLayoutSpec");
    Class insetClass = ApolloLPClass(@"ASInsetLayoutSpec");
    Class ratioClass = ApolloLPClass(@"ASRatioLayoutSpec");
    Class backgroundClass = ApolloLPClass(@"ASBackgroundLayoutSpec");
    if (!stackClass || !insetClass) return nil;

    UIColor *placeholder = [UIColor tertiarySystemFillColor];
    imageNode.URL = nil;
    imageNode.backgroundColor = placeholder;
    imageNode.cornerRadius = context == ApolloLPContextSelfText ? 10.0 : 8.0;
    siteNode.attributedText = ApolloLPAttributedString([preview.siteName uppercaseString], [UIFont systemFontOfSize:11.0 weight:UIFontWeightSemibold], [UIColor secondaryLabelColor]);
    titleNode.attributedText = ApolloLPAttributedString(@"     ", [UIFont systemFontOfSize:15.0 weight:UIFontWeightSemibold], placeholder);
    descriptionNode.attributedText = ApolloLPAttributedString(@"          ", [UIFont systemFontOfSize:13.0 weight:UIFontWeightRegular], placeholder);

    if (context == ApolloLPContextSelfText && ratioClass) {
        NSMutableArray *children = [NSMutableArray array];
        ApolloLPClearStyleSize([imageNode style]);
        [children addObject:[ratioClass ratioLayoutSpecWithRatio:9.0 / 16.0 child:imageNode]];

        ASStackLayoutSpec *textStack = [stackClass stackLayoutSpecWithDirection:ApolloLinkPreviewStackDirectionVertical
                                                                        spacing:4.0
                                                                 justifyContent:ApolloLinkPreviewStackJustifyContentStart
                                                                     alignItems:ApolloLinkPreviewStackAlignItemsStretch
                                                                       children:@[siteNode, titleNode, descriptionNode]];
        [children addObject:[insetClass insetLayoutSpecWithInsets:UIEdgeInsetsMake(8.0, 12.0, 10.0, 12.0) child:textStack]];

        ASStackLayoutSpec *cardStack = [stackClass stackLayoutSpecWithDirection:ApolloLinkPreviewStackDirectionVertical
                                                                        spacing:0.0
                                                                 justifyContent:ApolloLinkPreviewStackJustifyContentStart
                                                                     alignItems:ApolloLinkPreviewStackAlignItemsStretch
                                                                       children:children];
        backgroundNode.backgroundColor = [UIColor secondarySystemBackgroundColor];
        backgroundNode.cornerRadius = 10.0;
        backgroundNode.clipsToBounds = YES;
        id card = ApolloLPBackgroundWrappedSpec(cardStack, backgroundNode, backgroundClass);
        return [insetClass insetLayoutSpecWithInsets:UIEdgeInsetsMake(6.0, 0.0, 6.0, 0.0) child:card];
    }

    ApolloLPApplyStyleSize([imageNode style], CGSizeMake(84.0, 84.0));
    titleNode.maximumNumberOfLines = 1;
    ASStackLayoutSpec *textStack = [stackClass stackLayoutSpecWithDirection:ApolloLinkPreviewStackDirectionVertical
                                                                    spacing:3.0
                                                             justifyContent:ApolloLinkPreviewStackJustifyContentStart
                                                                 alignItems:ApolloLinkPreviewStackAlignItemsStretch
                                                                   children:@[siteNode, titleNode]];
    [[textStack style] setValue:@1.0 forKey:@"flexGrow"];
    [[textStack style] setValue:@1.0 forKey:@"flexShrink"];
    ASStackLayoutSpec *row = [stackClass stackLayoutSpecWithDirection:ApolloLinkPreviewStackDirectionHorizontal
                                                              spacing:10.0
                                                       justifyContent:ApolloLinkPreviewStackJustifyContentStart
                                                           alignItems:ApolloLinkPreviewStackAlignItemsStart
                                                             children:@[imageNode, textStack]];
    backgroundNode.backgroundColor = [UIColor secondarySystemBackgroundColor];
    backgroundNode.cornerRadius = 10.0;
    backgroundNode.clipsToBounds = YES;
    id card = ApolloLPBackgroundWrappedSpec([insetClass insetLayoutSpecWithInsets:UIEdgeInsetsMake(10.0, 10.0, 10.0, 10.0) child:row], backgroundNode, backgroundClass);
    return [insetClass insetLayoutSpecWithInsets:UIEdgeInsetsMake(4.0, 0.0, 4.0, 0.0) child:card];
}

static void ApolloLPTriggerRelayout(ASDisplayNode *node) {
    SEL invalidate = @selector(invalidateCalculatedLayout);
    if ([node respondsToSelector:invalidate]) {
        ((void (*)(id, SEL))objc_msgSend)(node, invalidate);
    }

    SEL relayout = NSSelectorFromString(@"_u_setNeedsLayoutFromAbove");
    if ([node respondsToSelector:relayout]) {
        ((void (*)(id, SEL))objc_msgSend)(node, relayout);
    }
}

// Round 4 diagnostic flag: throttles the per-call logging so a feed scroll
// doesn't spam OSLog with the same host hundreds of times. We still want one
// entry per unique host per session so we can correlate hook activity with
// the user's screenshots.
static NSMutableSet<NSString *> *ApolloLPLoggedHosts(void) {
    static NSMutableSet *set;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ set = [NSMutableSet set]; });
    return set;
}

static void ApolloLPLogOncePerHost(NSString *host, NSString *event) {
    if (host.length == 0) host = @"(nohost)";
    NSString *key = [NSString stringWithFormat:@"%@|%@", host, event];
    @synchronized (ApolloLPLoggedHosts()) {
        if ([ApolloLPLoggedHosts() containsObject:key]) return;
        [ApolloLPLoggedHosts() addObject:key];
    }
    ApolloLog(@"[LinkPreviews] %@ host=%@", event, host);
}

%hook _TtC6Apollo14LinkButtonNode

- (id)layoutSpecThatFits:(struct CDStruct_90e057aa)constrainedSize {
    if (!ApolloLPModeEnabled()) {
        ApolloLPLogOncePerHost(@"(any)", @"hook-disabled");
        ApolloLPRestoreHostShell((ASDisplayNode *)self);
        return %orig;
    }

    NSString *urlString = ApolloGetLinkButtonNodeURLString(self);
    NSURL *url = urlString.length > 0 ? [NSURL URLWithString:urlString] : nil;
    if (!url) {
        ApolloLPLogOncePerHost(NSStringFromClass([(id)self class]), @"no-url");
        ApolloLPRestoreHostShell((ASDisplayNode *)self);
        return %orig;
    }

    NSString *host = ApolloLPHost(url);

    if (ApolloLPShouldDeferToInlineMedia(url)) {
        ApolloLPLogOncePerHost(host, @"defer-inline-media");
        ApolloLPRestoreHostShell((ASDisplayNode *)self);
        return %orig;
    }
    if ([ApolloLinkPreviewFetcher isTwitterURL:url]) {
        ApolloLPLogOncePerHost(host, @"defer-twitter");
        ApolloLPRestoreHostShell((ASDisplayNode *)self);
        return %orig;
    }

    ApolloLinkPreview *cached = [[ApolloLinkPreviewCache sharedCache] cachedPreviewForURL:url];
    if (!cached) {
        ApolloLPContext placeholderContext = ApolloLPContextForMode(url, ApolloLPContextForLinkButton((ASDisplayNode *)self), [ApolloLinkPreview new]);
        NSNumber *inFlight = objc_getAssociatedObject(self, &kApolloLinkPreviewFetchInFlightKey);
        if (![inFlight boolValue]) {
            ApolloLPLogOncePerHost(host, @"cache-miss-fetch");
            objc_setAssociatedObject(self, &kApolloLinkPreviewFetchInFlightKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            __weak ASDisplayNode *weakSelf = (ASDisplayNode *)self;
            [ApolloLinkPreviewFetcher requestPreviewForURL:url completion:^(__unused ApolloLinkPreview *preview) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    ASDisplayNode *strongSelf = weakSelf;
                    if (!strongSelf) return;
                    objc_setAssociatedObject(strongSelf, &kApolloLinkPreviewFetchInFlightKey, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                    ApolloLPTriggerRelayout(strongSelf);
                });
            }];
        }
        id placeholder = ApolloLPBuildPlaceholderSpec((ASDisplayNode *)self, url, placeholderContext);
        if (placeholder) {
            ApolloLPClearHostShell((ASDisplayNode *)self);
            ApolloLPLogOncePerHost(host, placeholderContext == ApolloLPContextSelfText ? @"context-full-placeholder" : @"context-compact-placeholder");
            ApolloLPLogOncePerHost(host, placeholderContext == ApolloLPContextSelfText ? @"render-hero-placeholder" : @"render-compact-placeholder");
            return placeholder;
        }
        ApolloLPRestoreHostShell((ASDisplayNode *)self);
        return %orig;
    }

    if (![cached hasUsefulMetadata]) {
        ApolloLPLogOncePerHost(host, @"cache-hit-empty");
        ApolloLPRestoreHostShell((ASDisplayNode *)self);
        return %orig;
    }

    ApolloLPContext context = ApolloLPContextForMode(url, ApolloLPContextForLinkButton((ASDisplayNode *)self), cached);
    if (cached.imageIsFallbackIcon) {
        ApolloLPLogOncePerHost(host, @"fallback-icon-compact");
    } else if (ApolloLPShouldForceHeroForURL(url) && sLinkPreviewMode == ApolloLinkPreviewModeFull) {
        if (cached.imageURL.absoluteString.length == 0) {
            ApolloLPLogOncePerHost(host, @"force-hero-missing-image");
            ApolloLPRestoreHostShell((ASDisplayNode *)self);
            return %orig;
        }
    }
    id richSpec = (context == ApolloLPContextSelfText)
        ? ApolloLPBuildHeroCardSpec((ASDisplayNode *)self, url, cached)
        : ApolloLPBuildCompactCardSpec((ASDisplayNode *)self, url, cached);
    if (richSpec) {
        ApolloLPClearHostShell((ASDisplayNode *)self);
        ApolloLPLogOncePerHost(host, context == ApolloLPContextSelfText ? @"context-full" : @"context-compact");
        ApolloLPLogOncePerHost(host, context == ApolloLPContextSelfText ? @"render-hero" : @"render-compact");
        return richSpec;
    }
    ApolloLPLogOncePerHost(host, @"build-failed");
    ApolloLPRestoreHostShell((ASDisplayNode *)self);
    return %orig;
}

%end

%ctor {
    ApolloLog(@"[LinkPreviews] ctor: hook installed for _TtC6Apollo14LinkButtonNode mode=%ld", (long)sLinkPreviewMode);
    ApolloLog(@"[LinkPreviews] V5 polish active");
    ApolloLog(@"[LinkPreviews] V6 image-kind polish active");
    ApolloLog(@"[LinkPreviews] V7 display modes and placeholders active");
    ApolloLog(@"[LinkPreviews] V8 borderless cards active");
}

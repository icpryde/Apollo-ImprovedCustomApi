#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CoreImage/CoreImage.h>
#import <objc/message.h>
#import <objc/runtime.h>

#import "ApolloCommon.h"
#import "ApolloState.h"
#import "Tweak.h"

// Minimal AsyncDisplayKit forward decl — same shape as ApolloTagFilters.xm uses.
@interface ApolloFeedThumbDisplayNode : UIResponder
@property (nonatomic, readonly, nullable) UIView *view;
@property (nonatomic, readonly) BOOL isNodeLoaded;
@property (nonatomic, getter=isHidden) BOOL hidden;
- (void)setNeedsLayout;
@end

static NSString *ApolloFeedThumbDecodeEntities(NSString *string) {
    if (![string isKindOfClass:[NSString class]] || string.length == 0) return string;
    NSString *decoded = [string stringByReplacingOccurrencesOfString:@"&amp;" withString:@"&"];
    decoded = [decoded stringByReplacingOccurrencesOfString:@"&quot;" withString:@"\""];
    decoded = [decoded stringByReplacingOccurrencesOfString:@"&#39;" withString:@"'"];
    decoded = [decoded stringByReplacingOccurrencesOfString:@"&#x27;" withString:@"'"];
    decoded = [decoded stringByReplacingOccurrencesOfString:@"&lt;" withString:@"<"];
    decoded = [decoded stringByReplacingOccurrencesOfString:@"&gt;" withString:@">"];
    return decoded;
}

static NSURL *ApolloFeedThumbURLFromString(NSString *string) {
    if (![string isKindOfClass:[NSString class]] || string.length == 0) return nil;
    NSString *decoded = ApolloFeedThumbDecodeEntities(string);
    NSURL *url = [NSURL URLWithString:decoded];
    NSString *scheme = url.scheme.lowercaseString;
    if (![scheme isEqualToString:@"http"] && ![scheme isEqualToString:@"https"]) return nil;
    return url;
}

static BOOL ApolloFeedThumbURLIsUsable(NSURL *url) {
    if (![url isKindOfClass:[NSURL class]]) return NO;
    NSString *scheme = url.scheme.lowercaseString;
    if (![scheme isEqualToString:@"http"] && ![scheme isEqualToString:@"https"]) return NO;
    NSString *absolute = url.absoluteString.lowercaseString;
    if (absolute.length == 0) return NO;
    static NSSet<NSString *> *placeholders;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        placeholders = [NSSet setWithArray:@[@"self", @"default", @"nsfw", @"spoiler", @"image", @""]];
    });
    return ![placeholders containsObject:absolute];
}

static NSURL *ApolloFeedThumbURLFromPreviewItem(id item) {
    if (!item) return nil;

    @try {
        if ([item respondsToSelector:@selector(URL)]) {
            NSURL *url = ((NSURL *(*)(id, SEL))objc_msgSend)(item, @selector(URL));
            if (ApolloFeedThumbURLIsUsable(url)) return url;
        }
    } @catch (__unused NSException *exception) {}

    if ([item isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = (NSDictionary *)item;
        for (NSString *key in @[@"url", @"u"]) {
            NSURL *url = ApolloFeedThumbURLFromString(dict[key]);
            if (url) return url;
        }
    }

    return nil;
}

static NSURL *ApolloFeedThumbURLFromPreviewMedia(RDKLinkPreviewMedia *previewMedia) {
    Class previewMediaClass = objc_getClass("RDKLinkPreviewMedia");
    if (!previewMediaClass || ![(id)previewMedia isKindOfClass:previewMediaClass]) return nil;

    NSURL *sourceURL = nil;
    @try { sourceURL = previewMedia.sourceImage.URL; } @catch (__unused NSException *exception) {}
    if (ApolloFeedThumbURLIsUsable(sourceURL)) return sourceURL;

    NSArray *images = nil;
    @try { images = previewMedia.images; } @catch (__unused NSException *exception) {}
    if (![images isKindOfClass:[NSArray class]]) return nil;

    NSURL *fallbackURL = nil;
    CGFloat fallbackDelta = CGFLOAT_MAX;
    for (id item in images) {
        NSURL *url = ApolloFeedThumbURLFromPreviewItem(item);
        if (!url) continue;
        if (!fallbackURL) fallbackURL = url;

        double width = 0;
        @try {
            if ([item respondsToSelector:@selector(width)]) {
                width = ((double (*)(id, SEL))objc_msgSend)(item, @selector(width));
            } else if ([item isKindOfClass:[NSDictionary class]] && [item[@"width"] respondsToSelector:@selector(doubleValue)]) {
                width = [item[@"width"] doubleValue];
            }
        } @catch (__unused NSException *exception) {}

        if (width > 0) {
            CGFloat delta = fabs(width - 320.0);
            if (delta < fallbackDelta) {
                fallbackDelta = delta;
                fallbackURL = url;
            }
        }
    }

    return fallbackURL;
}

static NSURL *ApolloFeedThumbURLFromMediaMetadataEntry(NSDictionary *entry) {
    if (![entry isKindOfClass:[NSDictionary class]]) return nil;
    NSString *status = entry[@"status"];
    if ([status isKindOfClass:[NSString class]] && ![status isEqualToString:@"valid"]) return nil;

    NSString *kind = entry[@"e"];
    if ([kind isKindOfClass:[NSString class]] && kind.length > 0) {
        NSString *lowerKind = kind.lowercaseString;
        if (![lowerKind containsString:@"image"]) return nil;
    }

    NSArray *previews = entry[@"p"];
    NSURL *fallbackURL = nil;
    CGFloat fallbackDelta = CGFLOAT_MAX;
    if ([previews isKindOfClass:[NSArray class]]) {
        for (id preview in previews) {
            if (![preview isKindOfClass:[NSDictionary class]]) continue;
            NSDictionary *previewDict = (NSDictionary *)preview;
            NSURL *url = ApolloFeedThumbURLFromString(previewDict[@"u"]);
            if (!url) continue;
            if (!fallbackURL) fallbackURL = url;

            NSNumber *widthNumber = [previewDict[@"x"] respondsToSelector:@selector(doubleValue)] ? previewDict[@"x"] : nil;
            CGFloat delta = widthNumber ? fabs(widthNumber.doubleValue - 320.0) : CGFLOAT_MAX;
            if (delta < fallbackDelta) {
                fallbackDelta = delta;
                fallbackURL = url;
            }
        }
    }
    if (fallbackURL) return fallbackURL;

    NSDictionary *source = entry[@"s"];
    if ([source isKindOfClass:[NSDictionary class]]) {
        for (NSString *key in @[@"u", @"gif"]) {
            NSURL *url = ApolloFeedThumbURLFromString(source[key]);
            if (url) return url;
        }
    }

    return nil;
}

static NSURL *ApolloFeedThumbURLFromMediaMetadata(RDKLink *link) {
    NSDictionary *metadata = nil;
    @try { metadata = link.mediaMetadata; } @catch (__unused NSException *exception) {}
    if (![metadata isKindOfClass:[NSDictionary class]] || metadata.count == 0) return nil;

    for (id key in metadata) {
        NSURL *url = ApolloFeedThumbURLFromMediaMetadataEntry(metadata[key]);
        if (url) return url;
    }

    return nil;
}

static BOOL ApolloFeedThumbIsDirectImageURL(NSURL *url) {
    if (!ApolloFeedThumbURLIsUsable(url)) return NO;
    NSString *host = url.host.lowercaseString;
    NSString *extension = url.pathExtension.lowercaseString;
    static NSSet<NSString *> *imageExtensions;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        imageExtensions = [NSSet setWithArray:@[@"jpg", @"jpeg", @"png", @"webp", @"gif"]];
    });

    if ([host isEqualToString:@"i.redd.it"] || [host isEqualToString:@"preview.redd.it"] || [host isEqualToString:@"i.imgur.com"]) {
        return [imageExtensions containsObject:extension];
    }
    return NO;
}

static NSString *ApolloFeedThumbYouTubeID(NSURL *url) {
    if (!ApolloFeedThumbURLIsUsable(url)) return nil;
    NSString *host = url.host.lowercaseString;
    NSArray<NSString *> *parts = [url.path componentsSeparatedByString:@"/"];

    NSString *candidate = nil;
    if ([host isEqualToString:@"youtu.be"] || [host hasSuffix:@".youtu.be"]) {
        for (NSString *part in parts) {
            if (part.length > 0) {
                candidate = part;
                break;
            }
        }
    } else if ([host isEqualToString:@"youtube.com"] || [host hasSuffix:@".youtube.com"] || [host hasSuffix:@".youtube-nocookie.com"]) {
        NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
        for (NSURLQueryItem *item in components.queryItems) {
            if ([item.name isEqualToString:@"v"] && item.value.length > 0) {
                candidate = item.value;
                break;
            }
        }
        if (!candidate) {
            for (NSUInteger index = 0; index + 1 < parts.count; index++) {
                NSString *part = parts[index];
                if ([part isEqualToString:@"shorts"] || [part isEqualToString:@"embed"] || [part isEqualToString:@"v"]) {
                    candidate = parts[index + 1];
                    break;
                }
            }
        }
    }

    if (![candidate isKindOfClass:[NSString class]] || candidate.length < 6 || candidate.length > 32) return nil;
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-"];
    return ([candidate rangeOfCharacterFromSet:allowed.invertedSet].location == NSNotFound) ? candidate : nil;
}

static NSURL *ApolloFeedThumbURLFromDirectLink(RDKLink *link) {
    NSURL *linkURL = nil;
    @try { linkURL = link.URL; } @catch (__unused NSException *exception) {}
    if (ApolloFeedThumbIsDirectImageURL(linkURL)) return linkURL;

    NSString *youtubeID = ApolloFeedThumbYouTubeID(linkURL);
    if (youtubeID.length > 0) {
        return [NSURL URLWithString:[NSString stringWithFormat:@"https://i.ytimg.com/vi/%@/hqdefault.jpg", youtubeID]];
    }

    return nil;
}

static NSString *ApolloFeedThumbLogKeyForLink(RDKLink *link, NSString *source) {
    NSString *fullName = nil;
    @try { fullName = link.fullName; } @catch (__unused NSException *exception) {}
    if (fullName.length == 0) fullName = [NSString stringWithFormat:@"%p", link];
    return [NSString stringWithFormat:@"%@|%@", fullName, source ?: @"none"];
}

static NSMutableSet<NSString *> *ApolloFeedThumbLoggedKeys(void) {
    static NSMutableSet<NSString *> *keys;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        keys = [NSMutableSet set];
    });
    return keys;
}

static void ApolloFeedThumbLogOnce(RDKLink *link, NSString *source, NSURL *url) {
    NSString *key = ApolloFeedThumbLogKeyForLink(link, source);
    @synchronized (ApolloFeedThumbLoggedKeys()) {
        if ([ApolloFeedThumbLoggedKeys() containsObject:key]) return;
        [ApolloFeedThumbLoggedKeys() addObject:key];
    }

    NSString *subreddit = nil;
    NSString *title = nil;
    @try { subreddit = link.subreddit; } @catch (__unused NSException *exception) {}
    @try { title = link.title; } @catch (__unused NSException *exception) {}
    ApolloLog(@"[FeedThumbs] %@ fallback for r/%@ title='%@' url=%@",
              source ?: @"unknown", subreddit ?: @"?", title ?: @"?", url.absoluteString ?: @"nil");
}

static NSURL *ApolloFeedThumbCachedVRedditPreview(RDKLink *link);
static void ApolloFeedThumbKickVRedditFetch(RDKLink *link);

static NSURL *ApolloFeedThumbFallbackURLForLink(RDKLink *link, NSString **outSource) {
    Class linkClass = objc_getClass("RDKLink");
    if (!linkClass || ![(id)link isKindOfClass:linkClass]) return nil;

    // Note: NSFW/spoiler are NOT skipped here. The cell-level apply layer
    // renders a gaussian-blurred version of the loaded image for these posts,
    // mimicking Apollo's native spoiler/NSFW thumbnail blur, which Apollo
    // can't apply itself when Reddit returns an empty/placeholder thumbnail.

    RDKLinkPreviewMedia *previewMedia = nil;
    @try { previewMedia = link.previewMedia; } @catch (__unused NSException *exception) {}
    NSURL *url = ApolloFeedThumbURLFromPreviewMedia(previewMedia);
    if (url) {
        if (outSource) *outSource = @"previewMedia";
        return url;
    }

    url = ApolloFeedThumbURLFromDirectLink(link);
    if (url) {
        if (outSource) *outSource = @"direct";
        return url;
    }

    url = ApolloFeedThumbURLFromMediaMetadata(link);
    if (url) {
        if (outSource) *outSource = @"mediaMetadata";
        return url;
    }

    // Last resort: v.redd.it / crosspost-video posts whose previewMedia hasn't
    // been populated by Apollo yet. We synchronously check our async fetch cache
    // and (if missing) kick off a fetch that will post a notification on success.
    NSURL *cached = ApolloFeedThumbCachedVRedditPreview(link);
    if (cached) {
        if (outSource) *outSource = @"vredditCache";
        return cached;
    }
    ApolloFeedThumbKickVRedditFetch(link);

    return nil;
}

// MARK: - Cell-level injection
//
// Apollo's feed cells (Large/Compact PostCellNode) do NOT consume
// `-[RDKLink thumbnailURL]` — proven on-device. So we attach a UIImageView
// directly to the cell's `thumbnailNode.view` whenever Reddit gives Apollo
// an unusable native thumbnail but the link model still contains enough media
// metadata to recover a preview image.

static const void *kFeedThumbImageViewKey   = &kFeedThumbImageViewKey;   // UIImageView *
static const void *kFeedThumbBlurViewKey    = &kFeedThumbBlurViewKey;    // UIVisualEffectView * (legacy, no longer used)
static const void *kFeedThumbPlayBadgeKey   = &kFeedThumbPlayBadgeKey;   // UIImageView * (play.fill SF Symbol)
static const void *kFeedThumbCurrentURLKey  = &kFeedThumbCurrentURLKey;  // NSURL *
static const void *kFeedThumbCurrentTaskKey = &kFeedThumbCurrentTaskKey; // NSURLSessionDataTask *
static const void *kFeedThumbCurrentLinkIDKey = &kFeedThumbCurrentLinkIDKey; // NSString *
static const void *kFeedThumbLastAppliedLinkPtrKey = &kFeedThumbLastAppliedLinkPtrKey; // NSValue *
static const void *kFeedThumbLastAppliedSizeKey = &kFeedThumbLastAppliedSizeKey; // NSValue(CGSize)

NSString *const ApolloFeedThumbsLinkUpdatedNotification = @"ApolloFeedThumbsLinkUpdatedNotification";
static NSString *const kApolloFeedThumbsLinkPointerKey = @"linkPointer";

// MARK: - v.redd.it preview-image fetch
//
// Reddit's listing JSON for v.redd.it posts includes a still preview image
// (preview.images[0].source.url), but Apollo doesn't populate
// `RDKLink.previewMedia` for these posts until the user enters the post
// detail view. We bridge that gap by issuing one authenticated /api/info
// request per post (using the bearer token captured by ApolloImageUploadHost),
// caching the resolved URL by fullName, and posting the standard
// "link updated" notification so the cell-apply observer reapplies.

static NSCache<NSString *, NSURL *> *ApolloFeedThumbVRedditCache(void) {
    static NSCache<NSString *, NSURL *> *cache;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [[NSCache alloc] init];
        cache.countLimit = 512;
    });
    return cache;
}

static NSMutableSet<NSString *> *ApolloFeedThumbVRedditInFlight(void) {
    static NSMutableSet<NSString *> *set;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ set = [NSMutableSet set]; });
    return set;
}

static NSMutableSet<NSString *> *ApolloFeedThumbVRedditFailed(void) {
    static NSMutableSet<NSString *> *set;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ set = [NSMutableSet set]; });
    return set;
}

static BOOL ApolloFeedThumbLinkLooksLikeRedditVideo(RDKLink *link) {
    if (!link) return NO;
    NSURL *url = nil;
    @try { url = link.URL; } @catch (__unused id e) {}
    NSString *host = url.host.lowercaseString;
    if ([host isEqualToString:@"v.redd.it"]) return YES;
    // Crossposts and reddit.com/.../comments/ links fall through to detailed
    // fetch via thumbnailURL/previewMedia normally; only chase v.redd.it here.
    return NO;
}

static NSURL *ApolloFeedThumbCachedVRedditPreview(RDKLink *link) {
    NSString *fullName = nil;
    @try { fullName = link.fullName; } @catch (__unused id e) {}
    if (fullName.length == 0) return nil;
    return [ApolloFeedThumbVRedditCache() objectForKey:fullName];
}

static NSURLSession *ApolloFeedThumbSharedSession(void);  // forward decl

static void ApolloFeedThumbKickVRedditFetch(RDKLink *link) {
    if (!ApolloFeedThumbLinkLooksLikeRedditVideo(link)) return;

    NSString *fullName = nil;
    @try { fullName = link.fullName; } @catch (__unused id e) {}
    if (fullName.length == 0) return;

    NSString *bearer = sLatestRedditBearerToken;
    if (bearer.length == 0) return;  // No token yet — Apollo will likely populate previewMedia on its own once it talks to Reddit.

    NSCache *cache = ApolloFeedThumbVRedditCache();
    if ([cache objectForKey:fullName]) return;

    NSMutableSet *inflight = ApolloFeedThumbVRedditInFlight();
    NSMutableSet *failed   = ApolloFeedThumbVRedditFailed();
    @synchronized (inflight) {
        if ([inflight containsObject:fullName]) return;
        if ([failed containsObject:fullName]) return;  // Don't retry forever.
        [inflight addObject:fullName];
    }

    // Strongly capture the link so the pointer remains valid for the duration
    // of the request — the cell observer keys off the pointer to find which
    // cells to reapply.
    __strong RDKLink *strongLink = link;
    NSString *urlStr = [NSString stringWithFormat:@"https://oauth.reddit.com/api/info?id=%@&raw_json=1", fullName];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlStr]];
    [req setValue:[@"Bearer " stringByAppendingString:bearer] forHTTPHeaderField:@"Authorization"];
    [req setValue:@"ApolloImprovedCustomApi/1.0" forHTTPHeaderField:@"User-Agent"];
    req.timeoutInterval = 10.0;

    NSURLSessionDataTask *task = [ApolloFeedThumbSharedSession() dataTaskWithRequest:req
                                                                   completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        @synchronized (inflight) { [inflight removeObject:fullName]; }
        NSHTTPURLResponse *http = [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)response : nil;
        if (error || data.length == 0 || (http && http.statusCode >= 400)) {
            @synchronized (inflight) { [failed addObject:fullName]; }
            return;
        }
        NSError *jerr = nil;
        id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jerr];
        if (![json isKindOfClass:[NSDictionary class]]) {
            @synchronized (inflight) { [failed addObject:fullName]; }
            return;
        }
        NSDictionary *root = json;
        NSDictionary *dataD = [root[@"data"] isKindOfClass:[NSDictionary class]] ? root[@"data"] : nil;
        NSArray *children = [dataD[@"children"] isKindOfClass:[NSArray class]] ? dataD[@"children"] : nil;
        if (children.count == 0) {
            @synchronized (inflight) { [failed addObject:fullName]; }
            return;
        }
        NSDictionary *child = [children.firstObject isKindOfClass:[NSDictionary class]] ? children.firstObject : nil;
        NSDictionary *cd = [child[@"data"] isKindOfClass:[NSDictionary class]] ? child[@"data"] : nil;
        NSDictionary *preview = [cd[@"preview"] isKindOfClass:[NSDictionary class]] ? cd[@"preview"] : nil;
        NSArray *images = [preview[@"images"] isKindOfClass:[NSArray class]] ? preview[@"images"] : nil;
        NSDictionary *first = [images.firstObject isKindOfClass:[NSDictionary class]] ? images.firstObject : nil;
        NSDictionary *src = [first[@"source"] isKindOfClass:[NSDictionary class]] ? first[@"source"] : nil;
        NSString *u = [src[@"url"] isKindOfClass:[NSString class]] ? src[@"url"] : nil;
        NSURL *previewURL = ApolloFeedThumbURLFromString(u);
        if (!previewURL) {
            @synchronized (inflight) { [failed addObject:fullName]; }
            return;
        }
        [cache setObject:previewURL forKey:fullName];
        ApolloLog(@"[FeedThumbs] vredditFetched url=%@ fullName=%@", previewURL.absoluteString, fullName);

        // Notify the cell observer to reapply.
        const void *linkPtr = (__bridge const void *)strongLink;
        dispatch_async(dispatch_get_main_queue(), ^{
            (void)strongLink; // keep alive on main until notification
            [[NSNotificationCenter defaultCenter] postNotificationName:ApolloFeedThumbsLinkUpdatedNotification
                                                                object:nil
                                                              userInfo:@{kApolloFeedThumbsLinkPointerKey: [NSValue valueWithPointer:linkPtr]}];
        });
    }];
    [task resume];
}

// Weak registry of all live cells we've hooked, so the link-updated
// notification can find which cell currently displays a given mutated link
// (e.g. when v.redd.it's previewMedia is populated lazily after the cell
// already laid out with no fallback URL).
static NSHashTable<id> *ApolloFeedThumbTrackedCells(void) {
    static NSHashTable<id> *cells;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ cells = [NSHashTable weakObjectsHashTable]; });
    return cells;
}

static void ApolloFeedThumbTrackCell(id cell) {
    if (!cell) return;
    @synchronized (ApolloFeedThumbTrackedCells()) {
        [ApolloFeedThumbTrackedCells() addObject:cell];
    }
}

static id ApolloFeedThumbIvarByName(id obj, const char *name) {
    if (!obj || !name) return nil;
    Class cls = object_getClass(obj);
    while (cls) {
        Ivar ivar = class_getInstanceVariable(cls, name);
        if (ivar) return object_getIvar(obj, ivar);
        cls = class_getSuperclass(cls);
    }
    return nil;
}

static RDKLink *ApolloFeedThumbLinkFromCell(id cell) {
    if (!cell) return nil;
    id v = ApolloFeedThumbIvarByName(cell, "link");
    if ([v isKindOfClass:objc_getClass("RDKLink")]) return (RDKLink *)v;
    return nil;
}

static UIView *ApolloFeedThumbViewForNode(id node) {
    if (!node) return nil;
    if (![node respondsToSelector:@selector(view)]) return nil;
    @try {
        ApolloFeedThumbDisplayNode *n = (ApolloFeedThumbDisplayNode *)node;
        if (![n respondsToSelector:@selector(isNodeLoaded)] || !n.isNodeLoaded) return nil;
        return n.view;
    } @catch (__unused id e) {}
    return nil;
}

static UIView *ApolloFeedThumbThumbnailViewFromCell(id cell) {
    id node = ApolloFeedThumbIvarByName(cell, "thumbnailNode");
    UIView *v = ApolloFeedThumbViewForNode(node);
    if (v && v.bounds.size.width > 4 && v.bounds.size.height > 4) return v;
    return nil;
}

static NSURLSession *ApolloFeedThumbSharedSession(void) {
    static NSURLSession *session;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSURLSessionConfiguration *config = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        config.timeoutIntervalForRequest = 15.0;
        config.HTTPMaximumConnectionsPerHost = 6;
        // Reuse Foundation's default URL cache so re-displayed thumbnails don't refetch.
        config.requestCachePolicy = NSURLRequestUseProtocolCachePolicy;
        config.URLCache = [NSURLCache sharedURLCache];
        session = [NSURLSession sessionWithConfiguration:config];
    });
    return session;
}

static NSMutableSet<NSString *> *ApolloFeedThumbAppliedCellLogKeys(void) {
    static NSMutableSet<NSString *> *keys;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ keys = [NSMutableSet set]; });
    return keys;
}

static void ApolloFeedThumbLogAppliedOnce(id cell, RDKLink *link, NSString *source) {
    NSString *fullName = nil;
    @try { fullName = link.fullName; } @catch (__unused id e) {}
    if (fullName.length == 0) fullName = [NSString stringWithFormat:@"%p", link];
    NSString *key = [NSString stringWithFormat:@"%p|%@", cell, fullName];
    @synchronized (ApolloFeedThumbAppliedCellLogKeys()) {
        if ([ApolloFeedThumbAppliedCellLogKeys() containsObject:key]) return;
        [ApolloFeedThumbAppliedCellLogKeys() addObject:key];
    }
    NSString *sub = nil; NSString *title = nil;
    @try { sub = link.subreddit; } @catch (__unused id e) {}
    @try { title = link.title; } @catch (__unused id e) {}
    ApolloLog(@"[FeedThumbs] applied to cell (%@) for r/%@ title='%@'",
              source ?: @"?", sub ?: @"?", title ?: @"?");
}

static void ApolloFeedThumbClearImageOnCell(id cell) {
    UIImageView *iv = objc_getAssociatedObject(cell, kFeedThumbImageViewKey);
    if (iv) {
        iv.image = nil;
        iv.hidden = YES;
    }
    UIVisualEffectView *blur = objc_getAssociatedObject(cell, kFeedThumbBlurViewKey);
    if (blur) blur.hidden = YES;
    UIImageView *badge = objc_getAssociatedObject(cell, kFeedThumbPlayBadgeKey);
    if (badge) badge.hidden = YES;
    NSURLSessionDataTask *task = objc_getAssociatedObject(cell, kFeedThumbCurrentTaskKey);
    [task cancel];
    objc_setAssociatedObject(cell, kFeedThumbCurrentTaskKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(cell, kFeedThumbCurrentURLKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(cell, kFeedThumbCurrentLinkIDKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// MARK: - Spoiler/NSFW gaussian blur
//
// We render the spoiler effect by gaussian-blurring the loaded image itself
// (frosted-glass look that still hints at colors/silhouette) instead of
// stacking a UIVisualEffectView dark material over a black background
// (which collapses to a flat grey square when there's no underlying view
// content to vibrancy-mix with).

static CIContext *ApolloFeedThumbCIContext(void) {
    static CIContext *ctx;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ ctx = [CIContext contextWithOptions:nil]; });
    return ctx;
}

static NSCache<NSString *, UIImage *> *ApolloFeedThumbBlurCache(void) {
    static NSCache<NSString *, UIImage *> *cache;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [[NSCache alloc] init];
        cache.countLimit = 128;  // ~few MB cap; small thumbnails.
    });
    return cache;
}

static UIImage *ApolloFeedThumbBlurImage(UIImage *src, NSString *cacheKey) {
    if (!src) return nil;
    if (cacheKey.length > 0) {
        UIImage *hit = [ApolloFeedThumbBlurCache() objectForKey:cacheKey];
        if (hit) return hit;
    }
    CGImageRef cg = src.CGImage;
    if (!cg) return nil;
    CIImage *input = [CIImage imageWithCGImage:cg];
    if (!input) return nil;

    CIFilter *clamp = [CIFilter filterWithName:@"CIAffineClamp"];  // avoids translucent edges
    [clamp setValue:input forKey:kCIInputImageKey];
    [clamp setValue:[NSValue valueWithCGAffineTransform:CGAffineTransformIdentity] forKey:@"inputTransform"];

    CIFilter *blur = [CIFilter filterWithName:@"CIGaussianBlur"];
    [blur setValue:[clamp outputImage] forKey:kCIInputImageKey];
    [blur setValue:@(130.0) forKey:kCIInputRadiusKey];

    CIImage *output = [blur outputImage];
    if (!output) return nil;
    CGImageRef outCG = [ApolloFeedThumbCIContext() createCGImage:output fromRect:input.extent];
    if (!outCG) return nil;
    UIImage *result = [UIImage imageWithCGImage:outCG scale:src.scale orientation:src.imageOrientation];
    CGImageRelease(outCG);
    if (cacheKey.length > 0 && result) {
        [ApolloFeedThumbBlurCache() setObject:result forKey:cacheKey];
    }
    return result;
}

// MARK: - Play badge
//
// Apollo's own video play indicator is part of the thumbnailNode tree, which
// gets visually covered by our injected UIImageView (we have to render on
// top to hide the missing-thumbnail placeholder). Re-add a play.fill badge
// for video posts so users can tell the post is a video at a glance.

static BOOL ApolloFeedThumbLinkIsVideoPost(RDKLink *link, NSString *source) {
    if ([source isEqualToString:@"vredditCache"]) return YES;
    NSURL *url = nil;
    @try { url = link.URL; } @catch (__unused id e) {}
    NSString *host = url.host.lowercaseString;
    if (!host) return NO;
    if ([host isEqualToString:@"v.redd.it"]) return YES;
    if ([host isEqualToString:@"youtu.be"]) return YES;
    if ([host hasSuffix:@"youtube.com"]) return YES;
    if ([host hasSuffix:@"ytimg.com"]) return YES;  // direct hqdefault.jpg fallback for youtube
    if ([host hasSuffix:@"streamable.com"]) return YES;
    if ([host hasSuffix:@"gfycat.com"]) return YES;
    if ([host hasSuffix:@"redgifs.com"]) return YES;
    return NO;
}

static void ApolloFeedThumbApplyPlayBadge(id cell, UIView *parent, BOOL show) {
    UIImageView *badge = objc_getAssociatedObject(cell, kFeedThumbPlayBadgeKey);
    if (!show) {
        if (badge) badge.hidden = YES;
        return;
    }
    if (!badge) {
        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:18 weight:UIImageSymbolWeightSemibold];
        UIImage *playImg = [UIImage systemImageNamed:@"play.circle.fill" withConfiguration:cfg];
        badge = [[UIImageView alloc] initWithImage:playImg];
        badge.tintColor = [UIColor whiteColor];
        badge.userInteractionEnabled = NO;
        badge.contentMode = UIViewContentModeCenter;
        // Subtle drop shadow so the icon stays readable on bright thumbnails.
        badge.layer.shadowColor = [UIColor blackColor].CGColor;
        badge.layer.shadowOpacity = 0.6;
        badge.layer.shadowRadius = 2.5;
        badge.layer.shadowOffset = CGSizeMake(0, 1);
        objc_setAssociatedObject(cell, kFeedThumbPlayBadgeKey, badge, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (badge.superview != parent) {
        [badge removeFromSuperview];
        [parent addSubview:badge];
    } else {
        [parent bringSubviewToFront:badge];
    }
    badge.hidden = NO;
    // Anchor the badge to the bottom-right corner of the thumbnail.
    CGSize parentSize = parent.bounds.size;
    CGSize badgeSize = CGSizeMake(22, 22);
    CGFloat margin = 5.0;
    badge.frame = CGRectMake(parentSize.width  - badgeSize.width  - margin,
                             parentSize.height - badgeSize.height - margin,
                             badgeSize.width, badgeSize.height);
}

static UIImageView *ApolloFeedThumbEnsureImageView(id cell, UIView *parent) {
    UIImageView *iv = objc_getAssociatedObject(cell, kFeedThumbImageViewKey);
    if (!iv) {
        iv = [[UIImageView alloc] initWithFrame:parent.bounds];
        iv.contentMode = UIViewContentModeScaleAspectFill;
        iv.clipsToBounds = YES;
        iv.userInteractionEnabled = NO;
        iv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        iv.backgroundColor = [UIColor clearColor];
        // Match Apollo's native thumbnail corner rounding (compact + large feed cells).
        iv.layer.cornerRadius = 6.0;
        iv.layer.masksToBounds = YES;
        objc_setAssociatedObject(cell, kFeedThumbImageViewKey, iv, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (iv.superview != parent) {
        [iv removeFromSuperview];
        // Add on top so we cover the native thumbnailNode's placeholder layer
        // (which otherwise paints a grey image-icon square over us). Play
        // badges / gallery indicators live on sibling nodes, not on
        // thumbnailNode's subview tree, so they remain visible.
        [parent addSubview:iv];
    } else {
        // Make sure we stay above any subviews added later by the node.
        [parent bringSubviewToFront:iv];
    }
    iv.frame = parent.bounds;
    return iv;
}

static void ApolloFeedThumbApplyToCell(id cell) {
    if (!cell) return;
    RDKLink *link = ApolloFeedThumbLinkFromCell(cell);
    if (!link) {
        ApolloFeedThumbClearImageOnCell(cell);
        return;
    }

    UIView *thumbView = ApolloFeedThumbThumbnailViewFromCell(cell);
    if (!thumbView) {
        // Cell doesn't render a thumbnail slot (text/discussion post). Nothing to do.
        return;
    }

    // Gate: only inject when the native thumbnail is unusable.
    NSURL *nativeURL = nil;
    @try {
        if ([(id)link respondsToSelector:@selector(thumbnailURL)]) {
            nativeURL = ((NSURL *(*)(id, SEL))objc_msgSend)((id)link, @selector(thumbnailURL));
        }
    } @catch (__unused id e) {}
    if (ApolloFeedThumbURLIsUsable(nativeURL)) {
        // Apollo will draw its own thumbnail. Clear ours if present.
        ApolloFeedThumbClearImageOnCell(cell);
        return;
    }

    NSString *source = nil;
    NSURL *fallbackURL = ApolloFeedThumbFallbackURLForLink(link, &source);
    if (!fallbackURL) {
        ApolloFeedThumbClearImageOnCell(cell);
        return;
    }

    // Cell reuse / link change detection.
    NSString *linkID = nil;
    @try { linkID = link.fullName; } @catch (__unused id e) {}
    if (linkID.length == 0) linkID = [NSString stringWithFormat:@"%p", link];

    NSString *currentLinkID = objc_getAssociatedObject(cell, kFeedThumbCurrentLinkIDKey);
    NSURL *currentURL = objc_getAssociatedObject(cell, kFeedThumbCurrentURLKey);

    UIImageView *iv = ApolloFeedThumbEnsureImageView(cell, thumbView);

    // Spoiler / NSFW: render with a heavy gaussian blur of the actual image
    // so the spoiler retains color/silhouette hints (frosted-glass look)
    // instead of a flat grey box. The legacy UIVisualEffectView path is
    // hidden if it was previously installed.
    BOOL needsBlur = NO;
    @try {
        if ([(id)link respondsToSelector:@selector(isSpoiler)] && link.isSpoiler) needsBlur = YES;
        if ([(id)link respondsToSelector:@selector(isNSFW)] && link.isNSFW) needsBlur = YES;
    } @catch (__unused id e) {}
    UIVisualEffectView *legacyBlur = objc_getAssociatedObject(cell, kFeedThumbBlurViewKey);
    if (legacyBlur) legacyBlur.hidden = YES;

    BOOL isVideo = ApolloFeedThumbLinkIsVideoPost(link, source);
    ApolloFeedThumbApplyPlayBadge(cell, thumbView, isVideo);

    if ([currentLinkID isEqualToString:linkID] && [currentURL isEqual:fallbackURL] && iv.image) {
        // Same link, same URL, image already loaded — just resync visibility.
        iv.hidden = NO;
        return;
    }

    // New link or new URL — cancel any in-flight load and reset.
    NSURLSessionDataTask *oldTask = objc_getAssociatedObject(cell, kFeedThumbCurrentTaskKey);
    [oldTask cancel];
    iv.image = nil;
    iv.hidden = NO;

    objc_setAssociatedObject(cell, kFeedThumbCurrentLinkIDKey, linkID, OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(cell, kFeedThumbCurrentURLKey, fallbackURL, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    ApolloFeedThumbLogOnce(link, source, fallbackURL);
    ApolloFeedThumbLogAppliedOnce(cell, link, source);

    __weak UIImageView *weakIV = iv;
    __weak id weakCell = cell;
    NSString *expectedLinkID = linkID;
    NSURL *expectedURL = fallbackURL;
    BOOL captureNeedsBlur = needsBlur;

    NSURLSessionDataTask *task = [ApolloFeedThumbSharedSession() dataTaskWithURL:fallbackURL completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
        if (error || data.length == 0) return;
        UIImage *image = [UIImage imageWithData:data];
        if (!image) return;
        UIImage *finalImage = image;
        if (captureNeedsBlur) {
            UIImage *blurred = ApolloFeedThumbBlurImage(image, expectedURL.absoluteString);
            if (blurred) finalImage = blurred;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            UIImageView *strongIV = weakIV;
            id strongCell = weakCell;
            if (!strongIV || !strongCell) return;
            // Verify the cell still wants this image (no later reuse).
            NSString *nowLinkID = objc_getAssociatedObject(strongCell, kFeedThumbCurrentLinkIDKey);
            NSURL *nowURL = objc_getAssociatedObject(strongCell, kFeedThumbCurrentURLKey);
            if (![nowLinkID isEqualToString:expectedLinkID]) return;
            if (![nowURL isEqual:expectedURL]) return;
            strongIV.image = finalImage;
            strongIV.hidden = NO;
        });
    }];
    objc_setAssociatedObject(cell, kFeedThumbCurrentTaskKey, task, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [task resume];
}

// MARK: - Cell hooks

%hook _TtC6Apollo17LargePostCellNode

- (void)didLoad {
    %orig;
    ApolloFeedThumbTrackCell(self);
    ApolloFeedThumbApplyToCell(self);
}

- (void)layout {
    %orig;
    // Layout fast-path: skip work when neither the bound link nor the
    // thumbnail slot size has changed since our last successful apply.
    // ApolloFeedThumbApplyToCell still has its own (URL, image-loaded)
    // early-out, but doing the cheap pointer compare here avoids the ivar
    // walks for `link` / `thumbnailNode` on every layout pass during scrolling.
    RDKLink *link = ApolloFeedThumbLinkFromCell(self);
    UIView *thumbView = ApolloFeedThumbThumbnailViewFromCell(self);
    CGSize thumbSize = thumbView ? thumbView.bounds.size : CGSizeZero;
    NSValue *lastPtr = objc_getAssociatedObject(self, kFeedThumbLastAppliedLinkPtrKey);
    NSValue *lastSize = objc_getAssociatedObject(self, kFeedThumbLastAppliedSizeKey);
    if (link && lastPtr && [lastPtr pointerValue] == (__bridge void *)link &&
        lastSize && CGSizeEqualToSize([lastSize CGSizeValue], thumbSize)) {
        return;
    }
    ApolloFeedThumbApplyToCell(self);
    if (link) {
        objc_setAssociatedObject(self, kFeedThumbLastAppliedLinkPtrKey,
                                 [NSValue valueWithPointer:(__bridge void *)link],
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(self, kFeedThumbLastAppliedSizeKey,
                                 [NSValue valueWithCGSize:thumbSize],
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

%end

%hook _TtC6Apollo19CompactPostCellNode

- (void)didLoad {
    %orig;
    ApolloFeedThumbTrackCell(self);
    ApolloFeedThumbApplyToCell(self);
}

- (void)layout {
    %orig;
    RDKLink *link = ApolloFeedThumbLinkFromCell(self);
    UIView *thumbView = ApolloFeedThumbThumbnailViewFromCell(self);
    CGSize thumbSize = thumbView ? thumbView.bounds.size : CGSizeZero;
    NSValue *lastPtr = objc_getAssociatedObject(self, kFeedThumbLastAppliedLinkPtrKey);
    NSValue *lastSize = objc_getAssociatedObject(self, kFeedThumbLastAppliedSizeKey);
    if (link && lastPtr && [lastPtr pointerValue] == (__bridge void *)link &&
        lastSize && CGSizeEqualToSize([lastSize CGSizeValue], thumbSize)) {
        return;
    }
    ApolloFeedThumbApplyToCell(self);
    if (link) {
        objc_setAssociatedObject(self, kFeedThumbLastAppliedLinkPtrKey,
                                 [NSValue valueWithPointer:(__bridge void *)link],
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(self, kFeedThumbLastAppliedSizeKey,
                                 [NSValue valueWithCGSize:thumbSize],
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

%end

// MARK: - Lazy population (v.redd.it, etc.)
//
// Apollo populates `previewMedia` and `mediaMetadata` AFTER the feed initially
// loads for some media types — most notably v.redd.it, where the cell first
// renders with nil previewMedia (so we can't compute a fallback URL), and only
// after the post details are fetched (e.g. after the user opens the post and
// returns) does previewMedia get set. Hook those setters to broadcast a
// notification; the cell observer reapplies if the mutated link matches.

%hook RDKLink

- (void)setPreviewMedia:(id)previewMedia {
    %orig;
    [[NSNotificationCenter defaultCenter] postNotificationName:ApolloFeedThumbsLinkUpdatedNotification
                                                        object:nil
                                                      userInfo:@{kApolloFeedThumbsLinkPointerKey: [NSValue valueWithPointer:(__bridge const void *)self]}];
}

- (void)setMediaMetadata:(id)mediaMetadata {
    %orig;
    [[NSNotificationCenter defaultCenter] postNotificationName:ApolloFeedThumbsLinkUpdatedNotification
                                                        object:nil
                                                      userInfo:@{kApolloFeedThumbsLinkPointerKey: [NSValue valueWithPointer:(__bridge const void *)self]}];
}

%end

// MARK: - Comments header preview-pill suppression
//
// When Reddit returns an empty `thumbnail` for direct image posts, Apollo
// doesn't recognize the post as inline media and renders a generic
// LinkButtonNode pill ("redd.it/<id>.jpeg ›") below the post title in the
// comments view. This is baseline Apollo behavior for any post whose native
// thumbnail handling fails, but those posts are still normal image posts that
// should be shown inline.
//
// Hide that pill when the link's URL is a direct redd.it image, since the
// comments header already renders the actual image inline elsewhere (or, for
// spoiler/NSFW, the native blur tap-to-reveal area).

static BOOL ApolloFeedThumbURLIsDirectRedditImage(NSURL *url) {
    if (![url isKindOfClass:[NSURL class]]) return NO;
    NSString *host = url.host.lowercaseString;
    NSString *ext = url.pathExtension.lowercaseString;
    if (![host isEqualToString:@"i.redd.it"] && ![host isEqualToString:@"preview.redd.it"]) return NO;
    static NSSet<NSString *> *exts;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        exts = [NSSet setWithArray:@[@"jpg", @"jpeg", @"png", @"webp", @"gif"]];
    });
    return [exts containsObject:ext];
}

static void ApolloFeedThumbHideLinkPillIfRedundant(id headerCell) {
    if (!headerCell) return;
    RDKLink *link = ApolloFeedThumbLinkFromCell(headerCell);
    if (!link) return;
    NSURL *url = nil;
    @try { url = link.URL; } @catch (__unused id e) {}
    if (!ApolloFeedThumbURLIsDirectRedditImage(url)) return;

    // Resolve the link-button ivar exactly once per process. We cache the Ivar
    // pointer so subsequent layouts only do an O(1) `object_getIvar` call
    // instead of walking the superclass chain for each candidate name.
    static Ivar gPillIvar = NULL;
    static dispatch_once_t gPillOnce = 0;
    dispatch_once(&gPillOnce, ^{
        Class cls = object_getClass(headerCell);
        static const char *const kNames[] = {"linkButtonNode", "linkNode", "linkPreviewNode", "linkBubbleNode"};
        Class probe = cls;
        while (probe && !gPillIvar) {
            for (size_t i = 0; i < sizeof(kNames)/sizeof(kNames[0]); i++) {
                Ivar iv = class_getInstanceVariable(probe, kNames[i]);
                if (iv) { gPillIvar = iv; break; }
            }
            probe = class_getSuperclass(probe);
        }
    });
    if (!gPillIvar) return;

    id node = object_getIvar(headerCell, gPillIvar);
    if (!node) return;
    UIView *v = ApolloFeedThumbViewForNode(node);
    if (v && !v.hidden) v.hidden = YES;
    if ([node respondsToSelector:@selector(setHidden:)]) {
        @try { ((void (*)(id, SEL, BOOL))objc_msgSend)(node, @selector(setHidden:), YES); } @catch (__unused id e) {}
    }
}

%hook _TtC6Apollo22CommentsHeaderCellNode

- (void)didLoad {
    %orig;
    ApolloFeedThumbHideLinkPillIfRedundant(self);
}

- (void)layout {
    %orig;
    ApolloFeedThumbHideLinkPillIfRedundant(self);
}

%end

%ctor {
    %init(_TtC6Apollo17LargePostCellNode = objc_getClass("_TtC6Apollo17LargePostCellNode"),
          _TtC6Apollo19CompactPostCellNode = objc_getClass("_TtC6Apollo19CompactPostCellNode"),
          _TtC6Apollo22CommentsHeaderCellNode = objc_getClass("_TtC6Apollo22CommentsHeaderCellNode"));

    [[NSNotificationCenter defaultCenter] addObserverForName:ApolloFeedThumbsLinkUpdatedNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *note) {
        NSValue *ptrValue = note.userInfo[kApolloFeedThumbsLinkPointerKey];
        if (![ptrValue isKindOfClass:[NSValue class]]) return;
        const void *mutatedLinkPtr = [ptrValue pointerValue];
        if (!mutatedLinkPtr) return;

        NSArray *cells = nil;
        @synchronized (ApolloFeedThumbTrackedCells()) {
            cells = [[ApolloFeedThumbTrackedCells() allObjects] copy];
        }
        for (id cell in cells) {
            RDKLink *cellLink = ApolloFeedThumbLinkFromCell(cell);
            if ((__bridge const void *)cellLink == mutatedLinkPtr) {
                ApolloFeedThumbApplyToCell(cell);
            }
        }
    }];
}
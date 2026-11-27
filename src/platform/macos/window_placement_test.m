/* Window placement against the production AppKit host: appkit_host.m is
 * compiled into this harness, which drives real windows and checks
 *
 *  - the content size round trip for every titlebar style and restore
 *    policy: a window restored from a content rect lays its content out
 *    at exactly that rect, the placement cache answers it, and a relaunch
 *    from the answer reproduces it;
 *  - the settle rule: a programmatic frame settles at once (before the
 *    frame event it causes), an animated frame or a zoom settles at the
 *    end of its live resize, a move while a pointer button is held keeps
 *    the pre-drag answer until the button comes up, minimize and
 *    fullscreen keep the mode the window returns to, and every changed
 *    settle is followed by a frame event carrying the new answer;
 *  - a close (also before any settle, and while zoomed, minimized or in
 *    fullscreen) and a quit during a drag leave the cache, and the last
 *    frame event, with the placement the window returns to;
 *  - a zoomed open through every show mode (the startup window, immediate,
 *    passive, first-present, hidden) without a frame event reporting the
 *    window unzoomed before its first unzoom, which returns exactly to the
 *    normal frame; a frame from a removed screen lands on a remaining one.
 *
 * The real native fullscreen transition needs an active app on an
 * unlocked screen; without one it is skipped loudly (the fullscreen
 * freeze is also checked through the delegate's own notifications).
 * NATIVE_SDK_TEST_REQUIRE_FULLSCREEN=1 makes that skip a failure. Exit
 * status 0 means every check passed. */
#import "appkit_host.m"

/* These unrelated host services are implemented by Zig in apps. */
native_sdk_update_verify_result_t native_sdk_update_verify_feed(
    const char *envelope, size_t envelope_len,
    const char *public_key, size_t public_key_len,
    const char *bundle_id, size_t bundle_id_len,
    const char *current_version, size_t current_version_len,
    const char *target, size_t target_len,
    char *version_out, size_t version_capacity,
    char *archive_url_out, size_t archive_url_capacity,
    char *release_notes_out, size_t release_notes_capacity) {
    abort();
}
int native_sdk_update_verify_archive(const char *path, size_t path_len, uint64_t expected_bytes, const char *sha256, size_t sha256_len) {
    abort();
}

static int failures;
static int checks;
static int skips;

#define CHECK(condition, ...)                                                   \
    do {                                                                        \
        checks++;                                                               \
        if (!(condition)) {                                                     \
            failures++;                                                         \
            fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__);                 \
            fprintf(stderr, __VA_ARGS__);                                       \
            fprintf(stderr, "\n");                                              \
        }                                                                       \
    } while (0)

/* Every window frame event, with the placement the runtime would read
 * while handling it (the runtime queries inside the event). */
typedef struct {
    uint64_t id;
    NSRect frame;
    int open;
    int hidden;
    int maximized;
    int has_placement;
    NSRect placement;
    int placement_maximized;
    int before_shutdown;
} frame_record_t;

#define MAX_RECORDS 16384
static frame_record_t records[MAX_RECORDS];
static int record_count;
static int record_overflow;
static int shutdown_seen;

@interface NativeSdkPlacementTestHost : NativeSdkAppKitHost
@property(nonatomic, assign) BOOL pointerHeld;
@end

@interface NativeSdkPlacementTestHost (Cases)
- (void)runCases;
@end

static NativeSdkPlacementTestHost *host;

@implementation NativeSdkPlacementTestHost
- (void)emitEvent:(native_sdk_appkit_event_t)event {
    if (event.kind == NATIVE_SDK_APPKIT_EVENT_START) {
        [self performSelector:@selector(runCases) withObject:nil afterDelay:0.2];
        return;
    }
    if (event.kind == NATIVE_SDK_APPKIT_EVENT_SHUTDOWN) {
        shutdown_seen = 1;
        return;
    }
    if (event.kind != NATIVE_SDK_APPKIT_EVENT_WINDOW_FRAME) return;
    if (record_count == MAX_RECORDS) {
        record_overflow = 1;
        return;
    }
    frame_record_t *record = &records[record_count++];
    memset(record, 0, sizeof(*record));
    record->id = event.window_id;
    record->frame = NSMakeRect(event.x, event.y, event.width, event.height);
    record->open = event.open;
    record->hidden = event.hidden;
    record->maximized = event.maximized;
    record->before_shutdown = !shutdown_seen;
    double x = 0, y = 0, width = 0, height = 0;
    int maximized = 0;
    if (native_sdk_appkit_window_placement((__bridge native_sdk_appkit_host_t *)self, event.window_id, &x, &y, &width, &height, &maximized)) {
        record->has_placement = 1;
        record->placement = NSMakeRect(x, y, width, height);
        record->placement_maximized = maximized;
    }
}

- (BOOL)windowPlacementPointerHeld {
    return self.pointerHeld;
}
@end

/* ------------------------------------------------------------------------
 * Loop and window helpers. */

static void pump(double seconds) {
    NSDate *until = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while ([until timeIntervalSinceNow] > 0) {
        @autoreleasepool {
            NSEvent *event = [NSApp nextEventMatchingMask:NSEventMaskAny untilDate:until inMode:NSDefaultRunLoopMode dequeue:YES];
            if (event) [NSApp sendEvent:event];
        }
    }
}

static BOOL pumpUntil(double seconds, BOOL (^condition)(void)) {
    NSDate *until = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while (!condition()) {
        if ([until timeIntervalSinceNow] <= 0) return NO;
        @autoreleasepool {
            NSEvent *event = [NSApp nextEventMatchingMask:NSEventMaskAny untilDate:[NSDate dateWithTimeIntervalSinceNow:0.02] inMode:NSDefaultRunLoopMode dequeue:YES];
            if (event) [NSApp sendEvent:event];
        }
    }
    return YES;
}

static uint64_t next_window_id = 100;

static const char *styleName(int style) {
    switch (style) {
    case 0: return "standard";
    case 1: return "hidden_inset";
    case 2: return "hidden_inset_tall";
    default: return "chromeless";
    }
}

static NSWindow *windowOf(uint64_t windowId) {
    return host.windows[@(windowId)];
}

static NSRect contentOf(uint64_t windowId) {
    NSWindow *window = windowOf(windowId);
    return window ? [window contentRectForFrameRect:window.frame] : NSZeroRect;
}

typedef struct {
    int found;
    NSRect frame;
    int maximized;
} placement_t;

static placement_t placementOf(uint64_t windowId) {
    placement_t placement = {0};
    double x = 0, y = 0, width = 0, height = 0;
    placement.found = native_sdk_appkit_window_placement((__bridge native_sdk_appkit_host_t *)host, windowId, &x, &y, &width, &height, &placement.maximized);
    placement.frame = NSMakeRect(x, y, width, height);
    return placement;
}

static NSString *rectString(NSRect rect) {
    return [NSString stringWithFormat:@"(%.1f,%.1f %.1fx%.1f)", rect.origin.x, rect.origin.y, rect.size.width, rect.size.height];
}
#define R(rect) rectString(rect).UTF8String

static uint64_t createWindow(int style, int policy, NSRect frame, int initialPlacement, int show, uint32_t flags, BOOL resizable) {
    uint64_t windowId = next_window_id++;
    BOOL ok = [host createWindowWithId:windowId title:@"placement" label:[NSString stringWithFormat:@"w%llu", (unsigned long long)windowId]
        x:frame.origin.x y:frame.origin.y width:frame.size.width height:frame.size.height restoreFrame:YES
        initialPlacement:initialPlacement restorePolicy:policy resizable:resizable titlebarStyle:style showPolicy:show windowFlags:flags makeMain:NO];
    CHECK(ok, "create window %llu", (unsigned long long)windowId);
    return windowId;
}

static uint64_t restoreWindow(int style, int policy, NSRect frame, BOOL maximized) {
    return createWindow(style, policy, frame, 0, 0, maximized ? (1u << 6) : 0, YES);
}

static void closeWindow(uint64_t windowId) {
    NSWindow *window = windowOf(windowId);
    if (!window) return;
    [window close];
    pump(0.05);
}

static int recordMark(void) {
    return record_count;
}

static const frame_record_t *lastRecord(uint64_t windowId, int from) {
    for (int index = record_count - 1; index >= from; index--) {
        if (records[index].id == windowId) return &records[index];
    }
    return NULL;
}

/* The runtime persists the placement it reads while handling a frame
 * event, so after any settle the LAST frame event since `from` must carry
 * the cache's current answer. */
static void expectLastEventCarries(uint64_t windowId, int from, const char *what) {
    const frame_record_t *record = lastRecord(windowId, from);
    placement_t placement = placementOf(windowId);
    CHECK(record != NULL, "%s: a frame event for window %llu", what, (unsigned long long)windowId);
    if (!record) return;
    CHECK(record->has_placement && NSEqualRects(record->placement, placement.frame) && record->placement_maximized == placement.maximized,
        "%s: last frame event carries %s max=%d, cache is %s max=%d", what, R(record->placement), record->placement_maximized, R(placement.frame), placement.maximized);
}

static void expectPlacement(uint64_t windowId, NSRect frame, int maximized, const char *what) {
    placement_t placement = placementOf(windowId);
    CHECK(placement.found, "%s: window %llu has a placement", what, (unsigned long long)windowId);
    CHECK(NSEqualRects(placement.frame, frame) && placement.maximized == maximized,
        "%s: placement %s max=%d, want %s max=%d", what, R(placement.frame), placement.maximized, R(frame), maximized);
}

static BOOL zoomed(uint64_t windowId) {
    return NativeSdkWindowIsZoomed(windowOf(windowId));
}

/* ------------------------------------------------------------------------
 * Cases. */

/* The normal frame every case restores and expects back. It is placed
 * inside the primary screen's visible frame, with room for the cases'
 * moves and the titlebar, so clamp_to_visible_screen never moves it. A
 * fixed origin fit the test Mac's screen but not a CI runner's smaller
 * one, where every restored window was pushed down into the visible
 * frame and no placement matched. Set in main(). */
static NSRect normalFrame;

static NSRect fittedFrame(CGFloat inset, CGFloat width, CGFloat height) {
    const NSRect visible = NSScreen.screens.firstObject.visibleFrame;
    return NSMakeRect(NSMinX(visible) + inset, NSMinY(visible) + inset,
                      MIN(width, NSWidth(visible) - 3 * inset),
                      MIN(height, NSHeight(visible) - 4 * inset));
}

static void caseRoundTrip(void) {
    for (int policy = 0; policy <= 1; policy++) {
        for (int style = 0; style <= 3; style++) {
            NSRect frame = normalFrame;
            NSRect first = NSZeroRect;
            for (int launch = 0; launch < 4; launch++) {
                uint64_t windowId = restoreWindow(style, policy, frame, NO);
                pump(0.05);
                NSRect content = contentOf(windowId);
                NSWindow *window = windowOf(windowId);
                CHECK(NSEqualSizes(content.size, normalFrame.size) && NSEqualSizes(window.contentView.bounds.size, normalFrame.size),
                    "%s/%s launch %d: content %s (view %.1fx%.1f), want 720x480", styleName(style), policy ? "center" : "clamp", launch,
                    R(content), window.contentView.bounds.size.width, window.contentView.bounds.size.height);
                if (policy == 0) CHECK(NSEqualPoints(content.origin, normalFrame.origin), "%s clamp launch %d: origin %s", styleName(style), launch, R(content));
                if (launch == 0) first = content;
                CHECK(NSEqualRects(content, first), "%s/%s launch %d: %s drifted from %s", styleName(style), policy ? "center" : "clamp", launch, R(content), R(first));
                expectPlacement(windowId, content, 0, "round trip answer");
                frame = placementOf(windowId).frame;
                closeWindow(windowId);
            }
        }
    }
}

static void caseZoomedRoundTrip(void) {
    for (int style = 0; style <= 3; style++) {
        NSRect frame = normalFrame;
        for (int launch = 0; launch < 3; launch++) {
            int mark = recordMark();
            uint64_t windowId = restoreWindow(style, 0, frame, YES);
            pump(0.05);
            CHECK(zoomed(windowId), "%s zoomed launch %d: window opens zoomed", styleName(style), launch);
            expectPlacement(windowId, normalFrame, 1, "zoomed open answer");
            for (int index = mark; index < record_count; index++) {
                if (records[index].id == windowId) CHECK(records[index].maximized == 1, "%s zoomed launch %d: frame event %d says unzoomed", styleName(style), launch, index);
            }
            if (launch == 2) {
                [windowOf(windowId) zoom:nil];
                pump(0.05);
                CHECK(NSEqualRects(contentOf(windowId), normalFrame), "%s: unzoom returns to %s, got %s", styleName(style), R(normalFrame), R(contentOf(windowId)));
                expectPlacement(windowId, normalFrame, 0, "unzoomed answer");
                expectLastEventCarries(windowId, mark, "unzoom");
            }
            frame = placementOf(windowId).frame;
            closeWindow(windowId);
        }
    }
}

static void caseSettleRule(int style) {
    uint64_t windowId = restoreWindow(style, 0, normalFrame, NO);
    NSWindow *window = windowOf(windowId);
    pump(0.1);
    expectPlacement(windowId, normalFrame, 0, "seeded");

    // A programmatic frame settles before the frame event it causes.
    int mark = recordMark();
    NSRect moved = NSOffsetRect([window frameRectForContentRect:normalFrame], 40, -20);
    moved.size.width += 30;
    [window setFrame:moved display:YES];
    NSRect content = contentOf(windowId);
    expectPlacement(windowId, content, 0, "programmatic frame");
    const frame_record_t *record = lastRecord(windowId, mark);
    CHECK(record && NSEqualRects(record->frame, content) && NSEqualRects(record->placement, content),
        "%s programmatic: the frame event already carries the new placement", styleName(style));

    // An animated frame runs inside live-resize brackets: its frame
    // events keep the old answer until the live resize ends.
    NSRect before = content;
    mark = recordMark();
    NSRect animated = window.frame;
    animated.origin.y -= 30;
    animated.size.height += 20;
    [window setFrame:animated display:YES animate:YES];
    pump(0.05);
    content = contentOf(windowId);
    BOOL heldOld = NO;
    for (int index = mark; index < record_count; index++) {
        if (records[index].id == windowId && NSEqualRects(records[index].frame, content) && NSEqualRects(records[index].placement, before)) heldOld = YES;
    }
    CHECK(heldOld, "%s animated: a frame event inside the live resize still carries the pre-resize placement", styleName(style));
    expectPlacement(windowId, content, 0, "animated frame settled");
    expectLastEventCarries(windowId, mark, "animated frame");

    // A move while a pointer button is held is a window drag: it keeps
    // the pre-drag answer until the button comes up.
    before = content;
    mark = recordMark();
    host.pointerHeld = YES;
    [window setFrameOrigin:NSMakePoint(window.frame.origin.x + 25, window.frame.origin.y + 15)];
    [window setFrameOrigin:NSMakePoint(window.frame.origin.x + 25, window.frame.origin.y + 15)];
    pump(0.35);
    content = contentOf(windowId);
    expectPlacement(windowId, before, 0, "during a drag");
    record = lastRecord(windowId, mark);
    CHECK(record && NSEqualRects(record->frame, content) && NSEqualRects(record->placement, before), "%s drag: frame events carry the pre-drag placement", styleName(style));
    int released = recordMark();
    host.pointerHeld = NO;
    pumpUntil(1.0, ^BOOL { return NSEqualRects(placementOf(windowId).frame, contentOf(windowId)); });
    expectPlacement(windowId, content, 0, "drag released");
    expectLastEventCarries(windowId, released, "drag released");

    // Zoom and unzoom: the normal frame survives the zoom, the mode flips
    // at the end of each animation, and the frame events say so.
    NSRect normal = content;
    mark = recordMark();
    [window zoom:nil];
    pump(0.05);
    CHECK(zoomed(windowId), "%s: zoomed", styleName(style));
    expectPlacement(windowId, normal, 1, "zoomed");
    expectLastEventCarries(windowId, mark, "zoom");
    record = lastRecord(windowId, mark);
    CHECK(record && record->maximized == 1, "%s zoom: frame event reports the live zoomed state", styleName(style));
    mark = recordMark();
    [window zoom:nil];
    pump(0.05);
    CHECK(NSEqualRects(contentOf(windowId), normal), "%s: unzoom returns to %s, got %s", styleName(style), R(normal), R(contentOf(windowId)));
    expectPlacement(windowId, normal, 0, "unzoomed");
    expectLastEventCarries(windowId, mark, "unzoom");
    record = lastRecord(windowId, mark);
    CHECK(record && record->maximized == 0, "%s unzoom: frame event reports unzoomed", styleName(style));

    // Minimize keeps the pre-minimize mode.
    [window miniaturize:nil];
    CHECK(pumpUntil(5.0, ^BOOL { return window.isMiniaturized; }), "%s: minimized", styleName(style));
    expectPlacement(windowId, normal, 0, "minimized from normal");
    [window deminiaturize:nil];
    CHECK(pumpUntil(5.0, ^BOOL { return !window.isMiniaturized; }), "%s: deminiaturized", styleName(style));
    pump(0.1);
    expectPlacement(windowId, normal, 0, "deminiaturized");

    // Minimized from zoomed keeps the zoomed placement, while the frame
    // channel reports the minimized window unzoomed and the
    // deminiaturized one zoomed again.
    [window zoom:nil];
    pump(0.05);
    mark = recordMark();
    [window miniaturize:nil];
    CHECK(pumpUntil(5.0, ^BOOL { return window.isMiniaturized; }), "%s: minimized from zoomed", styleName(style));
    pump(0.1);
    expectPlacement(windowId, normal, 1, "minimized from zoomed");
    record = lastRecord(windowId, mark);
    CHECK(record && record->maximized == 0 && record->placement_maximized == 1, "%s: a minimized window reports unzoomed, placement zoomed", styleName(style));
    mark = recordMark();
    [window deminiaturize:nil];
    CHECK(pumpUntil(5.0, ^BOOL { return !window.isMiniaturized; }), "%s: deminiaturized from zoomed", styleName(style));
    pump(0.1);
    record = lastRecord(windowId, mark);
    CHECK(record && record->maximized == 1 && record->placement_maximized == 1, "%s: the deminiaturized window reports zoomed again", styleName(style));
    expectPlacement(windowId, normal, 1, "deminiaturized zoomed");
    [window miniaturize:nil];
    CHECK(pumpUntil(5.0, ^BOOL { return window.isMiniaturized; }), "%s: minimized from zoomed again", styleName(style));
    mark = recordMark();
    [window close];
    pump(0.05);
    CHECK(windowOf(windowId) == nil, "%s: closed while minimized", styleName(style));
    expectPlacement(windowId, normal, 1, "closed while minimized from zoomed");
    record = lastRecord(windowId, mark);
    CHECK(record && record->open == 0 && NSEqualRects(record->placement, normal) && record->placement_maximized == 1,
        "%s: the close event carries the zoomed placement", styleName(style));
}

/* The fullscreen freeze through the delegate's own notifications: the
 * transition AppKit runs needs an active app, these do not. */
static void caseFullScreenNotifications(BOOL fromZoomed) {
    uint64_t windowId = restoreWindow(0, 0, normalFrame, fromZoomed);
    NSWindow *window = windowOf(windowId);
    NativeSdkWindowDelegate *delegate = (NativeSdkWindowDelegate *)window.delegate;
    pump(0.05);
    NSRect before = window.frame;
    NSNotification *note = [NSNotification notificationWithName:NSWindowWillEnterFullScreenNotification object:window];
    [delegate windowWillEnterFullScreen:note];
    int mark = recordMark();
    // A frame unlike both the normal and the zoomed one stands in for
    // the fullscreen geometry.
    NSScreen *screen = window.screen ?: NSScreen.screens.firstObject;
    const NSRect stand_in = NSMakeRect(NSMinX(screen.visibleFrame) + 10, NSMinY(screen.visibleFrame) + 10, 900, 600);
    [window setFrame:stand_in display:YES];
    pump(0.05);
    expectPlacement(windowId, normalFrame, fromZoomed ? 1 : 0, "frozen in fullscreen");
    const frame_record_t *record = lastRecord(windowId, mark);
    CHECK(record && NSEqualRects(record->placement, normalFrame), "fullscreen%s: frame events carry the pre-fullscreen placement (record=%d placement %s, window %s)",
        fromZoomed ? " from zoomed" : "", record != NULL, record ? R(record->placement) : "-", R(window.frame));
    // Failing to enter, and exiting, return the window and thaw the
    // cache: the next change settles again.
    void (^expectThawed)(const char *) = ^(const char *what) {
        if (fromZoomed) {
            [window zoom:nil];
            pump(0.05);
            expectPlacement(windowId, normalFrame, 0, what);
            [window zoom:nil];
            pump(0.05);
            expectPlacement(windowId, normalFrame, 1, what);
        } else {
            [window setFrameOrigin:NSMakePoint(before.origin.x + 15, before.origin.y + 15)];
            expectPlacement(windowId, NSOffsetRect(normalFrame, 15, 15), 0, what);
            [window setFrame:before display:YES];
            expectPlacement(windowId, normalFrame, 0, what);
        }
    };
    [window setFrame:before display:YES];
    [delegate windowDidFailToEnterFullScreen:window];
    pump(0.05);
    expectPlacement(windowId, normalFrame, fromZoomed ? 1 : 0, "failed to enter fullscreen");
    expectThawed("thawed after a failed fullscreen");
    [delegate windowWillEnterFullScreen:note];
    [window setFrame:stand_in display:YES];
    [window setFrame:before display:YES];
    NSNotification *exitNote = [NSNotification notificationWithName:NSWindowDidExitFullScreenNotification object:window];
    [delegate windowDidExitFullScreen:exitNote];
    pump(0.05);
    expectPlacement(windowId, normalFrame, fromZoomed ? 1 : 0, "exited fullscreen");
    expectThawed("thawed after fullscreen");
    // Entering again, then closing in fullscreen.
    [delegate windowWillEnterFullScreen:note];
    [window setFrame:stand_in display:YES];
    mark = recordMark();
    [window close];
    pump(0.05);
    expectPlacement(windowId, normalFrame, fromZoomed ? 1 : 0, "closed in fullscreen");
    record = lastRecord(windowId, mark);
    CHECK(record && record->open == 0 && NSEqualRects(record->placement, normalFrame) && record->placement_maximized == (fromZoomed ? 1 : 0),
        "fullscreen close: the close event carries the pre-fullscreen placement");
}

static BOOL fullScreenEntered;
static BOOL fullScreenExited;
static BOOL fullScreenFailed;

static void caseRealFullScreen(BOOL fromZoomed) {
    uint64_t windowId = restoreWindow(0, 0, normalFrame, fromZoomed);
    NSWindow *window = windowOf(windowId);
    id observer = [[NSNotificationCenter defaultCenter] addObserverForName:nil object:window queue:nil usingBlock:^(NSNotification *note) {
        if ([note.name isEqualToString:NSWindowDidEnterFullScreenNotification]) fullScreenEntered = YES;
        if ([note.name isEqualToString:NSWindowDidExitFullScreenNotification]) fullScreenExited = YES;
        if ([note.name isEqualToString:@"NSWindowDidFailToEnterFullScreenNotification"]) fullScreenFailed = YES;
    }];
    fullScreenEntered = fullScreenExited = fullScreenFailed = NO;
    [NSApp activateIgnoringOtherApps:YES];
    [window makeKeyAndOrderFront:nil];
    pump(0.3);
    int mark = recordMark();
    [window toggleFullScreen:nil];
    pumpUntil(6.0, ^BOOL { return fullScreenEntered || fullScreenFailed; });
    // Whatever the transition did, every frame event it caused carried
    // the pre-fullscreen placement.
    for (int index = mark; index < record_count; index++) {
        if (records[index].id != windowId) continue;
        CHECK(NSEqualRects(records[index].placement, normalFrame) && records[index].placement_maximized == (fromZoomed ? 1 : 0),
            "real fullscreen%s: frame event %d carries %s max=%d", fromZoomed ? " from zoomed" : "", index, R(records[index].placement), records[index].placement_maximized);
    }
    if (!fullScreenEntered) {
        skips++;
        fprintf(stderr, "SKIP real fullscreen%s: AppKit did not enter fullscreen (app active=%d; a locked screen or an inactive app cannot)\n",
            fromZoomed ? " from zoomed" : "", NSApp.isActive);
        if (getenv("NATIVE_SDK_TEST_REQUIRE_FULLSCREEN")) CHECK(0, "real fullscreen required");
        expectPlacement(windowId, normalFrame, fromZoomed ? 1 : 0, "after a failed fullscreen");
    } else {
        pump(0.5);
        expectPlacement(windowId, normalFrame, fromZoomed ? 1 : 0, "in real fullscreen");
        // A fullscreen window is not maximized on the frame channel.
        int inside = recordMark();
        [host emitWindowFrameForWindowId:windowId open:YES];
        const frame_record_t *record = lastRecord(windowId, inside);
        CHECK(record && record->maximized == 0, "real fullscreen: frame events report not maximized");
        [window toggleFullScreen:nil];
        CHECK(pumpUntil(6.0, ^BOOL { return fullScreenExited; }), "real fullscreen: exited");
        pump(0.5);
        CHECK(zoomed(windowId) == fromZoomed, "real fullscreen: returns %s", fromZoomed ? "zoomed" : "normal");
        if (!fromZoomed) CHECK(NSEqualRects(contentOf(windowId), normalFrame), "real fullscreen: returns to %s, got %s", R(normalFrame), R(contentOf(windowId)));
        expectPlacement(windowId, normalFrame, fromZoomed ? 1 : 0, "after real fullscreen");
        expectLastEventCarries(windowId, mark, "after real fullscreen");
    }
    [[NSNotificationCenter defaultCenter] removeObserver:observer];
    closeWindow(windowId);
}

static void caseCloseBeforeSettle(void) {
    uint64_t windowId = restoreWindow(1, 0, normalFrame, NO);
    int mark = recordMark();
    [windowOf(windowId) close];
    expectPlacement(windowId, normalFrame, 0, "closed before any settle");
    const frame_record_t *record = lastRecord(windowId, mark);
    CHECK(record && record->open == 0 && NSEqualRects(record->placement, normalFrame), "close before settle: the close event carries the seeded placement");
    // A zoomed window closed at once.
    windowId = restoreWindow(1, 0, normalFrame, YES);
    mark = recordMark();
    [windowOf(windowId) close];
    expectPlacement(windowId, normalFrame, 1, "zoomed window closed at once");
    record = lastRecord(windowId, mark);
    CHECK(record && record->open == 0 && record->placement_maximized == 1 && NSEqualRects(record->placement, normalFrame), "zoomed close: the close event carries the zoomed placement");
    // A close during a drag (the app closes the window while the user
    // still holds the button): the close settles the dragged frame, and
    // the close event carries it.
    windowId = restoreWindow(0, 0, normalFrame, NO);
    NSWindow *window = windowOf(windowId);
    pump(0.05);
    host.pointerHeld = YES;
    [window setFrameOrigin:NSMakePoint(window.frame.origin.x + 40, window.frame.origin.y + 40)];
    const NSRect dragged = contentOf(windowId);
    expectPlacement(windowId, normalFrame, 0, "before a close during a drag");
    mark = recordMark();
    [window close];
    host.pointerHeld = NO;
    pump(0.3);
    expectPlacement(windowId, dragged, 0, "closed during a drag");
    record = lastRecord(windowId, mark);
    CHECK(record && record->open == 0 && NSEqualRects(record->placement, dragged), "close during a drag: the close event carries the dragged placement");
    // Unknown ids have no placement; a closed one keeps answering.
    CHECK(!placementOf(987654).found, "an id the host never created has no placement");
    pump(0.05);
    CHECK(placementOf(windowId).found, "a closed window keeps answering");
}

typedef struct {
    const char *name;
    int show;
    uint32_t flags;
    int style;
} show_case_t;

static void caseZoomedOpenShowModes(void) {
    const show_case_t cases[] = {
        { "immediate", 0, 0, 0 },
        { "immediate passive", 0, 1u << 3, 1 },
        { "first-present", 1, 0, 2 },
        { "hidden", 2, 0, 3 },
        { "hidden passive", 2, 1u << 3, 0 },
    };
    for (size_t index = 0; index < sizeof(cases) / sizeof(cases[0]); index++) {
        const show_case_t c = cases[index];
        int mark = recordMark();
        uint64_t windowId = createWindow(c.style, 0, normalFrame, 0, c.show, c.flags | (1u << 6), YES);
        NSWindow *window = windowOf(windowId);
        CHECK(zoomed(windowId), "%s: zoomed at create", c.name);
        CHECK(window.isVisible == (c.show == 0), "%s: visible=%d at create", c.name, window.isVisible);
        expectPlacement(windowId, normalFrame, 1, c.name);
        double x = 0, y = 0, width = 0, height = 0, scale = 0;
        int maximized = 0;
        CHECK(native_sdk_appkit_window_frame((__bridge native_sdk_appkit_host_t *)host, windowId, &x, &y, &width, &height, &scale, &maximized) && maximized == 1,
            "%s: createWindow's info reports maximized", c.name);
        CHECK(NSEqualRects(NSMakeRect(x, y, width, height), contentOf(windowId)) && width > normalFrame.size.width, "%s: createWindow's info carries the zoomed frame", c.name);
        if (c.show == 1) {
            CHECK(pumpUntil(3.0, ^BOOL { return window.isVisible; }), "%s: the fallback deadline reveals it", c.name);
        } else if (c.show == 2) {
            pump(0.1);
            CHECK(!window.isVisible, "%s: stays hidden", c.name);
            // The zoom's frame event at create already says hidden.
            for (int record = mark; record < record_count; record++) {
                if (records[record].id == windowId) CHECK(records[record].hidden == 1, "%s: frame event %d before the show reports hidden=0", c.name, record);
            }
            [host showWindowWithId:windowId];
        }
        pump(0.2);
        CHECK(window.isVisible && zoomed(windowId), "%s: shown zoomed", c.name);
        for (int record = mark; record < record_count; record++) {
            if (records[record].id == windowId) CHECK(records[record].maximized == 1 && records[record].placement_maximized == 1, "%s: frame event %d reports unzoomed", c.name, record);
        }
        [window zoom:nil];
        pump(0.05);
        CHECK(NSEqualRects(contentOf(windowId), normalFrame), "%s: unzoom returns to %s, got %s", c.name, R(normalFrame), R(contentOf(windowId)));
        expectPlacement(windowId, normalFrame, 0, "unzoomed after a zoomed open");
        closeWindow(windowId);
    }
    // A zoomed open while a pointer button is held (the click that opened
    // the window): the zoom's resize settle is deferred, and the create's
    // own settle emits the frame event that carries the zoomed placement.
    int held = recordMark();
    host.pointerHeld = YES;
    uint64_t heldId = createWindow(0, 0, normalFrame, 0, 2, 1u << 6, YES);
    expectPlacement(heldId, normalFrame, 1, "zoomed open while a button is held");
    expectLastEventCarries(heldId, held, "zoomed open while a button is held");
    host.pointerHeld = NO;
    pump(0.3);
    expectPlacement(heldId, normalFrame, 1, "zoomed open after the button is released");
    closeWindow(heldId);
    // No zoom for a window that cannot resize. AppKit's own isZoomed
    // says YES for every non-resizable window (its frame is the only
    // frame it can have), which is why the host's notion of zoomed
    // requires a resizable window.
    uint64_t windowId = createWindow(0, 0, normalFrame, 0, 0, 1u << 6, NO);
    fprintf(stderr, "non-resizable window: AppKit isZoomed=%d\n", windowOf(windowId).isZoomed);
    CHECK(!zoomed(windowId) && NSEqualRects(contentOf(windowId), normalFrame), "non-resizable: not zoomed, at %s", R(contentOf(windowId)));
    expectPlacement(windowId, normalFrame, 0, "non-resizable");
    int mark = recordMark();
    [host emitWindowFrameForWindowId:windowId open:YES];
    const frame_record_t *record = lastRecord(windowId, mark);
    CHECK(record && record->maximized == 0, "non-resizable: frame events report unzoomed");
    closeWindow(windowId);
}

static void caseRemovedScreen(void) {
    // A saved frame on a display that is gone lands on a remaining one,
    // and the placement answers where the window really is.
    const NSRect gone = NSMakeRect(-6000, -4000, 720, 480);
    uint64_t windowId = restoreWindow(0, 0, gone, NO);
    NSRect content = contentOf(windowId);
    BOOL onScreen = NO;
    for (NSScreen *screen in NSScreen.screens) {
        if (NSContainsRect(screen.visibleFrame, [windowOf(windowId) frameRectForContentRect:content])) onScreen = YES;
    }
    CHECK(onScreen && NSEqualSizes(content.size, gone.size), "removed screen: %s lands on a screen at its size", R(content));
    expectPlacement(windowId, content, 0, "removed screen");
    closeWindow(windowId);
    windowId = restoreWindow(0, 0, gone, YES);
    CHECK(zoomed(windowId), "removed screen: opens zoomed on a remaining screen");
    expectPlacement(windowId, content, 1, "removed screen, zoomed");
    [windowOf(windowId) zoom:nil];
    pump(0.05);
    CHECK(NSEqualRects(contentOf(windowId), content), "removed screen: unzoom returns to %s, got %s", R(content), R(contentOf(windowId)));
    closeWindow(windowId);
}

static void caseStartupWindow(NSRect startupNormal, BOOL visibleBeforeRun) {
    // The startup window was created zoomed in init and shown by run.
    CHECK(!visibleBeforeRun, "startup: not shown before run");
    NSWindow *window = windowOf(1);
    CHECK(window.isVisible && zoomed(1), "startup: shown zoomed");
    expectPlacement(1, startupNormal, 1, "startup window");
    for (int index = 0; index < record_count; index++) {
        if (records[index].id == 1) CHECK(records[index].maximized == 1, "startup: frame event %d reports unzoomed", index);
    }
    int mark = recordMark();
    [window zoom:nil];
    pump(0.05);
    CHECK(NSEqualRects(contentOf(1), startupNormal), "startup: unzoom returns to %s, got %s", R(startupNormal), R(contentOf(1)));
    expectLastEventCarries(1, mark, "startup unzoom");
}

static void caseQuitDuringDrag(void) {
    // A quit while a drag holds a settle back: the frame event that
    // settles it lands before SHUTDOWN.
    NSWindow *window = windowOf(1);
    NSRect before = placementOf(1).frame;
    host.pointerHeld = YES;
    [window setFrameOrigin:NSMakePoint(window.frame.origin.x + 30, window.frame.origin.y - 30)];
    pump(0.2);
    expectPlacement(1, before, 0, "startup during a drag");
    int mark = recordMark();
    [host emitShutdown];
    CHECK(shutdown_seen, "quit: shutdown emitted");
    const frame_record_t *record = lastRecord(1, mark);
    NSRect content = contentOf(1);
    CHECK(record && record->before_shutdown && NSEqualRects(record->placement, content), "quit: a frame event carrying the dragged placement precedes SHUTDOWN");
    expectPlacement(1, content, 0, "quit during a drag");
    host.pointerHeld = NO;
}

static NSRect startupNormal;
static BOOL startupVisibleBeforeRun;

@implementation NativeSdkPlacementTestHost (Cases)
- (void)runCases {
    printf("screens=%lu, app active=%d\n", (unsigned long)NSScreen.screens.count, NSApp.isActive);
    caseStartupWindow(startupNormal, startupVisibleBeforeRun);
    caseRoundTrip();
    caseZoomedRoundTrip();
    for (int style = 0; style <= 3; style++) caseSettleRule(style);
    caseFullScreenNotifications(NO);
    caseFullScreenNotifications(YES);
    caseRealFullScreen(NO);
    caseRealFullScreen(YES);
    caseCloseBeforeSettle();
    caseZoomedOpenShowModes();
    caseRemovedScreen();
    caseQuitDuringDrag();
    CHECK(!record_overflow, "frame record overflow");
    fprintf(stderr, "window placement: %d checks, %d failures, %d skipped\n", checks, failures, skips);
    fflush(stdout);
    fflush(stderr);
    exit(failures == 0 ? 0 : 1);
}
@end

int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        normalFrame = fittedFrame(40, 720, 480);
        startupNormal = fittedFrame(20, 640, 400);
        host = [[NativeSdkPlacementTestHost alloc] initWithAppName:@"placement-test" displayName:@"Placement Test" version:@"" aboutDescription:@""
            hasWebContent:NO webViewInspection:NO dockVisible:YES windowTitle:@"Placement Test" bundleIdentifier:@"dev.native_sdk.placement_test"
            iconPath:@"" windowLabel:@"main" x:startupNormal.origin.x y:startupNormal.origin.y width:startupNormal.size.width height:startupNormal.size.height
            restoreFrame:YES initialPlacement:0 restorePolicy:0 resizable:YES titlebarStyle:0 showPolicy:0 windowFlags:(1u << 6)];
        startupVisibleBeforeRun = windowOf(1).isVisible;
        [host runWithCallback:NULL context:NULL];
    }
    return 1;
}

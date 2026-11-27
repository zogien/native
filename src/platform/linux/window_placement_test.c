/* Window placement against the production GTK host: gtk_host.c is
 * compiled into this harness, which drives real windows on an X11
 * display and checks
 *
 *  - the content size round trip for every titlebar style: a window
 *    created with a content size lays its content out at exactly that
 *    size, the placement cache answers it, and a relaunch from the
 *    answer reproduces it (no per-launch shrink);
 *  - the settle rule: a resize stream keeps answering the pre-resize
 *    placement and settles once, with one frame event carrying the new
 *    answer, after the stream stops;
 *  - a close and a quit fold a still-pending settle into the answer the
 *    close event / the last frame event before SHUTDOWN reads, and a
 *    window closed before it was ever mapped keeps its seeded answer;
 *  - with a window manager on the display: maximize and unmaximize settle
 *    at once and keep the normal size, a maximized open works through
 *    every show mode without a frame event flipping maximized back, and
 *    a window closed while maximized persists maximized over its normal
 *    size.
 *
 * Run it under an X11 server (xvfb-run); start a window manager there
 * (openbox in CI) for the maximize cases, which are skipped, loudly,
 * without one. Exit status 0 means every check passed. */
#include "gtk_host.c"

#include <gdk/x11/gdkx.h>
#include <X11/Xatom.h>

static native_sdk_gtk_host_t *test_host;
static int failures;
static int checks;
static int window_manager;
static uint64_t next_window_id = 100;

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
    double width;
    double height;
    int open;
    int maximized;
    int has_placement;
    native_sdk_gtk_placement_t placement;
    int before_shutdown;
} frame_record_t;

#define MAX_RECORDS 16384
static frame_record_t records[MAX_RECORDS];
static int record_count;
static int shutdown_seen;
static int record_overflow;

static gboolean run_cases(gpointer data);

static void on_event(void *context, const native_sdk_gtk_event_t *event) {
    (void)context;
    if (event->kind == NATIVE_SDK_GTK_EVENT_START) {
        g_idle_add(run_cases, NULL);
        return;
    }
    if (event->kind == NATIVE_SDK_GTK_EVENT_SHUTDOWN) {
        shutdown_seen = 1;
        return;
    }
    if (event->kind != NATIVE_SDK_GTK_EVENT_WINDOW_FRAME) return;
    if (record_count == MAX_RECORDS) {
        record_overflow = 1;
        return;
    }
    frame_record_t *record = &records[record_count++];
    memset(record, 0, sizeof(*record));
    record->id = event->window_id;
    record->width = event->width;
    record->height = event->height;
    record->open = event->open;
    record->maximized = event->maximized;
    record->before_shutdown = !shutdown_seen;
    const native_sdk_gtk_placement_t *placement = native_sdk_find_placement(test_host, event->window_id);
    if (placement) {
        record->has_placement = 1;
        record->placement = *placement;
    }
}

/* ------------------------------------------------------------------------
 * Loop and window helpers. */

static gboolean pump_wake(gpointer data) {
    *(int *)data = 1;
    return G_SOURCE_REMOVE;
}

static void pump(int ms) {
    int done = 0;
    g_timeout_add((guint)ms, pump_wake, &done);
    while (!done) g_main_context_iteration(NULL, TRUE);
}

static native_sdk_gtk_window_t *window_of(uint64_t id) {
    return native_sdk_find_window(test_host, id);
}

static int content_width(uint64_t id) {
    native_sdk_gtk_window_t *win = window_of(id);
    return win && win->root_box ? gtk_widget_get_width(win->root_box) : 0;
}

static int content_height(uint64_t id) {
    native_sdk_gtk_window_t *win = window_of(id);
    return win && win->root_box ? gtk_widget_get_height(win->root_box) : 0;
}

static int is_allocated(uint64_t id, const void *arg) {
    (void)arg;
    return content_width(id) > 0 && content_height(id) > 0;
}

static int is_closed(uint64_t id, const void *arg) {
    (void)arg;
    return window_of(id) == NULL;
}

typedef struct {
    int width;
    int height;
} size_arg_t;

static int has_content_size(uint64_t id, const void *arg) {
    const size_arg_t *size = arg;
    return content_width(id) == size->width && content_height(id) == size->height;
}

static int is_maximized_and_grown(uint64_t id, const void *arg) {
    const size_arg_t *normal = arg;
    native_sdk_gtk_window_t *win = window_of(id);
    return win && gtk_window_is_maximized(win->gtk_window) &&
           (content_width(id) > normal->width || content_height(id) > normal->height);
}

static int settle_pending(uint64_t id, const void *arg) {
    (void)arg;
    native_sdk_gtk_window_t *win = window_of(id);
    return win && win->placement_settle_source != 0;
}

static int wait_until(int (*condition)(uint64_t, const void *), uint64_t id, const void *arg, int timeout_ms) {
    for (int waited = 0; waited < timeout_ms; waited += 10) {
        if (condition(id, arg)) return 1;
        pump(10);
    }
    return condition(id, arg);
}

static uint64_t create_window(int style, double x, double y, double width, double height, int resizable, int show_policy, uint32_t flags) {
    const uint64_t id = next_window_id++;
    char label[32];
    snprintf(label, sizeof(label), "w%llu", (unsigned long long)id);
    const int created = native_sdk_gtk_create_window(test_host, id, "placement", strlen("placement"), label, strlen(label),
                                                     x, y, width, height, 1, 0, 0, resizable, style, 0, 0, show_policy, flags);
    CHECK(created, "create window %llu (style %d)", (unsigned long long)id, style);
    return created ? id : 0;
}

static void close_window(uint64_t id) {
    native_sdk_gtk_window_t *win = window_of(id);
    if (!win) return;
    gtk_window_close(win->gtk_window);
    CHECK(wait_until(is_closed, id, NULL, 3000), "window %llu closes", (unsigned long long)id);
}

static int query(uint64_t id, native_sdk_gtk_placement_t *out) {
    memset(out, 0, sizeof(*out));
    out->id = id;
    return native_sdk_gtk_window_placement(test_host, id, &out->x, &out->y, &out->width, &out->height, &out->maximized);
}

static int placement_is(const native_sdk_gtk_placement_t *placement, double x, double y, double width, double height, int maximized) {
    return placement->x == x && placement->y == y && placement->width == width && placement->height == height &&
           placement->maximized == maximized;
}

static const frame_record_t *last_record(uint64_t id, int open) {
    for (int i = record_count - 1; i >= 0; i--) {
        if (records[i].id == id && records[i].open == open) return &records[i];
    }
    return NULL;
}

/* An external resize, the way a window manager applies the user's
 * resize drag: a configure of the toplevel, which GTK takes as the new
 * normal size. */
static void resize_externally(uint64_t id, int delta_width, int delta_height) {
    native_sdk_gtk_window_t *win = window_of(id);
    if (!win) return;
    GdkSurface *surface = gtk_native_get_surface(GTK_NATIVE(win->gtk_window));
    Display *display = gdk_x11_display_get_xdisplay(gdk_surface_get_display(surface));
    XResizeWindow(display, gdk_x11_surface_get_xid(surface),
                  (unsigned)(gdk_surface_get_width(surface) + delta_width),
                  (unsigned)(gdk_surface_get_height(surface) + delta_height));
    XFlush(display);
}

static int detect_window_manager(void) {
    GdkDisplay *gdk_display = gdk_display_get_default();
    Display *display = gdk_x11_display_get_xdisplay(gdk_display);
    Atom check = XInternAtom(display, "_NET_SUPPORTING_WM_CHECK", True);
    if (check == None) return 0;
    Atom type = None;
    int format = 0;
    unsigned long count = 0, after = 0;
    unsigned char *data = NULL;
    const int status = XGetWindowProperty(display, DefaultRootWindow(display), check, 0, 1, False, XA_WINDOW,
                                          &type, &format, &count, &after, &data);
    const int found = status == Success && data && count == 1;
    if (data) XFree(data);
    return found;
}

static const char *style_name(int style) {
    static const char *names[] = { "standard", "hidden_inset", "hidden_inset_tall", "chromeless" };
    return style >= 0 && style < 4 ? names[style] : "?";
}

/* ------------------------------------------------------------------------
 * Cases. */

/* Create with a content size, check the content and the answer, close,
 * and relaunch from the answer: three launches must agree exactly. */
static void case_round_trip(int style, int width, int height) {
    double saved_width = width, saved_height = height;
    for (int launch = 0; launch < 3; launch++) {
        const uint64_t id = create_window(style, 37, 21, saved_width, saved_height, 1, 0, 0);
        if (!id) return;
        CHECK(wait_until(is_allocated, id, NULL, 5000), "%s window %llu gets an allocation", style_name(style), (unsigned long long)id);
        pump(100);
        CHECK(content_width(id) == width && content_height(id) == height,
              "%s launch %d: content %dx%d, expected %dx%d", style_name(style), launch,
              content_width(id), content_height(id), width, height);
        const frame_record_t *frame = last_record(id, 1);
        CHECK(frame && frame->width == width && frame->height == height,
              "%s launch %d: the frame event reports the content size (%gx%g)", style_name(style), launch,
              frame ? frame->width : -1, frame ? frame->height : -1);
        native_sdk_gtk_placement_t placement;
        CHECK(query(id, &placement) && placement_is(&placement, 37, 21, width, height, 0),
              "%s launch %d: placement %g,%g %gx%g max=%d", style_name(style), launch,
              placement.x, placement.y, placement.width, placement.height, placement.maximized);
        close_window(id);
        const frame_record_t *closed = last_record(id, 0);
        CHECK(closed && closed->has_placement && placement_is(&closed->placement, 37, 21, width, height, 0),
              "%s launch %d: the close event reads the placement", style_name(style), launch);
        native_sdk_gtk_placement_t after_close;
        CHECK(query(id, &after_close) && placement_is(&after_close, 37, 21, width, height, 0),
              "%s launch %d: the placement answers after close", style_name(style), launch);
        saved_width = after_close.width;
        saved_height = after_close.height;
    }
}

/* A resize stream answers the pre-resize placement until it stops, then
 * settles once onto the live content size. */
static void case_resize_settles_once(int style) {
    const uint64_t id = create_window(style, 0, 0, 720, 480, 1, 0, 0);
    if (!id) return;
    CHECK(wait_until(is_allocated, id, NULL, 5000), "%s window gets an allocation", style_name(style));
    pump(NATIVE_SDK_PLACEMENT_SETTLE_MS + 200);
    native_sdk_gtk_placement_t before;
    query(id, &before);
    const int first_record = record_count;
    /* The stream must stay faster than the settle wait; a machine that
     * stalls longer than that between two steps has settled mid-stream
     * legitimately, so the per-step and once-only checks are skipped
     * (loudly) for that run instead of failing it. */
    gint64 last_step = g_get_monotonic_time();
    gint64 longest_gap_us = 0;
    int mid_stream_changes = 0;
    for (int step = 1; step <= 8; step++) {
        resize_externally(id, 15, 9);
        pump(40);
        const gint64 now = g_get_monotonic_time();
        if (now - last_step > longest_gap_us) longest_gap_us = now - last_step;
        last_step = now;
        native_sdk_gtk_placement_t during;
        query(id, &during);
        if (!placement_is(&during, before.x, before.y, before.width, before.height, before.maximized)) mid_stream_changes++;
    }
    const int stalled = longest_gap_us >= (gint64)(NATIVE_SDK_PLACEMENT_SETTLE_MS - 50) * 1000;
    if (stalled) {
        printf("NOTE %s resize stream stalled %lld ms between steps: settle-count checks skipped\n", style_name(style), (long long)(longest_gap_us / 1000));
    } else {
        CHECK(mid_stream_changes == 0, "%s resize stream: the answer changed at %d steps before the stream stopped", style_name(style), mid_stream_changes);
    }
    pump(NATIVE_SDK_PLACEMENT_SETTLE_MS + 400);
    native_sdk_gtk_placement_t after;
    query(id, &after);
    CHECK(after.width == content_width(id) && after.height == content_height(id) && after.width > before.width,
          "%s settled placement %gx%g matches the content %dx%d", style_name(style), after.width, after.height,
          content_width(id), content_height(id));
    int changes = 0, frames = 0;
    native_sdk_gtk_placement_t seen = before;
    for (int i = first_record; i < record_count; i++) {
        if (records[i].id != id || !records[i].has_placement) continue;
        frames++;
        const native_sdk_gtk_placement_t *p = &records[i].placement;
        if (!placement_is(p, seen.x, seen.y, seen.width, seen.height, seen.maximized)) {
            changes++;
            seen = *p;
        }
    }
    if (!stalled) CHECK(changes == 1, "%s resize stream: %d placement changes across %d frame events, expected 1", style_name(style), changes, frames);
    close_window(id);
}

/* A close inside the settle wait persists the new size. */
static void case_close_folds_pending_settle(void) {
    const uint64_t id = create_window(1, 0, 0, 720, 480, 1, 0, 0);
    if (!id) return;
    CHECK(wait_until(is_allocated, id, NULL, 5000), "window gets an allocation");
    pump(NATIVE_SDK_PLACEMENT_SETTLE_MS + 200);
    resize_externally(id, 40, 30);
    CHECK(wait_until(settle_pending, id, NULL, 3000), "the resize starts a settle wait");
    native_sdk_gtk_window_t *win = window_of(id);
    int default_width = 0, default_height = 0;
    gtk_window_get_default_size(win->gtk_window, &default_width, &default_height);
    const double expected_width = default_width - win->chrome_width;
    const double expected_height = default_height - win->chrome_height;
    native_sdk_gtk_placement_t pending;
    query(id, &pending);
    CHECK(placement_is(&pending, 0, 0, 720, 480, 0), "inside the settle wait the answer is still 720x480 (%gx%g)", pending.width, pending.height);
    close_window(id);
    const frame_record_t *closed = last_record(id, 0);
    CHECK(closed && closed->has_placement && placement_is(&closed->placement, 0, 0, expected_width, expected_height, 0),
          "the close event reads the pending size %gx%g (got %gx%g)", expected_width, expected_height,
          closed ? closed->placement.width : -1, closed ? closed->placement.height : -1);
}

/* A window closed before it was ever mapped answers its seeded placement. */
static void case_close_before_map(void) {
    const uint64_t id = create_window(2, 5, 6, 640, 400, 1, 2, 0);
    if (!id) return;
    close_window(id);
    const frame_record_t *closed = last_record(id, 0);
    CHECK(closed && closed->has_placement && placement_is(&closed->placement, 5, 6, 640, 400, 0),
          "a never-shown window's close event reads the seeded placement");
}

/* A non-resizable window never opens maximized. */
static void case_non_resizable_opens_normal(void) {
    const uint64_t id = create_window(1, 0, 0, 500, 360, 0, 0, 1u << 6);
    if (!id) return;
    native_sdk_gtk_placement_t seeded;
    CHECK(query(id, &seeded) && placement_is(&seeded, 0, 0, 500, 360, 0), "a non-resizable window seeds a normal placement");
    CHECK(wait_until(is_allocated, id, NULL, 5000), "non-resizable window gets an allocation");
    pump(100);
    CHECK(content_width(id) == 500 && content_height(id) == 360, "non-resizable content %dx%d", content_width(id), content_height(id));
    close_window(id);
}

/* Maximize and unmaximize settle at once and keep the normal size; a
 * close while maximized persists maximized over it. */
static void case_maximize(int style) {
    const size_arg_t normal = { 720, 480 };
    const uint64_t id = create_window(style, 0, 0, normal.width, normal.height, 1, 0, 0);
    if (!id) return;
    CHECK(wait_until(is_allocated, id, NULL, 5000), "%s window gets an allocation", style_name(style));
    pump(200);
    native_sdk_gtk_window_t *win = window_of(id);
    gtk_window_maximize(win->gtk_window);
    CHECK(wait_until(is_maximized_and_grown, id, &normal, 5000), "%s window maximizes", style_name(style));
    native_sdk_gtk_placement_t placement;
    query(id, &placement);
    CHECK(placement_is(&placement, 0, 0, normal.width, normal.height, 1),
          "%s maximized placement %gx%g max=%d", style_name(style), placement.width, placement.height, placement.maximized);
    const frame_record_t *frame = last_record(id, 1);
    CHECK(frame && frame->maximized, "%s frame events report the live maximize", style_name(style));
    gtk_window_unmaximize(win->gtk_window);
    CHECK(wait_until(has_content_size, id, &normal, 5000), "%s unmaximize returns to %dx%d (now %dx%d)", style_name(style),
          normal.width, normal.height, content_width(id), content_height(id));
    pump(NATIVE_SDK_PLACEMENT_SETTLE_MS + 200);
    query(id, &placement);
    CHECK(placement_is(&placement, 0, 0, normal.width, normal.height, 0),
          "%s restored placement %gx%g max=%d", style_name(style), placement.width, placement.height, placement.maximized);
    frame = last_record(id, 1);
    CHECK(frame && !frame->maximized, "%s frame events report the restore", style_name(style));
    gtk_window_maximize(win->gtk_window);
    CHECK(wait_until(is_maximized_and_grown, id, &normal, 5000), "%s window maximizes again", style_name(style));
    close_window(id);
    const frame_record_t *closed = last_record(id, 0);
    CHECK(closed && closed->has_placement && placement_is(&closed->placement, 0, 0, normal.width, normal.height, 1),
          "%s closed while maximized: maximized over the normal size", style_name(style));
}

enum { SHOW_PRESENT, SHOW_NO_ACTIVATE, SHOW_HIDDEN_THEN_SHOW, SHOW_FIRST_PRESENT };

static const char *show_name(int variant) {
    static const char *names[] = { "present", "no-activate", "hidden-then-show", "first-present" };
    return names[variant];
}

/* A maximized open through every show mode: maximized from the first
 * frame event on, and Unmaximize returns to the normal size. */
static void case_initial_maximized(int style, int variant) {
    const size_arg_t normal = { 760, 500 };
    const int show_policy = variant == SHOW_HIDDEN_THEN_SHOW ? 2 : variant == SHOW_FIRST_PRESENT ? 1 : 0;
    const uint32_t flags = (1u << 6) | (variant == SHOW_NO_ACTIVATE ? 1u << 3 : 0);
    const int first_record = record_count;
    const uint64_t id = create_window(style, 0, 0, normal.width, normal.height, 1, show_policy, flags);
    if (!id) return;
    native_sdk_gtk_placement_t placement;
    CHECK(query(id, &placement) && placement_is(&placement, 0, 0, normal.width, normal.height, 1),
          "%s/%s: the create-time placement is maximized", style_name(style), show_name(variant));
    if (variant == SHOW_HIDDEN_THEN_SHOW) {
        pump(200);
        CHECK(native_sdk_gtk_show_window(test_host, id), "show the hidden window");
    }
    CHECK(wait_until(is_maximized_and_grown, id, &normal, 5000), "%s/%s opens maximized (content %dx%d)",
          style_name(style), show_name(variant), content_width(id), content_height(id));
    pump(200);
    int flipped = 0;
    for (int i = first_record; i < record_count; i++) {
        if (records[i].id == id && records[i].open && !records[i].maximized) flipped++;
    }
    CHECK(flipped == 0, "%s/%s: %d frame events reported a normal window before the restore", style_name(style), show_name(variant), flipped);
    native_sdk_gtk_window_t *win = window_of(id);
    gtk_window_unmaximize(win->gtk_window);
    CHECK(wait_until(has_content_size, id, &normal, 5000), "%s/%s: unmaximize returns to %dx%d (now %dx%d)",
          style_name(style), show_name(variant), normal.width, normal.height, content_width(id), content_height(id));
    query(id, &placement);
    CHECK(placement_is(&placement, 0, 0, normal.width, normal.height, 0), "%s/%s: restored placement %gx%g max=%d",
          style_name(style), show_name(variant), placement.width, placement.height, placement.maximized);
    close_window(id);
}

/* A hidden window, shown and then maximized. */
static void case_show_hidden_then_maximize(void) {
    const size_arg_t normal = { 700, 450 };
    const uint64_t id = create_window(1, 0, 0, normal.width, normal.height, 1, 2, 0);
    if (!id) return;
    pump(200);
    CHECK(native_sdk_gtk_show_window(test_host, id), "show the hidden window");
    CHECK(wait_until(is_allocated, id, NULL, 5000), "shown window gets an allocation");
    pump(200);
    gtk_window_maximize(window_of(id)->gtk_window);
    CHECK(wait_until(is_maximized_and_grown, id, &normal, 5000), "shown window maximizes");
    native_sdk_gtk_placement_t placement;
    query(id, &placement);
    CHECK(placement_is(&placement, 0, 0, normal.width, normal.height, 1), "shown-then-maximized placement %gx%g max=%d",
          placement.width, placement.height, placement.maximized);
    close_window(id);
}

/* The quit verb inside a settle wait: the last frame event before
 * SHUTDOWN carries the new size. With a window manager, a window
 * maximized and then hidden stays open across the quit too: whatever
 * maximized state it has by then is what the store must hold. Checked
 * in main, after the loop. */
static uint64_t quit_window;
static double quit_expected_width;
static double quit_expected_height;
static uint64_t hidden_window;

static void case_quit_folds_pending_settle(void) {
    if (window_manager) {
        const size_arg_t normal = { 600, 400 };
        hidden_window = create_window(2, 0, 0, normal.width, normal.height, 1, 0, 0);
        if (hidden_window) {
            CHECK(wait_until(is_allocated, hidden_window, NULL, 5000), "hidden-at-quit window gets an allocation");
            gtk_window_maximize(window_of(hidden_window)->gtk_window);
            CHECK(wait_until(is_maximized_and_grown, hidden_window, &normal, 5000), "hidden-at-quit window maximizes");
            CHECK(native_sdk_gtk_hide_window(test_host, hidden_window), "hide the maximized window");
            pump(500);
            printf("a maximized window hidden: GTK reports maximized=%d\n", gtk_window_is_maximized(window_of(hidden_window)->gtk_window) ? 1 : 0);
        }
    }
    quit_window = create_window(1, 0, 0, 720, 480, 1, 0, 0);
    if (!quit_window) return;
    CHECK(wait_until(is_allocated, quit_window, NULL, 5000), "quit window gets an allocation");
    pump(NATIVE_SDK_PLACEMENT_SETTLE_MS + 200);
    resize_externally(quit_window, 50, 20);
    CHECK(wait_until(settle_pending, quit_window, NULL, 3000), "the resize starts a settle wait");
    native_sdk_gtk_window_t *win = window_of(quit_window);
    int default_width = 0, default_height = 0;
    gtk_window_get_default_size(win->gtk_window, &default_width, &default_height);
    quit_expected_width = default_width - win->chrome_width;
    quit_expected_height = default_height - win->chrome_height;
    native_sdk_gtk_stop(test_host);
}

static gboolean run_cases(gpointer data) {
    (void)data;
    window_manager = detect_window_manager();
    printf("window manager on the display: %s\n", window_manager ? "yes" : "no - maximize cases SKIPPED");
    /* CI starts one and must not pass by skipping. */
    CHECK(window_manager || !getenv("NATIVE_SDK_TEST_REQUIRE_WM"), "NATIVE_SDK_TEST_REQUIRE_WM is set but no window manager runs on the display");
    for (int style = 0; style < 4; style++) case_round_trip(style, 720, 480);
    case_round_trip(2, 1040, 640);
    case_resize_settles_once(0);
    case_resize_settles_once(1);
    case_close_folds_pending_settle();
    case_close_before_map();
    case_non_resizable_opens_normal();
    if (window_manager) {
        for (int style = 0; style < 4; style++) case_maximize(style);
        for (int variant = SHOW_PRESENT; variant <= SHOW_FIRST_PRESENT; variant++) case_initial_maximized(1, variant);
        case_initial_maximized(0, SHOW_PRESENT);
        case_show_hidden_then_maximize();
    }
    case_quit_folds_pending_settle();
    return G_SOURCE_REMOVE;
}

int main(void) {
    if (!getenv("DISPLAY")) {
        fprintf(stderr, "window placement test: no DISPLAY - run it under an X11 server (xvfb-run)\n");
        return 1;
    }
    gdk_set_allowed_backends("x11");
    /* The main window stays hidden for the whole run, so closing the
     * test windows never ends the loop: only the quit case does. */
    test_host = native_sdk_gtk_create("placement-test", strlen("placement-test"), "", 0,
                                      "dev.native_sdk.window_placement_test", strlen("dev.native_sdk.window_placement_test"),
                                      "", 0, "main", 4, 0, 0, 320, 200, 1, 2, 0, 1, 0, 0, 0, 2, 0);
    if (!test_host) {
        fprintf(stderr, "window placement test: host create failed\n");
        return 1;
    }
    native_sdk_gtk_run(test_host, on_event, NULL);

    CHECK(shutdown_seen, "the quit reaches SHUTDOWN");
    int quit_saved = 0;
    for (int i = 0; i < record_count; i++) {
        const frame_record_t *record = &records[i];
        if (record->id == quit_window && record->open && record->before_shutdown && record->has_placement &&
            placement_is(&record->placement, 0, 0, quit_expected_width, quit_expected_height, 0)) {
            quit_saved = 1;
        }
    }
    CHECK(quit_window && quit_saved, "a frame event before SHUTDOWN carries the pending size %gx%g", quit_expected_width, quit_expected_height);
    if (hidden_window) {
        /* The live state at quit (the window still exists until destroy)
         * must be what the last frame event before SHUTDOWN read. */
        native_sdk_gtk_window_t *hidden = window_of(hidden_window);
        const int live_maximized = hidden && gtk_window_is_maximized(hidden->gtk_window) ? 1 : 0;
        const frame_record_t *last = NULL;
        for (int i = 0; i < record_count; i++) {
            if (records[i].id == hidden_window && records[i].before_shutdown && records[i].has_placement) last = &records[i];
        }
        CHECK(last && placement_is(&last->placement, 0, 0, 600, 400, live_maximized),
              "the hidden window's last frame event before SHUTDOWN reads 600x400 max=%d (got %gx%g max=%d)", live_maximized,
              last ? last->placement.width : -1, last ? last->placement.height : -1, last ? last->placement.maximized : -1);
    }
    CHECK(!record_overflow, "frame record buffer overflowed");
    native_sdk_gtk_destroy(test_host);

    printf("window placement test: %d checks, %d failures%s\n", checks, failures, window_manager ? "" : " (maximize cases skipped: no window manager)");
    return failures == 0 ? 0 : 1;
}

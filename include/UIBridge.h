#ifndef UI_BRIDGE_H
#define UI_BRIDGE_H

#include <stdint.h>

/* Node types */
#define UI_NODE_TEXT       0
#define UI_NODE_BUTTON     1
#define UI_NODE_COLUMN     2
#define UI_NODE_ROW        3
#define UI_NODE_TEXT_INPUT  4
#define UI_NODE_SCROLL_VIEW 5
#define UI_NODE_IMAGE       6
#define UI_NODE_MAP_VIEW    7
#define UI_NODE_WEBVIEW     8
#define UI_NODE_STACK       9
#define UI_NODE_HORIZONTAL_SCROLL_VIEW 10
#define UI_NODE_LAZY_COLUMN 11
/* An on/off switch: UI_PROP_CHECKED, and UI_EVENT_CLICK as the user flips it. */
#define UI_NODE_SWITCH      12

/* Property IDs for string properties */
#define UI_PROP_TEXT            0
#define UI_PROP_COLOR           1
#define UI_PROP_HINT            2
#define UI_PROP_BG_COLOR        3
#define UI_PROP_IMAGE_RESOURCE  4
#define UI_PROP_IMAGE_FILE      5
#define UI_PROP_WEBVIEW_URL     6
#define UI_PROP_IMAGE_STREAM    7

/* Property IDs for numeric properties */
#define UI_PROP_FONT_SIZE   0
#define UI_PROP_PADDING     1
#define UI_PROP_INPUT_TYPE  2
#define UI_PROP_GRAVITY     3
#define UI_PROP_SCALE_TYPE          4
#define UI_PROP_MAP_LAT             5
#define UI_PROP_MAP_LON             6
#define UI_PROP_MAP_ZOOM            7
#define UI_PROP_MAP_SHOW_USER_LOC   8
#define UI_PROP_TRANSLATE_X         9
#define UI_PROP_TRANSLATE_Y         10
#define UI_PROP_AUTO_FOCUS          11
#define UI_PROP_TOUCH_PASSTHROUGH   12
#define UI_PROP_WIDTH               13
#define UI_PROP_HEIGHT              14
#define UI_PROP_WEIGHT              15
#define UI_PROP_ALIGN_SELF          16
#define UI_PROP_MARGIN              17
#define UI_PROP_MAX_WIDTH           18
#define UI_PROP_CORNER_RADIUS       19
#define UI_PROP_KEEP_AT_END         20
#define UI_PROP_MAX_LINES           21
/* A lazy column's number of items, which also has it show them again. */
#define UI_PROP_ITEM_COUNT          22
/* A ListView scrolls to its end when this changes. */
#define UI_PROP_SCROLL_TO_END       23
/* A text's font: 1 bold, 2 monospace, 4 italic. */
#define UI_PROP_FONT_STYLE          24
/* Padding at the top and bottom, after UI_PROP_PADDING set all four. */
#define UI_PROP_PADDING_Y           25
/* A corner's radius of the background, clockwise from the top left; NaN
 * goes back to UI_PROP_CORNER_RADIUS. */
#define UI_PROP_CORNER_TOP_LEFT     26
#define UI_PROP_CORNER_TOP_RIGHT    27
#define UI_PROP_CORNER_BOTTOM_RIGHT 28
#define UI_PROP_CORNER_BOTTOM_LEFT  29
/* A switch is on (1) or off (0). */
#define UI_PROP_CHECKED             30

/* Event types */
#define UI_EVENT_CLICK       0
#define UI_EVENT_TEXT_CHANGE  1
#define UI_EVENT_LONG_PRESS   2
/* Where a list is, as ListPosition's number: haskellOnUIScroll. */
#define UI_EVENT_SCROLLED     3

/*
 * Function pointer table filled by the platform (Android/iOS).
 * Haskell calls through these pointers via ui_* wrappers.
 * When NULL (desktop), stubs log to stderr and return dummy IDs.
 */
typedef struct UIBridgeCallbacks {
    int32_t (*createNode)(int32_t nodeType);
    void    (*setStrProp)(int32_t nodeId, int32_t propId, const char *value);
    void    (*setNumProp)(int32_t nodeId, int32_t propId, double value);
    void    (*setImageData)(int32_t nodeId, const uint8_t *data, int32_t length);
    void    (*setHandler)(int32_t nodeId, int32_t eventType, int32_t callbackId);
    void    (*addChild)(int32_t parentId, int32_t childId);
    void    (*removeChild)(int32_t parentId, int32_t childId);
    void    (*destroyNode)(int32_t nodeId);
    void    (*setRoot)(int32_t nodeId);
    void    (*clear)(void);
    /* Optional: whether the platform shows dark colours. */
    int32_t (*darkMode)(void);
    /* Optional: put text on the clipboard, and tell the user so where the
       system doesn't, as Android does from 13 on. */
    void    (*copyText)(const char *text);
    /* Optional: let the user pick a file of a MIME type, reported to the
       app once the platform copied it where the app can read it. */
    void    (*pickFile)(const char *mimeType);
    /* Optional: show one of the app's files, by its UTF-8 path, in another app. */
    void    (*openFile)(const char *path);
    /* Optional: whether the user wants times on a 24-hour clock. */
    int32_t (*clock24)(void);
    /* Optional: open a web or mail address, in UTF-8, in another app. */
    void    (*openUri)(const char *uri);
    /* Optional: as pickFile, letting the user pick several. */
    void    (*pickFiles)(const char *mimeType);
    /* Optional: take a picture with the platform's camera app, reported
       as a picked file. */
    void    (*capturePicture)(void);
    /* Optional: let the user pick a picture, cut to a square PNG of the
       first of the sides with at most limit bytes, reported to the app. */
    void    (*pickPicture)(const int32_t *sides, int32_t count, int32_t limit);
    /* Optional: let the user save a copy of one of the app's files where
       they choose, under a suggested name, all in UTF-8. */
    void    (*saveFile)(const char *path, const char *name, const char *mimeType);
    /* Optional: the width and height a picture file shows at, the way its
       camera turned it, or 0 if it isn't one. */
    int32_t (*imageSize)(const char *path, int32_t *width, int32_t *height);
} UIBridgeCallbacks;

/* Register platform callbacks. Ownership is NOT transferred. */
void ui_register_callbacks(UIBridgeCallbacks *callbacks);

/* Platform-agnostic wrappers (delegate to callbacks or desktop stubs) */
int32_t ui_create_node(int32_t nodeType);
void    ui_set_str_prop(int32_t nodeId, int32_t propId, const char *value);
void    ui_set_num_prop(int32_t nodeId, int32_t propId, double value);
void    ui_set_image_data(int32_t nodeId, const uint8_t *data, int32_t length);
void    ui_set_handler(int32_t nodeId, int32_t eventType, int32_t callbackId);
void    ui_add_child(int32_t parentId, int32_t childId);
void    ui_remove_child(int32_t parentId, int32_t childId);
void    ui_destroy_node(int32_t nodeId);
void    ui_set_root(int32_t nodeId);
void    ui_clear(void);
int32_t ui_dark_mode(void);
int32_t ui_clock24(void);
void    ui_copy_text(const char *text);
void    ui_pick_file(const char *mimeType);
void    ui_open_file(const char *path);
void    ui_open_uri(const char *uri);
void    ui_pick_files(const char *mimeType);
void    ui_capture_picture(void);
void    ui_pick_picture(const int32_t *sides, int32_t count, int32_t limit);
void    ui_save_file(const char *path, const char *name, const char *mimeType);
int32_t ui_image_size(const char *path, int32_t *width, int32_t *height);

#endif /* UI_BRIDGE_H */

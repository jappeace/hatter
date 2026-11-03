/*
 * Android implementation of the UI bridge callbacks.
 *
 * Uses JNI to create Android views (TextView, Button, LinearLayout)
 * and manage the view hierarchy. Compiled by NDK clang, not cabal.
 *
 * All functions run on the main/UI thread — the same thread that
 * calls haskellRenderUI from Java.
 */

#include <jni.h>
#include "jni_helpers.h"
#include <stdlib.h>
#include <string.h>
#include <android/log.h>
#include "UIBridge.h"

#define LOG_TAG "UIBridge"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

/* --- Node pool configuration ---
 *
 * Two compile-time flags control the pool strategy:
 *   -DMAX_NODES=N         Override the static pool size (default 256).
 *   -DDYNAMIC_NODE_POOL   Use malloc/realloc; MAX_NODES is ignored.
 *
 * Incremental diffing means nodes persist across frames; the pool bounds
 * the total live node count.  Destroyed node IDs are reclaimed via a
 * free stack to avoid exhausting the pool during navigation. */
#ifdef DYNAMIC_NODE_POOL
  static jobject *g_nodes         = NULL;
  static int32_t  g_pool_capacity = 0;
  #define INITIAL_POOL_SIZE 256
#else
  #ifndef MAX_NODES
  #define MAX_NODES 256
  #endif
  static jobject  g_nodes[MAX_NODES];
#endif
static int32_t g_next_node_id = 1;

/* --- Free stack: reclaimed node IDs for reuse ---
 *
 * Two-buffer scheme: IDs freed during a render pass go into the
 * "pending" buffer and are NOT available for reuse until setRoot
 * flushes them into the main free stack.  This prevents same-pass
 * ID reuse which would confuse the Haskell diff engine (it uses
 * node ID equality to detect unchanged nodes). */
#ifdef DYNAMIC_NODE_POOL
  static int32_t *g_free_stack   = NULL;
  static int32_t *g_pending_free = NULL;
#else
  static int32_t  g_free_stack[MAX_NODES];
  static int32_t  g_pending_free[MAX_NODES];
#endif
static int32_t g_free_count    = 0;
static int32_t g_pending_count = 0;

/* Haskell FFI exports (declared here since this file is compiled by NDK) */
extern void haskellOnUIEvent(void *ctx, int callbackId);
extern void haskellOnUITextChange(void *ctx, int callbackId, const char *text);

/* ---- Global state (valid only on the UI thread) ---- */
static JNIEnv  *g_env      = NULL;
static jobject  g_activity  = NULL;   /* global ref to Activity */

/* Guard against re-entrant TextWatcher callbacks.
 * When setStrProp(PropText) calls editText.setText(), the TextWatcher
 * fires synchronously on the same thread.  Without this flag the cycle
 * setText → TextWatcher → haskellOnUITextChange → renderView →
 * setStrProp → setText → ... recurses until the stack overflows.
 * Safe without atomics because all calls are on the UI thread. */
static int g_setting_text_programmatically = 0;

/* Cached JNI class/method IDs, resolved once in setup by resolve_jni_ids */
static jclass   g_class_TextView;
static jclass   g_class_Button;
static jclass   g_class_Switch;
static jclass   g_class_EditText;
static jclass   g_class_LinearLayout;
static jclass   g_class_ScrollView;
static jclass   g_class_ListView;
static jclass   g_class_HorizontalScrollView;
static jclass   g_class_ImageView;
static jclass   g_class_WebView;
static jclass   g_class_FrameLayout;
static jclass   g_class_View;
static jclass   g_class_ViewGroup;
static jclass   g_class_Integer;

static jmethodID g_ctor_TextView;
static jmethodID g_ctor_Button;
static jmethodID g_ctor_Switch;
static jmethodID g_ctor_EditText;
static jmethodID g_ctor_LinearLayout;
static jmethodID g_ctor_ScrollView;
static jmethodID g_ctor_HorizontalScrollView;
static jmethodID g_ctor_ImageView;
static jmethodID g_ctor_WebView;
static jmethodID g_ctor_FrameLayout;
static jmethodID g_ctor_Integer;

static jmethodID g_method_setText;
static jmethodID g_method_setHint;
static jmethodID g_method_setOrientation;
static jmethodID g_method_addView;
static jmethodID g_method_removeView;
static jmethodID g_method_removeAllViews;
static jmethodID g_method_setContentView;
static jmethodID g_method_setTag;
static jmethodID g_method_getTag;
static jmethodID g_method_intValue;
static jmethodID g_method_setOnClickListener;
static jmethodID g_method_registerTextWatcher;
static jmethodID g_method_setInputType;
static jmethodID g_method_setTextSize;
static jmethodID g_method_setPadding;
static jmethodID g_method_setGravity_TextView;
static jmethodID g_method_setGravity_LinearLayout;
static jmethodID g_method_setTextColor;
static jmethodID g_method_setImageBitmap;
static jmethodID g_method_setScaleType;
static jmethodID g_method_loadUrl;
static jmethodID g_method_getSettings;
static jmethodID g_method_getParent;
static jmethodID g_method_setJavaScriptEnabled;
static jmethodID g_method_registerWebViewClient;
static jmethodID g_method_getChildAt;
static jmethodID g_method_requestFocusOnView;
static jmethodID g_method_setLayoutField;
static jmethodID g_method_applyLayout;
static jmethodID g_method_setCornerRadius;
static jmethodID g_method_setCorner;
static jmethodID g_method_setBackgroundColour;
static jmethodID g_method_setPaddingY;
static jmethodID g_method_setSwitch;
static jmethodID g_method_watchSwitch;
static jmethodID g_method_setTapFeedback;
static jmethodID g_method_isNightMode;
static jmethodID g_method_is24HourClock;
static jmethodID g_method_setLongPress;
static jmethodID g_method_openUri;
static jmethodID g_method_pickFiles;
static jmethodID g_method_capturePicture;
static jmethodID g_method_decodeImageData;
static jmethodID g_method_pickPicture;
static jmethodID g_method_saveFile;
static jmethodID g_method_imageSize;
static jmethodID g_method_setScrollWatch;
static jmethodID g_method_scrollToEnd;
static jmethodID g_method_copyText;
static jmethodID g_method_pickFile;
static jmethodID g_method_openFile;
static jmethodID g_method_decodeImageFile;
static jmethodID g_method_setMaxWidth;
static jmethodID g_method_setMaxLines;
static jmethodID g_method_setFontStyle;
static jmethodID g_method_keepAtEnd;
static jmethodID g_ctor_ListView;
static jmethodID g_method_initLazyList;
static jmethodID g_method_setLazyCount;
static jmethodID g_method_getText;
static jclass    g_class_CharSequence;
static jmethodID g_method_charSeqToString;

/* LinearLayout orientation constants */
static jint ORIENTATION_VERTICAL   = 1;
static jint ORIENTATION_HORIZONTAL = 0;

/* ---- Forward declarations ---- */
static int32_t android_create_node(int32_t nodeType);
static void    android_set_str_prop(int32_t nodeId, int32_t propId, const char *value);
static void    android_set_num_prop(int32_t nodeId, int32_t propId, double value);
static void    android_set_image_data(int32_t nodeId, const uint8_t *data, int32_t length);
static void    android_set_handler(int32_t nodeId, int32_t eventType, int32_t callbackId);
static void    android_add_child(int32_t parentId, int32_t childId);
static void    android_remove_child(int32_t parentId, int32_t childId);
static void    android_destroy_node(int32_t nodeId);
static void    android_set_root(int32_t nodeId);
static void    android_clear(void);
static int32_t android_dark_mode(void);
static int32_t android_clock24(void);
static void    android_copy_text(const char *text);
static void    android_pick_file(const char *mimeType);
static void    android_open_file(const char *path);
static void    android_open_uri(const char *uri);
static void    android_pick_files(const char *mimeType);
static void    android_capture_picture(void);
static void    android_pick_picture(const int32_t *sides, int32_t count, int32_t limit);
static void    android_save_file(const char *path, const char *name, const char *mimeType);
static int32_t android_image_size(const char *path, int32_t *width, int32_t *height);

static UIBridgeCallbacks g_android_callbacks = {
    .createNode   = android_create_node,
    .setStrProp   = android_set_str_prop,
    .setNumProp   = android_set_num_prop,
    .setImageData = android_set_image_data,
    .setHandler   = android_set_handler,
    .addChild     = android_add_child,
    .removeChild  = android_remove_child,
    .destroyNode  = android_destroy_node,
    .setRoot      = android_set_root,
    .clear        = android_clear,
    .darkMode     = android_dark_mode,
    .copyText     = android_copy_text,
    .pickFile     = android_pick_file,
    .openFile     = android_open_file,
    .clock24      = android_clock24,
    .openUri      = android_open_uri,
    .pickFiles    = android_pick_files,
    .capturePicture = android_capture_picture,
    .pickPicture  = android_pick_picture,
    .saveFile     = android_save_file,
    .imageSize    = android_image_size,
};

/* ---- JNI class/method resolution ---- */

/* The activity's class: its own methods ship with this file. */
static jclass g_class_Activity;
static jclass g_class_Resources;

static jmethodID g_method_setTranslationX;
static jmethodID g_method_setTranslationY;
static jmethodID g_method_setClickable;
static jmethodID g_method_setFocusable;
static jmethodID g_method_setImageDrawable;
static jmethodID g_method_getResources;
static jmethodID g_method_getPackageName;
static jmethodID g_method_getIdentifier;
static jmethodID g_method_getDrawable;

static const struct {
    jclass *cls;
    const char *name;
} g_classes[] = {
    {&g_class_TextView, "android/widget/TextView"},
    {&g_class_Button, "android/widget/Button"},
    {&g_class_Switch, "android/widget/Switch"},
    {&g_class_EditText, "android/widget/EditText"},
    /* Columns and rows that measure stretched children like a flexbox. */
    {&g_class_LinearLayout, "me/jappie/hatter/HatterLinearLayout"},
    {&g_class_ScrollView, "android/widget/ScrollView"},
    {&g_class_HorizontalScrollView, "android/widget/HorizontalScrollView"},
    {&g_class_ListView, "android/widget/ListView"},
    {&g_class_ImageView, "android/widget/ImageView"},
    {&g_class_WebView, "android/webkit/WebView"},
    {&g_class_FrameLayout, "android/widget/FrameLayout"},
    {&g_class_View, "android/view/View"},
    {&g_class_ViewGroup, "android/view/ViewGroup"},
    {&g_class_Integer, "java/lang/Integer"},
    {&g_class_CharSequence, "java/lang/CharSequence"},
    {&g_class_Resources, "android/content/res/Resources"},
};

#define CONTEXT_CTOR "(Landroid/content/Context;)V"

static const struct {
    jmethodID *id;
    jclass *cls;
    const char *name;
    const char *sig;
} g_methods[] = {
    {&g_ctor_TextView, &g_class_TextView, "<init>", CONTEXT_CTOR},
    {&g_ctor_Button, &g_class_Button, "<init>", CONTEXT_CTOR},
    {&g_ctor_Switch, &g_class_Switch, "<init>", CONTEXT_CTOR},
    {&g_ctor_EditText, &g_class_EditText, "<init>", CONTEXT_CTOR},
    {&g_ctor_LinearLayout, &g_class_LinearLayout, "<init>", CONTEXT_CTOR},
    {&g_ctor_ScrollView, &g_class_ScrollView, "<init>", CONTEXT_CTOR},
    {&g_ctor_HorizontalScrollView, &g_class_HorizontalScrollView, "<init>", CONTEXT_CTOR},
    {&g_ctor_ListView, &g_class_ListView, "<init>", CONTEXT_CTOR},
    {&g_ctor_ImageView, &g_class_ImageView, "<init>", CONTEXT_CTOR},
    {&g_ctor_WebView, &g_class_WebView, "<init>", CONTEXT_CTOR},
    {&g_ctor_FrameLayout, &g_class_FrameLayout, "<init>", CONTEXT_CTOR},
    {&g_ctor_Integer, &g_class_Integer, "<init>", "(I)V"},

    {&g_method_setText, &g_class_TextView, "setText", "(Ljava/lang/CharSequence;)V"},
    {&g_method_setHint, &g_class_TextView, "setHint", "(Ljava/lang/CharSequence;)V"},
    {&g_method_getText, &g_class_TextView, "getText", "()Ljava/lang/CharSequence;"},
    /* Size in scaled pixels. */
    {&g_method_setTextSize, &g_class_TextView, "setTextSize", "(F)V"},
    {&g_method_setGravity_TextView, &g_class_TextView, "setGravity", "(I)V"},
    {&g_method_setTextColor, &g_class_TextView, "setTextColor", "(I)V"},
    {&g_method_setMaxWidth, &g_class_TextView, "setMaxWidth", "(I)V"},
    {&g_method_setInputType, &g_class_EditText, "setInputType", "(I)V"},
    {&g_method_charSeqToString, &g_class_CharSequence, "toString", "()Ljava/lang/String;"},
    {&g_method_setOrientation, &g_class_LinearLayout, "setOrientation", "(I)V"},
    {&g_method_setGravity_LinearLayout, &g_class_LinearLayout, "setGravity", "(I)V"},
    {&g_method_addView, &g_class_ViewGroup, "addView", "(Landroid/view/View;)V"},
    {&g_method_removeView, &g_class_ViewGroup, "removeView", "(Landroid/view/View;)V"},
    {&g_method_removeAllViews, &g_class_ViewGroup, "removeAllViews", "()V"},
    {&g_method_getChildAt, &g_class_ViewGroup, "getChildAt", "(I)Landroid/view/View;"},
    /* A view's tag holds its click's callback ID. */
    {&g_method_setTag, &g_class_View, "setTag", "(Ljava/lang/Object;)V"},
    {&g_method_getTag, &g_class_View, "getTag", "()Ljava/lang/Object;"},
    {&g_method_intValue, &g_class_Integer, "intValue", "()I"},
    /* The activity is the click listener. */
    {&g_method_setOnClickListener, &g_class_View, "setOnClickListener", "(Landroid/view/View$OnClickListener;)V"},
    /* Padding in pixels. */
    {&g_method_setPadding, &g_class_View, "setPadding", "(IIII)V"},
    {&g_method_getParent, &g_class_View, "getParent", "()Landroid/view/ViewParent;"},
    {&g_method_setTranslationX, &g_class_View, "setTranslationX", "(F)V"},
    {&g_method_setTranslationY, &g_class_View, "setTranslationY", "(F)V"},
    {&g_method_setClickable, &g_class_View, "setClickable", "(Z)V"},
    {&g_method_setFocusable, &g_class_View, "setFocusable", "(Z)V"},
    {&g_method_setImageBitmap, &g_class_ImageView, "setImageBitmap", "(Landroid/graphics/Bitmap;)V"},
    {&g_method_setImageDrawable, &g_class_ImageView, "setImageDrawable", "(Landroid/graphics/drawable/Drawable;)V"},
    {&g_method_setScaleType, &g_class_ImageView, "setScaleType", "(Landroid/widget/ImageView$ScaleType;)V"},
    {&g_method_loadUrl, &g_class_WebView, "loadUrl", "(Ljava/lang/String;)V"},
    {&g_method_getSettings, &g_class_WebView, "getSettings", "()Landroid/webkit/WebSettings;"},
    {&g_method_getIdentifier, &g_class_Resources, "getIdentifier",
     "(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;)I"},

    {&g_method_setContentView, &g_class_Activity, "setContentView", "(Landroid/view/View;)V"},
    {&g_method_getResources, &g_class_Activity, "getResources", "()Landroid/content/res/Resources;"},
    {&g_method_getPackageName, &g_class_Activity, "getPackageName", "()Ljava/lang/String;"},
    /* The activity's, which applies its theme, as a drawable's theme
     * attributes (like an icon's tint) need. */
    {&g_method_getDrawable, &g_class_Activity, "getDrawable", "(I)Landroid/graphics/drawable/Drawable;"},
    {&g_method_registerTextWatcher, &g_class_Activity, "registerTextWatcher", "(Landroid/widget/EditText;)V"},
    {&g_method_registerWebViewClient, &g_class_Activity, "registerWebViewClient", "(Landroid/webkit/WebView;)V"},
    {&g_method_requestFocusOnView, &g_class_Activity, "requestFocusOnView", "(Landroid/view/View;)V"},
    {&g_method_setLayoutField, &g_class_Activity, "setLayoutField", "(Landroid/view/View;IF)V"},
    {&g_method_applyLayout, &g_class_Activity, "applyLayout", "(Landroid/view/View;)V"},
    {&g_method_setCornerRadius, &g_class_Activity, "setCornerRadius", "(Landroid/view/View;F)V"},
    {&g_method_setTapFeedback, &g_class_Activity, "setTapFeedback", "(Landroid/view/View;)V"},
    {&g_method_setCorner, &g_class_Activity, "setCorner", "(Landroid/view/View;IF)V"},
    {&g_method_setBackgroundColour, &g_class_Activity, "setBackgroundColour", "(Landroid/view/View;I)V"},
    {&g_method_setPaddingY, &g_class_Activity, "setPaddingY", "(Landroid/view/View;I)V"},
    {&g_method_setSwitch, &g_class_Activity, "setSwitch", "(Landroid/widget/CompoundButton;Z)V"},
    {&g_method_watchSwitch, &g_class_Activity, "watchSwitch", "(Landroid/widget/CompoundButton;)V"},
    {&g_method_isNightMode, &g_class_Activity, "isNightMode", "()Z"},
    {&g_method_is24HourClock, &g_class_Activity, "is24HourClock", "()Z"},
    {&g_method_setLongPress, &g_class_Activity, "setLongPress", "(Landroid/view/View;I)V"},
    {&g_method_openUri, &g_class_Activity, "openUri", "([B)V"},
    {&g_method_pickFiles, &g_class_Activity, "pickFiles", "(Ljava/lang/String;)V"},
    {&g_method_capturePicture, &g_class_Activity, "capturePicture", "()V"},
    {&g_method_decodeImageData, &g_class_Activity, "decodeImageData", "([B)Landroid/graphics/Bitmap;"},
    {&g_method_pickPicture, &g_class_Activity, "pickPicture", "([II)V"},
    {&g_method_saveFile, &g_class_Activity, "saveFile", "([B[BLjava/lang/String;)V"},
    {&g_method_imageSize, &g_class_Activity, "imageSize", "([B)[I"},
    {&g_method_setScrollWatch, &g_class_Activity, "setScrollWatch", "(Landroid/view/View;I)V"},
    {&g_method_scrollToEnd, &g_class_Activity, "scrollToEnd", "(Landroid/view/View;)V"},
    {&g_method_copyText, &g_class_Activity, "copyText", "(Ljava/lang/String;)V"},
    {&g_method_pickFile, &g_class_Activity, "pickFile", "(Ljava/lang/String;)V"},
    {&g_method_openFile, &g_class_Activity, "openFile", "([B)V"},
    {&g_method_decodeImageFile, &g_class_Activity, "decodeImageFile", "([B)Landroid/graphics/Bitmap;"},
    {&g_method_setMaxLines, &g_class_Activity, "setMaxLines", "(Landroid/widget/TextView;I)V"},
    {&g_method_setFontStyle, &g_class_Activity, "setFontStyle", "(Landroid/widget/TextView;I)V"},
    {&g_method_keepAtEnd, &g_class_Activity, "keepAtEnd", "(Landroid/view/View;)V"},
    {&g_method_initLazyList, &g_class_Activity, "initLazyList", "(Landroid/widget/ListView;I)V"},
    {&g_method_setLazyCount, &g_class_Activity, "setLazyCount", "(Landroid/widget/ListView;I)V"},
};

/* Every class and method the bridge calls, or -1 if one is missing: the
 * activity's methods ship with this file, so build both from the same
 * hatter sources. */
static int resolve_jni_ids(JNIEnv *env, jobject activity)
{
    jclass activity_class = (*env)->GetObjectClass(env, activity);
    g_class_Activity = (*env)->NewGlobalRef(env, activity_class);
    (*env)->DeleteLocalRef(env, activity_class);

    for (size_t i = 0; i < sizeof g_classes / sizeof g_classes[0]; i++) {
        jclass cls = (*env)->FindClass(env, g_classes[i].name);
        if (cls == NULL) {
            (*env)->ExceptionClear(env);
            LOGE("Class not found: %s", g_classes[i].name);
            return -1;
        }
        *g_classes[i].cls = (*env)->NewGlobalRef(env, cls);
        (*env)->DeleteLocalRef(env, cls);
    }

    for (size_t i = 0; i < sizeof g_methods / sizeof g_methods[0]; i++) {
        *g_methods[i].id = (*env)->GetMethodID(env, *g_methods[i].cls, g_methods[i].name, g_methods[i].sig);
        if (*g_methods[i].id == NULL) {
            (*env)->ExceptionClear(env);
            LOGE("Method not found: %s%s", g_methods[i].name, g_methods[i].sig);
            return -1;
        }
    }

    jclass webSettings = (*env)->FindClass(env, "android/webkit/WebSettings");
    if (webSettings == NULL) {
        (*env)->ExceptionClear(env);
        LOGE("Class not found: android/webkit/WebSettings");
        return -1;
    }
    g_method_setJavaScriptEnabled = (*env)->GetMethodID(env, webSettings, "setJavaScriptEnabled", "(Z)V");
    (*env)->DeleteLocalRef(env, webSettings);
    if (g_method_setJavaScriptEnabled == NULL) {
        (*env)->ExceptionClear(env);
        LOGE("Method not found: setJavaScriptEnabled");
        return -1;
    }
    return 0;
}

/* ---- Node pool helpers ---- */

#ifdef DYNAMIC_NODE_POOL
/* Grow the pool so that nodeId < g_pool_capacity. */
static int ensure_pool_capacity(int32_t needed)
{
    if (needed < g_pool_capacity) return 0;
    int32_t new_cap = g_pool_capacity ? g_pool_capacity : INITIAL_POOL_SIZE;
    while (new_cap <= needed) new_cap *= 2;
    jobject *new_pool = realloc(g_nodes, (size_t)new_cap * sizeof(jobject));
    int32_t *new_free = realloc(g_free_stack, (size_t)new_cap * sizeof(int32_t));
    int32_t *new_pend = realloc(g_pending_free, (size_t)new_cap * sizeof(int32_t));
    if (!new_pool || !new_free || !new_pend) {
        LOGE("Node pool realloc failed (requested %d slots)", new_cap);
        if (new_pool) g_nodes = new_pool;
        if (new_free) g_free_stack = new_free;
        if (new_pend) g_pending_free = new_pend;
        return -1;
    }
    memset(new_pool + g_pool_capacity, 0,
           (size_t)(new_cap - g_pool_capacity) * sizeof(jobject));
    g_nodes = new_pool;
    g_free_stack = new_free;
    g_pending_free = new_pend;
    g_pool_capacity = new_cap;
    return 0;
}
#endif

/* The view of a node, for jni_bridge.c, which hands lazy rows to Java. */
jobject ui_android_node_view(int32_t nodeId);

static jobject get_node(int32_t nodeId)
{
#ifdef DYNAMIC_NODE_POOL
    if (nodeId < 1 || nodeId >= g_pool_capacity) return NULL;
#else
    if (nodeId < 1 || nodeId >= MAX_NODES) return NULL;
#endif
    return g_nodes[nodeId];
}

jobject ui_android_node_view(int32_t nodeId)
{
    return get_node(nodeId);
}

/* ---- Hex color parser ---- */

/*
 * Parse a hex color string (#RGB, #RRGGBB, or #AARRGGBB) into a jint ARGB value.
 * Returns 0 (transparent black) on invalid input.
 */
static jint parse_hex_color(const char *hex)
{
    if (!hex || hex[0] != '#') return 0;
    const char *digits = hex + 1;
    size_t len = strlen(digits);
    unsigned long raw = strtoul(digits, NULL, 16);

    switch (len) {
    case 3: {
        /* #RGB -> #FFRRGGBB (expand each nibble) */
        unsigned int r = (raw >> 8) & 0xF;
        unsigned int g = (raw >> 4) & 0xF;
        unsigned int b = raw & 0xF;
        return (jint)(0xFF000000u | (r * 0x11u) << 16 | (g * 0x11u) << 8 | (b * 0x11u));
    }
    case 6:
        /* #RRGGBB -> #FFRRGGBB */
        return (jint)(0xFF000000u | (raw & 0xFFFFFFu));
    case 8:
        /* #AARRGGBB — already complete */
        return (jint)raw;
    default:
        return 0;
    }
}

/* ---- Callback implementation ---- */

static int32_t android_create_node(int32_t nodeType)
{
    /* Only check capacity when no free IDs are available */
    if (g_free_count == 0) {
#ifdef DYNAMIC_NODE_POOL
        if (ensure_pool_capacity(g_next_node_id) != 0) {
            LOGE("Node pool exhausted (realloc failed at %d)", g_next_node_id);
            return 0;
        }
#else
        if (g_next_node_id >= MAX_NODES) {
            LOGE("Node pool exhausted (max %d)", MAX_NODES);
            return 0;
        }
#endif
    }

    JNIEnv *env = g_env;
    jobject view = NULL;

    switch (nodeType) {
    case UI_NODE_TEXT:
        view = (*env)->NewObject(env, g_class_TextView, g_ctor_TextView, g_activity);
        break;
    case UI_NODE_BUTTON:
        view = (*env)->NewObject(env, g_class_Button, g_ctor_Button, g_activity);
        break;
    case UI_NODE_SWITCH:
        view = (*env)->NewObject(env, g_class_Switch, g_ctor_Switch, g_activity);
        break;
    case UI_NODE_COLUMN: {
        view = (*env)->NewObject(env, g_class_LinearLayout, g_ctor_LinearLayout, g_activity);
        (*env)->CallVoidMethod(env, view, g_method_setOrientation, ORIENTATION_VERTICAL);
        break;
    }
    case UI_NODE_ROW: {
        view = (*env)->NewObject(env, g_class_LinearLayout, g_ctor_LinearLayout, g_activity);
        (*env)->CallVoidMethod(env, view, g_method_setOrientation, ORIENTATION_HORIZONTAL);
        break;
    }
    case UI_NODE_TEXT_INPUT:
        view = (*env)->NewObject(env, g_class_EditText, g_ctor_EditText, g_activity);
        break;
    case UI_NODE_SCROLL_VIEW: {
        view = (*env)->NewObject(env, g_class_ScrollView, g_ctor_ScrollView, g_activity);
        /* Android ScrollView only accepts one direct child.
         * Create an inner vertical LinearLayout so that multiple
         * Haskell children can be added via addChild(). */
        jobject innerLayout = (*env)->NewObject(env, g_class_LinearLayout,
            g_ctor_LinearLayout, g_activity);
        (*env)->CallVoidMethod(env, innerLayout, g_method_setOrientation,
            ORIENTATION_VERTICAL);
        (*env)->CallVoidMethod(env, view, g_method_addView, innerLayout);
        (*env)->DeleteLocalRef(env, innerLayout);
        break;
    }
    case UI_NODE_IMAGE:
        view = (*env)->NewObject(env, g_class_ImageView, g_ctor_ImageView, g_activity);
        break;
    case UI_NODE_MAP_VIEW: {
        /* Placeholder: FrameLayout containing a TextView showing coordinates.
         * A real map (osmdroid or Google Maps) can replace this once the build
         * pipeline supports AAR dependencies. */
        jobject frame = (*env)->NewObject(env, g_class_FrameLayout, g_ctor_FrameLayout, g_activity);
        jobject label = (*env)->NewObject(env, g_class_TextView, g_ctor_TextView, g_activity);
        jstring text = (*env)->NewStringUTF(env, "Map placeholder (0.0, 0.0) z1.0");
        (*env)->CallVoidMethod(env, label, g_method_setText, text);
        (*env)->DeleteLocalRef(env, text);
        (*env)->CallVoidMethod(env, frame, g_method_addView, label);
        (*env)->DeleteLocalRef(env, label);
        view = frame;
        break;
    }
    case UI_NODE_WEBVIEW: {
        view = (*env)->NewObject(env, g_class_WebView, g_ctor_WebView, g_activity);
        if (view) {
            jobject settings = (*env)->CallObjectMethod(env, view, g_method_getSettings);
            if (settings) {
                (*env)->CallVoidMethod(env, settings, g_method_setJavaScriptEnabled, JNI_TRUE);
                (*env)->DeleteLocalRef(env, settings);
            }
        }
        break;
    }
    case UI_NODE_STACK: {
        /* Stack: children overlap in z-order (first at bottom, last on top).
         * FrameLayout is already cached from MapView placeholder. */
        view = (*env)->NewObject(env, g_class_FrameLayout, g_ctor_FrameLayout, g_activity);
        break;
    }
    case UI_NODE_LAZY_COLUMN:
        view = (*env)->NewObject(env, g_class_ListView, g_ctor_ListView, g_activity);
        break;
    case UI_NODE_HORIZONTAL_SCROLL_VIEW: {
        view = (*env)->NewObject(env, g_class_HorizontalScrollView,
            g_ctor_HorizontalScrollView, g_activity);
        /* HorizontalScrollView only accepts one direct child.
         * Create an inner horizontal LinearLayout so that multiple
         * Haskell children can be added via addChild(). */
        jobject innerLayout = (*env)->NewObject(env, g_class_LinearLayout,
            g_ctor_LinearLayout, g_activity);
        (*env)->CallVoidMethod(env, innerLayout, g_method_setOrientation,
            ORIENTATION_HORIZONTAL);
        (*env)->CallVoidMethod(env, view, g_method_addView, innerLayout);
        (*env)->DeleteLocalRef(env, innerLayout);
        break;
    }
    default:
        LOGE("Unknown node type: %d", nodeType);
        return 0;
    }

    if (!view) {
        LOGE("Failed to create view for type %d", nodeType);
        return 0;
    }

    int32_t nodeId;
    if (g_free_count > 0) {
        nodeId = g_free_stack[--g_free_count];
    } else {
        nodeId = g_next_node_id++;
    }
    g_nodes[nodeId] = (*env)->NewGlobalRef(env, view);
    (*env)->DeleteLocalRef(env, view);

    /* Its adapter asks for rows by the list's node ID. */
    if (nodeType == UI_NODE_LAZY_COLUMN) {
        (*env)->CallVoidMethod(env, g_activity, g_method_initLazyList, g_nodes[nodeId], (jint)nodeId);
    }

    LOGI("createNode(type=%d) -> %d", nodeType, nodeId);
    return nodeId;
}

static void android_set_str_prop(int32_t nodeId, int32_t propId, const char *value)
{
    JNIEnv *env = g_env;
    jobject view = get_node(nodeId);
    if (!view) return;

    switch (propId) {
    case UI_PROP_TEXT: {
        /* Skip setText if the view already contains the same text.
         * Calling setText on an EditText resets the IME input connection,
         * causing the soft keyboard to hide and disrupting text entry.
         * When the user types a character, the TextWatcher fires → Haskell
         * re-renders → diff sees the value changed → calls setStrProp.
         * But the EditText already has the correct text, so the call is
         * redundant and harmful. Only call setText when the text differs
         * (e.g. programmatic text changes like a "clear" button). */
        jobject curCharSeq = (*env)->CallObjectMethod(env, view, g_method_getText);
        if (curCharSeq) {
            jstring curStr = (*env)->CallObjectMethod(env, curCharSeq, g_method_charSeqToString);
            const char *curCStr = (*env)->GetStringUTFChars(env, curStr, NULL);
            int same = curCStr && value && strcmp(curCStr, value) == 0;
            (*env)->ReleaseStringUTFChars(env, curStr, curCStr);
            (*env)->DeleteLocalRef(env, curStr);
            (*env)->DeleteLocalRef(env, curCharSeq);
            if (same) {
                LOGI("setStrProp(node=%d, text) — skipped (same)", nodeId);
                break;
            }
        }
        /* Not the text: Android keeps the log, and texts are messages. */
        LOGI("setStrProp(node=%d, text)", nodeId);
        jstring jstr = (*env)->NewStringUTF(env, value);
        g_setting_text_programmatically = 1;
        (*env)->CallVoidMethod(env, view, g_method_setText, jstr);
        g_setting_text_programmatically = 0;
        (*env)->DeleteLocalRef(env, jstr);
        break;
    }
    case UI_PROP_HINT: {
        LOGI("setStrProp(node=%d, hint=\"%s\")", nodeId, value);
        jstring jstr = (*env)->NewStringUTF(env, value);
        (*env)->CallVoidMethod(env, view, g_method_setHint, jstr);
        (*env)->DeleteLocalRef(env, jstr);
        break;
    }
    case UI_PROP_COLOR: {
        LOGI("setStrProp(node=%d, color=\"%s\")", nodeId, value);
        if ((*env)->IsInstanceOf(env, view, g_class_TextView)) {
            jint argb = parse_hex_color(value);
            (*env)->CallVoidMethod(env, view, g_method_setTextColor, argb);
        }
        break;
    }
    case UI_PROP_BG_COLOR: {
        LOGI("setStrProp(node=%d, bgColor=\"%s\")", nodeId, value);
        jint argb = parse_hex_color(value);
        /* In the shape of its corners, where it has its own. */
        (*env)->CallVoidMethod(env, g_activity, g_method_setBackgroundColour, view, argb);
        break;
    }
    case UI_PROP_IMAGE_RESOURCE: {
        LOGI("setStrProp(node=%d, imageResource=\"%s\")", nodeId, value);
        /* Resource lookup: getResources().getIdentifier(name, "drawable", packageName) */
        if ((*env)->IsInstanceOf(env, view, g_class_ImageView)) {
            jobject resources = (*env)->CallObjectMethod(env, g_activity, g_method_getResources);
            jstring packageName = (*env)->CallObjectMethod(env, g_activity, g_method_getPackageName);
            jstring jname = (*env)->NewStringUTF(env, value);
            jstring jtype = (*env)->NewStringUTF(env, "drawable");
            jint resId = (*env)->CallIntMethod(env, resources, g_method_getIdentifier,
                jname, jtype, packageName);
            if (resId != 0) {
                jobject drawable = (*env)->CallObjectMethod(env, g_activity, g_method_getDrawable, resId);
                (*env)->CallVoidMethod(env, view, g_method_setImageDrawable, drawable);
                (*env)->DeleteLocalRef(env, drawable);
            } else {
                LOGE("Resource not found: %s", value);
            }
            (*env)->DeleteLocalRef(env, jname);
            (*env)->DeleteLocalRef(env, jtype);
            (*env)->DeleteLocalRef(env, packageName);
            (*env)->DeleteLocalRef(env, resources);
        }
        break;
    }
    case UI_PROP_IMAGE_FILE: {
        LOGI("setStrProp(node=%d, imageFile=\"%s\")", nodeId, value);
        if ((*env)->IsInstanceOf(env, view, g_class_ImageView)) {
            /* At the size the screen needs, the right way up. */
            jbyteArray jpath = hatter_utf8_bytes(env, value);
            jobject bitmap = (*env)->CallObjectMethod(env, g_activity, g_method_decodeImageFile, jpath);
            if (bitmap) {
                (*env)->CallVoidMethod(env, view, g_method_setImageBitmap, bitmap);
                (*env)->DeleteLocalRef(env, bitmap);
            } else {
                LOGE("Failed to decode file: %s", value);
            }
            (*env)->DeleteLocalRef(env, jpath);
        }
        break;
    }
    case UI_PROP_IMAGE_STREAM: {
        LOGI("setStrProp(node=%d, imageStream=\"%s\")", nodeId, value);
        if ((*env)->IsInstanceOf(env, view, g_class_ImageView)) {
            jclass videoClass = (*env)->FindClass(env, "me/jappie/hatter/HatterCallVideo");
            jmethodID attach = videoClass
                ? (*env)->GetStaticMethodID(env, videoClass, "attach", "([BLandroid/widget/ImageView;)V")
                : NULL;
            if (attach) {
                jbyteArray jkey = hatter_utf8_bytes(env, value);
                (*env)->CallStaticVoidMethod(env, videoClass, attach, jkey, view);
                (*env)->DeleteLocalRef(env, jkey);
            } else {
                (*env)->ExceptionClear(env);
                LOGE("HatterCallVideo not found");
            }
            if (videoClass) {
                (*env)->DeleteLocalRef(env, videoClass);
            }
        }
        break;
    }
    case UI_PROP_WEBVIEW_URL: {
        LOGI("setStrProp(node=%d, webviewUrl=\"%s\")", nodeId, value);
        if ((*env)->IsInstanceOf(env, view, g_class_WebView)) {
            jstring jurl = (*env)->NewStringUTF(env, value);
            (*env)->CallVoidMethod(env, view, g_method_loadUrl, jurl);
            (*env)->DeleteLocalRef(env, jurl);
        }
        break;
    }
    default:
        LOGI("setStrProp: unknown propId %d", propId);
        break;
    }
}

static void android_set_num_prop(int32_t nodeId, int32_t propId, double value)
{
    JNIEnv *env = g_env;
    jobject view = get_node(nodeId);
    if (!view) return;

    switch (propId) {
    case UI_PROP_FONT_SIZE:
        /* setTextSize only makes sense on TextView subclasses */
        if ((*env)->IsInstanceOf(env, view, g_class_TextView)) {
            (*env)->CallVoidMethod(env, view, g_method_setTextSize, (jfloat)value);
            LOGI("setNumProp(node=%d, fontSize=%.1f)", nodeId, value);
        } else {
            LOGI("setNumProp: fontSize ignored on non-TextView node=%d", nodeId);
        }
        break;
    case UI_PROP_PADDING: {
        jint px = (jint)value;
        (*env)->CallVoidMethod(env, view, g_method_setPadding, px, px, px, px);
        LOGI("setNumProp(node=%d, padding=%d)", nodeId, px);
        break;
    }
    case UI_PROP_CHECKED:
        if ((*env)->IsInstanceOf(env, view, g_class_Switch)) {
            (*env)->CallVoidMethod(env, g_activity, g_method_setSwitch, view, (jboolean)(value != 0));
        }
        break;
    case UI_PROP_PADDING_Y:
        (*env)->CallVoidMethod(env, g_activity, g_method_setPaddingY, view, (jint)value);
        break;
    case UI_PROP_CORNER_TOP_LEFT:
    case UI_PROP_CORNER_TOP_RIGHT:
    case UI_PROP_CORNER_BOTTOM_RIGHT:
    case UI_PROP_CORNER_BOTTOM_LEFT:
        (*env)->CallVoidMethod(env, g_activity, g_method_setCorner, view,
            (jint)(propId - UI_PROP_CORNER_TOP_LEFT), (jfloat)value);
        break;
    case UI_PROP_WIDTH:
    case UI_PROP_HEIGHT:
    case UI_PROP_WEIGHT:
    case UI_PROP_ALIGN_SELF:
    case UI_PROP_MARGIN:
        /* Sizes and margins in raw pixels, like UI_PROP_PADDING. The
         * activity applies them in the kind of layout parameters the
         * parent takes, keeping its defaults for the rest. */
        (*env)->CallVoidMethod(env, g_activity, g_method_setLayoutField, view,
            (jint)(propId - UI_PROP_WIDTH), (jfloat)value);
        LOGI("setNumProp(node=%d, layout prop=%d, value=%.1f)", nodeId, propId, value);
        break;
    case UI_PROP_MAX_WIDTH:
        if ((*env)->IsInstanceOf(env, view, g_class_TextView)) {
            (*env)->CallVoidMethod(env, view, g_method_setMaxWidth, (jint)value);
        }
        LOGI("setNumProp(node=%d, maxWidth=%.0f)", nodeId, value);
        break;
    case UI_PROP_SCROLL_TO_END:
        (*env)->CallVoidMethod(env, g_activity, g_method_scrollToEnd, view);
        break;
    case UI_PROP_ITEM_COUNT:
        if ((*env)->IsInstanceOf(env, view, g_class_ListView)) {
            (*env)->CallVoidMethod(env, g_activity, g_method_setLazyCount, view, (jint)value);
        }
        LOGI("setNumProp(node=%d, itemCount=%.0f)", nodeId, value);
        break;
    case UI_PROP_FONT_STYLE:
        if ((*env)->IsInstanceOf(env, view, g_class_TextView)) {
            (*env)->CallVoidMethod(env, g_activity, g_method_setFontStyle, view, (jint)value);
        }
        break;
    case UI_PROP_MAX_LINES:
        if ((*env)->IsInstanceOf(env, view, g_class_TextView)) {
            (*env)->CallVoidMethod(env, g_activity, g_method_setMaxLines, view, (jint)value);
        }
        LOGI("setNumProp(node=%d, maxLines=%.0f)", nodeId, value);
        break;
    case UI_PROP_KEEP_AT_END:
        if ((int)value == 1 &&
            ((*env)->IsInstanceOf(env, view, g_class_ScrollView) ||
             (*env)->IsInstanceOf(env, view, g_class_ListView))) {
            (*env)->CallVoidMethod(env, g_activity, g_method_keepAtEnd, view);
        }
        LOGI("setNumProp(node=%d, keepAtEnd=%.0f)", nodeId, value);
        break;
    case UI_PROP_CORNER_RADIUS:
        (*env)->CallVoidMethod(env, g_activity, g_method_setCornerRadius, view, (jfloat)value);
        LOGI("setNumProp(node=%d, cornerRadius=%.1f)", nodeId, value);
        break;
    case UI_PROP_INPUT_TYPE: {
        /* Haskell 0 = InputText      -> Android TYPE_CLASS_TEXT       (1)
         * Haskell 1 = InputNumber    -> Android TYPE_CLASS_NUMBER |
         *                               TYPE_NUMBER_FLAG_DECIMAL      (8194)
         * Haskell 2 = InputMultiline -> Android TYPE_CLASS_TEXT |
         *                               TYPE_TEXT_FLAG_CAP_SENTENCES |
         *                               TYPE_TEXT_FLAG_MULTI_LINE     (147457)
         * Haskell 3 = InputPassword  -> Android TYPE_CLASS_TEXT |
         *                               TYPE_TEXT_VARIATION_PASSWORD  (129)
         */
        jint androidType;
        if ((int)value == 1) {
            androidType = 8194; /* TYPE_CLASS_NUMBER | TYPE_NUMBER_FLAG_DECIMAL */
        } else if ((int)value == 2) {
            androidType = 147457;
        } else if ((int)value == 3) {
            androidType = 129;
        } else {
            androidType = 1;    /* TYPE_CLASS_TEXT */
        }
        (*env)->CallVoidMethod(env, view, g_method_setInputType, androidType);
        LOGI("setNumProp(node=%d, inputType=%d, android=%d)", nodeId, (int)value, androidType);
        break;
    }
    case UI_PROP_GRAVITY: {
        /* Haskell 0 = AlignStart  -> Gravity.START              (0x00800003)
         * Haskell 1 = AlignCenter -> Gravity.CENTER_HORIZONTAL  (1)
         * Haskell 2 = AlignEnd    -> Gravity.END                (0x00800005)
         */
        jint gravity;
        switch ((int)value) {
        case 1:  gravity = 1;          break; /* CENTER_HORIZONTAL */
        case 2:  gravity = 0x00800005; break; /* END */
        default: gravity = 0x00800003; break; /* START */
        }
        if ((*env)->IsInstanceOf(env, view, g_class_TextView)) {
            (*env)->CallVoidMethod(env, view, g_method_setGravity_TextView, gravity);
            /* Set width to MATCH_PARENT so gravity has room to take effect */
            (*env)->CallVoidMethod(env, g_activity, g_method_setLayoutField, view,
                (jint)0 /* width */, (jfloat)-1 /* MATCH_PARENT */);
        } else if ((*env)->IsInstanceOf(env, view, g_class_LinearLayout)) {
            (*env)->CallVoidMethod(env, view, g_method_setGravity_LinearLayout, gravity);
        }
        LOGI("setNumProp(node=%d, gravity=%d)", nodeId, gravity);
        break;
    }
    case UI_PROP_SCALE_TYPE: {
        /* Haskell 0 = ScaleFit  -> FIT_CENTER
         * Haskell 1 = ScaleFill -> CENTER_CROP
         * Haskell 2 = ScaleNone -> CENTER
         */
        if ((*env)->IsInstanceOf(env, view, g_class_ImageView)) {
            jclass scaleTypeClass = (*env)->FindClass(env, "android/widget/ImageView$ScaleType");
            const char *fieldName;
            switch ((int)value) {
            case 1:  fieldName = "CENTER_CROP"; break;
            case 2:  fieldName = "CENTER";      break;
            default: fieldName = "FIT_CENTER";  break;
            }
            jfieldID field = (*env)->GetStaticFieldID(env, scaleTypeClass,
                fieldName, "Landroid/widget/ImageView$ScaleType;");
            jobject scaleType = (*env)->GetStaticObjectField(env, scaleTypeClass, field);
            (*env)->CallVoidMethod(env, view, g_method_setScaleType, scaleType);
            (*env)->DeleteLocalRef(env, scaleType);
            (*env)->DeleteLocalRef(env, scaleTypeClass);
        }
        LOGI("setNumProp(node=%d, scaleType=%d)", nodeId, (int)value);
        break;
    }
    case UI_PROP_MAP_LAT:
    case UI_PROP_MAP_LON:
    case UI_PROP_MAP_ZOOM: {
        /* Update placeholder label inside the FrameLayout with new coordinates.
         * The FrameLayout's first child is the placeholder TextView. */
        if ((*env)->IsInstanceOf(env, view, g_class_FrameLayout)) {
            jobject child = (*env)->CallObjectMethod(env, view, g_method_getChildAt, (jint)0);
            if (child && (*env)->IsInstanceOf(env, child, g_class_TextView)) {
                char buf[128];
                snprintf(buf, sizeof(buf), "Map placeholder (%.4f, %.4f) z%.1f",
                         value, value, value);
                jstring jtext = (*env)->NewStringUTF(env, buf);
                (*env)->CallVoidMethod(env, child, g_method_setText, jtext);
                (*env)->DeleteLocalRef(env, jtext);
            }
            if (child) (*env)->DeleteLocalRef(env, child);
        }
        LOGI("setNumProp(node=%d, mapProp=%d, value=%.4f)", nodeId, propId, value);
        break;
    }
    case UI_PROP_MAP_SHOW_USER_LOC:
        /* No-op for placeholder — real map would toggle location layer */
        LOGI("setNumProp(node=%d, showUserLoc=%.0f)", nodeId, value);
        break;
    case UI_PROP_TRANSLATE_X: {
        (*env)->CallVoidMethod(env, view, g_method_setTranslationX, (jfloat)value);
        LOGI("setNumProp(node=%d, translateX=%.1f)", nodeId, value);
        break;
    }
    case UI_PROP_TRANSLATE_Y: {
        (*env)->CallVoidMethod(env, view, g_method_setTranslationY, (jfloat)value);
        LOGI("setNumProp(node=%d, translateY=%.1f)", nodeId, value);
        break;
    }
    case UI_PROP_AUTO_FOCUS:
        (*env)->CallVoidMethod(env, g_activity, g_method_requestFocusOnView, view);
        LOGI("setNumProp(node=%d, autoFocus=%.0f)", nodeId, value);
        break;
    case UI_PROP_TOUCH_PASSTHROUGH: {
        /* When enabled (1.0), disable click and focus so touches pass through
         * to sibling views underneath in a FrameLayout (Stack). */
        jboolean enabled = (int)value == 1 ? JNI_FALSE : JNI_TRUE;
        (*env)->CallVoidMethod(env, view, g_method_setClickable, enabled);
        (*env)->CallVoidMethod(env, view, g_method_setFocusable, enabled);
        LOGI("setNumProp(node=%d, touchPassthrough=%.0f)", nodeId, value);
        break;
    }
    default:
        LOGI("setNumProp: unknown propId %d", propId);
        break;
    }
}

static void android_set_image_data(int32_t nodeId, const uint8_t *data, int32_t length)
{
    JNIEnv *env = g_env;
    jobject view = get_node(nodeId);
    if (!view) return;
    if (!(*env)->IsInstanceOf(env, view, g_class_ImageView)) return;

    /* Create Java byte[] and copy data */
    jbyteArray jdata = (*env)->NewByteArray(env, length);
    (*env)->SetByteArrayRegion(env, jdata, 0, length, (const jbyte *)data);

    /* Bounded by the screen and a pixel count, as the bytes may come from
       anyone. */
    jobject bitmap = (*env)->CallObjectMethod(env, g_activity, g_method_decodeImageData, jdata);
    if (bitmap) {
        (*env)->CallVoidMethod(env, view, g_method_setImageBitmap, bitmap);
        (*env)->DeleteLocalRef(env, bitmap);
    } else {
        LOGE("setImageData: not a picture it can show (node=%d, %d bytes)", nodeId, length);
    }
    (*env)->DeleteLocalRef(env, jdata);

    LOGI("setImageData(node=%d, %d bytes)", nodeId, length);
}

static void android_set_handler(int32_t nodeId, int32_t eventType, int32_t callbackId)
{
    JNIEnv *env = g_env;
    jobject view = get_node(nodeId);
    if (!view) return;

    /* A long press keeps its callback in its listener, as the tag holds
       the click's. */
    if (eventType == UI_EVENT_SCROLLED) {
        (*env)->CallVoidMethod(env, g_activity, g_method_setScrollWatch, view, (jint)callbackId);
        return;
    }
    if (eventType == UI_EVENT_LONG_PRESS) {
        (*env)->CallVoidMethod(env, g_activity, g_method_setLongPress, view, (jint)callbackId);
        LOGI("setHandler(node=%d, longPress, callback=%d)", nodeId, callbackId);
        return;
    }

    /* Store callbackId as the view's tag (Integer) */
    jobject tagObj = (*env)->NewObject(env, g_class_Integer, g_ctor_Integer, callbackId);
    (*env)->CallVoidMethod(env, view, g_method_setTag, tagObj);
    (*env)->DeleteLocalRef(env, tagObj);

    switch (eventType) {
    case UI_EVENT_CLICK:
        if ((*env)->IsInstanceOf(env, view, g_class_WebView)) {
            /* Register a WebViewClient via our Java helper for page-load callbacks */
            (*env)->CallVoidMethod(env, g_activity, g_method_registerWebViewClient, view);
            LOGI("setHandler(node=%d, webview-pageload, callback=%d)", nodeId, callbackId);
        } else if ((*env)->IsInstanceOf(env, view, g_class_Switch)) {
            /* A flip, by a tap or a drag, not just a tap */
            (*env)->CallVoidMethod(env, g_activity, g_method_watchSwitch, view);
        } else {
            /* Register the Activity (which implements OnClickListener) as handler */
            (*env)->CallVoidMethod(env, view, g_method_setOnClickListener, g_activity);
            if (!(*env)->IsInstanceOf(env, view, g_class_Button)) {
                (*env)->CallVoidMethod(env, g_activity, g_method_setTapFeedback, view);
            }
        }
        LOGI("setHandler(node=%d, click, callback=%d)", nodeId, callbackId);
        break;
    case UI_EVENT_TEXT_CHANGE:
        if ((*env)->IsInstanceOf(env, view, g_class_FrameLayout)) {
            /* MapView placeholder: callbackId stored in tag, no TextWatcher needed */
            LOGI("setHandler(node=%d, mapRegionChange, callback=%d)", nodeId, callbackId);
        } else {
            /* Register a TextWatcher via our Java helper */
            (*env)->CallVoidMethod(env, g_activity, g_method_registerTextWatcher, view);
            LOGI("setHandler(node=%d, textChange, callback=%d)", nodeId, callbackId);
        }
        break;
    default:
        LOGI("setHandler: unknown eventType %d", eventType);
        break;
    }
}

/* Layout fields set before the child had a parent take effect now. */
static void apply_layout(JNIEnv *env, jobject child)
{
    (*env)->CallVoidMethod(env, g_activity, g_method_applyLayout, child);
}

static int32_t android_dark_mode(void)
{
    return (*g_env)->CallBooleanMethod(g_env, g_activity, g_method_isNightMode) ? 1 : 0;
}

static int32_t android_clock24(void)
{
    return (*g_env)->CallBooleanMethod(g_env, g_activity, g_method_is24HourClock) ? 1 : 0;
}

static void android_copy_text(const char *text)
{
    jstring jtext = (*g_env)->NewStringUTF(g_env, text);
    (*g_env)->CallVoidMethod(g_env, g_activity, g_method_copyText, jtext);
    (*g_env)->DeleteLocalRef(g_env, jtext);
}

static void android_pick_file(const char *mimeType)
{
    jstring jtype = (*g_env)->NewStringUTF(g_env, mimeType);
    (*g_env)->CallVoidMethod(g_env, g_activity, g_method_pickFile, jtype);
    (*g_env)->DeleteLocalRef(g_env, jtype);
}

static void android_open_file(const char *path)
{
    jbyteArray jpath = hatter_utf8_bytes(g_env, path);
    (*g_env)->CallVoidMethod(g_env, g_activity, g_method_openFile, jpath);
    (*g_env)->DeleteLocalRef(g_env, jpath);
}

static void android_pick_files(const char *mimeType)
{
    jstring jtype = (*g_env)->NewStringUTF(g_env, mimeType);
    (*g_env)->CallVoidMethod(g_env, g_activity, g_method_pickFiles, jtype);
    (*g_env)->DeleteLocalRef(g_env, jtype);
}

static int32_t android_image_size(const char *path, int32_t *width, int32_t *height)
{
    jbyteArray jpath = hatter_utf8_bytes(g_env, path);
    jintArray size = (*g_env)->CallObjectMethod(g_env, g_activity, g_method_imageSize, jpath);
    (*g_env)->DeleteLocalRef(g_env, jpath);
    if (size == NULL) return 0;
    jint values[2];
    (*g_env)->GetIntArrayRegion(g_env, size, 0, 2, values);
    (*g_env)->DeleteLocalRef(g_env, size);
    *width = values[0];
    *height = values[1];
    return 1;
}

static void android_save_file(const char *path, const char *name, const char *mimeType)
{
    jbyteArray jpath = hatter_utf8_bytes(g_env, path);
    jbyteArray jname = hatter_utf8_bytes(g_env, name);
    jstring jtype = (*g_env)->NewStringUTF(g_env, mimeType);
    (*g_env)->CallVoidMethod(g_env, g_activity, g_method_saveFile, jpath, jname, jtype);
    (*g_env)->DeleteLocalRef(g_env, jpath);
    (*g_env)->DeleteLocalRef(g_env, jname);
    (*g_env)->DeleteLocalRef(g_env, jtype);
}

static void android_pick_picture(const int32_t *sides, int32_t count, int32_t limit)
{
    jintArray jsides = (*g_env)->NewIntArray(g_env, count);
    (*g_env)->SetIntArrayRegion(g_env, jsides, 0, count, (const jint *)sides);
    (*g_env)->CallVoidMethod(g_env, g_activity, g_method_pickPicture, jsides, (jint)limit);
    (*g_env)->DeleteLocalRef(g_env, jsides);
}

static void android_capture_picture(void)
{
    (*g_env)->CallVoidMethod(g_env, g_activity, g_method_capturePicture);
}

static void android_open_uri(const char *uri)
{
    jbyteArray juri = hatter_utf8_bytes(g_env, uri);
    (*g_env)->CallVoidMethod(g_env, g_activity, g_method_openUri, juri);
    (*g_env)->DeleteLocalRef(g_env, juri);
}

static void android_add_child(int32_t parentId, int32_t childId)
{
    JNIEnv *env = g_env;
    jobject parent = get_node(parentId);
    jobject child  = get_node(childId);
    if (!parent || !child) return;

    /* Android ScrollView / HorizontalScrollView only accept one direct
     * child.  Redirect to the inner LinearLayout wrapper (child 0)
     * that was created in android_create_node. */
    if ((*env)->IsInstanceOf(env, parent, g_class_ScrollView) ||
        (*env)->IsInstanceOf(env, parent, g_class_HorizontalScrollView)) {
        jobject innerLayout = (*env)->CallObjectMethod(env, parent,
            g_method_getChildAt, (jint)0);
        if (innerLayout) {
            (*env)->CallVoidMethod(env, innerLayout, g_method_addView, child);
            (*env)->DeleteLocalRef(env, innerLayout);
            apply_layout(env, child);
            return;
        }
    }

    (*env)->CallVoidMethod(env, parent, g_method_addView, child);
    apply_layout(env, child);
}

static void android_remove_child(int32_t parentId, int32_t childId)
{
    JNIEnv *env = g_env;
    jobject parent = get_node(parentId);
    jobject child  = get_node(childId);
    if (!parent || !child) return;

    /* ScrollView / HorizontalScrollView: redirect to inner LinearLayout wrapper. */
    if ((*env)->IsInstanceOf(env, parent, g_class_ScrollView) ||
        (*env)->IsInstanceOf(env, parent, g_class_HorizontalScrollView)) {
        jobject innerLayout = (*env)->CallObjectMethod(env, parent,
            g_method_getChildAt, (jint)0);
        if (innerLayout) {
            (*env)->CallVoidMethod(env, innerLayout, g_method_removeView, child);
            (*env)->DeleteLocalRef(env, innerLayout);
            return;
        }
    }

    (*env)->CallVoidMethod(env, parent, g_method_removeView, child);
}

static void android_destroy_node(int32_t nodeId)
{
    JNIEnv *env = g_env;
    jobject view = get_node(nodeId);
    if (!view) return;

    /* Remove from parent ViewGroup before freeing — prevents orphaned
     * Views staying visible when replaceNode destroys type-changed children. */
    jobject parent = (*env)->CallObjectMethod(env, view, g_method_getParent);
    if (parent) {
        /* A lazy column's rows are its adapter's, which ListView doesn't
         * let anyone else remove. */
        if ((*env)->IsInstanceOf(env, parent, g_class_ViewGroup) &&
            !(*env)->IsInstanceOf(env, parent, g_class_ListView))
            (*env)->CallVoidMethod(env, parent, g_method_removeView, view);
        (*env)->DeleteLocalRef(env, parent);
    }

    (*env)->DeleteGlobalRef(env, view);
    g_nodes[nodeId] = NULL;
    g_pending_free[g_pending_count++] = nodeId;
}

static void android_set_root(int32_t nodeId)
{
    JNIEnv *env = g_env;
    jobject view = get_node(nodeId);
    if (!view) return;

    (*env)->CallVoidMethod(env, g_activity, g_method_setContentView, view);

    /* Flush pending freed IDs into the free stack now that the render
     * pass is complete.  This prevents same-pass ID reuse. */
    for (int32_t i = 0; i < g_pending_count; i++)
        g_free_stack[g_free_count++] = g_pending_free[i];
    g_pending_count = 0;

    LOGI("setRoot(node=%d)", nodeId);
}

static void android_clear(void)
{
    JNIEnv *env = g_env;
    for (int i = 1; i < g_next_node_id; i++) {
        if (g_nodes[i]) {
            (*env)->DeleteGlobalRef(env, g_nodes[i]);
            g_nodes[i] = NULL;
        }
    }
    g_next_node_id = 1;
    g_free_count = 0;
    g_pending_count = 0;
    /* Dynamic mode: keep the allocation to avoid malloc/free churn each frame.
     * Static mode: nothing extra to do — array is stack-allocated. */
    LOGI("clear()");
}

/* ---- Public API ---- */

/*
 * Set up the Android UI bridge. Called from Java before haskellRenderUI.
 * Resolves JNI IDs and registers callbacks with the platform-agnostic
 * dispatcher.
 */
void setup_android_ui_bridge(JNIEnv *env, jobject activity, void *haskellCtx)
{
    static int resolved = 0;

    g_env = env;
    if (g_activity) {
        (*env)->DeleteGlobalRef(env, g_activity);
    }
    g_activity = (*env)->NewGlobalRef(env, activity);
    (void)haskellCtx; /* context is now owned by jni_bridge.c */

#ifdef DYNAMIC_NODE_POOL
    if (!g_nodes) {
        g_pool_capacity = INITIAL_POOL_SIZE;
        g_nodes = calloc((size_t)g_pool_capacity, sizeof(jobject));
        g_free_stack = calloc((size_t)g_pool_capacity, sizeof(int32_t));
        g_pending_free = calloc((size_t)g_pool_capacity, sizeof(int32_t));
    }
#endif
    /* The views of an earlier activity go with it. */
    android_clear();

    if (!resolved) {
        if (resolve_jni_ids(env, activity) != 0) {
            LOGE("Failed to resolve JNI IDs for UI bridge");
            return;
        }
        resolved = 1;
    }

    ui_register_callbacks(&g_android_callbacks);
    LOGI("Android UI bridge initialized");
}

/*
 * Handle a click event from Java. Looks up the callbackId from the
 * view's tag and dispatches to Haskell.
 */
void android_handle_click(JNIEnv *env, jobject view, void *haskellCtx)
{
    /* Update g_env in case we're called from a different JNI attach */
    g_env = env;

    jobject tagObj = (*env)->CallObjectMethod(env, view, g_method_getTag);
    if (!tagObj) {
        LOGI("Click on view with no tag — ignoring");
        return;
    }

    jint callbackId = (*env)->CallIntMethod(env, tagObj, g_method_intValue);
    (*env)->DeleteLocalRef(env, tagObj);

    LOGI("Click dispatched: callbackId=%d", callbackId);
    haskellOnUIEvent(haskellCtx, callbackId);
}

/*
 * Handle a text change event from Java. Looks up the callbackId from
 * the view's tag and dispatches to Haskell with the new text.
 * Does NOT trigger a re-render (avoids EditText cursor/flicker).
 */
void android_handle_text_change(JNIEnv *env, jobject view, jstring text, void *haskellCtx)
{
    g_env = env;

    /* Skip re-entrant callbacks caused by programmatic setText calls
     * from the Haskell render engine (see g_setting_text_programmatically). */
    if (g_setting_text_programmatically) {
        return;
    }

    jobject tagObj = (*env)->CallObjectMethod(env, view, g_method_getTag);
    if (!tagObj) {
        LOGI("Text change on view with no tag — ignoring");
        return;
    }

    jint callbackId = (*env)->CallIntMethod(env, tagObj, g_method_intValue);
    (*env)->DeleteLocalRef(env, tagObj);

    const char *ctext = (*env)->GetStringUTFChars(env, text, NULL);
    if (!ctext) return;

    LOGI("Text change dispatched: callbackId=%d", callbackId);
    haskellOnUITextChange(haskellCtx, callbackId, ctext);

    (*env)->ReleaseStringUTFChars(env, text, ctext);
}

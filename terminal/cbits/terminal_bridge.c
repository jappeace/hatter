/*
 * The terminal's UI callbacks. It draws the widgets itself, so it leaves
 * the node calls out, and those it doesn't have.
 */

#include <stddef.h>

#include "UIBridge.h"

static UIBridgeCallbacks g_callbacks;

void hatter_terminal_register_ui(
    int32_t (*dark_mode)(void),
    int32_t (*clock24)(void),
    void (*copy_text)(const char *),
    void (*pick_file)(const char *),
    void (*pick_files)(const char *),
    void (*pick_picture)(const int32_t *, int32_t, int32_t),
    void (*save_file)(const char *, const char *, const char *),
    void (*open_file)(const char *),
    void (*open_uri)(const char *),
    int32_t (*image_size)(const char *, int32_t *, int32_t *))
{
    g_callbacks.darkMode = dark_mode;
    g_callbacks.clock24 = clock24;
    g_callbacks.copyText = copy_text;
    g_callbacks.pickFile = pick_file;
    g_callbacks.pickFiles = pick_files;
    g_callbacks.pickPicture = pick_picture;
    g_callbacks.saveFile = save_file;
    g_callbacks.openFile = open_file;
    g_callbacks.openUri = open_uri;
    g_callbacks.imageSize = image_size;
    ui_register_callbacks(&g_callbacks);
}

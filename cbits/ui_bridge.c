/*
 * Platform-agnostic UI bridge dispatcher.
 *
 * Stores a pointer to UIBridgeCallbacks (filled by Android/iOS).
 * Each ui_* function delegates to the corresponding function pointer.
 * When no callbacks are registered (desktop), functions log to stderr
 * and return dummy IDs so that cabal build/test works without native UI.
 */

#include "UIBridge.h"
#include <stdio.h>

static UIBridgeCallbacks *g_callbacks = NULL;
static int32_t g_stub_next_id = 1;

void ui_register_callbacks(UIBridgeCallbacks *callbacks)
{
    g_callbacks = callbacks;
}

int32_t ui_create_node(int32_t nodeType)
{
    if (g_callbacks && g_callbacks->createNode) {
        return g_callbacks->createNode(nodeType);
    }
    int32_t id = g_stub_next_id++;
    fprintf(stderr, "[UIBridge stub] createNode(type=%d) -> %d\n", nodeType, id);
    return id;
}

void ui_set_str_prop(int32_t nodeId, int32_t propId, const char *value)
{
    if (g_callbacks && g_callbacks->setStrProp) {
        g_callbacks->setStrProp(nodeId, propId, value);
        return;
    }
    fprintf(stderr, "[UIBridge stub] setStrProp(node=%d, prop=%d, value=\"%s\")\n",
            nodeId, propId, value ? value : "(null)");
}

void ui_set_num_prop(int32_t nodeId, int32_t propId, double value)
{
    if (g_callbacks && g_callbacks->setNumProp) {
        g_callbacks->setNumProp(nodeId, propId, value);
        return;
    }
    fprintf(stderr, "[UIBridge stub] setNumProp(node=%d, prop=%d, value=%.2f)\n",
            nodeId, propId, value);
}

void ui_set_image_data(int32_t nodeId, const uint8_t *data, int32_t length)
{
    if (g_callbacks && g_callbacks->setImageData) {
        g_callbacks->setImageData(nodeId, data, length);
        return;
    }
    fprintf(stderr, "[UIBridge stub] setImageData(node=%d, %d bytes)\n", nodeId, length);
}

void ui_set_handler(int32_t nodeId, int32_t eventType, int32_t callbackId)
{
    if (g_callbacks && g_callbacks->setHandler) {
        g_callbacks->setHandler(nodeId, eventType, callbackId);
        return;
    }
    fprintf(stderr, "[UIBridge stub] setHandler(node=%d, event=%d, callback=%d)\n",
            nodeId, eventType, callbackId);
}

void ui_add_child(int32_t parentId, int32_t childId)
{
    if (g_callbacks && g_callbacks->addChild) {
        g_callbacks->addChild(parentId, childId);
        return;
    }
    fprintf(stderr, "[UIBridge stub] addChild(parent=%d, child=%d)\n",
            parentId, childId);
}

void ui_remove_child(int32_t parentId, int32_t childId)
{
    if (g_callbacks && g_callbacks->removeChild) {
        g_callbacks->removeChild(parentId, childId);
        return;
    }
    fprintf(stderr, "[UIBridge stub] removeChild(parent=%d, child=%d)\n",
            parentId, childId);
}

void ui_destroy_node(int32_t nodeId)
{
    if (g_callbacks && g_callbacks->destroyNode) {
        g_callbacks->destroyNode(nodeId);
        return;
    }
    fprintf(stderr, "[UIBridge stub] destroyNode(node=%d)\n", nodeId);
}

void ui_set_root(int32_t nodeId)
{
    if (g_callbacks && g_callbacks->setRoot) {
        g_callbacks->setRoot(nodeId);
        return;
    }
    fprintf(stderr, "[UIBridge stub] setRoot(node=%d)\n", nodeId);
}

void ui_clear(void)
{
    if (g_callbacks && g_callbacks->clear) {
        g_callbacks->clear();
        return;
    }
    g_stub_next_id = 1;
    fprintf(stderr, "[UIBridge stub] clear()\n");
}

int32_t ui_dark_mode(void)
{
    if (g_callbacks && g_callbacks->darkMode) {
        return g_callbacks->darkMode();
    }
    return 0;
}

void ui_copy_text(const char *text)
{
    if (g_callbacks && g_callbacks->copyText) {
        g_callbacks->copyText(text);
        return;
    }
    fprintf(stderr, "[UIBridge stub] copyText(\"%s\")\n", text);
}

void ui_pick_file(const char *mimeType)
{
    if (g_callbacks && g_callbacks->pickFile) {
        g_callbacks->pickFile(mimeType);
        return;
    }
    fprintf(stderr, "[UIBridge stub] pickFile(\"%s\")\n", mimeType);
}

int32_t ui_clock24(void)
{
    if (g_callbacks && g_callbacks->clock24) {
        return g_callbacks->clock24();
    }
    return 0;
}

void ui_pick_files(const char *mimeType)
{
    if (g_callbacks && g_callbacks->pickFiles) {
        g_callbacks->pickFiles(mimeType);
        return;
    }
    fprintf(stderr, "[UIBridge stub] pickFiles(\"%s\")\n", mimeType);
}

void ui_capture_picture(void)
{
    if (g_callbacks && g_callbacks->capturePicture) {
        g_callbacks->capturePicture();
        return;
    }
    fprintf(stderr, "[UIBridge stub] capturePicture()\n");
}

void ui_pick_picture(const int32_t *sides, int32_t count, int32_t limit)
{
    if (g_callbacks && g_callbacks->pickPicture) {
        g_callbacks->pickPicture(sides, count, limit);
        return;
    }
    fprintf(stderr, "[UIBridge stub] pickPicture(%d sides, %d bytes)\n", count, limit);
}

void ui_save_file(const char *path, const char *name, const char *mimeType)
{
    if (g_callbacks && g_callbacks->saveFile) {
        g_callbacks->saveFile(path, name, mimeType);
        return;
    }
    fprintf(stderr, "[UIBridge stub] saveFile(\"%s\", \"%s\", \"%s\")\n", path, name, mimeType);
}

int32_t ui_image_size(const char *path, int32_t *width, int32_t *height)
{
    if (g_callbacks && g_callbacks->imageSize) {
        return g_callbacks->imageSize(path, width, height);
    }
    return 0;
}

void ui_open_uri(const char *uri)
{
    if (g_callbacks && g_callbacks->openUri) {
        g_callbacks->openUri(uri);
        return;
    }
    fprintf(stderr, "[UIBridge stub] openUri(\"%s\")\n", uri);
}

void ui_open_file(const char *path)
{
    if (g_callbacks && g_callbacks->openFile) {
        g_callbacks->openFile(path);
        return;
    }
    fprintf(stderr, "[UIBridge stub] openFile(\"%s\")\n", path);
}

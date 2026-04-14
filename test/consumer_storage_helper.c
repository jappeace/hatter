/*
 * Consumer simulation storage helper — replicates prrrrrrrrr's
 * cbits/storage_helper.c to stress the binary translation layer.
 *
 * Pattern: global mutable C state accessed via FFI from Haskell.
 * This exercises libndk_translation's handling of cross-compiled C
 * globals accessed from translated ARM code.
 *
 * On Android, hatter's jni_bridge.c calls setAppFilesDir() during
 * JNI_OnLoad (before haskellRunMain), so getAppFilesDir() returns
 * the real app-private directory.  We use that as the default.
 */

#include <string.h>
#include <stdlib.h>

#define MAX_PATH 512

static char g_files_dir[MAX_PATH] = "";
static int g_initialized = 0;

/* Provided by hatter's files_dir.c — already linked into libhatter.so */
extern const char* getAppFilesDir(void);

void set_app_files_dir(const char *path)
{
    strncpy(g_files_dir, path, MAX_PATH - 1);
    g_files_dir[MAX_PATH - 1] = '\0';
    g_initialized = 1;
}

const char *get_app_files_dir(void)
{
    if (!g_initialized) {
        /* On Android, hatter's jni_bridge.c has already called
         * setAppFilesDir() during JNI_OnLoad.  Use that. */
        const char *hatterDir = getAppFilesDir();
        if (hatterDir && hatterDir[0] != '\0' && hatterDir[0] != '.') {
            strncpy(g_files_dir, hatterDir, MAX_PATH - 1);
        } else {
            /* Desktop fallback: TMPDIR or /tmp */
            const char *tmpdir = getenv("TMPDIR");
            if (tmpdir && tmpdir[0] != '\0') {
                strncpy(g_files_dir, tmpdir, MAX_PATH - 1);
            } else {
                strncpy(g_files_dir, "/tmp", MAX_PATH - 1);
            }
        }
        g_files_dir[MAX_PATH - 1] = '\0';
        g_initialized = 1;
    }
    return g_files_dir;
}

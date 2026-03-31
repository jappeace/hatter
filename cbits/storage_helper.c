/*
 * Storage helper for haskell-mobile.
 *
 * On Android, the Java side calls set_app_files_dir() during onCreate
 * to tell native code where to store the SQLite database.
 * On iOS, Swift calls set_app_files_dir() during initialize().
 * On desktop, falls back to TMPDIR (for nix sandbox) or /tmp.
 */

#include <string.h>
#include <stdlib.h>

#define MAX_PATH 512

static char g_files_dir[MAX_PATH] = "";
static int g_initialized = 0;

void set_app_files_dir(const char *path)
{
    strncpy(g_files_dir, path, MAX_PATH - 1);
    g_files_dir[MAX_PATH - 1] = '\0';
    g_initialized = 1;
}

const char *get_app_files_dir(void)
{
    if (!g_initialized) {
        const char *tmpdir = getenv("TMPDIR");
        if (tmpdir && tmpdir[0] != '\0') {
            strncpy(g_files_dir, tmpdir, MAX_PATH - 1);
        } else {
            strncpy(g_files_dir, "/tmp", MAX_PATH - 1);
        }
        g_files_dir[MAX_PATH - 1] = '\0';
        g_initialized = 1;
    }
    return g_files_dir;
}

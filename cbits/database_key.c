/*
 * The app's database key, from the platform's keystore.
 *
 * Uses a set/get pattern like files_dir.c: platform bridges set it before
 * haskellRunMain, and Haskell code reads it via getDatabaseKey(). Without
 * one, there is no key.
 */

#include <stddef.h>
#include <string.h>

#define DATABASE_KEY_BYTES 32

/* 0: no keystore here, 1: the key, -1: the keystore failed. */
static int g_status = 0;
static unsigned char g_key[DATABASE_KEY_BYTES];

void setDatabaseKey(const unsigned char *key, size_t length)
{
    if (key == NULL || length != DATABASE_KEY_BYTES) {
        g_status = -1;
        return;
    }
    memcpy(g_key, key, DATABASE_KEY_BYTES);
    g_status = 1;
}

void setDatabaseKeyFailed(void)
{
    g_status = -1;
}

/* Copies the key to out, which holds DATABASE_KEY_BYTES, when there is one. */
int getDatabaseKey(unsigned char *out)
{
    if (g_status == 1) {
        memcpy(out, g_key, DATABASE_KEY_BYTES);
    }
    return g_status;
}

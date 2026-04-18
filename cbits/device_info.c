/*
 * Device information globals.
 *
 * Uses a set/get pattern: platform bridges call setDevice*() during
 * initialization, and Haskell code reads values via getDevice*().
 *
 * Android: jni_bridge.c calls setters in JNI_OnLoad after querying
 *          Build.MODEL, Build.VERSION.RELEASE, and DisplayMetrics.
 * iOS:     UIBridgeIOS.m calls setters in setup_ios_platform_globals
 *          after querying utsname, UIDevice, and UIScreen.
 * Desktop: falls back to sensible defaults ("desktop", "unknown", etc.).
 */

#include <stddef.h>

static const char *g_device_model = NULL;
static const char *g_device_os_version = NULL;
static const char *g_device_screen_density = NULL;
static const char *g_device_screen_width = NULL;
static const char *g_device_screen_height = NULL;

void setDeviceModel(const char *value)
{
    g_device_model = value;  /* caller owns the memory (static/strdup'd) */
}

const char* getDeviceModel(void)
{
    return g_device_model ? g_device_model : "desktop";
}

void setDeviceOsVersion(const char *value)
{
    g_device_os_version = value;
}

const char* getDeviceOsVersion(void)
{
    return g_device_os_version ? g_device_os_version : "unknown";
}

void setDeviceScreenDensity(const char *value)
{
    g_device_screen_density = value;
}

const char* getDeviceScreenDensity(void)
{
    return g_device_screen_density ? g_device_screen_density : "1.0";
}

void setDeviceScreenWidth(const char *value)
{
    g_device_screen_width = value;
}

const char* getDeviceScreenWidth(void)
{
    return g_device_screen_width ? g_device_screen_width : "0";
}

void setDeviceScreenHeight(const char *value)
{
    g_device_screen_height = value;
}

const char* getDeviceScreenHeight(void)
{
    return g_device_screen_height ? g_device_screen_height : "0";
}

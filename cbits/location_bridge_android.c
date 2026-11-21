/*
 * Android implementation of the location (GPS) bridge callbacks.
 *
 * Uses JNI to call the static Activity.locationUpdates(), which starts or
 * stops updates on the main/UI thread. Compiled by NDK clang, not cabal.
 *
 * Starting and stopping may be called from any thread.
 */

#include <jni.h>
#include <android/log.h>
#include "LocationBridge.h"
#include "JniBridge.h"

#define LOG_TAG "LocationBridge"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

/* Haskell FFI export (dispatches location update back to Haskell callback) */
extern void haskellOnLocationUpdate(void *ctx, double lat, double lon,
                                     double alt, double acc);

/* ---- Global state (set on the UI thread during setup) ---- */
static JavaVM  *g_jvm            = NULL;
static jclass   g_activity_class = NULL;  /* global ref, kept for good */
static void    *g_haskell_ctx    = NULL;  /* stored for async JNI callback */

/* Cached JNI method ID of the static HatterActivity.locationUpdates */
static jmethodID g_method_locationUpdates;

/* The current thread's JNIEnv, attaching it if need be. */
static JNIEnv *attached_env(int *need_detach)
{
    JNIEnv *env = NULL;
    *need_detach = 0;
    jint status = (*g_jvm)->GetEnv(g_jvm, (void **)&env, JNI_VERSION_1_6);
    if (status == JNI_EDETACHED) {
        if ((*g_jvm)->AttachCurrentThread(g_jvm, &env, NULL) != JNI_OK) {
            LOGE("AttachCurrentThread failed");
            return NULL;
        }
        *need_detach = 1;
    } else if (status != JNI_OK) {
        LOGE("GetEnv failed (status=%d)", status);
        return NULL;
    }
    return env;
}

/* ---- Location bridge implementations ---- */

static void location_updates(jboolean on)
{
    if (!g_jvm || !g_activity_class) {
        LOGE("location_updates: bridge not initialized");
        return;
    }
    int need_detach;
    JNIEnv *env = attached_env(&need_detach);
    if (env == NULL) {
        return;
    }

    LOGI("location_updates(%d)", on);
    (*env)->CallStaticVoidMethod(env, g_activity_class, g_method_locationUpdates, on);
    if ((*env)->ExceptionCheck(env)) {
        LOGE("location_updates: Java exception thrown");
        (*env)->ExceptionClear(env);
    }
    if (need_detach) {
        (*g_jvm)->DetachCurrentThread(g_jvm);
    }
}

static void android_location_start_updates(void *ctx)
{
    g_haskell_ctx = ctx;
    location_updates(JNI_TRUE);
}

static void android_location_stop_updates(void)
{
    location_updates(JNI_FALSE);
}

/* ---- Public API ---- */

/*
 * Set up the Android location bridge. Called from jni_bridge.c
 * during renderUI (after the Activity is available).
 * Resolves JNI method IDs and registers callbacks with the
 * platform-agnostic dispatcher.
 */
void setup_android_location_bridge(JNIEnv *env, jobject activity, void *haskellCtx)
{
    g_haskell_ctx = haskellCtx;

    if (!g_jvm) {
        (*env)->GetJavaVM(env, &g_jvm);
    }
    /* Only the class: another thread may be calling through it while a
     * recreated activity sets the bridge up again, so it is never replaced
     * or deleted. */
    if (g_activity_class) {
        return;
    }

    jclass actClass = (*env)->GetObjectClass(env, activity);
    g_method_locationUpdates = (*env)->GetStaticMethodID(env, actClass,
        "locationUpdates", "(Z)V");
    if (!g_method_locationUpdates) {
        LOGE("Failed to resolve location JNI method ID — location bridge disabled");
        (*env)->ExceptionClear(env);
        (*env)->DeleteLocalRef(env, actClass);
        return;
    }
    /* Set after the method, as other threads take a class as ready. */
    g_activity_class = (jclass)(*env)->NewGlobalRef(env, actClass);
    (*env)->DeleteLocalRef(env, actClass);

    location_register_impl(android_location_start_updates,
                           android_location_stop_updates);

    LOGI("Android location bridge initialized");
}

/* ---- JNI callback from Java location result ---- */

JNIEXPORT void JNICALL
JNI_METHOD(onLocationResult)(JNIEnv *env, jobject thiz,
                              jdouble lat, jdouble lon,
                              jdouble alt, jdouble acc)
{
    LOGI("onLocationResult(lat=%f, lon=%f, alt=%f, acc=%f)", lat, lon, alt, acc);
    haskellOnLocationUpdate(g_haskell_ctx, (double)lat, (double)lon,
                            (double)alt, (double)acc);
}

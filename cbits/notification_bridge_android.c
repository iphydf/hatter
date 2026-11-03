/*
 * Android implementation of the notification bridge.
 *
 * Calls the static methods of HatterNotifications with the Application,
 * so notifications work from any thread and without an Activity. The
 * class is looked up during JNI_OnLoad, as threads attached later only
 * see the system class loader. Strings go as UTF-8 bytes, since JNI's own
 * strings take modified UTF-8, which has no emoji.
 */

#include <jni.h>
#include <string.h>
#include <android/log.h>
#include "NotificationBridge.h"

#define LOG_TAG "NotificationBridge"
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

static JavaVM   *g_jvm = NULL;
static jobject   g_app = NULL;
static jclass    g_class = NULL;
static jmethodID g_show = NULL;
static jmethodID g_cancel = NULL;
static jmethodID g_ongoing = NULL;
static jmethodID g_status = NULL;
static jmethodID g_run = NULL;
static jmethodID g_stop = NULL;
static jmethodID g_over = NULL;
static jmethodID g_keep = NULL;
static jmethodID g_allowed = NULL;
static jmethodID g_allow = NULL;

static jbyteArray utf8_bytes(JNIEnv *env, const char *s)
{
    const jsize length = (jsize)strlen(s);
    jbyteArray bytes = (*env)->NewByteArray(env, length);
    (*env)->SetByteArrayRegion(env, bytes, 0, length, (const jbyte *)s);
    return bytes;
}

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

static void android_notification_show(const char *key, const char *channel, const char *icon,
                                      const char *title, const char *text, int kind)
{
    int need_detach;
    JNIEnv *env = attached_env(&need_detach);
    if (env == NULL) {
        return;
    }

    jbyteArray jkey = utf8_bytes(env, key);
    jbyteArray jchannel = utf8_bytes(env, channel);
    jbyteArray jicon = utf8_bytes(env, icon);
    jbyteArray jtitle = utf8_bytes(env, title);
    jbyteArray jtext = utf8_bytes(env, text);
    (*env)->CallStaticVoidMethod(env, g_class, g_show, g_app, jkey, jchannel, jicon, jtitle, jtext,
                                 (jint)kind);
    if ((*env)->ExceptionCheck(env)) {
        LOGE("show: Java exception thrown");
        (*env)->ExceptionDescribe(env);
        (*env)->ExceptionClear(env);
    }
    (*env)->DeleteLocalRef(env, jkey);
    (*env)->DeleteLocalRef(env, jchannel);
    (*env)->DeleteLocalRef(env, jicon);
    (*env)->DeleteLocalRef(env, jtitle);
    (*env)->DeleteLocalRef(env, jtext);

    if (need_detach) {
        (*g_jvm)->DetachCurrentThread(g_jvm);
    }
}

static void android_notification_ongoing(const char *key, const char *title, long long since)
{
    int need_detach;
    JNIEnv *env = attached_env(&need_detach);
    if (env == NULL) {
        return;
    }
    jbyteArray jkey = utf8_bytes(env, key);
    jbyteArray jtitle = utf8_bytes(env, title);
    (*env)->CallStaticVoidMethod(env, g_class, g_ongoing, g_app, jkey, jtitle, (jlong)since);
    if ((*env)->ExceptionCheck(env)) {
        LOGE("ongoing: Java exception thrown");
        (*env)->ExceptionDescribe(env);
        (*env)->ExceptionClear(env);
    }
    (*env)->DeleteLocalRef(env, jkey);
    (*env)->DeleteLocalRef(env, jtitle);
    if (need_detach) {
        (*g_jvm)->DetachCurrentThread(g_jvm);
    }
}

static void android_status(const char *text)
{
    int need_detach;
    JNIEnv *env = attached_env(&need_detach);
    if (env == NULL) {
        return;
    }
    jbyteArray jtext = utf8_bytes(env, text);
    (*env)->CallStaticVoidMethod(env, g_class, g_status, g_app, jtext);
    if ((*env)->ExceptionCheck(env)) {
        LOGE("setStatus: Java exception thrown");
        (*env)->ExceptionDescribe(env);
        (*env)->ExceptionClear(env);
    }
    (*env)->DeleteLocalRef(env, jtext);
    if (need_detach) {
        (*g_jvm)->DetachCurrentThread(g_jvm);
    }
}

static void android_run_in_background(int on)
{
    int need_detach;
    JNIEnv *env = attached_env(&need_detach);
    if (env == NULL) {
        return;
    }
    (*env)->CallStaticVoidMethod(env, g_class, g_run, g_app, (jboolean)(on != 0));
    if ((*env)->ExceptionCheck(env)) {
        LOGE("runInBackground: Java exception thrown");
        (*env)->ExceptionDescribe(env);
        (*env)->ExceptionClear(env);
    }
    if (need_detach) {
        (*g_jvm)->DetachCurrentThread(g_jvm);
    }
}

static void android_stop_background(void)
{
    int need_detach;
    JNIEnv *env = attached_env(&need_detach);
    if (env == NULL) {
        return;
    }
    (*env)->CallStaticVoidMethod(env, g_class, g_stop, g_app);
    if ((*env)->ExceptionCheck(env)) {
        LOGE("stopBackground: Java exception thrown");
        (*env)->ExceptionDescribe(env);
        (*env)->ExceptionClear(env);
    }
    if (need_detach) {
        (*g_jvm)->DetachCurrentThread(g_jvm);
    }
}

static void android_over_lock_screen(int on)
{
    int need_detach;
    JNIEnv *env = attached_env(&need_detach);
    if (env == NULL) {
        return;
    }
    (*env)->CallStaticVoidMethod(env, g_class, g_over, g_app, (jboolean)(on != 0));
    if ((*env)->ExceptionCheck(env)) {
        LOGE("overLockScreen: Java exception thrown");
        (*env)->ExceptionDescribe(env);
        (*env)->ExceptionClear(env);
    }
    if (need_detach) {
        (*g_jvm)->DetachCurrentThread(g_jvm);
    }
}

static void android_keep_screen_on(int on)
{
    int need_detach;
    JNIEnv *env = attached_env(&need_detach);
    if (env == NULL) {
        return;
    }
    (*env)->CallStaticVoidMethod(env, g_class, g_keep, g_app, (jboolean)(on != 0));
    if ((*env)->ExceptionCheck(env)) {
        LOGE("keepScreenOn: Java exception thrown");
        (*env)->ExceptionDescribe(env);
        (*env)->ExceptionClear(env);
    }
    if (need_detach) {
        (*g_jvm)->DetachCurrentThread(g_jvm);
    }
}

static int android_full_screen_allowed(void)
{
    int need_detach;
    JNIEnv *env = attached_env(&need_detach);
    if (env == NULL) {
        return 1;
    }
    jboolean allowed = (*env)->CallStaticBooleanMethod(env, g_class, g_allowed, g_app);
    if ((*env)->ExceptionCheck(env)) {
        LOGE("fullScreenAllowed: Java exception thrown");
        (*env)->ExceptionDescribe(env);
        (*env)->ExceptionClear(env);
        allowed = JNI_TRUE;
    }
    if (need_detach) {
        (*g_jvm)->DetachCurrentThread(g_jvm);
    }
    return allowed != JNI_FALSE;
}

static void android_allow_full_screen(void)
{
    int need_detach;
    JNIEnv *env = attached_env(&need_detach);
    if (env == NULL) {
        return;
    }
    (*env)->CallStaticVoidMethod(env, g_class, g_allow, g_app);
    if ((*env)->ExceptionCheck(env)) {
        LOGE("allowFullScreen: Java exception thrown");
        (*env)->ExceptionDescribe(env);
        (*env)->ExceptionClear(env);
    }
    if (need_detach) {
        (*g_jvm)->DetachCurrentThread(g_jvm);
    }
}

static void android_notification_cancel(const char *key)
{
    int need_detach;
    JNIEnv *env = attached_env(&need_detach);
    if (env == NULL) {
        return;
    }

    jbyteArray jkey = utf8_bytes(env, key);
    (*env)->CallStaticVoidMethod(env, g_class, g_cancel, g_app, jkey);
    if ((*env)->ExceptionCheck(env)) {
        LOGE("cancel: Java exception thrown");
        (*env)->ExceptionDescribe(env);
        (*env)->ExceptionClear(env);
    }
    (*env)->DeleteLocalRef(env, jkey);

    if (need_detach) {
        (*g_jvm)->DetachCurrentThread(g_jvm);
    }
}

/*
 * Set up the bridge. Called from JNI_OnLoad, where the class loader that
 * loaded the library finds Hatter's classes.
 */
void setup_android_notification_bridge(JavaVM *vm, JNIEnv *env)
{
    g_jvm = vm;

    jclass atClass = (*env)->FindClass(env, "android/app/ActivityThread");
    jmethodID currentApp = (*env)->GetStaticMethodID(env, atClass,
        "currentApplication", "()Landroid/app/Application;");
    jobject app = (*env)->CallStaticObjectMethod(env, atClass, currentApp);
    (*env)->DeleteLocalRef(env, atClass);

    jclass cls = (*env)->FindClass(env, "me/jappie/hatter/HatterNotifications");
    if (app == NULL || cls == NULL) {
        LOGE("No Application or HatterNotifications: notifications disabled");
        (*env)->ExceptionClear(env);
        return;
    }

    g_app = (*env)->NewGlobalRef(env, app);
    g_class = (*env)->NewGlobalRef(env, cls);
    g_show = (*env)->GetStaticMethodID(env, cls, "show",
        "(Landroid/content/Context;[B[B[B[B[BI)V");
    g_cancel = (*env)->GetStaticMethodID(env, cls, "cancel",
        "(Landroid/content/Context;[B)V");
    (*env)->DeleteLocalRef(env, app);
    (*env)->DeleteLocalRef(env, cls);

    if (g_show == NULL || g_cancel == NULL) {
        LOGE("HatterNotifications methods not found: notifications disabled");
        (*env)->ExceptionClear(env);
        return;
    }

    notification_register_impl(android_notification_show, android_notification_cancel);
    g_ongoing = (*env)->GetStaticMethodID(env, g_class, "setOngoing", "(Landroid/content/Context;[B[BJ)V");
    if (g_ongoing == NULL) {
        (*env)->ExceptionClear(env);
    } else {
        notification_register_ongoing(android_notification_ongoing);
    }
    g_status = (*env)->GetStaticMethodID(env, g_class, "setStatus", "(Landroid/content/Context;[B)V");
    if (g_status == NULL) {
        (*env)->ExceptionClear(env);
    } else {
        notification_register_status(android_status);
    }
    g_run = (*env)->GetStaticMethodID(env, g_class, "runInBackground", "(Landroid/content/Context;Z)V");
    g_stop = (*env)->GetStaticMethodID(env, g_class, "stopBackground", "(Landroid/content/Context;)V");
    if (g_run == NULL || g_stop == NULL) {
        (*env)->ExceptionClear(env);
    } else {
        notification_register_background(android_run_in_background, android_stop_background);
    }
    g_over = (*env)->GetStaticMethodID(env, g_class, "overLockScreen", "(Landroid/content/Context;Z)V");
    g_allowed = (*env)->GetStaticMethodID(env, g_class, "fullScreenAllowed", "(Landroid/content/Context;)Z");
    g_allow = (*env)->GetStaticMethodID(env, g_class, "allowFullScreen", "(Landroid/content/Context;)V");
    if (g_over == NULL || g_allowed == NULL || g_allow == NULL) {
        (*env)->ExceptionClear(env);
    } else {
        notification_register_lock_screen(android_over_lock_screen, android_full_screen_allowed,
                                          android_allow_full_screen);
    }
    g_keep = (*env)->GetStaticMethodID(env, g_class, "keepScreenOn", "(Landroid/content/Context;Z)V");
    if (g_keep == NULL) {
        (*env)->ExceptionClear(env);
    } else {
        notification_register_keep_screen_on(android_keep_screen_on);
    }
}

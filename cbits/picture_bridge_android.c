/*
 * Android implementation of the picture bridge: HatterFiles decodes, on
 * whichever thread asks, attached to the JVM for the call.
 */

#include <jni.h>
#include <stdlib.h>
#include <string.h>
#include <android/log.h>
#include "PictureBridge.h"

#define LOG_TAG "PictureBridge"
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

static JavaVM   *g_jvm = NULL;
static jclass    g_class = NULL;
static jmethodID g_pixels = NULL;
static jmethodID g_shrink = NULL;

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
        return NULL;
    }
    return env;
}

static jbyteArray utf8_bytes(JNIEnv *env, const char *s)
{
    const jsize length = (jsize)strlen(s);
    jbyteArray bytes = (*env)->NewByteArray(env, length);
    (*env)->SetByteArrayRegion(env, bytes, 0, length, (const jbyte *)s);
    return bytes;
}

static uint8_t *android_picture_pixels(const char *path, int32_t max_pixels, int32_t *width, int32_t *height)
{
    int need_detach;
    JNIEnv *env = attached_env(&need_detach);
    if (env == NULL) {
        return NULL;
    }

    uint8_t *pixels = NULL;
    jbyteArray jpath = utf8_bytes(env, path);
    /* Width and height, big-endian, then the pixels. */
    jbyteArray result = (*env)->CallStaticObjectMethod(env, g_class, g_pixels, jpath, (jint)max_pixels);
    if ((*env)->ExceptionCheck(env)) {
        LOGE("pixels: Java exception thrown");
        (*env)->ExceptionDescribe(env);
        (*env)->ExceptionClear(env);
        result = NULL;
    }
    if (result != NULL) {
        jsize size = (*env)->GetArrayLength(env, result);
        if (size >= 8) {
            uint8_t head[8];
            (*env)->GetByteArrayRegion(env, result, 0, 8, (jbyte *)head);
            *width = (int32_t)((uint32_t)head[0] << 24 | (uint32_t)head[1] << 16 | (uint32_t)head[2] << 8 | head[3]);
            *height = (int32_t)((uint32_t)head[4] << 24 | (uint32_t)head[5] << 16 | (uint32_t)head[6] << 8 | head[7]);
            if ((int64_t)*width * *height * 4 == size - 8) {
                pixels = malloc((size_t)(size - 8));
                if (pixels != NULL) {
                    (*env)->GetByteArrayRegion(env, result, 8, size - 8, (jbyte *)pixels);
                }
            }
        }
        (*env)->DeleteLocalRef(env, result);
    }
    (*env)->DeleteLocalRef(env, jpath);
    if (need_detach) {
        (*g_jvm)->DetachCurrentThread(g_jvm);
    }
    return pixels;
}

static int32_t android_picture_shrink(const char *path, const char *out, int32_t longest)
{
    int need_detach;
    JNIEnv *env = attached_env(&need_detach);
    if (env == NULL) {
        return 0;
    }
    jbyteArray jpath = utf8_bytes(env, path);
    jbyteArray jout = utf8_bytes(env, out);
    jint kind = (*env)->CallStaticIntMethod(env, g_class, g_shrink, jpath, jout, (jint)longest);
    if ((*env)->ExceptionCheck(env)) {
        LOGE("shrink: Java exception thrown");
        (*env)->ExceptionDescribe(env);
        (*env)->ExceptionClear(env);
        kind = 0;
    }
    (*env)->DeleteLocalRef(env, jpath);
    (*env)->DeleteLocalRef(env, jout);
    if (need_detach) {
        (*g_jvm)->DetachCurrentThread(g_jvm);
    }
    return kind;
}

/* Called from JNI_OnLoad, where the class loader finds Hatter's classes. */
void setup_android_picture_bridge(JavaVM *vm, JNIEnv *env)
{
    g_jvm = vm;
    jclass cls = (*env)->FindClass(env, "me/jappie/hatter/HatterFiles");
    if (cls == NULL) {
        (*env)->ExceptionClear(env);
        return;
    }
    g_class = (*env)->NewGlobalRef(env, cls);
    (*env)->DeleteLocalRef(env, cls);
    g_pixels = (*env)->GetStaticMethodID(env, g_class, "pixels", "([BI)[B");
    g_shrink = (*env)->GetStaticMethodID(env, g_class, "shrink", "([B[BI)I");
    if (g_pixels == NULL || g_shrink == NULL) {
        (*env)->ExceptionClear(env);
        return;
    }
    picture_register_impl(android_picture_pixels, android_picture_shrink);
}

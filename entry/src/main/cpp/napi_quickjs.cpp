#include <node_api.h>
#include <string>
#include <vector>
#include <pthread.h>
#include <unistd.h>
#include <cstdlib>
#include <cstdio>
#include <cstring>
#include <ctime>
#include <sys/time.h>
#include "quickjs.h"
#include "hilog/log.h"

static constexpr char MODULE_NAME[] = "QuickJSNAPI";
static constexpr unsigned int LOG_PRINT_ID = 0xFF00;
static constexpr const char* DEFAULT_SECURITY_KEY = "lxmusic_harmony_key";

#define LOGI(fmt, ...) OH_LOG_INFO(LOG_APP, "%{public}s:" fmt, __FUNCTION__, ##__VA_ARGS__)
#define LOGW(fmt, ...) OH_LOG_WARN(LOG_APP, "%{public}s:" fmt, __FUNCTION__, ##__VA_ARGS__)
#define LOGE(fmt, ...) OH_LOG_ERROR(LOG_APP, "%{public}s:" fmt, __FUNCTION__, ##__VA_ARGS__)

// Global runtime and context
static JSRuntime *runtime = nullptr;
static JSContext *context = nullptr;

// Mutex for thread safety
static pthread_mutex_t js_mutex = PTHREAD_MUTEX_INITIALIZER;

// Security key for native callbacks
static std::string security_key;

// ==================== 异步桥：待办队列 ====================
//
// QuickJS 是同步引擎，而 LX 源脚本的取链流程是纯异步的：
//   lx.request(url, opts, cb) -> 等 HTTP -> cb(err, resp) -> resolve Promise -> lx.send('response')
// 原生层不能自己发 HTTP（没有网络栈），所以把「JS 想发的请求」排队，
// 由 ArkTS 侧（CustomSourcePlugin 的 pump）取走、用 @ohos.net.http 发出去、
// 再把结果塞回 JS。这里就是那条队列的存放处，外加定时器队列。
//
// 队列用独立的 mutex，避免和 js_mutex 形成锁序问题（js_mutex 里只做 JS 操作）。
static pthread_mutex_t queue_mutex = PTHREAD_MUTEX_INITIALIZER;

struct PendingRequest {
    std::string request_key;
    std::string url;
    std::string options_json;  // 原样保存 JS 给的 options，由 ArkTS 侧解析
};

struct PendingTimer {
    int64_t id;
    int64_t due_ms;
};

struct ActionResult {
    std::string request_key;
    std::string data_json;  // lx.send('response', ...) 的完整载荷
};

static std::vector<PendingRequest> g_requests;
static std::vector<PendingTimer> g_timers;
static std::vector<ActionResult> g_results;
static int64_t g_timer_seq = 1;

static int64_t NowMs() {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return static_cast<int64_t>(ts.tv_sec) * 1000 + ts.tv_nsec / 1000000;
}

/** 把字符串转义成 JSON 字面量（含首尾引号） */
static void AppendJsonString(std::string& out, const std::string& value) {
    out += '"';
    for (size_t i = 0; i < value.size(); i++) {
        unsigned char c = static_cast<unsigned char>(value[i]);
        switch (c) {
            case '"': out += "\\\""; break;
            case '\\': out += "\\\\"; break;
            case '\n': out += "\\n"; break;
            case '\r': out += "\\r"; break;
            case '\t': out += "\\t"; break;
            default:
                if (c < 0x20) {
                    char esc[8];
                    snprintf(esc, sizeof(esc), "\\u%04x", c);
                    out += esc;
                } else {
                    out += static_cast<char>(c);
                }
        }
    }
    out += '"';
}


static std::string GetExceptionMessageWithStack(JSContext* ctx, JSValueConst exception) {
    const char* msg_c = JS_ToCString(ctx, exception);
    std::string msg = msg_c ? msg_c : "Unknown QuickJS exception";
    if (msg_c) {
        JS_FreeCString(ctx, msg_c);
    }

    JSValue stack_val = JS_GetPropertyStr(ctx, exception, "stack");
    if (!JS_IsUndefined(stack_val) && !JS_IsNull(stack_val)) {
        const char* stack_c = JS_ToCString(ctx, stack_val);
        if (stack_c && strlen(stack_c) > 0) {
            msg += " | stack: ";
            msg += stack_c;
        }
        if (stack_c) {
            JS_FreeCString(ctx, stack_c);
        }
    }
    JS_FreeValue(ctx, stack_val);
    return msg;
}

// ==================== Crypto Utilities ====================

// Simple MD5 implementation (RFC 1321)
static void md5_encode(const char *input, size_t len, char *output) {
    // MD5 constants
    static const unsigned int S[64] = {
        7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
        5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
        4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
        6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21
    };

    static const unsigned int K[64] = {
        0xd76aa478, 0xe8c7b756, 0x242070db, 0xc1bdceee, 0xf57c0faf, 0x4787c62a, 0xa8304613, 0xfd469501,
        0x698098d8, 0x8b44f7af, 0xffff5bb1, 0x895cd7be, 0x6b901122, 0xfd987193, 0xa679438e, 0x49b40821,
        0xf61e2562, 0xc040b340, 0x265e5a51, 0xe9b6c7aa, 0xd62f105d, 0x02441453, 0xd8a1e681, 0xe7d3fbc8,
        0x21e1cde6, 0xc33707d6, 0xf4d50d87, 0x455a14ed, 0xa9e3e905, 0xfcefa3f8, 0x676f02d9, 0x8d2a4c8a,
        0xfffa3942, 0x8771f681, 0x6d9d6122, 0xfde5380c, 0xa4beea44, 0x4bdecfa9, 0xf6bb4b60, 0xbebfbc70,
        0x289b7ec6, 0xeaa127fa, 0xd4ef3085, 0x04881d05, 0xd9d4d039, 0xe6db99e5, 0x1fa27cf8, 0xc4ac5665,
        0xf4292244, 0x432aff97, 0xab9423a7, 0xfc93a039, 0x655b59c3, 0x8f0ccc92, 0xffeff47d, 0x85845dd1,
        0x6fa87e4f, 0xfe2ce6e0, 0xa3014314, 0x4e0811a1, 0xf7537e82, 0xbd3af235, 0x2ad7d2bb, 0xeb86d391
    };

    // Initialize variables
    unsigned int a0 = 0x67452301, b0 = 0xefcdab89, c0 = 0x98badcfe, d0 = 0x10325476;

    // Pre-processing: adding padding bits
    size_t original_len = len;
    size_t padded_len = ((len + 8) / 64 + 1) * 64;
    unsigned char *padded = new unsigned char[padded_len];
    memset(padded, 0, padded_len);
    memcpy(padded, input, len);
    padded[len] = 0x80;

    // Append length
    unsigned long long bit_len = original_len * 8;
    memcpy(padded + padded_len - 8, &bit_len, 8);

    // Process each 512-bit block
    for (size_t i = 0; i < padded_len; i += 64) {
        unsigned int M[16];
        for (int j = 0; j < 16; j++) {
            M[j] = padded[i + j * 4] | (padded[i + j * 4 + 1] << 8) |
                   (padded[i + j * 4 + 2] << 16) | (padded[i + j * 4 + 3] << 24);
        }

        unsigned int A = a0, B = b0, C = c0, D = d0;

        for (int j = 0; j < 64; j++) {
            unsigned int F, g;
            if (j < 16) {
                F = (B & C) | ((~B) & D);
                g = j;
            } else if (j < 32) {
                F = (D & B) | ((~D) & C);
                g = (5 * j + 1) % 16;
            } else if (j < 48) {
                F = B ^ C ^ D;
                g = (3 * j + 5) % 16;
            } else {
                F = C ^ (B | (~D));
                g = (7 * j) % 16;
            }

            F = F + A + K[j] + M[g];
            A = D;
            D = C;
            C = B;
            B = B + ((F << S[j]) | (F >> (32 - S[j])));
        }

        a0 += A;
        b0 += B;
        c0 += C;
        d0 += D;
    }

    delete[] padded;

    // Output
    sprintf(output, "%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x",
            a0 & 0xff, (a0 >> 8) & 0xff, (a0 >> 16) & 0xff, (a0 >> 24) & 0xff,
            b0 & 0xff, (b0 >> 8) & 0xff, (b0 >> 16) & 0xff, (b0 >> 24) & 0xff,
            c0 & 0xff, (c0 >> 8) & 0xff, (c0 >> 16) & 0xff, (c0 >> 24) & 0xff,
            d0 & 0xff, (d0 >> 8) & 0xff, (d0 >> 16) & 0xff, (d0 >> 24) & 0xff);
}

// Simple Base64 encoding
static void base64_encode(const char *input, size_t input_len, char *output) {
    const char *base64_chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    size_t i = 0;
    size_t j = 0;

    while (i < input_len) {
        unsigned char b1 = i < input_len ? input[i++] : 0;
        unsigned char b2 = i < input_len ? input[i++] : 0;
        unsigned char b3 = i < input_len ? input[i++] : 0;

        output[j++] = base64_chars[(b1 >> 2) & 0x3F];
        output[j++] = base64_chars[((b1 << 4) | (b2 >> 4)) & 0x3F];
        output[j++] = (i > input_len + 1) ? '=' : base64_chars[((b2 << 2) | (b3 >> 6)) & 0x3F];
        output[j++] = (i > input_len) ? '=' : base64_chars[b3 & 0x3F];
    }
    output[j] = '\0';
}

// Simple Base64 decoding
static size_t base64_decode(const char *input, size_t input_len, unsigned char *output, size_t output_cap) {
    const char *base64_chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    size_t i = 0;
    size_t j = 0;
    unsigned int temp = 0;

    while (input_len > 0 && input[input_len - 1] == '=') {
        input_len--;
    }

    for (size_t k = 0; k < input_len; k++) {
        const char *pos = strchr(base64_chars, input[k]);
        if (!pos) return 0;
        temp = (temp << 6) | (pos - base64_chars);

        if ((k + 1) % 4 == 0) {
            if (j < output_cap) output[j++] = (temp >> 16) & 0xFF;
            if (j < output_cap) output[j++] = (temp >> 8) & 0xFF;
            if (j < output_cap) output[j++] = temp & 0xFF;
            temp = 0;
        }
    }

    // 处理不以 4 字节对齐收尾的余数（原来直接丢掉，尾部字节会少）
    size_t rest = input_len % 4;
    if (rest == 2) {
        if (j < output_cap) output[j++] = (temp >> 4) & 0xFF;
    } else if (rest == 3) {
        if (j < output_cap) output[j++] = (temp >> 10) & 0xFF;
        if (j < output_cap) output[j++] = (temp >> 2) & 0xFF;
    }

    return j;
}

// Simple hex to bytes conversion
static size_t hex_to_bytes(const char *hex, size_t hex_len, unsigned char *out) {
    for (size_t i = 0; i < hex_len / 2; i++) {
        sscanf(hex + 2 * i, "%2hhx", &out[i]);
    }
    return hex_len / 2;
}

// Simple bytes to hex conversion
static void bytes_to_hex(const unsigned char *bytes, size_t len, char *out) {
    for (size_t i = 0; i < len; i++) {
        sprintf(out + 2 * i, "%02x", bytes[i]);
    }
    out[len * 2] = '\0';
}

// ==================== Native Callbacks ====================

// Native callback: String to Base64
static JSValue Native_str2b64(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    if (argc < 1 || !JS_IsString(argv[0])) {
        return JS_NewString(ctx, "");
    }

    const char *input = JS_ToCString(ctx, argv[0]);
    if (!input) return JS_NewString(ctx, "");

    size_t input_len = strlen(input);
    size_t output_len = ((input_len + 2) / 3) * 4 + 1;

    char *output = new char[output_len];
    memset(output, 0, output_len);

    base64_encode(input, input_len, output);

    JSValue result = JS_NewString(ctx, output);
    delete[] output;
    JS_FreeCString(ctx, input);
    return result;
}

// Native callback: Base64 to Buffer (returns array of bytes)
static JSValue Native_b642buf(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    if (argc < 1 || !JS_IsString(argv[0])) {
        return JS_NewArray(ctx);
    }

    const char *input = JS_ToCString(ctx, argv[0]);
    if (!input) return JS_NewArray(ctx);

    size_t input_len = strlen(input);
    // 原来固定 4096 字节栈缓冲：解出来的内容超过约 3KB 就被静默截断。
    // 现在按输入长度算出上界动态分配（base64 -> 二进制是 3/4），
    // 源脚本用它解封面/歌词这类几 KB~几十 KB 的载荷才不会丢数据。
    size_t cap = (input_len / 4) * 3 + 4;
    unsigned char *output = new unsigned char[cap];
    memset(output, 0, cap);

    size_t out_len = base64_decode(input, input_len, output, cap);

    JSValue result_array = JS_NewArray(ctx);
    for (size_t i = 0; i < out_len; i++) {
        JS_SetPropertyUint32(ctx, result_array, i, JS_NewInt32(ctx, output[i]));
    }

    delete[] output;
    JS_FreeCString(ctx, input);
    return result_array;
}

// Native callback: String to MD5
static JSValue Native_str2md5(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    if (argc < 1 || !JS_IsString(argv[0])) {
        return JS_NewString(ctx, "");
    }

    const char *input = JS_ToCString(ctx, argv[0]);
    if (!input) return JS_NewString(ctx, "");

    char md5_string[33];
    md5_encode(input, strlen(input), md5_string);

    JSValue result = JS_NewString(ctx, md5_string);
    JS_FreeCString(ctx, input);
    return result;
}

/**
 * Native callback: AES encryption
 *
 * 这里原来是把入参原样返回（注释写着 "simplified - pass through"）。
 * 那是最糟的一种失败：源脚本拿自己输入的 base64 明文去请求服务端，
 * 服务端拒绝，日志里却看不出「加密没做」，只能猜「这个源用不了」。
 *
 * 现在明确抛异常：脚本的 try/catch 会捕获，preload 把 errorMessage 带回来，
 * ArkTS 侧能打出「该源依赖 AES 加密，当前引擎不支持」这样可执行的结论。
 * 依赖 AES 的源依然用不了 —— 但至少失败原因是准确的，不会误导排查。
 */
static JSValue Native_aes_encrypt(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    return JS_ThrowInternalError(ctx,
        "lx.utils.crypto.aesEncrypt is not supported by this QuickJS build");
}

/** Native callback: RSA encryption —— 同上，原来是 return ""，同样属于静默错误 */
static JSValue Native_rsa_encrypt(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    return JS_ThrowInternalError(ctx,
        "lx.utils.crypto.rsaEncrypt is not supported by this QuickJS build");
}

// Native callback: setTimeout handler
//
// 以前这里直接 return 0，等于把定时器整个丢掉：脚本里
// `await new Promise(r => setTimeout(r, 300))` 会永久挂住。
// 现在登记到 g_timers，由 ArkTS 侧的 pump 在到期后回调 __lx_native__('__set_timeout__')。
static JSValue Native_set_timeout(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    if (argc < 2) {
        return JS_NewInt32(ctx, 0);
    }
    int32_t delay = 0;
    JS_ToInt32(ctx, &delay, argv[1]);
    if (delay < 0) {
        delay = 0;
    }
    pthread_mutex_lock(&queue_mutex);
    PendingTimer timer;
    timer.id = g_timer_seq++;
    timer.due_ms = NowMs() + delay;
    g_timers.push_back(timer);
    pthread_mutex_unlock(&queue_mutex);
    return JS_NewInt32(ctx, static_cast<int32_t>(timer.id));
}

/** 从 JSON 对象里取字符串字段，缺失/非字符串返回空串 */
static std::string JsonPropString(JSContext *ctx, JSValueConst obj, const char *name) {
    std::string out;
    JSValue value = JS_GetPropertyStr(ctx, obj, name);
    if (JS_IsString(value)) {
        const char *text = JS_ToCString(ctx, value);
        if (text) {
            out = text;
            JS_FreeCString(ctx, text);
        }
    }
    JS_FreeValue(ctx, value);
    return out;
}

/** 把 JSON 对象里的某个字段重新序列化成字符串（用于原样转发 options） */
static std::string JsonPropStringify(JSContext *ctx, JSValueConst obj, const char *name) {
    std::string out;
    JSValue value = JS_GetPropertyStr(ctx, obj, name);
    if (!JS_IsUndefined(value) && !JS_IsNull(value)) {
        JSValue dumped = JS_JSONStringify(ctx, value, JS_UNDEFINED, JS_UNDEFINED);
        if (JS_IsString(dumped)) {
            const char *text = JS_ToCString(ctx, dumped);
            if (text) {
                out = text;
                JS_FreeCString(ctx, text);
            }
        }
        JS_FreeValue(ctx, dumped);
    }
    JS_FreeValue(ctx, value);
    return out;
}

// Native callback: main entry point for JS -> Native calls
static JSValue Native_call(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    if (argc < 2) {
        return JS_NewString(ctx, "{\"error\":\"Invalid arguments\"}");
    }

    const char *key = JS_ToCString(ctx, argv[0]);
    const char *action = JS_ToCString(ctx, argv[1]);
    if (!key || !action) {
        if (key) JS_FreeCString(ctx, key);
        if (action) JS_FreeCString(ctx, action);
        return JS_NewString(ctx, "{\"error\":\"Invalid key or action\"}");
    }

    if (security_key.empty() || strcmp(key, security_key.c_str()) != 0) {
        JS_FreeCString(ctx, key);
        JS_FreeCString(ctx, action);
        return JS_NewString(ctx, "{\"error\":\"Invalid key\"}");
    }

    std::string data_str = "";
    if (argc > 2 && JS_IsString(argv[2])) {
        const char *data = JS_ToCString(ctx, argv[2]);
        if (data) {
            data_str = data;
            JS_FreeCString(ctx, data);
        }
    }

    std::string action_str = action;
    JS_FreeCString(ctx, key);
    JS_FreeCString(ctx, action);

    if (action_str == "init") {
        return JS_NewString(ctx, "{\"status\":\"ok\"}");
    }

    if (action_str == "request" || action_str == "response" || action_str == "cancelRequest"
        || action_str == "showUpdateAlert") {
        if (data_str.empty()) {
            return JS_NewString(ctx, "{\"status\":\"ok\"}");
        }

        // showUpdateAlert 不是取链结果，不能进响应队列：它的载荷没有 requestKey/
        // result，混进 g_results 会让 pumpEvents 产出一条对不上号的垃圾记录。
        if (action_str == "showUpdateAlert") {
            LOGI("Native_call updateAlert: %.200s", data_str.c_str());
            return JS_NewString(ctx, "{\"status\":\"ok\"}");
        }

        JSValue payload = JS_ParseJSON(ctx, data_str.c_str(), data_str.size(), "<native-call>");
        if (JS_IsException(payload)) {
            JSValue err = JS_GetException(ctx);
            JS_FreeValue(ctx, err);
            LOGW("Native_call parse failed for action=%s", action_str.c_str());
            return JS_NewString(ctx, "{\"error\":\"Invalid payload\"}");
        }

        if (action_str == "request") {
            PendingRequest req;
            req.request_key = JsonPropString(ctx, payload, "requestKey");
            req.url = JsonPropString(ctx, payload, "url");
            req.options_json = JsonPropStringify(ctx, payload, "options");
            if (req.options_json.empty()) {
                req.options_json = "{}";
            }
            JS_FreeValue(ctx, payload);
            pthread_mutex_lock(&queue_mutex);
            g_requests.push_back(req);
            size_t depth = g_requests.size();
            pthread_mutex_unlock(&queue_mutex);
            LOGI("Native_call queued request key=%s depth=%zu", req.request_key.c_str(), depth);
            return JS_NewString(ctx, "{\"status\":\"pending\"}");
        }

        if (action_str == "response") {
            ActionResult result;
            result.request_key = JsonPropString(ctx, payload, "requestKey");
            result.data_json = data_str;
            JS_FreeValue(ctx, payload);
            pthread_mutex_lock(&queue_mutex);
            g_results.push_back(result);
            pthread_mutex_unlock(&queue_mutex);
            LOGI("Native_call got action result key=%s", result.request_key.c_str());
            return JS_NewString(ctx, "{\"status\":\"ok\"}");
        }

        JS_FreeValue(ctx, payload);
        return JS_NewString(ctx, "{\"status\":\"ok\"}");
    }

    LOGW("Native_call unknown action=%s", action_str.c_str());
    return JS_NewString(ctx, "{\"error\":\"Unknown action\"}");
}

// ==================== QuickJS Setup ====================

/**
 * 把 __lx_native_call__* 这一组 C 函数挂到全局对象上。
 *
 * 必须在每次 LoadScript 之前重新挂一遍：preload 里的 lx_setup() 会把它们
 * 从 globalThis 上 delete 掉（防止脚本自己乱调），如果只在建 context 时挂一次，
 * 那么第二次导入源（或重启后恢复上次启用的源）时 preload 就拿不到 _nativeCall，
 * 整个 lx.request 直接抛 TypeError —— 表现就是「第一个源能用，之后怎么导都失败」。
 */
static void InstallGlobals(JSContext *ctx) {
    JSValue global = JS_GetGlobalObject(ctx);

    JS_SetPropertyStr(ctx, global, "__lx_native_call__",
        JS_NewCFunction(ctx, Native_call, "__lx_native_call__", 3));
    JS_SetPropertyStr(ctx, global, "__lx_native_call__str2b64",
        JS_NewCFunction(ctx, Native_str2b64, "__lx_native_call__str2b64", 1));
    JS_SetPropertyStr(ctx, global, "__lx_native_call__utils_str2b64",
        JS_NewCFunction(ctx, Native_str2b64, "__lx_native_call__utils_str2b64", 1));
    JS_SetPropertyStr(ctx, global, "__lx_native_call__b642buf",
        JS_NewCFunction(ctx, Native_b642buf, "__lx_native_call__b642buf", 1));
    JS_SetPropertyStr(ctx, global, "__lx_native_call__utils_b642buf",
        JS_NewCFunction(ctx, Native_b642buf, "__lx_native_call__utils_b642buf", 1));
    JS_SetPropertyStr(ctx, global, "__lx_native_call__str2md5",
        JS_NewCFunction(ctx, Native_str2md5, "__lx_native_call__str2md5", 1));
    JS_SetPropertyStr(ctx, global, "__lx_native_call__utils_str2md5",
        JS_NewCFunction(ctx, Native_str2md5, "__lx_native_call__utils_str2md5", 1));
    JS_SetPropertyStr(ctx, global, "__lx_native_call__aes_encrypt",
        JS_NewCFunction(ctx, Native_aes_encrypt, "__lx_native_call__aes_encrypt", 4));
    JS_SetPropertyStr(ctx, global, "__lx_native_call__utils_aes_encrypt",
        JS_NewCFunction(ctx, Native_aes_encrypt, "__lx_native_call__utils_aes_encrypt", 4));
    JS_SetPropertyStr(ctx, global, "__lx_native_call__rsa_encrypt",
        JS_NewCFunction(ctx, Native_rsa_encrypt, "__lx_native_call__rsa_encrypt", 3));
    JS_SetPropertyStr(ctx, global, "__lx_native_call__utils_rsa_encrypt",
        JS_NewCFunction(ctx, Native_rsa_encrypt, "__lx_native_call__utils_rsa_encrypt", 3));
    JS_SetPropertyStr(ctx, global, "__lx_native_call__set_timeout",
        JS_NewCFunction(ctx, Native_set_timeout, "__lx_native_call__set_timeout", 2));

    JS_FreeValue(ctx, global);
}

static bool InitJSContext() {
    pthread_mutex_lock(&js_mutex);
    if (runtime == nullptr) {
        runtime = JS_NewRuntime();
        if (runtime == nullptr) {
            LOGE("Failed to create JS runtime");
            pthread_mutex_unlock(&js_mutex);
            return false;
        }
        LOGI("JS Runtime created");
    }
    if (context == nullptr) {
        context = JS_NewContext(runtime);
        if (context == nullptr) {
            LOGE("Failed to create JS context");
            pthread_mutex_unlock(&js_mutex);
            return false;
        }
        LOGI("JS Context created");
        InstallGlobals(context);
    }
    pthread_mutex_unlock(&js_mutex);
    return true;
}

// ==================== NAPI Functions ====================

// 前向声明：CallJS 里要推进微任务，实现在后面的异步桥小节
static int RunPendingJobs();

static napi_value LoadScript(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1];
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);

    if (argc < 1) {
        napi_value result_val;
        napi_create_string_utf8(env, "Expected script string argument", NAPI_AUTO_LENGTH, &result_val);
        return result_val;
    }

    size_t script_len;
    napi_get_value_string_utf8(env, argv[0], nullptr, 0, &script_len);
    char *script = new char[script_len + 1];
    napi_get_value_string_utf8(env, argv[0], script, script_len + 1, &script_len);

    LOGI("Loading script, length: %zu", script_len);

    if (!InitJSContext()) {
        delete[] script;
        napi_value result_val;
        napi_create_string_utf8(env, "Failed to initialize JS context", NAPI_AUTO_LENGTH, &result_val);
        return result_val;
    }

    pthread_mutex_lock(&js_mutex);

    if (security_key.empty()) {
        security_key = DEFAULT_SECURITY_KEY;
    }

    // 每次装脚本前重挂一遍原生钩子：preload 的 lx_setup 会把它们从 globalThis 删掉，
    // 不重挂的话第二次导入源时 preload 拿不到 _nativeCall（详见 InstallGlobals 注释）。
    InstallGlobals(context);

    JSValue result = JS_Eval(context, script, script_len, "<script>", JS_EVAL_TYPE_GLOBAL);
    delete[] script;

    if (JS_IsException(result)) {
        JSValue exception = JS_GetException(context);
        std::string error_text = GetExceptionMessageWithStack(context, exception);
        LOGE("Script error: %s", error_text.c_str());
        JS_FreeValue(context, exception);
        JS_FreeValue(context, result);
        pthread_mutex_unlock(&js_mutex);
        napi_value result_val;
        napi_create_string_utf8(env, error_text.c_str(), NAPI_AUTO_LENGTH, &result_val);
        return result_val;
    }

    JS_FreeValue(context, result);
    // 脚本顶层可能已经把自己塞进微任务（比如直接 send(inited) 后的 then），先跑一轮
    RunPendingJobs();
    pthread_mutex_unlock(&js_mutex);

    napi_value result_val;
    napi_create_string_utf8(env, "", NAPI_AUTO_LENGTH, &result_val);
    return result_val;
}

static napi_value CallJS(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value argv[2];
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);

    if (argc < 2) {
        napi_value result_val;
        napi_create_string_utf8(env, "{\"error\":\"Expected action and data arguments\"}", NAPI_AUTO_LENGTH, &result_val);
        return result_val;
    }

    size_t action_len;
    napi_get_value_string_utf8(env, argv[0], nullptr, 0, &action_len);
    char *action = new char[action_len + 1];
    napi_get_value_string_utf8(env, argv[0], action, action_len + 1, &action_len);

    size_t data_len;
    napi_get_value_string_utf8(env, argv[1], nullptr, 0, &data_len);
    char *data = new char[data_len + 1];
    napi_get_value_string_utf8(env, argv[1], data, data_len + 1, &data_len);

    LOGI("CallJS action=%s data_len=%zu", action, data_len);

    pthread_mutex_lock(&js_mutex);
    if (context == nullptr) {
        pthread_mutex_unlock(&js_mutex);
        delete[] action;
        delete[] data;
        napi_value result_val;
        napi_create_string_utf8(env, "{\"error\":\"JS context not initialized\"}", NAPI_AUTO_LENGTH, &result_val);
        return result_val;
    }

    JSValue global_obj = JS_GetGlobalObject(context);
    JSValue func = JS_GetPropertyStr(context, global_obj, "__lx_native__");

    if (!JS_IsFunction(context, func)) {
        JS_FreeValue(context, global_obj);
        JS_FreeValue(context, func);
        pthread_mutex_unlock(&js_mutex);
        delete[] action;
        delete[] data;
        napi_value result;
        napi_get_null(env, &result);
        return result;
    }

    JSValue args[3] = {
        JS_NewString(context, security_key.c_str()),
        JS_NewString(context, action),
        JS_NewString(context, data)
    };

    JSValue js_result = JS_Call(context, func, global_obj, 3, args);

    for (int i = 0; i < 3; i++) {
        JS_FreeValue(context, args[i]);
    }
    JS_FreeValue(context, global_obj);
    JS_FreeValue(context, func);

    delete[] action;
    delete[] data;

    if (JS_IsException(js_result)) {
        JSValue exception = JS_GetException(context);
        std::string error_text = GetExceptionMessageWithStack(context, exception);
        LOGE("CallJS error: %s", error_text.c_str());
        JS_FreeValue(context, exception);
        JS_FreeValue(context, js_result);
        pthread_mutex_unlock(&js_mutex);
        std::string json_error = "{\"error\":\"" + error_text + "\"}";
        napi_value result_val;
        napi_create_string_utf8(env, json_error.c_str(), NAPI_AUTO_LENGTH, &result_val);
        return result_val;
    }

    napi_value result_val;
    if (JS_IsString(js_result)) {
        const char *result_str = JS_ToCString(context, js_result);
        napi_create_string_utf8(env, result_str, NAPI_AUTO_LENGTH, &result_val);
        JS_FreeCString(context, result_str);
    } else if (JS_IsNumber(js_result)) {
        double num;
        JS_ToFloat64(context, &num, js_result);
        napi_create_double(env, num, &result_val);
    } else if (JS_IsBool(js_result)) {
        int bval = JS_ToBool(context, js_result);
        napi_get_boolean(env, bval != 0, &result_val);
    } else {
        napi_get_null(env, &result_val);
    }

    JS_FreeValue(context, js_result);
    // 同步调用里可能挂上了新的微任务（脚本 send(inited) 之后的 then 等），推进一轮
    RunPendingJobs();
    pthread_mutex_unlock(&js_mutex);

    return result_val;
}

static napi_value Destroy(napi_env env, napi_callback_info info) {
    LOGI("Destroy called");

    pthread_mutex_lock(&js_mutex);
    if (context != nullptr) {
        JS_FreeContext(context);
        context = nullptr;
        LOGI("JS Context freed");
    }
    if (runtime != nullptr) {
        JS_FreeRuntime(runtime);
        runtime = nullptr;
        LOGI("JS Runtime freed");
    }
    security_key.clear();
    pthread_mutex_unlock(&js_mutex);

    // 引擎销毁时把异步桥的队列一起清掉：残留的 requestKey 已经不可能再被回调，
    // 留着只会让下一次 pump 把结果丢给一个不存在的 context。
    pthread_mutex_lock(&queue_mutex);
    g_requests.clear();
    g_timers.clear();
    g_results.clear();
    pthread_mutex_unlock(&queue_mutex);

    napi_value result;
    napi_get_undefined(env, &result);
    return result;
}

// ==================== 异步桥 NAPI 导出 ====================

/**
 * 调用 JS 侧的 __lx_native__(key, action, dataJson)，调用方必须已持有 js_mutex。
 * 这是 native -> JS 的唯一入口（preload 里 jsCall 的分发点）。
 */
static JSValue CallNativeEntry(const char *action, const char *data_json, const char *tag) {
    if (context == nullptr) {
        return JS_EXCEPTION;
    }
    JSValue global = JS_GetGlobalObject(context);
    JSValue func = JS_GetPropertyStr(context, global, "__lx_native__");
    if (!JS_IsFunction(context, func)) {
        JS_FreeValue(context, func);
        JS_FreeValue(context, global);
        LOGE("%s: __lx_native__ not found", tag);
        return JS_EXCEPTION;
    }

    JSValue args[3] = {
        JS_NewString(context, security_key.c_str()),
        JS_NewString(context, action),
        JS_NewString(context, data_json)
    };
    JSValue ret = JS_Call(context, func, global, 3, args);
    for (int i = 0; i < 3; i++) {
        JS_FreeValue(context, args[i]);
    }
    JS_FreeValue(context, func);
    JS_FreeValue(context, global);

    if (JS_IsException(ret)) {
        JSValue exception = JS_GetException(context);
        std::string error_text = GetExceptionMessageWithStack(context, exception);
        LOGE("%s: %s", tag, error_text.c_str());
        JS_FreeValue(context, exception);
    }
    return ret;
}

/** 跑完 JS 微任务队列（Promise then/catch），调用方必须已持有 js_mutex */
static int RunPendingJobs() {
    if (runtime == nullptr) {
        return 0;
    }
    JSContext *ctx = context;
    int total = 0;
    for (int guard = 0; guard < 64; guard++) {
        int executed = JS_ExecutePendingJob(runtime, &ctx);
        if (executed <= 0) {
            break;
        }
        total += executed;
    }
    return total;
}

/**
 * takePendingRequest(): string
 * 取一条 JS 侧待发的 HTTP 请求，返回 JSON：
 *   {"requestKey":"...","url":"...","options":{...}}；队列为空返回空串。
 */
static napi_value TakePendingRequest(napi_env env, napi_callback_info info) {
    std::string out;
    pthread_mutex_lock(&queue_mutex);
    if (!g_requests.empty()) {
        PendingRequest req = g_requests.front();
        g_requests.erase(g_requests.begin());
        out = "{\"requestKey\":";
        AppendJsonString(out, req.request_key);
        out += ",\"url\":";
        AppendJsonString(out, req.url);
        out += ",\"options\":";
        out += req.options_json.empty() ? "{}" : req.options_json;
        out += "}";
    }
    pthread_mutex_unlock(&queue_mutex);

    napi_value result_val;
    napi_create_string_utf8(env, out.c_str(), out.size(), &result_val);
    return result_val;
}

/**
 * completeRequest(responseJson): boolean
 * 把 HTTP 结果交回 JS：触发 __lx_native__('response', ...) -> preload 的
 * handleNativeResponse -> 脚本的 request 回调 resolve -> Promise 继续往下走。
 * responseJson 为 preload 期望的形状：
 *   {"requestKey":"..","statusCode":200,"headers":{..},"body":..} 或 {"error":true,"errorMessage":".."}
 */
static napi_value CompleteRequest(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1];
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);

    bool ok = false;
    if (argc >= 1 && context != nullptr) {
        size_t resp_len = 0;
        napi_get_value_string_utf8(env, argv[0], nullptr, 0, &resp_len);
        char *resp = new char[resp_len + 1];
        napi_get_value_string_utf8(env, argv[0], resp, resp_len + 1, &resp_len);

        pthread_mutex_lock(&js_mutex);
        JSValue ret = CallNativeEntry("response", resp, "completeRequest");
        ok = !JS_IsException(ret);
        if (ok) {
            JS_FreeValue(context, ret);
            // 回调里可能又发了新请求 / 直接产出了结果，顺手推进一轮
            RunPendingJobs();
        }
        pthread_mutex_unlock(&js_mutex);
        delete[] resp;
    }

    napi_value result_val;
    napi_get_boolean(env, ok, &result_val);
    return result_val;
}

/**
 * 把 g_results 里的一条载荷拆成 {requestKey, status, errorMessage, result}。
 *
 * 存进来的是 preload 里 nativeCall('response', {...}) 的原始对象：
 *   成功：{"requestKey":"..","status":true,"result":{"source":..,"action":..,"data":..}}
 *   失败：{"requestKey":"..","status":false,"errorMessage":".."}
 * 必须把 result 抽出来再交给 ArkTS：直接把整个对象当 data 传，
 * 业务层读 data.url 永远读不到（真实取链结果藏在 result.data.url 里）。
 */
static bool AppendActionResult(std::string& out, const std::string& payload_json) {
    JSContext *ctx = context;
    if (ctx == nullptr) {
        return false;
    }

    JSValue payload = JS_ParseJSON(ctx, payload_json.c_str(), payload_json.size(), "<result>");
    if (JS_IsException(payload)) {
        JSValue err = JS_GetException(ctx);
        JS_FreeValue(ctx, err);
        return false;
    }

    std::string request_key = JsonPropString(ctx, payload, "requestKey");
    JSValue status_val = JS_GetPropertyStr(ctx, payload, "status");
    bool ok = !JS_IsBool(status_val) || JS_ToBool(ctx, status_val) != 0;
    JS_FreeValue(ctx, status_val);

    std::string error_message;
    if (!ok) {
        error_message = JsonPropString(ctx, payload, "errorMessage");
    }

    out += "{\"requestKey\":";
    AppendJsonString(out, request_key);
    out += ",\"status\":";
    out += ok ? "true" : "false";
    out += ",\"errorMessage\":";
    AppendJsonString(out, error_message);
    out += ",\"result\":";

    JSValue result_val = JS_GetPropertyStr(ctx, payload, "result");
    if (JS_IsUndefined(result_val) || JS_IsNull(result_val)) {
        out += "null";
    } else {
        JSValue dumped = JS_JSONStringify(ctx, result_val, JS_UNDEFINED, JS_UNDEFINED);
        if (JS_IsString(dumped)) {
            const char *text = JS_ToCString(ctx, dumped);
            out += (text && text[0] != '\0') ? text : "null";
            if (text) {
                JS_FreeCString(ctx, text);
            }
        } else {
            out += "null";
        }
        JS_FreeValue(ctx, dumped);
    }
    JS_FreeValue(ctx, result_val);
    JS_FreeValue(ctx, payload);
    out += "}";   // 收尾 item 对象：漏了它整条就是非法 JSON，parse 失败后结果被丢弃
    return true;
}

/**
 * pumpEvents(): string
 * 派遣到期的 setTimeout、跑完 JS 微任务，然后取走脚本通过 lx.send('response')
 * 产出的结果。返回 JSON 数组：
 *   [{"requestKey":"..","status":true,"errorMessage":"","result":{..}}]
 *
 * 为什么要主动 pump：QuickJS 不会自己跑 Promise 回调，脚本里的
 * `.then(() => send(response))` 必须由宿主在执行完 IO 后再进一次 JS 才能推进。
 */
static napi_value PumpEvents(napi_env env, napi_callback_info info) {
    std::string out = "[";

    if (context == nullptr) {
        out += "]";
        napi_value result_val;
        napi_create_string_utf8(env, out.c_str(), out.size(), &result_val);
        return result_val;
    }

    // 1) 到期的 setTimeout 先派发
    std::vector<int64_t> due;
    pthread_mutex_lock(&queue_mutex);
    int64_t now = NowMs();
    for (size_t i = 0; i < g_timers.size();) {
        if (g_timers[i].due_ms <= now) {
            due.push_back(g_timers[i].id);
            g_timers.erase(g_timers.begin() + static_cast<long>(i));
        } else {
            i++;
        }
    }
    // 顺手把已经取走的结果腾出来，稍后统一解析
    std::vector<ActionResult> results;
    results.swap(g_results);
    pthread_mutex_unlock(&queue_mutex);

    pthread_mutex_lock(&js_mutex);
    for (size_t i = 0; i < due.size(); i++) {
        char payload[32];
        snprintf(payload, sizeof(payload), "%lld", static_cast<long long>(due[i]));
        JSValue ret = CallNativeEntry("__set_timeout__", payload, "pumpEvents/timer");
        if (!JS_IsException(ret)) {
            JS_FreeValue(context, ret);
        }
    }
    // 2) 跑完 JS 微任务
    RunPendingJobs();

    // 3) 拆包（要在持有 js_mutex 时做：AppendActionResult 会碰 JS context）
    bool first = true;
    for (size_t i = 0; i < results.size(); i++) {
        std::string item;
        if (!AppendActionResult(item, results[i].data_json)) {
            continue;
        }
        if (!first) {
            out += ",";
        }
        out += item;
        first = false;
    }
    pthread_mutex_unlock(&js_mutex);

    out += "]";
    napi_value result_val;
    napi_create_string_utf8(env, out.c_str(), out.size(), &result_val);
    return result_val;
}

/**
 * hasPendingWork(): boolean
 * pump 循环用它判断还要不要再转一轮（有请求待发 / 有到期定时器 / 有结果待取）。
 */
static napi_value HasPendingWork(napi_env env, napi_callback_info info) {
    bool pending = false;
    pthread_mutex_lock(&queue_mutex);
    if (!g_requests.empty() || !g_results.empty()) {
        pending = true;
    } else {
        int64_t now = NowMs();
        for (size_t i = 0; i < g_timers.size(); i++) {
            if (g_timers[i].due_ms <= now) {
                pending = true;
                break;
            }
        }
    }
    pthread_mutex_unlock(&queue_mutex);

    napi_value result_val;
    napi_get_boolean(env, pending, &result_val);
    return result_val;
}

// ==================== Plain C API for dlopen/dlsym ====================
// These functions can be called from the loader module via dlsym

extern "C" {

/**
 * Load a JavaScript script (plain C version)
 * @param script The JavaScript source code
 * @return Error message or empty string on success
 */
const char* napi_loadScript(const char* script) {
    if (!script || !context) {
        return "Invalid arguments or JS context not initialized";
    }

    pthread_mutex_lock(&js_mutex);

    if (security_key.empty()) {
        security_key = DEFAULT_SECURITY_KEY;
    }
    InstallGlobals(context);

    size_t script_len = strlen(script);
    JSValue result = JS_Eval(context, script, script_len, "<script>", JS_EVAL_TYPE_GLOBAL);

    if (JS_IsException(result)) {
        JSValue exception = JS_GetException(context);
        std::string error_text = GetExceptionMessageWithStack(context, exception);
        JS_FreeValue(context, exception);
        JS_FreeValue(context, result);
        pthread_mutex_unlock(&js_mutex);

        static thread_local char error_buffer[512];
        strncpy(error_buffer, error_text.c_str(), sizeof(error_buffer) - 1);
        error_buffer[sizeof(error_buffer) - 1] = '\0';
        return error_buffer;
    }

    JS_FreeValue(context, result);
    pthread_mutex_unlock(&js_mutex);
    return "";
}

/**
 * Call a JavaScript function (plain C version)
 * @param action The action name
 * @param data JSON stringified data
 * @return Result string
 */
const char* napi_callJS(const char* action, const char* data) {
    if (!action || !data || !context) {
        return "{\"error\":\"Invalid arguments or JS context not initialized\"}";
    }

    pthread_mutex_lock(&js_mutex);

    JSValue global_obj = JS_GetGlobalObject(context);
    JSValue func = JS_GetPropertyStr(context, global_obj, "__lx_native__");

    if (!JS_IsFunction(context, func)) {
        JS_FreeValue(context, global_obj);
        JS_FreeValue(context, func);
        pthread_mutex_unlock(&js_mutex);
        return "{\"error\":\"__lx_native__ function not found\"}";
    }

    JSValue args[3] = {
        JS_NewString(context, security_key.c_str()),
        JS_NewString(context, action),
        JS_NewString(context, data)
    };

    JSValue js_result = JS_Call(context, func, global_obj, 3, args);

    JS_FreeValue(context, global_obj);
    JS_FreeValue(context, func);
    for (int i = 0; i < 3; i++) {
        JS_FreeValue(context, args[i]);
    }

    if (JS_IsException(js_result)) {
        JSValue exception = JS_GetException(context);
        std::string error_text = GetExceptionMessageWithStack(context, exception);
        JS_FreeValue(context, exception);
        JS_FreeValue(context, js_result);
        pthread_mutex_unlock(&js_mutex);

        static thread_local char error_buffer[512];
        snprintf(error_buffer, sizeof(error_buffer), "{\"error\":\"%s\"}", error_text.c_str());
        return error_buffer;
    }

    const char* result_str = JS_ToCString(context, js_result);
    JS_FreeValue(context, js_result);

    // 之前这里是 8192 的固定缓冲 + strncpy：自定义源返回的歌词/歌单 JSON 常超过 8KB，
    // 会被静默截成非法 JSON。改成按实际长度分配。
    static thread_local std::string result_holder;
    result_holder = result_str ? result_str : "";
    if (result_str) {
        JS_FreeCString(context, result_str);
    }
    pthread_mutex_unlock(&js_mutex);

    return result_holder.c_str();
}

/**
 * Destroy the QuickJS context (plain C version)
 */
void napi_destroy(void) {
    LOGI("napi_destroy called");
    pthread_mutex_lock(&js_mutex);

    if (context != nullptr) {
        JS_FreeContext(context);
        context = nullptr;
    }
    if (runtime != nullptr) {
        JS_FreeRuntime(runtime);
        runtime = nullptr;
    }
    security_key.clear();

    pthread_mutex_unlock(&js_mutex);
}

} // extern "C"

// ==================== Module Export ====================

static napi_value Export(napi_env env, napi_value exports) {
    napi_value loadScriptFn;
    napi_create_function(env, "loadScript", NAPI_AUTO_LENGTH, LoadScript, nullptr, &loadScriptFn);
    napi_set_named_property(env, exports, "loadScript", loadScriptFn);

    napi_value callJSFn;
    napi_create_function(env, "callJS", NAPI_AUTO_LENGTH, CallJS, nullptr, &callJSFn);
    napi_set_named_property(env, exports, "callJS", callJSFn);

    napi_value destroyFn;
    napi_create_function(env, "destroy", NAPI_AUTO_LENGTH, Destroy, nullptr, &destroyFn);
    napi_set_named_property(env, exports, "destroy", destroyFn);

    // 异步桥：JS 的 lx.request 与实际 HTTP 之间靠这四个函数对接
    napi_value takeFn;
    napi_create_function(env, "takePendingRequest", NAPI_AUTO_LENGTH, TakePendingRequest, nullptr, &takeFn);
    napi_set_named_property(env, exports, "takePendingRequest", takeFn);

    napi_value completeFn;
    napi_create_function(env, "completeRequest", NAPI_AUTO_LENGTH, CompleteRequest, nullptr, &completeFn);
    napi_set_named_property(env, exports, "completeRequest", completeFn);

    napi_value pumpFn;
    napi_create_function(env, "pumpEvents", NAPI_AUTO_LENGTH, PumpEvents, nullptr, &pumpFn);
    napi_set_named_property(env, exports, "pumpEvents", pumpFn);

    napi_value pendingFn;
    napi_create_function(env, "hasPendingWork", NAPI_AUTO_LENGTH, HasPendingWork, nullptr, &pendingFn);
    napi_set_named_property(env, exports, "hasPendingWork", pendingFn);

    LOGI("QuickJS NAPI module exported");
    return exports;
}

NAPI_MODULE_INIT() {
    LOGI("QuickJS NAPI module initializing");
    return Export(env, exports);
}
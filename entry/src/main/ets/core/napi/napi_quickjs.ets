/**
 * QuickJS 原生引擎封装（自定义源插件执行环境）
 *
 * 原生库句柄不在这里直接 import：统一走 core/napi/NativeModules.ets 的
 * getQuickJSModule() / getQuickJSLoaderModule() 取，接口形状声明在
 * core/napi/NativeModuleTypes.ets。这里只负责引擎生命周期与脚本调用。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { utf8Decode } from '../../utils/TextCodec';
import { httpRequest } from '../network/http';
import type { common } from '@kit.AbilityKit';
import {
  getQuickJSLoaderModule,
  getQuickJSModule,
} from './NativeModules';
import type { QuickJSLoaderNativeModule, QuickJSNativeModule } from './NativeModuleTypes';

/** QuickJS 引擎接口形状由 NativeModuleTypes.ets 单一声明，这里沿用旧类型名 */
export type QuickJSNAPI = QuickJSNativeModule;

function formatErrorMessage(err: Object): string {
  const e = err as Error;
  if (e && e.message && e.message.length > 0) {
    return e.message;
  }
  const text = String(err);
  if (text && text !== '[object Object]') {
    return text;
  }
  const json = JSON.stringify(err);
  if (json && json !== '{}') {
    return json;
  }
  return 'unknown error object';
}

// Module tag for logging
const MODULE_TAG = 'QuickJSNAPI';
const DOMAIN = 0xFF01;

// Native module instance - loaded via dlopen
let quickjsModule: QuickJSNAPI | null = null;
let isInitialized = false;

// Loaded script content for re-initialization
let loadedPreloadScript: string = '';
let abilityContext: common.UIAbilityContext | null = null;

export function setQuickJSContext(context: common.UIAbilityContext): void {
  abilityContext = context;
}

function getQuickJSContext(): common.UIAbilityContext {
  if (abilityContext) {
    return abilityContext;
  }
  throw new Error('QuickJS context not set');
}

// Native function type definitions
type LoadScriptFn = (script: string) => string;
type CallJSFn = (action: string, data: string) => string;
type DestroyFn = () => void;

// Function handles from native library
let loadScriptFn: LoadScriptFn | null = null;
let callJSFn: CallJSFn | null = null;
let destroyFn: DestroyFn | null = null;

/**
 * 直连 quickjs_napi.so 时留一份句柄：异步桥（takePendingRequest / completeRequest /
 * pumpEvents / hasPendingWork）只在直连模式下可用，loader 兜底路径没有这些导出。
 */
let directModule: QuickJSNativeModule | null = null;

class QuickJSFunctionAdapter implements QuickJSNAPI {
  loadScript(script: string): string {
    hilog.info(DOMAIN, MODULE_TAG, 'QuickJS loadScript called, length: %{public}d', script.length);
    if (loadScriptFn) {
      return loadScriptFn(script);
    }
    return '';
  }

  callJS(action: string, data: string): string {
    hilog.info(DOMAIN, MODULE_TAG, 'QuickJS callJS called: %{public}s', action);
    if (callJSFn) {
      return callJSFn(action, data);
    }
    return '{"error":"stub"}';
  }

  destroy(): void {
    hilog.info(DOMAIN, MODULE_TAG, 'QuickJS destroy called');
    if (destroyFn) {
      destroyFn();
    }
  }

  takePendingRequest(): string {
    return directModule ? directModule.takePendingRequest() : '';
  }

  completeRequest(responseJson: string): boolean {
    return directModule ? directModule.completeRequest(responseJson) : false;
  }

  pumpEvents(): string {
    return directModule ? directModule.pumpEvents() : '[]';
  }

  hasPendingWork(): boolean {
    return directModule ? directModule.hasPendingWork() : false;
  }
}

/**
 * Load the native library and get the QuickJS NAPI interface
 */
function loadNativeModule(): boolean {
  hilog.info(DOMAIN, MODULE_TAG, 'Loading QuickJS native module');

  // 1) 优先直连 native-modules.d.ts 声明的 quickjs_napi.so
  const directNapi: QuickJSNativeModule | null = getQuickJSModule();
  if (directNapi &&
      typeof directNapi.loadScript === 'function' &&
      typeof directNapi.callJS === 'function' &&
      typeof directNapi.destroy === 'function') {
    hilog.info(DOMAIN, MODULE_TAG, 'Using direct quickjs_napi.so module');
    directModule = directNapi;
    loadScriptFn = (script: string): string => directNapi.loadScript(script);
    callJSFn = (action: string, data: string): string => directNapi.callJS(action, data);
    destroyFn = (): void => directNapi.destroy();
    return true;
  }

  // 2) 直连不可用时，通过 quickjs_loader.so 按路径 dlopen quickjs_napi.so
  const loaderSo: QuickJSLoaderNativeModule | null = getQuickJSLoaderModule();
  if (loaderSo && typeof loaderSo.loadQuickJS === 'function') {
    const context = getQuickJSContext();
    const bundleCodeDir = context.bundleCodeDir;
    const candidates: string[] = [
      `${bundleCodeDir}/libs/arm64-v8a/libquickjs_napi.so`,
      `${bundleCodeDir}/libs/x86_64/libquickjs_napi.so`,
      `${bundleCodeDir}/libs/libquickjs_napi.so`,
      `${bundleCodeDir}/libs/arm64-v8a/liblibquickjs_napi.so`,
      `${bundleCodeDir}/libs/liblibquickjs_napi.so`,
    ];
    for (let i = 0; i < candidates.length; i++) {
      const path = candidates[i];
      try {
        hilog.info(DOMAIN, MODULE_TAG, 'Loader trying path: %{public}s', path);
        if (loaderSo.loadQuickJS(path)) {
          hilog.info(DOMAIN, MODULE_TAG, 'Loader loaded quickjs_napi.so successfully');
          loadScriptFn = (script: string): string => loaderSo.loadScript(script);
          callJSFn = (action: string, data: string): string => loaderSo.callJS(action, data);
          destroyFn = (): void => loaderSo.unload();
          return true;
        }
      } catch (e) {
        hilog.warn(DOMAIN, MODULE_TAG, 'Loader path failed: %{public}s', formatErrorMessage(e as Object));
      }
    }
  }

  hilog.warn(DOMAIN, MODULE_TAG, 'Native QuickJS module not available');
  return false;
}

/**
 * Initialize the QuickJS native module
 */
export function initQuickJS(): boolean {
  if (isInitialized && quickjsModule) {
    hilog.info(DOMAIN, MODULE_TAG, 'QuickJS already initialized');
    return true;
  }

  hilog.info(DOMAIN, MODULE_TAG, 'Initializing QuickJS native module');

  // Try to load native module
  if (!loadNativeModule()) {
    hilog.error(DOMAIN, MODULE_TAG, 'Failed to load QuickJS native module');
    return false;
  }

  try {
    quickjsModule = new QuickJSFunctionAdapter();

    isInitialized = true;
    hilog.info(DOMAIN, MODULE_TAG, 'QuickJS initialized successfully');
    return true;
  } catch (e) {
    hilog.error(DOMAIN, MODULE_TAG, 'Exception during QuickJS init: %{public}s', formatErrorMessage(e as Object));
    return false;
  }
}

/**
 * Load the preload script (user-api-preload.js) into QuickJS
 * This sets up the lx global object and native callbacks
 */
export async function loadPreloadScript(): Promise<boolean> {
  if (!isInitialized || !quickjsModule) {
    hilog.error(DOMAIN, MODULE_TAG, 'QuickJS not initialized');
    return false;
  }

  try {
    const context = getQuickJSContext();
    const rawMgr = context.resourceManager;
    if (!rawMgr || typeof rawMgr.getRawFileContent !== 'function') {
      hilog.warn(DOMAIN, MODULE_TAG, 'ResourceManager.getRawFileContent is unavailable');
      return false;
    }
    const preloadBytes = await rawMgr.getRawFileContent('user-api-preload.js');
    if (!preloadBytes || preloadBytes.length === 0) {
      hilog.warn(DOMAIN, MODULE_TAG, 'user-api-preload.js is empty');
      return false;
    }
    loadedPreloadScript = utf8Decode(preloadBytes);
    hilog.info(DOMAIN, MODULE_TAG, 'Preload script loaded, length: %{public}d', loadedPreloadScript.length);
    return loadedPreloadScript.length > 0;
  } catch (e) {
    hilog.error(DOMAIN, MODULE_TAG, 'Exception loading preload: %{public}s', formatErrorMessage(e as Object));
    return false;
  }
}

/**
 * Load JavaScript plugin source code
 * @param script The JavaScript source code from the plugin
 * @returns true if loaded successfully
 */
export function loadPluginScript(script: string): boolean {
  if (!isInitialized) {
    hilog.error(DOMAIN, MODULE_TAG, 'QuickJS not initialized');
    return false;
  }

  if (!quickjsModule) {
    hilog.error(DOMAIN, MODULE_TAG, 'QuickJS module not available');
    return false;
  }

  try {
    hilog.info(DOMAIN, MODULE_TAG, 'Loading plugin script, length: %{public}d', script.length);

    // First load the preload script
    if (loadedPreloadScript.length > 0) {
      const preloadResult = quickjsModule.loadScript(loadedPreloadScript);
      if (preloadResult && preloadResult.length > 0) {
        hilog.error(DOMAIN, MODULE_TAG, 'Failed to load preload: %{public}s', preloadResult);
        return false;
      }
    }

    // Then load the plugin script
    const result = quickjsModule.loadScript(script);
    if (result && result.length > 0) {
      hilog.error(DOMAIN, MODULE_TAG, 'Failed to load plugin script: %{public}s', result);
      return false;
    }

    hilog.info(DOMAIN, MODULE_TAG, 'Plugin script loaded successfully');
    return true;
  } catch (e) {
    hilog.error(DOMAIN, MODULE_TAG, 'Exception loading plugin script: %{public}s', formatErrorMessage(e as Object));
    return false;
  }
}

/**
 * Call a function in the JavaScript plugin context
 * @param action The action to perform (e.g., 'search', 'musicUrl', 'lyric')
 * @param data The data to pass to the action
 * @returns The result from the JavaScript plugin
 */
export function callPluginAction(action: string, data: string): string {
  if (!isInitialized) {
    hilog.error(DOMAIN, MODULE_TAG, 'QuickJS not initialized');
    return '';
  }

  if (!quickjsModule) {
    hilog.error(DOMAIN, MODULE_TAG, 'QuickJS module not available');
    return '';
  }

  try {
    hilog.debug(DOMAIN, MODULE_TAG, 'Calling action: %{public}s', action);
    const result = quickjsModule.callJS(action, data);
    return result ?? '';
  } catch (e) {
    hilog.error(DOMAIN, MODULE_TAG, 'Exception calling action: %{public}s', formatErrorMessage(e as Object));
    return '';
  }
}

// ==================== 异步桥（脚本取链必需） ====================

/** 脚本通过 lx.request 发出的、等待宿主执行的 HTTP 请求 */
interface ScriptPendingRequest {
  requestKey: string;
  url: string;
  options: ScriptRequestOptions;
}

/** lx.request 的 options（脚本侧可传字段，其余忽略） */
interface ScriptRequestOptions {
  method?: string;
  headers?: Record<string, string>;
  body?: string | Object;
  timeout?: number;
  binary?: boolean;
}

/** 回给 preload 的 HTTP 响应体（preload 的 handleNativeResponse 读这几个字段） */
interface ScriptHttpResponse {
  statusCode: number;
  statusMessage: string;
  headers: Record<string, string>;
  body: string;
}

/** 一条 native -> JS 的响应载荷 */
interface ScriptResponsePayload {
  requestKey: string;
  response?: ScriptHttpResponse;
  error?: boolean;
  errorMessage?: string;
}

/** pumpEvents 取回的一条脚本产出（已由原生侧拆包） */
interface ScriptActionResult {
  requestKey: string;
  status: boolean;
  errorMessage: string;
  result?: Object | null;
}

/** 脚本返回的业务数据（preload 已按 action 校验过） */
export interface ScriptActionResponse {
  source?: string;
  action?: string;
  data?: Object | string | null;
}

let requestSeq = 0;

function nextRequestKey(): string {
  requestSeq++;
  return `lxreq_${Date.now()}_${requestSeq}`;
}

function delay(ms: number): Promise<void> {
  return new Promise<void>((resolve: () => void) => {
    setTimeout(resolve, ms);
  });
}

/** 取一条脚本待发的请求；没有则返回 null */
function takePendingRequest(): ScriptPendingRequest | null {
  if (!quickjsModule) {
    return null;
  }
  try {
    const raw = quickjsModule.takePendingRequest();
    if (!raw || raw.length === 0) {
      return null;
    }
    return JSON.parse(raw) as ScriptPendingRequest;
  } catch (e) {
    hilog.warn(DOMAIN, MODULE_TAG, 'takePendingRequest parse failed: %{public}s',
      formatErrorMessage(e as Object));
    return null;
  }
}

/** 把 HTTP 结果交回脚本，推进其 Promise 链 */
function completeRequest(payload: ScriptResponsePayload): void {
  if (!quickjsModule) {
    return;
  }
  try {
    quickjsModule.completeRequest(JSON.stringify(payload));
  } catch (e) {
    hilog.warn(DOMAIN, MODULE_TAG, 'completeRequest failed: %{public}s',
      formatErrorMessage(e as Object));
  }
}

/** 派遣到期定时器 + 跑完微任务，取回脚本产出的响应 */
function pumpEvents(): ScriptActionResult[] {
  if (!quickjsModule) {
    return [];
  }
  try {
    const raw = quickjsModule.pumpEvents();
    if (!raw || raw.length === 0 || raw === '[]') {
      return [];
    }
    try {
      return JSON.parse(raw) as ScriptActionResult[];
    } catch (parseErr) {
      hilog.warn(DOMAIN, MODULE_TAG, 'pumpEvents parse failed: %{public}s raw=%{public}s',
        formatErrorMessage(parseErr as Object), raw.length > 500 ? raw.substring(0, 500) : raw);
      return [];
    }
  } catch (e) {
    hilog.warn(DOMAIN, MODULE_TAG, 'pumpEvents call failed: %{public}s',
      formatErrorMessage(e as Object));
    return [];
  }
}

/** 执行脚本发来的一条 HTTP 请求，并把结果写回 JS */
async function runScriptRequest(req: ScriptPendingRequest): Promise<void> {
  const opts: ScriptRequestOptions = req.options ?? {};
  const header: Record<string, string> = opts.headers ?? {};
  const method = (opts.method ?? 'GET').toUpperCase();
  let extraData: string | undefined = undefined;
  if (opts.body !== undefined && opts.body !== null) {
    extraData = typeof opts.body === 'string' ? opts.body : JSON.stringify(opts.body);
  }
  const timeout = opts.timeout && opts.timeout > 0 ? Math.min(opts.timeout, 30000) : 20000;

  try {
    const task = httpRequest(req.url, {
      method: method as 'GET' | 'POST' | 'PUT' | 'DELETE' | 'PATCH' | 'HEAD',
      headers: header,
      extraData: extraData,
      timeout: timeout,
      responseType: 'text',
      connectTimeout: timeout,
      readTimeout: timeout,
    });
    const response = await task.promise;
    // body 必须是文本：preload 会在 JS 侧再包一层（见 user-api-preload.js 的 makeBody）
    const bodyText = response.rawText;
    hilog.info(DOMAIN, MODULE_TAG, 'script request status=%{public}d url=%{public}s body=%{public}s',
      response.status, req.url, bodyText.length > 400 ? bodyText.substring(0, 400) : bodyText);
    const payload: ScriptResponsePayload = {
      requestKey: req.requestKey,
      response: {
        statusCode: response.status,
        statusMessage: response.statusText,
        headers: response.headers,
        body: bodyText,
      },
    };
    completeRequest(payload);
  } catch (e) {
    const message = formatErrorMessage(e as Object);
    hilog.warn(DOMAIN, MODULE_TAG, 'script request failed: %{public}s %{public}s', req.url, message);
    const payload: ScriptResponsePayload = {
      requestKey: req.requestKey,
      error: true,
      errorMessage: message,
    };
    completeRequest(payload);
  }
}

/**
 * 让脚本执行一次 action 并等它把结果交回来。
 *
 * LX 自定义源的取链是异步的：脚本要自己发 HTTP、等响应、再 resolve Promise。
 * QuickJS 是同步引擎，宿主必须在这段时间里反复「替它发请求 + 推进微任务」，
 * 直到脚本通过 lx.send('response') 把结果吐出来。之前的实现是同步返回，
 * 脚本的 Promise 永远停在 pending，所以取链必然拿不到地址。
 *
 * @param action preload 的 action 名（musicUrl / lyric / pic）
 * @param source 音乐平台标识（kw/kg/tx/wy/mg）。源脚本靠它决定去哪个平台取链，
 *               漏传会让脚本拼出 source=undefined 的请求，服务端直接拒绝
 * @param infoJson 传给脚本的 info 对象（JSON 串）
 * @param timeoutMs 整体超时
 * @returns 脚本返回的数据（musicUrl 是 URL 字符串）；失败或超时返回 null
 */
export async function invokePluginAction(
  action: string, source: string, infoJson: string, timeoutMs: number
): Promise<ScriptActionResponse | null> {
  if (!isInitialized || !quickjsModule) {
    hilog.error(DOMAIN, MODULE_TAG, 'invokePluginAction: QuickJS not ready');
    return null;
  }

  const requestKey = nextRequestKey();
  const payload = `{"requestKey":${JSON.stringify(requestKey)},"source":${JSON.stringify(source)},` +
    `"action":${JSON.stringify(action)},"info":${infoJson}}`;
  hilog.info(DOMAIN, MODULE_TAG, 'invokePluginAction action=%{public}s source=%{public}s key=%{public}s',
    action, source, requestKey);
  callPluginAction('request', payload);

  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    // 1) 把脚本要发的 HTTP 请求全部取出去发（不阻塞，完成后自己回写）
    for (let i = 0; i < 8; i++) {
      const pending = takePendingRequest();
      if (!pending) {
        break;
      }
      runScriptRequest(pending).catch((err: Error) => {
        hilog.warn(DOMAIN, MODULE_TAG, 'runScriptRequest crashed: %{public}s', err.message);
      });
    }

    // 2) 推进 JS（到期定时器 + 微任务），收取产出
    const results = pumpEvents();
    for (let i = 0; i < results.length; i++) {
      const item = results[i];
      if (item.requestKey === requestKey) {
        if (!item.status) {
          // preload 在脚本 reject 时回 {"status":false,"errorMessage":..}，
          // 原先把这条当成功吞掉了，排查时只看得到「返回空 URL」
          hilog.warn(DOMAIN, MODULE_TAG, 'script action error: %{public}s',
            item.errorMessage.length > 0 ? item.errorMessage : 'unknown');
          return null;
        }
        const parsed = item.result as ScriptActionResponse | null;
        hilog.info(DOMAIN, MODULE_TAG, 'invokePluginAction done action=%{public}s', action);
        return parsed;
      }
    }

    await delay(25);
  }

  hilog.warn(DOMAIN, MODULE_TAG, 'invokePluginAction timeout action=%{public}s after %{public}dms',
    action, timeoutMs);
  return null;
}

/**
 * Destroy the QuickJS context and release resources
 */
export function destroyQuickJS(): void {  if (!isInitialized) {
    return;
  }

  try {
    hilog.info(DOMAIN, MODULE_TAG, 'Destroying QuickJS');

    if (quickjsModule) {
      quickjsModule.destroy();
    }

    quickjsModule = null;
    isInitialized = false;
    loadedPreloadScript = '';

    hilog.info(DOMAIN, MODULE_TAG, 'QuickJS destroyed');
  } catch (e) {
    hilog.error(DOMAIN, MODULE_TAG, 'Exception destroying QuickJS: %{public}s', formatErrorMessage(e as Object));
  }
}

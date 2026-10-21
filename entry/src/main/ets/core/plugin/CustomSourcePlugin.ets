/**
 * 自定义源插件实现
 * 基于 QuickJS 原生引擎执行插件 JS 代码
 */
// 日志经由应用日志门面，既输出 hilog 也进入「设置 → 运行日志」
import { appLog as hilog } from '../log/AppLogger';
import {
  initQuickJS as initNativeQuickJS,
  loadPluginScript,
  callPluginAction,
  invokePluginAction,
  destroyQuickJS as destroyNativeQuickJS,
  loadPreloadScript
} from '../napi/napi_quickjs';
import { httpRequest } from '../network/http';
import type { Plugin, PluginSongInfo, PluginLyricInfo, PluginSearchResult, PluginSongListResult, PluginBoard, PluginBoardDetail, PluginHotSearch } from './PluginManager';

const TAG = 'CustomSourcePlugin';
const DOMAIN = 0x0001;

// QuickJS request info
interface QuickJSRequestInfo {
  mid?: string;
  hash?: string;
  type?: string;
  musicInfo?: PluginSongInfo;
  keyword?: string;
  page?: number;
  tagId?: string;
  boardId?: string;
}

// QuickJS request result
interface QuickJSRequestResult {
  url?: string;
  pic?: string;
  lyric?: string;
  list?: object[];
  total?: number;
}

/** musicUrl 的 info.type 需要带上音质；preload 校验后 data 是 { type, url } */
interface QuickJSMusicUrlData {
  type?: string;
  url?: string;
}

/** 取链超时：一次点击要等脚本自己发 HTTP 再回包，给足时间 */
const MUSIC_URL_TIMEOUT_MS = 15000;
const LYRIC_TIMEOUT_MS = 12000;

// Plugin info interface
interface PluginInfo {
  id: string;
  name: string;
  description: string;
  version: string;
  author: string;
  homepage: string;
}

// Source config for QuickJS init
interface SourceConfig {
  type: string;
  actions: string[];
  qualitys: string[];
}

interface InitCallResult {
  error?: string;
}

interface ScriptApiResponse {
  code: number;
  url?: string;
  msg?: string;
}

const QUICKJS_SETUP_KEY = 'lxmusic_harmony_key';

// QuickJS 状态
let isQuickJSInited = false;
let currentPluginId: string = '';

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

/**
 * 加载 native QuickJS 模块
 */
function loadNativeQuickJS(): boolean {
  hilog.info(DOMAIN, TAG, 'Loading native QuickJS module');

  // 直接调用 napi_quickjs 模块初始化
  // 静态导入的 native module 会在内部处理所有加载逻辑
  const result = initNativeQuickJS();
  hilog.info(DOMAIN, TAG, 'initNativeQuickJS result: %{public}s', result.toString());
  return result;
}

/**
 * 尝试初始化 native QuickJS
 */
function tryLoadNativeQuickJS(): boolean {
  hilog.info(DOMAIN, TAG, 'tryLoadNativeQuickJS called');

  // 尝试加载 native QuickJS
  const loaded = loadNativeQuickJS();
  if (loaded) {
    hilog.info(DOMAIN, TAG, 'Native QuickJS loaded successfully');
    return true;
  }

  hilog.warn(DOMAIN, TAG, 'Failed to load native QuickJS');
  return false;
}

/**
 * 初始化 QuickJS 引擎
 */
function initQuickJS(): boolean {
  if (isQuickJSInited) {
    return true;
  }

  hilog.info(DOMAIN, TAG, 'Initializing QuickJS engine');

  // 尝试加载 native QuickJS
  const nativeLoaded = tryLoadNativeQuickJS();

  if (!nativeLoaded) {
    hilog.error(DOMAIN, TAG, 'QuickJS native module unavailable');
    isQuickJSInited = false;
    return false;
  }

  hilog.info(DOMAIN, TAG, 'QuickJS initialized successfully');
  isQuickJSInited = true;
  return true;
}

/**
 * 使用 QuickJS 执行插件请求
 */
function quickjsRequest(source: string, action: string, info: QuickJSRequestInfo): QuickJSRequestResult {
  if (!isQuickJSInited) {
    return { url: '', lyric: '', list: [], total: 0 };
  }

  const requestData = JSON.stringify({
    source: source,
    action: action,
    info: info,
  });

  const result = callPluginAction('request', requestData);
  if (!result) {
    return { url: '', lyric: '', list: [], total: 0 };
  }

  try {
    return JSON.parse(result) as QuickJSRequestResult;
  } catch (e) {
    hilog.warn(DOMAIN, TAG, 'JSON.parse failed in quickjsRequest: %{public}s', (e as Error)?.message);
    return { url: '', lyric: '', list: [], total: 0 };
  }
}

/**
 * 解析插件信息
 */
function parsePluginInfo(scriptContent: string): PluginInfo | null {
  try {
    const infoMatch = scriptContent.match(/export\s+const\s+plugin\s*=\s*\{([^}]+)\}/s);
    if (!infoMatch) {
      return null;
    }

    const info: PluginInfo = {
      id: '',
      name: '',
      description: '',
      version: '',
      author: '',
      homepage: '',
    };

    const idMatch = scriptContent.match(/id:\s*['"]([^'"]+)['"]/);
    if (idMatch) {
      info.id = idMatch[1];
    }

    const nameMatch = scriptContent.match(/name:\s*['"]([^'"]+)['"]/);
    if (nameMatch) {
      info.name = nameMatch[1];
    }

    const descMatch = scriptContent.match(/description:\s*['"]([^'"]+)['"]/);
    if (descMatch) {
      info.description = descMatch[1];
    }

    const versionMatch = scriptContent.match(/version:\s*['"]([^'"]+)['"]/);
    if (versionMatch) {
      info.version = versionMatch[1];
    }

    const authorMatch = scriptContent.match(/author:\s*['"]([^'"]+)['"]/);
    if (authorMatch) {
      info.author = authorMatch[1];
    }

    const homepageMatch = scriptContent.match(/homepage:\s*['"]([^'"]+)['"]/);
    if (homepageMatch) {
      info.homepage = homepageMatch[1];
    }

    return info;
  } catch (e) {
    hilog.warn(DOMAIN, TAG, 'parsePluginInfo failed: %{public}s', (e as Error)?.message);
    return null;
  }
}

// All known action names supported by the plugin system
const ALL_KNOWN_ACTIONS: string[] = ['search', 'musicUrl', 'lyric', 'pic', 'songList', 'hotSearch', 'boards', 'boardList'];

function parseSupportedActions(scriptContent: string): Set<string> {
  const actions = new Set<string>();

  // Strategy 1: Match clear-text "actions: [...]" blocks (works for normal scripts)
  const actionBlockRegex = /actions\s*:\s*\[([^\]]*)\]/g;
  let match: RegExpExecArray | null = actionBlockRegex.exec(scriptContent);
  while (match) {
    const block = match[1];
    const actionRegex = /['"]([a-zA-Z][a-zA-Z0-9]*)['"]/g;
    let actionMatch: RegExpExecArray | null = actionRegex.exec(block);
    while (actionMatch) {
      actions.add(actionMatch[1]);
      actionMatch = actionRegex.exec(block);
    }
    match = actionBlockRegex.exec(scriptContent);
  }

  // Strategy 2: Match string literals that match known action names,
  //             catching obfuscated code where action names survive as data
  //             even when variable names are mangled (e.g., a:["search","musicUrl"])
  if (actions.size === 0) {
    for (let i = 0; i < ALL_KNOWN_ACTIONS.length; i++) {
      const action = ALL_KNOWN_ACTIONS[i];
      // Look for the action name as a string literal anywhere in the script
      const pattern = new RegExp('["\']' + action + '["\']', 'g');
      if (pattern.test(scriptContent)) {
        actions.add(action);
      }
    }
  }

  // Strategy 3: Fallback - if still nothing found (truly obfuscated),
  //             default to all known actions so QuickJS runtime gets to try them all.
  //             The native bridge will gracefully handle unsupported actions.
  if (actions.size === 0) {
    hilog.warn(DOMAIN, TAG, 'No actions detected in script - defaulting to all known actions for obfuscated plugins');
    for (let i = 0; i < ALL_KNOWN_ACTIONS.length; i++) {
      actions.add(ALL_KNOWN_ACTIONS[i]);
    }
  }

  return actions;
}

/**
 * 加载插件到 QuickJS
 */
function loadPluginToQuickJS(scriptContent: string, pluginInfo: PluginInfo, sources: SourceConfig[]): boolean {
  if (!isQuickJSInited) {
    return false;
  }

  try {
    hilog.info(DOMAIN, TAG, 'Loading plugin to QuickJS: %{public}s', pluginInfo.name);

    const entryScript = [
      'if (typeof globalThis.lx_setup === "function") {',
      `  globalThis.lx_setup(${JSON.stringify(QUICKJS_SETUP_KEY)}, ${JSON.stringify(pluginInfo.id)}, ${JSON.stringify(pluginInfo.name)}, ${JSON.stringify(pluginInfo.description)}, ${JSON.stringify(pluginInfo.version)}, ${JSON.stringify(pluginInfo.author)}, ${JSON.stringify(pluginInfo.homepage)}, ${JSON.stringify(scriptContent)});`,
      '}',
      scriptContent,
    ].join('\n');

    const loaded = loadPluginScript(entryScript);
    if (!loaded) {
      hilog.error(DOMAIN, TAG, 'Failed to load plugin script');
      return false;
    }

    const initResult = callPluginAction('init', JSON.stringify({
      id: pluginInfo.id,
      name: pluginInfo.name,
      sources: sources,
    }));
    // Current preload bridge does not implement explicit "init" action.
    // Many scripts initialize themselves via send(EVENT_NAMES.inited) at load time.
    if (initResult && initResult.length > 0 && initResult !== 'Unknown action: init') {
      hilog.info(DOMAIN, TAG, 'Plugin init result: %{public}s', initResult);
      try {
        const parsed = JSON.parse(initResult) as InitCallResult;
        if (parsed.error && parsed.error.length > 0) {
          hilog.error(DOMAIN, TAG, 'Plugin init failed: %{public}s', parsed.error);
          return false;
        }
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'Plugin init result parse failed: %{public}s', (e as Error)?.message);
        // ignore parse error, keep compatibility with non-JSON init responses
      }
    }

    currentPluginId = pluginInfo.id;
    hilog.info(DOMAIN, TAG, 'Plugin loaded to QuickJS successfully');
    return true;
  } catch (e) {
    hilog.error(DOMAIN, TAG, 'Failed to load plugin to QuickJS: %{public}s', formatErrorMessage(e as Object));
    return false;
  }
}

/**
 * 自定义源插件类
 */
export class CustomSourcePlugin implements Plugin {
  id: string;
  name: string;
  description: string;
  version: string;
  author: string;
  homepage: string;
  loaded: boolean = false;
  useQuickJS: boolean = false;
  useScriptApiFallback: boolean = false;
  fallbackApiUrl: string = '';
  fallbackApiKey: string = '';
  scriptContent: string = '';
  private supportedActions: Set<string>;

  constructor(id: string, name: string, description: string, version: string, author: string, homepage: string, scriptContent: string) {
    this.id = id;
    this.name = name;
    this.description = description;
    this.version = version;
    this.author = author;
    this.homepage = homepage;
    this.scriptContent = scriptContent;
    this.supportedActions = parseSupportedActions(scriptContent);
  }

  async onInit(): Promise<boolean> {
    hilog.info(DOMAIN, TAG, 'CustomSourcePlugin initializing: %{public}s', this.name);

    // 初始化 QuickJS
    this.useQuickJS = initQuickJS();
    if (!this.useQuickJS) {
      hilog.warn(DOMAIN, TAG, 'QuickJS unavailable, trying script-api fallback mode');
      const fallbackReady = this.initScriptApiFallback();
      this.loaded = fallbackReady;
      this.useScriptApiFallback = fallbackReady;
      return fallbackReady;
    }

    if (this.useQuickJS) {
      const preloadLoaded = await loadPreloadScript();
      hilog.info(DOMAIN, TAG, 'Preload script load result: %{public}s', preloadLoaded.toString());
      if (!preloadLoaded) {
        hilog.warn(DOMAIN, TAG, 'Failed to load preload script, QuickJS plugin may fail');
      }
      const loaded = loadPluginToQuickJS(this.scriptContent, {
        id: this.id,
        name: this.name,
        description: this.description || '',
        version: this.version || '',
        author: this.author || '',
        homepage: '',
      }, [{
        type: 'custom',
        actions: this.getInitActions(),
        qualitys: ['128k', '320k', 'flac'],
      }]);

      if (loaded) {
        // Keep API fallback as a backup path when QuickJS request returns empty.
        const fallbackReady = this.initScriptApiFallback();
        if (fallbackReady) {
          hilog.info(DOMAIN, TAG, 'Script-api fallback is ready as backup');
        }
        hilog.info(DOMAIN, TAG, 'CustomSourcePlugin initialized with QuickJS: %{public}s', this.name);
        this.loaded = true;
        this.useScriptApiFallback = false;
        return true;
      } else {
        hilog.warn(DOMAIN, TAG, 'QuickJS script load failed, trying script-api fallback mode');
        const fallbackReady = this.initScriptApiFallback();
        this.loaded = fallbackReady;
        this.useQuickJS = false;
        this.useScriptApiFallback = fallbackReady;
        return fallbackReady;
      }
    }

    return false;
  }

  async onSearch(keyword: string, page: number): Promise<PluginSearchResult> {
    if (!this.isActionSupported('search')) {
      return { list: [], total: 0, page };
    }
    if (!this.loaded || !this.useQuickJS) {
      return { list: [], total: 0, page };
    }

    try {
      const result = quickjsRequest('custom', 'search', { keyword, page });
      return {
        list: (result.list || []) as PluginSongInfo[],
        total: result.total || 0,
        page,
      };
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'onSearch failed: %{public}s', (e as Error)?.message);
      return { list: [], total: 0, page };
    }
  }

  async onGetMusicUrl(songInfo: PluginSongInfo, quality: string): Promise<string> {
    if (!this.isActionSupported('musicUrl')) {
      return '';
    }
    if (!this.loaded) {
      return '';
    }

    if (!this.useQuickJS && this.useScriptApiFallback) {
      return await this.getMusicUrlByScriptApi(songInfo, quality);
    }

    if (!this.useQuickJS) {
      return '';
    }

    const quickjsUrl = await this.requestMusicUrlFromScript(songInfo, quality);
    if (quickjsUrl.length > 0) {
      return quickjsUrl;
    }
    if (this.fallbackApiUrl.length > 0 && this.fallbackApiKey.length > 0) {
      hilog.warn(DOMAIN, TAG, 'QuickJS returned empty musicUrl, fallback to script-api');
      return await this.getMusicUrlByScriptApi(songInfo, quality);
    }
    return '';
  }

  /**
   * 让脚本自己取链。
   *
   * 必须走异步桥（invokePluginAction）：脚本内部要发 HTTP（POST /music/url 之类），
   * QuickJS 不会自己驱动 Promise，宿主得替它发请求并把响应喂回去，直到它 resolve。
   * 之前这里是同步 callJS，脚本的 Promise 永远 pending，所以「导入成功但播放没声」。
   */
  private async requestMusicUrlFromScript(songInfo: PluginSongInfo, quality: string): Promise<string> {
    try {
      const infoJson = JSON.stringify({
        type: quality,
        musicInfo: songInfo,
      });
      // source 必须传：源脚本按它决定去哪个平台取链，缺了会拼出 source=undefined
      const source = songInfo.source && songInfo.source.length > 0 ? songInfo.source : 'kw';
      const response = await invokePluginAction('musicUrl', source, infoJson, MUSIC_URL_TIMEOUT_MS);
      if (!response) {
        return '';
      }
      const data = response.data as QuickJSMusicUrlData | string | null;
      if (typeof data === 'string') {
        return data;
      }
      const url = data?.url ?? '';
      if (url.length === 0) {
        hilog.warn(DOMAIN, TAG, 'script returned empty musicUrl for %{public}s',
          songInfo.songmid ?? songInfo.hash ?? '');
      }
      return url;
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'requestMusicUrlFromScript failed: %{public}s', (e as Error)?.message);
      return '';
    }
  }

  async onGetLyric(songInfo: PluginSongInfo): Promise<PluginLyricInfo> {
    if (!this.isActionSupported('lyric')) {
      return { lyric: '' };
    }
    if (!this.loaded || !this.useQuickJS) {
      return { lyric: '' };
    }

    try {
      const infoJson = JSON.stringify({ musicInfo: songInfo });
      const source = songInfo.source && songInfo.source.length > 0 ? songInfo.source : 'kw';
      const response = await invokePluginAction('lyric', source, infoJson, LYRIC_TIMEOUT_MS);
      if (!response) {
        return { lyric: '' };
      }
      const data = response.data as PluginLyricInfo | null;
      if (!data) {
        return { lyric: '' };
      }
      return {
        lyric: data.lyric ?? '',
        tlyric: data.tlyric ?? '',
        lxlyric: data.lxlyric ?? '',
        rlyric: data.rlyric ?? '',
      };
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'onGetLyric failed: %{public}s', (e as Error)?.message);
      return { lyric: '' };
    }
  }

  async onGetPic(songInfo: PluginSongInfo): Promise<string> {
    if (!this.isActionSupported('pic')) {
      return '';
    }
    if (!this.loaded || !this.useQuickJS) {
      return '';
    }
    try {
      const infoJson = JSON.stringify({ musicInfo: songInfo });
      const source = songInfo.source && songInfo.source.length > 0 ? songInfo.source : 'kw';
      const response = await invokePluginAction('pic', source, infoJson, LYRIC_TIMEOUT_MS);
      if (!response) {
        return '';
      }
      if (typeof response.data === 'string') {
        return response.data;
      }
      return '';
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'onGetPic failed: %{public}s', (e as Error)?.message);
      return '';
    }
  }

  async onGetSongList(songListId: string, page: number): Promise<PluginSongListResult> {
    if (!this.isActionSupported('songList')) {
      return { list: [], total: 0, page, limit: 20 };
    }
    if (!this.loaded || !this.useQuickJS) {
      return { list: [], total: 0, page, limit: 20 };
    }

    try {
      const result = quickjsRequest('custom', 'songList', { mid: songListId });
      return {
        list: (result.list || []) as PluginSongInfo[],
        total: result.total || 0,
        page,
        limit: 20,
      };
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'onGetSongList failed: %{public}s', (e as Error)?.message);
      return { list: [], total: 0, page, limit: 20 };
    }
  }

  async onGetHotSearch(): Promise<PluginHotSearch[]> {
    if (!this.isActionSupported('hotSearch')) {
      return [];
    }
    if (!this.loaded || !this.useQuickJS) {
      return [];
    }

    try {
      const result = quickjsRequest('custom', 'hotSearch', {});
      return (result.list || []) as PluginHotSearch[];
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'onGetHotSearch failed: %{public}s', (e as Error)?.message);
      return [];
    }
  }

  async onGetBoards(): Promise<PluginBoard[]> {
    if (!this.isActionSupported('boards')) {
      return [];
    }
    if (!this.loaded || !this.useQuickJS) {
      return [];
    }
    try {
      const result = quickjsRequest('custom', 'boards', {});
      return (result.list || []) as PluginBoard[];
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'onGetBoards failed: %{public}s', (e as Error)?.message);
      return [];
    }
  }

  async onGetBoardList(boardId: string, page: number): Promise<PluginBoardDetail> {
    if (!this.isActionSupported('boardList')) {
      return { name: '', list: [], total: 0, page };
    }
    if (!this.loaded || !this.useQuickJS) {
      return { name: '', list: [], total: 0, page };
    }

    try {
      const result = quickjsRequest('custom', 'boardList', { boardId, page });
      return {
        name: boardId,
        list: (result.list || []) as PluginSongInfo[],
        total: result.total || 0,
        page,
      };
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'onGetBoardList failed: %{public}s', (e as Error)?.message);
      return { name: '', list: [], total: 0, page };
    }
  }

  async destroy(): Promise<void> {
    hilog.info(DOMAIN, TAG, 'CustomSourcePlugin destroying');

    if (this.useQuickJS) {
      destroyNativeQuickJS();
    }

    this.loaded = false;
    this.useQuickJS = false;
    this.useScriptApiFallback = false;
  }

  private initScriptApiFallback(): boolean {
    try {
      // Strategy 1: Clear-text patterns (API_URL / API_KEY variables)
      const apiUrlMatch = this.scriptContent.match(/API_URL\s*=\s*['"]([^'"]+)['"]/);
      const apiKeyMatch = this.scriptContent.match(/API_KEY\s*=\s*['"]([^'"]+)['"]/);

      let apiUrl = apiUrlMatch ? apiUrlMatch[1] : '';
      let apiKey = apiKeyMatch ? apiKeyMatch[1] : '';

      // Strategy 2: Broader patterns for minified/obfuscated code
      // Look for URL assignments with any variable name
      if (apiUrl.length === 0) {
        const urlAssign = this.scriptContent.match(/\w+\s*=\s*['"](https?:\/\/[^'"]+api[^'"]*)['"]/);
        if (urlAssign) apiUrl = urlAssign[1];
      }
      // Look for key assignments with any variable name
      if (apiKey.length === 0) {
        const keyAssign = this.scriptContent.match(/\w+\s*=\s*['"]([A-Za-z0-9_-]{16,})['"]/);
        if (keyAssign) apiKey = keyAssign[1];
      }

      // Strategy 3: Try to find URL+key pair even in deeply obfuscated code
      // by scanning ALL string literals and matching URL patterns
      if (apiUrl.length === 0) {
        const allUrls = this.scriptContent.match(/['"](https?:\/\/[^'"]+)['"]/g);
        if (allUrls && allUrls.length > 0) {
          // Pick the first URL that looks like an API endpoint
          for (let i = 0; i < allUrls.length; i++) {
            const u = allUrls[i].replace(/^['"]|['"]$/g, '');
            if (u.length < 200 && /\/api\/|\/url\/|\.com\/|\.cn\/|\.net\//.test(u)) {
              apiUrl = u;
              break;
            }
          }
        }
      }

      if (apiUrl.length === 0 || apiKey.length === 0) {
        hilog.warn(DOMAIN, TAG, 'Script-api fallback init: missing API_URL/API_KEY in script');
        return false;
      }

      this.fallbackApiUrl = apiUrl;
      this.fallbackApiKey = apiKey;
      hilog.info(DOMAIN, TAG, 'Script-api fallback enabled: %{public}s', this.fallbackApiUrl);
      return true;
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'Script-api fallback init failed: %{public}s', formatErrorMessage(e as Object));
      return false;
    }
  }

  /**
   * QuickJS 不可用时的降级取链：直接按源脚本自己的协议打它的 API。
   *
   * 之前这里请求的是 `${api}/url/{source}/{id}/{quality}` —— 这个端点是臆造的，
   * 源服务端根本没有，所以永远是 404/纯文本，日志里只剩一句
   * "Unexpected Number in JSON"（正文不是 JSON 时 JSON.parse 报的错），
   * 既拿不到地址又误导排查。现在改成与脚本完全一致的：
   *   POST {API_URL}/music/url  body={source,musicId,quality}  头带 X-Api-Key
   */
  private async getMusicUrlByScriptApi(songInfo: PluginSongInfo, quality: string): Promise<string> {
    try {
      const source = songInfo.source || 'kw';
      const songId = songInfo.hash || songInfo.songmid || '';
      if (songId.length === 0) {
        return '';
      }
      const requestUrl = `${this.fallbackApiUrl}/music/url`;
      const response = await httpRequest(requestUrl, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'User-Agent': 'lx-music-mobile/2.0.0',
          'X-Api-Key': this.fallbackApiKey,
        },
        extraData: JSON.stringify({ source: source, musicId: songId, quality: quality }),
        responseType: 'text',
        timeout: 15000,
      }).promise;

      const bodyText = response.rawText;
      if (!bodyText || bodyText.length === 0) {
        hilog.warn(DOMAIN, TAG, 'script-api returned empty body (status=%{public}d)', response.status);
        return '';
      }
      let body: ScriptApiResponse | null = null;
      try {
        body = JSON.parse(bodyText) as ScriptApiResponse;
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'script-api body is not JSON: %{public}s',
          bodyText.length > 200 ? bodyText.substring(0, 200) : bodyText);
        return '';
      }
      if (body && body.code === 200 && body.url && body.url.length > 0) {
        return body.url;
      }
      hilog.warn(DOMAIN, TAG, 'script-api returned no url: code=%{public}d msg=%{public}s',
        body?.code ?? -1, body?.msg ?? '');
      return '';
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'script-api request failed: %{public}s', formatErrorMessage(e as Object));
      return '';
    }
  }

  private isActionSupported(action: string): boolean {
    return this.supportedActions.has(action);
  }

  private getInitActions(): string[] {
    const orderedActions = ['search', 'musicUrl', 'lyric', 'pic', 'songList', 'hotSearch', 'boards', 'boardList'];
    const actions: string[] = [];
    for (const action of orderedActions) {
      if (this.supportedActions.has(action)) {
        actions.push(action);
      }
    }
    if (actions.length === 0) {
      actions.push('musicUrl');
    }
    return actions;
  }
}

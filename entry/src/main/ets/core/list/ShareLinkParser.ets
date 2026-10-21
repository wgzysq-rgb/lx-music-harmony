/**
 * 各音乐平台「分享歌单」链接解析
 *
 * 用户从网易云 / QQ 音乐 / 酷我 / 酷狗 App 里「分享 → 复制链接」拿到的通常是
 * **一整段文案**（含 emoji、书名号、【】、分享语），例如：
 *
 *   分享单曲、歌单、电台：《歌名》http://music.163.com/playlist/111111111/…
 *   【歌单】某某歌单标题 https://y.qq.com/n/ryqq/playlist/2222222222
 *
 * 所以这里做两件事：先把 URL 从文案里捞出来，再按 host 分派到平台正则。
 *
 * 只输出**纯数字 id**：各源 `getListDetail` 对 id 的接受度不一致 ——
 *   wy / kg 已支持直接传整条 URL（内部会再提取一次），
 *   kw       只认 `ku_123` 或纯数字，传 URL 会被原样拼进接口地址直接失败；
 *   tx       只认纯数字，传 URL 后 `disstid=<整条链接>` 同样失败。
 * 统一产出纯 id 是唯一让四个源都能打开的形式。
 *
 * 短链（t1.kugou.com、163cn.tv、c6.y.qq.com/base/fcgi-bin/u?__= 等）需要先跟随
 * 一次跳转才能拿到真实地址，见文件末尾的 resolveShortLink。
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { httpRequest } from '../network/http';

const DOMAIN = 0x0001;
const TAG = 'ShareLinkParser';

/** 解析结果：平台标识 + 歌单 id */
export interface ShareLinkTarget {
  source: string;
  id: string;
}

/** 失败原因。空串表示成功；给 UI 层按 key 取本地化文案 */
export enum ShareLinkError {
  NONE = '',
  /** 整段文本里没有 URL */
  NO_URL = 'no_url',
  /** 是短链：需要跟随一次跳转，由 resolveShortLink 处理；解析失败也归这里 */
  SHORT_LINK = 'short_link',
  /** 认不出是哪个平台 */
  UNKNOWN_PLATFORM = 'unknown_platform',
  /** 认出了平台但没提到歌单 id（可能是单曲/专辑/歌手链接） */
  NO_ID = 'no_id',
}

export interface ShareLinkParseResult {
  target: ShareLinkTarget | null;
  error: ShareLinkError;
  /**
   * 识别为短链时带回原始短链，供 resolveShortLink 跟随跳转。
   * 非短链场景为空串。
   */
  shortUrl: string;
}

/** 短链跳转解析结果 */
export interface ShortLinkResolveResult {
  target: ShareLinkTarget | null;
  error: ShareLinkError;
}

/** 从分享文案里捞出第一个 http(s) URL（排除中文标点与引号，避免把「。」粘进去） */
const URL_PATTERN: RegExp = /https?:\/\/[^\s"'<>，。、；：！？）】》」]+/i;

/** 只看 host 用 */
const HOST_PATTERN: RegExp = /^https?:\/\/([^/?#]+)/i;

/** 短链域名：需要跟随跳转才有真实地址，本轮不支持 */
const SHORT_LINK_HOSTS: string[] = ['163cn.tv', 'url.cn', 't1.kugou.com', 't2.kugou.com'];

/**
 * 从一段文本里取出 URL。
 * 分享文案末尾常带全角标点，正则已经排除，这里再兜底去掉结尾的英文标点。
 */
function extractUrl(text: string): string {
  const match: RegExpMatchArray | null = text.match(URL_PATTERN);
  if (!match) {
    return '';
  }
  let url: string = match[0];
  // 结尾可能粘上英文句点/逗号/右括号
  while (url.length > 0) {
    const last: string = url.charAt(url.length - 1);
    if (last === '.' || last === ',' || last === ')' || last === ';' || last === ']') {
      url = url.substring(0, url.length - 1);
    } else {
      break;
    }
  }
  return url;
}

function isShortLinkHost(host: string): boolean {
  for (let i = 0; i < SHORT_LINK_HOSTS.length; i++) {
    if (host === SHORT_LINK_HOSTS[i] || host.endsWith('.' + SHORT_LINK_HOSTS[i])) {
      return true;
    }
  }
  return false;
}

/**
 * QQ 的短链：`c6.y.qq.com/base/fcgi-bin/u?__=SVZRedQWqBAQ`。
 *
 * 它和正常 QQ 歌单链接同属 qq.com 域，只能靠路径 `/base/fcgi-bin/u`
 * 或 `__=` 参数区分。不先拦下来会走到「认出平台但没有歌单 id」，
 * 提示成「这条链接里没有歌单」，把用户引到错误方向。
 */
function isQqShortLink(url: string, host: string): boolean {
  if (!host.endsWith('qq.com')) {
    return false;
  }
  return /\/base\/fcgi-bin\/u/i.test(url) || /[?&]__=/.test(url);
}

/** 按 host 判断平台标识，认不出返回空串 */
function sourceFromHost(host: string): string {
  if (host.endsWith('music.163.com')) {
    return 'wy';
  }
  if (host.endsWith('qq.com')) {
    return 'tx';
  }
  if (host.endsWith('kuwo.cn')) {
    return 'kw';
  }
  if (host.endsWith('kugou.com')) {
    return 'kg';
  }
  return '';
}

function hostOf(url: string): string {
  const match: RegExpMatchArray | null = url.match(HOST_PATTERN);
  return match ? match[1].toLowerCase() : '';
}

/**
 * 网易云：/playlist/123、/playlist?id=123、/#/playlist?id=123
 *
 * 不能留裸的 `?id=` 兜底：`music.163.com/song?id=xxx`（单曲）、
 * `/album?id=`、`/artist?id=` 都会被误判成歌单，然后拿单曲 id 去请歌单接口，
 * 结果是「导入成功但打开是空歌单」。所以只认路径里带 playlist 的形态。
 */
function parseWyId(url: string): string {
  const patterns: RegExp[] = [
    /\/playlist\/(\d+)/i,
    /\/playlist[^#]*[?&]id=(\d+)/i,
  ];
  return firstGroup(url, patterns);
}

/**
 * QQ 音乐：/playlist/123、taoge.html?id=123、disstid=123
 *
 * 同理不给裸 `?id=` 兜底：单曲是 /songDetail/<mid>，但历史上也出现过
 * `songDetail.html?id=` 的形态，兜底会把单曲 id 误当歌单 id。
 */
function parseTxId(url: string): string {
  const patterns: RegExp[] = [
    /\/playlist\/(\d+)/i,
    /taoge[^#]*[?&]id=(\d+)/i,
    /[?&]disstid=(\d+)/i,
  ];
  return firstGroup(url, patterns);
}

/** 酷我：/playlist_detail/123、?pid=123、/h5app/playlist/123 */
function parseKwId(url: string): string {
  const patterns: RegExp[] = [
    /playlist_detail\/(\d+)/i,
    /[?&]pid=(\d+)/i,
    /\/h5app\/playlist\/(\d+)/i,
    /\/playlist\/(\d+)/i,
  ];
  return firstGroup(url, patterns);
}

/** 酷狗：/special/single/123(-5-9999).html、/plist/list/123、/songlist/123.html */
function parseKgId(url: string): string {
  const patterns: RegExp[] = [
    /special\/single\/(\d+)/i,
    /plist\/list\/(\d+)/i,
    /songlist\/(\d+)/i,
    /[?&]specialid=(\d+)/i,
  ];
  return firstGroup(url, patterns);
}

function firstGroup(url: string, patterns: RegExp[]): string {
  for (let i = 0; i < patterns.length; i++) {
    const match: RegExpMatchArray | null = url.match(patterns[i]);
    if (match && match[1]) {
      return match[1];
    }
  }
  return '';
}

/**
 * 解析用户粘贴的分享内容。
 *
 * @param raw 整段分享文本，或纯链接
 */
export function parseShareLink(raw: string): ShareLinkParseResult {
  const text: string = (raw ?? '').trim();
  const none: ShareLinkTarget | null = null;
  if (text.length === 0) {
    return { target: none, error: ShareLinkError.NO_URL, shortUrl: '' };
  }

  const url: string = extractUrl(text);
  if (url.length === 0) {
    return { target: none, error: ShareLinkError.NO_URL, shortUrl: '' };
  }

  const hostMatch: RegExpMatchArray | null = url.match(HOST_PATTERN);
  const host: string = hostMatch ? hostMatch[1].toLowerCase() : '';

  if (isShortLinkHost(host) || isQqShortLink(url, host)) {
    return { target: none, error: ShareLinkError.SHORT_LINK, shortUrl: url };
  }

  const source: string = sourceFromHost(host);
  if (source.length === 0) {
    return { target: none, error: ShareLinkError.UNKNOWN_PLATFORM, shortUrl: '' };
  }

  let id: string = '';
  if (source === 'wy') {
    id = parseWyId(url);
  } else if (source === 'tx') {
    id = parseTxId(url);
  } else if (source === 'kw') {
    id = parseKwId(url);
  } else {
    id = parseKgId(url);
  }

  if (id.length === 0) {
    // 认出了平台但没提到歌单 id：多半贴的是单曲/专辑/歌手链接
    return { target: none, error: ShareLinkError.NO_ID, shortUrl: '' };
  }

  const target: ShareLinkTarget = { source, id };
  return { target, error: ShareLinkError.NONE, shortUrl: '' };
}

/** 302 的 Location 里形如 `...&id=1234567890&...` / `?disstid=` */
const REDIRECT_ID_PATTERNS: RegExp[] = [
  /[?&]disstid=(\d+)/i,
  /[?&]id=(\d+)/i,
  /\/playlist\/(\d+)/i,
];

function extractIdFromUrl(url: string): string {
  return firstGroup(url, REDIRECT_ID_PATTERNS);
}

/**
 * 跟随短链跳转，解析出真实歌单。
 *
 * QQ 的 `c6.y.qq.com/base/fcgi-bin/u?__=xxx` 是 302 到
 * `i2.y.qq.com/n3/other/pages/details/playlist.html?...&id=1234567890`，
 * 歌单 id 就在 Location 里。这里对两种运行时行为都做兼容：
 *
 *   - 系统 http 不跟随跳转：能直接读到 `location` 头，解析它；
 *   - 系统 http 自动跟随：拿到的是 200 + SPA 空壳 HTML，此时退而在
 *     正文里搜 `id=`，仍拿不到就明确报错（不会静默成功）。
 *
 * 只跟一跳：QQ 第二跳是同一个页面换了 host，id 已经在第一跳里了。
 */
export async function resolveShortLink(shortUrl: string): Promise<ShortLinkResolveResult> {
  const none: ShareLinkTarget | null = null;
  if (shortUrl.length === 0) {
    return { target: none, error: ShareLinkError.NO_URL };
  }

  let location: string = '';
  let bodyText: string = '';
  try {
    const response = await httpRequest(shortUrl, {
      method: 'GET',
      responseType: 'text',
      timeout: 15000,
    }).promise;
    // header 键在不同实现里大小写不一致，两种都试
    const headers: Record<string, string> = response.headers;
    const rawLocation: string | undefined = headers['location'] ?? headers['Location'];
    location = rawLocation ?? '';
    bodyText = response.rawText;
    hilog.info(DOMAIN, TAG, 'resolveShortLink status=%{public}d location=%{public}s',
      response.status, location.length > 0 ? location : '(none)');
  } catch (e) {
    hilog.warn(DOMAIN, TAG, 'resolveShortLink failed: %{public}s', (e as Error)?.message);
    return { target: none, error: ShareLinkError.SHORT_LINK };
  }

  // 1) 优先看 Location
  if (location.length > 0) {
    const fromLocation: ShortLinkResolveResult = buildFromResolved(location);
    if (fromLocation.target) {
      return fromLocation;
    }
  }

  // 2) 已跟随跳转（或 Location 里没有 id）时，在正文里再找一次
  if (bodyText.length > 0) {
    // 正文可能是一整页 HTML，按原短链的平台兜底（跳转丢了平台信息时仍能对上）
    const fallbackSource: string = sourceFromHost(hostOf(shortUrl));
    const id: string = extractIdFromUrl(bodyText);
    if (id.length > 0 && fallbackSource.length > 0) {
      const target: ShareLinkTarget = { source: fallbackSource, id };
      return { target, error: ShareLinkError.NONE };
    }
  }

  return { target: none, error: ShareLinkError.SHORT_LINK };
}

/**
 * 从跳转目标里解析平台与 id。
 *
 * 跳转目标形如 `i2.y.qq.com/n3/other/pages/details/playlist.html?...&id=1234567890`，
 * 注意路径是 `playlist.html` 而不是 `/playlist/123`，所以不能直接套 parseShareLink
 * 的平台正则，只能用 extractIdFromUrl 的通用 `?id=` 规则。
 */
function buildFromResolved(resolvedUrl: string): ShortLinkResolveResult {
  const none: ShareLinkTarget | null = null;
  const host: string = hostOf(resolvedUrl);
  const source: string = sourceFromHost(host);
  if (source.length === 0) {
    return { target: none, error: ShareLinkError.SHORT_LINK };
  }
  const id: string = extractIdFromUrl(resolvedUrl);
  if (id.length === 0) {
    return { target: none, error: ShareLinkError.SHORT_LINK };
  }
  hilog.info(DOMAIN, TAG, 'short link resolved: source=%{public}s id=%{public}s', source, id);
  const target: ShareLinkTarget = { source, id };
  return { target, error: ShareLinkError.NONE };
}

/**
 * 网易云音乐 - 歌曲搜索
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { httpRequest, parseHttpBodyJson } from '../../../../core/network/http';
import { decodeName, formatPlayTime, normalizeCoverUrl } from '../../../../utils/CommonUtils';
import { BaseMusicSource } from '../BaseMusicSource';
import type { MusicInfo, SearchResult, Quality, QualityDetail, MusicQualityType } from '../../../../types/MusicTypes';
import { neteaseWeapi, buildWeapiFormBody, type WeapiJsonObject } from './NeteaseCrypto';

const TAG = 'WYMUSIC';
const DOMAIN = 0x0001;
const LIMIT = 30;

// 网易云歌手信息
interface WYArtistInfo {
  name: string;
}

// 网易云专辑信息
interface WYAlbumInfo {
  name: string;
  picUrl: string;
  id: number;
}

// 网易云音乐项
interface WYMusicItem {
  id: number;
  name: string;
  ar: WYArtistInfo[];
  al: WYAlbumInfo;
  dt: number;
  alias: string[];
}

// 网易云搜索响应数据
interface WYSearchResultData {
  songs?: WYMusicItem[];
  songCount?: number;
}

// 网易云搜索响应
interface WYSearchResponse {
  code: number;
  result?: WYSearchResultData;
}

// 音乐搜索接口
export interface MusicSearchInterface {
  search: (keyword: string, page: number, limit: number) => Promise<SearchResult>;
  /** 明文 cloudsearch（首选）。null 表示失败需降级 */
  searchByCloudSearchApi: (keyword: string, page: number, limit: number) => Promise<SearchResult | null>;
  searchByLegacyApi: (keyword: string, page: number, limit: number) => Promise<SearchResult>;
}

// 构建空搜索结果
// 使用 BaseMusicSource.buildEmptySearchResult('wy')

/**
 * 格式化时长
 */
// 使用 CommonUtils.formatPlayTime(Math.floor(dt / 1000))

/**
 * 构建歌曲信息
 */
function buildMusicInfo(rawData: WYMusicItem): MusicInfo {
  const types: MusicQualityType[] = [];
  const _types: Map<Quality, QualityDetail> = new Map();
  const typeUrl: Map<string, string> = new Map();

  const picUrl: string = normalizeCoverUrl(rawData.al.picUrl || '');

  const musicInfo: MusicInfo = {
    name: decodeName(rawData.name),
    singer: decodeName(rawData.ar.map((a: WYArtistInfo): string => a.name).join('、')),
    source: 'wy',
    songmid: rawData.id.toString(),
    albumId: rawData.al.id.toString(),
    albumName: decodeName(rawData.al.name),
    interval: formatPlayTime(Math.floor(rawData.dt / 1000)),
    img: picUrl,
    lrc: null,
    otherSource: null,
    types,
    _types,
    typeUrl,
  };
  return musicInfo;
}

/**
 * 把网易云搜索响应的歌曲列表统一转换成搜索结果
 * （新老两个接口的响应结构一致，收尾逻辑收敛到这一处）
 */
function buildSearchResultFromBody(body: WYSearchResponse, keyword: string, limit: number): SearchResult {
  if (body.code !== 200) {
    hilog.warn(DOMAIN, TAG, 'wy search 返回异常 code: %{public}d, keyword: %{public}s', body.code, keyword);
    return BaseMusicSource.buildEmptySearchResult('wy');
  }
  const rawData: WYMusicItem[] = body.result?.songs || [];
  // 这条日志别删：code=200 但 songs 为空时原来完全无输出，
  // 上层只会表现成「wy 搜不到 → 回退全源聚合 → 显示的全是别家的歌」，
  // 排查时看不出是接口返回空还是解析失败。
  hilog.info(DOMAIN, TAG, 'wy search ok keyword=%{public}s songs=%{public}d songCount=%{public}d',
    keyword, rawData.length, body.result?.songCount || 0);
  const list: MusicInfo[] = [];
  for (const item of rawData) {
    list.push(buildMusicInfo(item));
  }
  const total: number = body.result?.songCount || 0;
  return {
    list,
    allPage: Math.ceil(total / limit),
    total,
    limit,
    source: 'wy',
  };
}

/**
 * 明文 cloudsearch 接口（首选）。
 * 返回 null 表示「请求/解析失败，应该降级」；返回结果对象表示「拿到了应答」
 * （即使 list 为空，也说明该关键词确实没有结果，不应再降级重试）。
 */
async function searchByCloudSearchApi(
  keyword: string, page: number, limit: number
): Promise<SearchResult | null> {
  try {
    const offset = limit * (page - 1);
    const url = `https://music.163.com/api/cloudsearch/pc?s=${encodeURIComponent(keyword)}` +
      `&offset=${offset}&limit=${limit}&type=1`;
    const headers: Map<string, string> = new Map();
    headers.set('Referer', 'https://music.163.com/');
    headers.set('Origin', 'https://music.163.com');
    headers.set('User-Agent', 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/110.0.0.0 Safari/537.36');
    const response = await httpRequest(url, { header: headers, responseType: 'text' }).promise;
    const resultData: string | Object | ArrayBuffer = response.result as string | Object | ArrayBuffer;
    const body = parseHttpBodyJson<WYSearchResponse>(resultData);
    if (!body || body.code !== 200) {
      hilog.warn(DOMAIN, TAG, 'wy cloudsearch 不可用 status=%{public}d code=%{public}d',
        response.status, body ? body.code : -1);
      return null;
    }
    return buildSearchResultFromBody(body, keyword, limit);
  } catch (e) {
    hilog.warn(DOMAIN, TAG, 'wy cloudsearch failed: %{public}s', (e as Error)?.message);
    return null;
  }
}

async function searchByLegacyApi(
  keyword: string, page: number, limit: number
): Promise<SearchResult> {
  try {
    const url = `https://music.163.com/api/search/pc?s=${encodeURIComponent(keyword)}&offset=${(page - 1) * limit}&limit=${limit}&type=1`;
    const headers: Map<string, string> = new Map();
    headers.set('Referer', 'https://music.163.com/');
    headers.set('User-Agent', 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/110.0.0.0 Safari/537.36');
    const response = await httpRequest(url, { header: headers, responseType: 'text' }).promise;
    const resultData: string | Object | ArrayBuffer = response.result as string | Object | ArrayBuffer;
    const body = parseHttpBodyJson<WYSearchResponse>(resultData);
    if (!body) {
      return BaseMusicSource.buildEmptySearchResult('wy');
    }
    return buildSearchResultFromBody(body, keyword, limit);
  } catch (e) {
    hilog.warn(DOMAIN, TAG, 'wy searchByLegacyApi failed: %{public}s', (e as Error)?.message);
    return BaseMusicSource.buildEmptySearchResult('wy');
  }
}

export const musicSearch: MusicSearchInterface = {
  /**
   * 搜索歌曲。
   *
   * 三级降级（顺序是按「实测可用性」排的，不是按接口新旧）：
   *   1. /api/cloudsearch/pc —— 明文 GET，实测稳定，返回结构与 weapi 完全一致
   *   2. /weapi/cloudsearch/get/web —— 加密 POST。实测在多环境下返回空 body
   *      （HTTP 200 但正文为空），解析必然失败，所以不能当首选
   *   3. /api/search/pc —— 老接口，常返回 code=-462（需要登录态）
   *
   * 之前只有 2 和 3，两个都失败时静默返回空列表，上层 SearchRunner 会
   * 回退到「全源聚合」，于是用户选了网易云却看到一堆酷我的结果
   * ——「切了源还是搜不到原唱」的真正原因。
   */
  async search(keyword: string, page: number = 1, limit: number = LIMIT): Promise<SearchResult> {
    const byPlain: SearchResult | null = await searchByCloudSearchApi(keyword, page, limit);
    if (byPlain) {
      return byPlain;
    }

    try {
      const url = 'https://music.163.com/weapi/cloudsearch/get/web';
      const payload: WeapiJsonObject = {};
      payload['s'] = keyword;
      payload['type'] = 1;
      payload['limit'] = limit;
      payload['total'] = page === 1;
      payload['offset'] = limit * (page - 1);
      const form = await neteaseWeapi(payload);
      const bodyText = buildWeapiFormBody(form);
      const headers: Map<string, string> = new Map();
      headers.set('Content-Type', 'application/x-www-form-urlencoded');
      headers.set('Referer', 'https://music.163.com/');
      headers.set('Origin', 'https://music.163.com');
      headers.set('User-Agent', 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/110.0.0.0 Safari/537.36');

      const response = await httpRequest(url, {
        method: 'POST',
        header: headers,
        extraData: bodyText,
        responseType: 'text',
      }).promise;
      const resultData: string | Object | ArrayBuffer = response.result as string | Object | ArrayBuffer;
      const body = parseHttpBodyJson<WYSearchResponse>(resultData);
      if (!body) {
        hilog.warn(DOMAIN, TAG, 'wy search(weapi) body 解析失败 status=%{public}d raw=%{public}s',
          response.status,
          response.rawText.length > 200 ? response.rawText.substring(0, 200) : response.rawText);
        return await searchByLegacyApi(keyword, page, limit);
      }
      return buildSearchResultFromBody(body, keyword, limit);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'wy search(weapi) failed, falling back to legacy: %{public}s',
        (e as Error)?.message);
      return await searchByLegacyApi(keyword, page, limit);
    }
  },

  searchByCloudSearchApi,
  searchByLegacyApi,
};

export default musicSearch;

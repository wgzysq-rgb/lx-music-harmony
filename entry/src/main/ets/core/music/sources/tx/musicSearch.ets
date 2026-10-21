/**
 * QQ音乐 - 歌曲搜索
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { httpRequest, parseHttpBodyJson } from '../../../../core/network/http';
import { decodeName, formatPlayTime, normalizeCoverUrl } from '../../../../utils/CommonUtils';
import { BaseMusicSource } from '../BaseMusicSource';
import type { MusicInfo, SearchResult, Quality, QualityDetail, MusicQualityType } from '../../../../types/MusicTypes';

const TAG = 'TXMUSIC';
const DOMAIN = 0x0001;
const LIMIT = 30;

// QQ音乐歌手信息
interface TXSingerInfo {
  name: string;
}

// QQ音乐专辑信息
interface TXAlbumInfo {
  name: string;
  mid: string;
}

// QQ音乐文件信息（音质/媒体 mid 都在这里）
interface TXFileInfo {
  media_mid?: string;
}

// QQ音乐项
interface TXMusicItem {
  /** 歌曲 mid（QQ 返回的字段名就是 mid，不是 songmid） */
  mid: string;
  name: string;
  singer: TXSingerInfo[];
  album: TXAlbumInfo;
  interval: number;
  /** 数字歌曲 id（QQ 返回的字段名就是 id，不是 songId） */
  id: number;
  file?: TXFileInfo;
}

// QQ音乐搜索响应数据
interface TXSearchSongData {
  list?: TXMusicItem[];
}

/**
 * QQ 的 musicu.fcg 响应是三层包裹：
 *   { code, req: { code, data: { body: { song: { list } } } } }
 *
 * 之前这里按 { code, data: { song } } 解析 —— 少了两层，导致
 * `body.data?.song` 永远 undefined、搜索结果恒为空列表，
 * 上层再回退「全源聚合」，表现成「切到 QQ 音乐搜不到，全是别家的歌」。
 * body.song 里也没有总数（meta 为空），总数用列表长度代替。
 */
interface TXSearchBody {
  song?: TXSearchSongData;
}

interface TXSearchResponseData {
  body?: TXSearchBody;
  /** 兼容某些扁平返回 */
  song?: TXSearchSongData;
}

interface TXSearchReq {
  code?: number;
  data?: TXSearchResponseData;
}

interface TXSearchResponse {
  code: number;
  req?: TXSearchReq;
  /** 兼容某些扁平返回 */
  data?: TXSearchResponseData;
}

// 音乐搜索接口
export interface MusicSearchInterface {
  search: (keyword: string, page: number, limit: number) => Promise<SearchResult>;
}

// 构建空搜索结果
// 使用 BaseMusicSource.buildEmptySearchResult

/**
 * 格式化时长
 */
// 使用 CommonUtils.formatPlayTime

/**
 * 构建歌曲信息
 */
function buildMusicInfo(rawData: TXMusicItem): MusicInfo {
  const types: MusicQualityType[] = [];
  const _types: Map<Quality, QualityDetail> = new Map();
  const typeUrl: Map<string, string> = new Map();

  const img: string = normalizeCoverUrl(`https://y.gtimg.cn/music/photo_new/T002R500x500M000${rawData.album.mid}.jpg`);

  const musicInfo: MusicInfo = {
    name: decodeName(rawData.name),
    singer: decodeName(rawData.singer.map((s: TXSingerInfo): string => s.name).join('、')),
    source: 'tx',
    songmid: rawData.mid,
    // 取链要用 file.media_mid（通常与 mid 相同，但存在不一致的曲目）
    strMediaMid: rawData.file?.media_mid ?? rawData.mid,
    songId: rawData.id,
    albumId: rawData.album.mid,
    albumName: decodeName(rawData.album.name),
    interval: formatPlayTime(rawData.interval),
    img,
    lrc: null,
    otherSource: null,
    types,
    _types,
    typeUrl,
  };
  return musicInfo;
}

export const musicSearch: MusicSearchInterface = {
  /**
   * 搜索歌曲
   */
  search(keyword: string, page: number = 1, limit: number = LIMIT): Promise<SearchResult> {
    const url: string = 'https://u.y.qq.com/cgi-bin/musicu.fcg?data=%7B%22req%22%3A%7B%22method%22%3A%22DoSearchForQQMusicDesktop%22%2C%22module%22%3A%22music.search.SearchCgiService%22%2C%22param%22%3A%7B%22num_per_page%22%3A' + limit + '%2C%22page_num%22%3A' + page + '%2C%22query%22%3A%22' + encodeURIComponent(keyword) + '%22%2C%22search_type%22%3A0%7D%7D%7D';

    const headers: Map<string, string> = new Map();
    headers.set('Referer', 'https://y.qq.com/');
    headers.set('User-Agent', 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/110.0.0.0 Safari/537.36');

    // 强制按文本收：让 parseHttpBodyJson 自己处理 BOM/杂质，
    // 避免 http 层解析失败时被下面的 catch 静默吞成空列表
    return httpRequest(url, { header: headers, responseType: 'text' }).promise.then((response) => {
      const resultData: string | Object | ArrayBuffer = response.result as string | Object | ArrayBuffer;
      const body = parseHttpBodyJson<TXSearchResponse>(resultData);

      if (!body || body.code !== 0) {
        hilog.warn(DOMAIN, TAG, 'tx search 响应异常 status=%{public}d code=%{public}d keyword=%{public}s',
          response.status, body ? body.code : -1, keyword);
        return BaseMusicSource.buildEmptySearchResult('tx');
      }

      // 正常路径 req.data.body.song；扁平返回时退回 data.song
      const root: TXSearchResponseData | undefined = body.req?.data ?? body.data;
      const songData: TXSearchSongData | undefined = root?.body?.song ?? root?.song;
      const rawData: TXMusicItem[] = songData?.list || [];
      hilog.info(DOMAIN, TAG, 'tx search ok keyword=%{public}s songs=%{public}d',
        keyword, rawData.length);
      const list: MusicInfo[] = [];
      for (const item of rawData) {
        list.push(buildMusicInfo(item));
      }
      // QQ 这个接口不返回总数（body.meta 为空），用本页条数代替
      const total: number = list.length;
      const allPage: number = total > 0 ? 1 : 0;

      const result: SearchResult = {
        list,
        allPage,
        total,
        limit,
        source: 'tx',
      };
      return result;
    }).catch((e: Error) => {
      hilog.warn(DOMAIN, TAG, 'tx search failed: %{public}s', e?.message);
      return BaseMusicSource.buildEmptySearchResult('tx');
    });
  },
};

export default musicSearch;

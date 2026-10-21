/**
 * 启动后异步检查远端版本信息，与 RN 端 src/core/version.ts 行为对齐（仅拉取并广播，不弹窗）。
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { bundleManager } from '@kit.AbilityKit';
import { stateEvent, type VersionInfo } from '../event/StateEvent';
import { fetchUtf8Text } from './HttpRepository';

const TAG = 'VersionCheck';
const DOMAIN = 0x0006;

const PRIMARY_VERSION_URL =
  'https://raw.githubusercontent.com/lyswhut/lx-music-mobile/master/publish/version.json';
const VERSION_CHECK_DEFER_MS = 9000;

function parseVersionPayload(text: string): VersionInfo | null {
  try {
    const trimmed = text.trim();
    if (trimmed.length === 0) {
      return null;
    }
    const root = JSON.parse(trimmed) as Record<string, string | number | Object | undefined>;
    const rawVer = root['version'];
    const versionStr = typeof rawVer === 'number' ? String(rawVer) : rawVer;
    if (typeof versionStr !== 'string' || versionStr.length === 0) {
      return null;
    }
    const desc = root['desc'];
    const descStr = typeof desc === 'string' ? desc : '';
    const info: VersionInfo = {
      version: versionStr,
      desc: descStr,
      publishTime: '',
    };
    return info;
  } catch (e) {
    hilog.warn(DOMAIN, TAG, 'parseVersionPayload failed: %{public}s', (e as Error)?.message);
    return null;
  }
}

async function fetchAndEmitVersionInfo(): Promise<VersionInfo | null> {
  try {
    const body = await fetchUtf8Text(PRIMARY_VERSION_URL);
    if (body.length === 0) {
      hilog.warn(DOMAIN, TAG, 'Version check empty response');
      return null;
    }
    const info = parseVersionPayload(body);
    if (info) {
      lastCheckedInfo = info;
      stateEvent.versionInfoUpdated(info);
      hilog.info(DOMAIN, TAG, 'Remote version: %{public}s', info.version);
      return info;
    }
    hilog.warn(DOMAIN, TAG, 'Version check unparsable or no top-level version (len=%{public}d)', body.length);
    return null;
  } catch (e) {
    hilog.warn(DOMAIN, TAG, 'Version check failed: %{public}s', JSON.stringify(e));
    return null;
  }
}

/**
 * 当前应用版本。
 *
 * 直接读安装包的 versionName（AppScope/app.json5 是唯一来源）。
 * 以前这里写死 '1.0.0'，改版本号时容易忘了同步，关于页显示的版本
 * 和实际安装的包对不上 —— 排查「到底测的是哪个包」时就很难受。
 * 读不到时退回 '0.0.0'（不阻塞界面，只是版本比较会偏保守）。
 */
function readAppVersion(): string {
  try {
    const info = bundleManager.getBundleInfoForSelfSync(
      bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
    const name: string = info.versionName;
    return name && name.length > 0 ? name : '0.0.0';
  } catch (err) {
    hilog.warn(DOMAIN, TAG, 'read versionName failed: %{public}s', JSON.stringify(err));
    return '0.0.0';
  }
}

export const APP_VERSION: string = readAppVersion();

/**
 * 版本号比较：a > b 返回正数，相等返回 0，a < b 返回负数
 * 兼容 '1.2.3' / 'v1.2.3' / '1.2.3-beta.1' 这类写法
 */
export function compareVersion(a: string, b: string): number {
  const normalize = (v: string): number[] => {
    const core = v.replace(/^v/i, '').split('-')[0];
    return core.split('.').map((part: string) => {
      const n = parseInt(part, 10);
      return isNaN(n) ? 0 : n;
    });
  };
  const left = normalize(a);
  const right = normalize(b);
  const length = Math.max(left.length, right.length);
  for (let i = 0; i < length; i++) {
    const l = i < left.length ? left[i] : 0;
    const r = i < right.length ? right[i] : 0;
    if (l !== r) {
      return l - r;
    }
  }
  return 0;
}

/** 立即检查一次（设置页「检查更新」用），返回远端版本信息 */
export async function checkVersionNow(): Promise<VersionInfo | null> {
  return await fetchAndEmitVersionInfo();
}

/** 上次检查缓存的远端版本（供页面进入时直接展示） */
let lastCheckedInfo: VersionInfo | null = null;

export function getLastVersionInfo(): VersionInfo | null {
  return lastCheckedInfo;
}

/** 延后执行，避免与冷启动存储/首屏抢占网络。 */
export function runVersionCheckDeferred(): void {
  setTimeout(() => {
    void fetchAndEmitVersionInfo();
  }, VERSION_CHECK_DEFER_MS);
}

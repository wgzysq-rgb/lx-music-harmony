/**
 * 「加入歌单」的目标选择器
 *
 * 单曲菜单和批量操作都要弹同一个面板，但 `SonglistRowActions` 已经依赖
 * `SonglistActions`（下载），把选择器放在任一侧都会形成循环依赖，
 * 所以单独抽到中立模块，两边各自 import。
 *
 * 面板走 `sheetService.addToTarget`：它渲染成自绘浮层而不是 bindSheet。
 * 因为这个面板几乎总是在动作菜单之后紧跟着打开，两个 bindSheet 连着开关时
 * 后一个会被前一个的收起动画吞掉（实测闪一下就消失）。
 * 自绘浮层没有窗口切换，也就没有这个问题，因此这里不需要任何延时。
 */
import { appLog as hilog } from '../../core/log/AppLogger';
import { t } from '../../service/LocalizationService';
import { sheetService, NEW_TARGET_PREFIX, type SheetOption } from '../../service/SheetService';
import {
  createUserList,
  getDefaultList,
  getLoveList,
  getUserList,
  getUserListMusic,
  LIST_IDS,
  type ListInfo,
  type MusicItem,
} from '../../service/ListService';

const TAG = 'SonglistTargetPicker';
const DOMAIN: number = 0x0001;

/** 一个可加入的目标歌单 */
export interface AddTarget {
  id: string;
  name: string;
}

/**
 * 歌单里是否已经有这首歌。
 *
 * addMusicToList 对重复添加是**静默跳过**的，调用方无从区分「加了」和「本来就有」，
 * 提示就会说谎（明明没变化也报「已添加」）。这里显式查一遍，让调用方给真实反馈。
 */
export function listContainsMusic(listId: string, musicId: string): boolean {
  let list: MusicItem[] = [];
  if (listId === LIST_IDS.LOVE) {
    list = getLoveList();
  } else if (listId === LIST_IDS.DEFAULT) {
    list = getDefaultList();
  } else {
    list = getUserListMusic(listId);
  }
  return list.some((item: MusicItem): boolean => item.id === musicId);
}

/**
 * 可加入的目标顺序：我喜欢 → 自建列表。
 *
 * **故意不放「默认列表」**：它在本 App 里没有任何入口页（我的页只有
 * 我喜欢 / 播放历史 / 本地音乐，也没有它的路由），加进去用户哪儿都看不到，
 * 表现就跟「点了却没添加」一样。与之相对，「喜欢列表」和自建歌单都有页面可进。
 */
function collectTargets(): AddTarget[] {
  const targets: AddTarget[] = [];
  targets.push({ id: LIST_IDS.LOVE, name: t('love_title') });
  const userLists: ListInfo[] = getUserList();
  for (let i = 0; i < userLists.length; i++) {
    targets.push({ id: userLists[i].id, name: userLists[i].name });
  }
  return targets;
}

/**
 * 让用户选目标歌单；面板末尾自带「新建歌单」，选中后在同一浮层里输入名字。
 *
 * @returns null 表示用户取消（含新建时输入为空）
 */
export async function pickAddTarget(): Promise<AddTarget | null> {
  const targets: AddTarget[] = collectTargets();
  const options: SheetOption[] = [];
  for (let i = 0; i < targets.length; i++) {
    options.push({ label: targets[i].name, value: targets[i].id });
  }

  const picked: string = await sheetService.addToTarget(t('player_add_to_list'), options);
  hilog.info(DOMAIN, TAG, 'pickAddTarget: picked=[%{public}s]', picked);
  if (picked.length === 0) {
    return null;
  }

  // 已有歌单：回传的是歌单 id
  if (!picked.startsWith(NEW_TARGET_PREFIX)) {
    for (let i = 0; i < targets.length; i++) {
      if (targets[i].id === picked) {
        return targets[i];
      }
    }
    hilog.warn(DOMAIN, TAG, 'picked unknown target: %{public}s', picked);
    return null;
  }

  // 新建：回传的是 `new:<名字>`
  const name: string = picked.substring(NEW_TARGET_PREFIX.length).trim();
  if (name.length === 0) {
    return null;
  }
  // 同名直接复用已有那张，避免建出两张同名歌单
  const existing: ListInfo | undefined =
    getUserList().find((info: ListInfo): boolean => info.name === name);
  if (existing) {
    hilog.info(DOMAIN, TAG, 'reuse existing list: %{public}s', existing.name);
    return { id: existing.id, name: existing.name };
  }
  const created: ListInfo = await createUserList(name);
  hilog.info(DOMAIN, TAG, 'created list: %{public}s', created.name);
  return { id: created.id, name: created.name };
}

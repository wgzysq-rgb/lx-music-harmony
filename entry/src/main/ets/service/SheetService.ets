/**
 * 全局底部面板服务（命令式调用）
 *
 * 背景：设置页的分组是渲染在 Scroll 里的，把 BottomSheet 挂在分组内会被滚动容器裁剪
 * （真机上表现为「点了没反应」）。凡是浮层都应该挂在页面根节点之上，
 * 因此这里统一成「服务发请求 → 根部宿主渲染」的模式：
 *
 *   const theme = await sheetService.select('浅色主题', options, current);
 *   const size = await sheetService.input('字体大小', '14', { numberOnly: true });
 *
 * 取消时返回空字符串，调用方按「未修改」处理。
 */
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG = 'SheetService';
const DOMAIN = 0x0005;

/** 面板选项 */
export interface SheetOption {
  label: string;
  value: string;
}

/**
 * 面板里的一行动作（菜单 / 确认框共用）
 * - icon：行首系统符号，商业级菜单都是「左图标 + 右文案」
 * - index：回传给调用方的原始下标（菜单项顺序会被调用方用来分支）
 */
export interface SheetRow {
  label: string;
  icon: Resource;
  danger: boolean;
  disabled: boolean;
  index: number;
}

/**
 * 选歌单面板的「新建」返回值前缀。
 *
 * 该面板把「列出歌单」和「输入新名字」放在同一个浮层里切换（不换窗口），
 * 所以新建意图也用返回值表达：`new:<用户输入的名字>`。
 * 歌单 id 只有 default / love / user_xxx 三种形态，不会与这个前缀冲突。
 */
export const NEW_TARGET_PREFIX: string = 'new:';

export type SheetKind = 'select' | 'input' | 'menu' | 'confirm' | 'addToTarget';

/** 一次面板请求（宿主据此渲染） */
export interface SheetRequest {
  kind: SheetKind;
  title: string;
  options: SheetOption[];
  value: string;
  placeholder: string;
  numberOnly: boolean;
  /** menu / confirm：动作行 */
  rows: SheetRow[];
  /** confirm：说明文字 */
  message: string;
  /** 完成：选中值 / 输入值；取消返回空字符串 */
  resolve: (value: string) => void;
}

type SheetPresenter = (request: SheetRequest) => void;

class SheetServiceImpl {
  private presenter: SheetPresenter | null = null;
  /**
   * 当前未结束请求的「强制收尾」句柄。
   *
   * 它就是原来的 busy 锁，但换成了可主动调用：早期只靠一个 boolean，
   * 一旦上一次面板的回调丢了（同类型面板连弹、组件被复用而回调还是旧的），
   * boolean 就永远是 true，之后**整个应用**所有浮层都弹不出来。
   * 现在新请求进来时先把上一个按「取消」收掉再接管，锁不会烂在原地。
   */
  private releaser: (() => void) | null = null;

  /** 宿主注册（应用启动时由 SheetHost 调用一次） */
  register(presenter: SheetPresenter): void {
    this.presenter = presenter;
  }

  /**
   * 宿主卸载（例如切到车机整屏界面）。
   *
   * 传入的 presenter 与当前登记的不是同一个就不动 —— 车机界面替换根节点时，
   * 新旧宿主的 mount/unmount 顺序不保证，避免新宿主刚注册就被旧宿主注销。
   */
  unregister(presenter: SheetPresenter): void {
    if (this.presenter !== presenter) {
      return;
    }
    this.presenter = null;
    // 未结束的请求按取消收掉，别让调用方的 await 永远悬着
    this.releasePending();
  }

  private releasePending(): void {
    const release = this.releaser;
    this.releaser = null;
    if (release) {
      release();
    }
  }

  /** 单选面板 */
  select(title: string, options: SheetOption[], value: string): Promise<string> {
    return this.request('select', title, options, value, '', false);
  }

  /** 输入面板 */
  input(
    title: string, value: string, placeholder: string = '', numberOnly: boolean = false
  ): Promise<string> {
    return this.request('input', title, [], value, placeholder, numberOnly);
  }

  /**
   * 选歌单面板：列出已有歌单，末尾一项「新建歌单」。
   *
   * 与其他面板的关键差别：它渲染成**自绘浮层**而不是 bindSheet。
   * 原因见 components/ui/AddToTargetSheet —— 这个面板几乎总是紧跟在动作菜单之后出现，
   * 而两个 bindSheet 连续开关时，后一个会被前一个的收起动画吞掉（实测闪一下就没）。
   * 自绘浮层挂在页面顶层 Stack，不存在窗口切换，也就没有这个问题。
   *
   * @returns 选中的歌单 id；新建返回 `new:<名字>`；取消返回空串
   */
  addToTarget(title: string, options: SheetOption[]): Promise<string> {
    return this.request('addToTarget', title, options, '', '', false);
  }

  /** 动作菜单：返回被点行的原始下标，取消返回 -1 */
  async menu(title: string, rows: SheetRow[]): Promise<number> {
    const picked: string = await this.request('menu', title, [], '', '', false, rows);
    return SheetServiceImpl.toIndex(picked);
  }

  /** 确认框：返回被点行的原始下标（调用方约定 1=确认、0=取消），取消返回 -1 */
  async confirm(title: string, message: string, rows: SheetRow[]): Promise<number> {
    const picked: string = await this.request('confirm', title, [], '', '', false, rows, message);
    return SheetServiceImpl.toIndex(picked);
  }

  private static toIndex(picked: string): number {
    if (picked.length === 0) {
      return -1;
    }
    const index: number = parseInt(picked);
    return isNaN(index) ? -1 : index;
  }

  private request(
    kind: SheetKind,
    title: string,
    options: SheetOption[],
    value: string,
    placeholder: string,
    numberOnly: boolean,
    rows: SheetRow[] = [],
    message: string = ''
  ): Promise<string> {
    if (!this.presenter) {
      hilog.warn(DOMAIN, TAG, 'No sheet host registered, request dropped: %{public}s', title);
      return Promise.resolve('');
    }
    if (this.releaser !== null) {
      // 上一个面板还没结束就来了新请求：按取消把它收掉，再由新请求接管。
      // 早期这里是「直接丢弃新请求」，一旦上一个面板的回调丢了锁就再也放不开，
      // 表现就是用户看到的「点了一次之后设置里什么弹框都弹不出来」。
      hilog.warn(DOMAIN, TAG, 'Superseding unfinished sheet with: %{public}s', title);
      this.releasePending();
    }
    return new Promise<string>((resolve: (result: string) => void) => {
      let settled: boolean = false;
      // 零参的「强制收尾」句柄：新请求要顶掉时直接调它，按取消结束本请求
      let release: () => void = (): void => {};
      const finish = (result: string): void => {
        if (settled) {
          return;
        }
        settled = true;
        if (this.releaser === release) {
          this.releaser = null;
        }
        resolve(result);
      };
      release = (): void => {
        finish('');
      };
      const request: SheetRequest = {
        kind,
        title,
        options,
        value,
        placeholder,
        numberOnly,
        rows,
        message,
        resolve: finish,
      };
      this.releaser = release;
      this.presenter?.(request);
    });
  }
}

export const sheetService = new SheetServiceImpl();

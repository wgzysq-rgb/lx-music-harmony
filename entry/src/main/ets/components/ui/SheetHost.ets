/**
 * 全局面板宿主（挂在页面根节点之上）
 *
 * 与 service/SheetService 配对：任何页面/分组都可以命令式调用
 * `sheetService.select(...)` / `sheetService.input(...)`，
 * 真正的浮层由这里渲染，避免被 Scroll 等容器裁剪。
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { sheetService, type SheetRequest } from '../../service/SheetService';
import { SelectSheet } from './SelectSheet';
import { InputSheet } from './InputSheet';
import { MenuSheet } from './MenuSheet';
import { AddToTargetOverlay } from './AddToTargetOverlay';
import type { SettingOption } from './SettingsTypes';
import type { SheetRow } from '../../service/SheetService';

const TAG = 'SheetHost';
const DOMAIN = 0x0005;

@Component
export struct SheetHost {
  /** bindSheet 面板（select / input / menu / confirm）的显隐 */
  @State visible: boolean = false;
  /**
   * 自绘浮层（addToTarget）的显隐。
   *
   * 与 visible 分开的原因：addToTarget 几乎总是在动作菜单之后打开，
   * 两个 bindSheet 连着开关时后一个会被前一个的收起动画吞掉。
   * 它走自绘浮层就没有窗口切换，用独立状态避免互相干扰。
   */
  @State overlayVisible: boolean = false;
  @State kind: string = 'select';
  /**
   * 当前请求的代号：每来一个新请求 +1。
   *
   * 面板切换时旧面板组件被卸载，bindSheet 随节点销毁会补发一次
   * onDisappear（按「用户取消」处理）。那次补发针对的是**上一个**请求，
   * 若不识别出来，就会把刚建立的新请求按取消结束 —— 实测日志里的
   * 「State variable 'visible' has changed during render」和
   * pickAddTarget: picked=[] 就是它造成的（表现为面板连弹都不弹）。
   * 用 @State 是为了让每次新请求都必然触发一次重建，回调里捕获的代号保持新鲜。
   */
  @State seq: number = 0;
  @State title: string = '';
  @State options: SettingOption[] = [];
  @State value: string = '';
  @State placeholder: string = '';
  @State numberOnly: boolean = false;
  @State rows: SheetRow[] = [];
  @State message: string = '';
  private pending: SheetRequest | null = null;
  /** 延迟收起用的定时器句柄（-1 表示没有待执行的） */
  private closeTimer: number = -1;
  /**
   * 注册给 SheetService 的投递函数。
   *
   * 存成字段是为了卸载时能把它原样交回去 —— 车机界面替换根节点时新旧宿主的
   * mount/unmount 顺序不保证，靠同一个引用比对，才不会把新宿主刚注册的那个注销掉。
   */
  private readonly presenter: (request: SheetRequest) => void = (request: SheetRequest): void => {
    this.seq += 1;
    this.pending = request;
    this.kind = request.kind;
    this.title = request.title;
    this.options = request.options.map((item): SettingOption => {
      const option: SettingOption = { label: item.label, value: item.value };
      return option;
    });
    this.value = request.value;
    this.placeholder = request.placeholder;
    this.numberOnly = request.numberOnly;
    this.rows = request.rows;
    this.message = request.message;
    if (request.kind === 'addToTarget') {
      // 自绘浮层：旧 bindSheet 直接收起。它的收尾回调已因代号过期被忽略，
      // 不会把新请求按取消结束。
      this.visible = false;
      this.overlayVisible = true;
    } else {
      this.overlayVisible = false;
      this.visible = true;
    }
    hilog.info(DOMAIN, TAG, 'present kind=%{public}s seq=%{public}d', request.kind, this.seq);
  };

  aboutToAppear() {
    sheetService.register(this.presenter);
  }

  aboutToDisappear() {
    if (this.closeTimer !== -1) {
      clearTimeout(this.closeTimer);
      this.closeTimer = -1;
    }
    sheetService.unregister(this.presenter);
    this.pending = null;
  }

  /**
   * 结束当前面板：取消传空字符串。
   *
   * 这里**不能**立刻把可见状态置 false。调用方拿到结果后常常紧接着又开一个面板，
   * 如果立刻收起，bindSheet 的收起动画会把紧接着打开的面板一起带走。
   * 所以把「收起」推迟到下一轮事件循环再判断：期间若有新请求（pending 非空），
   * 保持打开、直接换内容；没有新请求才真正关闭。
   */
  private finish(result: string): void {
    const request = this.pending;
    if (request === null) {
      // 已经结束过：bindSheet 收起动画结束时的 onDisappear 兜底回调会再进来一次
      return;
    }
    this.pending = null;
    request.resolve(result);
    hilog.info(DOMAIN, TAG, 'finish result=[%{public}s]', result);
    // 只保留最新一个待执行的收起：连续 finish 时旧的那个已无意义
    if (this.closeTimer !== -1) {
      clearTimeout(this.closeTimer);
    }
    this.closeTimer = setTimeout((): void => {
      this.closeTimer = -1;
      if (this.pending === null) {
        this.visible = false;
        this.overlayVisible = false;
      }
    }, 0);
  }

  /**
   * 面板回传的「完成」回调 —— 代号由**面板自己**带回，不从这里捕获。
   *
   * 这一点是这个宿主的全部关键：`onPick` 这类普通成员变量在 ArkUI 里只在面板
   * **创建**时赋值，父组件重建时不会刷新（只有 @Prop / @Link 会）。同类型面板
   * 连弹第二次时，面板还是同一个实例，回调却仍是第一次那个闭包，代号对不上就
   * 被当成过期回调丢掉 —— 表现是面板里的选项点了完全没反应，而且 SheetService
   * 的锁再也放不开，之后所有弹框都弹不出来。
   *
   * 改成「@Prop 把代号送进面板 → 面板回传 → 这里与当前代号比对」：
   * - 面板实例被复用（同类型连弹）：@Prop 会刷新，代号与当前一致，正常放行；
   * - 面板真被销毁（换 kind）：它停在自己的旧代号上，迟到的 onDisappear 照样被拦下。
   */
  private doneWithSeq(): (result: string, seq: number) => void {
    return (result: string, seq: number): void => {
      if (seq !== this.seq) {
        hilog.info(DOMAIN, TAG, 'stale sheet callback ignored (seq %{public}d)', seq);
        return;
      }
      this.finish(result);
    };
  }

  /** doneWithSeq 的取消形态 */
  private cancelledWithSeq(): (seq: number) => void {
    const done = this.doneWithSeq();
    return (seq: number): void => {
      done('', seq);
    };
  }

  /** doneWithSeq 的菜单形态：MenuSheet 回传的是行下标 */
  private pickedRowWithSeq(): (index: number, seq: number) => void {
    const done = this.doneWithSeq();
    return (index: number, seq: number): void => {
      done(index.toString(), seq);
    };
  }

  build() {
    Stack() {
      if (this.kind === 'input') {
        InputSheet({
          visible: $visible,
          requestSeq: this.seq,
          title: this.title,
          placeholder: this.placeholder,
          value: this.value,
          numberOnly: this.numberOnly,
          hostControlled: true,
          onSubmitSeq: this.doneWithSeq(),
          onCancelSeq: this.cancelledWithSeq(),
        })
      } else if (this.kind === 'menu' || this.kind === 'confirm') {
        MenuSheet({
          visible: $visible,
          requestSeq: this.seq,
          title: this.title,
          message: this.message,
          rows: this.rows,
          hostControlled: true,
          onPickRowSeq: this.pickedRowWithSeq(),
          onCancelSeq: this.cancelledWithSeq(),
        })
      } else if (this.kind === 'addToTarget') {
        // 自绘浮层：与动作菜单连着开也不会被 bindSheet 的收起动画吞掉
        AddToTargetOverlay({
          visible: this.overlayVisible,
          requestSeq: this.seq,
          title: this.title,
          options: this.options,
          onPickSeq: this.doneWithSeq(),
          onCancelSeq: this.cancelledWithSeq(),
        })
      } else {
        SelectSheet({
          visible: $visible,
          requestSeq: this.seq,
          title: this.title,
          options: this.options,
          value: this.value,
          // 关闭由本宿主统一负责（见 finish），面板自己不关，
          // 否则调用方紧接着再开一个面板时会被收起动画吞掉
          closeOnPick: false,
          hostControlled: true,
          onPickSeq: this.doneWithSeq(),
          onCancelSeq: this.cancelledWithSeq(),
        })
      }
    }
  }
}

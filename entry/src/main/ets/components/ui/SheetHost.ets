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

  aboutToAppear() {
    sheetService.register((request: SheetRequest): void => {
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
    });
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
    setTimeout((): void => {
      if (this.pending === null) {
        this.visible = false;
        this.overlayVisible = false;
      }
    }, 0);
  }

  /**
   * 生成「只对当前请求生效」的完成回调（带请求代号校验）。
   *
   * 旧面板被卸载时 bindSheet 会补发取消回调，代号对不上就直接忽略 ——
   * 这是「菜单 → 添加到歌单」两步面板一闪而过 / 连弹都不弹的根因修复。
   */
  private done(seq: number): (result: string) => void {
    return (result: string): void => {
      if (seq !== this.seq) {
        hilog.info(DOMAIN, TAG, 'stale sheet callback ignored (seq %{public}d)', seq);
        return;
      }
      this.finish(result);
    };
  }

  /** done 的取消形态：onCancel 回调签名是空参 */
  private cancelled(seq: number): () => void {
    const done = this.done(seq);
    return (): void => {
      done('');
    };
  }

  /** done 的菜单形态：MenuSheet 回传的是行下标 */
  private pickedRow(seq: number): (index: number) => void {
    return (index: number): void => {
      if (seq !== this.seq) {
        hilog.info(DOMAIN, TAG, 'stale sheet callback ignored (seq %{public}d)', seq);
        return;
      }
      this.finish(index.toString());
    };
  }

  build() {
    Stack() {
      if (this.kind === 'input') {
        InputSheet({
          visible: $visible,
          title: this.title,
          placeholder: this.placeholder,
          value: this.value,
          numberOnly: this.numberOnly,
          hostControlled: true,
          onSubmit: this.done(this.seq),
          onCancel: this.cancelled(this.seq),
        })
      } else if (this.kind === 'menu' || this.kind === 'confirm') {
        MenuSheet({
          visible: $visible,
          title: this.title,
          message: this.message,
          rows: this.rows,
          hostControlled: true,
          onPick: this.pickedRow(this.seq),
          onCancel: this.cancelled(this.seq),
        })
      } else if (this.kind === 'addToTarget') {
        // 自绘浮层：与动作菜单连着开也不会被 bindSheet 的收起动画吞掉
        AddToTargetOverlay({
          visible: this.overlayVisible,
          title: this.title,
          options: this.options,
          onPick: this.done(this.seq),
          onCancel: this.cancelled(this.seq),
        })
      } else {
        SelectSheet({
          visible: $visible,
          title: this.title,
          options: this.options,
          value: this.value,
          // 关闭由本宿主统一负责（见 finish），面板自己不关，
          // 否则调用方紧接着再开一个面板时会被收起动画吞掉
          closeOnPick: false,
          hostControlled: true,
          onPick: this.done(this.seq),
          onCancel: this.cancelled(this.seq),
        })
      }
    }
  }
}

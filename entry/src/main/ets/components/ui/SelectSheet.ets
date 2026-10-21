/**
 * 选择面板（单选）
 *
 * 取代设置页里手写的「居中弹窗 + ForEach 列表 + 回调透传」：
 * 底部面板、当前项打勾、点击即回传并关闭。
 */
import { DesignTokens } from '../../theme/DesignTokens';
import { t } from '../../service/LocalizationService';
import { BottomSheet, dismissSheet } from './BottomSheet';
import type { SettingOption } from './SettingsTypes';
import { SheetHeader } from './SheetHeader';
import { isConfirmKey } from '../../utils/KeyboardTools';

@Component
export struct SelectSheet {
  @StorageProp('theme') theme: string = 'light';
  @Link visible: boolean;
  @Prop title: string = '';
  @Prop options: SettingOption[] = [];
  @Prop value: string = '';
  onPick?: (value: string) => void;
  /** 关闭（点遮罩/取消）：调用方据此按「未修改」处理 */
  onCancel?: () => void;
  /**
   * 选中后是否由本组件自己关闭。
   *
   * 页面直接使用时为 true（现有行为不变）；
   * 经 SheetHost 渲染时传 false —— 关闭交给 SheetHost.finish 统一处理，
   * 这样调用方紧接着再开一个面板（例如选完「新建歌单」接着弹输入框）时，
   * 不会因为 true → false → true 的抖动被收起动画吞掉。
   */
  @Prop closeOnPick: boolean = true;
  /**
   * 关闭由外部宿主（SheetHost）统一负责时不写 visible。
   * 面板切换时本组件被卸载，bindSheet 销毁补发的 onDisappear 会在父组件渲染期间
   * 往 @Link visible 写状态（框架报错），托管模式下只回传取消、不碰 visible。
   * 页面直接使用时保持 false，行为不变。
   */
  @Prop hostControlled: boolean = false;

  /**
   * 一屏最多展示多少行（更多则面板内滚动）。
   * 面板整体高度由 BottomSheet 的 FIT_CONTENT 按内容量出来：选项 2-4 个就矮，
   * 主题这种 16 个的按 8 行封顶，再高在面板里滚动。
   */
  private static readonly MAX_VISIBLE_ROWS: number = 8;

  /** 行区高度：按选项数（上限 8 行）算，面板不会出现大片空白 */
  private listHeight(): number {
    const visible: number = Math.min(this.options.length, SelectSheet.MAX_VISIBLE_ROWS);
    return visible * DesignTokens.touchTarget();
  }

  private cancel(): void {
    if (this.hostControlled) {
      // 宿主托管：visible 由 SheetHost.finish 统一收，这里只回传取消
      if (this.onCancel) {
        this.onCancel();
      }
      return;
    }
    this.visible = dismissSheet(this.onCancel);
  }

  build() {
    BottomSheet({
      visible: $visible,
      // 标题自绘（左对齐 + 右上角关闭），不用 BottomSheet 的居中标题栏
      title: '',
      onDismiss: (): void => {
        this.cancel();
      },
      content: (): void => {
        this.Options();
      },
    })
  }

  @Builder
  Options() {
    // 标题行：左标题 + 右上角关闭（取消不再单独占一行，与其他面板统一）
    SheetHeader({
      title: this.title,
      onClose: (): void => {
        this.cancel();
      },
    })

    List() {
      ForEach(this.options, (option: SettingOption) => {
        ListItem() {
          Row() {
            Text(option.label)
              .fontSize(DesignTokens.fontTitle())
              .fontColor(option.value === this.value ? DesignTokens.accent() : DesignTokens.labelPrimary(this.theme))
              .fontWeight(option.value === this.value ? FontWeight.Medium : FontWeight.Normal)
              .layoutWeight(1)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })

            if (option.value === this.value) {
              SymbolGlyph($r('sys.symbol.checkmark_circle_fill'))
                .fontSize(DesignTokens.fontIconXl())
                .fontColor([DesignTokens.accent()])
            }
          }
          .width('100%')
          .height(DesignTokens.touchTarget())
          .alignItems(VerticalAlign.Center)
          // 2in1：选项行给悬停反馈 + 键盘可聚焦（PC 上没有电容按压）
          .hoverEffect(HoverEffect.Highlight)
          .focusable(true)
          .onKeyEvent((event: KeyEvent): void => {
            if (isConfirmKey(event)) {
              if (this.onPick) {
                this.onPick(option.value);
              }
              if (this.closeOnPick) {
                this.visible = false;
              }
            }
          })
        }
        .accessibilityText(t('a11y_select_all'))
        .onClick(() => {
          // 先回调再关闭（同 InputSheet：关闭事件会把请求按取消处理）
          if (this.onPick) {
            this.onPick(option.value);
          }
          if (this.closeOnPick) {
            this.visible = false;
          }
        })
      }, (option: SettingOption) => option.value)
    }
    .width('100%')
    .height(this.listHeight())
    .scrollBar(BarState.Off)
    .margin({ top: 4 })

  }
}

/**
 * 动作菜单面板（原系统 showActionMenu 的替代）
 *
 * 系统 showActionMenu 每一行都是居中文字，且最多 6 项、超了还得折叠；
 * 商业化 App（华为音乐 / Apple Music / QQ 音乐）的做法是底部面板 + 左侧图标 + 右侧文案，
 * 行与行左对齐、上下等距。这里统一成一套：
 *
 * - 标题（如歌曲名）左对齐放在最上面，下面可选一行说明（确认框用）
 * - 每行：行首系统符号 + 文案；危险项用危险色，禁用项变淡且点击无效
 * - 底部固定一行「取消」，与动作行之间有分隔，避免误触
 */
import { DesignTokens } from '../../theme/DesignTokens';
import { BottomSheet, dismissSheet } from './BottomSheet';
import { isConfirmKey } from '../../utils/KeyboardTools';
import { SheetHeader } from './SheetHeader';
import type { SheetRow } from '../../service/SheetService';

@Component
export struct MenuSheet {
  @StorageProp('theme') theme: string = 'light';
  @Link visible: boolean;
  /** 面板标题（歌曲名 / 列表名），左对齐 */
  @Prop title: string = '';
  /** 确认框的说明文字（菜单为空） */
  @Prop message: string = '';
  @Prop rows: SheetRow[] = [];
  /**
   * 关闭由外部宿主（SheetHost）统一负责时不写 visible。
   *
   * 原因：面板切换时本组件会被卸载，bindSheet 随节点销毁会补发一次 onDisappear；
   * 此时父组件正在渲染，往 @Link visible 里写状态会触发框架报错
   * （State variable has changed during render），回调也会被宿主的代号校验拦掉。
   * 页面直接使用时保持 false，行为不变。
   */
  @Prop hostControlled: boolean = false;
  onPick?: (index: number) => void;
  onCancel?: () => void;
  /**
   * 宿主托管时的请求代号。
   *
   * 必须用 @Prop：普通成员变量只在面板**创建**时赋值，父组件重建时不刷新。
   * 同类型面板连弹第二次时面板还是同一个实例，回调里带的一直是第一次的代号，
   * 宿主按「过期回调」丢弃 —— 表现就是菜单项点了没反应。
   */
  @Prop requestSeq: number = 0;
  /** 宿主托管专用：把代号一起回传，宿主据此识别已销毁面板的迟到回调 */
  onPickRowSeq?: (index: number, seq: number) => void;
  onCancelSeq?: (seq: number) => void;

  /** 一屏最多展示多少行（更多则面板内滚动，避免面板顶到屏幕顶） */
  private static readonly MAX_VISIBLE_ROWS: number = 8;

  /** 行区高度（行数 > 8 时内部滚动） */
  private contentHeight(): number {
    const visible: number = Math.min(this.rows.length, MenuSheet.MAX_VISIBLE_ROWS);
    return visible * DesignTokens.touchTarget();
  }


  private cancel(): void {
    if (this.hostControlled) {
      // 宿主托管：visible 由 SheetHost.finish 统一收，这里只回传取消
      if (this.onCancelSeq) {
        this.onCancelSeq(this.requestSeq);
      } else if (this.onCancel) {
        this.onCancel();
      }
      return;
    }
    this.visible = dismissSheet(this.onCancel);
  }

  /**
   * 点某一行动作：禁用行忽略，其余回传原始下标。
   *
   * 这里**不自己**把 visible 置 false：本组件只由 SheetHost 渲染，关闭由
   * SheetHost.finish 统一负责（它会等一拍，好让调用方紧接着开的下一个面板
   * 直接换内容，而不是被收起动画带走）。若在这里立刻关，
   * 「动作菜单 → 添加到歌单 → 选歌单」这类两步面板会闪一下就没。
   */
  private pick(row: SheetRow): void {
    if (row.disabled) {
      return;
    }
    if (this.onPickRowSeq) {
      this.onPickRowSeq(row.index, this.requestSeq);
      return;
    }
    if (this.onPick) {
      this.onPick(row.index);
    }
  }

  private rowColor(row: SheetRow): string {
    if (row.disabled) {
      return DesignTokens.labelTertiary(this.theme);
    }
    return row.danger ? DesignTokens.danger() : DesignTokens.labelPrimary(this.theme);
  }

  build() {
    BottomSheet({
      visible: $visible,
      // 标题自己画（左对齐），不用 BottomSheet 的居中标题栏
      title: '',
      // 高度按行数算（此前固定 medium，选项少时下面一大片空白）
      onDismiss: (): void => {
        this.cancel();
      },
      content: (): void => {
        this.Content()
      },
    })
  }

  @Builder
  Content() {
    Column() {
      // 标题行：左标题 + 右上角关闭（取消不单独占一行）
      SheetHeader({
        title: this.title,
        onClose: (): void => {
          this.cancel();
        },
      })
      .padding({ bottom: this.message.length > 0 ? 4 : 6 })

      if (this.message.length > 0) {
        Text(this.message)
          .fontSize(DesignTokens.fontCaption())
          .fontColor(DesignTokens.labelSecondary(this.theme))
          .maxLines(3)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .padding({ bottom: 8 })
      }

      List() {
        ForEach(this.rows, (row: SheetRow) => {
          ListItem() {
            this.ActionRow(row)
          }
        }, (row: SheetRow) => `menu_row_${row.index}`)
      }
      .width('100%')
      .height(this.contentHeight())
      .scrollBar(BarState.Off)
      .divider({
        strokeWidth: 0.33,
        color: DesignTokens.hairlineSeparator(this.theme),
        startMargin: DesignTokens.spaceGutter(),
        endMargin: DesignTokens.spaceGutter(),
      })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /** 单个动作行：左图标 + 右文案（左对齐，行高统一） */
  @Builder
  ActionRow(row: SheetRow) {
    Row({ space: 14 }) {
      SymbolGlyph(row.icon)
        .fontSize(DesignTokens.iconLg())
        .fontColor([this.rowColor(row)])
      Text(row.label)
        .fontSize(DesignTokens.fontTitle())
        .fontColor(this.rowColor(row))
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .textAlign(TextAlign.Start)
    }
    .width('100%')
    .height(DesignTokens.touchTarget())
    .alignItems(VerticalAlign.Center)
    .opacity(row.disabled ? 0.5 : 1)
    .hoverEffect(HoverEffect.Highlight)
    .focusable(!row.disabled)
    .accessibilityText(row.label)
    .onKeyEvent((event: KeyEvent): void => {
      if (isConfirmKey(event)) {
        this.pick(row);
      }
    })
    .onClick(() => {
      this.pick(row);
    })
  }
}

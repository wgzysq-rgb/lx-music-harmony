/**
 * 选歌单浮层（自绘，不走 bindSheet）
 *
 * 文件名带 Overlay 而不是 Sheet，是为了如实反映实现：它**故意**不用
 * components/ui/BottomSheet。项目的面板约定见 scripts/check_sheet_convention.py，
 * 这个文件已登记进该脚本的自绘遮罩白名单。
 *
 * **为什么不用 bindSheet**：
 * 这个浮层几乎总是在「动作菜单 → 添加到歌单」之后出现，即两个面板连着开。
 * 两个 bindSheet 连续开关时，后一个会被前一个的收起动画一起带走，
 * 实测表现为新面板弹出来不到半秒就自己缩回去（用户根本来不及点）。
 * 自绘浮层挂在 NavIndex 的顶层 Stack 上（不是 Scroll 里，不会被裁剪），
 * 只靠条件渲染显隐，不涉及窗口创建/销毁，因此没有这个时序问题。
 *
 * **为什么新建也放在这里**：新建要输入名字，原本是再弹一个 InputSheet。
 * 那又会变成两个面板连着开，问题依旧。这里做成同一浮层内的「列表 ↔ 新建」切换，
 * 整个流程始终只有一个浮层。
 */
import { DesignTokens } from '../../theme/DesignTokens';
import { t } from '../../service/LocalizationService';
import { NEW_TARGET_PREFIX } from '../../service/SheetService';
import { SheetHeader } from './SheetHeader';
import { requestFocusSafe } from '../../utils/FocusTools';
import { window } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import type { common } from '@kit.AbilityKit';
import type { SettingOption } from './SettingsTypes';

const TAG = 'AddToTargetOverlay';
const DOMAIN = 0x0005;

/** 新建输入框的焦点键：切到新建态时自动聚焦 */
const CREATE_INPUT_KEY: string = 'addToTargetInput';

@Component
export struct AddToTargetOverlay {
  @StorageProp('theme') theme: string = 'light';
  /** 显隐由 SheetHost 控制（不双向绑定，浮层没有系统收起手势需要回写） */
  @Prop @Watch('onVisibleChanged') visible: boolean = false;
  @Prop title: string = '';
  @Prop options: SettingOption[] = [];
  onPick?: (value: string) => void;
  onCancel?: () => void;

  /** false = 列歌单；true = 输入新名字。两者共用同一个浮层 */
  @State creating: boolean = false;
  @State draft: string = '';
  /** 键盘高度（vp）：新建态把面板顶到键盘上方（bindSheet 自动避让，自绘浮层得自己做） */
  @State keyboardHeight: number = 0;
  private appWindow: window.Window | null = null;
  private keyboardListener: ((height: number) => void) | null = null;

  /** 一屏最多列多少行，更多则面板内滚动 */
  private static readonly MAX_VISIBLE_ROWS: number = 8;

  aboutToAppear(): void {
    this.creating = false;
    this.draft = '';
    this.watchKeyboard(true);
  }

  aboutToDisappear(): void {
    this.watchKeyboard(false);
  }

  /**
   * 监听键盘高度：面板底部留出键盘的空间（单位从 px 换算成 vp）。
   *
   * 全程 try/catch：这是 aboutToAppear 里唯一的异步动作，一旦抛出就会把整个
   * 浮层的挂载带下去（表现为「面板一次都不弹」）。避让只是锦上添花，
   * 拿不到窗口就退化成不避让，绝不能影响面板本身能不能显示。
   */
  private watchKeyboard(on: boolean): void {
    if (on) {
      if (this.keyboardListener !== null) {
        return;
      }
      try {
        const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
        if (!context) {
          return;
        }
        window.getLastWindow(context).then((win: window.Window): void => {
          try {
            this.appWindow = win;
            this.keyboardListener = (height: number): void => {
              this.keyboardHeight = this.getUIContext().px2vp(height);
            };
            win.on('keyboardHeightChange', this.keyboardListener);
          } catch (err) {
            hilog.warn(DOMAIN, TAG, 'watchKeyboard bind failed: %{public}s', JSON.stringify(err));
          }
        }).catch((err: Error): void => {
          hilog.warn(DOMAIN, TAG, 'getLastWindow failed: %{public}s', err.message);
        });
      } catch (err) {
        hilog.warn(DOMAIN, TAG, 'watchKeyboard skipped: %{public}s', JSON.stringify(err));
      }
      return;
    }
    try {
      if (this.appWindow !== null && this.keyboardListener !== null) {
        this.appWindow.off('keyboardHeightChange', this.keyboardListener);
      }
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'watchKeyboard unbind failed: %{public}s', JSON.stringify(err));
    }
    this.appWindow = null;
    this.keyboardListener = null;
    this.keyboardHeight = 0;
  }

  /**
   * 每次重新显示都回到「列歌单」态。
   * 浮层不走挂载/卸载（同一类型面板连续两次时组件一直挂着），
   * 只靠 aboutToAppear 重置会漏：上次停在新建态关掉，这次打开就还是输入框。
   */
  onVisibleChanged(): void {
    hilog.info(DOMAIN, TAG, 'visible=%{public}s -> reset create state', this.visible ? 'true' : 'false');
    if (this.visible) {
      this.creating = false;
      this.draft = '';
    }
  }

  /**
   * 滚动区高度：按选项数算（上限 8 行）。
   * 「新建歌单」已移到 List 外面固定显示，这里不再 +1。
   */
  private listHeight(): number {
    const rows: number = Math.min(this.options.length, AddToTargetOverlay.MAX_VISIBLE_ROWS);
    return rows * DesignTokens.touchTarget();
  }

  /**
   * 返回上一级：新建态退回列表，列表态才真正关闭。
   * 这样在输入名字时误触遮罩不会丢掉已经选好的流程。
   */
  private back(): void {
    if (this.creating) {
      this.creating = false;
      this.draft = '';
      return;
    }
    if (this.onCancel) {
      this.onCancel();
    }
  }

  private submitCreate(): void {
    const name: string = this.draft.trim();
    if (name.length === 0) {
      return;
    }
    if (this.onPick) {
      this.onPick(`${NEW_TARGET_PREFIX}${name}`);
    }
  }

  build() {
    if (this.visible) {
      Stack({ alignContent: Alignment.Bottom }) {
        // 遮罩：点空白处返回（新建态退回列表，列表态关闭）
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor(DesignTokens.maskColor())
          .onClick((): void => {
            hilog.info(DOMAIN, TAG, 'tap mask (creating=%{public}s)', this.creating ? 'true' : 'false');
            this.back();
          })

        // 面板卡片
        Column() {
          SheetHeader({
            title: this.creating ? t('list_create_title') : this.title,
            onClose: (): void => {
              this.back();
            },
          })
          .margin({ bottom: 4 })

          if (this.creating) {
            this.CreateForm()
          } else {
            this.TargetList()
          }
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 8, bottom: 16 })
        // 键盘弹出时整体抬升，确认按钮不被键盘盖住
        .margin({ bottom: this.keyboardHeight })
        .backgroundColor(DesignTokens.glassFill(this.theme))
        .borderRadius({ topLeft: 28, topRight: 28 })
        .transition(TransitionEffect.OPACITY
          .combine(TransitionEffect.translate({ y: 240 }))
          .animation({ duration: 200, curve: Curve.FastOutSlowIn }))
      }
      .width('100%')
      .height('100%')
      .transition(TransitionEffect.OPACITY.animation({ duration: 160 }))
    }
  }

  /**
   * 歌单列表 + 底部固定的「新建歌单」。
   *
   * 「新建歌单」**故意不放进 List**：List 超过 8 行就会变成滚动区，自建歌单一多，
   * 它作为最后一项会被折叠到看不见（用户反馈「弹框里没有新建歌单」）。
   * 固定在滚动区下面，无论有多少歌单都始终可见可直接点。
   */
  @Builder
  TargetList() {
    Column() {
      List() {
        ForEach(this.options, (option: SettingOption) => {
          ListItem() {
            Row() {
              Text(option.label)
                .fontSize(DesignTokens.fontTitle())
                .fontColor(DesignTokens.labelPrimary(this.theme))
                .layoutWeight(1)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            .width('100%')
            .height(DesignTokens.touchTarget())
            .alignItems(VerticalAlign.Center)
            .hoverEffect(HoverEffect.Highlight)
            .onClick((): void => {
              hilog.info(DOMAIN, TAG, 'tap target row [%{public}s]', option.value);
              if (this.onPick) {
                this.onPick(option.value);
              }
            })
          }
        }, (option: SettingOption) => option.value)
      }
      .width('100%')
      .height(this.listHeight())
      .scrollBar(BarState.Off)
      .divider({
        strokeWidth: 0.33,
        color: DesignTokens.hairlineSeparator(this.theme),
        startMargin: DesignTokens.spaceGutter(),
        endMargin: DesignTokens.spaceGutter(),
      })

      // 「新建歌单」固钉在面板最下方
      Row()
        .width('100%')
        .height(1)
        .backgroundColor(DesignTokens.hairlineSeparator(this.theme))
      Row({ space: 10 }) {
        SymbolGlyph($r('sys.symbol.plus'))
          .fontSize(DesignTokens.iconLg())
          .fontColor([DesignTokens.accent()])
        Text(t('list_create_title'))
          .fontSize(DesignTokens.fontTitle())
          .fontColor(DesignTokens.accent())
          .layoutWeight(1)
      }
      .width('100%')
      .height(DesignTokens.touchTarget())
      .alignItems(VerticalAlign.Center)
      .hoverEffect(HoverEffect.Highlight)
      .accessibilityText(t('list_create_title'))
      .onClick((): void => {
        hilog.info(DOMAIN, TAG, 'tap create row -> creating=true');
        this.creating = true;
      })
    }
    .width('100%')
  }

  /** 新建歌单：输入名字 */
  @Builder
  CreateForm() {
    Column() {
      TextInput({ placeholder: t('list_name_placeholder'), text: this.draft })
        .id(CREATE_INPUT_KEY)
        .onAppear((): void => {
          requestFocusSafe(this.getUIContext(), CREATE_INPUT_KEY);
        })
        .height(DesignTokens.touchTarget())
        .width('100%')
        .backgroundColor(DesignTokens.mutedFill(this.theme))
        .borderRadius(12)
        .padding({ left: 14, right: 14 })
        .fontSize(DesignTokens.fontTitle())
        .fontColor(DesignTokens.labelPrimary(this.theme))
        .placeholderColor(DesignTokens.labelTertiary(this.theme))
        .onChange((value: string): void => {
          this.draft = value;
        })
        .onSubmit((): void => {
          this.submitCreate();
        })

      Row() {
        Button(t('confirm'))
          .type(ButtonType.Capsule)
          .layoutWeight(1)
          .height(DesignTokens.touchTarget())
          .fontSize(DesignTokens.fontTitle())
          .fontColor(DesignTokens.onAccent())
          .backgroundColor(DesignTokens.accent())
          .onClick((): void => {
            this.submitCreate();
          })
      }
      .width('100%')
      .margin({ top: 16 })
    }
    .width('100%')
  }
}

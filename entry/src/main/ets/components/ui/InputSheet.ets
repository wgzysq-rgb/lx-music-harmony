/**
 * 输入面板（单行文本）
 *
 * 取代设置页里手写的「居中弹窗 + TextInput + 两个按钮 + 回调透传」。
 */
import { DesignTokens } from '../../theme/DesignTokens';
import { t } from '../../service/LocalizationService';
import { BottomSheet, dismissSheet } from './BottomSheet';
import { requestFocusSafe } from '../../utils/FocusTools';
import { SheetHeader } from './SheetHeader';

/** 输入框焦点键：面板出现即聚焦，省掉用户多点一次 */
const INPUT_SHEET_KEY: string = 'sheetTextInput';

@Component
export struct InputSheet {
  @StorageProp('theme') theme: string = 'light';
  @Link visible: boolean;
  @Prop title: string = '';
  @Prop placeholder: string = '';
  /** 初始值（面板打开时由调用方写入） */
  @Prop value: string = '';
  /** 键盘类型：普通文本 / 数字（下载并发数等） */
  @Prop numberOnly: boolean = false;
  /**
   * 关闭由外部宿主（SheetHost）统一负责时不写 visible。
   * 面板切换时本组件被卸载，bindSheet 销毁补发的 onDisappear 会在父组件渲染期间
   * 往 @Link visible 写状态（框架报错），托管模式下只回传取消、不碰 visible。
   * 页面直接使用时保持 false，行为不变。
   */
  @Prop hostControlled: boolean = false;
  onSubmit?: (value: string) => void;
  /** 关闭（点遮罩/取消） */
  onCancel?: () => void;
  /**
   * 宿主托管时的请求代号。
   *
   * 必须用 @Prop：普通成员变量只在面板**创建**时赋值，父组件重建时不刷新。
   * 同类型面板连弹第二次时面板还是同一个实例，回调里带的一直是第一次的代号，
   * 宿主按「过期回调」丢弃 —— 表现就是输入完点确定没反应。
   */
  @Prop requestSeq: number = 0;
  /** 宿主托管专用：把代号一起回传，宿主据此识别已销毁面板的迟到回调 */
  onSubmitSeq?: (value: string, seq: number) => void;
  onCancelSeq?: (seq: number) => void;

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

  /** 提交回传：宿主托管时带上请求代号，页面直连时走原来的 onSubmit */
  private emitSubmit(value: string): void {
    if (this.onSubmitSeq) {
      this.onSubmitSeq(value, this.requestSeq);
      return;
    }
    if (this.onSubmit) {
      this.onSubmit(value);
    }
  }

  @State draft: string = '';

  aboutToAppear() {
    this.draft = this.value;
  }


  build() {
    BottomSheet({
      visible: $visible,
      // 标题自绘（左对齐 + 右上角关闭）
      title: '',
      onDismiss: (): void => {
        this.cancel();
      },
      content: (): void => {
        this.Form();
      },
    })
  }

  @Builder
  Form() {
    Column() {
      // 标题行：左标题 + 右上角关闭（取消不再占一行按钮）
      SheetHeader({
        title: this.title,
        onClose: (): void => {
          this.cancel();
        },
      })
      .margin({ bottom: 8 })

      TextInput({ placeholder: this.placeholder, text: this.draft })
        .type(this.numberOnly ? InputType.Number : InputType.Normal)
        .id(INPUT_SHEET_KEY)
        // 面板打开时自动聚焦并弹键盘（主流输入面板的手感）
        .onAppear(() => {
          requestFocusSafe(this.getUIContext(), INPUT_SHEET_KEY);
        })
        .height(DesignTokens.touchTarget())
        .width('100%')
        .backgroundColor(DesignTokens.mutedFill(this.theme))
        .borderRadius(12)
        .padding({ left: 14, right: 14 })
        .fontSize(DesignTokens.fontTitle())
        .fontColor(DesignTokens.labelPrimary(this.theme))
        .placeholderColor(DesignTokens.labelTertiary(this.theme))
        .onChange((value: string) => {
          this.draft = value;
        })

      Row() {
        Button(t('confirm'))
          .type(ButtonType.Capsule)
          .layoutWeight(1)
          .height(DesignTokens.touchTarget())
          .fontSize(DesignTokens.fontTitle())
          .fontColor(DesignTokens.onAccent())
          .backgroundColor(DesignTokens.accent())
          .onClick(() => {
            // 必须先回调再关闭：bindSheet 关闭会触发 onDismiss（按「取消」处理），
            // 反过来会先用空值结束请求，用户输入就被吞掉了。
            this.emitSubmit(this.draft);
            this.visible = false;
          })
      }
      .width('100%')
      .margin({ top: 16 })
    }
    .width('100%')
  }
}

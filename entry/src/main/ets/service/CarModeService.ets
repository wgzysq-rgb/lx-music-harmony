/**
 * 车机（HiCar）模式服务
 *
 * 定位：把「手机是否连着车机」这件事收敛成 App 内一个可订阅的布尔状态，
 * 首页/播放页据此切到驾驶态（大按钮、简化信息）。
 *
 * 为什么车机 UI 不需要另写一套：HiCar 上的音频类应用不是投屏 App 自己的界面，
 * 车机侧界面、分辨率适配、桌面音频卡片都由 HiCar 绘制，它与 App 的数据通道是
 * 系统播控（AVSession）——曲目/封面/进度/上下一首/循环/收藏全部走 PlaybackSession
 * 那一层。所以「支持车机」真正要补的是：
 *   1. AVSession 元数据与控制命令够完整（见 MediaControlCommands）；
 *   2. 手机自己这一份界面在车机分辨率下不至于小得点不到 —— 本服务只负责
 *      告诉界面「现在是车机场景」，具体排版由页面自己收口。
 *
 * 两条事实决定了这里的写法：
 *   1. ohos.permission.ACCESS_CAR_DISTRIBUTED_ENGINE 是 normal + system_grant，
 *      普通应用在 module.json5 声明即可，没有 ACL 审批，也没有运行时弹窗；
 *   2. 在无车机能力的设备（模拟器、平板）上这些接口会抛 201/801，
 *      因此全部调用都包在能力探测 + try/catch 里，失败一律视为「未连接」，
 *      绝不能让车机探测把启动流程拖挂。
 */
import { smartMobilityCommon } from '@kit.CarKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import type { CarModeSetting } from './settings/SettingsTypes';

const TAG = 'CarModeService';
const DOMAIN: number = 0x0002;

// 设置项类型统一在 settings/SettingsTypes 定义，这里 re-export 方便调用方就近引用
export type { CarModeSetting };

/** AppStorage key：车机模式是否生效（页面用 @StorageProp('carMode') 订阅） */
const CAR_MODE_KEY: string = 'carMode';
/** AppStorage key：系统层面是否真的连着 HiCar（与手动覆盖无关） */
const CAR_CONNECTED_KEY: string = 'carConnected';

class CarModeService {
  private awareness: smartMobilityCommon.SmartMobilityAwareness | null = null;
  private listening: boolean = false;
  private setting: CarModeSetting = 'auto';
  private connected: boolean = false;
  private active: boolean = false;

  /**
   * 启动探测并订阅。
   * 幂等：重复调用不会重复订阅；失败只记日志，不影响应用其它功能。
   */
  init(): void {
    // 先落一次初值：@StorageProp 在 key 不存在时拿到的是默认值，
    // 后续第一次 setOrCreate 若值相同不会通知，界面就永远停在默认值上。
    this.publish();

    if (!canIUse('SystemCapability.CarService.DistributedEngine')) {
      hilog.info(DOMAIN, TAG, 'Car distributed engine unsupported, car mode stays off');
      return;
    }

    if (this.awareness === null) {
      try {
        this.awareness = smartMobilityCommon.getSmartMobilityAwareness();
        hilog.info(DOMAIN, TAG, 'SmartMobilityAwareness acquired');
      } catch (err) {
        hilog.warn(DOMAIN, TAG, 'getSmartMobilityAwareness failed: %{public}s', this.describe(err));
        return;
      }
    }

    // 订阅前先同步一次当前状态：应用可能在已连车机的情况下被拉起，
    // 只靠 on() 会等不到「状态变化」事件，界面就一直是手机态。
    this.syncStatus();
    this.subscribe();
  }

  /**
   * 应用设置。'auto' 跟随系统，'on'/'off' 是手动覆盖——
   * 没有车机的环境（模拟器、开发机）靠它预览和验收驾驶态。
   */
  applySetting(setting: CarModeSetting): void {
    if (this.setting === setting) {
      return;
    }
    hilog.info(DOMAIN, TAG, 'setting %{public}s -> %{public}s', this.setting, setting);
    this.setting = setting;
    this.refresh();
  }

  /** 停止订阅（应用退出时调用，避免回调打到已销毁的界面） */
  destroy(): void {
    if (this.awareness === null || !this.listening) {
      return;
    }
    try {
      this.awareness.off('smartMobilityStatus', [smartMobilityCommon.SmartMobilityType.HICAR]);
      hilog.info(DOMAIN, TAG, 'SmartMobilityStatus unsubscribed');
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'off smartMobilityStatus failed: %{public}s', this.describe(err));
    }
    this.listening = false;
  }

  /** 读取一次当前连接状态（不依赖事件） */
  private syncStatus(): void {
    const awareness = this.awareness;
    if (awareness === null) {
      return;
    }
    try {
      const info: smartMobilityCommon.SmartMobilityInfo =
        awareness.getSmartMobilityStatus(smartMobilityCommon.SmartMobilityType.HICAR);
      this.applyConnected(info.status === smartMobilityCommon.SmartMobilityStatus.RUNNING);
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'getSmartMobilityStatus failed: %{public}s', this.describe(err));
    }
  }

  /** 订阅 HiCar 连接状态变化 */
  private subscribe(): void {
    const awareness = this.awareness;
    if (awareness === null || this.listening) {
      return;
    }
    try {
      awareness.on('smartMobilityStatus', [smartMobilityCommon.SmartMobilityType.HICAR],
        (info: smartMobilityCommon.SmartMobilityInfo): void => {
          this.applyConnected(info.status === smartMobilityCommon.SmartMobilityStatus.RUNNING);
        });
      this.listening = true;
      hilog.info(DOMAIN, TAG, 'SmartMobilityStatus subscribed (HiCar)');
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'on smartMobilityStatus failed: %{public}s', this.describe(err));
    }
  }

  private applyConnected(connected: boolean): void {
    if (this.connected === connected) {
      return;
    }
    hilog.info(DOMAIN, TAG, 'HiCar connected=%{public}s', String(connected));
    this.connected = connected;
    this.refresh();
  }

  /** 按「设置来源 + 系统连接状态」重算生效状态 */
  private refresh(): void {
    let next: boolean = this.connected;
    if (this.setting === 'on') {
      next = true;
    } else if (this.setting === 'off') {
      next = false;
    }
    if (this.active !== next) {
      this.active = next;
      hilog.info(DOMAIN, TAG, 'car mode active=%{public}s (setting=%{public}s connected=%{public}s)',
        String(next), this.setting, String(this.connected));
    }
    this.publish();
  }

  private publish(): void {
    AppStorage.setOrCreate(CAR_MODE_KEY, this.active);
    AppStorage.setOrCreate(CAR_CONNECTED_KEY, this.connected);
  }

  private describe(err: Object): string {
    const e = err as BusinessError;
    const code: number = e.code ?? 0;
    const message: string = (err as Error)?.message ?? '';
    return `code=${code} msg=${message}`;
  }
}

export const carModeService = new CarModeService();

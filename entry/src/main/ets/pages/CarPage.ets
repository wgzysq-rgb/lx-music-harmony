/**
 * 车机（HiCar）全屏界面
 *
 * 定位：连上车机时整窗切换成这一屏，替代手机版首页/播放页。
 *
 * 为什么自己做而不是用 HiCar 原生那套：HiCar 的音频原生界面由 HiCar 自己绘制，
 * 但**只对云端白名单里的应用生效**，而白名单校验的是包名 + AGC 签名证书指纹，
 * 本地改不了。既然拿不到，就在 App 内画一个观感/交互对齐它的界面——
 * 车机上隔着一块中控屏，用户要的其实只有四件事：看清是谁在唱、听清这一句、
 * 能一下点中播放/切歌、不误触。所以这一屏只保留这些。
 *
 * 与手机版的差异（有意为之）：
 * - 固定深色：车内常是暗光环境，且不跟随手机浅色主题；
 * - 强制横屏：车机屏是横向的，"更多应用"投屏时按横屏渲染才不会两侧留黑；
 * - 信息极简：只有封面/歌名/歌手/当前一句歌词，没有列表、评论、音源切换；
 * - 控件放大 + 横向滑动切歌：手指落点大，滑动比找按钮快。
 */
import { window } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { DesignTokens } from '../theme/DesignTokens';
import { playerService } from '../service/PlayerService';
import type { SongInfo } from '../service/PlayerService';
import type { MusicInfo } from '../types/MusicTypes';
import type { ProgressInfo } from '../service/player/PlaybackTypes';
import type { LyricLineState } from '../service/player/LyricHub';
import { PlayMediaAssets } from './PlayDetail/PlayMediaAssets';
import { applyThemeToWindow } from '../service/WindowService';
import { t } from '../service/LocalizationService';
import { asText } from '../utils/ValueCoerce';
import { appLog as hilog } from '../core/log/AppLogger';

const TAG = 'CarPage';
const DOMAIN: number = 0x0001;

/** 横向滑动切歌的最小位移（vp）：太小会让"点进度条"被误判成切歌 */
const SWIPE_THRESHOLD_VP: number = 70;

@Component
export struct CarPage {
  @State musicName: string = '';
  @State singer: string = '';
  @State album: string = '';
  @State cover: string = '';
  @State isPlaying: boolean = false;
  @State progress: number = 0;
  @State currentTime: string = '00:00';
  @State totalTime: string = '00:00';
  /** 当前这一句歌词（车机上只显示一句，瞟一眼就够） */
  @State lyricLine: string = '';
  /** 下一句：给一个"要来了"的预告，比多行滚动更省注意力 */
  @State nextLyric: string = '';
  /** 拖动进度条时显示预览值；-1 表示没在拖 */
  @State previewProgress: number = -1;
  /**
   * 封面边长（vp）。不用百分比 + aspectRatio 直接定：横屏时左右两栏都是"宽大于高"，
   * 按高度算出的边长会横向溢出左栏。这里取容器实测的较小边，横竖都不会越界。
   */
  @State coverSize: number = 240;
  /** 状态栏高度（vp）：全屏后内容会铺到状态栏下面，顶栏要自己让出这块 */
  @State topInset: number = 0;

  /** 退出车机界面（回到手机版布局） */
  onExit?: () => void;

  private alive: boolean = true;
  private carWindow: window.Window | null = null;
  private unsubscribePlayState: (() => void) | null = null;
  private unsubscribeMusicInfo: (() => void) | null = null;
  private unsubscribeProgress: (() => void) | null = null;
  private unsubscribeLyric: (() => void) | null = null;

  aboutToAppear(): void {
    hilog.info(DOMAIN, TAG, 'car UI mounted');
    // 先声明"车机界面在屏"：窗口服务据此固定深色系统栏。
    // 必须早于任何 applyThemeToWindow，否则会先被刷成手机主题色。
    AppStorage.setOrCreate('carUiVisible', true);
    this.syncFromPlayer();
    void this.lockLandscape();

    this.unsubscribePlayState = playerService.onPlayStateChange((isPlay: boolean): void => {
      if (!this.alive) {
        return;
      }
      this.isPlaying = isPlay;
    });
    this.unsubscribeMusicInfo = playerService.onMusicInfoChange((info: MusicInfo): void => {
      if (!this.alive) {
        return;
      }
      this.applyMusicInfo(info);
    });
    this.unsubscribeProgress = playerService.onProgressInfoChange((prog: ProgressInfo): void => {
      if (!this.alive) {
        return;
      }
      // 拖动中不用轮询值覆盖，否则进度条会被"拽回去"
      if (this.previewProgress >= 0) {
        this.currentTime = prog.nowPlayTimeStr;
        this.totalTime = prog.maxPlayTimeStr;
        return;
      }
      this.progress = prog.progress;
      this.currentTime = prog.nowPlayTimeStr;
      this.totalTime = prog.maxPlayTimeStr;
    });
    this.unsubscribeLyric = playerService.onLyricLineChange((state: LyricLineState): void => {
      if (!this.alive) {
        return;
      }
      this.lyricLine = state.hasLyric ? state.current : '';
      this.nextLyric = state.hasLyric ? state.next : '';
    });
  }

  aboutToDisappear(): void {
    this.alive = false;
    // 先撤销"在屏"标记，restoreOrientation 末尾那次 applyThemeToWindow
    // 才会按手机主题把系统栏刷回去
    AppStorage.setOrCreate('carUiVisible', false);
    if (this.unsubscribePlayState) this.unsubscribePlayState();
    if (this.unsubscribeMusicInfo) this.unsubscribeMusicInfo();
    if (this.unsubscribeProgress) this.unsubscribeProgress();
    if (this.unsubscribeLyric) this.unsubscribeLyric();
    this.unsubscribePlayState = null;
    this.unsubscribeMusicInfo = null;
    this.unsubscribeProgress = null;
    this.unsubscribeLyric = null;
    void this.restoreOrientation();
  }

  /** 进入车机界面时先取一次现状：从后台被拉起时不会再有"变化"事件 */
  private syncFromPlayer(): void {
    const info = playerService.getCurrentSong();
    if (info) {
      this.applyMusicInfoFromSong(info);
    }
    const snapshot = playerService.getProgress();
    this.progress = snapshot.progress;
    this.currentTime = snapshot.nowPlayTimeStr;
    this.totalTime = snapshot.maxPlayTimeStr;
    this.isPlaying = playerService.isPlaying();
    const lyric = playerService.getLyricState();
    this.lyricLine = lyric.hasLyric ? lyric.current : '';
    this.nextLyric = lyric.hasLyric ? lyric.next : '';
  }

  private applyMusicInfo(info: MusicInfo): void {
    this.musicName = asText(info.name, t('unknown_song'));
    this.singer = asText(info.singer, t('unknown_artist'));
    this.album = asText(info.albumName, asText(info.album));
    this.cover = PlayMediaAssets.normalizeCoverUrl(asText(info.pic, asText(info.img)));
  }

  /** SongInfo 是播放器内部口径，和 MusicInfo 字段名不同，这里单独铺一遍 */
  private applyMusicInfoFromSong(song: SongInfo): void {
    this.musicName = asText(song.title, t('unknown_song'));
    this.singer = asText(song.artist, t('unknown_artist'));
    this.album = asText(song.album);
    this.cover = PlayMediaAssets.normalizeCoverUrl(asText(song.artwork));
  }

  /**
   * 车机场景强制横屏。
   *
   * "更多应用"投屏是按车机屏渲染 App 界面的：App 若停在竖屏，两侧会留出大片黑边。
   * 这里主动请求横屏，退出时恢复系统默认（UNSPECIFIED = 交回系统策略）。
   */
  private async lockLandscape(): Promise<void> {
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      const win = await window.getLastWindow(ctx);
      this.carWindow = win;
      await win.setPreferredOrientation(window.Orientation.LANDSCAPE);
      hilog.info(DOMAIN, TAG, 'orientation locked to landscape');
      // 车机界面是整屏场景：顶部状态栏（白色时间/信号条）在这块屏上没有意义，
      // 而且深色界面上突然一条白底非常刺眼。单独 try：部分窗口不支持改系统栏。
      try {
        await win.setWindowSystemBarEnable([]);
        hilog.info(DOMAIN, TAG, 'system bars hidden');
      } catch (barErr) {
        hilog.warn(DOMAIN, TAG, 'hide system bars failed: %{public}s',
          (barErr as Error)?.message ?? '');
      }
      // 平板/2in1 上 setWindowSystemBarEnable([]) 会返回成功但并不真的隐藏状态栏，
      // 这时退而求其次：让内容铺到状态栏下方，深色背景直接盖住那条白。
      try {
        await win.setWindowLayoutFullScreen(true);
        hilog.info(DOMAIN, TAG, 'layout full screen enabled');
      } catch (fsErr) {
        hilog.warn(DOMAIN, TAG, 'enable full screen layout failed: %{public}s',
          (fsErr as Error)?.message ?? '');
      }
      // 上面两步都压不住那条白条时，最后一招是把它"染成"车机底色：
      // 交给窗口服务做（它读 carUiVisible），不在这里直接下发——
      // initWindowService 与 onThemeChange 都会带延时重刷系统栏，
      // 页面里染完就被覆盖，只有让窗口服务自己知道深色才不会打架。
      try {
        await applyThemeToWindow();
        hilog.info(DOMAIN, TAG, 'window appearance switched to car palette');
      } catch (themeErr) {
        hilog.warn(DOMAIN, TAG, 'switch to car palette failed: %{public}s',
          (themeErr as Error)?.message ?? '');
      }
      // 全屏铺开后内容会顶到状态栏底下，顶栏得自己让出这块高度，
      // 否则"正在播放 / 退出车机界面"会被状态栏压住。
      try {
        const avoid = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
        const insetPx = avoid.topRect.height;
        this.topInset = insetPx > 0 ? Math.round(this.getUIContext().px2vp(insetPx)) : 0;
        hilog.info(DOMAIN, TAG, 'top inset=%{public}svp (raw %{public}spx)', String(this.topInset), String(insetPx));
      } catch (avoidErr) {
        hilog.warn(DOMAIN, TAG, 'read avoid area failed: %{public}s',
          (avoidErr as Error)?.message ?? '');
      }
    } catch (err) {
      // 部分设备/窗口不支持改方向，横屏失败只影响观感，不该拖垮界面
      hilog.warn(DOMAIN, TAG, 'lock landscape failed: %{public}s',
        (err as Error)?.message ?? '');
    }
  }

  private async restoreOrientation(): Promise<void> {
    const win = this.carWindow;
    this.carWindow = null;
    if (!win) {
      return;
    }
    try {
      await win.setPreferredOrientation(window.Orientation.UNSPECIFIED);
      hilog.info(DOMAIN, TAG, 'orientation restored');
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'restore orientation failed: %{public}s',
        (err as Error)?.message ?? '');
    }
    try {
      await win.setWindowSystemBarEnable(['status', 'navigation']);
      hilog.info(DOMAIN, TAG, 'system bars restored');
    } catch (barErr) {
      hilog.warn(DOMAIN, TAG, 'restore system bars failed: %{public}s',
        (barErr as Error)?.message ?? '');
    }
    try {
      await win.setWindowLayoutFullScreen(false);
      hilog.info(DOMAIN, TAG, 'layout full screen disabled');
    } catch (fsErr) {
      hilog.warn(DOMAIN, TAG, 'disable full screen layout failed: %{public}s',
        (fsErr as Error)?.message ?? '');
    }
    // 系统栏底色回到手机主题色：车机那套深色是这一屏专用的，不能带出去
    this.topInset = 0;
    await applyThemeToWindow();
  }

  private togglePlay(): void {
    if (this.isPlaying) {
      playerService.pause().catch((err: Error) => {
        hilog.warn(DOMAIN, TAG, 'pause failed: %{public}s', err.message);
      });
      return;
    }
    playerService.play().catch((err: Error) => {
      hilog.warn(DOMAIN, TAG, 'play failed: %{public}s', err.message);
    });
  }

  private prev(): void {
    playerService.playPrev().catch((err: Error) => {
      hilog.warn(DOMAIN, TAG, 'playPrev failed: %{public}s', err.message);
    });
  }

  private next(): void {
    playerService.playNext().catch((err: Error) => {
      hilog.warn(DOMAIN, TAG, 'playNext failed: %{public}s', err.message);
    });
  }

  /** 松手才真正 seek：拖动过程只更新预览，避免每移动一像素就调一次播放器 */
  private commitSeek(value: number): void {
    this.previewProgress = -1;
    const duration = playerService.getProgress().maxPlayTime;
    if (duration <= 0) {
      return;
    }
    playerService.seekTo(duration * value / 100).catch((err: Error) => {
      hilog.warn(DOMAIN, TAG, 'seek failed: %{public}s', err.message);
    });
  }

  @Builder
  TransportKey(kind: string, filled: boolean) {
    Stack() {
      Circle({ width: filled ? 96 : 72, height: filled ? 96 : 72 })
        .fill(filled ? DesignTokens.accent() : DesignTokens.carSurface())
      Image(this.iconFor(kind))
        .width(filled ? 40 : 32)
        .height(filled ? 40 : 32)
        .fillColor(filled ? DesignTokens.onAccent() : DesignTokens.carLabelPrimary())
        .margin(kind === 'play' && !this.isPlaying ? { left: 3 } : {})
    }
    .accessibilityText(this.transportLabel(kind))
    .onClick(() => {
      if (kind === 'prev') {
        this.prev();
      } else if (kind === 'next') {
        this.next();
      } else {
        this.togglePlay();
      }
    })
  }

  private iconFor(kind: string): Resource {
    if (kind === 'prev') {
      return $r('app.media.ic_pd_prev');
    }
    if (kind === 'next') {
      return $r('app.media.ic_pd_next');
    }
    return this.isPlaying ? $r('app.media.ic_pd_pause') : $r('app.media.ic_pd_play');
  }

  private transportLabel(kind: string): string {
    if (kind === 'prev') {
      return t('a11y_previous');
    }
    if (kind === 'next') {
      return t('a11y_next');
    }
    return this.isPlaying ? t('a11y_pause') : t('a11y_play');
  }

  build() {
    Column() {
      // 顶栏：只留状态与"退出车机界面"，不放导航
      Row() {
        Text(t('car_now_playing'))
          .fontSize(DesignTokens.fontCaption())
          .fontColor(DesignTokens.carLabelTertiary())
        Blank()
        Text(t('car_exit'))
          .fontSize(DesignTokens.fontCaption())
          .fontColor(DesignTokens.carLabelTertiary())
          .padding({ left: 14, right: 14, top: 7, bottom: 7 })
          .borderRadius(15)
          .backgroundColor(DesignTokens.carSurface())
          .onClick(() => {
            if (this.onExit) {
              this.onExit();
            }
          })
      }
      .width('100%')
      // 高度随避让区一起长：padding 是"占内部空间"而不是"把内容往下推"，
      // 只加 padding 不加速度会把 46vp 的顶栏内容压扁
      .height(46 + this.topInset)
      .padding({ left: 30, right: 24, top: this.topInset })

      // 主体：左封面 / 右信息，横向滑动切歌
      Row({ space: 44 }) {
        Column() {
          if (this.cover.length > 0) {
            Image(this.cover)
              .width(this.coverSize)
              .height(this.coverSize)
              .objectFit(ImageFit.Cover)
              .borderRadius(26)
              .draggable(false)
          } else {
            Image($r('app.media.ic_player_cover_placeholder'))
              .width(this.coverSize)
              .height(this.coverSize)
              .objectFit(ImageFit.Cover)
              .borderRadius(26)
          }
        }
        .layoutWeight(46)
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .onAreaChange((_oldValue: Area, newValue: Area): void => {
          const width = Number(newValue.width);
          const height = Number(newValue.height);
          if (!(width > 0) || !(height > 0)) {
            return;
          }
          const side = Math.max(140, Math.min(width, height) * 0.94);
          // 只在变化明显时写状态：onAreaChange 会在布局过程中触发，频繁小抖动没必要重绘
          if (Math.abs(side - this.coverSize) > 1) {
            this.coverSize = side;
          }
        })

        Column() {
          Text(this.musicName.length > 0 ? this.musicName : t('car_no_track'))
            .fontSize(DesignTokens.fontHeading())
            .fontWeight(FontWeight.Bold)
            .fontColor(DesignTokens.carLabelPrimary())
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')

          Text(this.singer)
            .fontSize(DesignTokens.fontSubhead())
            .fontColor(DesignTokens.carLabelSecondary())
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
            .margin({ top: 8 })

          Blank()

          // 当前一句歌词：驾驶时不看整段，只看"正在唱哪句"
          Text(this.lyricLine.length > 0 ? this.lyricLine : this.album)
            .fontSize(DesignTokens.fontTitle())
            .fontWeight(FontWeight.Medium)
            .fontColor(DesignTokens.carLabelPrimary())
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')

          Text(this.nextLyric)
            .fontSize(DesignTokens.fontBody())
            .fontColor(DesignTokens.carLabelTertiary())
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
            .margin({ top: 6 })
            .visibility(this.nextLyric.length > 0 ? Visibility.Visible : Visibility.None)

          Blank()
        }
        .layoutWeight(54)
        .height('100%')
        .padding({ top: 10, bottom: 10 })
        .alignItems(HorizontalAlign.Start)
        .justifyContent(FlexAlign.Center)
      }
      .width('100%')
      .layoutWeight(1)
      .padding({ left: 30, right: 30 })
      .gesture(
        PanGesture({ direction: PanDirection.Horizontal, distance: SWIPE_THRESHOLD_VP })
          .onActionEnd((event: GestureEvent): void => {
            if (event.offsetX <= -SWIPE_THRESHOLD_VP) {
              this.next();
            } else if (event.offsetX >= SWIPE_THRESHOLD_VP) {
              this.prev();
            }
          })
      )

      // 进度
      Row() {
        Text(this.currentTime)
          .fontSize(DesignTokens.fontCaption())
          .fontColor(DesignTokens.carLabelTertiary())
          .width(62)
          .textAlign(TextAlign.Center)
        Slider({
          value: this.previewProgress >= 0 ? this.previewProgress : this.progress * 100,
          min: 0,
          max: 100,
          style: SliderStyle.OutSet,
        })
          .layoutWeight(1)
          .height(40)
          .blockColor(DesignTokens.accent())
          .trackColor(DesignTokens.carSurface())
          .selectedColor(DesignTokens.accent())
          .onChange((value: number, mode: SliderChangeMode): void => {
            if (mode === SliderChangeMode.Begin || mode === SliderChangeMode.Moving) {
              this.previewProgress = value;
              return;
            }
            this.commitSeek(value);
          })
        Text(this.totalTime)
          .fontSize(DesignTokens.fontCaption())
          .fontColor(DesignTokens.carLabelTertiary())
          .width(62)
          .textAlign(TextAlign.Center)
      }
      .width('100%')
      .padding({ left: 24, right: 24 })

      // 传送键
      Row({ space: 52 }) {
        this.TransportKey('prev', false)
        this.TransportKey('play', true)
        this.TransportKey('next', false)
      }
      .width('100%')
      .height(132)
      .justifyContent(FlexAlign.Center)
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(DesignTokens.carBg())
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}

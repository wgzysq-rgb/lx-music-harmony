#!/usr/bin/env python3
"""面板（弹框）形态一致性检查

踩过的坑：新加功能时很自然地手写一段
    Stack { 全屏遮罩 + 居中卡片 Column().width('86%').borderRadius(20) }
看起来「能用」，但和项目其它面板完全不是一套：
- 挂在 Scroll / 页面 Column 里会被容器裁剪（设置页点选项没反应就是这么来的）；
- 遮罩只盖住页面可视区，盖不到顶部栏；
- 居中卡片是系统对话框的观感，与「底部面板 + 左标题 + 右上角 ×」的既有约定两样。

约定：所有面板一律用 components/ui/BottomSheet（系统 bindSheet）+ SheetHeader。
因此这里钉两条：
1. 全项目只有 BottomSheet 自己（以及首次启动的全屏协议拦截）可以画 maskColor 遮罩；
2. 名字以 Sheet 结尾的面板文件必须真的用到 BottomSheet。

用法：python3 scripts/check_sheet_convention.py
"""
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent / 'entry/src/main/ets'

# 允许自绘遮罩：面板套件自身 + 首次启动协议拦截（系统级全屏，不是页面内面板）
# + components/ui/AddToTargetOverlay（选歌单浮层）。
#
# 后者是**有意的例外**：它几乎总是紧跟在动作菜单之后打开，而两个 bindSheet
# 连续开关时后一个会被前一个的收起动画一起带走（实测新面板闪一下就没）。
# 它挂在 NavIndex 顶层 Stack（不在 Scroll 里，不会被裁剪），只用条件渲染控制显隐，
# 不创建窗口，从而绕开这个时序问题。文件名因此用 Overlay 而非 Sheet。
MASK_ALLOWED = {
    'components/ui/BottomSheet.ets',
    'components/ui/AddToTargetOverlay.ets',
    'pages/NavIndex.ets',
    'theme/DesignTokens.ets',
}
MASK_PATTERN = 'maskColor()'


def main() -> int:
    problems = []
    sheets = []
    for path in sorted(ROOT.rglob('*.ets')):
        # 必须用 as_posix()：Windows 上 str(Path) 是反斜杠，与下面白名单里的
        # 正斜杠写法永远匹配不上，会让所有白名单文件被误报（曾长期存在）。
        rel = path.relative_to(ROOT).as_posix()
        text = path.read_text()
        if MASK_PATTERN in text and rel not in MASK_ALLOWED:
            problems.append(
                f'{rel}: 自绘了遮罩（{MASK_PATTERN}）—— 面板请改用 components/ui/BottomSheet')
        if path.name.endswith('Sheet.ets'):
            sheets.append(rel)
            if 'BottomSheet' not in text:
                problems.append(f'{rel}: 面板没有使用 components/ui/BottomSheet')

    print(f'面板文件 {len(sheets)} 个；自绘遮罩白名单 {len(MASK_ALLOWED)} 个')
    if problems:
        print('FAIL 面板形态不统一:')
        for p in problems:
            print(' ', p)
        return 1
    print('面板形态一致性检查通过')
    return 0


if __name__ == '__main__':
    sys.exit(main())

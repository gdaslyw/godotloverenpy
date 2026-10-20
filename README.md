# 一个视觉小说框架
致力于在 Godot 里有 Ren'Py 那样的开发体验。

## 本仓库只包含运行时核心 vn/
开发端工具 vn/dev/（含剧本编译器）、 美术 / 音频 / 字体 / Live2D 模型、示例工程都不在仓库里，clone 下来不能直接运行。

## 环境
- Godot 版本：v4.7.2-stable
- 平台：Windows、Android
- Live2D 拓展：gd_cubism 0.9.1（需自行编译）

## 最短可跑路径
- 把仓库里的 vn/ 目录复制到工程的 res:// 下
- Autoload 加 VN = res://vn/frame.gd
- 四条音频总线：Voice / Music / Sound / System
- 需要自己搭建 UI 界面并接入
- VN.start("", VN.StartMode.NEW_GAME)

## 致谢
- Ren'Py：设计参考，MIT；本项目为独立重写，未包含其源码
- gd_cubism：Live2D 后端
- Live2D：本仓库不打包 SDK / Core / 模型，使用受其协议约束

MIT © 2026 孤独爱上了夜晚，见 LICENSE。

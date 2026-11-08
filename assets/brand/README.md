# 虚拟定位 Logo

青绿色圆角底承载白色导航箭头，下面的椭圆轨道表示目标落点。图形不含文字，便于在关于面板、Dock 和菜单栏中使用。

- 色源与「修改定位」按钮一致：系统 teal。应用图标固定使用浅色外观的 teal，再生成明暗渐变，切换系统外观时图标保持一致。
- `logo.png`：1024 × 1024 透明背景图。
- `logo-preview.png`：512 × 512 预览图。
- `logo.pdf`：可缩放矢量版本。
- `AppIcon.icns` / `AppIcon.iconset/`：macOS 应用图标与各尺寸图像。

唯一绘图源为 `Sources/VirtualLocation/BrandArtwork.swift`。关于面板和菜单栏直接绘制同一套路径，菜单栏使用系统自适应的单色模板。

在项目根目录运行以下命令可重新生成图像，并构建包含新图标的应用：

```sh
sh scripts/build-app.sh
```

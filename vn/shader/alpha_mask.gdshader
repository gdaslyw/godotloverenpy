shader_type canvas_item;

// ═══════════════════════════════════════════════════════════
//  Alpha 遮罩。用另一张图的 alpha 通道裁剪当前节点，
//  对应 Ren'Py 的 AlphaMask(child, mask)。
//
//  用途：存档槽里的缩略图要裁成 sl_emtpy 那个异形轮廓，
//  而不是一块方方正正的矩形。
//
//  ── 为什么用 shader 而不是在 CPU 上裁 ──
//  CPU 侧也能做（Image.blend_rect_mask），但要先把遮罩缩放到目标尺寸、
//  再逐像素合成，而且每种显示尺寸都得重做一遍。shader 只多一次纹理采样，
//  遮罩常驻显存，控件改多大都自动适配。
//
//  ── 遮罩会被拉伸到控件大小 ──
//  采样用的是同一个 UV，所以遮罩纹理的 (0,0)-(1,1) 正好铺满控件。
//  这与原项目给 sl_emtpy 挂 zoom 2.1 的意图一致：素材本身是 451x243，
//  槽里的显示区约 924x520，那边也是"放大之后当遮罩用"。
//
//  ── 只取 alpha，不取颜色 ──
//  遮罩的 RGB 完全被忽略。换一张同形状的纯白图，效果一模一样。
//
//  ── 透明度怎么进 ──
//  fragment 的 COLOR 入口已经含了顶点色（modulate × self_modulate）与
//  默认纹理色，所以只乘 alpha 就能保留节点的 modulate。
//  u_alpha 是槽位自己的状态透明度（选中/压暗），与 modulate 相乘。
// ═══════════════════════════════════════════════════════════

/// 遮罩纹理。它的 alpha 会与被绘制内容的 alpha 相乘
uniform sampler2D u_mask : repeat_disable, filter_linear;

/// 整体透明度。与遮罩共同决定最终 alpha，默认全不透明
uniform float u_alpha : hint_range(0.0, 1.0) = 1.0;

void fragment() {
	COLOR.a *= texture(u_mask, UV).a * u_alpha;
}
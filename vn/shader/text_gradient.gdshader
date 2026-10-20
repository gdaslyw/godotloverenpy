shader_type canvas_item;

// ═══════════════════════════════════════════════════════════
//  垂直渐变。给任意 CanvasItem（Label、TextureRect…）套一层
//  「上 -> 下」的颜色渐变。
//
//  与 Ren'Py 那份 vertical.gradient 的关键差别：
//    Ren'Py 写的是 gl_FragColor *= mix(...)，是**乘**，
//    白色文字会被染成渐变，别的颜色则会和渐变相乘，得不到纯净的渐变。
//    这里改成**替换** COLOR.rgb —— 两个 uniform 是什么色，
//    画出来就是什么色，不再受原图/字体颜色影响。
//
//  代价要知道：替换之后 CanvasItem 自身的颜色（Label 的 font_color、
//  TextureRect 的 modulate 之 rgb 部分）就完全不起作用了，
//  渐变的两个颜色成为唯一来源。
//
//  COLOR.a 不参与替换，只参与乘。它同时承载两件事，直接盖成 1 会出问题：
//    1. 字形的抗锯齿覆盖率（盖掉，字边会变成硬锯齿）
//    2. CanvasItem.modulate 的透明度（盖掉，淡入淡出就失效了）
//  所以保留 COLOR.a，再乘上两个颜色 alpha 的插值 ——
//  底色的 alpha 因此就是"渐变下沿淡出到多透"的开关：
//  给 0.2，字会从上到下越来越淡、最后透出背景。
//
//  本 shader 是透明的：渐变只在被绘制的地方可见。
//  也就是说给透明背景的 Label 用时，看到的是"渐变色的字"；
//  想得到"整块矩形铺满渐变"，那是另一件事，需要一个覆盖度方案，
//  现在没有这个需求，所以不做。
// ═══════════════════════════════════════════════════════════
//
//  ── 为什么按 VERTEX.y 而不按 UV.y 算进度 ──
//  UV 看着更自然（0..1 区间），但它不是"控件内的位置"：
//    Sprite2D / TextureRect 是一整张纹理铺一个 quad，UV 恰好是 0..1；
//    Label 的文字却是从字体图集里抠字形，UV 是**字形在图集中的坐标**，
//    跟这行字在屏幕上排第几行毫无关系。
//  照 UV 算的结果是：同一字号的所有字形都落在图集同一条带上，
//  取到几乎同一个值 → 整行字混成一块单色（排查时很像"shader 没生效"）。
//  VERTEX 是节点局部坐标下的像素位置，才是真正"上 / 下"的来源。
//  代价是要有人告诉 shader 区间在哪，于是有了下面两个 uniform ——
//  它们由 VNUIEffects 按控件尺寸（Label 按文字块）算好后写进来。
// ═══════════════════════════════════════════════════════════

/// 渐变起始色（区间顶部）。alpha 一般是 1
uniform vec4 u_top_color : source_color = vec4(1.0);
/// 渐变结束色（区间底部）。alpha 决定下沿淡出到多透
uniform vec4 u_bottom_color : source_color = vec4(1.0);
/// 渐变区间的起点：节点局部坐标的 y（像素）
uniform float u_span_top = 0.0;
/// 渐变区间的长度（像素）。由调用方保证 > 0
uniform float u_span_height = 1.0;

/// 0 = 区间顶部，1 = 区间底部。由 vertex() 算出，插值后交给 fragment()
varying float v_progress;

// 顶点阶段把局部 y 换算成 0..1 的进度。
// 区间之外的顶点会被 clamp 到两端 —— 多行文字受行距影响偶尔溢出一点时，
// 宁可停在端点色，也不要让渐变在字尾"翻上去"
void vertex() {
	v_progress = clamp((VERTEX.y - u_span_top) / max(u_span_height, 0.001), 0.0, 1.0);
}

// 片元阶段：rgb 按进度插值后**替换**，a 按进度插值后**相乘**。
// 两者分开是有意的：替换 rgb 才拿得到纯净的渐变；而 a 若也替换，
// 字形抗锯齿和 modulate 的透明度就一起丢了
void fragment() {
	COLOR.rgb = mix(u_top_color.rgb, u_bottom_color.rgb, v_progress);
	COLOR.a *= mix(u_top_color.a, u_bottom_color.a, v_progress);
}

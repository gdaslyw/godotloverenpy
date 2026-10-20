shader_type canvas_item;

// ═══════════════════════════════════════════════════════════
//  雨丝。纯程序化，不需要任何贴图。
//
//  ── 为什么用 shader 而不是粒子 ──
//  Ren'Py 那边的雨是 SnowBlossom：几百个 sprite 各自算位置。Godot 里等价的
//  是 GPUParticles2D，但它需要一张雨丝贴图，而且 2560 宽的画面上要铺够密度
//  得几千个粒子 —— 贴图要美术画，粒子数还要按设备调。
//  shader 这一版没有素材依赖，每帧只付一次全屏填充，密度和长短全在 uniform 里。
//
//  ── 一根雨丝是怎么画出来的 ──
//  屏幕按列切开，每列是一根竖直的"槽"。槽内把 uv.y 做周期滚动
//  （fract(uv.y - t * speed)），取相位轴上 [0, length] 的一小段当雨丝本体，
//  两端各用一两个像素软化。列号进哈希，于是每一列的相位、速度、亮度都不同，
//  相邻列不会同步跳 —— 这是"看起来像雨"而不是"看起来像条纹窗帘"的关键。
//
//  ── 为什么列数写死 ──
//  COLUMNS 一旦变化，floor(uv.x * COLUMNS) 会把每根雨丝瞬间指派到新列，
//  画面上是整片雨同时瞬移。所以它不做成 uniform：密度靠每列的根数和
//  不透明度表达，不靠改列数。
//
//  ── 三层叠加 ──
//  远 / 中 / 近三层，速度、长度、粗细各不相同，形成景深。
//  每层两根雨丝，第二根的显现程度由 u_density 控制 —— 这就是"雨变大"时
//  密度上的变化，而不是单纯变亮。
//
//  ── 抗锯齿 ──
//  细线在 GL Compatibility 下没有 MSAA，硬边会抖。横向宽度与纵向端点都按
//  fwidth 取当前像素的覆盖范围做软化，缩放窗口时不会忽粗忽细。
// ═══════════════════════════════════════════════════════════

/// 雨丝颜色。rgb 是颜色，a 是单根雨丝的峰值不透明度
uniform vec4 u_color : source_color = vec4(1.0, 1.0, 1.0, 0.55);

/// 档位总强度。三档由 VNRain 用 tween 推到这里
uniform float u_intensity : hint_range(0.0, 2.0) = 0.8;

/// 已经下落过的距离，单位是"屏幕高度"。由 VNRain 每帧累加 delta * 速度。
///
/// ── 为什么不能直接用 TIME 乘速度 ──
/// phase = fract(uv.y - TIME * speed)。speed 一变，TIME * speed 就会整体
/// 跳一下，跳的幅度是 TIME × 速度变化量 —— 游戏跑了 100 秒之后，速度从
/// 2.0 降到 1.4 的那一秒里，d(TIME*speed)/dt 会变成约 -58，
/// 表现就是整片雨向上飞，等 tween 结束才恢复正常。
/// 累积量没有这个问题：速度变化只影响"每帧加多少"，位置始终连续
uniform float u_scroll = 0.0;

/// 雨丝倾斜。值是斜率 tan(角度)，不是角度本身 ——
/// 在 UV 里做剪切时，tan 正好等于"每往下一个屏幕高度，横向平移多少屏幕宽度"。
/// 角度到斜率的换算在 VNRain 里做，shader 只认斜率
uniform float u_slant : hint_range(-2.0, 2.0) = 0.0;

/// 雨丝长度：屏幕高度的比例
uniform float u_length : hint_range(0.01, 0.5) = 0.18;

/// 雨丝横向粗细：列宽的比例
uniform float u_width : hint_range(0.001, 0.3) = 0.08;

/// 每列第二根雨丝的显现程度。0 时只有一根，1 时两根全出
uniform float u_density : hint_range(0.0, 1.0) = 0.55;

/// 屏幕分成多少列。固定 —— 见文件头
const float COLUMNS = 120.0;

// 一维哈希。输入任意浮点，输出 0..1 的伪随机数。
// 常数取自 Dave Hoskins 的 hash 系列，够快且分布均匀
float hash11(float p) {
	p = fract(p * 0.1031);
	p *= p + 33.33;
	p *= p + p;
	return fract(p);
}

// 一层雨丝。返回该像素在这层里的亮度（0..1）。
//   seed          整层的随机源，让三层互不相关
//   scroll        已经下落的距离（屏幕高度），由 CPU 累积
//   speed_scale   相对基础速度的倍率
//   length_scale  相对 u_length 的倍率
//   width_scale   相对 u_width 的倍率
//   second_weight 第二根雨丝的权重，由 u_density 换算而来
float rain_layer(vec2 uv, float scroll, float seed, float speed_scale,
		float length_scale, float width_scale, float second_weight) {
	// 把 uv 投影到"雨丝方向"与"垂直雨丝方向"两个轴上。
	//
	// 只做 uv.x += uv.y * slant 只能让雨丝看起来变斜，相位仍沿 y 走 ——
	// 结果是斜线在垂直下滑。投影之后相位沿斜线走，雨才是斜着落的。
	// slant 为 0 时这两个式子退化成 across = uv.x、along = uv.y。
	//
	// seed 顺带把每层的列整体错开半个单元，三层才不会叠出同一根雨丝
	float inv_len = inversesqrt(1.0 + u_slant * u_slant);
	float across = (uv.x - uv.y * u_slant) * inv_len;
	float along = (uv.y + uv.x * u_slant) * inv_len;

	float col = across * COLUMNS + seed * 13.0;
	float id = floor(col);
	float fx = fract(col) - 0.5;
	float h = hash11(id + seed);

	// 横向：一条细线。边缘按 fwidth 软化，避免细线锯齿
	float w = u_width * width_scale;
	float aa = fwidth(col) * 0.5;
	float slit = 1.0 - smoothstep(w - aa, w + aa, abs(fx));

	// 纵向：周期滚动的相位。每层速度不同，每列再随机错开一点
	float len = u_length * length_scale;
	float speed = speed_scale * (0.75 + 0.5 * h);
	float soft = max(fwidth(along), 1e-5) * 1.5;
	float phase_base = along - scroll * speed + h * 17.0;

	// 第一根。相位轴上 [0, len] 是雨丝本体，两端软化
	float p1 = fract(phase_base);
	float a1 = smoothstep(0.0, soft, p1) * (1.0 - smoothstep(len - soft, len, p1));
	// 头部（相位 0 附近）更亮，尾部渐淡
	a1 *= mix(0.45, 1.0, 1.0 - smoothstep(0.0, len, p1));

	// 第二根：相位错开半屏，所以它总在第一根的间隙里
	float p2 = fract(phase_base + 0.5);
	float a2 = smoothstep(0.0, soft, p2) * (1.0 - smoothstep(len - soft, len, p2));
	a2 *= mix(0.45, 1.0, 1.0 - smoothstep(0.0, len, p2));

	return slit * (a1 + a2 * second_weight);
}

void fragment() {
	float scroll = u_scroll;
	float d = u_density;

	// 远景：细、慢、短，第二根很早就冒出来（离得远，本来就看不清单根）
	float band_far = rain_layer(UV, scroll, 3.1, 0.70, 0.75, 0.60, smoothstep(0.00, 0.45, d));
	// 中景
	float band_mid = rain_layer(UV, scroll, 7.7, 1.00, 1.00, 1.00, smoothstep(0.05, 0.65, d));
	// 近景：粗、快、长，数量最少，只有大雨时才补上第二根
	float band_near = rain_layer(UV, scroll, 13.3, 1.45, 1.40, 1.60, smoothstep(0.40, 0.95, d));

	float a = band_far * 0.35 + band_mid * 0.55 + band_near * 0.30;

	// COLOR 进来时已经含了 modulate（转场靠它做淡入淡出），所以只覆盖 rgb、
	// 把 alpha 乘进去。直接赋值会把 modulate 丢掉，with dissolve 就不灵了
	COLOR.rgb = u_color.rgb;
	COLOR.a = u_color.a * clamp(a, 0.0, 1.0) * u_intensity * COLOR.a;
}

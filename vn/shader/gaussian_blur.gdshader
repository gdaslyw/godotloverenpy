shader_type canvas_item;

// ═══════════════════════════════════════════════════════════
//  高斯模糊。屏幕空间 —— 糊的是"自己下方已经画完的一切"，
//  而不是自己这张贴图。
//
//  这个区别是本 shader 存在的唯一理由：单个 CanvasItem 的 shader
//  只能拿到它自己绘制的那张纹理，糊不了"背景 + 立绘 + 特效"这种组合，
//  只有屏幕纹理拿得到。所以它的用法不是"挂在某个节点上"，而是
//  **往场景树里插一层**：
//
//      背景 → 【本层】 → 立绘 → 对话框
//
//  层插在谁后面，就糊谁。只想糊背景，就插在背景和立绘之间。
//
//  算法与 Ren'Py 的 blur 变换属性一致（renpy.blur 这个 shader part
//  的源码在离线文档 shader_parts.html 里是公开的）：不做多 pass 卷积，
//  而是借硬件的 mipmap 链，一个 pass 采样十几个层级，第 i 层的权重取
//
//      exp(-0.5 * (log2(blur) - i)^2)
//
//  最后除以权重和。mipmap 第 i 层的每个 texel 覆盖 2^i 见方，所以权重
//  峰值落在 i = log2(blur) 时，糊出来正好是 blur 像素 —— blur 4 的峰值
//  在 lod 2，代价是 7 次采样，而不是半径 4 的 81 次。
//
//  唯一的硬性前提是 filter 必须带 mipmap。文档对此有专门的警告：
//  filter 名字里没有 mipmap 时，textureLod 传大于 0 的 lod 与传 0
//  外观完全相同 —— 效果会静默退化成"什么都没做"，且不报任何错。
// ═══════════════════════════════════════════════════════════

// 屏幕纹理。repeat_disable 让出界的采样取边缘像素而不是回卷，
// 否则画面四周会把对边的内容卷进来，糊出一圈鬼影
uniform sampler2D screen_texture : hint_screen_texture, repeat_disable, filter_linear_mipmap;

/// 模糊半径，单位像素。0 表示不模糊
uniform float u_blur = 4.0;

// 高斯权重偏离中心多少层之后截断。偏离 5 层时权重已经不足千分之一，
// 再往外采是白费。Ren'Py 用的也是 5
const float TAIL = 5.0;

// 循环的编译期上界。屏幕纹理不会有这么多层级，它只是让循环定长；
// 真正的退出条件是上面的 TAIL
const int MAX_LOD = 14;

void fragment() {
	if (u_blur <= 0.0) {
		// 半径 0：原样输出。这是保险 —— GDScript 那边在 blur 为 0 时
		// 会把整层藏掉，正常流程走不到这里
		COLOR = textureLod(screen_texture, SCREEN_UV, 0.0);
	} else {
		float center = log2(u_blur);
		vec4 acc = vec4(0.0);
		float weight_sum = 0.0;

		// 第 0 层要额外吸收"负数层级"的权重。
		// 半径不足 1 像素时 center 落在 0 与 1 之间，按公式该往 -1、-2
		// 这些层上分权重，可 mipmap 没有负数层，只能全部折进第 0 层。
		// Ren'Py 把这一段单独写成定长循环，就是为了这件事
		for (int i = -5; i < 1; i++) {
			float d = center - float(i);
			weight_sum += exp(-0.5 * d * d);
		}
		acc += weight_sum * textureLod(screen_texture, SCREEN_UV, 0.0);

		// 第 1 层往上逐个取权重。越过高斯尾部就停 ——
		// 更高的层级权重已经可以忽略，继续取只会把画面糊成一片色块
		for (int i = 1; i < MAX_LOD; i++) {
			if (float(i) >= center + TAIL) {
				break;
			}
			float d = center - float(i);
			float w = exp(-0.5 * d * d);
			acc += w * textureLod(screen_texture, SCREEN_UV, float(i));
			weight_sum += w;
		}

		// 归一化。weight_sum 恒大于 0（第 0 层那一段至少含 i = 0 一项），
		// 不必防零
		COLOR = acc / weight_sum;
	}
}
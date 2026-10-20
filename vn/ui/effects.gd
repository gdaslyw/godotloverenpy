class_name VNUIEffects

# ═══════════════════════════════════════════════════════════
#  通用 UI 效果。目前两项：垂直渐变、alpha 遮罩。
#
#  放在 vn/ui/ 是因为它们跟具体作品无关 —— 任何一部作品都可能想让
#  标题带上渐变、想让缩略图裁成异形，而 shader 本身怎么用、材质怎么
#  复用属于框架的事，调用方只该关心"给哪个节点、用什么素材"。
# ═══════════════════════════════════════════════════════════

## 垂直渐变 shader。同目录，随本脚本一起进框架
const GRADIENT_SHADER := preload("res://vn/shader/text_gradient.gdshader")

## alpha 遮罩 shader。用途见 apply_alpha_mask()
const ALPHA_MASK_SHADER := preload("res://vn/shader/alpha_mask.gdshader")

## 只在编辑器里额外检查颜色参数是否写错。运行时不查 ——
## 那种情况下能省一次类型判断，而参数在开发期就会被撞出来
const DEBUG_CHECK := true

###########################################################

## 给一个 CanvasItem 套上垂直渐变，颜色分量**替换**而非相乘。
##
## top / bottom 可以是 Color，也可以是 "#fff"、"#5A4B78"、"#5A4B7888"
## 这类 HTML 颜色码字符串，长度 3 / 4 / 6 / 8 位都认。
##
## 重复调用是安全的：已经有本 shader 的材质就只改颜色，不会每调一次
## 就多堆一个 ShaderMaterial 上去 —— 界面重建、热重载都会反复走到这里。
##
## 注意替换语义带来的后果：套上之后，这个节点自身的颜色
## （Label 的 font_color、TextureRect 的 modulate 的 rgb 部分）就不再起作用，
## 看到的就是这两个颜色之间的渐变。透明度仍受 modulate.a 控制
##
## 渐变范围（从哪一行到哪一行）由这里自己算，调用方不用管：
## 普通控件用整个 size，Label 用文字块的实际高度 —— 原因见 _gradient_span()
static func apply_vertical_gradient(target: CanvasItem, top: Variant,
		bottom: Variant) -> void:
	if target == null:
		push_error("VNUIEffects：target 为空，垂直渐变没有应用")
		return

	var top_color := _to_color(top, "top")
	var bottom_color := _to_color(bottom, "bottom")

	# 复用已有的材质。判定方式是"材质的 shader 就是本 shader"，
	# 而不是"材质不为空" —— 节点上可能已经挂了别的效果，
	# 那种情况下不该把人家覆盖掉，宁可不去动它
	var material := _ensure_material(target, GRADIENT_SHADER, "垂直渐变")
	if material == null:
		return

	# 参数名必须和 shader 里的 uniform 逐字一致（区分大小写）
	material.set_shader_parameter("u_top_color", top_color)
	material.set_shader_parameter("u_bottom_color", bottom_color)

	# 区间先写一次，再挂 resized 持续同步。
	# 之所以不能只写一次：调用点基本都在 _ready 里，那一刻 Label 还没布局，
	# size 是 0 —— 区间会算成 1 像素高，整行字全挤在渐变的一端
	_refresh_gradient_span(target, material)
	_hook_gradient_resize(target)

## 给一个 CanvasItem 套上 alpha 遮罩。
##
## 遮罩的 alpha 会与被绘制内容的 alpha 相乘，用来做异形裁剪 ——
## 对应 Ren'Py 的 AlphaMask(child, mask)。遮罩会被拉伸到控件大小，
## 所以同一张遮罩能给任意尺寸的槽位用，不必按尺寸准备多份。
##
## 重复调用是安全的：已经有本 shader 的材质就只换遮罩纹理。
## 槽位复用同一个 TextureRect 显示不同存档的缩略图时会反复走到这里
static func apply_alpha_mask(target: CanvasItem,
		mask_texture: Texture2D) -> void:
	if target == null:
		push_error("VNUIEffects：target 为空，alpha 遮罩没有应用")
		return
	if mask_texture == null:
		push_error("VNUIEffects：遮罩纹理为空，alpha 遮罩没有应用")
		return

	var material := _ensure_material(target, ALPHA_MASK_SHADER, "alpha 遮罩")
	if material == null:
		return

	# 参数名必须和 shader 里的 uniform 逐字一致（区分大小写）
	material.set_shader_parameter("u_mask", mask_texture)

## 给任意一条滚动条套上"只有滑块、没有底槽"的皮肤。
##
## 对应原项目 vpgrid 上那一组属性：vscrollbar_base_bar Null()（底槽不画）、
## vscrollbar_thumb "sl_thumb"。
##
## 滚动条由 VNViewport 持有并交给页面，所以这里拿到的是一条普通的
## VScrollBar / HScrollBar，不再有"内部条"和"外部条"的分别
##
## ── 宽度必须显式给死，这是个踩过的坑 ──
## 不给的话，滚动条宽度会一路退化成 0：
##   VScrollBar 的最小宽度 = max(底槽的最小宽度, 滑块的最小宽度)
##   底槽是 StyleBoxEmpty                     → 0
##   滑块是 StyleBoxTexture，它的最小宽度算的是
##   texture_margin_left / right 里较大的那个  → 默认值就是 0
## 结果是"滚动条存在、也 visible，但宽度为 0"：内容能滚，却什么都看不见。
## 所以调用方必须同时设 bar.custom_minimum_size（见各页面的说明）
static func style_scroll_bar(bar: ScrollBar, thumb: Texture2D) -> void:
	if bar == null:
		return

	if thumb != null:
		var grabber := StyleBoxTexture.new()
		grabber.texture = thumb
		# ── 九宫格切分 ──
		# sl_thumb 是个圆角胶囊：上下各一个半圆端头，中段是纯色。
		# 整图拉伸会把那两个半圆抻成椭圆，看起来就是"滑块被扯变形了"。
		# 切法：上下各留 5 像素不参与拉伸（胶囊宽 9，半径 4.5，取 5 保证
		# 把圆弧整个包住），中间剩下的随便伸缩 —— 那一段是纯色。
		# 左右不切：滑块宽度固定就是 9，和素材同宽，本来就没有拉伸可言
		grabber.texture_margin_left = 0.0
		grabber.texture_margin_right = 0.0
		grabber.texture_margin_top = 5.0
		grabber.texture_margin_bottom = 5.0

		bar.add_theme_stylebox_override("grabber", grabber)
		bar.add_theme_stylebox_override("grabber_highlight", grabber)
		bar.add_theme_stylebox_override("grabber_pressed", grabber)

	# 底槽留空：原项目 vscrollbar_base_bar Null()，只有滑块、没有槽。
	# 三档一起清掉，否则拿到焦点时默认样式的槽会突然冒出来
	bar.add_theme_stylebox_override("scroll", StyleBoxEmpty.new())
	bar.add_theme_stylebox_override("scroll_focus", StyleBoxEmpty.new())

###########################################################
#  内部
###########################################################

## 把调用方传来的颜色参数规范化成 Color。
##
## 非法的字符串会 push_error 并退回白色，而不是让 Color.from_string
## 静默返回黑色 —— 那种失败在深色界面上看着就像"这个控件没画出来"，
## 和真正的漏画混在一起，很难查
static func _to_color(value: Variant, which: String) -> Color:
	if value is Color:
		return value

	if value is String:
		var code := value as String
		if not Color.html_is_valid(code):
			push_error("VNUIEffects：%s 不是合法的颜色码：\"%s\"（退回白色）"
				% [which, code])
			return Color.WHITE
		return Color(code)

	push_error("VNUIEffects：%s 只接受 Color 或颜色码字符串，收到 %s（退回白色）"
		% [which, type_string(typeof(value))])
	return Color.WHITE

## 取节点上可以给这个 shader 用的材质，没有就建一个。
##
## 判定"能不能复用"的依据是"材质的 shader 就是这一个"，而不是
## "材质不为空"：节点上可能已经挂着别的效果，那不该被静默覆盖 ——
## 两个 shader 叠在一起会互相打架，而排查时又看不出是谁盖了谁。
##
## 返回 null 表示这个节点上已有别的材质，本次不应用
static func _ensure_material(target: CanvasItem, shader: Shader,
		what: String) -> ShaderMaterial:
	var material := target.material as ShaderMaterial
	if material != null and material.shader == shader:
		return material

	if target.material != null:
		if DEBUG_CHECK:
			push_warning("VNUIEffects：%s 上已有别的材质，%s 未应用"
				% [target.name, what])
		return null

	material = ShaderMaterial.new()
	material.shader = shader
	target.material = material
	return material

## 算出渐变区间在节点局部坐标里的位置，返回 Vector2(top, height)。
##
## 默认取整块控件的高度。Label 例外：布局经常把它撑得比文字高
## （比如 960×60 的框里放 36 号字，行高才 47），若按控件高归一化，
## 渐变会有一大截摊在上下空白上，文字只吃到中间一段，看着"没渐变到底"。
## 所以 Label 按文字块的实际高度取区间，并按 vertical_alignment 摆正。
##
## 拿不到尺寸（还没布局、非 Control 节点）时退回 1 像素，
## 免得 shader 里那句 max(u_span_height, 0.001) 除出个巨大的比值
static func _gradient_span(target: CanvasItem) -> Vector2:
	var height := 1.0
	if target is Control:
		height = (target as Control).size.y
	if height <= 0.0:
		height = 1.0

	if target is Label:
		var label := target as Label
		var text_height := _label_text_height(label)
		# 文字比控件还高（被裁切）时不收窄：那种情况算出来的 top 是负数，
		# 渐变会从控件外面开始，反而不对
		if text_height > 0.0 and text_height <= height:
			var top := 0.0
			if label.vertical_alignment == VERTICAL_ALIGNMENT_CENTER:
				top = (height - text_height) * 0.5
			elif label.vertical_alignment == VERTICAL_ALIGNMENT_BOTTOM:
				top = height - text_height
			return Vector2(top, text_height)

	return Vector2(0.0, height)

## 量一个 Label 的文字块高度（像素）。
##
## get_line_height() 不含行间距，多行时要自己补上 line_spacing ——
## 现在的标题都是单行，这条分支用不上，但留着免得以后换成两行标题时
## 渐变区间比文字矮一截
static func _label_text_height(label: Label) -> float:
	var lines := label.get_line_count()
	if lines <= 0:
		return 0.0

	var total := 0.0
	for i in lines:
		total += float(label.get_line_height(i))

	if lines > 1:
		total += float(label.get_theme_constant("line_spacing")) * float(lines - 1)

	return total

## 把当前区间写进材质。参数名必须与 shader 里的 uniform 逐字一致
static func _refresh_gradient_span(target: CanvasItem,
		material: ShaderMaterial) -> void:
	var span := _gradient_span(target)
	material.set_shader_parameter("u_span_top", span.x)
	material.set_shader_parameter("u_span_height", span.y)

## 让渐变区间在尺寸或文字变化时自动重算。
##
## 只在 Control 上挂：resized 是 Control 的信号，CanvasItem 本身没有。
## 挂过的用 meta 记一笔，重复 apply（界面重建、热重载都会反复走到）
## 不会再连一堆同一个目标的连接 —— 那不算错，但每次尺寸变化都要跑好几遍
##
## Label 还要多连一条 minimum_size_changed：它的 size 常常是外面硬给的
## （比如 960×60 的框放一行字），换文字时 size 一动不动，resized 不会响；
## 而文字块高度变了、渐变区间就该跟着变
static func _hook_gradient_resize(target: CanvasItem) -> void:
	if not target is Control:
		return

	var control := target as Control
	if control.has_meta(&"vn_gradient_resize_hook"):
		return

	control.set_meta(&"vn_gradient_resize_hook", true)
	control.resized.connect(_on_gradient_target_resized.bind(control))

	if control is Label:
		(control as Label).minimum_size_changed.connect(
			_on_gradient_target_resized.bind(control))

## 尺寸或文字块变化后的回调：重算渐变区间。
##
## 材质是从节点上现取的，不是 bind 进来的 —— 中间要是有人换过材质，
## 拿旧引用写参数只会写到一份已经没人引用的材质上
static func _on_gradient_target_resized(control: Control) -> void:
	var material := control.material as ShaderMaterial
	if material == null or material.shader != GRADIENT_SHADER:
		return
	_refresh_gradient_span(control, material)

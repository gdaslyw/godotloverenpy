class_name VNSlider
extends Range

# ═══════════════════════════════════════════════════════════
#  通用滑块。对标 Ren'Py 的 bar。
#
#  ── 和 Godot 原生 HSlider 的差别，和 VNButton 之于 Button 是同一处 ──
#
#  外观完全由三张图决定，一档一张路径，不做 theme / StyleBox 那一套。
#  对应 Ren'Py 的 left_bar / right_bar / thumb：
#    track_filled  已填充的轨道，按比例只画左边那一段
#    track_empty   未填充的轨道，整条铺满打底
#    thumb         滑块本身
#  某一档留空就是不画那一档 —— 调用方只关心"我要它长什么样"。
#
#  ── 为什么不用 HSlider ──
#
#  HSlider 的轨道是 StyleBox、滑块是 theme icon。想让它长得跟原项目那张
#  874x50 的图一样，得把图切九宫格、再算 grabber_offset 抵掉滑块自身的
#  宽度 —— 算出来的结果还不如直接按像素画准。而且 HSlider 自带键盘焦点
#  框和 theme 那套，这个界面一样都用不上；本类的焦点视觉自己画，
#  方向键增量也自己接（见 _gui_input）。
#
#  ── 写盘时机 ──
#
#  拖动过程中每变一次值都发 Range 自带的 value_changed，但**不写盘**。
#  松手那一刻才发 vn_released，调用方在那时调 save_config()。
#  音量这类要边拖边听的，靠前者实时生效；靠后者避免拖一下写十几遍文件。
# ═══════════════════════════════════════════════════════════

###########################################################
#  信号
###########################################################

## 松开鼠标。值可能变了也可能没变，调用方自己比对后决定要不要写盘 ——
## 本类不知道"写盘"这回事，它只管报告"这一轮拖动结束了"
signal vn_released

###########################################################
#  外观
###########################################################

## 已填充轨道的图。对应 Ren'Py 的 left_bar
@export_file("*.png") var track_filled := ""

## 未填充轨道的图。对应 Ren'Py 的 right_bar
@export_file("*.png") var track_empty := ""

## 滑块的图。对应 Ren'Py 的 thumb
@export_file("*.png") var thumb := ""

## 滑块中心在两端能走到哪。对应 Ren'Py 的 left_gutter / right_gutter。
##
## 默认 0 表示"能到极限"：比例值为 0 时中心贴控件左边缘、为 1 时贴右边缘，
## 滑块有一半会露到控件外面。要往内收就调大这两个值 —— 原项目两边都设了 15，
## 那是为了让滑块整块留在轨道里
@export var left_gutter := 0.0
@export var right_gutter := 0.0

## 滑块中心相对值的额外偏移。对应 Ren'Py 的 thumb_offset。
## 两边微调不够用时用它整体平移
@export var thumb_offset := 0.0

## 是否参与键盘焦点导航。
##
## 默认关：项目里其他滑块（音乐进度条之类）仍只认鼠标。设置页把它打开，
## 焦点停在滑块上时左右键调值、上下键交给引擎移到相邻控件。
@export var keyboard_focus := false:
	set(value):
		keyboard_focus = value
		_sync_focus_mode()

###########################################################
#  内部
###########################################################

## 现在是不是正按着左键拖
var _dragging := false

## 键盘方向键是不是正在连续调值（按下后还没松开）。
##
## 长按方向键会持续产生 echo 事件，每一下都写盘会把设置页卡住。
## 所以调值时只标记，等松开（或焦点被移走）再发一次 vn_released。
var _key_adjusting := false

## 路径 → 纹理。三张图在整个生命周期里不会变，查一次就够
var _textures: Dictionary = {}

###########################################################

func _init() -> void:
	# 在这里接而不是 _ready()：value 可能在入树之前就被调用方设好，
	# 那一次同样需要重绘。信号连接本身不依赖入树
	value_changed.connect(_on_value_changed)
	changed.connect(queue_redraw)

func _ready() -> void:
	# 输入模式在 gui_get_hovered_control() 查不到时会遍历这个组，
	# 按矩形兜底找"鼠标下的滑条"
	add_to_group(&"vn_sliders")
	# VNFocus 切换当前焦点时通过这个组通知重画
	add_to_group(&"vn_focus_visuals")

	# STOP 而不是 PASS：滑块要把落在自己身上的点击吃掉，
	# 否则会漏到底下的台词界面去推进剧情
	mouse_filter = Control.MOUSE_FILTER_STOP

	# 光标形状**故意不设**，保持 CURSOR_ARROW 的默认值。
	#
	# 常识里滑块该配 CURSOR_POINTING_HAND，但本项目在 project.godot 里
	# 配了 mouse_cursor/custom_image —— 默认箭头已经被换成了一张自定义图。
	# 一旦给某个控件设成别的手型，引擎会切回系统光标，表现就是
	# "鼠标移到滑条上，自定义光标凭空消失，变回一只系统小手"。
	# 想让滑块也有专属光标，正路是给项目换图，不是在这里改 enum

	# 焦点模式由 keyboard_focus 决定，默认仍是 FOCUS_NONE。
	#
	# 打开时也不会有引擎默认的虚线框：本类自绘 _draw()，不画 theme 的
	# focus 样式；焦点视觉是滑块下面那圈柔光（见 _draw）。
	focus_entered.connect(_on_focus_entered)
	focus_exited.connect(_on_focus_exited)
	_sync_focus_mode()

	# 鼠标移到滑条上时先拿一个隐藏焦点。
	#
	# 目的是让"鼠标停在滑条上按方向键"有一个确定的落脚点：VNInputMode
	# 在方向键按下时会先看当前焦点，再看鼠标位置；这两条都失效时才会
	# 退回界面默认首项（就是焦点跑侧边栏/窗口大小那一组的原因）。
	#
	# 只在当前完全没有焦点时拿：键盘导航中鼠标恰好扫过滑条，不该把
	# 焦点从按钮上抢走。
	mouse_entered.connect(_on_mouse_entered)
	mouse_exited.connect(_on_mouse_exited)

	# 输入模式切换时重画：键盘模式下焦点光晕才是唯一的高亮来源，
	# 鼠标模式下焦点已经被清掉，不该继续亮
	if VN.input_mode != null:
		VN.input_mode.mode_changed.connect(_on_input_mode_changed)

## 按 keyboard_focus 同步原生焦点模式。
##
## 滑块没有 disabled 这一档，可用性由调用方自己决定；这里只区分
## "参不参与键盘导航"。
func _sync_focus_mode() -> void:
	focus_mode = Control.FOCUS_ALL if keyboard_focus else Control.FOCUS_NONE

## 输入模式切换。滑块没有 hover 视觉，只关心焦点光晕还在不在
func _on_input_mode_changed(_mode: int) -> void:
	queue_redraw()

## 按一个步长调值。键盘左右键走这里。
##
## **不在这里发 vn_released**：长按方向键的 echo 会一秒触发几十次，
## 每一下都让设置页写盘会把界面卡住。这里只标记"正在键盘调值"，
## 松开时（或焦点被移走时，见 _on_focus_exited）统一补发一次。
func _step_value(direction: float) -> void:
	var delta := step if step > 0.0 \
		else maxf((max_value - min_value) / 100.0, 0.0001)
	set_value(clampf(value + direction * delta, min_value, max_value))
	_key_adjusting = true

## 焦点进入。有作用域时反向同步逻辑焦点（Tab/grab_focus 路径）
func _on_focus_entered() -> void:
	if VNFocus.has_scope() and has_focus(true):
		VNFocus.adopt(self)
	queue_redraw()

## VNFocus 切换当前焦点后由组通知重画
func _refresh_focus_visuals() -> void:
	queue_redraw()

## 焦点离开。键盘调值还没等到松开时，补发一次 vn_released，
## 避免设置页漏写盘；同时重画，把焦点光晕收掉。
func _on_focus_exited() -> void:
	if _key_adjusting:
		_key_adjusting = false
		vn_released.emit()
	queue_redraw()

## 鼠标移到滑条上：当前没有任何焦点时，先拿一个隐藏焦点。
##
## 只拿隐藏焦点（hide_focus=true），不显示 —— 鼠标模式下按钮/滑条都不看
## 焦点外观，滑条不该因为鼠标扫过就亮起键盘光晕。等玩家真按方向键，
## VNInputMode 会把它显示出来，并把这次按键放行给 _gui_input() 调值。
##
## 只在焦点为空时拿：键盘导航中鼠标恰好扫过滑条，不该把焦点从按钮上抢走。
func _on_mouse_entered() -> void:
	if not keyboard_focus:
		return
	# 悬停立刻同步逻辑焦点；mouse_entered 晚于 VNInputMode 的 hover 查询
	if VNFocus.has_scope():
		VNFocus.adopt(self)
	if get_viewport().gui_get_focus_owner() != null:
		return
	grab_focus(true)

## 鼠标移出：如果当前焦点是本滑条，立刻熄灭光晕
func _on_mouse_exited() -> void:
	if VNFocus.has_scope():
		VNFocus.clear_if_current(self)

###########################################################
#  输入
###########################################################

## 按下即跳到该点、拖动跟随、松手发 vn_released。
##
## 按下那一下也立刻设值，是 Ren'Py bar 的行为 —— 点轨道中间就直接跳过去，
## 不必先按住再拖。只有左键有意义
func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index != MOUSE_BUTTON_LEFT:
			return
		if event.pressed:
			_dragging = true
			_set_from_x(event.position.x)
			accept_event()
		elif _dragging:
			_dragging = false
			accept_event()
			vn_released.emit()
		return

	if event is InputEventMouseMotion and _dragging:
		_set_from_x(event.position.x)
		accept_event()
		return

	# 键盘。焦点在本滑块上才会收到（Control 的键盘分发只给焦点控件）。
	# 左右调值，上下不接 —— 留空给 Viewport 的焦点导航，于是上下键
	# 移到相邻控件，左右键留在本控件里。
	#
	# is_action_pressed 的第二个参数 **必须传 true**（allow_echo）：
	# 长按方向键时，第一次按下之后全是 echo 事件；默认 allow_echo=false
	# 会把 echo 当成"没按"，滑条不 accept_event，Viewport 的焦点导航
	# 接手，焦点就从滑条跑掉了。这正是"长按右焦点跑侧边栏"的原因。
	if event is InputEventKey:
		if event.is_action_pressed("ui_left", true) \
				or event.is_action_pressed("ui_right", true):
			var direction := -1.0 if event.is_action_pressed("ui_left", true) else 1.0
			_step_value(direction)
			# 吃掉，别让焦点导航把这次左右键也当成移动
			accept_event()
		elif event.is_action_released("ui_left") or event.is_action_released("ui_right"):
			# 松开也吃掉：否则松开那一下会触发焦点导航，焦点从滑块上跑掉
			accept_event()
			if _key_adjusting:
				_key_adjusting = false
				vn_released.emit()

## 把鼠标的横坐标换算成值。
##
## 反着走一遍 _thumb_center() 的公式：先扣掉两端留白和偏移，
## 剩下的那一段才是值真正能走动的距离。
##
## 可走距离 <= 0 时直接返回：控件还没被布局（size 为 0）时会出现这种情况，
## 此时算出来的比例没有意义，硬除会得到 inf
func _set_from_x(x: float) -> void:
	var span := size.x - left_gutter - right_gutter
	if span <= 0.0:
		return

	var at := clampf((x - left_gutter - thumb_offset) / span, 0.0, 1.0)
	set_value(min_value + (max_value - min_value) * at)

###########################################################
#  绘制
###########################################################

## 三层从下往上：空轨道、填充轨道、滑块。
##
## 轨道图的高度往往小于控件高度（原项目是 50 对 100），一律垂直居中 ——
## 那是 Ren'Py bar 的做法，也是"图比框矮"时唯一说得通的摆法
func _draw() -> void:
	var center_y := size.y * 0.5

	var empty := _texture(track_empty)
	if empty != null:
		var h := empty.get_height()
		draw_texture_rect(empty, Rect2(0.0, center_y - h * 0.5, size.x, h), false)

	var at := _value_ratio()
	var filled := _texture(track_filled)
	if filled != null:
		# 填充到滑块中心为止。裁的是源矩形，所以图不会被压扁
		var w := minf(_thumb_center(at), filled.get_width())
		if w > 0.0:
			var h := filled.get_height()
			draw_texture_rect_region(filled,
				Rect2(0.0, center_y - h * 0.5, w, h),
				Rect2(0.0, 0.0, w, h))

	var thumb_tex := _texture(thumb)
	if thumb_tex != null:
		var tw := thumb_tex.get_width()
		var th := thumb_tex.get_height()
		var center := Vector2(_thumb_center(at), center_y)
		var lit := VNFocus.is_current(self) if VNFocus.has_scope() \
			else has_focus(true)

		# 焦点视觉：滑块下面一圈柔光。没有现成的焦点素材，用几何图形画，
		# 不依赖任何一张图。只看非隐藏焦点 —— 鼠标点出来的焦点不亮，
		# 否则点过一次滑块就永远带着一圈光。
		if lit:
			draw_circle(center, th * 0.72, Color(1.0, 0.96, 1.0, 0.20))

		draw_texture_rect(thumb_tex,
			Rect2(center - Vector2(tw, th) * 0.5, Vector2(tw, th)),
			false,
			Color(1.06, 1.06, 1.06, 1.0) if lit else Color.WHITE)

## 值在 [min, max] 里的位置，0 到 1。
##
## 名字刻意不叫 ratio：Range 基类已经有一个同名属性（value 的归一化版本），
## 这里再声明一个就会遮蔽它，Godot 会报 SHADOWED_VARIABLE_BASE_CLASS。
## 语义上两者其实一致，区别只在本函数显式挡了上下限相等的情况 ——
## 基类那边除零后是 0 还是 nan，不值得为省一个函数去赌
func _value_ratio() -> float:
	var span := max_value - min_value
	if span <= 0.0:
		return 0.0
	return clampf((value - min_value) / span, 0.0, 1.0)

## 某个比例下滑块**中心**的横坐标。参数叫 at 而不叫 ratio，同上
func _thumb_center(at: float) -> float:
	return left_gutter + (size.x - left_gutter - right_gutter) * at \
		+ thumb_offset

## 取一张图。路径为空或文件不存在时返回 null，由绘制那边按"不画"处理 ——
## 某一档没配图不是错误，是合法的外观选择（和 VNButton 一个规矩）
func _texture(path: String) -> Texture2D:
	if path.is_empty():
		return null
	if not _textures.has(path):
		_textures[path] = load(path) if ResourceLoader.exists(path) else null
	return _textures[path] as Texture2D

## 值变了就重绘。不做缓动 —— 滑块跟手比顺滑重要，
## 手停在哪滑块就该停在哪
func _on_value_changed(_to: float) -> void:
	queue_redraw()

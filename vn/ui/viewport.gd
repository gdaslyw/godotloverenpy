class_name VNViewport
extends Control

# ═══════════════════════════════════════════════════════════
#  视口组件：一个可滚动的区域，加它自己那几条滚动条。
#
#  ── 为什么不是一个 ScrollContainer 子类 ──
#  Godot 的 ScrollContainer 把滚动条焊在内部，而且 clip_contents 为真 ——
#  想把条摆到列表外面（原项目的音乐鉴赏就是摆在左侧），只能关掉自带那条、
#  另起一条自己同步。这正是 extra_music.gd 原先那段五十来行代码在做的事。
#  滚动条既然是"这个视口的一部分"，就该由视口自己持有。
#
#  ── 对应 Ren'Py 的 viewport ──
#  属性名直接沿用那边：draggable / mousewheel / scrollbars / xinitial /
#  yinitial（见 renpy/display/viewport.py:85-96 与 doc/screens.html）。
#  那边还有 arrowkeys、pagekeys，以及 mousewheel 的 "change" 取值，
#  本项目用不到，没有实现。
#
#  ── 节点结构 ──
#    VNViewport (Control)
#    ├─ Scroll  (ScrollContainer)   内容放这里，自带的滚动条一律不画
#    ├─ HBar    (HScrollBar)        scrollbars 含 "horizontal" 才有
#    └─ VBar    (VScrollBar)        scrollbars 含 "vertical" 才有
#
#  条的位置与尺寸默认由本组件摆（贴右/下边缘，粗细取条自己的
#  custom_minimum_size）；需要自己摆的页面把 auto_place_bars 关掉。
#
#  ── 滚动条的值怎么来 ──
#  **不抄 ScrollContainer 内部那条**。extra_music.gd 原先那段注释记下了
#  两个坑：内部条要等布局算完才有值，_ready() 里读到的是 0；靠它的
#  changed 信号补同步也不可靠。这里按"内容容器的合并最小尺寸 / 视口尺寸"
#  自己算，每帧都拿得到，不依赖任何一次性的信号。
# ═══════════════════════════════════════════════════════════

## 内部 ScrollContainer 的节点名。页面可以在 .tscn 里直接声明它，
## 好把内容节点写在它下面；不声明就由本组件建一个
const SCROLL_NAME := "Scroll"

## 点击与拖拽的分界距离（像素）。超过它才算拖拽，松手时那次点击要被挡掉。
## 与原先散在四个界面里的那个值保持一致
const DRAG_THRESHOLD := 8.0

## 滚轮一格滚多少像素。只在 mousewheel 为 "horizontal" 时用得上 ——
## true 那条路交给 ScrollContainer 原生处理，这里的值不参与
const WHEEL_STEP := 80

## 要哪几条滚动条，取值照 Ren'Py：
##   ""           竖向可滚，不画条（最常见的列表）
##   "vertical"   竖向可滚，画一条竖条
##   "horizontal" 横向可滚，画一条横条
##   "both"       两向都可滚，两条都画
##
## 没画条的那些轴**不是关掉滚动**，是"能滚但不显示条"（SHOW_NEVER）——
## 拖拽和滚轮照样有效果，只是看不见滑块
@export var scrollbars := "":
	set = set_scrollbars

## 拖动滚动。对应 Ren'Py viewport 的 draggable
@export var draggable := true

## 条的位置尺寸由本组件摆。要自己摆的页面关掉它
@export var auto_place_bars := true

## 初始滚动位置。对应 Ren'Py 的 xinitial / yinitial：
## 0.0 是最前，1.0 是最后。**只支持比例** —— Ren'Py 那边写整数是像素、
## 写小数是比例，GDScript 一个类型化变量没法同时表达两种
@export var xinitial := 0.0
@export var yinitial := 0.0

## 滚轮行为。对应 Ren'Py viewport 的 mousewheel，取值：
##   false         吞掉滚轮，不响应
##   true          交给 ScrollContainer 原生处理（竖向）
##   "horizontal"  吞掉竖向滚轮，改成横向滚
var mousewheel: Variant = true

## 内部滚动容器。内容都放在它下面
var scroll: ScrollContainer = null

## 竖条与横条。scrollbars 里没要的那条为 null
var vertical_bar: VScrollBar = null
var horizontal_bar: HScrollBar = null

## 内容根节点。用来算滚动条的范围 —— 传进来的那个、或 Scroll 的第一个子节点
var content: Control = null

## 当前滚动位置。转发给内部 ScrollContainer ——
## 页面不必知道自己拿的是一个复合容器还是裸的 ScrollContainer
var scroll_vertical: int:
	get:
		return scroll.scroll_vertical if scroll != null else 0
	set(value):
		if scroll != null:
			scroll.scroll_vertical = value

## 当前横向滚动位置。说明同上
var scroll_horizontal: int:
	get:
		return scroll.scroll_horizontal if scroll != null else 0
	set(value):
		if scroll != null:
			scroll.scroll_horizontal = value

## 这一次按下是不是变成了拖拽。下次在视口内按下时复位
var _drag_click := false
var _dragging := false
var _drag_origin := Vector2.ZERO
var _drag_scroll := Vector2i.ZERO

## 正在把值写进条，别把它当成"玩家拖了条"
var _syncing := false

###########################################################
#  生命周期
###########################################################

## 建出内部结构与滚动条。位置应用延到下一帧 —— 那时布局才跑完，
## yinitial 之类的比例才算得出该落在哪
func _ready() -> void:
	_ensure_scroll()
	_rebuild_bars()
	_apply_initial()

## 每帧同步条的范围与位置。没有条就根本不开 _process
func _process(_delta: float) -> void:
	if auto_place_bars:
		_place_bars()
	_sync_bars()

###########################################################
#  对外接口
###########################################################

## 把内容节点放进视口。
##
## 代码里建视口时用它；.tscn 里把内容直接声明在 Scroll 下面的页面不用调 ——
## 那种情况下本组件会把 Scroll 的第一个子节点当成内容
func add_content(node: Control) -> void:
	_ensure_scroll()
	content = node
	scroll.add_child(node)

## 这一次点击是不是一次拖拽的收尾。
##
## 各页面的点击回调开头查它：拖完松手那一次抬起不该再触发槽位/条目。
## 不用手动清 —— 下次在视口内按下时会复位
func is_drag_click() -> bool:
	return _drag_click

###########################################################
#  结构
###########################################################

## 拿到或建出内部的 ScrollContainer。
##
## 页面在 .tscn 里声明过的那个优先 —— 那样内容节点能直接写在它下面，
## 路径稳定。没声明就新建，并把 Scroll 压到最底层，免得盖住滚动条
func _ensure_scroll() -> void:
	if scroll != null:
		return

	var existing := get_node_or_null(SCROLL_NAME)
	if existing is ScrollContainer:
		scroll = existing
	else:
		scroll = ScrollContainer.new()
		scroll.name = SCROLL_NAME
		add_child(scroll)
		move_child(scroll, 0)

	# 视口内部一律铺满。页面要控制的是整个 VNViewport 的矩形，不是 Scroll 的
	scroll.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

## 按 scrollbars 重建滚动条。
##
## 先拆后建：属性在运行期被改时也得跟着换，不能只认第一次
func _rebuild_bars() -> void:
	_free_bars()

	# "" 与 "vertical" 都是竖向可滚，区别只在画不画条；
	# 横向只有显式点名才开
	var want_vertical := scrollbars != "horizontal"
	var want_horizontal := scrollbars == "horizontal" or scrollbars == "both"

	# 内部条一律不画。要装的轴用 SHOW_NEVER（能滚、不画），
	# 不要的轴用 DISABLED（连滚都不能）
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER \
		if want_vertical else ScrollContainer.SCROLL_MODE_DISABLED
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER \
		if want_horizontal else ScrollContainer.SCROLL_MODE_DISABLED

	if scrollbars == "vertical" or scrollbars == "both":
		vertical_bar = VScrollBar.new()
		vertical_bar.name = "VBar"
		# step 1：否则 Range 会按自己的步长把值取整，拖起来一跳一跳
		vertical_bar.step = 1.0
		vertical_bar.value_changed.connect(_on_vertical_changed)
		add_child(vertical_bar)

	if want_horizontal:
		horizontal_bar = HScrollBar.new()
		horizontal_bar.name = "HBar"
		horizontal_bar.step = 1.0
		horizontal_bar.value_changed.connect(_on_horizontal_changed)
		add_child(horizontal_bar)

	set_process(vertical_bar != null or horizontal_bar != null)

## 拆掉现有的两条
func _free_bars() -> void:
	if vertical_bar != null:
		remove_child(vertical_bar)
		vertical_bar.queue_free()
		vertical_bar = null
	if horizontal_bar != null:
		remove_child(horizontal_bar)
		horizontal_bar.queue_free()
		horizontal_bar = null

## 把两条条摆到边缘。
##
## 粗细取条自己的 custom_minimum_size —— 素材决定宽度，本组件不猜。
## 还没设（宽度为 0）就先不动它：等页面套完皮肤那一帧自然会摆对
func _place_bars() -> void:
	if vertical_bar != null and vertical_bar.custom_minimum_size.x > 0.0:
		var w := vertical_bar.custom_minimum_size.x
		vertical_bar.position = Vector2(size.x - w, 0.0)
		vertical_bar.size = Vector2(w, size.y)

	if horizontal_bar != null and horizontal_bar.custom_minimum_size.y > 0.0:
		var h := horizontal_bar.custom_minimum_size.y
		horizontal_bar.position = Vector2(0.0, size.y - h)
		horizontal_bar.size = Vector2(size.x, h)

###########################################################
#  滚动条同步
###########################################################

## 把内容范围、视口范围与当前位置写进两条条。
##
## 内容取 content；没设过就退回 Scroll 的第一个子节点 —— .tscn 里
## 把内容声明在 Scroll 下面的页面走这一条
func _sync_bars() -> void:
	if vertical_bar == null and horizontal_bar == null:
		return

	var target := content
	if target == null and scroll.get_child_count() > 0:
		target = scroll.get_child(0) as Control
	if target == null:
		return

	var extent := target.get_combined_minimum_size()

	# 挡住赋值引发的 value_changed：那一下会被当成"玩家在拖条"
	_syncing = true
	if vertical_bar != null:
		vertical_bar.max_value = maxf(extent.y, scroll.size.y)
		vertical_bar.page = scroll.size.y
		vertical_bar.value = float(scroll.scroll_vertical)
		# 内容装得下就不画。Ren'Py 那边 scrollbars 也是这样按需出现的
		vertical_bar.visible = vertical_bar.max_value > vertical_bar.page
	if horizontal_bar != null:
		horizontal_bar.max_value = maxf(extent.x, scroll.size.x)
		horizontal_bar.page = scroll.size.x
		horizontal_bar.value = float(scroll.scroll_horizontal)
		horizontal_bar.visible = horizontal_bar.max_value > horizontal_bar.page
	_syncing = false

## 玩家拖竖条
func _on_vertical_changed(value: float) -> void:
	if _syncing:
		return
	scroll.scroll_vertical = int(value)

## 玩家拖横条
func _on_horizontal_changed(value: float) -> void:
	if _syncing:
		return
	scroll.scroll_horizontal = int(value)

## 把 xinitial / yinitial 落到实际滚动位置。
##
## 必须等一帧：内容的最小尺寸要等布局跑完才算得出来，
## 在 _ready() 里直接算只会拿到 0（history 那块原先就踩过）
func _apply_initial() -> void:
	await get_tree().process_frame
	if scroll == null:
		return

	_scroll_to_fraction(xinitial, yinitial)

## 按比例滚到某个位置。0.0 最前，1.0 最后
func _scroll_to_fraction(x: float, y: float) -> void:
	var target := content
	if target == null and scroll.get_child_count() > 0:
		target = scroll.get_child(0) as Control
	if target == null:
		return

	var extent := target.get_combined_minimum_size()

	scroll.scroll_vertical = int(clampf(y, 0.0, 1.0)
		* maxf(0.0, extent.y - scroll.size.y))
	scroll.scroll_horizontal = int(clampf(x, 0.0, 1.0)
		* maxf(0.0, extent.x - scroll.size.x))

###########################################################
#  输入
###########################################################

## 拖拽与滚轮都在这里看。
##
## 必须是 _input：滚轮被吞掉、以及拖拽期间的判断都要赶在 GUI 之前 ——
## 内容里的条目是 VNButton（MOUSE_FILTER_STOP），按下时事件被按钮吃掉，
## ScrollContainer 自己收不到。_input 早于 GUI，所以拖拽期间按钮的按下态
## 照常变化，只是松手时那次 vn_pressed 会被 is_drag_click() 挡掉
func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		_on_button(event as InputEventMouseButton)
	elif event is InputEventMouseMotion:
		_on_motion(event as InputEventMouseMotion)

## 鼠标按下/抬起/滚轮
func _on_button(event: InputEventMouseButton) -> void:
	if event.button_index == MOUSE_BUTTON_WHEEL_UP \
			or event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
		_on_wheel(event)
		return

	if event.button_index != MOUSE_BUTTON_LEFT:
		return

	if not event.pressed:
		_dragging = false
		return

	if not _accepts_drag_at(event.position):
		return

	_dragging = true
	_drag_click = false
	_drag_origin = event.global_position
	_drag_scroll = Vector2i(scroll.scroll_horizontal, scroll.scroll_vertical)

## 拖动
func _on_motion(event: InputEventMouseMotion) -> void:
	if not _dragging:
		return

	var moved := event.global_position - _drag_origin

	# 只有能滚的轴才算进死区：竖向列表里左右抖一下不该把点击废掉
	var travelled := 0.0
	if scroll.vertical_scroll_mode != ScrollContainer.SCROLL_MODE_DISABLED:
		travelled += absf(moved.y)
	if scroll.horizontal_scroll_mode != ScrollContainer.SCROLL_MODE_DISABLED:
		travelled += absf(moved.x)

	if not _drag_click and travelled > DRAG_THRESHOLD:
		_drag_click = true
	if not _drag_click:
		return

	scroll.scroll_vertical = _drag_scroll.y - int(moved.y)
	scroll.scroll_horizontal = _drag_scroll.x - int(moved.x)

## 滚轮。
##
## mousewheel 为 true 时原样放行，交给 ScrollContainer 自己处理；
## 另外两种取值要先把事件吞掉，否则原生处理会先滚一遍竖的
func _on_wheel(event: InputEventMouseButton) -> void:
	if mousewheel == true:
		return
	if scroll == null or not get_global_rect().has_point(event.position):
		return

	get_viewport().set_input_as_handled()
	if mousewheel != "horizontal":
		return

	scroll.scroll_horizontal += WHEEL_STEP if event.button_index \
		== MOUSE_BUTTON_WHEEL_DOWN else -WHEEL_STEP

## 这个点能不能起手拖拽：要在视口矩形内，且不落在任何一条滚动条上 ——
## 落在条上时该由条自己处理，否则两边同时改滚动位置会打架
func _accepts_drag_at(point: Vector2) -> bool:
	if not draggable or scroll == null:
		return false
	if not get_global_rect().has_point(point):
		return false
	if vertical_bar != null and vertical_bar.get_global_rect().has_point(point):
		return false
	if horizontal_bar != null \
			and horizontal_bar.get_global_rect().has_point(point):
		return false
	return true

###########################################################
#  属性
###########################################################

## scrollbars 的写入口。运行期改也要重建，不能只认 .tscn 里那一次
func set_scrollbars(value: String) -> void:
	scrollbars = value
	if not is_inside_tree() or scroll == null:
		return
	_rebuild_bars()

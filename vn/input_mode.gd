class_name VNInputMode
extends Node

# ═══════════════════════════════════════════════════════════
#  输入模式：最后用的是键盘导航（方向键/Tab）还是鼠标。
#
#  ── 对应 Ren'Py 的哪一层 ──
#  renpy/display/focus.py 的 pending_focus_type（"keyboard" / "mouse"）。
#  那边鼠标事件把它设成 "mouse" 并重新按鼠标位置算焦点，键盘方向键把它
#  设成 "keyboard"；MouseArea.event 在键盘模式下强制 is_hovered = False
#  （behavior.py:2817），所以两套高亮不会同时亮。
#
#  ── 本项目落地成什么 ──
#  只剩两个状态：
#    MOUSE     按钮只由 is_hovered() 决定外观；键盘焦点清空
#    KEYBOARD  按钮只由 has_focus(true) 决定外观；鼠标光标藏起来
#  切换时发 mode_changed，按钮/滑块/图库格子收到后重画。
#
#  ── 默认 ──
#  启动是 MOUSE。界面的首项只登记成 VNFocus.default_focus，不立刻 grab；
#  玩家第一次按方向键时才把它叫出来。这样打开菜单时不会凭空多一个
#  键盘高亮，也不会和鼠标悬停打架。
# ═══════════════════════════════════════════════════════════

## 模式变了。参数是 Mode。
signal mode_changed(mode: int)

enum Mode {
	MOUSE,
	KEYBOARD,
}

## 当前模式。初始是鼠标 —— 玩家还没碰键盘时不该有键盘焦点
var mode := Mode.MOUSE

## 鼠标隐藏节点。由 VNFrame 在装配时注入
var mouse_hide: VNMouseHide = null

###########################################################

## 现在是不是键盘模式
func is_keyboard() -> bool:
	return mode == Mode.KEYBOARD

###########################################################

## 全局输入监听。
##
## 挂在 autoload 上，而不是各界面自己监听：模式是跨界面的状态，
## 菜单、剧情、选项都该遵守同一套"最后输入设备"规则。
func _input(event: InputEvent) -> void:
	# 鼠标与触摸都算"鼠标这一类"。触摸没有悬停，但模式仍然要切回鼠标，
	# 否则安卓上按过硬件键盘之后触摸就再也点不亮按钮了
	if event is InputEventMouse \
			or event is InputEventScreenTouch \
			or event is InputEventScreenDrag:
		_enter_mouse(event)
		return

	if event is InputEventKey and event.pressed:
		# 方向键由本节点接管，不再交给 Viewport 的自动邻居猜测。
		# 第一次按下先切模式、藏光标、必要时把默认焦点叫出来；
		# echo 直接沿显式焦点图移动，长按才能连续走。
		if _is_direction(event):
			if not event.echo:
				_enter_keyboard(event)
			if not get_viewport().is_input_handled():
				_navigate(event)
			return

		# Tab 的焦点导航交给 Viewport / quick_menu，这里只负责切模式和藏光标
		if _is_focus_key(event):
			# quick menu 可见时，Tab 是它的“进入/退出”开关，由它自己处理。
			# 组合作用域不能抢这个键，否则 Tab 会变成在 QM 按钮之间循环。
			if _quick_menu_tab_active():
				if not event.echo:
					_enter_keyboard(event)
				return

			if VNFocus.has_scope():
				if not event.echo:
					_enter_keyboard(event)
				var delta := 1 if event.is_action_pressed(&"ui_focus_next", true) else -1
				VNFocus.move_ordered(delta, true)
				get_viewport().set_input_as_handled()
				return
			if not event.echo:
				_enter_keyboard(event)
				return

		# 鼠标点击留下的隐藏焦点不该被回车触发。焦点虽然还在，但视觉上
		# 从没亮过；清掉之后回车会走它本来的路（推进剧情 / 主菜单开始 /
		# 菜单界面无操作），而不是再按一次刚才点过的按钮。
		#
		# 悬停产生的隐藏焦点是例外：玩家把鼠标停在历史语音按钮上再按
		# 回车，期望的是操作那个按钮，而不是让下面的剧情推进。
		if not event.echo and event.is_action_pressed(&"ui_accept"):
			# 名字不叫 owner：Node 已经有同名属性
			var focus_owner := get_viewport().gui_get_focus_owner()
			if focus_owner != null and not focus_owner.has_focus(true):
				var hover_focus := VNFocus.is_mouse_hover_focus() \
					and VNFocus.current_focus() == focus_owner
				if not hover_focus:
					get_viewport().gui_release_focus()

## 鼠标模式。
##
## 只有"鼠标移动"才清焦点，而且左键按住时不清：
##
##   BaseButton 在鼠标按下时 grab 焦点，失去焦点会把 status.press_attempt
##   清掉 —— 如果在松开事件之前清焦点，松开那一下就不会发 pressed。
##   这正是"鼠标左键几乎无效"的原因：点击过程中手一抖产生一个 motion，
##   焦点被清，按下状态跟着没了。
##
## 所以：
##   点击事件（按下/松开）  只切模式，不碰焦点
##   移动事件、左键没按住  才释放键盘焦点（"移动鼠标，键盘焦点消失"）
##   移动事件、左键按住中  不动焦点，让这次点击完整走完
func _enter_mouse(event: InputEvent) -> void:
	var moving := event is InputEventMouseMotion or event is InputEventScreenDrag

	if moving and mouse_hide != null:
		mouse_hide.force_show()

	if moving and not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		# 鼠标在滑条上时不释放：滑条自己在 mouse_entered 时拿了隐藏焦点，
		# 这个焦点就是"鼠标停在滑条上"的锚点。释放掉的话，之后按方向键
		# 又只能退回默认首项，焦点就跑侧边栏了。
		if _mouse_over_slider() == null:
			if get_viewport().gui_get_focus_owner() != null:
				get_viewport().gui_release_focus()

	_set_mode(Mode.MOUSE)

	# 有作用域时，鼠标位置就是逻辑焦点：悬停到哪个可聚焦控件，
	# 哪个就是当前焦点；悬停到空白则清空。
	if VNFocus.has_scope():
		VNFocus.focus_from_mouse(moving)

## 键盘模式。
##
## 只有方向键和 Tab 会走到这里（见 _input）。这里只负责切模式和藏光标；
## 真正的焦点移动由 VNFocus 的作用域现算。
func _enter_keyboard(_event: InputEvent) -> void:
	_set_mode(Mode.KEYBOARD)
	if mouse_hide != null:
		mouse_hide.force_hide()

## 这次按键是不是焦点导航键（Tab / Shift+Tab）
func _is_focus_key(event: InputEvent) -> bool:
	return event.is_action_pressed(&"ui_focus_next", true) \
		or event.is_action_pressed(&"ui_focus_prev", true)

## quick menu 是否可见且属于当前作用域。是的话 Tab 交给它的 _input，
## 保持“Tab 进入/退出 QM”的开关语义，而不是在 QM 按钮间顺序循环。
func _quick_menu_tab_active() -> bool:
	if not VNFocus.has_scope():
		return false
	for node in get_tree().get_nodes_in_group(&"vn_quick_menu"):
		var quick_menu := node as Control
		if quick_menu != null and quick_menu.is_visible_in_tree() \
				and VNFocus.is_in_scope(quick_menu):
			return true
	return false

## 这次按键是不是四向方向键。allow_echo 传 true 才能认出长按的重复事件
func _is_direction(event: InputEvent) -> bool:
	return event.is_action_pressed(&"ui_up", true) \
		or event.is_action_pressed(&"ui_down", true) \
		or event.is_action_pressed(&"ui_left", true) \
		or event.is_action_pressed(&"ui_right", true)

## 鼠标下的滑条。先信引擎的 hover 查询；它返回 null 时再按矩形兜底。
##
## 兜底不是多余：光标刚被切换、或平台/窗口状态让 hover 查询短暂为空时，
## gui_get_hovered_control() 会返回 null。没有兜底就会退回默认首项，
## 焦点跑到窗口大小/侧边栏。
##
## hovered 非 null 但不是滑条时直接返回 null，不进入兜底 —— 否则弹窗
## 压在设置页上时，矩形兜底会穿透弹窗找到底下的滑条。
func _mouse_over_slider() -> VNSlider:
	var hovered := get_viewport().gui_get_hovered_control()
	if hovered != null:
		return hovered as VNSlider

	for node in get_tree().get_nodes_in_group(&"vn_sliders"):
		var slider := node as VNSlider
		if slider == null or not slider.keyboard_focus:
			continue
		if not slider.is_visible_in_tree():
			continue
		if slider.get_global_rect().has_point(slider.get_global_mouse_position()):
			return slider
	return null

## 方向键导航。所有带键盘焦点的界面都有自己的作用域，
## 由 VNFocus 现算几何最近的控件，不再读 focus_neighbor_*。
##
## 滑条的左右是调值，不是导航 —— 先放行给 VNSlider._gui_input()。
func _navigate(event: InputEvent) -> void:
	var side := _side_of(event)
	if side < 0:
		return

	var focus_owner := get_viewport().gui_get_focus_owner()
	if focus_owner is Range and (side == SIDE_LEFT or side == SIDE_RIGHT):
		return

	if not VNFocus.has_scope():
		return

	VNFocus.sync_native()
	VNFocus.move(side, true)
	get_viewport().set_input_as_handled()

## 这次方向键对应哪个 Side。不是方向键返回 -1
func _side_of(event: InputEvent) -> int:
	if event.is_action_pressed(&"ui_left", true):
		return SIDE_LEFT
	if event.is_action_pressed(&"ui_right", true):
		return SIDE_RIGHT
	if event.is_action_pressed(&"ui_up", true):
		return SIDE_TOP
	if event.is_action_pressed(&"ui_down", true):
		return SIDE_BOTTOM
	return -1

## 改模式并广播。相同模式不重复发
func _set_mode(next: Mode) -> void:
	if mode == next:
		return
	mode = next
	mode_changed.emit(mode)

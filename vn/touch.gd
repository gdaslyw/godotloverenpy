class_name VNTouch
extends Node

# ═══════════════════════════════════════════════════════════
#  触摸适配。目前只做一件事：**长按视为鼠标右键**。
#
#  ── 为什么需要它 ──
#  安卓没有右键，而本项目里右键是有语义的：关掉 extra、确认框选「否」、
#  鉴赏页关查看器、剧情里切换观赏模式。长按是最接近右键的触摸手势。
#
#  ── 对应 Ren'Py 的哪一处 ──
#  renpy/config.py:533-540：
#      longpress_duration = 0.5   判定时长
#      longpress_radius   = 15    手指允许漂移的像素半径
#      longpress_vibrate  = 0.1   触发时的振动
#  判定写在 renpy/display/behavior.py:1156-1174 的 Button.event()；
#  「忽略这次触摸剩下的部分」在 renpy/display/core.py:2027 的 after_longpress()。
#
#  ── 和 Ren'Py 的两处差别 ──
#   1. 时长 1 秒（原版 0.5），且不振动
#   2. **不限位置**：Ren'Py 只对定义了 alternate 的按钮生效，这里在任何地方
#      都出右键 —— 需求是「把长按当成鼠标右键」，不是「给按钮加个别名动作」
#
#  ── 为什么不自己接管触摸→鼠标 ──
#  引擎的 input_devices/pointing/emulate_mouse_from_touch 默认开着，触摸本来
#  就会产生左键。把它关掉再自己重做一遍，要连带重写滚动、滑块、悬停，代价
#  远大于收益。这里只在旁边补一手：长按出右键，并吞掉那次左键释放。
# ═══════════════════════════════════════════════════════════

## 按住多久算长按，毫秒。
##
## Ren'Py 那边是 0.5 秒，本项目定为 1 秒 —— 推进台词是点一下，手指在屏幕上
## 停过半秒太容易了，那样会在读台词的中途莫名切进观赏模式
const LONGPRESS_MSEC := 1000

## 手指允许漂移的半径，像素。超过就取消。
##
## 照抄 Ren'Py 的 config.longpress_radius。作用是别把「按住稍久一点的拖动」
## 误判成长按 —— 列表和滚动条都靠拖动
const LONGPRESS_RADIUS := 15.0

## 正在计时的那根手指。多指时只认第一根，和引擎的触摸→鼠标转换一致。
##
## 长按触发之后 _armed 变假但这里仍有值（手指还按着），直到真正抬手
var _index := -1

## 按下时的位置与时刻
var _start_pos := Vector2.ZERO
var _start_msec := 0

## 这次触摸还在计时吗。抬手、漂移超距、已经触发过长按，三者都会让它变假
var _armed := false

## 下一次左键释放要不要吞掉。
##
## 长按触发时置真：那根手指抬起时引擎仍会照常发出左键释放，不吞的话它还
## 会再走一遍点击 —— 剧情里推一句台词、按钮上补一次点击。这正是 Ren'Py
## after_longpress() 置 ignore_touch 要解决的事
var _swallow_release := false

###########################################################
#  生命周期
###########################################################

## 平时不跑 _process，只在按住期间开
func _ready() -> void:
	set_process(false)

###########################################################
#  输入
###########################################################

## 触摸与鼠标两条路都在这里看。
##
## 必须是 _input 而不是 _unhandled_input：吞左键释放那一步要赶在 GUI 之前。
## 官方教程 tutorials/inputs/inputevent 写明顺序是
## _input -> GUI(_gui_input) -> _shortcut_input -> _unhandled_input，
## 并且在 _input 里 set_input_as_handled() 就「even before the GUI」。
## 放到 _unhandled_input 的话，按钮和 say 界面早就收到那次点击了
func _input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		var touch := event as InputEventScreenTouch
		if touch.pressed:
			_begin(touch)
		else:
			_end(touch)
		return

	if event is InputEventScreenDrag:
		_check_drift(event as InputEventScreenDrag)
		return

	_check_swallow(event)

## 计时到点就在这里触发。
##
## 触发放在 _process 而不是抬手时，是照 Ren'Py 的 timeout 语义（那边排一个
## longpress_duration 的定时器）。附带好处是：吞释放的标志在手指抬起之前
## 早就置好了，不依赖「触摸事件与鼠标事件谁先到」
func _process(_delta: float) -> void:
	if not _armed:
		return
	if Time.get_ticks_msec() - _start_msec < LONGPRESS_MSEC:
		return
	_fire()

###########################################################
#  内部
###########################################################

## 一根手指按下，开始计时。
##
## 已经在计时就忽略后来的手指。判断用 _armed 而不是 _index：长按已经触发、
## 手指还按着的时候 _armed 是假而 _index 有值，那时后来的手指该能接管
func _begin(touch: InputEventScreenTouch) -> void:
	if _armed:
		return

	_index = touch.index
	_start_pos = touch.position
	_start_msec = Time.get_ticks_msec()
	_armed = true

	# 新的一次触摸开始，上一次留下的吞释放标志作废。它对应的那次释放要么
	# 已经来过，要么永远不会来（触摸→鼠标转换被关掉时就是后者），
	# 留着它会把下一次正常的左键点击吃掉
	_swallow_release = false
	set_process(true)

## 手指抬起，停止计时。
##
## **不动 _swallow_release** —— 这次触摸对应的左键释放可能还没到，
## 那一位要留给 _check_swallow()
func _end(touch: InputEventScreenTouch) -> void:
	if touch.index != _index:
		return

	_index = -1
	_armed = false
	set_process(false)

## 手指移动。漂移超过半径就取消计时 —— 那是在拖动，不是长按
func _check_drift(drag: InputEventScreenDrag) -> void:
	if not _armed or drag.index != _index:
		return
	if drag.position.distance_to(_start_pos) <= LONGPRESS_RADIUS:
		return

	_armed = false
	set_process(false)

## 到点了：这一次触摸算长按。
##
## 先解除计时、置吞释放标志，再注入那一对右键 —— 顺序不能反：注入是同步
## 派发的，先发事件再改状态的话，事件回来时状态还是旧的
##
## 按下与抬起都发。本项目所有右键处理都认抬起（extra 关菜单、确认框选「否」、
## 鉴赏关查看器、剧情切观赏模式），只发抬起虽然也能用，但那不是一次真实的点击
func _fire() -> void:
	_armed = false
	set_process(false)
	_swallow_release = true

	_send_right(true)
	_send_right(false)

## 注入一次右键，位置就是按下时那一点。
##
## 用 Input.parse_input_event() 而不是 get_viewport().push_input()：前者走
## 完整条输入管线，和玩家真按下右键没有区别（文档：会触发 Node._input()）。
##
## device 标成 DEVICE_ID_EMULATION —— 官方对它的说明正是「触摸屏转出来的
## 模拟鼠标输入」，和引擎自己从触摸转出来的左键同一个标记
func _send_right(pressed: bool) -> void:
	var mouse := InputEventMouseButton.new()
	mouse.button_index = MOUSE_BUTTON_RIGHT
	mouse.pressed = pressed
	mouse.position = _start_pos
	mouse.global_position = _start_pos
	mouse.device = InputEvent.DEVICE_ID_EMULATION
	Input.parse_input_event(mouse)

## 吞掉长按之后那次左键释放。
##
## 只认「左键 + 抬起」：按下在长按判定出来之前就已经过去了，拦不住也不该拦 ——
## 拦了按钮和滑块连按下状态都不会有
func _check_swallow(event: InputEvent) -> void:
	if not _swallow_release:
		return
	if not (event is InputEventMouseButton):
		return

	var mouse := event as InputEventMouseButton
	if mouse.button_index != MOUSE_BUTTON_LEFT or mouse.pressed:
		return

	_swallow_release = false
	get_viewport().set_input_as_handled()

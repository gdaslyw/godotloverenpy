class_name VNMouseHide
extends Node

# ═══════════════════════════════════════════════════════════
#  鼠标静止一段时间之后把光标藏起来。
#
#  ── 对应 Ren'Py 的哪一层 ──
#  config.mouse_hide_time（display/core.py:1750 的 is_mouse_visible）。
#  那边不是"起个定时器，到点隐藏"，而是每帧问一次"距离上次鼠标事件
#  过去多久了" —— 本类照这个思路写：累加空闲时间，超过阈值就藏。
#
#  ── 为什么这样比定时器稳 ──
#  定时器一旦启动就得在每次鼠标事件里 stop() + start()，漏一次就会在
#  玩家正动着的时候把光标藏掉。每帧累加没有这种状态可以漏：鼠标一动，
#  空闲时间归零，光标当场回来
#
#  ── 藏的是哪个光标 ──
#  Input.mouse_mode。本项目的光标图配在 project.godot 的
#  mouse_cursor/custom_image 里，那个设置只在 MOUSE_MODE_VISIBLE 下生效，
#  所以藏起来再放出来拿到的还是同一张自定义图
# ═══════════════════════════════════════════════════════════

## 隐藏延迟，单位秒。**0 表示永不隐藏**。
##
## 默认 0 而不是 30：本类不知道玩家想设多少，装配时由 VNFrame 按
## 玩家配置灌进来。这样它不依赖 VNConfig，单独拿出来也能用
var hide_time := 0.0

## 距离上一次鼠标事件过了多久
var _idle := 0.0

## 光标现在是不是被本类藏起来了
var _hidden := false

###########################################################

func _ready() -> void:
	# 没有可见光标的平台整个停掉：安卓、Web 的触屏上 MOUSE_MODE_HIDDEN
	# 没有任何意义。process_mode 会一并关掉 _process 与 _input
	if not VNDisplay.is_desktop():
		process_mode = Node.PROCESS_MODE_DISABLED

func _process(delta: float) -> void:
	# 关掉之后不该留着一个藏起来的光标
	if hide_time <= 0.0:
		_show()
		return

	_idle += delta
	if not _hidden and _idle >= hide_time:
		_hide()

## 任何鼠标事件都算"玩家还在动"。
##
## 用 _input 而不是 _unhandled_input：后者只收界面没吃掉的，
## 而鼠标停在按钮上时那些事件全被控件吃了 —— 那样"停在按钮上不动"
## 反而永远等不到隐藏
func _input(event: InputEvent) -> void:
	if event is InputEventMouse:
		_wake()

## 改隐藏间隔。外部（Settings 页）走这里而不是直接赋字段，
## 因为改完之后要立刻按新间隔重算一次
func set_hide_time(seconds: float) -> void:
	hide_time = maxf(seconds, 0.0)
	_idle = 0.0
	if hide_time <= 0.0:
		_show()

###########################################################
#  内部
###########################################################

## 有鼠标动静：计时归零，光标放出来
func _wake() -> void:
	_idle = 0.0
	_show()

## 藏起来。已经藏了就不重复设 —— 每帧写一次 mouse_mode 会打断引擎那边
## 对它自己的状态跟踪
func _hide() -> void:
	if _hidden:
		return
	_hidden = true
	Input.mouse_mode = Input.MOUSE_MODE_HIDDEN

## 放出来。同样只在真的藏着时才动
func _show() -> void:
	if not _hidden:
		return
	_hidden = false
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

## 本节点被移走时把光标还回去 —— 否则界面重建、切场景之后
## 玩家会遇到一个没有光标的游戏
func _exit_tree() -> void:
	_show()

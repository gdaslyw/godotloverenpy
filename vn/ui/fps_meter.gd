class_name VNFPSMeter
extends CanvasLayer

# ═══════════════════════════════════════════════════════════
#  左上角的帧率显示。
#
#  装在最上层（500，压在 Transition 的 400 之上）：转场黑幕一来就看不见
#  帧率的话，最该看数字的时刻恰好被盖住。
#
#  为什么不是每帧刷新：Label 每改一次文本都会走一遍重排与重绘，每帧刷
#  反而会污染它自己要测的那个数字。0.25 秒一次肉眼完全够用。
#
#  为什么用 Engine.get_frames_per_second()：它内部做过平滑，比自己拿
#  1/delta 算要稳 —— 后者会在 59 和 61 之间乱跳，看不出真正的卡顿。
# ═══════════════════════════════════════════════════════════

## 压在 Transition(400) 之上，转场期间也看得见
const LAYER := 500
## 刷新间隔（秒）
const REFRESH_INTERVAL := 0.25
## 字号。视口是 2560×1440，24 以下在这个尺寸上偏小
const FONT_SIZE := 32
## 左上角内边距
const MARGIN := Vector2(12, 12)
## 描边宽度。压在亮色背景上时靠它把字托出来
const OUTLINE_SIZE := 6
## 启动时是否显示。F3 随时可以切换 —— 这个值只决定第一眼看到的样子
const DEFAULT_VISIBLE := true

var _label: Label = null
var _elapsed := 0.0

func _ready() -> void:
	layer = LAYER

	var label := Label.new()
	# 它只是显示。Control 的默认值是 STOP，会吞掉推进台词的那一下点击
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.position = MARGIN
	label.add_theme_font_size_override("font_size", FONT_SIZE)
	label.add_theme_color_override("font_color", Color.WHITE)
	label.add_theme_color_override("font_outline_color", Color.BLACK)
	label.add_theme_constant_override("outline_size", OUTLINE_SIZE)
	add_child(label)
	_label = label

	_update_text()
	_apply_visible(DEFAULT_VISIBLE)

## F3 切换显示。用抬起而不是按下 —— 和项目里其它交互一致。
##
## 藏起来之后这个回调仍然有效，所以不会出现"关掉就再也打不开"
func _input(event: InputEvent) -> void:
	if not event.is_action_released(&"vn_fps_toggle"):
		return

	_apply_visible(not visible)
	# 别再往 UI 传：F3 不是任何界面的按键，传下去只会让将来某个界面
	# 意外多出一条快捷键
	get_viewport().set_input_as_handled()

## 显示与刷新一起开关。藏起来还继续算文本没有意义，重新打开时立刻补一次，
## 免得先看到 0.25 秒前的旧数字
func _apply_visible(on: bool) -> void:
	visible = on
	set_process(on)
	if on:
		_update_text()

func _process(delta: float) -> void:
	_elapsed += delta
	if _elapsed < REFRESH_INTERVAL:
		return

	_elapsed = 0.0
	_update_text()

## 把当前帧率写进标签。只取整数 —— 小数位对判断卡顿没有帮助
func _update_text() -> void:
	_label.text = "FPS %d" % Engine.get_frames_per_second()

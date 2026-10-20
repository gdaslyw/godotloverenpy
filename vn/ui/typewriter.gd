class_name VNTypewriter
extends RichTextLabel

signal typed

## 纯文本
var _plain := ""
## 纯字符数量
var _total := 0
## 已显示到第几个字（浮点累积，整数部分生效）
var _shown := 0.0
var _typing := false

###########################################################

func _ready() -> void:
	# 按整形后的字符裁剪：排好版后再控制显示数量，而不是一边显示一边排版
	visible_characters_behavior = TextServer.VC_CHARS_AFTER_SHAPING
	# 不打字时不占用每帧回调
	set_process(false)

func play(bbcode: String) -> void:
	# 直接全赋值，只控制显示数量
	text = bbcode

	_plain = get_parsed_text()
	_total = get_total_character_count()
	_shown = 0.0
	visible_characters = 0

	# _typing 先立起来，后面两条提前返回的路都要靠 _typed() 收尾。
	# 原先它立在最后，于是"台词为空"那一路调 _typed() 时 _typing 还是
	# false，被守卫挡掉 —— typed 信号根本发不出去
	_typing = true

	# 速度为 0 表示不打字机（对应 Ren'Py 的 preferences.text_cps = 0），
	# 整句立刻显示。
	#
	# 这一支不能省掉、也不能指望 _process 里每帧推进 0 个字来实现：
	# 那样 target 恒为 0，visible_characters 永远停在初值上，整句卡死
	if _total <= 0 or VN.config.text_cps <= 0:
		visible_characters = -1
		_typed()
		return

	set_process(true)

func skip() -> void:
	if not _typing:
		return
	_shown = float(_total)
	visible_characters = -1
	_typed()

## 清空文本并停止打字。窗口在下一句台词之前就显示时用它，
## 避免上一句的内容跟着对话框一起淡入。
##
## 名字不能叫 clear()：RichTextLabel 自带一个原生 clear()，
## 覆盖它会被 GDScript 当成错误
func clear_text() -> void:
	text = ""
	_plain = ""
	_total = 0
	_shown = 0.0
	_typing = false
	visible_characters = -1
	set_process(false)

func is_typing() -> bool:
	return _typing

func _process(delta: float) -> void:
	# 速度每帧现取，不在 play() 时缓存：玩家在设置里调完速度，
	# 下一句就该按新速度走，不必重开一局
	_shown += VN.config.text_cps * delta
	var target := int(_shown)
	if target <= visible_characters:
		return
	visible_characters = target
	if target >= _total:
		_typed()

func _typed() -> void:
	if not _typing:
		return
	_typing = false
	set_process(false)
	# 延迟发出，避免调用方在信号里直接重入 play()
	typed.emit.call_deferred()

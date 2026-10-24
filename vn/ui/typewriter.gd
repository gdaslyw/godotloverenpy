class_name VNTypewriter
extends RichTextLabel

signal typed

## 打到 {w} / {p} 的无限等待点时发出。
##
## 打字机自己不该决定"等不等"：手动模式下要等玩家点击，自动播放和快进
## 模式下不能停。这个判断只有界面知道，所以这里只报告"到点了"，
## 由 say.gd 决定要不要调 resume_wait()
signal wait_reached

## 纯文本
var _plain := ""
## 纯字符数量
var _total := 0
## 已显示到第几个字（浮点累积，整数部分生效）
var _shown := 0.0
var _typing := false

# ── 事件相关 ──

## 事件表，按 at 升序。每项 { at, kind, value }，cps 项另带 end
var _events: Array[Dictionary] = []
## 下一条待处理事件的下标
var _event_at := 0
## 每个字符的推进速度；0 表示跟随全局 text_cps
var _speeds: PackedFloat32Array = PackedFloat32Array()
## 是否正停在等待点
var _waiting := false
## 剩余等待秒数。只在定时等待里用得上
var _wait_left := 0.0
## {nw} 的延迟秒数。-1 表示这句没有 {nw}
var _no_wait := -1.0

# ── 链接悬停相关 ──

## 本句的解析结果与图像表。悬停要重建 BBCode，重建就得有原始 runs
var _runs: Array = []
var _images: Dictionary = {}
## 当前悬停的链接地址。空串表示没有
var _hover_id := ""

###########################################################

func _ready() -> void:
	# 按整形后的字符裁剪：排好版后再控制显示数量，而不是一边显示一边排版
	visible_characters_behavior = TextServer.VC_CHARS_AFTER_SHAPING
	# 不打字时不占用每帧回调
	set_process(false)

## 播放一段台词。
##
## skip_leading 是开头多少个字符要立即显示、不参与打字 —— 正文的首行缩进
## 前缀用得上：那两个全角空格本来就只是占位，逐字打出来只会让句子晚
## 2/cps 秒才开始出字（25cps 下 80ms）。跳过它们等于"缩进一开始就在那儿"，
## 和 Ren'Py 里 first_indent 是排版属性、不参与打字的行为一致。
##
## events 是 VNTextTag.parse() 产出的位置事件（{w} {p} {cps} {fast} {nw}）。
## 它们的 at 是**相对整句文本**的字符下标；因为调用方传进来的 bbcode
## 已经含了缩进，这里不需要再加偏移
func play(runs: Array, images: Dictionary, skip_leading: int = 0,
		events: Array = []) -> void:
	_runs = runs
	_images = images
	_hover_id = ""

	# 直接全赋值，只控制显示数量
	text = _build_bbcode()

	_plain = get_parsed_text()
	_total = get_total_character_count()
	_prepare(events)

	_shown = float(skip_leading)
	visible_characters = skip_leading
	_apply_fast()

	# _typing 先立起来，后面两条提前返回的路都要靠 _typed() 收尾。
	# 原先它立在最后，于是"台词为空"那一路调 _typed() 时 _typing 还是
	# false，被守卫挡掉 —— typed 信号根本发不出去
	_typing = true

	# 速度为 0 表示不打字机（对应 Ren'Py 的 preferences.text_cps = 0），
	# 整句立刻显示。
	#
	# 这一支不能省掉、也不能指望 _process 里每帧推进 0 个字来实现：
	# 那样 target 恒为 0，visible_characters 永远停在初值上，整句卡死。
	#
	# 但 {nw} 仍然要认 —— 它管的是"打完自动走"，跟显示速度无关。
	# {w} / {p} 的停顿则直接跳过：玩家把速度设成 0 就是不想等，
	# 再卡在句中的等待点上自相矛盾
	if _total <= 0 or VN.config.text_cps <= 0:
		for ev: Dictionary in _events:
			if String(ev["kind"]) == "no_wait":
				_take_no_wait(float(ev["value"]))
		visible_characters = -1
		_typed()
		return

	set_process(true)

func skip() -> void:
	if not _typing:
		return
	_waiting = false
	_wait_left = 0.0
	_shown = float(_total)
	visible_characters = -1
	_typed()

## 让等待点放行。点击、自动播放、快进都走这里。
func resume_wait() -> void:
	if not _waiting:
		return
	_resume()

## 是不是正停在 {w} / {p} 上。
##
## say.gd 用它区分"正在打字"和"正在等"：同一个点击落在前者身上是
## "补完这句"，落在后者身上只是"放行继续打" —— 含义完全不同
func is_waiting() -> bool:
	return _waiting

## {nw} 的延迟秒数；返回 -1 表示这句没有 {nw}。
## 0 表示打完立刻前进，正数是等这么多秒
func no_wait_delay() -> float:
	return _no_wait

## 设置当前悬停的链接地址，空串表示没有。
##
## 悬停变色只能靠整段重建 BBCode —— RichTextLabel 没有局部改色的接口。
## 打字中途直接返回：重建会把 visible_characters 冲掉，那半句话就没了
func set_link_hover(address: String) -> void:
	if _typing or _hover_id == address:
		return
	_hover_id = address
	text = _build_bbcode()
	# 重建之后显示数量要显式写回"全显示"
	visible_characters = -1

## 按当前悬停状态生成 BBCode。
##
## 链接的颜色与下划线来自作品配置，不写死在剧本里。
##
## 正文色也一并传下去：{alpha} 只能并进 [color] 的第四个字节，
## 而"只写透明度不写颜色"时，得知道要被透明化的那个颜色是什么。
## 现问现取而不是缓存 —— 切主题、换界面都可能改它，而这只在重建
## BBCode 时调用一次
func _build_bbcode() -> String:
	var s := VNSettings.get_current()
	return VNTextTag.runs_to_bbcode(_runs, _images, {
		"idle": s.link_color,
		"hover": s.link_hover_color,
		"hover_id": _hover_id,
		"underline": s.link_underline,
	}, get_theme_color(&"default_color"))

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
	_events.clear()
	_speeds.clear()
	_event_at = 0
	_waiting = false
	_wait_left = 0.0
	_no_wait = -1.0
	_runs = []
	_images = {}
	_hover_id = ""
	visible_characters = -1
	set_process(false)

func is_typing() -> bool:
	return _typing

func _process(delta: float) -> void:
	# 停在等待点。定时等待自己倒计时走完；无参的等外部 resume_wait()
	if _waiting:
		if _wait_left > 0.0:
			_wait_left -= delta
			if _wait_left <= 0.0:
				_resume()
		return

	# 速度每帧现取，不在 play() 时缓存全局值：玩家在设置里调完速度，
	# 下一句就该按新速度走，不必重开一局。{cps} 段覆盖这个全局值。
	#
	# 显式转 float：config.text_cps 是 int，直接 := 会把 speed 推断成 int，
	# 下面那行赋 PackedFloat32Array 的元素时就要报收窄转换
	var speed := float(VN.config.text_cps)
	var idx := int(_shown)
	if idx >= 0 and idx < _speeds.size() and _speeds[idx] > 0.0:
		speed = _speeds[idx]

	_shown += speed * delta
	var target := int(_shown)
	if target <= visible_characters:
		return
	visible_characters = target

	# 越过事件点就逐条处理。wait / pause 会在这里把显示钳回去 ——
	# 一帧的 delta 跨过好几个事件时，也不会把后面的字提前露出来
	while _event_at < _events.size():
		var ev: Dictionary = _events[_event_at]
		if target < int(ev["at"]):
			break
		_event_at += 1
		if _fire(ev):
			_shown = float(ev["at"])
			visible_characters = int(ev["at"])
			return

	if target >= _total:
		_typed()

func _typed() -> void:
	if not _typing:
		return
	_typing = false
	set_process(false)
	# 延迟发出，避免调用方在信号里直接重入 play()
	typed.emit.call_deferred()

###########################################################
#  事件
###########################################################

## 把解析结果摊成打字机要的两张表：事件表与每字符速度表。
##
## 事件是复制一份再用：原数组还在解析结果里，别的调用方（比如缓存）
## 可能还拿着它，就地改会把对方的数据一起改掉
func _prepare(events: Array) -> void:
	_events.clear()
	for ev: Dictionary in events:
		_events.append(ev.duplicate(true))

	_event_at = 0
	_waiting = false
	_wait_left = 0.0
	_no_wait = -1.0
	_build_speeds()

## 把 {cps} 区间摊成"每字符一个速度"。
##
## 用数组而不是每帧查区间：一句话就几百字，建表的代价可以忽略，
## 换来的是 _process 里一次下标访问。0 表示"这一格跟随全局速度"
func _build_speeds() -> void:
	_speeds.resize(_total)
	_speeds.fill(0.0)
	for ev: Dictionary in _events:
		if String(ev["kind"]) != "cps":
			continue
		var value := float(ev["value"])
		# 负数在 parse 里表示"倍率"，正数才是绝对的字符每秒。
		# 倍率要乘的是**当前**全局速度，所以在这里算而不是 parse 时算
		var speed := value if value > 0.0 else VN.config.text_cps * (-value)
		var end := mini(int(ev.get("end", _total)), _total)
		for idx in range(int(ev["at"]), end):
			if idx >= 0 and idx < _total:
				_speeds[idx] = speed

## {fast}：它之前的字要立刻显示。
##
## 典型用法是紧接上一句的续写 —— 上一句以 {nw} 结尾，这一句前面那一截
## 玩家刚看过，再逐字打一遍很怪。多个 {fast} 取最远的那个，等价于
## "到最远的那一处为止全都立即显示"
func _apply_fast() -> void:
	var target := _shown
	for ev: Dictionary in _events:
		if String(ev["kind"]) == "fast":
			target = maxf(target, float(ev["at"]))
	if target > _shown:
		_shown = target
		visible_characters = int(target)

## 处理一条事件，返回 true 表示要在这里停住。
func _fire(ev: Dictionary) -> bool:
	match String(ev["kind"]):
		"fast":
			# play 时 _apply_fast() 已经处理过一遍，这里兜的是
			# "fast 点在 play 那一刻还没到、后来才被越过"的情况
			_shown = maxf(_shown, float(ev["at"]))
			visible_characters = int(_shown)
		"wait", "pause":
			var secs := float(ev["value"])
			if secs < 0.0:
				# 无参：无限等，等界面放行
				_waiting = true
				_wait_left = 0.0
				wait_reached.emit.call_deferred()
				return true
			if secs > 0.0:
				_waiting = true
				_wait_left = secs
				return true
			# 等 0 秒：不停
		"no_wait":
			_take_no_wait(float(ev["value"]))
	return false

## 记下 {nw}。多个 {nw} 取最早生效的那个 —— 第一处已经决定这句
## 不等点击，后面再写没有额外意义
func _take_no_wait(value: float) -> void:
	if _no_wait < 0.0:
		_no_wait = value
	else:
		_no_wait = minf(_no_wait, value)

## 从等待点继续。
func _resume() -> void:
	_waiting = false
	_wait_left = 0.0
	# 等待点正好落在句末时没有"继续打"可言，直接收尾
	if int(_shown) >= _total:
		visible_characters = -1
		_typed()

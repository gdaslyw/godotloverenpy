class_name VNTextTag
extends RefCounted

# ═══════════════════════════════════════════════════════════
#  {} 文本标签 → 富文本的唯一转换层。
#
#  ── 为什么中间隔一层 run，不直接拼 BBCode ──
#  同一个解析结果要喂给两种控件：正文是 RichTextLabel（要 BBCode），
#  历史和存档附言是 Label（要纯文本）。直接拼字符串的话，"剥纯文本"
#  就得反过来用正则去啃 BBCode，既容易错也丢信息。所以先解析成一串
#  run（每段自带完整样式快照），BBCode 只是它的一个输出形式：
#
#      原文 → tr → 插值 → parse() → run 数组 ─┬→ to_bbcode()
#                                              └→ to_plain()
#
#  将来加打字机事件（{w} {cps}）、加悬停高亮（meta），都只是给 run
#  添字段，两个输出出口跟着改一行，业务代码不动。
#
#  ── run 里存的是"快照"不是"增量" ──
#  每段 run 带上当时生效的全部样式，转 BBCode 时就不需要维护开关栈：
#  每段独立开闭，嵌套怎么写都不会串味。代价是 BBCode 会啰嗦一点，
#  但 RichTextLabel 解析这点标签的开销可以忽略。
#
#  ── 转义为什么是 {{ 而不是 \{ ──
#  lexer.gd 的 ESCAPES 只认 \" \\ \n \t 四种，其余转义直接报错。用 \{
#  就得改词法器，而且从此 \{ 会在词法层被吃掉，标签层再也看不到 —— 两套
#  转义叠在一起没法读。{{ 只在标签层闭环，单遍扫描就能处理。
#  Ren'Py 自己也是这么做的（renpy/display/behavior.py 把 {} 塞进带标签
#  文本时写的是 .replace("{", "{{")）。
#
#  ── 容错的分工 ──
#  编译期由 compiler.gd 调 parse() 取 errors，写错标签当场编译失败；
#  运行时这份 errors 完全不看 —— 译文是外部 PO，编辑器管不到，写错了
#  也不能让玩家端崩。所以**未知标签原样输出**（玩家看到 {foo}，作者能
#  立刻发现），**闭合不匹配的闭合标签直接丢掉**（它没有任何可见内容）。
# ═══════════════════════════════════════════════════════════

## 支持的成对标签。加标签时改这里、再在 _make_entry 里加一个分支。
##
## {/} 不在表里 —— 它不是某个标签的闭合，而是"把还没关的一次性关掉"，
## 见 parse() 里的那段分支。
const PAIRED := ["b", "i", "u", "s", "color", "size", "outline", "outlinecolor",
	"cps", "font", "url", "jump", "call", "a", "alpha"]

## 跳转类标签在 meta 里的前缀。
##
## {jump=} / {call=} 和外链走的是同一条 [url] 通道 —— 样式、悬停变色、
## "打字中点击只补完"全都共用，只在 meta_clicked 里按前缀分流。
## 加前缀而不是另设样式键，是因为 RichTextLabel 的 meta 只带一个字符串，
## 混在一起才需要区分。冒号分隔与 Ren'Py 的 hyperlink 协议写法一致。
const JUMP_PREFIX := "jump:"

## {call=label} 在 meta 里的前缀。
##
## 与 jump 的差别只在点中之后：jump 一去不回，call 在目标 label 走到
## return 时回到**触发它的那一句**（Ren'Py 的 from_current 语义）。
const CALL_PREFIX := "call:"

## {a=值} 在 meta 里的前缀。
##
## 这是给开发者的扩展口：框架完全不解释值，原样转成一个信号就完事。
## 加前缀是做**隔离**，不是做协议 —— 不带前缀的话，{a=jump:foo} 的 meta
## 和 {jump=foo} 会变成同一个字符串，那个值就会绕过开发者直接触发跳转。
## 剥掉这个前缀之后，剩下的就是一串普通文本，框架不会再拿它比对任何东西
const LINK_PREFIX := "a:"

## 自闭合的点事件标签：它们不改样式、不进栈，只在 events 里留一条
## "到此为止"的标记，由打字机按位置触发
const POINT_TAGS := ["w", "p", "nw", "fast"]

## 自闭合的"插一个东西"标签。它们各自占一个字符位 ——
## RichTextLabel 把 [img] 解析成一个空格、get_total_character_count()
## 算 1，所以 parse 的字符计数也必须 +1，否则它后面的 {w} {cps}
## 会整体错位一格
const SINGLE_TAGS := ["image"]

###########################################################
#  对外接口
###########################################################

## 把一段带 {} 标签的文本解析成 run 数组。
##
## base_size 是当前控件的正文字号，只在 {size=+10} / {size=*2} 这类
## 相对写法里用得上：RichTextLabel 的 [font_size] 只认绝对值，不知道
## 基线就算不出来。传 0 表示"没有基线"，此时相对写法退化成绝对值。
##
## 返回 { "runs": Array[Dictionary], "errors": Array[Dictionary] }：
##   runs 每项 { "text": String, "style": Dictionary }
##   errors 每项 { "offset": int, "message": String }
## offset 是 text 里的字符下标，编译期拿它换算成源文件列号。
static func parse(text: String, base_size: int = 0) -> Dictionary:
	var runs: Array[Dictionary] = []
	var events: Array[Dictionary] = []
	var errors: Array[Dictionary] = []
	# 打开中的标签栈。元素 { "name", "value", "at" }。
	# value 存在打开那一刻算好的**绝对值**（字号已经按当时的基线换算过），
	# 所以后面再改基线也不会动到已经开着的标签。at 是打开时的字符位置，
	# 只有 {cps} 用得上 —— 它要等到闭合那一刻才算得出区间的右端
	var stack: Array[Dictionary] = []
	# 尚未定型的纯文本。用数组而不是 String 只为一件事：数组是引用传递，
	# _flush() 能直接清空它，不必把字符串来回传
	var buf: Array[String] = []
	# 已经定型的字符数。事件位置全按它算：既不含花括号标签本身，
	# 也不含首行缩进（缩进由打字机在 play 时补偏移），
	# 与 RichTextLabel 的 visible_characters 是同一个坐标系
	var chars := 0

	var i := 0
	var n := text.length()
	while i < n:
		var ch := text[i]

		if ch == "{":
			# {{ 是字面花括号，不参与标签
			if i + 1 < n and text[i + 1] == "{":
				buf.append("{")
				i += 2
				continue

			var close := text.find("}", i + 1)
			if close < 0:
				# 裸 {：后面没有 }。原样留着，玩家看得见
				errors.append({
					"offset": i,
					"message": "花括号没有闭合；要写字面花括号请用 {{",
				})
				buf.append("{")
				i += 1
				continue

			var inner := text.substr(i + 1, close - i - 1)
			if inner.is_empty():
				errors.append({"offset": i, "message": "空标签 {}"})
				buf.append("{}")
			elif inner.begins_with("/"):
				var name := inner.substr(1)
				if name.is_empty():
					# {/}：把还没闭合的全部关掉，等价于在这里提前执行
					# 句末自动闭合。栈空时是空操作，不报错
					chars += _flush(runs, buf, stack)
					_close_cps(stack, 0, events, chars)
					stack.clear()
				else:
					var at := _find_open(stack, name)
					if at < 0:
						errors.append({
							"offset": i,
							"message": "闭合标签 {/%s} 没有对应的开标签" % name,
						})
					else:
						chars += _flush(runs, buf, stack)
						# 从栈顶一直弹到它（含）。写成 {b}{i}...{/b} 这种
						# 违反先开先关的写法时，i 也一并被关掉 —— 这是
						# 容错取舍：按"用户想关 b"来猜，比原样保留更合直觉。
						# 被一起弹掉的 {cps} 也要就地收尾，否则它的区间
						# 会一直拖到句末
						_close_cps(stack, at, events, chars)
						stack.resize(at)
			else:
				var eq := inner.find("=")
				var name := inner if eq < 0 else inner.substr(0, eq)
				var raw := "" if eq < 0 else inner.substr(eq + 1)
				var entry := _make_entry(name, raw, stack, base_size)
				if entry.is_empty():
					errors.append({
						"offset": i,
						"message": "未知或不支持的标签 {%s}" % inner,
					})
					buf.append("{%s}" % inner)
				elif name == "image":
					# 内联图自成一个 run：它没有文字，text 留空，
					# 靠 image / size 让输出端去查路径
					chars += _flush(runs, buf, stack)
					runs.append({
						"text": "",
						"style": {},
						"image": entry["image"],
						"size": entry["size"],
					})
					chars += 1
				elif POINT_TAGS.has(name):
					# 自闭合的点事件：不进栈，只在事件表里留一条
					chars += _flush(runs, buf, stack)
					if name == "p":
						# {p} 先断行再等。换行也算一个字符，事件落在它之后，
						# 于是打字机会先把行断掉、再停住
						buf.append("\n")
						chars += _flush(runs, buf, stack)
					entry["at"] = chars
					events.append(entry)
				else:
					chars += _flush(runs, buf, stack)
					entry["at"] = chars
					stack.append(entry)
			i = close + 1

		elif ch == "}":
			# }} 是字面右花括号
			if i + 1 < n and text[i + 1] == "}":
				buf.append("}")
				i += 2
			else:
				errors.append({
					"offset": i,
					"message": "多余的 }；要写字面花括号请用 }}",
				})
				buf.append("}")
				i += 1

		else:
			buf.append(ch)
			i += 1

	# 句末还有没闭合的标签：按 Ren'Py 的行为自动闭合，不报错。
	# 译文漏写 {/b} 是很常见的手误，为它让整句变成错误不值
	chars += _flush(runs, buf, stack)
	_close_cps(stack, 0, events, chars)

	# 按位置排序：{cps} 是等到闭合那一刻才补进事件表的，位置可能比
	# 后面那些点事件更靠前。打字机按升序逐条消费，必须排好
	events.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a["at"]) < int(b["at"]))

	return {"runs": runs, "events": events, "errors": errors}


## 转成 RichTextLabel 认得的一串 BBCode。
##
## base_size 同 parse()，只影响相对字号。images / link_style / base_color 见
## runs_to_bbcode()。
static func to_bbcode(text: String, base_size: int = 0,
		images: Dictionary = {}, link_style: Dictionary = {},
		base_color: Color = Color.WHITE) -> String:
	return runs_to_bbcode(parse(text, base_size)["runs"], images, link_style,
		base_color)


## 把已经解析好的 runs 转成 BBCode。
##
## 与 to_bbcode() 的区别只是"解析过没有"：正文那边要先 parse 拿到
## events 交给打字机，再拿同一份 runs 来转 —— 解析两遍纯属浪费。
##
## images 是"图像 ID → res:// 路径"的表（VN.images()）。只有 {image=}
## 用得上；不传就当作查不到，图直接不出现。
##
## link_style 是链接外观：{ "idle": Color, "hover": Color,
## "hover_id": String, "underline": bool }。{url=} 的开标签把它写进
## [url] 的参数里；hover_id 与地址相同时用 hover 色
##
## base_color 是控件正文字色的基线，只有 {alpha} 用得上 —— 只写透明度
## 不写颜色时，得知道要透明的那个颜色原本是什么
static func runs_to_bbcode(runs: Array, images: Dictionary = {},
		link_style: Dictionary = {},
		base_color: Color = Color.WHITE) -> String:
	var parts := PackedStringArray()
	for run: Dictionary in runs:
		# 内联图：路径在这一步才查。parse 保持纯文本处理，不碰资源表 ——
		# 否则 to_plain() 也得带一份表进来
		if run.has("image"):
			var path := String(images.get(String(run["image"]), ""))
			if not path.is_empty():
				parts.append("[img height=%s]%s[/img]" % [run["size"], path])
			continue

		var style: Dictionary = run["style"]
		# 字体名到路径的解析同理，也只在这里做
		var font_path := ""
		if style.has("font"):
			font_path = VNI18n.inline_font_path(String(style["font"]))
		parts.append(_open_tags(style, font_path, link_style, base_color))
		parts.append(_escape_bbcode(String(run["text"])))
		parts.append(_close_tags(style, font_path))
	return "".join(parts)


## 剥成纯文本。历史面板和存档附言用的是 Label，没法吃 BBCode。
##
## 这里**不返回 BBCode 再剥**：直接拼 run 的 text，顺带把 {{ }} 解掉，
## 一步到位，也不用担心 "[" 这类字符被误伤。
static func to_plain(text: String) -> String:
	var parsed := parse(text)
	var parts := PackedStringArray()
	for run: Dictionary in parsed["runs"]:
		parts.append(String(run["text"]))
	return "".join(parts)

###########################################################
#  内部：扫描
###########################################################

## 把缓冲区里的文字定成一段 run 并清空，返回这一段有多少字符。
##
## 返回字符数是为了让调用方累出事件位置：事件按可见字符计，
## 而 run 正是那批字符的载体。buf 为空时返回 0 且什么都不做 ——
## 连续两个开标签（{b}{i}）不该产生空 run。
static func _flush(runs: Array[Dictionary], buf: Array[String],
		stack: Array[Dictionary]) -> int:
	if buf.is_empty():
		return 0
	var text := "".join(buf)
	runs.append({"text": text, "style": _collapse(stack)})
	buf.clear()
	return text.length()


## 把栈里从 from_index 起（含）还开着的 {cps} 收尾，区间右端记为 chars。
##
## 只认 cps：其余标签没有"区间"这个属性，直接弹掉就行。
## 倒着扫是为了让内层先于外层收尾，events 读起来和源码顺序一致
static func _close_cps(stack: Array[Dictionary], from_index: int,
		events: Array[Dictionary], chars: int) -> void:
	for k in range(stack.size() - 1, from_index - 1, -1):
		var entry: Dictionary = stack[k]
		if String(entry["name"]) != "cps":
			continue
		events.append({
			"at": int(entry["at"]),
			"end": chars,
			"kind": "cps",
			"value": entry["value"],
		})


## 从栈顶往下找同名标签，返回它的下标；没有则返回 -1。
static func _find_open(stack: Array[Dictionary], name: String) -> int:
	for i in range(stack.size() - 1, -1, -1):
		if String(stack[i]["name"]) == name:
			return i
	return -1


## 当前生效的正文字号。栈里没有 size 就落到控件基线。
static func _current_size(stack: Array[Dictionary], base_size: int) -> int:
	for i in range(stack.size() - 1, -1, -1):
		if String(stack[i]["name"]) == "size":
			return int(stack[i]["value"])
	return base_size


## 当前生效的透明度。栈里没有 alpha 就是完全不透明。
##
## {alpha=+0.2} / {alpha=*0.5} 这类相对写法要拿它当基准，
## 所以取值和解析是两个函数：这个只回答"现在是多少"，不算新值
static func _current_alpha(stack: Array[Dictionary]) -> float:
	for i in range(stack.size() - 1, -1, -1):
		if String(stack[i]["name"]) == "alpha":
			return float(stack[i]["value"])
	return 1.0


## 把整条标签栈折叠成一份完整样式快照。
##
## 键只在"被显式设置过"时出现：{size} 出现在 {b} 里时，快照里同时有
## b 和 size；没有 color 就不写 color 键，输出时也不会凭空冒出 [color]。
static func _collapse(stack: Array[Dictionary]) -> Dictionary:
	var style := {}
	for entry in stack:
		var name := String(entry["name"])
		match name:
			"b", "i", "u", "s":
				style[name] = true
			"color":
				style["color"] = entry["value"]
			"size":
				style["size"] = entry["value"]
			"outline":
				style["outline"] = entry["value"]
			# outlinecolor 在样式里的键名换成 Godot 的写法，
			# 免得输出 BBCode 时再映射一次
			"outlinecolor":
				style["outline_color"] = entry["value"]
			# font 存的是名字不是路径：路径要查字体目录，那是输出端的事
			"font":
				style["font"] = entry["value"]
			# url 也存地址原文，颜色和 underline 由输出端按作品配置拼。
			# jump / call / a 也落到同一个样式键：输出端只认 style["url"]，
			# 值里的前缀已经决定了点击时走哪条路
			"url", "jump", "call", "a":
				style["url"] = entry["value"]
			# alpha 存的是已经结算过的绝对值，与 size 同理
			"alpha":
				style["alpha"] = entry["value"]
	return style


## 校验一个开标签，合格就返回栈元素 { "name", "value" }，否则返回空字典。
##
## name 是用户写的原样（小写），value 一律换算成**绝对值**：
## {size=+10} 存进去的是 60 而不是 +10，这样同一段文字后面再改基线，
## 已经开着的标签也不会跟着变。
static func _make_entry(name: String, raw: String,
		stack: Array[Dictionary], base_size: int) -> Dictionary:
	# 白名单先过一遍。match 的 default 也能兜住未知标签，但那张表集中
	# 说明了"到底支持哪些"，作者和将来的改动都从这里看
	if not PAIRED.has(name) and not POINT_TAGS.has(name) \
			and not SINGLE_TAGS.has(name):
		return {}

	match name:
		"b", "i", "u", "s":
			# 这四个不带参数。{b=1} 这种写法要报出来，
			# 否则作者会以为参数起了作用
			if not raw.is_empty():
				return {}
			return {"name": name, "value": true}

		"color", "outlinecolor":
			var hex := _normalize_color(raw)
			if hex.is_empty():
				return {}
			return {"name": name, "value": hex}

		"size":
			var size := _resolve_size(raw, _current_size(stack, base_size))
			if size < 0:
				return {}
			return {"name": name, "value": size}

		"outline":
			if not raw.is_valid_int():
				return {}
			var width := raw.to_int()
			if width < 0:
				return {}
			return {"name": name, "value": width}

		"font":
			var fname := raw.strip_edges()
			if fname.is_empty():
				return {}
			# 必须带 .ttf / .otf 后缀，且只能是文件名 ——
			# 字体目录由作品配置决定，写路径的一律在编译期报错
			if fname.contains("/") or fname.contains("\\"):
				return {}
			var ext := fname.get_extension().to_lower()
			if ext != "ttf" and ext != "otf":
				return {}
			return {"name": name, "value": fname}

		"url":
			var addr := raw.strip_edges()
			# 只放行 http/https。地址最终会交给 OS.shell_open，
			# file:// 之类让系统去开是危险的，何况台词里没有正当用途
			var lower := addr.to_lower()
			if not (lower.begins_with("http://")
					or lower.begins_with("https://")):
				return {}
			return {"name": name, "value": addr}

		"jump", "call":
			# 目标是 label 名。这里只挡住"根本不可能是个名字"的写法 ——
			# 名字对不对由编译期查整包 label 表，那是标签层看不见的东西，
			# 而运行时的译文是外部文件，target 查不到也有兜底
			var target := raw.strip_edges()
			if target.is_empty() or target.contains(" ") \
					or target.contains("\t"):
				return {}
			# 值里带上前缀，样式就落到 url 那份里，
			# 点击时看前缀就知道该跳剧情、读一段再回来，还是开浏览器
			var prefix := JUMP_PREFIX if name == "jump" else CALL_PREFIX
			return {"name": name, "value": prefix + target}

		"a":
			# 开发者的扩展口。除了"不能是空的、不能带空格"，这里什么都不拦 ——
			# 冒号、斜杠之类都随作者写，因为含义由订阅方定义。
			#
			# 空格必须挡掉：值最终写进 [url href=... underline=...] 的 options，
			# 而 options 是按空格切分的 —— 带空格的值会被切成两段，
			# href 只剩前半截，后半截当成未知参数丢掉。要传复杂内容，
			# 用逗号、竖线这类不含空格的自己约定分隔符
			var payload := raw.strip_edges()
			if payload.is_empty() or payload.contains(" ") \
					or payload.contains("\t"):
				return {}
			return {"name": "a", "value": LINK_PREFIX + payload}

		"alpha":
			# 与 {size} 同一个套路：存**绝对值**，相对写法在解析这一刻就结算掉。
			# 不这么做的话，嵌套里再改一次外层就没法复现 —— 而 Alpha 是
			# 逐层相乘/相加出来的，必须固定在当前上下文里
			var opacity := _resolve_alpha(raw, _current_alpha(stack))
			if opacity < 0.0:
				return {}
			return {"name": "alpha", "value": opacity}

		"image":
			return _make_image_entry(raw)

		"cps":
			if raw.is_empty():
				return {}
			# *2 是"当前速度的倍数"，真正的秒数要到运行时才知道。
			# 倍数存成负数，和绝对速度区分开
			if raw.begins_with("*"):
				var body := raw.substr(1)
				if not body.is_valid_float():
					return {}
				return {"name": "cps", "value": -body.to_float()}
			if not raw.is_valid_float():
				return {}
			var speed := raw.to_float()
			if speed < 0.0:
				return {}
			return {"name": "cps", "value": speed}

		"w", "p":
			# 无参是"等点击"，存 -1 好和"等 0 秒"区分开
			var wait_secs := -1.0
			if not raw.is_empty():
				if not raw.is_valid_float():
					return {}
				wait_secs = raw.to_float()
				if wait_secs < 0.0:
					return {}
			return {
				"kind": "wait" if name == "w" else "pause",
				"value": wait_secs,
			}

		"nw":
			# 无参是"打完立刻走"，等价于 0 秒
			var nw_secs := 0.0
			if not raw.is_empty():
				if not raw.is_valid_float():
					return {}
				nw_secs = raw.to_float()
				if nw_secs < 0.0:
					return {}
			return {"kind": "no_wait", "value": nw_secs}

		"fast":
			if not raw.is_empty():
				return {}
			return {"kind": "fast", "value": 0.0}

	return {}


## 解析 {image=id,尺寸} 的参数。
##
## 尺寸可选，默认 1em —— 与一行文字等高，是 Ren'Py 对行内图的默认设想。
## 允许给尺寸是因为 1em 在 50 号字下只有 50px，细节多的图会糊
static func _make_image_entry(raw: String) -> Dictionary:
	if raw.is_empty():
		return {}

	var comma := raw.find(",")
	var id := raw if comma < 0 else raw.substr(0, comma)
	id = id.strip_edges()
	if id.is_empty():
		return {}

	var size := "1em"
	if comma >= 0:
		size = _resolve_image_size(raw.substr(comma + 1))
		if size.is_empty():
			return {}
	return {"kind": "image", "image": id, "size": size}


## {image=id,尺寸} 里尺寸那一段，返回能直接写进 [img height=...] 的值。
##
## 空串表示"没写"，按 1em 处理（和一行文字等高）。
## 纯数字按像素，带 em 后缀按当前字号倍数。
##
## 只支持高度：宽度交给 RichTextLabel 按原图比例算。写成 width 会让排版
## 以宽度为基准，同一张图在不同字号下就会变形。
## 非法返回空串，调用方据此报到 errors 里
static func _resolve_image_size(raw: String) -> String:
	var text := raw.strip_edges()
	if text.is_empty():
		return "1em"

	if text.ends_with("em"):
		var num := text.substr(0, text.length() - 2)
		if not num.is_valid_float():
			return ""
		if num.to_float() <= 0.0:
			return ""
		return "%sem" % num

	if text.is_valid_int():
		if text.to_int() <= 0:
			return ""
		return text

	return ""


###########################################################
#  内部：取值
###########################################################

## 把 #rgb / #rgba / #rrggbb / #rrggbbaa 统一展开成 Godot 认的 6 位或 8 位。
##
## RichTextLabel 不认 3 位和 4 位的短写法，而 Ren'Py 三种都收，
## 所以短的在这里补全：#f00 → #ff0000，#f00a → #ff0000aa。
## 非法时返回空串，调用方据此报到 errors 里。
static func _normalize_color(raw: String) -> String:
	if not raw.begins_with("#"):
		return ""
	var hex := raw.substr(1)
	if not hex.is_valid_hex_number():
		return ""
	match hex.length():
		3, 4:
			var expanded := "#"
			for i in hex.length():
				expanded += hex[i] + hex[i]
			return expanded
		6, 8:
			return "#" + hex
	return ""


## 解析 {size} 的参数，返回绝对字号。
##
## 四种写法：24（绝对值）、+10 / -10（在当前值上加减）、*2（乘，向下取整，
## 和 Ren'Py 文档写的 "multiplied by that number and then rounded down" 一致）。
## 非法返回 -1。
static func _resolve_size(raw: String, current: int) -> int:
	if raw.is_empty():
		return -1

	var head := raw[0]
	var body := raw.substr(1)

	if head == "+" or head == "-":
		if not body.is_valid_int():
			return -1
		# raw.to_int() 对 "-10" 自带符号，直接加即可
		return maxi(1, current + raw.to_int())

	if head == "*":
		if not body.is_valid_float():
			return -1
		return maxi(1, int(floor(body.to_float() * float(current))))

	if not raw.is_valid_int():
		return -1
	return maxi(1, raw.to_int())


## 解析 {alpha} 的参数，返回绝对透明度（0 全透明，1 不透明）。
##
## 三种写法与 Ren'Py 一致：0.5（绝对值）、+0.2 / -0.2（在当前值上加减）、
## *0.5（乘）。结果夹到 [0, 1] —— 越界的透明度没有意义，
## 而宽进严出比让作者去猜为什么字消失了更友好。非法返回 -1。
static func _resolve_alpha(raw: String, current: float) -> float:
	var text := raw.strip_edges()
	if text.is_empty():
		return -1.0

	if text.begins_with("*"):
		var body := text.substr(1)
		if not body.is_valid_float():
			return -1.0
		return clampf(current * body.to_float(), 0.0, 1.0)

	if not text.is_valid_float():
		return -1.0
	if text.begins_with("+") or text.begins_with("-"):
		return clampf(current + text.to_float(), 0.0, 1.0)
	return clampf(text.to_float(), 0.0, 1.0)


###########################################################
#  内部：输出
###########################################################

## 一段样式的开工标签。顺序固定，保证每次输出的嵌套关系一致。
##
## font_path 由调用方查好再传进来：字体名到路径的解析要碰作品配置，
## 不该让这个纯拼接函数知道。link_style 同理，只用来挑 url 的颜色。
##
## base_color 是控件正文字色的基线，只有 {alpha} 用得上：RichTextLabel
## 没有独立的透明度标签，只能合成进 [color] 的第四个字节，而"只要透明、
## 没写颜色"时也必须知道 RGB 是多少
static func _open_tags(style: Dictionary, font_path := "",
		link_style: Dictionary = {},
		base_color: Color = Color.WHITE) -> String:
	var out := ""
	# 颜色排最外层。链接的常态/悬停色只能用 [color] 给 ——
	# [url] 的 options 只认 href / underline / tooltip，没有颜色。
	# 作者显式写了 {color} 时以作者为准，那一段就不再套链接色
	var color := String(style.get("color", ""))
	if color.is_empty() and style.has("url"):
		color = _link_color(String(style["url"]), link_style)
	# 透明度并进颜色：作者写了 {color} 就用它当底，没写就用控件正文色。
	# 悬停变色走的也是这一条路，所以链接高亮时透明度不会丢
	if style.has("alpha"):
		var base := color
		if base.is_empty():
			base = "#" + base_color.to_html(false)
		color = _with_alpha(base, float(style["alpha"]))
	if not color.is_empty():
		out += "[color=%s]" % color

	# url 在颜色之内、其余样式之外：它包住的整段文字都可点
	if style.has("url"):
		out += _url_open(String(style["url"]), link_style)
	if style.get("b", false):
		out += "[b]"
	if style.get("i", false):
		out += "[i]"
	if style.get("u", false):
		out += "[u]"
	if style.get("s", false):
		out += "[s]"
	if style.has("size"):
		out += "[font_size=%d]" % style["size"]
	if style.has("outline"):
		out += "[outline_size=%d]" % style["outline"]
	if style.has("outline_color"):
		out += "[outline_color=%s]" % style["outline_color"]
	if not font_path.is_empty():
		out += "[font=%s]" % font_path
	return out


## 一个 {url=} 的开标签。
##
## 参数走 RichTextLabel 的 options 形式：[url href=地址 underline=模式]。
## 注意这里**不能**写成 [url=地址 ...] —— 等号右边整段都会被当成 href，
## 于是 "地址 color=#xxx" 一股脑塞进去，点开就是一个带空格的坏链接
static func _url_open(address: String, link_style: Dictionary) -> String:
	var mode := String(link_style.get("underline", "always"))
	return "[url href=%s underline=%s]" % [address, mode]


## 链接当前的显示颜色：默认用常态色，地址与悬停中的地址相同时用悬停色。
static func _link_color(address: String, link_style: Dictionary) -> String:
	var color: Color = link_style.get("idle", Color.WHITE)
	if String(link_style.get("hover_id", "")) == address:
		color = link_style.get("hover", color)
	return "#" + color.to_html(false)


## 把一个 #rgb / #rrggbb / #rrggbbaa 的颜色换成指定透明度，返回 #rrggbbaa。
##
## 走 Color 而不是自己拼字符串：短写法的补全、8 位原色的截断都由它兜着，
## 这里只需要回答"换成这个透明度之后长什么样"
static func _with_alpha(hex: String, alpha: float) -> String:
	var color := Color(hex)
	color.a = clampf(alpha, 0.0, 1.0)
	return "#" + color.to_html(true)


## 一段样式的收工标签。必须是 _open_tags() 的逆序 —— BBCode 是栈式的，
## 乱序闭合在 RichTextLabel 里会把后面的样式带歪。
static func _close_tags(style: Dictionary, font_path := "") -> String:
	var out := ""
	if not font_path.is_empty():
		out += "[/font]"
	if style.has("outline_color"):
		out += "[/outline_color]"
	if style.has("outline"):
		out += "[/outline_size]"
	if style.has("size"):
		out += "[/font_size]"
	if style.get("s", false):
		out += "[/s]"
	if style.get("u", false):
		out += "[/u]"
	if style.get("i", false):
		out += "[/i]"
	if style.get("b", false):
		out += "[/b]"
	if style.has("url"):
		out += "[/url]"
	# 颜色可能是作者写的，也可能是 _open_tags() 为链接或 {alpha} 补的，
	# 这几种都要关。三者共用同一个 [color]，只关一次
	if style.has("color") or style.has("url") or style.has("alpha"):
		out += "[/color]"
	return out


## 转义文本里的方括号。
##
## 必须的：变量插值出来的值和译文都可能带 "["，RichTextLabel 会当成
## BBCode 去解析，轻则丢字重则整句样式错乱。BBCode 自己的转义是
## [lb] / [rb]，逐字符替换而不是链式 replace —— 后者会把刚生成的
## [lb] 里的 "[" 二次转义成 [lb]lb]
static func _escape_bbcode(text: String) -> String:
	var parts := PackedStringArray()
	for ch in text:
		match ch:
			"[":
				parts.append("[lb]")
			"]":
				parts.append("[rb]")
			_:
				parts.append(ch)
	return "".join(parts)

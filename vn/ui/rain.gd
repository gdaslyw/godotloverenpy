class_name VNRain
extends ColorRect

# ═══════════════════════════════════════════════════════════
#  舞台上的雨。
#
#  剧本里就是普通的舞台内容，走 show / hide / scene 那一套：
#      show rain                       # 默认档 normal，瞬时出现
#      show rain light                 # 细雨，1 秒渐变过去
#      show rain heavy(2.0)            # 大雨，2 秒渐变过去
#      show rain heavy(2.0) angle(20)  # 同上，同时把雨丝向右斜 20 度
#      show rain angle(-15)            # 只改风向，向左斜 15 度
#      hide rain                       # 雨停
#      scene bg2                       # 雨被清掉，之后要重新 show rain
#
#  属性能写两种词，顺序无所谓：
#      强度档位  light / normal / heavy，括号里是过渡秒数
#      倾角      angle(度)，负号照写，angle(-15) 等价于 angle(345)
#  都不写就是 normal + 默认时长 + 当前倾角。
#  倾角会一直保留到下一次写 angle() —— 切档不会顺手把风向改回垂直。
#
#  ── 为什么继承 ColorRect ──
#  雨的每一帧都由 shader 算，节点只负责"铺满屏幕 + 挂材质"。
#  ColorRect 是 Control 里最直接的载体，而且天然兼容舞台的两件事：
#  转场按 CanvasItem.modulate.a 做淡入淡出（VNTransition.set_alpha），
#  屏幕尺寸由 stretch 统一处理，节点不用关心实际窗口分辨率。
#
#  ── 切档为什么不重建节点 ──
#  重建会让雨从"没有"重新长出来，中间有一帧是空的。原地更新只改
#  shader 的 uniform，雨丝一直在落，只是变密变快 —— 这才是天气在变。
#
#  ── 属性词为什么取最后一个 ──
#  VNSession._merge_attrs() 把属性串按写入顺序排列，重写的词会移到末尾。
#  所以串里最后一个强度词就是这次写的那个。取第一个会让"切回去"失效。
# ═══════════════════════════════════════════════════════════

## 雨丝 shader。同目录，随本脚本一起进框架
const RAIN_SHADER := preload("res://vn/shader/rain.gdshader")

## 三档强度。键就是剧本里写的属性词，值是直接推给 shader 的 uniform。
## 四组数各自管一件事，不是随便调的：
##   intensity  总体不透明度
##   speed      每秒扫过几个屏幕高度
##   length     单根雨丝的长度（屏幕高度比例）
##   width      横向粗细（列宽比例）
##   density    每列第二根雨丝的显现程度 —— 这是"变密"而不只是"变亮"
const LEVELS := {
	"light": {"intensity": 0.50, "speed": 1.40, "length": 0.12, "width": 0.075, "density": 0.15},
	"normal": {"intensity": 0.80, "speed": 2.00, "length": 0.18, "width": 0.095, "density": 0.55},
	"heavy": {"intensity": 1.00, "speed": 2.80, "length": 0.26, "width": 0.125, "density": 0.95},
}

## 没写档位时的默认档
const DEFAULT_LEVEL := "normal"

## 没写数字时的过渡时长（秒）
const DEFAULT_DURATION := 1.0

## 只用于 CPU 侧累积滚动距离的参数名。它**不对应任何 shader uniform** ——
## shader 收到的是累积结果 u_scroll
const SPEED_PARAM := "speed"

## 倾角在属性串里的词名，写法是 `angle(20)`，单位是度。
##
## 角度和档位是两类词，各自带自己的括号参数：
##   heavy(2.0)   → 切到 heavy，过渡 2.0 秒
##   angle(20)    → 倾角 20 度
## 括号由编译器解析成一个整体词（见 VNParser._parse_attr_args），
## 所以它们在属性串里不会被 VNSession._merge_attrs() 的重排拆散
const ANGLE_KEYWORD := "angle"

## 倾角参数名。它在 _params 里但不在 LEVELS 里 —— 档位管不到的旋钮
const SLANT_PARAM := "slant"

## 没写 angle 时的默认倾角（度）。0 是垂直下落，正数向右斜
const RAIN_ANGLE := 0.0

## 雨丝颜色。rgb 改色调，a 改单根雨丝的峰值不透明度 ——
## 实机看着不顺眼就调这一行
const RAIN_COLOR := Color(1.0, 1.0, 1.0, 0.55)

## 当前各 uniform 的值。切档时从这里面读起点，tween 一路改到终点
var _params: Dictionary = {}

## 挂在本节点上的材质。只在 _build_material() 里创建一次
var _material: ShaderMaterial = null

## 正在跑的切档 tween。再切一次要先把它掐掉，否则两组 tween 会互相打架
var _tween: Tween = null

## 当前档位名。只用于读档与调试，不参与渲染
var _level := DEFAULT_LEVEL

## 已经下落过的距离，单位是"屏幕高度"。每帧按当前速度累加，推给 u_scroll。
##
## ── 为什么不让 shader 直接用 TIME ──
## phase = fract(uv.y - TIME * speed)。TIME 是绝对值，speed 一要变，
## TIME * speed 就整体跳一次，跳的幅度正比于已经跑过的时间 ——
## 游戏跑几分钟之后切一次档，雨会整片向上飞，等 tween 结束才恢复。
## 累积量没有这个毛病：速度变化只影响"每帧加多少"，位置始终连续
var _scroll := 0.0

## setup() 时写了时长的话，目标档与时长先存在这里。
## Node.create_tween() 要求节点已经在场景树里，而 setup() 在入树之前调用 ——
## 所以真正的渐变要等 _ready() 再启动
var _pending_level := ""
var _pending_duration := 0.0
var _pending_slant := 0.0

###########################################################
#  构造
###########################################################

## 常量字典是只读的，而参数要能逐帧改，所以拷一份出来。
## 倾角不在 LEVELS 里（它不是档位的一部分），单独补进去，
## 这样 _set_param() 遍历 _params 时也能一并推给 shader
func _init() -> void:
	_params = (LEVELS[DEFAULT_LEVEL] as Dictionary).duplicate()
	_params[SLANT_PARAM] = tan(deg_to_rad(RAIN_ANGLE))

## 入树之前由 VNStage 调用，按属性决定初始档位。
##
## 首次 show 时写了数字就是"雨慢慢下起来"：从完全透明开始，在指定时长里
## 补到目标档。没写数字就瞬时出现 —— 雨第一次出现在画面上时它本来就已经
## 在下着了，那一下的观感该由舞台转场（with dissolve）负责
func setup(attrs: PackedStringArray) -> void:
	_build_material()

	var parsed := _parse_attrs(attrs, 0.0)
	var duration := float(parsed["duration"])
	if duration > 0.0:
		# 渐变留到 _ready()。起点设为完全透明，否则会先以默认档显形再变
		_pending_level = String(parsed["level"])
		_pending_duration = duration
		_pending_slant = float(parsed[SLANT_PARAM])
		_set_param("intensity", 0.0)
		return

	_apply_level(String(parsed["level"]), 0.0, float(parsed[SLANT_PARAM]))

###########################################################
#  舞台契约
###########################################################

## 舞台属性变了。返回 true 表示原地更新完毕，不需要重建节点。
##
## 只认档位、过渡秒数和倾角，其余的词一概忽略 —— 雨没有"变体"，
## 多写的属性没有意义，不该因此把整层雨推倒重来
func apply_attrs(attrs: PackedStringArray) -> bool:
	var parsed := _parse_attrs(attrs, DEFAULT_DURATION)
	_apply_level(String(parsed["level"]), float(parsed["duration"]),
		float(parsed[SLANT_PARAM]))
	return true

###########################################################
#  节点
###########################################################

func _ready() -> void:
	# 铺满屏幕。舞台把它直接挂在 CanvasLayer 下，父级不是 Control，
	# 锚点因此以视口为基准 —— 窗口缩放交给 stretch 统一处理
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# 舞台的 _disable_mouse() 会再设一次，这里自己设一遍：
	# 单独拿来用的时候也不该把点击整个吞掉（那会让剧情点不动）
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	# ColorRect 的底色会被 shader 完全覆盖，但它的 alpha 会进 COLOR ——
	# 设成透明的话整个节点根本不会被绘制
	color = Color.WHITE
	# 锚点算不出矩形时（父级不是 Control 又没有可视区），给一个全屏尺寸兜底。
	# 正常情况下走不到这一支，多这一句是为了"雨层尺寸为 0、屏幕上什么都没有"
	# 这种最难查的故障不出现
	if size.x <= 0.0 or size.y <= 0.0:
		size = get_viewport_rect().size
	# 没走 setup() 直接 new 出来的情况（比如以后别处复用）兜个底
	_build_material()

	# setup() 写下的首次渐变到这里才真正开始。
	# _ready 里节点已经入树，create_tween() 才有地方挂
	if not _pending_level.is_empty():
		_apply_level(_pending_level, _pending_duration, _pending_slant)
		_pending_level = ""
		_pending_duration = 0.0
		_pending_slant = 0.0

## 每帧把"下落了多少"累加到滚动距离上。
##
## 这一帧的增量用的就是当前 speed —— tween 期间它在变，累积出来的位置
## 因此是连续的。shader 只负责把累积量画成雨丝，不碰时间
func _process(delta: float) -> void:
	_scroll += delta * float(_params.get(SPEED_PARAM, 0.0))
	if _material != null:
		_material.set_shader_parameter("u_scroll", _scroll)

## 建材质并铺上当前参数。已经建过就直接返回，重复调用安全
func _build_material() -> void:
	if _material != null:
		return

	_material = ShaderMaterial.new()
	_material.shader = RAIN_SHADER
	_material.set_shader_parameter("u_color", RAIN_COLOR)
	_material.set_shader_parameter("u_scroll", _scroll)
	for key in _params:
		if key == SPEED_PARAM:
			continue
		_material.set_shader_parameter("u_" + key, float(_params[key]))

	material = _material

###########################################################
#  档位
###########################################################

## 切到某一档。duration <= 0 是瞬时切换。
##
## slant 是斜率（tan 角度），和四个档位参数一起 tween —— 切档的同时
## 风向变了，两者该是同一个动作。
##
## 不透明度刻意滞后四分之一时长：先看到雨丝变快变长，再看到它变浓。
## 四个参数齐步走的话，视觉上更像"这一层在整体变亮"，而不是天气在变
func _apply_level(level_: String, duration: float, slant: float) -> void:
	_level = level_
	# 档位参数 + 倾角。倾角不归档位管，所以复制出来再单独塞进去
	var target: Dictionary = (LEVELS[level_] as Dictionary).duplicate()
	target[SLANT_PARAM] = slant

	_kill_tween()

	if duration <= 0.0:
		for key in target:
			_set_param(key, float(target[key]))
		return

	# 树外不能建 tween —— Node.create_tween() 要求节点已经在场景树里，
	# 否则返回 null。正常路径走不到这里（setup 已经把首次渐变推迟到
	# _ready），留着这一支是为了任何在树外调用 apply_attrs() 的路径
	# 都只是"瞬间到档"而不是崩溃
	if not is_inside_tree():
		for key in target:
			_set_param(key, float(target[key]))
		return

	_tween = create_tween()
	_tween.set_parallel(true)
	for key in target:
		var from: float = float(_params.get(key, target[key]))
		# 不透明度延后开始，总时长仍等于 duration
		var span := duration
		var delay := 0.0
		if key == "intensity":
			span = duration * 0.75
			delay = duration * 0.25

		var tweener: MethodTweener = _tween.tween_method(
			_make_setter(key), from, float(target[key]), span)
		tweener.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
		if delay > 0.0:
			tweener.set_delay(delay)

## 掐掉正在跑的 tween。切档必须从**当前值**出发 —— 上一段渐变走到一半时
## 又切一次，起点是它此刻的真实值，不是上一档的目标值
func _kill_tween() -> void:
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_tween = null

## 给某个 uniform 造一个 setter。
##
## 不在循环里直接写 lambda：闭包捕获的是循环变量本身，
## 等回调真正触发时它可能已经不是建这个回调时的值了
func _make_setter(key: String) -> Callable:
	return func(value: float) -> void: _set_param(key, value)

## 写一个参数。参数名统一加 u_ 前缀，和 shader 里的 uniform 对上。
##
## speed 是例外：它不推给 shader，只喂给 _process 去累积滚动距离，
## shader 那边拿到的是累积结果 u_scroll
func _set_param(key: String, value: float) -> void:
	_params[key] = value
	if _material == null or key == SPEED_PARAM:
		return
	_material.set_shader_parameter("u_" + key, value)

###########################################################
#  属性解析
###########################################################

## 解析属性串，返回 { level: String, duration: float, slant: float }。
##
## 两种词，顺序无所谓，各自带一个括号参数：
##   light / normal / heavy   档位。括号里是过渡秒数：heavy(2.0)
##   angle                    倾角。括号里是度数：angle(20)
##
## 度数与数学角度一致，负号照写：angle(0) 垂直、angle(15) 向右斜、
## angle(-15) 向左斜。angle(-15) 和 angle(345) 完全等价，tan 那边是同一个值。
##
## 裸数字**不认**：时长只能写进档位的括号里。认不出的词静默忽略 ——
## 属性串里会留下历史词（`_merge_attrs` 只做去重和重排，不删除），
## 对它们报警告会在每次切档时刷屏
##
## 括号是编译器拼进词里的，见 VNParser._parse_attr_args()
##
## slant 的初值是**当前值**：没写 angle 就保持原样，切档不该顺手把风向改回去
func _parse_attrs(attrs: PackedStringArray, fallback: float) -> Dictionary:
	var level_ := DEFAULT_LEVEL
	var duration := fallback
	var slant := float(_params.get(SLANT_PARAM, 0.0))

	for word in attrs:
		var key := String(word)
		var args := PackedStringArray()

		# 拆出 "heavy(2.0)" 这样的词。编译器保证括号配对，
		# 这里按第一个 ( 和末尾的 ) 切就够了
		var open := key.find("(")
		if open >= 0 and key.ends_with(")"):
			args = key.substr(open + 1, key.length() - open - 2).split(",", false)
			key = key.substr(0, open)

		if LEVELS.has(key):
			level_ = key
			# 第一个参数是过渡时长。多写的参数忽略 ——
			# 档位只有"用多久切过去"一个旋钮
			var span := _arg(args, 0)
			if span.is_valid_float():
				duration = maxf(0.0, span.to_float())
			continue

		if key == ANGLE_KEYWORD:
			var degrees := _arg(args, 0)
			if degrees.is_valid_float():
				slant = tan(deg_to_rad(degrees.to_float()))
			continue

	# 键名用 SLANT_PARAM 的值，所以先建字典再下标写入 ——
	# 字典字面量里的裸标识符是**字符串键**，不是那个常量的值
	var result := {"level": level_, "duration": duration}
	result[SLANT_PARAM] = slant
	return result

## 取第 index 个括号参数。
## 越界或没有括号时返回空串 —— 调用方用 is_valid_float() 一并挡掉
func _arg(args: PackedStringArray, index: int) -> String:
	if index < 0 or index >= args.size():
		return ""
	return String(args[index]).strip_edges()

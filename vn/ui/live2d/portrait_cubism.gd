class_name VNPortraitCubism
extends GDCubismUserModel

# ═══════════════════════════════════════════════════════════
#  Live2D 立绘后端。把一个 (角色 ID, 属性表) 变成屏幕上的模型。
#
#  它是 VNStage.resolve() 分派的三个后端里最重的一个：
#  静态图是一张贴图，视频是一个流，而这里要读 .model3.json、
#  加载 moc3 与纹理、建三张索引表，还要持续跑物理与动作。
#
#  为什么独立成一个文件：上面那堆东西和"舞台状态怎么同步到节点树"
#  是两件不同的事。stage.gd 的注释里写明扩展方式是覆写 resolve()，
#  这里就是那个落点。
#
#  ── 目录约定（纯约定，不做任何配置）──
#    content/role/<角色 ID>/ 下递归找所有 *.model3.json。
#    模型文件名去掉 "<角色 ID>_" 前缀之后就是它的**变体名**：
#      content/role/mao_pro/runtime/mao_pro.model3.json        → 变体 ""
#      content/role/kei/kei_basic_free/runtime/xxx.model3.json → 变体 "basic_free"
#    剧本里不写变体时用变体名为空的那个；角色只有一个模型时就是它本身。
#
#  ── 属性语义：一张表查三类，全部精确匹配 ──
#    属性集由 VNSession 负责累加与移除（见 session.gd 的 _merge_attrs），
#    走到这里时已经是一份**完整的当前形态**，不含 "-" 前缀。本类只
#    把它翻译成模型状态：
#
#      变体  至多一个，取属性集里**最后**一个匹配的
#      表情  至多一个，取最后一个匹配的
#      动作  **全部**收下，按它们在属性集里的顺序依次播放
#
#    "取最后一个"实现的正是 Ren'Py 里"新的同类属性顶掉旧的"那个效果：
#    show mao_pro exp_01 之后再 show mao_pro exp_02，属性集里两个都在，
#    生效的是后者。而主动移除由剧本侧的 "-exp_01" 完成，那一步在
#    VNSession 里就做掉了，本类根本看不到减号。
#
#    为什么动作不像另外两类那样只取一个：Ren'Py 的 Live2D 文档里 show
#    可以一次给多个动作（show hiyori m10 m01），它们按顺序播 ——
#    "先做一个动作、再接上待机"就是这么写的。我们照做。
#
#    查不到时打警告并列出该模型所有可用的名字：屏幕上什么都不出现
#    是最难查的故障，这里必须留下线索。不做任何模糊匹配 ——
#    写 exp_1 就是找不到 exp_01，如实报错。
#
#  ── gd_cubism 不让一次入队多个动作（踩过的坑）──
#    internal_cubism_user_model.cpp 的 motion_start() 里：
#      if (priority == PRIORITY_FORCE) SetReservePriority(priority);
#      else if (!ReserveMotion(priority)) return InvalidMotionQueueEntryHandleValue;
#    而 Cubism 的 ReserveMotion 规则是 `if (_reservePriority >= priority) return false`。
#    于是同优先级的第二次 start_motion 直接失败，动作根本没进队列 ——
#    实测连续入队两个 PRIORITY_NORMAL，get_cubism_motion_queue_entries()
#    只有 1 个条目。所以"一个 show 多个动作"只能自己排队，靠
#    motion_finished 逐个驱动。
#
#    起播一律用 PRIORITY_FORCE：它是唯一能绕过 ReserveMotion 的优先级，
#    而且 Idle 可能正占着位置。强制替换**不会**误触发 motion_finished ——
#    Cubism 的 StopAllMotions() 只是 Clear() 队列，finished handler
#    只在动作自然播完时才调。
#
#  ── 定位用 canvas，不用网格包围盒（踩过的坑，别再改回去）──
#    gd_cubism 的类文档说 get_meshes() 返回 ArrayMesh，**那是错的**，
#    实际返回的是 MeshInstance2D 节点（源码 internal_cubism_renderer_2d.cpp
#    里 dict_mesh 存的就是节点）。照文档写类型判断，一个网格都匹配不上。
#    就算类型改对了也不能用：实测 mao_pro 有 260 个网格，其中 127 个是
#    不可见的特效件（心形、烟雾、爆炸、兔子、光环……），全算进去的包围盒
#    高 17730，而 canvas 只有 8400 —— 按它缩放人物会小一半。
#    只统计可见网格倒是准的，但 visible 标志要等第一次 update() 才刷出来，
#    _ready() 里拿到的还是默认的 true，等于没过滤。
#    canvas 尺寸在加载完成的瞬间就可用，不受这两件事影响。
#
#  ── canvas 的 origin 语义（同样踩过）──
#    实测 mao_pro：size=(5800, 8400)，origin=(2900, 4200)，正好是 size 的一半。
#    所以 origin 是"画布中心在画布坐标系里的位置"，**不是**"画布中心在模型
#    本地坐标系里的位置"。真正的对应关系是：
#      **模型本地原点 = 画布中心**，画布本地范围 = [-w/2, +w/2] × [-h/2, +h/2]
#    按后者理解会把人物推下半个画布、左移半个画布 —— 正好是
#    "下半身在屏幕外、人缩在左下角"那个 bug。定位时根本不需要 origin。
# ═══════════════════════════════════════════════════════════

## 模型清单的后缀。既是扫描时的筛选条件，也用来把文件名还原成变体名
const MODEL_SUFFIX := ".model3.json"
## 动作文件的后缀。解析 Motions 段时用它把文件名还原成动作名
const MOTION_SUFFIX := ".motion3.json"
## .model3.json 里标定口型参数的那一组。
## Cubism 的事实标准组名，也是 gd_cubism 自己的 EyeBlink 效果读组的方式
const LIPSYNC_GROUP := "LipSync"
## Idle 动作组名。这个组里的动作会被循环播放，其余的播完就回它
const IDLE_GROUP := "Idle"

## 角色 ID。等于 content/role/ 下的目录名
var character_id := ""

## 待应用的属性。setup() 一定早于 _ready()（节点入树前就要构造好），
## 所以属性先寄存在这里，等 _ready() 再真正落地
var _pending_attrs: PackedStringArray = PackedStringArray()

## 变体名 → .model3.json 的 res:// 路径
var _variants: Dictionary = {}
## 表情名 → true。只为查得快，取值本身没有意义
var _expressions: Dictionary = {}
## 动作名 → { "group": String, "no": int }
var _motions: Dictionary = {}

## 当前选中的变体名
var _variant := ""
## 当前表情名。空串表示没有
var _expression := ""

## 待播的动作队列（动作名）。gd_cubism 一次只接受一个动作入队，
## 所以这里自己排，播完一个由 _on_motion_finished() 起下一个
var _motion_queue: Array[String] = []
## 上一次属性集里的动作序列。用来在**剧本正常往下走**时区分"追加"和
## "重新编排"：
##   · 旧序列是新序列的前缀 → 追加，只补播新增的那几个
##   · 其余情况（删了动作、换了顺序、中间插了一个）→ 整串重播
##
## 它**不参与热重载**。热重载走的是"显示层节点全部重建"那条路
## （VNSession.stage_rebuilt → VNStage._on_stage_rebuilt），新节点的这个
## 字段是空的，于是当前句的整串动作自然从头播 —— 那正是热重载要的。
## 这里的前缀判断只服务于正常播放：show mao_pro mtn_02 之后再
## show mao_pro mtn_02 mtn_03，不该把"点头"点两次
var _last_motions: Array[String] = []

## 当前播的是不是 Idle 循环
var _playing_idle := false

## 是否已完成初始化。apply_attrs() 靠它决定能不能走原地更新
var _initialized := false
## 预加载建出来的节点跳过初始属性应用。见 prepare()
var _skip_attrs_on_init := false
## 是否已经就"有多个模型却没写明用哪个"警告过一次。
## 每次属性变化都会重新挑变体，不加这个标志会反复刷同一条警告
var _variant_warned := false

###########################################################
#  对外接口（由 VNStage 调用）
###########################################################

## 设置角色与初始属性。**在节点入树之前**调用。
##
## 真正的加载与布局推迟到 _ready()：那之前拿不到视口尺寸，
## 而定位缩放要靠它。目录扫描不依赖视口，所以就地做掉
func setup(id: String, attrs: PackedStringArray) -> void:
	character_id = id
	_pending_attrs = attrs
	_scan_variants()

## 预加载用：把模型读进来、建好索引表，但**不应用任何表情与动作**。
##
## 预加载发生在玩家还在读上一句的时候。此时如果把动作用上，角色会在
## 玩家还没看到它之前就先动一遍，动作进度也白白消耗掉。取出时由
## apply_attrs() 补上，效果与"刚加载完再应用"完全一致。
##
## 变体仍然在 setup() 里按 attrs 选好 —— 换变体要重新读 moc3，
## 那正是最贵的一步，必须在这一刻就选对
func prepare(id: String, attrs: PackedStringArray) -> void:
	setup(id, attrs)
	_skip_attrs_on_init = true

## 这组属性选出来的变体和本节点是否一致。
##
## 池靠它判断能不能直接复用 —— 变体变了就必须换节点，没有原地换模型的
## 余地。还没初始化完时一律返回 false：那时 _variants 之外的东西都还不可信
func matches_attrs(attrs: PackedStringArray) -> bool:
	if not _initialized:
		return false
	return _pick_variant(attrs) == _variant

## 当前模型变体名。预加载池拿它做键
func variant_name() -> String:
	return _variant

## 原地更新属性。返回 true 表示已处理，false 表示请销毁重建。
##
## 只有"换模型变体"必须重建 —— 换模型要重新加载 moc3 和纹理，
## 那是换一个对象，不是改一个属性。表情和动作都能在现有模型上改，
## 而"换个表情"在剧本里是极常见的操作，每次都重建会明显卡顿
func apply_attrs(attrs: PackedStringArray) -> bool:
	if not _initialized:
		# 还没 _ready()。存下来让它自己初始化时处理
		_pending_attrs = attrs
		return true

	if _pick_variant(attrs) != _variant:
		return false

	_pending_attrs = attrs
	_apply_attrs(attrs)
	return true

## 舞台必须先把这个模型烘焙进一张纹理，再整体调透明度。
##
## 0.9 的渲染器把每个 drawable 建成一个独立的 MeshInstance2D 子节点
## （internal_cubism_renderer_2d.cpp 的 build_model），每个都带
## blend_premul_alpha 的材质、各画各的。直接调本节点的 modulate.a 会级联
## 进全部 260 个部件，每个部件都对着屏幕混合一次，重叠区 alpha 累加成
## 1-(1-a)^n —— 半透明时能看见部件轮廓，像"每个部件单独做淡入淡出"。
## 这是逐层绘制的数学结果，不是扩展的 bug：整体半透明必须先合成再乘 alpha。
## 舞台用 Sprite2D + SubViewport 做这件事，见 stage.gd 文件头
func needs_alpha_group() -> bool:
	return true

## 烘焙纹理需要的本地包围盒。模型本地原点就是画布中心（见文件头），
## 所以覆盖范围是 [-w/2, +w/2] × [-h/2, +h/2] 再乘当前缩放。
##
## 舞台据此分配纹理，而不是给每个模型铺一张全屏 RT —— 按视口高度缩放后
## mao_pro 只占屏幕面积的三分之一，两个角色同屏时差距翻倍。
## 画布还没加载出来（get_canvas_info 为空）时返回空矩形，让舞台退回全屏
func alpha_group_rect() -> Rect2:
	var info := get_canvas_info()
	if info.is_empty():
		return Rect2()

	var canvas: Vector2 = info.get("size_in_pixels", Vector2.ZERO)
	if canvas.x <= 0.0 or canvas.y <= 0.0:
		return Rect2()

	var size := canvas * scale
	return Rect2(-size * 0.5, size)

## 烘焙纹理的目标分辨率，来自角色定义的 canvas 参数。
##
## 这个值决定模型渲染得多清晰，**不**改变它在舞台上的大小 —— 那个就是
## 设计画布的原始尺寸，要缩放请写 transform。零表示不声明：舞台按逻辑
## 尺寸 1:1 分配（等于画布尺寸），不做超采样
func alpha_group_rt_size() -> Vector2:
	return VN.character_vector_property(character_id, "canvas")

###########################################################
#  生命周期
###########################################################

func _ready() -> void:
	# 这里**不能**写 super._ready()。
	#
	# GDCubismUserModel 确实有一个 _ready()，但它是 C++ 侧的
	# `void _ready() override`（覆写 Node 的虚函数），并没有注册成
	# GDScript 能解析的父类虚函数 —— 写了会直接编译报错
	# "Cannot call the parent class' virtual function _ready()"。
	#
	# 它内部做的事是"assets 非空就再 load_model() 一次"，而加载本来
	# 就由 assets 的 setter 完成（赋值即加载），场景里预设 assets 也走
	# 同一个 setter，所以不需要它。
	#
	# 另外，C++ 虚函数和 GDScript 覆写是两条独立路径，两者都会执行，
	# 不存在"被盖掉"的问题：引擎先跑 C++ 那个（此刻 assets 还是空的，
	# 它什么都不做），再跑这里（设 assets，触发加载），顺序恰好是对的

	# 动作播完要推进队列或回 Idle
	motion_finished.connect(_on_motion_finished)
	_initialize(_pending_attrs)

###########################################################
#  初始化
###########################################################

## 首次初始化：选模型 → 加载 → 建表 → 挂效果 → 布局 → 应用属性
func _initialize(attrs: PackedStringArray) -> void:
	if _variants.is_empty():
		push_warning("角色 \"%s\" 在 %s 下找不到任何 %s"
			% [character_id, _role_dir(), MODEL_SUFFIX])
		return

	_variant = _pick_variant(attrs)
	# 赋值即同步加载，设完之后 get_canvas_info() / get_expressions() 立刻可用
	assets = _variants[_variant]
	_initialized = true

	_build_expression_table()
	_build_motion_table()
	_install_effects()
	_verify_canvas()
	# 预加载建出来的节点先不进属性：动作要等真正 show 出来时才播
	if not _skip_attrs_on_init:
		_apply_attrs(attrs)

###########################################################
#  目录扫描与索引
###########################################################

## 角色资源目录
func _role_dir() -> String:
	return VNStage.ROLE_DIR.path_join(character_id)

## 扫角色目录下所有 .model3.json，建"变体名 → 路径"表。
##
## 纯目录约定：加一套模型就是往目录里放一个文件，不用改任何 GDScript，
## 也不用在 define_role() 里登记路径
func _scan_variants() -> void:
	_variants.clear()

	var files := PackedStringArray()
	_collect_models(_role_dir(), files)

	for path in files:
		var base := path.get_file().trim_suffix(MODEL_SUFFIX)
		var variant := _variant_name(base)
		if _variants.has(variant):
			# 重名报错而不是覆盖：两个文件解析成同一个变体名时，
			# 谁赢都说不清，而剧本那边没有任何办法区分它们
			push_error("角色 \"%s\" 的变体 \"%s\" 重复：%s 和 %s"
				% [character_id, variant, _variants[variant], path])
			continue
		_variants[variant] = path

## 递归收集目录下所有模型清单。目录不存在时静默返回 ——
## "这个角色还没放模型"是内容层的正常状态，不该报错
func _collect_models(dir_path: String, out: PackedStringArray) -> void:
	if not DirAccess.dir_exists_absolute(dir_path):
		return

	for fn in DirAccess.get_files_at(dir_path):
		if fn.ends_with(MODEL_SUFFIX):
			out.append(dir_path.path_join(fn))

	for sub in DirAccess.get_directories_at(dir_path):
		_collect_models(dir_path.path_join(sub), out)

## 模型文件名 → 变体名。
## 文件名和角色 ID 完全相同时变体名是空串，表示"这个角色的默认模型"
func _variant_name(base: String) -> String:
	if base == character_id:
		return ""
	var prefix := character_id + "_"
	if base.begins_with(prefix):
		return base.substr(prefix.length())
	return base

## 从属性集里挑出模型变体名。挑不到就退回默认变体。
##
## 取**最后**一个匹配的：属性集是累加出来的，旧的同类属性可能还留在
## 里面，最新写下的那个才是作者现在的意思
func _pick_variant(attrs: PackedStringArray) -> String:
	var picked := ""
	for a in attrs:
		if _variants.has(a):
			picked = a

	if picked.is_empty():
		return _default_variant()
	return picked

## 默认变体：优先用变体名为空的那个。
## 多个候选又都没写变体名时说清楚发生了什么 —— 否则玩家只会看到
## "怎么不是我想要的那个模型"，而剧本里一个字都没写错
func _default_variant() -> String:
	if _variants.has("") or _variants.size() <= 1:
		return "" if _variants.has("") else String(_variants.keys()[0])

	var names := PackedStringArray(_variants.keys())
	if not _variant_warned:
		_variant_warned = true
		push_warning("角色 \"%s\" 有多个模型变体（%s），剧本里没说用哪个，本次用了 \"%s\""
			% [character_id, ", ".join(names), names[0]])
	return names[0]

## 建表情表。get_expressions() 直接给名字，不需要解析文件
func _build_expression_table() -> void:
	_expressions.clear()
	for exp_name in get_expressions():
		_expressions[String(exp_name)] = true

## 建动作表：动作名 → { group, no }。
##
## 为什么要自己读 .model3.json：
##   get_motions() 只给"组名 → 该组有几个动作"，拿不到名字，
##   而 start_motion() 要的偏偏是 (组名, 组内下标)。
##   下标只能自己数，数的规则必须和 gd_cubism 内部一致 ——
##   两者都是"按 Motions 段里组的顺序、组内数组的顺序"遍历，
##   而 Godot 的 Dictionary 保持插入顺序，所以这里对得上。
##   （实测已验证：show mao_pro mtn_02 播出来的确实是 mtn_02）
func _build_motion_table() -> void:
	_motions.clear()

	var data: Variant = _read_json(assets)
	if not (data is Dictionary):
		return

	var refs: Variant = (data as Dictionary).get("FileReferences", {})
	if not (refs is Dictionary):
		return

	var groups: Variant = (refs as Dictionary).get("Motions", {})
	if not (groups is Dictionary):
		return

	for group in (groups as Dictionary):
		var list: Variant = (groups as Dictionary)[group]
		if not (list is Array):
			continue

		var entries: Array = list
		for i in entries.size():
			var entry: Variant = entries[i]
			if not (entry is Dictionary):
				continue

			var file := String((entry as Dictionary).get("File", ""))
			if file.is_empty():
				continue

			var motion_id := file.get_file().trim_suffix(MOTION_SUFFIX)
			if _motions.has(motion_id):
				push_warning("角色 \"%s\" 的动作名 \"%s\" 重复，后一个被忽略"
					% [character_id, motion_id])
				continue
			_motions[motion_id] = {"group": String(group), "no": i}

## 读 .model3.json 的 Groups 段，取出 LipSync 组标定的参数名。
##
## 为什么不能像官方 demo 那样硬编码参数名 —— 本项目四个模型四种情况：
##   mao_pro        是 ParamA
##   kei_basic_free 是 ParamMouthOpenY
##   kei_vowels_pro 的组是**空的**
##   Ren'Py 原项目的模型是 Param4
## 没有一个共通的名字，只能读组。
##
## 组为空就返回空数组，调用方据此不挂唇跟随 —— 空组是模型作者的明确
## 表态（kei_vowels_pro 是元音模型，口型该由 ParamA/I/U/E/O 组合决定，
## 不该被单一开口度接管），不是遗漏，所以静默跳过
##
## 这是本文件第三次读同一份 .model3.json（前两次是动作表与这次的 Groups，
## 表情表不读文件）。几 KB 的文件在初始化时读三次，量级是毫秒，
## 不值得为此加一层缓存
func _build_lipsync_ids() -> PackedStringArray:
	var data: Variant = _read_json(assets)
	if not (data is Dictionary):
		return PackedStringArray()

	var groups: Variant = (data as Dictionary).get("Groups", [])
	if not (groups is Array):
		return PackedStringArray()

	for entry in (groups as Array):
		if not (entry is Dictionary):
			continue

		var e: Dictionary = entry
		if String(e.get("Name", "")) != LIPSYNC_GROUP:
			continue
		# Target 不是 Parameter 的组（部件组）语义不同，跳过
		if String(e.get("Target", "Parameter")) != "Parameter":
			continue

		var ids: Variant = e.get("Ids", [])
		if not (ids is Array):
			return PackedStringArray()

		var out := PackedStringArray()
		for id in (ids as Array):
			var name_ := String(id)
			if not name_.is_empty():
				out.append(name_)
		return out

	return PackedStringArray()

## 读一个 JSON 文件成 Variant，失败返回 null。
##
## 用 FileAccess 而不是 load()：这些文件在导出后仍需按原始路径读到，
## 走资源系统会引入"它到底算不算资源"的不确定 —— 而 .motion3.json
## 恰好被 gd_cubism 注册的加载器认领成了 Animation，.model3.json 没有，
## 两者待遇不同，干脆都不走
func _read_json(path: String) -> Variant:
	if not FileAccess.file_exists(path):
		push_warning("文件不存在：%s" % path)
		return null

	var text := FileAccess.get_file_as_string(path)
	if text.is_empty():
		return null

	return JSON.parse_string(text)

###########################################################
#  效果
###########################################################

## 挂上 gd_cubism 自带的效果子节点，挂上即生效：
##   Breath   呼吸起伏。没有它立绘就是一张死图
##   EyeBlink 眨眼。靠模型 Groups 里的 EyeBlink 参数组驱动，
##            参数组缺失时它自己什么都不做，所以不必先检查
##   LipSync  口型跟随。同样靠 Groups 的 LipSync 组驱动，但组为空时
##            由我们自己决定不挂 —— 见 _build_lipsync_ids()
##
## 三者都必须是本节点的**直接子节点**：GDCubismEffect 的 _enter_tree()
## 会 cast 自己的 parent，挂到孙辈不会报错，只是永远不生效
func _install_effects() -> void:
	add_child(GDCubismEffectBreath.new())
	add_child(GDCubismEffectEyeBlink.new())

	var lip_ids := _build_lipsync_ids()
	if lip_ids.is_empty():
		return

	var lipsync := VNCubismLipSync.new()
	lipsync.parameter_ids = lip_ids
	lipsync.role_id = character_id
	# 传的是**执行器**而不是统筹类：VNCubismLipSync.player 要问的是
	# voice_owner()，那件事在 VNPlayer 上。统筹类不转这个字段
	lipsync.player = VN.player
	add_child(lipsync)

###########################################################
#  定位
###########################################################

## 只做一件事：确认模型真的加载出来了、画布信息可用。
##
## 这里**刻意不碰 scale / position**。模型按设计画布的原始尺寸显示，
## 位置和大小全部交给剧本 —— `show xxx` 的默认 xycenter 会把它居中，
## 要缩放就写 transform。后端偷偷 auto-fit 会让其他开发者以为模型自带的
## 设计画布尺寸不对，转头去改模型导出参数，而实际只是框架替他们做了一次
## 缩放；大小应当是**看得见**的，写在剧本里
func _verify_canvas() -> void:
	var info := get_canvas_info()
	if info.is_empty():
		# 加载失败时这里原本是静默 return，模型会以 Node2D 默认的
		# 位置与缩放到左上角往外铺 —— 表现成"人物巨大、只看得见一角"，
		# 而且全程没有任何提示。必须留话
		push_warning("角色 \"%s\" 的模型没有加载成功，跳过画布检查" % character_id)
		return

	var canvas: Vector2 = info.get("size_in_pixels", Vector2.ZERO)
	if canvas.x <= 0.0 or canvas.y <= 0.0:
		push_warning("角色 \"%s\" 的 canvas 尺寸无效（%s）" % [character_id, canvas])

###########################################################
#  属性应用
###########################################################

## 按属性集应用表情与动作。
##
## 收到的属性集是**完整形态**（VNSession 已经做完累加和 "-" 移除），
## 所以这里不需要记住上一次是什么，照着做即可：
##   表情  取最后一个 —— 属性集里可能留着同类的历史，最新那个才生效
##   动作  全部收下、保持顺序 —— 一个 show 给多个动作就是靠这个
func _apply_attrs(attrs: PackedStringArray) -> void:
	var expression := ""
	var motions: Array[String] = []

	for a in attrs:
		if _variants.has(a):
			# 变体在 _initialize() 里已经用过了，这里跳过。
			# 走到 apply_attrs() 时变体必然没变（变了就返回 false 了）
			continue
		if _expressions.has(a):
			expression = a
			continue
		if _motions.has(a):
			motions.append(a)
			continue
		push_warning("角色 \"%s\" 不认识属性 \"%s\"。可用的是 —— %s"
			% [character_id, a, _available_names()])

	if expression != _expression:
		_expression = expression
		if expression.is_empty():
			stop_expression()
		else:
			start_expression(expression)

	# 判断这次是"追加"还是"重新编排"。
	#
	# 只有旧序列是新序列的前缀才算追加 —— 那时补播新增的几个就够，
	# 重播已经放过的动作在演出上是错的（"点头"会被点两次）。
	#
	# 其余情况一律整串重播：删掉一个动作、换顺序、甚至只是中间插了一个，
	# 都意味着这串演出被重新编排过，剧本改了就该按新的来 ——
	# 这也正是热重载时要看到的东西
	var appended := true
	for i in _last_motions.size():
		if i >= motions.size() or motions[i] != _last_motions[i]:
			appended = false
			break

	var to_play: Array[String] = []
	if appended:
		for i in range(_last_motions.size(), motions.size()):
			to_play.append(motions[i])
	else:
		to_play = motions.duplicate()

	_last_motions = motions.duplicate()

	if not to_play.is_empty():
		# _play_motions() 会整个换掉队列，所以属性集里被删掉的动作
		# 不会还赖在队列里等着播
		_play_motions(to_play)
	elif not _motion_queue.is_empty():
		# 动作被删光了。正在播的那个让它播完，排队等着的不该再播
		_motion_queue.clear()

## 该模型所有可用名字的清单，只用于报错。
## 变体只有一个时不列出来 —— "变体：mao_pro" 对作者没有信息量
func _available_names() -> String:
	var parts := PackedStringArray()

	if _variants.size() > 1:
		parts.append("变体：" + ", ".join(PackedStringArray(_variants.keys())))
	if not _expressions.is_empty():
		parts.append("表情：" + ", ".join(PackedStringArray(_expressions.keys())))
	if not _motions.is_empty():
		parts.append("动作：" + ", ".join(PackedStringArray(_motions.keys())))

	return " / ".join(parts)

###########################################################
#  动作
###########################################################

## 开始播放一串动作。真正的逐个起播交给 _advance_motion_queue()，
## 每个播完再由 _on_motion_finished() 推进下一个
func _play_motions(motion_ids: Array[String]) -> void:
	_motion_queue = motion_ids.duplicate()
	_advance_motion_queue()

## 从队列里取下一个动作起播；队列空了就回 Idle。
##
## 起播一律用 PRIORITY_FORCE —— 见文件头：NORMAL 会被 Cubism 的
## ReserveMotion 挡掉，而且 Idle 可能正占着位置
func _advance_motion_queue() -> void:
	if _motion_queue.is_empty():
		_play_idle()
		return

	var motion_id: String = _motion_queue.pop_front()
	var entry: Dictionary = _motions[motion_id]
	var group := String(entry["group"])
	var no := int(entry["no"])

	if group == IDLE_GROUP:
		# Idle 组的动作自己就是循环的，起播之后这条链就到此为止
		_motion_queue.clear()
		_playing_idle = true
		start_motion_loop(group, no, GDCubismUserModel.PRIORITY_FORCE, true, true)
		return

	_playing_idle = false
	start_motion(group, no, GDCubismUserModel.PRIORITY_FORCE)

## 回到 Idle 循环。
##
## 没有 Idle 组的模型（kei 就是）什么都不做 —— 没有可循环的东西，
## 让它停在当前姿势比强行播点别的合理
func _play_idle() -> void:
	var idle := _first_motion_in_group(IDLE_GROUP)
	if idle.is_empty():
		_playing_idle = false
		return

	var entry: Dictionary = _motions[idle]
	_playing_idle = true
	start_motion_loop(String(entry["group"]), int(entry["no"]),
		GDCubismUserModel.PRIORITY_IDLE, true, true)

## 找某个动作组里的第一个动作名。没有这个组时返回空串。
## Dictionary 保持插入顺序，所以"第一个"就是 json 里排最前的那个
func _first_motion_in_group(group: String) -> String:
	for motion_name in _motions:
		if String(_motions[motion_name]["group"]) == group:
			return String(motion_name)
	return ""

## 一个动作播完了。
##
## motion_finished 是**每个动作播完都发**（gd_cubism 把它挂在每个 motion
## 的 finished handler 上，见 gd_cubism_user_model.cpp:443），不是队列空了
## 才发 —— 所以这里要接着推进队列，而不是直接回 Idle，否则多动作连播时
## 第二个动作永远等不到
##
## 另外，实测过回调时刻 get_cubism_motion_queue_entries() 里已经有
## _play_idle() 刚插进去的 Idle，拿它判断"队列空"是不可靠的，
## 自己维护的 _motion_queue 才准
func _on_motion_finished() -> void:
	# Idle 是循环播的，正常走不到这里；真走到了（比如循环被外力打断）
	# 也不能再回 Idle，否则会自我触发成死循环
	if _playing_idle:
		return
	_advance_motion_queue()

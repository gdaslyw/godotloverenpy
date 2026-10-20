class_name VNSession
extends Node

# ═══════════════════════════════════════════════════════════
#  一局的演出状态。角色属性、舞台内容、对话历史三样都在这里。
#
#  ── 为什么这三样归一处 ──
#  它们是同一类东西：**会随存档走、且每次进入一局都会重来一份的状态**。
#  对应 Ren'Py 那边，它们同属 renpy.execution.Context —— 舞台是 Context 的
#  scene_lists（execution.py:334），历史是 Context 的历史表，都不是引擎
#  全局的。所以这不是"把三个字典塞进一个类"，是它们本来就该在一起。
#
#  ── 与 VNPlayer 的分工 ──
#    VNSession（本文件）  状态：有什么角色、屏幕上摆着什么、说过什么
#    VNPlayer            执行：游标走到哪、指令怎么分派、控制流怎么重放
#  一句话：Player 决定"下一步做什么"，Session 记住"现在是什么样"。
#  剧本指令改状态时是 Player 单向调进来，Session 不知道剧本存在。
#
#  ── 怎么被创建 ──
#  由 VNFrame 在 _ready() 里 new 出来并 add_child，**不自己找依赖**：
#  本类一个 VNSettings / VNConfig / VNPlayer 都不引用，也不需要 setup()。
#  这是刻意的 —— 零依赖意味着它能被单独拿出来测，也意味着它的构造顺序
#  永远不会成为启动链上的一个坑。
#
#  ── 怎么被外部看到 ──
#  外部一律走 VNFrame 的转发接口（VN.stage() / VN.history() /
#  VN.character_property()），不直接引用本类实例。
# ═══════════════════════════════════════════════════════════

###########################################################
#  角色属性
###########################################################

## 剧本能改的角色属性白名单。**全项目只有这一份** —— vn/dev/parser.gd
## 直接引用它做编译期校验，两边不会走散。
##
## 名单之外的属性（canvas、portrait_kind …）是**定义**：define_role() 给一次
## 之后剧本改不了，存档也不存 —— 存档只记会变的那几个，定义由当前代码提供。
## 这样"改角色定义"和"读存档"就不会互相覆盖
const WRITABLE_ROLE_PROPS := ["name"]

## 角色属性的**初始定义**，由 register_roles() / define_role() 灌入。
## 只读用途：reset_roles() 从这里重新拷一份出来
var _role_defs: Dictionary = {}
## 角色属性的**当前值**。剧本里的 set role.<id>.<属性> 改的是这一份，
## 但只限 WRITABLE_ROLE_PROPS 里的属性 —— 定义型属性放在这里只是为了让
## 读取方有一个统一入口，它们永远不会被写
var _roles: Dictionary = {}

###########################################################
#  舞台
###########################################################

## 舞台状态：tag → { "attrs": String, "order": int }。
## 全部是可序列化的原始类型 —— 存档要原样写出去，所以这里不存节点、不存资源。
## attrs 用空格分隔的字符串而不是数组，和 .vnbc 的 args 形状保持一致
var _stage: Dictionary = {}
## 是否正在重放舞台指令。重放期间 _emit_stage() 静默，
## 由 end_replay() 统一发一次 —— 见那里的说明
var _replaying := false

###########################################################
#  历史与附言
###########################################################

## 对话历史。见 vn/ui/history.gd
var _history := VNHistory.new()

## 最近一句交给界面的台词文本（已过 tr()）。存档的附言取它 ——
## 存档记的是"玩家当时读到的那句话"，所以是译文而不是原文
var _last_say_text := ""

###########################################################
#  生命周期
###########################################################

## 占位。**本类刻意不做任何初始化**。
##
## 留着它是因为本类是 Node：将来若有人往这里写"启动时做点什么"，
## 那件事就会发生在 VNFrame._ready() 的注入过程之中，而那时
## VNFrame 还没装配完 —— 会变成一条极难查的时序依赖。
## 初始化一律由 VNFrame 显式调用，不借 _ready() 的顺风车
func _ready() -> void:
	pass

###########################################################
#  角色属性
###########################################################

## 注册角色定义。表是 { 角色 ID: { 属性名: 值 } }，由应用层在启动时给一次。
##
## 定义会被留一份底，set 改的是"当前值"那一份。两份必须分开存：
## 共用一份的话，set 改的就是底本身，start(NEW_GAME) 重置回不去，
## 而且症状是"玩过一次新游戏之后，初始名永久变成了上次的值"
func register_roles(table: Dictionary) -> void:
	_role_defs = table.duplicate(true)
	_roles = table.duplicate(true)

## 定义一个角色。由应用层的定义脚本在启动时调用，参数带默认值 ——
## 将来加属性时只是多一个具名参数，已有的定义一行都不用改。
##
## canvas 是这个模型的"画布大小"：烘焙纹理的目标分辨率（像素）。
## 它**不**影响模型在舞台上的显示大小，那个就是设计画布的原始尺寸，
## 要缩放请写 transform。零表示不声明 —— 舞台按逻辑尺寸 1:1 分配。
##
## 它和 portrait_kind 一样属于定义型属性：不在 WRITABLE_ROLE_PROPS 里，
## 所以剧本改不了，存档也不会存
func define_role(id: String, display_name: String,
		portrait_kind: String = "static",
		canvas: Vector2 = Vector2.ZERO) -> void:
	var defs := {"name": display_name, "portrait_kind": portrait_kind}
	if canvas.x > 0.0 and canvas.y > 0.0:
		defs["canvas"] = canvas

	_role_defs[id] = defs.duplicate(true)
	_roles[id] = defs.duplicate(true)

## 把所有角色属性恢复成注册时的初始值。
## start(..., NEW_GAME) 会自动调用，一般不需要手动调
func reset_roles() -> void:
	_roles = _role_defs.duplicate(true)

## 取某个角色某个属性的当前值。没注册过或没这个属性时返回空串。
## 需要"取不到就退回 ID"的场合（比如显示名）请用 VNPlayer._resolve_role_name
func character_property(character_id: String, prop: String) -> String:
	var props: Dictionary = _roles.get(character_id, {})
	return String(props.get(prop, ""))

## 取某个角色某个**向量**属性的值。没注册过、或这个属性不是向量时返回零。
##
## 向量属性目前只有 canvas，它是定义型的 —— 读当前值表也没关系，
## 因为 WRITABLE_ROLE_PROPS 挡住了所有写入路径（set / 存档 / 读档），
## 它从 define_role() 之后就不会再变
func character_vector_property(character_id: String, prop: String) -> Vector2:
	var props: Dictionary = _roles.get(character_id, {})
	var value = props.get(prop, null)
	if value is Vector2:
		return value
	return Vector2.ZERO

## 改一个角色属性。路径形状已由 parser 校验，这里是运行时的落点。
##
## 角色没注册过时**宽容处理并留下线索**而不是拒绝：角色定义在应用层的
## GDScript 里，框架编译期看不到这份表，拦不住拼错的 ID。
## 屏幕上出现 me 这种标识符本身就是最直观的线索，比什么都不显示强
##
## 非白名单属性一律拒绝。parser 已经在编译期挡过，这里只是运行时的兜底 ——
## 手写或改过的 .vnbc 可能绕过那一道
func set_character_property(character_id: String, prop: String, value: String) -> void:
	if not WRITABLE_ROLE_PROPS.has(prop):
		push_warning("角色属性 \"%s\" 不是剧本可改的（可用：%s）"
			% [prop, ", ".join(PackedStringArray(WRITABLE_ROLE_PROPS))])
		return

	var props: Dictionary = _roles.get(character_id, {})
	if props.is_empty():
		push_warning("set 的角色 \"%s\" 没有注册过，已自动创建" % character_id)
		props = {}
		_roles[character_id] = props

	props[prop] = value

## 导出**会变**的角色属性（深拷）。存档写它，读档还原它。
##
## 只导出白名单里的属性：canvas、portrait_kind 这类定义型属性由当前代码
## 提供，存进存档反而会在读档时用旧值（甚至旧格式）盖掉新定义
func roles_data() -> Dictionary:
	var out := {}
	for id in _roles:
		var props: Dictionary = _roles[id]
		var writable := {}
		for key in WRITABLE_ROLE_PROPS:
			if props.has(key):
				writable[key] = props[key]
		out[id] = writable
	return out

## 从存档恢复角色属性。
##
## 先 reset 再覆盖，两步都不能省：
##   reset   保证**当前代码里**定义过的角色全都在场。存档可能是几天前存的，
##           那时 characters.gd 还没有后来新增的角色
##   覆盖    把存档里的值贴回去，且**只贴白名单里的属性** —— 别的属性是
##           定义，当前代码说了算。旧存档里就算带着它们也会被忽略
##
## 存档里多出来的角色（已从 characters.gd 删掉的）也一并恢复：剧本引用
## 不到它们，留着无害，而"按存档原样还原"是更可预期的行为
func restore_roles(saved: Variant) -> void:
	reset_roles()
	if not (saved is Dictionary):
		return

	for id in (saved as Dictionary):
		var props: Variant = (saved as Dictionary)[id]
		if not (props is Dictionary):
			continue

		var target: Dictionary = _roles.get(String(id), {})
		for key in WRITABLE_ROLE_PROPS:
			if (props as Dictionary).has(key):
				target[key] = (props as Dictionary)[key]
		_roles[String(id)] = target

###########################################################
#  舞台：状态读取
###########################################################

## 当前舞台状态的深拷。发的是拷贝而不是引用：显示层和存档都不该有能力
## 改到框架的内部状态
func stage() -> Dictionary:
	return _stage.duplicate(true)

## 舞台是否为空
func stage_is_empty() -> bool:
	return _stage.is_empty()

## 姿态请求。显示层收到后把当前各 tag 的变换写进 buffer。
##
## 姿态只有显示层知道 —— 它握着节点。session 手里只有 attrs / at
## 这类指令层面的描述，算不出"内容现在在哪"
##
## 用缓冲区而不是让显示层写回 _stage：历史条目要的是"这一句开始时
## 的画面"，存档要的是"存档那一刻的画面"，两者都只是取出来用一下。
## 剧本要求把某个 tag 的 ATL 结算到最终态（`show <tag> at end`）。
##
## 发信号而不是改数据：动画进度住在节点上，_stage 里只有"谁在台上、
## 什么形态、哪一层"。而且 at end 不该在 _stage 里留下痕迹 —— 留下的话
## 下次重建舞台会把 "end" 当成 transform 名去查表
signal atl_end_requested(tag: String)

## 写回舞台数据的话会和读档重建用的那份 pose 混在同一格，界面重建时
## 可能误用上一个存档留下的旧位置
signal pose_requested(buffer: Dictionary)

## 收集当前各 tag 的显示姿态，每项 { position, scale, rotation, alpha }。
##
## 先发一次**同步**信号让显示层填 buffer，再返回 —— 同步意味着信号
## 回来时拿到的就是这一帧的值
func stage_poses() -> Dictionary:
	var buffer := {}
	pose_requested.emit(buffer)
	return buffer

## 把一整份姿态合并进舞台数据。
##
## 读档时用：rebuild_stage() 重放出来的 _stage 没有姿态（指令里没有），
## 在通知显示层之前把存档里那份贴进去，建节点时才能恢复原位
func apply_poses(poses: Dictionary) -> void:
	for tag in poses:
		if not _stage.has(tag):
			continue
		var pose = poses[tag]
		if pose is Dictionary:
			_stage[tag]["pose"] = pose

## 执行 `show <tag> at end`：让这个 tag 正在播的动画立刻结算到最终态。
##
## 刻意不走 show_tag()：at end 不是一次显示，改 _stage 会让重建舞台时
## 把 "end" 当成 transform 名去找。这里只把请求转给显示层
func finish_tag(tag: String) -> void:
	if tag.is_empty():
		return
	atl_end_requested.emit(tag)

###########################################################
#  舞台：状态写入
#
#  下面这些由 VNPlayer 在执行 show / hide / scene 指令时调用 ——
#  包括**重放**那一路（rebuild_stage）。重放的循环控制在 Player，
#  落到数据上的效果在这里，两边各管一段。
###########################################################

## 执行 show / show_front。
## 同一个 tag 重复 show 是**更新**而不是新增 —— 这正是 Ren'Py 的 image tag 语义。
##
## 属性是**累加**的：这次写下的词并进已有属性集，没有提到的类别原样保留。
## 这正是 Ren'Py Live2D 的行为 —— 它的文档里写着 "Nonexclusive expressions
## persist until removed with attribute negation"，例子是 show hiyori -wave。
## 所以 show mao_pro exp_01 之后再 show mao_pro mtn_02，表情会留着。
##
## 为什么累加放在框架层而不是各后端自己做：_stage 存的是"这个 tag 当前的
## 完整形态"，存档、界面重建、调试读的都是它。让显示层自己记累加状态的话，
## 节点一重建（scene 之后重新 show、界面换掉再挂回来）状态就丢了
##
## at / atl 是**覆盖**而不是累加：它们描述的是"这一条 show 用哪套动画"，
## 每次 show 都给出完整答案。没写 at 就是空串，由显示层按默认的 xycenter 处理
func show_tag(tag: String, attrs: String, front: bool,
		at_name: String = "", atl: String = "") -> void:
	if tag.is_empty():
		return

	if not _stage.has(tag):
		# 首次登场：拿一个新的 order，落在最上面。
		# 也过一遍合并，这样万一写了 "-xxx" 会被丢掉而不是当成属性名存下来
		_stage[tag] = {
			"attrs": _merge_attrs("", attrs),
			"order": _next_order(),
			"at": at_name,
			"atl": atl,
		}
	else:
		var entry: Dictionary = _stage[tag]
		entry["attrs"] = _merge_attrs(String(entry.get("attrs", "")), attrs)
		entry["at"] = at_name
		entry["atl"] = atl
		# 新的 show 意味着新的定位意图，读档时贴进来的旧姿态到此作废 ——
		# 留着它会让下一次节点重建误用上一个存档的位置
		entry.erase("pose")
		# 只有显式要求 front 才动 order。普通 show 不该让立绘跳层 ——
		# 那会让"换个表情"这种操作意外地改变遮挡关系
		if front:
			entry["order"] = _next_order()

	_emit_stage()

## 执行 hide
func hide_tag(tag: String) -> void:
	if tag.is_empty():
		return
	_stage.erase(tag)
	_emit_stage()

## 执行 scene：清空内容层，然后放新图像。
##
## 语义和 Ren'Py 一致 —— 它不是"换背景"，是整个内容层重来。
## 所以 scene 之后必须重新 show 立绘，这正是 VN 剧本里 scene 后面
## 总跟着一串 show 的原因
func scene_with(tag: String, attrs: String = "",
		at_name: String = "", atl: String = "") -> void:
	if tag.is_empty():
		return

	_stage.clear()
	_stage[tag] = {"attrs": attrs, "order": 1, "at": at_name, "atl": atl}
	_emit_stage()

## 清空舞台并推给显示层。回主菜单（end_session）与开新游戏时用
func clear_stage() -> void:
	_stage.clear()
	_emit_stage()

###########################################################
#  舞台：重放开关
###########################################################

## 进入重放模式。期间的 _emit_stage() 全部静默。
##
## 由 VNPlayer.rebuild_stage() 在扫指令流之前调用。一次重放会走过几十上百条
## show，每条都发一次信号的话，显示层要反复增删同样的节点，
## 而只有最后那次的状态是有效的
func begin_replay() -> void:
	_replaying = true

## 退出重放模式并推一次最终状态。
##
## 先让显示层把节点全丢掉（stage_rebuilt），再推新状态。顺序反了的话，
## 显示层会先按新状态"就地更新"一轮 —— 而那一轮照样带着上一句的执行进度
func end_replay() -> void:
	_replaying = false
	stage_rebuilt.emit()
	_emit_stage()

## 把舞台状态推给显示层。重放期间静默，理由见 begin_replay()
func _emit_stage() -> void:
	if _replaying:
		return
	stage_changed.emit(_stage.duplicate(true))

## 取一个新 order：当前最大值 + 1。
## 用"现存最大值"而不是全局计数器：hide 掉的条目会从 _stage 移除，
## 全部隐藏后自然归零，不会无限涨（z_index 有 ±4096 的范围）
func _next_order() -> int:
	var max_order := 0
	for tag in _stage:
		var o := int(_stage[tag].get("order", 0))
		if o > max_order:
			max_order = o
	return max_order + 1

## 把一组新属性并进旧属性集。
##
## 规则只有两条，都不涉及任何语义 —— 框架依旧不知道什么是"表情"、
## 什么是"动作"，那是各后端的属性表决定的：
##   · 新词追加到末尾；重写已存在的词时**先删再追加**，于是它移到末尾
##   · "-词" 表示移除，把那个词从集合里删掉
##
## ── 为什么重写要移到末尾 ──
## 属性串的顺序就是"写入顺序"。后端靠"取最后一个同类属性"决定生效的是哪个
## （见 portrait_cubism.gd 的 _apply_attrs），所以顺序就是语义。
## 如果重写时原地不动，同一组属性来回切换就会失效：
##     show rain light      → "light"
##     show rain heavy      → "light heavy"
##     show rain light      → "light heavy"    ← 串没变，light 切不回来
## 第三句的属性串和第二句一模一样，显示层无从知道"这次写的是 light"。
##
## 末尾写的是同一个词时（重复 show 同一形态），删掉再追加回去，串不变，
## 调用方也就不会触发重建 —— 幂等性保住了。
##
## 同类替换（两个表情名同时存在时哪个生效）由后端自己"取最后一个"解决，
## 框架不参与 —— 见 portrait_cubism.gd 的 _apply_attrs()
##
## 代价是属性集里会留下同类属性的历史（exp_01 exp_02），但它**有界**：
## 去重之后最多等于该模型的表情数 + 动作数 + 变体数，不会无限增长
func _merge_attrs(current: String, incoming: String) -> String:
	if incoming.is_empty():
		return current

	var parts := Array(current.split(" ", false))
	for word in incoming.split(" ", false):
		var a := String(word)
		if a.begins_with("-"):
			# 负属性：移除。只吃一个减号，"--x" 这种留给属性表去报"不认识"
			parts.erase(a.substr(1))
			continue
		# 先删再追加。已经存在的词因此移到末尾，顺序才等于写入顺序 ——
		# 详见函数头。erase 一个不存在的元素是无操作，新词照样落到末尾
		parts.erase(a)
		parts.append(a)

	return " ".join(PackedStringArray(parts))

###########################################################
#  历史
###########################################################

## 对话历史。
##
## 发的是实例本身而不是深拷 —— 和历史条目不同，这里要的就是那个能
## 调 add() / truncate() 的对象。界面只读是注释层的约定，不是类型层的
func history() -> VNHistory:
	return _history

## 追加一条历史。由 VNPlayer._show_current() 调用。
##
## pose 是这一句开始时舞台的姿态。历史跳转要回到"那句的画面"，而画面
## 只存在于当时那一帧 —— 从 ep1 跳回 ep0 时，当前画面里根本没有旧信息可抓
func add_history(sid: int, who: String, text: String, voice: String,
		position: Dictionary, pose: Dictionary = {}) -> bool:
	return _history.add(sid, who, text, voice, position, pose)

## 把历史截断到前 count 条。回跳后由 VNPlayer.jump_to_history() 调用
func truncate_history(count: int) -> void:
	_history.truncate(count)

## 清空历史。开新游戏时用
func clear_history() -> void:
	_history.clear()

## 导出历史
func history_data() -> Array:
	return _history.to_data()

## 从存档恢复历史
func restore_history(data: Variant) -> void:
	_history.from_data(data)

###########################################################
#  附言
###########################################################

## 记下最近一句交给界面的台词文本
func set_last_say_text(text: String) -> void:
	_last_say_text = text

## 最近一句台词的文本（已过 tr()）。存档的附言取它。
## 一局还没显示过任何台词时是空串
func last_say_text() -> String:
	return _last_say_text

###########################################################
#  信号
###########################################################

## 舞台内容变化。带的是深拷后的完整舞台状态 { tag: { attrs, order } }
signal stage_changed(stage: Dictionary)
## 舞台被整体重建（热重载、存档恢复）。显示层收到后应当**丢弃所有节点**
## 并重新构造 —— 这不是优化掉的一步，是语义要求：
## 重建的意图是"重新执行当前句"，那么当前句的效果就得从头开始
signal stage_rebuilt()

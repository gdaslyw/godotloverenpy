class_name VNStage
extends CanvasLayer

# ═══════════════════════════════════════════════════════════
#  舞台显示层。把 VNSession 那份纯数据投影成实际节点。
#
#  分工
#    VN      只存"场上有谁、什么形态、第几层"—— 全是数据
#    本类    把 (tag, attrs) 解析成节点，并维护它们的生命周期
#
#  为什么解析放在这里而不是 VN 里：
#    "lili 的 1 号立绘在哪个文件"是内容，"L2D 模型怎么驱动"是技术选型，
#    框架两个都不该知道。VN 只传 tag 和 attrs 下来。
#
#  扩展方式：继承本类覆写 resolve()。
#    静态图和视频是框架自带的实现（纯资源约定，无外部依赖）；
#    层叠式和 L2D 各自是一份覆写，接上去不动 _stage、不动指令语义、
#    更不动剧本一个字。
#
#  ── 每个内容独占一个 CanvasLayer，而不是直接挂在本层下 ──
#    排序用 CanvasLayer.layer，不用 CanvasItem.z_index。原因是 L2D 会给
#    **每一个部件网格**都设 z_index = 它自己的绘制顺序（实测 mao_pro 的
#    260 个部件占 0..259），而 Godot 的 z 是父子累加的（文档原话：
#    子节点的 final Z = 自己的 z_index + 父节点的 final Z）。两个立绘
#    直接同层时，它们的部件区间大面积重叠 —— 表现出来就是
#    "两个模型一重叠，部件就交叉堆叠"。
#
#    CanvasLayer 之间不比较内部 z（文档原话：layer 顺序 "will hold
#    regardless of the CanvasItem.z_index of the nodes within each layer"），
#    这才是真正的隔离。代价实测为 0：3 个内容各包一层之后
#    draw call 一个没多（L2D 的网格本来就无法合批，静态图各用各的
#    大纹理，本来也不在同一批次里），只多了每内容 1 个节点。
#
#    为什么不能"只给 L2D 套层"：静态图的 z_index 只在本层内部有效，
#    而 CanvasLayer(1) 永远在 CanvasLayer(0) 之上 —— 结果是所有静态图
#    都会被所有 L2D 盖住，无论 order 是多少。两套排序机制无法互相
#    穿插，所以要么全用、要么全不用。
#
#  ── 前提：本节点的 layer 必须是 0 ──
#    内容层的 layer 直接取 order。子 CanvasLayer 的 layer 是绝对还是
#    相对父层，两种语义下 0 + order 都等于 order，所以不必关心；
#    但本层的 layer 一旦不是 0，相对语义下所有内容层会整体偏移。
#
#  ── 整体透明度：多部件内容要先烘焙成一张纹理 ──
#    淡入淡出打的属性只有一个，但"整体"的含义取决于内容的结构：
#    一张贴图、一个视频，改自己的 modulate.a 就是整体透明；而 L2D 是几百个
#    网格各自绘制的，改父节点的 modulate.a 会让每个部件都对着屏幕混合一次，
#    重叠区累加成 1-(1-a)^n —— 半透明时部件轮廓会浮出来。
#    所以整体透明必须先合成一次。Ren'Py 的 Flatten + mesh 是同一件事：
#    它把 child 烘进一张 Render，之后的 alpha 才作用在那张纹理上。
#
#    为什么不用 CanvasGroup：它的文档就是为这个场景写的（用 self_modulate），
#    但实测在 gl_compatibility 下它并没有真正离屏合成 —— 子项照常画到
#    backbuffer，self_modulate 和自定义 shader 都只能影响那层叠加，整体
#    alpha 完全无效（实测图像差异 1.2，而级联的 modulate 是 4.6/8.7）。
#    SubViewport 是唯一确定能烘焙的路子。
#
#    内容声明 needs_alpha_group() 后，本类给它套 Sprite2D + SubViewport。
#    纹理不是全屏：按内容报的包围盒分配，Sprite 1:1 贴上去。L2D 按视口高度
#    缩放后通常只占屏幕三分之一，给每个模型铺一张 2560×1440 纯属浪费
#    （见 _fit_alpha_texture）。
#    _entries 里因此有两个节点：node 是"屏幕上可淡入淡出的整体"（Sprite2D），
#    inner 是"真正的内容"。属性更新、meta 都归 inner
#
#  ── 层级分区 ──
#    0        本层（舞台容器，自己什么都不画）
#    1..99    内容层，一个内容一层（上限见 MAX_LAYER）
#    100      MainLayer（主菜单 / 剧情界面）
#    200      MenuLayer（游戏菜单）
#    300      OverlayLayer（确认弹窗）
# ═══════════════════════════════════════════════════════════

## 角色资源目录。每个角色一个同名子目录
const ROLE_DIR := "res://content/role/"

## 内置显示物的 tag。这些名字**不走图像表** —— 它们没有源文件可扫，
## 由本类直接造节点。剧本照写 show rain / show rain heavy 2.0，
## 和普通图像是同一条通路
const RAIN_TAG := "rain"

## 定义在 VNFrame.MAX_CONTENT_LAYER 里 —— 那个值跟着 LAYER_MAIN 走，
## 而层号表归统筹类：它是"界面怎么分层"，与剧情执行无关
const MAX_LAYER := VN.MAX_CONTENT_LAYER

## 烘焙纹理在内容包围盒外留的余量比例（各轴各算）。
## 呼吸和物理会让模型在画布边缘外轻微滑动，贴边的立绘不留余量会被切掉一条；
## 留太多又白白扩大每帧合成的面积
const ALPHA_TEXTURE_PADDING := 0.02

## 烘焙纹理分配多大，由内容报的可选方法 alpha_group_rt_size() 决定 ——
## L2D 的来自角色定义的 canvas 参数。不报就按逻辑尺寸 1:1，不做超采样。
##
## 为什么不用 2D MSAA：gl_compatibility 走的是 GLES3，引擎里直接写着
## "2D MSAA is not yet supported for GLES3"（texture_storage.cpp:3210）。
## 而 L2D 放大后露锯齿的正是几何边 —— Cubism 的每个 drawable 是三角网格，
## 轮廓由网格顶点裁出来，不受纹理过滤影响；静态图只有带抗锯齿的 alpha，
## 所以同样放大却干净。提高烘焙分辨率是这条渲染路径上唯一的办法

## ATL 运行时。用 preload 而不是直接写 VNATL：后者依赖全局类注册，
## 新脚本第一次被引用时编辑器/headless 都可能还没扫到它
const ATL_SCRIPT := preload("res://vn/ui/atl.gd")

## 舞台内容：tag → { "layer", "node", "inner", "at", "atl", "atl_player" }。
## 存包装层而不是直接存内容节点，因为销毁、换层都是对包装层操作。
## node 是屏幕上可整体调透明度的节点，inner 是真正的内容 —— 没有包装时两者相同
##
## at / atl 是这一条 show 带来的动画来源：at 存 transform 名，atl 存内联块。
## 两者都为空时由 VNATL 用默认的 xycenter 顶上
var _entries: Dictionary = {}

## 重建前各 tag 包装层的实际变换，只活一次重建。
##
## _on_stage_rebuilt() 里填，_apply_stage() 建节点时取用，取完即删。
## 它的存在是为了让热重载 / 历史跳转后的画面停在"原来那个位置"，
## 而不是被默认的 xycenter 拽回舞台中心
var _saved_transforms: Dictionary = {}
## 是否已经就"图像表为空"警告过一次。
## 每次解析图像都会查表，不加这个标志会在整场剧情里反复刷同一条
var _images_warned := false
## 是否已经就"内容层级用尽"警告过一次。
## _set_layer() 在每次 stage_changed 都会被调到，不加这个标志会刷屏
var _layer_warned := false

## 本次变化里被移除或重建的包装层，等着 with_run 消费。
## 没有 with 来消费时在下一帧销毁 —— 包装层先藏起来，
## 那一帧里不会和新节点叠在一起，玩家看不到
var _leaving: Array[Dictionary] = []
## 本次变化之前的节点集合。用来区分"这一轮新出现的节点"，转场时它们要淡入
var _pending_before: Array[Node] = []
## 是否有待转场的变化
var _pending_active := false
## 建立待转场的那一帧。下一帧还没被消费就丢弃
var _pending_frame := -1

###########################################################
#  预加载池
#
#  cubism 模型加载一次要几百毫秒，而 show 的那一刻正好是玩家在看屏幕的时候。
#  播放器会报来"接下来 32 条指令里会 show 什么"，本类提前把模型读进来，
#  show 时直接取用。
#
#  只池化 cubism：静态图与视频是毫秒级，占着内存不放没有意义。
#
#  池里的节点是**一次性**的 —— 取出去就不再放回。回收复用要处理表情、
#  动作进度、物理摆动和层号，重置这些比重新加载更容易出状况；而池里通常
#  只留一两个待用模型，回收的收益不值得这份复杂度
###########################################################

## 预加载池最多留几个模型。每个 L2D 几十 MB，同屏极少超过三个
const POOL_LIMIT := 3

## tag → { "node": VNPortraitCubism, "variant": String }
var _pool: Dictionary = {}
## 池的放入顺序。超限时淘汰最前面那个（最久没人要的）
var _pool_order: Array[String] = []
## 待预取的请求。每帧只消化一个 —— 加载是同步的，连着做几个会把一帧撑爆
var _prefetch_queue: Array[Dictionary] = []
## 池节点的挂载点。不可见、也不跑 _process：隐藏的模型不该继续呼吸和眨眼
var _pool_root: CanvasLayer = null

###########################################################

func _ready() -> void:
	# 池容器。layer 取 -1，藏在所有内容层之下；不可见 + 不处理，
	# 这样预加载好的模型只是"躺在内存里"，不占每帧的绘制与物理更新
	_pool_root = CanvasLayer.new()
	_pool_root.name = "PortraitPool"
	_pool_root.layer = -1
	_pool_root.visible = false
	_pool_root.process_mode = Node.PROCESS_MODE_DISABLED
	add_child(_pool_root)

	VN.stage_changed.connect(_on_stage_changed)
	VN.stage_rebuilt.connect(_on_stage_rebuilt)
	VN.stage_transition_requested.connect(_on_stage_transition)
	VN.stage_prefetch_requested.connect(_on_prefetch_requested)
	# 存档时要一份当前姿态。信号是同步的：session 发完立刻就能读到值。
	# 判空是为了不依赖 VNFrame 的 _ready 顺序 —— 它是 autoload，理论上总在
	# 本节点之前跑完，但这条连接少一层假设就少一个"有时候没保存姿态"的坑
	if VN.session != null:
		VN.session.pose_requested.connect(_on_pose_requested)
		VN.session.atl_end_requested.connect(_on_atl_end_requested)
	# 可能在界面重建之前舞台就已经有内容了，先对齐一次。
	# 这样本层可以随时销毁重建，和 say 界面一样
	_apply_stage(VN.stage())

###########################################################
#  状态同步
###########################################################

func _on_stage_changed(stage: Dictionary) -> void:
	_apply_stage(stage)

## 舞台被整体重建：把所有节点丢掉，让随后的 _apply_stage() 从零构造。
##
## 这不是为了省事，是语义要求。热重载的意图是**重新执行当前句**，
## 当前句的效果就必须从头开始 —— L2D 的动作队列要从第一个动作重播，
## 将来的 ATL 动画更是必须从第 0 帧起。任何"保留节点、只更新属性"的
## 做法都会留下上一轮的进度，表现成"改了动画，屏幕上却不动"。
##
## 先 remove_child 再 queue_free：前者让节点立刻离开场景树（停止绘制和
## _process），后者负责回收。只 queue_free 的话旧节点要等帧末才走，
## 会和新节点重叠一帧
##
## 代价是 L2D 要重新加载模型（几百毫秒）。开发期独有的操作，
## 用它换掉一整类"状态残留"的 bug 是划算的
func _on_stage_rebuilt() -> void:
	# 待转场的旧节点不在 _entries 里，得单独清一遍，
	# 否则重建之后它们会永远留在舞台上
	_drop_pending()

	# 先把画面上的变换记下来再销毁。重建只该"重算状态"，不该让位置、
	# 缩放、透明度一起归零 —— 那样热重载和历史跳转看到的都是
	# "跳回初始位置再把当前句动画播一遍"
	_saved_transforms.clear()
	for tag in _entries:
		var node: Node = _entries[tag]["node"]
		if node != null and is_instance_valid(node):
			_saved_transforms[tag] = _capture_transform(node)

	for tag in _entries:
		var layer_: Node = _entries[tag]["layer"]
		remove_child(layer_)
		layer_.queue_free()
	_entries.clear()

## 记下一个包装层当前的变换：位置 / 缩放 / 旋转 / 透明度。
##
## 只记这四个量，不记 ATL 的内部状态 —— 重建后 ATL 是新建的，
## 它从节点读初值，于是自然接着这几个值往下算。
##
## 够用的前提是内容尺寸没变。热重载若换了模型尺寸，位置会按新尺寸重算，
## 那种情况下本来也该重新定位
func _capture_transform(node: Node) -> Dictionary:
	var out := {
		"position": Vector2.ZERO,
		"scale": Vector2.ONE,
		"rotation": 0.0,
		"alpha": 1.0,
	}

	if node is Node2D:
		var n2 := node as Node2D
		out["position"] = n2.position
		out["scale"] = n2.scale
		out["rotation"] = n2.rotation
	elif node is Control:
		var c := node as Control
		out["position"] = c.position
		out["scale"] = c.scale
		out["rotation"] = c.rotation

	if node is CanvasItem:
		out["alpha"] = (node as CanvasItem).modulate.a

	return out

## 把重建前记下的变换贴到新节点上。
##
## 返回是否真的贴过。贴过就说明这个 tag 是"沿用旧位置"的，
## 默认的 xycenter 不能再把它挪到舞台中心 —— 那个位置就是它该在的地方
func _restore_transform(tag: String, node: Node) -> bool:
	if node == null or not _saved_transforms.has(tag):
		return false

	var saved: Dictionary = _saved_transforms[tag]
	_saved_transforms.erase(tag)
	_apply_pose(node, saved)
	return true

## 把一份姿态贴到节点上。
##
## 姿态是 { position, scale, rotation, alpha }，由 _capture_transform() 产出。
## 两条路径共用这一段：热重载从销毁前的节点抓，读档从存档里取
func _apply_pose(node: Node, saved: Dictionary) -> void:
	if node == null or saved.is_empty():
		return

	var pos: Vector2 = saved.get("position", Vector2.ZERO)
	var scale_v: Vector2 = saved.get("scale", Vector2.ONE)
	var rot: float = float(saved.get("rotation", 0.0))

	if node is Node2D:
		var n2 := node as Node2D
		n2.position = pos
		n2.scale = scale_v
		n2.rotation = rot
	elif node is Control:
		var c := node as Control
		c.position = pos
		c.scale = scale_v
		c.rotation = rot

	if node is CanvasItem:
		var ci := node as CanvasItem
		var m := ci.modulate
		m.a = float(saved.get("alpha", 1.0))
		ci.modulate = m

## 把新的舞台状态对齐到节点树。
##
## 增量处理，不做全量重建：新出现的建节点、消失的销毁、属性变的重建、
## 只有 order 变的只改 layer。全量重建会让视频重新加载、立绘闪一下 ——
## 而 stage_changed 在 scene 之后常常连发好几次（连续 show）
func _apply_stage(stage: Dictionary) -> void:
	# 变化之前的节点集合。转场时"哪些是新出现的"就靠它区分
	var before := _content_nodes()
	var changed := false

	# 已经不在舞台上的，挪进待转场列表。没有 with 消费时下一帧销毁
	for tag in _entries.keys():
		if not stage.has(tag):
			var gone: Dictionary = _entries[tag]
			_entries.erase(tag)
			_keep_leaving(gone)
			changed = true

	for tag in stage:
		var entry: Dictionary = stage[tag]
		var attrs := String(entry.get("attrs", ""))
		var order := int(entry.get("order", 0))
		var at_name := String(entry.get("at", ""))
		var atl := String(entry.get("atl", ""))
		# 读档时贴进来的姿态。普通 show 不会带这一项 —— 它只活一次重建
		var pose: Dictionary = entry.get("pose", {})

		if not _entries.has(tag):
			_add_entry(tag, attrs, order, at_name, atl, pose)
			changed = true
			continue

		var e: Dictionary = _entries[tag]
		var inner: Node = e["inner"]
		if String(inner.get_meta("vn_attrs", "")) != attrs:
			# 属性变了。节点若能自己消化就复用它 —— L2D 重建的代价是
			# 重新加载 moc3 和纹理，还要丢掉物理摆动与动作进度，
			# 而"换个表情"在剧本里是极常见的操作。
			# 它返回 false 表示这次变化超出原地更新的范围（比如换了模型），
			# 那就仍然走重建
			if _try_update_attrs(inner, attrs):
				inner.set_meta("vn_attrs", attrs)
				_set_layer(e["layer"], order)
				_maybe_restart_atl(e, at_name, atl)
				continue

			# 静态图换属性就是换张贴图，视频重新加载会从头播 ——
			# 但视频的属性不应该在播放中途变，所以这个代价可以接受。
			# 重建要连包装层一起换掉：内容节点换了，包装层没有复用的理由
			_entries.erase(tag)
			_keep_leaving(e)
			_add_entry(tag, attrs, order, at_name, atl, pose)
			changed = true
		else:
			_set_layer(e["layer"], order)
			_maybe_restart_atl(e, at_name, atl)

	if changed:
		_arm_pending(before)

	# 恢复只在重建后的第一次对齐里有效。剩下的（新状态里已经不存在的 tag）
	# 留着也没用 —— 在下次重建之前它们不会再有节点
	_saved_transforms.clear()

## 让节点自己消化属性变化。节点没实现 apply_attrs() 时返回 false。
##
## 这是给"重建代价很高"的后端留的口子 —— 目前只有 L2D 用得上。
## 契约是：
##   返回 true  —— 已按新属性更新完毕，调用方复用这个节点
##   返回 false —— 这次变化我处理不了，请销毁我重建
func _try_update_attrs(node: Node, attrs: String) -> bool:
	if not node.has_method("apply_attrs"):
		return false
	return bool(node.call("apply_attrs", attrs.split(" ", false)))

## 实例化一个 tag 的内容节点，连同它的包装层一起挂上舞台。
##
## 先让内容进包装层、再把包装层挂上舞台，顺序不能反：反过来的话，
## 内容会先以"直接挂在本层下"的身份入树一次，它的 _ready() 里
## 看到的层级与坐标基准都是临时的，L2D 还会顺手多做一次布局
##
## pose 是读档带回来的姿态。热重载不走它（那边从旧节点现抓一份，
## 见 _saved_transforms），两条路径最后都汇到 _apply_pose()
func _add_entry(tag: String, attrs: String, order: int,
		at_name: String = "", atl: String = "",
		pose: Dictionary = {}) -> void:
	var node := resolve(tag, attrs.split(" ", false))
	if node == null:
		push_warning("舞台上没有可显示的东西：\"%s %s\"" % [tag, attrs])
		return

	# 图和视频上屏了即算"看过"，CG 鉴赏靠这份记录解锁。
	# 记的是 tag 而不是 tag_attrs：CG 鉴赏的条目都是不带属性的图
	# （scene cg1 / scene bg1），带属性的立绘变体不需要单独解锁。
	# 重放舞台时会再标记一次，但 mark_image_seen() 是幂等的
	#
	# 先查表：内置显示物（雨）没有对应素材，记进去只会让 images.dat
	# 多一条永远用不上的记录
	if VN.images().has(tag):
		VN.config.mark_image_seen(tag)

	_disable_mouse(node)
	node.set_meta("vn_attrs", attrs)

	# 需要整体透明度的内容先烘焙进一张纹理 —— 见文件头。
	# 此时它和内容都还没入树，内容的 _ready() 仍然等到整条链挂上舞台
	# 之后才跑，L2D 的定位拿到的视口尺寸不受影响
	var inner := node
	var sprite: Sprite2D = null
	var viewport: SubViewport = null
	if _needs_alpha_group(node):
		# 尺寸先按全屏占位，等入树、内容跑完自己的 _ready() 之后
		# 再由 _fit_alpha_texture() 收缩到实际占用的矩形 ——
		# L2D 要在这时才知道自己的画布尺寸
		viewport = SubViewport.new()
		viewport.size = Vector2i(get_viewport().get_visible_rect().size)
		viewport.transparent_bg = true
		viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		viewport.disable_3d = true
		viewport.gui_disable_input = true
		viewport.add_child(node)

		sprite = Sprite2D.new()
		sprite.centered = false
		sprite.add_child(viewport)
		node = sprite

	var layer_ := CanvasLayer.new()
	_set_layer(layer_, order)
	layer_.add_child(node)
	add_child(layer_)

	# 纹理要等入树之后再取：ViewportTexture 绑的是 viewport 的 RID，
	# 未入树时拿到的是无效纹理，Sprite2D 会一直空白
	if sprite != null:
		_fit_alpha_texture(sprite, viewport, inner)

	# 恢复姿态。两条来源，优先级不能倒：
	#
	#   1) pose 非空 —— 读档 / 历史跳转带回来的。它属于"那一刻"，是权威值
	#   2) 否则看 _saved_transforms —— 热重载在原地销毁前抓的
	#
	# 反过来的话，历史跳转会被 _on_stage_rebuilt() 抓到的那份盖掉：那一路
	# 抓的是 restore_position() 里 advance() 之后、且可能已经是别的章节的
	# 画面，真正的"那一条历史当时的姿态"反而被丢掉
	var restored := false
	if not pose.is_empty():
		_apply_pose(node, pose)
		restored = true
	else:
		restored = _restore_transform(tag, node)

	_entries[tag] = {
		"layer": layer_,
		"node": node,
		"inner": inner,
		"at": at_name,
		"atl": atl,
		"atl_player": _start_atl(node, at_name, atl, restored),
	}

## 为一个包装层启动 ATL。
##
## 三种来源，优先级从高到低：
##   内联块（`show lili:` 后面的冒号块）
##   at 指定的 transform（查剧本包里的 transform 表）
##   两者都没有 —— 默认的 xycenter（"没写 at 就居中"）
##
## skip_default 为 true 表示这个节点刚从重建里恢复了旧位置：这时**不能**
## 再套默认的 xycenter，否则画面会"跳回中心再把动画播一遍"，正是重建后
## 位置不对的来源
##
## 内联块在指令里是 JSON 字符串。属性名在编译期已经校验过，走到
## 解析失败只可能是产物损坏；那种情况退回默认值，比让整个舞台不动要好
func _start_atl(node: Node, at_name: String, atl: String,
		skip_default: bool = false) -> RefCounted:
	var blocks: Array = []
	var has_source := not atl.is_empty() or not at_name.is_empty()

	if not atl.is_empty():
		var parsed = JSON.parse_string(atl)
		if parsed is Array:
			blocks = parsed
	elif not at_name.is_empty():
		var story: VNStory = VN.player.story if VN.player != null else null
		if story != null and story.transforms.has(at_name):
			var defined = story.transforms[at_name]
			if defined is Array:
				blocks = defined

	if not has_source and skip_default:
		return null

	var player = ATL_SCRIPT.new()
	# 烘焙层报的纹理是放大过的，ATL 要靠这个倍数把数值换算回逻辑尺寸。
	# 普通内容没有这个 meta，取默认的 1:1
	var render_scale: Vector2 = node.get_meta("vn_supersample", Vector2.ONE)
	player.start(node, blocks, get_viewport().get_visible_rect().size, render_scale)
	return player

## 动画来源变了就重播，没变就让它接着跑。
##
## 不能无条件重播：stage_changed 在 scene 之后常常连发好几次（连续 show），
## 每次都重放的话，循环动画会被反复打回第 0 帧，表现为"一直卡在第一段"
##
## 换之前先把上一段结算掉。玩家点得太快时它可能只播了一半，直接换的话
## 新动画会从半路的位置起跳 —— 表现成"上一段没演完就跳走了"。结算到
## 最终态再接手，新动画的起点就是它本该到的终点
func _maybe_restart_atl(entry: Dictionary, at_name: String, atl: String) -> void:
	if String(entry.get("at", "")) == at_name and String(entry.get("atl", "")) == atl:
		return

	var previous = entry.get("atl_player")
	if previous != null:
		previous.finish()

	entry["at"] = at_name
	entry["atl"] = atl
	entry["atl_player"] = _start_atl(entry["node"], at_name, atl)

## 推进所有常驻 ATL。
##
## 已经播完的也要每帧看一眼：内容尺寸可能在播完之后才确定（L2D 的纹理、
## 视频流），那时要把最终状态重新贴一次，否则位置会停在"零尺寸"那次
## 算出来的值上
func _update_atl(delta: float) -> void:
	for tag in _entries:
		var entry: Dictionary = _entries[tag]
		var player = entry.get("atl_player")
		if player != null:
			player.update(delta)

## 存档 / 历史条目要一份当前姿态时，session 会发这个信号。
## 把每个 tag 包装层的变换填进 buffer。
##
## 只填包装层：它是屏幕上真正被 ATL 摆布的那个节点。inner 的坐标是内容
## 自己算的（L2D 的画布偏移、视频的布局），存下来对下次重建没有意义 ——
## 新内容会重新算一遍
##
## 填进调用方给的 buffer 而不是写回舞台数据：这份姿态要存进历史条目和
## 存档，不该留在 _stage 里和读档重建用的那份混在一起
func _on_pose_requested(buffer: Dictionary) -> void:
	for tag in _entries:
		var node: Node = _entries[tag]["node"]
		if node != null and is_instance_valid(node):
			buffer[tag] = _capture_transform(node)

## 剧本要求把某个 tag 的动画结算到最终态（`show <tag> at end`）。
##
## 两条"什么都不做"的路都是正常情况，不报警：
##   · 舞台上没有这个 tag —— 它可能已经 hide 了
##   · 它本来就没在播动画 —— 玩家正常点击，动画早就播完了
## 这正是 at end 的语义：把还没演完的那一段补完，没得补就直接过
func _on_atl_end_requested(tag: String) -> void:
	if not _entries.has(tag):
		return

	var player = _entries[tag].get("atl_player")
	if player != null:
		player.finish()

## 把烘焙纹理收缩到内容实际占用的屏幕矩形。
##
## 全屏 RT 是浪费：L2D 按视口高度缩放之后，mao_pro 只有约 994×1440，
## 占屏幕面积的三分之一。两个角色同屏时这笔账会翻倍，而移动端的填充率
## 本来就紧。所以纹理按内容报的包围盒分配，Sprite 摆回去。
##
## 内容通过三个可选方法参与这一段的决策：
##   alpha_group_rect()    本地包围盒，决定纹理的逻辑尺寸
##   alpha_group_rt_size() 目标分辨率，决定纹理的像素尺寸
## 内容都没实现、或报了空矩形时保持全屏，行为与不收缩时一致
func _fit_alpha_texture(sprite: Sprite2D, viewport: SubViewport, inner: Node) -> void:
	var body := inner as Node2D
	var local := Rect2()
	if body != null and inner.has_method("alpha_group_rect"):
		local = inner.call("alpha_group_rect")

	if body == null or local.size.x <= 0.0 or local.size.y <= 0.0:
		# 退化路径：模型还没报出包围盒，退回全屏 RT，1:1。
		# 这条路上也没有模型可渲染，不值得为它把纹理放大
		sprite.texture = viewport.get_texture()
		return

	# 四周留一点余量：呼吸与物理会让网格在画布边缘外轻微滑动，
	# 贴边的模型不留余量会被切掉一条
	var pad: Vector2 = local.size * ALPHA_TEXTURE_PADDING
	var size: Vector2 = (local.size + pad * 2.0).round()
	var origin: Vector2 = body.position + local.position - pad

	# 纹理分配多大由内容自己说。声明了就当**精确**的目标分辨率用，
	# 没声明就按逻辑尺寸 1:1。两个方向都允许：大于逻辑尺寸是超采样，
	# 小于就是降采样（省显存与填充率，代价是放大后更糊）。
	#
	# 不做下限保护 —— 那会让"我想按 1000×1500 渲染"这种诉求无声失效。
	# 16 只是防呆，避免把 RT 设成零
	var rt_size := size
	var render_scale := Vector2.ONE
	var declared := _alpha_group_rt_size(inner)
	if declared.x > 0.0 and declared.y > 0.0:
		rt_size = Vector2(maxf(declared.x, 16.0), maxf(declared.y, 16.0)).round()
		render_scale = rt_size / size

	# 2D 坐标空间仍是逻辑尺寸：模型保持原来的坐标布局，只是用更多像素
	# 光栅化。inner 的位置、缩放一个都不用改
	viewport.size = Vector2i(rt_size)
	viewport.size_2d_override = Vector2i(size)
	viewport.size_2d_override_stretch = true

	body.position = -local.position + pad
	sprite.position = origin
	sprite.texture = viewport.get_texture()
	# 纹理比逻辑尺寸大，先缩回原大小；ATL 启动后会按同一比例重新算一遍。
	# 不设的话，没写 at、也没有内联块的那种 show 会按纹理大小铺出来
	sprite.scale = Vector2.ONE / render_scale
	# 让 ATL 知道它摆布的是"放大过的纹理"：所有对外数值都要换算回逻辑尺寸
	sprite.set_meta("vn_supersample", render_scale)

## 内容声明的烘焙分辨率（像素）。没实现这个方法、或报了零，表示按逻辑
## 尺寸 1:1 分配 —— 不做超采样，放大后的阶梯也就保持原样
func _alpha_group_rt_size(node: Node) -> Vector2:
	if not node.has_method("alpha_group_rt_size"):
		return Vector2.ZERO
	var value = node.call("alpha_group_rt_size")
	if value is Vector2:
		return value
	return Vector2.ZERO

## 内容是否声明了自己需要整体透明度。
##
## 契约是几个可选方法，本类不认识任何具体后端 —— 和 apply_attrs() 一样
## 是"内容自己说了算"的约定：
##   needs_alpha_group() -> bool  声明要烘焙成一张纹理再整体调透明度
##   alpha_group_rect() -> Rect2  可选，报自己的本地包围盒；不报就按全屏分配
##   alpha_group_rt_size() -> Vector2  可选，报烘焙纹理的目标分辨率
func _needs_alpha_group(node: Node) -> bool:
	if not node.has_method("needs_alpha_group"):
		return false
	return bool(node.call("needs_alpha_group"))

## 把一个内容放到指定的层上。
##
## 这里不再是 z_index 而是 CanvasLayer.layer：两者都决定遮挡顺序，
## 但 layer 是"层与层"之间的排序，不受内容内部 z 的影响 ——
## 这正是 L2D 那种"自带几百个部件 z"的内容需要的
func _set_layer(layer_: Node, order: int) -> void:
	if not (layer_ is CanvasLayer):
		return

	if order > MAX_LAYER:
		if not _layer_warned:
			_layer_warned = true
			push_warning("舞台内容超过 %d 个，多出来的会挤在同一层上，"
				% MAX_LAYER + "遮挡关系将取决于节点顺序。"
				+ "要放宽请同时调大 MAX_LAYER 和 MainLayer 的 layer")
		order = MAX_LAYER

	(layer_ as CanvasLayer).layer = order

## 舞台上的东西一律不参与 GUI 输入。
##
## Control 的 mouse_filter 默认是 MOUSE_FILTER_STOP。铺满全屏的
## VideoStreamPlayer 会把点击整个吞掉并标记为已处理，事件到不了
## say.gd 的 _unhandled_input —— 症状就是"动态 CG 一出来就点不动了"。
## 而 Sprite2D 是 Node2D，压根不参与命中测试，所以静态图从来没暴露这个问题。
##
## 在这里统一处理而不是只修视频：将来任何 Control 系的内容
## （L2D 模型、要点击的 CG）挂上来都会撞上同一个坑。
## 反过来，需要点击交互的内容自己把 mouse_filter 打开就行
func _disable_mouse(node: Node) -> void:
	if node is Control:
		(node as Control).mouse_filter = Control.MOUSE_FILTER_IGNORE

###########################################################
#  舞台转场
#
#  剧本里的 with 落到这里。流程：
#    1. _apply_stage 把被移除/重建的包装层藏起来、记进 _leaving
#    2. with_run 发来请求时，_play_transition 拿 _leaving 当旧画面、
#       拿 _pending_before 之外的新节点当新画面
#    3. 转场结束销毁旧包装层，通知播放器继续
#
#  没有被 with 消费的变化在下一帧由 _process 丢弃 —— 普通 show / scene
#  仍然是瞬时切换，行为和加 with 之前完全一样
###########################################################

## 没有 with 消费的待转场节点在这里清理。
## 包装层在 _keep_leaving() 里已经藏起来，销毁它不会被玩家看到
##
## 预取也挂在这里：每帧最多消化一个请求，加载的那一帧会卡住几百毫秒，
## 但至少不会连着卡好几帧
func _process(delta: float) -> void:
	_update_atl(delta)

	if not _prefetch_queue.is_empty():
		_build_prefetched()

	if not _pending_active:
		return
	if Engine.get_process_frames() <= _pending_frame:
		return
	_drop_pending()

###########################################################
#  预加载池
###########################################################

## 播放器报来一批"接下来会 show 的内容"。
##
## 按后端分两路：
##   cubism          进池，由 _process 每帧建一个（加载是同步的，几百毫秒）
##   静态立绘 / 图 / 视频  只需一次后台预读，交给资源加载器就行
##
## 认不出来的 tag 一律忽略 —— 预取是尽力而为，真正 show 时该报的错照报
func _on_prefetch_requested(requests: Array) -> void:
	for request in requests:
		var tag := String(request.get("tag", ""))
		if tag.is_empty():
			continue

		var kind := VN.character_property(tag, "portrait_kind")
		if kind == "cubism":
			if _queued_tag(tag) or _pool_has(tag, _attrs_of(request)):
				continue
			_prefetch_queue.append(request)
			continue

		_prefetch_resource(_asset_path(tag, _attrs_of(request), kind))

## 推算一个非 cubism 内容会用到哪个资源。推不出来时返回空串。
##
## 这条路径只服务于预读 —— 真正的解析仍然走 resolve()。两边算得不一样
## 最多是多读一个文件或少读一个，不会让画面出错
func _asset_path(tag: String, attrs: PackedStringArray, kind: String) -> String:
	if kind == "static":
		return _portrait_path(tag, attrs)

	var id := tag
	for a in attrs:
		id += "_" + a
	var table := VN.images()
	if table.has(id):
		return String(table[id])
	return ""

## 预读一个图像或视频。真正的 load() 会命中同一份缓存，
## 这里只是把 I/O 提前到玩家还在读上一句的时候
func _prefetch_resource(path: String) -> void:
	if path.is_empty() or not ResourceLoader.exists(path):
		return
	ResourceLoader.load_threaded_request(path)

## 队列里是否已经有这个 tag 在等
func _queued_tag(tag: String) -> bool:
	for request in _prefetch_queue:
		if String(request.get("tag", "")) == tag:
			return true
	return false

## 把请求里的属性串拆成数组。空串拆出空数组
func _attrs_of(request: Dictionary) -> PackedStringArray:
	return PackedStringArray(String(request.get("attrs", "")).split(" ", false))

## 池里是否已经有一个能直接用的节点
func _pool_has(tag: String, attrs: PackedStringArray) -> bool:
	if not _pool.has(tag):
		return false
	return (_pool[tag]["node"] as VNPortraitCubism).matches_attrs(attrs)

## 从队列里取一个请求真正加载。
##
## add_child 会同步把 _ready() 跑完，几百毫秒就花在这一行上 —— 这正是
## 预加载的代价：卡顿从"show 的那一刻"挪到"玩家读上一句的时候"
func _build_prefetched() -> void:
	var request: Dictionary = _prefetch_queue.pop_front()
	var tag := String(request.get("tag", ""))
	var attrs := _attrs_of(request)

	# 排队期间它可能已经被 show 出来了。舞台上已经有一个同变体的模型时
	# 再预取一份，只会在池里多躺一份没人要的副本
	if _entries.has(tag):
		var shown: Node = _entries[tag]["inner"]
		if shown is VNPortraitCubism and (shown as VNPortraitCubism).matches_attrs(attrs):
			return

	# 池里已经有了
	if _pool_has(tag, attrs):
		return

	var portrait := VNPortraitCubism.new()
	portrait.prepare(tag, attrs)
	_pool_root.add_child(portrait)

	# 加载失败（资源缺失、模型损坏）时 matches_attrs 会返回 false。
	# 那种节点留在池里占着位置也永远不会被取用，直接丢掉
	if not portrait.matches_attrs(attrs):
		portrait.queue_free()
		return

	_pool_set_active(portrait, false)
	_pool_store(tag, portrait)

## 把一个加载好的节点放进池。同 tag 的旧节点直接丢掉 ——
## 一个角色同时只用一个模型，留着旧的没有意义
func _pool_store(tag: String, node: VNPortraitCubism) -> void:
	_pool_drop(tag)
	_pool[tag] = {"node": node, "variant": node.variant_name()}
	_pool_order.append(tag)

	while _pool_order.size() > POOL_LIMIT:
		_pool_drop(_pool_order[0])

## 丢掉某个 tag 的池节点
func _pool_drop(tag: String) -> void:
	_pool_order.erase(tag)
	if not _pool.has(tag):
		return

	var node: Node = _pool[tag]["node"]
	_pool.erase(tag)
	if is_instance_valid(node):
		node.queue_free()

## 从池里取出一个能用的节点，并把它从池里摘掉。没有就返回 null。
##
## 取出时必须恢复 process_mode：池容器是 DISABLED，不恢复的话模型会停在
## 预加载时的那一帧，不动也不眨眼
func _pool_take(tag: String, attrs: PackedStringArray) -> VNPortraitCubism:
	if not _pool_has(tag, attrs):
		return null

	var node: VNPortraitCubism = _pool[tag]["node"]
	_pool.erase(tag)
	_pool_order.erase(tag)

	if node.get_parent() != null:
		node.get_parent().remove_child(node)
	node.process_mode = Node.PROCESS_MODE_INHERIT
	_pool_set_active(node, true)
	return node

## 开关池节点的渲染。
##
## process_mode 只能停掉模型的 _process，停不掉 gd_cubism 内部那些遮罩
## SubViewport —— 它们建的时候是 UPDATE_ALWAYS，父层不可见也照常每帧渲染。
## 池里躺着两三个模型就是两三次白白的离屏绘制，所以进池时显式关掉
func _pool_set_active(node: Node, on: bool) -> void:
	var mode := SubViewport.UPDATE_ALWAYS if on else SubViewport.UPDATE_DISABLED
	for child in node.get_children():
		if child is SubViewport:
			(child as SubViewport).render_target_update_mode = mode

###########################################################
#  状态投影
###########################################################

## 当前屏幕上所有可整体调透明度的节点（不含包装层）。
## 转场要的是这些节点：包装层是 CanvasLayer，它没有可调的透明度属性
func _content_nodes() -> Array[Node]:
	var out: Array[Node] = []
	for tag in _entries:
		out.append(_entries[tag]["node"])
	return out

## 把一个要消失或要被替换的节点挪进待转场列表。
## 包装层先藏起来：没有 with 消费时它会在下一帧销毁，
## 藏起来就不会在那一帧里和新节点叠在一起
func _keep_leaving(entry: Dictionary) -> void:
	# 要消失的节点不该再被 ATL 推着动 —— 它可能还要陪 with 转场演完，
	# 但那时控制权在转场手上
	entry["atl_player"] = null

	var layer_: Node = entry["layer"]
	if layer_ is CanvasLayer:
		(layer_ as CanvasLayer).visible = false
	_leaving.append(entry)

## 登记一次待转场的变化。同一帧里连续 show / scene 只记第一次，
## 这样 with_run 拿到的是"这一串变化之前的画面"
func _arm_pending(before: Array[Node]) -> void:
	if _pending_active:
		return
	_pending_active = true
	_pending_before = before
	_pending_frame = Engine.get_process_frames()

## 丢弃待转场的旧节点。没有 with 消费时走这里
func _drop_pending() -> void:
	for entry in _leaving:
		_destroy_layer(entry["layer"])
	_leaving.clear()
	_pending_before.clear()
	_pending_active = false
	_pending_frame = -1

## 释放一个包装层。已经进销毁队列的跳过，免得重复 queue_free
func _destroy_layer(layer_: Node) -> void:
	if not is_instance_valid(layer_):
		return
	if layer_.is_queued_for_deletion():
		return
	layer_.queue_free()

## 剧本请求一次舞台转场。没有待转场的变化时（例如 with 前面什么都没改）
## 直接放行 —— 延到帧末是因为此刻还在播放器的 advance() 调用栈里，
## 同步 resume 会让 advance() 递归下去
func _on_stage_transition(transition: String, params: Array,
		serial: int) -> void:
	if not _pending_active:
		VN.resume_transition.call_deferred(serial)
		return
	_play_transition(transition, params, serial)

## 执行一次转场。消费掉 _leaving 与 _pending_before，结束后销毁旧节点并放行播放器
func _play_transition(transition: String, params: Array,
		serial: int) -> void:
	# 先摘下来：转场期间 _process 不能再清理它们
	var leaving := _leaving
	var before := _pending_before
	_leaving = []
	_pending_before = []
	_pending_active = false
	_pending_frame = -1

	var to_hide: Array[Node] = []
	for entry in leaving:
		var layer_: Node = entry["layer"]
		if not is_instance_valid(layer_):
			continue
		if layer_ is CanvasLayer:
			(layer_ as CanvasLayer).visible = true
		var node: Node = entry["node"]
		if node is CanvasItem and is_instance_valid(node):
			to_hide.append(node)

	var to_show: Array[Node] = []
	for tag in _entries:
		var node: Node = _entries[tag]["node"]
		if before.has(node):
			continue
		if node is CanvasItem and is_instance_valid(node):
			to_show.append(node)

	# 画面没变（比如 show 的是当前形态）：转场无事可做，直接放行
	if to_show.is_empty() and to_hide.is_empty():
		_destroy_entries(leaving)
		VN.resume_transition.call_deferred(serial)
		return

	var settings := VNSettings.get_current()
	if not settings.transition_enabled:
		_finish_transition(to_show)
		_destroy_entries(leaving)
		VN.resume_transition.call_deferred(serial)
		return

	var duration := settings.stage_dissolve_time
	if transition == "dissolve" and params.size() > 0:
		duration = float(params[0])

	match transition:
		"dissolve":
			await VN.transition.crossfade(to_show, to_hide, duration)
		"fade":
			await _play_fade(to_show, to_hide, params, settings)
		"none":
			_finish_transition(to_show)
		_:
			push_warning("未知的舞台转场：%s，按瞬时切换处理" % transition)
			_finish_transition(to_show)

	_destroy_entries(leaving)
	VN.resume_transition.call_deferred(serial)

## 黑场转场：旧画面淡到中间色 → 换画面 → 从中间色淡入新画面。
## 新内容在遮罩底下提前就位，全黑那一刻才显示，玩家看不到切换的瞬间
func _play_fade(to_show: Array[Node], to_hide: Array[Node],
		params: Array, settings: VNSettings) -> void:
	var out_time := settings.stage_fade_out_time
	var hold_time := settings.stage_fade_hold_time
	var in_time := settings.stage_fade_in_time
	var color := settings.stage_fade_color

	if params.size() > 0:
		out_time = float(params[0])
	if params.size() > 1:
		hold_time = float(params[1])
	if params.size() > 2:
		in_time = float(params[2])
	if params.size() > 3:
		color = Color.from_string(String(params[3]), color)

	# 新内容先透明。遮罩还没盖满时它不能露出来
	for node in to_show:
		VNTransition.set_alpha(node, 0.0)

	# 全黑那一刻换画面。此时遮罩盖满，玩家看不到任何切换
	var change := func() -> void:
		for node in to_show:
			VNTransition.set_alpha(node, 1.0)
		for node in to_hide:
			VNTransition.set_alpha(node, 0.0)

	await VN.transition.fade_through(change, out_time, hold_time, in_time, color)

## 把新内容补到不透明。instant 与转场收尾共用
func _finish_transition(to_show: Array[Node]) -> void:
	for node in to_show:
		VNTransition.set_alpha(node, 1.0)

## 销毁一批包装层
func _destroy_entries(entries: Array) -> void:
	for entry in entries:
		_destroy_layer(entry["layer"])

###########################################################
#  解析（扩展点）
###########################################################

## 把一个 tag + 属性解析成可显示的节点。返回 null 表示没有对应资源。
##
## 默认分派规则：
##    tag 是注册过的角色 → 按它声明的 portrait_kind 走对应的立绘后端
##    否则               → 查 content/images/ 的索引，当普通图像处理
##
## 覆写本方法即可接入新的后端。覆写时建议先调 super() 或自己完整分派，
## 两种都行 —— 这里没有任何隐藏状态
func resolve(tag: String, attrs: PackedStringArray) -> Node:
	# 内置显示物优先于图像表。名字被占用了就是占用了 ——
	# 将来真的往 content/images/ 里放一张 rain.png，也压不过这一支
	if tag == RAIN_TAG:
		return _make_rain(attrs)

	var kind := VN.character_property(tag, "portrait_kind")
	if kind.is_empty():
		return _resolve_image(tag, attrs)
	return _resolve_portrait(tag, attrs, kind)

## 雨。程序化生成，没有任何源文件可扫，所以不查图像表。
## 档位与过渡时长交给节点自己解析 —— 和 L2D 的 apply_attrs() 一样，
## 是"内容自己说了算"的约定
func _make_rain(attrs: PackedStringArray) -> Node:
	var rain := VNRain.new()
	rain.setup(attrs)
	return rain

## 角色立绘。按**声明的**方式分派 —— 声明是显式的，所以资源缺失时
## 能说出准确原因，而不是"自动判断猜错了后端"。
## cubism 的实现见 portrait_cubism.gd
func _resolve_portrait(tag: String, attrs: PackedStringArray, kind: String) -> Node:
	match kind:
		"static":
			return _make_sprite(_portrait_path(tag, attrs))
		"layered":
			push_warning("角色 \"%s\" 声明为 layered，但层叠式后端还没实现" % tag)
			return null
		"cubism":
			# 先从预加载池里取。取到的是已经读完 moc3 与纹理的节点，
			# show 时省掉那几百毫秒
			var cached := _pool_take(tag, attrs)
			if cached != null:
				# 预加载时刻意没应用属性（见 prepare），现在补上。
				# 表情与动作从此刻开始，和刚加载完再应用完全一样
				cached.apply_attrs(attrs)
				return cached

			var portrait := VNPortraitCubism.new()
			# 属性交给它自己解析。放在这里而不是 _add_entry() 里，
			# 是因为它需要在入树之前的构造阶段就知道自己是谁 ——
			# 换模型变体要重新加载，那不该发生在节点已经在屏幕上的时候
			portrait.setup(tag, attrs)
			return portrait
		_:
			push_error("角色 \"%s\" 的 portrait_kind 不认识：\"%s\"" % [tag, kind])
			return null

## 静态立绘路径：content/role/<tag>/<tag>_<属性下划线相连>.png。
## 无属性时是 <tag>.png
func _portrait_path(tag: String, attrs: PackedStringArray) -> String:
	var file := tag
	for a in attrs:
		file += "_" + a
	return ROLE_DIR.path_join(tag).path_join(file + ".png")

## 非角色的图像：查编译器写进剧本包的图像表。
##
## 表为空是一个独立的故障（包没编译、或版本过旧读不到 image 段），
## 和"这一张图不存在"要分开说 —— 前者会让整场剧情的背景全部消失，
## 而报错现场只有一句含糊的"舞台上没有可显示的东西"
func _resolve_image(tag: String, attrs: PackedStringArray) -> Node:
	var id := tag
	for a in attrs:
		id += "_" + a

	var table := VN.images()
	if table.is_empty():
		if not _images_warned:
			_images_warned = true
			push_warning("图像表为空：剧本包可能没编译，或是旧格式的包。"
				+ "重新编译一次剧本即可 —— 表由编译器扫描 content/images/ 生成")
		return null

	if not table.has(id):
		return null

	var path: String = table[id]
	if path.get_extension().to_lower() == "ogv":
		return _make_video(path)
	return _make_sprite(path)

###########################################################
#  节点构造
###########################################################

## 静态图。用 Sprite2D 而不是 TextureRect：它是 Node2D 系，
## 定位直接靠 position，不受 anchor 系统影响
func _make_sprite(path: String) -> Node:
	if not ResourceLoader.exists(path):
		push_warning("图像不存在：%s" % path)
		return null

	var tex := load(path)
	if not (tex is Texture2D):
		push_warning("不是可用的贴图：%s" % path)
		return null

	var sprite := Sprite2D.new()
	sprite.texture = tex
	sprite.centered = false
	return sprite

## 视频。VideoStreamPlayer 是 Control，而它的几个默认值都不适合 VN 场景：
##   loop / autoplay 默认 false —— 不改就播一次停住
##   expand 默认 false         —— 不改视频不会缩放到 size
##   size 默认 (0, 0)          —— 不设就是一片空白，而且不报任何错
##   bus 默认 Master           —— 那样会绕过项目的分轨设计
func _make_video(path: String) -> Node:
	if not ResourceLoader.exists(path):
		push_warning("视频不存在：%s" % path)
		return null

	var stream := load(path)
	if not (stream is VideoStream):
		push_warning("不是可用的视频流：%s" % path)
		return null

	var player := VideoStreamPlayer.new()
	player.stream = stream
	player.loop = true
	player.expand = true
	player.size = get_viewport().get_visible_rect().size
	player.bus = VNSettings.get_current().video_bus
	player.autoplay = true
	return player

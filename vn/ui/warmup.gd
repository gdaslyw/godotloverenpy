class_name VNWarmup
extends Node

# ═══════════════════════════════════════════════════════════
#  界面预热池。把"界面第一次出场的构建成本"从玩家眼前挪到空闲帧。
#
#  ── 对应 Ren'Py 的哪一层 ──
#  predict_screen()。Ren'Py 的 predict 协程会把目标的 screen 语言真跑一遍
#  （display/screen.py:1393 → ScreenDisplayable.update()），再把结果树里的
#  图片丢给预解码线程，然后**整棵树丢掉** —— 它从不复用界面本身。
#
#  本类多做一步：把建好的节点树留着，切换时直接搬走。因为我们这边没有
#  "screen 语言"这种每次都要重新解释的东西，_ready() 跑完就等价于
#  "这个界面已经建好了"，留着比重建便宜。
#
#  ── 为什么池里的实例是一次性的 ──
#  取走就销毁，不再放回。复用要处理界面上的一切瞬时状态：滑块的当前值、
#  "跳过未读"的开关、占位选项的选中态……重置这些比重新 instantiate()
#  更容易出状况，而且出状况是**静默**的 —— 玩家看到的是"设置界面记着
#  上次没保存的值"。VNStage 的立绘池（stage.gd:_pool）出于同样的理由
#  也只存不还。
#
#  ── 为什么容器不可见 ──
#  预热只为跑 _ready()，不需要画出来。不可见 + layer -1 + 进程禁用，三条
#  合起来保证池里的东西既不渲染、不接输入、也不跑 _process，只是躺在内存里。
#
#  代价是 _draw() 也不会执行，而 VNButton 的底图偏偏是懒在 _draw() 里读盘
#  的。所以建完要再请它预载一次，见 _preload_textures()
# ═══════════════════════════════════════════════════════════

## 池与队列加起来的登记上限。
##
## 只为防调用点写错，不是容量规划：界面不是立绘，正常项目不会登记几十个。
## 真撞上了说明某处循环在无脑 request，让它响一声比静默吃掉好
const LIMIT := 8

## 已经建好、脱离树等待取用的实例。PackedScene → Node
var _pool: Dictionary = {}

## 排队等待构建的场景，先进先出
var _queue: Array[PackedScene] = []

## 池容器。不可见、不接输入、不跑 _process
var _root: CanvasLayer = null

###########################################################

func _ready() -> void:
	# 照抄 VNStage 的 PortraitPool（stage.gd:_ready）：layer 取 -1 藏在
	# 所有内容层之下，不可见，进程模式禁用。这样预热出来的界面既不参与
	# 绘制，也不会因为 _process 里的逻辑提前改变状态
	_root = CanvasLayer.new()
	_root.name = "WarmupPool"
	_root.layer = -1
	_root.visible = false
	_root.process_mode = Node.PROCESS_MODE_DISABLED
	add_child(_root)

	# 队列空时不占帧。request() 会把开关打开
	set_process(false)

###########################################################
#  公共接口
###########################################################

## 登记一个待预热的界面。重复登记会被忽略。
##
## 登记**不等于立刻构建** —— 真正的构建要等转场结束，见 _step()。
## 已经热好或正在排队的场景再登记一次是空操作
func request(scene: PackedScene) -> void:
	if scene == null:
		return

	if _pool.has(scene) or _queue.has(scene):
		return

	if _pool.size() + _queue.size() >= LIMIT:
		push_warning("VNWarmup：池已满（%d），%s 未登记"
			% [LIMIT, scene.resource_path])
		return

	_queue.append(scene)
	set_process(true)

## 取一个已经预热好的实例。**没热好返回 null，不是错误**。
##
## 调用方一律写成"取得到就用、取不到就 instantiate()"：
##
##     var page := VN.warmup.take(SCENE)
##     if page == null:
##         page = SCENE.instantiate()
##
## 这样预热失败、玩家点得太快、池被取消，全都走同一条退路，
## 调用方永远不需要关心"热好了没有"。
##
## 取出的节点**已经脱离树**，调用方必须 add_child 它。拿了却不挂上去
## 的话它不会自己释放 —— 这是池的固有代价，立绘池也一样
func take(scene: PackedScene) -> Node:
	if scene == null:
		return null

	# 还在排队：调用方现在就要用，撤销登记，让它走 instantiate 那条路
	if _queue.has(scene):
		_queue.erase(scene)
		if _queue.is_empty():
			set_process(false)

	if not _pool.has(scene):
		return null

	var node: Node = _pool[scene]
	_pool.erase(scene)
	return node

## 撤销一个还没被取走的登记，排队的和已建好的一并清掉。
##
## 给"玩家已经离开这个区域、这些界面不会再打开了"的场景用 ——
## 不撤销也不会出错，只是白占内存
func cancel(scene: PackedScene) -> void:
	if scene == null:
		return

	if _queue.has(scene):
		_queue.erase(scene)
		if _queue.is_empty():
			set_process(false)

	if _pool.has(scene):
		var node: Node = _pool[scene]
		_pool.erase(scene)
		if is_instance_valid(node):
			node.queue_free()

## 丢弃池里和队列里的全部登记。
##
## 切语言时调一次。池里存的是**用旧语言、旧字体建好的实例**：Label 上的
## 文字在 _ready() 那一刻就定下来了，引擎不会因为 set_locale 回头改它。
## 不丢的话，切完语言再点设置页会拿到一个预热过的旧语言页面 ——
## 而且它看起来完全正常，不会有任何报错
##
## 这里用 queue_free 而不是 free：调用点可能正处在某个节点的信号回调里
## （语言按钮的 vn_pressed），同步释放会把正在执行回调的那棵树拆掉
func clear() -> void:
	for scene: PackedScene in _pool:
		var node: Node = _pool[scene]
		if is_instance_valid(node):
			node.queue_free()
	_pool.clear()

	_queue.clear()
	set_process(false)

###########################################################
#  构建
###########################################################

## 每帧检查一次队列：转场不在跑，就建一个。
##
## 每帧只建一个而不是一口气建完，理由和 VNStage 的预取队列一样 ——
## add_child 是同步的，连着做几个会把一帧撑爆。三页三帧约 50 毫秒，
## 而玩家从目录页移到侧边栏再点下去怎么也要一两百毫秒，够用
func _process(_delta: float) -> void:
	_step()

## 消化队列里的一个。
##
## 转场期间不建：add_child 会同步跑完整棵界面树的 _ready()，那一帧必然
## 掉帧。落在转场中就是玩家正盯着画面看的时候抖一下；落在转场结束后，
## 画面是静止的，掉一帧看不出来
func _step() -> void:
	if _queue.is_empty():
		set_process(false)
		return

	# transition 一定比本类先装配好（见 VNFrame._ready 的第 11 步），
	# 判空只是不让一次装配失误连累整条预热带
	if VN.transition != null and VN.transition.is_running():
		return

	var scene: PackedScene = _queue.pop_front()
	_build(scene)

## 实例化一个界面，把它的 _ready() 跑完，然后搬出树存进池。
##
## 成本就压在 add_child 那一行上 —— 它会同步把整棵子树的 _ready() 跑完，
## stage.gd:469 的注释说的是同一件事。
##
## ── 被预热的界面有一条约束 ──
## _ready() 里不能 await 任何东西。add_child 返回的那一刻 _ready() 必须
## 已经全部执行完，池里存的才算一个"到齐了"的界面。带 await 的 _ready
## 会在下一帧接着跑，那时节点已经被 remove_child 了，剩下的初始化就落在
## 半路上。
##
## 现有界面都没有这个用法。写在这里是给后来的人看 —— 这类问题不报错，
## 只表现为"同一个界面，预热过的和没预热过的长得不一样"
func _build(scene: PackedScene) -> void:
	var node := scene.instantiate()
	if node == null:
		push_error("VNWarmup：无法实例化 %s" % scene.resource_path)
		return

	_root.add_child(node)

	# 不可见的节点不会 _draw()，而 VNButton 的底图是在 _draw() 里才读盘的。
	# 不在这里补一次，这批图仍然要等第一次真正显示时才加载，预热就只热了
	# 节点树那一半
	_preload_textures(node)

	_root.remove_child(node)
	_pool[scene] = node

## 递归请界面里所有按钮把自己的底图读进缓存。
##
## 只认 VNButton：别的控件要么没有懒加载的图，要么读盘成本可以忽略。
## 这里故意不写成通用接口（比如给 Node 加一个 warm() 虚方法），
## 因为那会要求每个控件都实现一遍，而目前只有按钮有这个问题
func _preload_textures(node: Node) -> void:
	if node is VNButton:
		(node as VNButton).preload_textures()

	for child in node.get_children():
		_preload_textures(child)

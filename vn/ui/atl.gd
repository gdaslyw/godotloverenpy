class_name VNATL
extends RefCounted

# ═══════════════════════════════════════════════════════════
#  ATL 运行时。把一棵 ATL 语句树变成逐帧推进的状态机。
#
#  为什么自己跑 update() 而不是用 Tween：
#    ATL 不是"一次性补间"，它是**持续状态机** —— repeat 可以无限循环，
#    pause 是"停住但保持当前值"，parallel 的每条分支各有各的进度。
#    这些用 Tween 拼不出来：无限循环的 Tween 要么每轮重建（当前进度
#    变得不可查询），要么在回调里递归（栈会越滚越深）。
#
#  和节点的关系：
#    只改包装层的 position / scale / rotation / modulate.a。
#    内容尺寸与原点偏移都从节点自己身上取，所以 L2D 那种"已经自己
#    居中过"的内容不会被二次偏移 —— 默认的 xycenter 算出来就是原地不动。
#
#  属性语义（对齐 Ren'Py 的 transform properties）：
#    pos / xpos / ypos          整数=像素，浮点=容器比例
#    anchor / xanchor / yanchor 整数=像素，浮点=内容比例
#    xycenter / xcenter / ycenter  同上，另外把锚点定在 0.5
#    align / xalign / yalign    只收 0..1 浮点，pos 与 anchor 同时设
#    offset / xoffset / yoffset 只收像素
#    zoom / xzoom / yzoom / rotate / alpha / xflip / yflip
#
#  另外两种节点由编译器展开后写进来：
#    use    内联块里引用的 transform。它必须**自己一帧**串行跑 ——
#           摊平进父块的话，它自带的 repeat 会回到父块开头而不是自己那段
#    wait   块尾声明，不占时间轴。播放器用 wait_time() 读时长，
#           在 show 之后停一拍
#
#  结算（finish）：
#    换动画之前、以及剧本里的 `show <tag> at end`，都会把当前动画直接
#    推到最终态。有限块跑完，无限循环只跑一轮 —— 后者停在循环每次
#    回到的那个点，而不是"刚开始播"的样子
# ═══════════════════════════════════════════════════════════

## 结算（finish）时最多推进多少步。正常块几步就到底了；撞上这个数
## 只可能是块结构出了问题 —— 与其卡死，不如停在当前状态并报一句
const SETTLE_GUARD := 1000

## 没写 at 也没有内联块时的默认动画：把内容放到舞台中心。
##
## 用函数返回而不是常量：Dictionary 是引用类型，常量被多个实例共享，
## 万一谁改了它，下一次 show 的默认值就跟着变了
static func default_blocks() -> Array:
	return [{
		"op": "interp",
		"easing": "linear",
		"duration": "0",
		"props": {"xycenter": ["0.5", "0.5"]},
	}]

## 从一棵 ATL 块里取 wait 声明的时长（秒）。没有就返回 0。
##
## 时长由编译器算好写进那条语句 —— 它展开完所有 transform 引用之后才
## 知道整块有多长，运行时不可能比它算得准。这里只负责把结果读出来
static func wait_time(blocks: Array) -> float:
	for stmt in blocks:
		if not (stmt is Dictionary):
			continue
		if String(stmt.get("op", "")) != "wait":
			continue
		return float(String(stmt.get("duration", "0")))
	return 0.0

## 目标节点（舞台的包装层，或任意 CanvasItem）
var _node: Node = null
## 舞台容器尺寸。比例型数值（浮点）按它换算
var _container := Vector2(2560, 1440)

## 烘焙纹理相对逻辑尺寸的放大倍数，逐轴独立。1:1 表示纹理与逻辑尺寸相同。
##
## 舞台为了让 L2D 的几何边缘在放大时不那么硬，会把内容烘焙到一张更大的
## 纹理里（角色定义的 canvas 参数，见 stage 的 alpha_group_rt_size）。
## 两个轴各算各的：声明尺寸的纵横比不必和显示尺寸一致，模型在纹理里
## 被非均匀拉伸，摆回去时按同一比例缩回，净效果仍然是不变形。
##
## 本类对外的所有数值都是**逻辑尺寸**，所以三处要换算：
##   读节点 —— 尺寸与原点偏移除以它（_content_size / _origin_offset）
##   写节点 —— 缩放除以它（_apply_state）
##   反读   —— 缩放乘回来（_read_state）
## 位置公式本身不用动：锚点补偿用的是逻辑缩放，正好和写节点那一步抵消
var _render_scale := Vector2.ONE

## 根帧
var _root: Dictionary = {}

## 逻辑状态。位置与锚点分开存，是因为 xycenter 这类属性会同时改两者
var _state: Dictionary = {}

## 是否还在推进
var _running := false

## 上一次应用时的内容尺寸。播完之后如果尺寸才确定下来（L2D 纹理、视频流），
## 靠它发现"该重新贴一次了"
var _last_size := Vector2.ZERO

## 上一次 _resolve_props() 改动到的状态键。并行分支靠它知道"这次插值只该写回
## 哪几个键"—— 否则每条分支都用自己那份完整快照覆盖，会把别的分支的结果抹掉
var _changed_keys: Array = []

## 结算模式：插值与停顿一律立即完成，不看 delta。
##
## finish() 期间置位。用它而不是"传一个巨大的 delta"，是因为 repeat 会
## 在块尾回到块首重新计时 —— 一次性的大 delta 只能推进一轮，多轮推不完
var _settling := false

## 结算时遇到无限 repeat 只跑一轮。没有这一条，finish() 会一直在
## 循环里转到 SETTLE_GUARD 才被拦住
var _settle_single_loop := false

###########################################################
#  对外接口
###########################################################

## 启动。blocks 为空时用 default_blocks()。
##
## container 传舞台尺寸（比例换算的基准）。传零向量表示"沿用当前值"。
## render_scale 是节点纹理相对逻辑尺寸的放大倍数：烘焙层传它声明的
## 分辨率比，普通内容用默认的 1:1
func start(node: Node, blocks: Array, container: Vector2 = Vector2.ZERO,
		render_scale: Vector2 = Vector2.ONE) -> void:
	if node == null or not is_instance_valid(node):
		return

	_node = node
	if container.x > 0.0 and container.y > 0.0:
		_container = container
	# 防御零：除零会让整条链的数值变成 inf，症状是模型突然消失
	_render_scale = Vector2(maxf(render_scale.x, 0.001), maxf(render_scale.y, 0.001))

	_state = _read_state(node)
	_root = _make_frame(blocks if not blocks.is_empty() else default_blocks())
	_running = true

	# 立刻把第 0 帧算出来。瞬时语句（纯属性、linear 0）在这一步就生效，
	# 调用方紧接着读到的节点状态才是这一句真正的起点 ——
	# 否则要等下一次 _process，中间那一帧的位置还是"内容刚建好、还没摆"。
	# 历史条目记录的"这一句开始时舞台的样子"正好取自那一刻
	update(0.0)

## 推进一帧。返回是否仍在运行 —— false 表示这套动画已经播完
func update(delta: float) -> bool:
	if _node == null or not is_instance_valid(_node):
		_running = false
		return false

	# 已经播完也要看一眼：内容尺寸可能在播完之后才确定，
	# 那样最终位置会停在"零尺寸"那次算出来的值上。
	# 这里只在尺寸真的变了时才重贴，平时没有开销
	if not _running:
		var idle_size := _content_size()
		if idle_size != _last_size:
			_last_size = idle_size
			_apply_state()
		return false

	_last_size = _content_size()

	if _step(_root, delta):
		return true

	_running = false
	return false

## 是否还在推进
func is_running() -> bool:
	return _running

## 立刻把动画结算到最终态，并停止推进。
##
## 两个调用方：换动画之前（玩家点得太快时上一段还没播完，直接换会让新动画
## 从半路的位置起跳）、以及剧本里的 `show <tag> at end`。
##
## "最终态"的定义：
##   有限块（含 repeat N）  忽略时间把整块跑完，停在终点
##   无参 repeat           只跑一轮，停在循环每次回到的那个点
##
## 已经播完的动画直接返回：节点上本来就是最终态，再算一遍没有意义。
## 注意这里不重置 _state 的来源 —— 结算完再 start() 一条新动画时，
## 新的 _read_state() 读到的正是这份终点，位置因此是连续的
func finish() -> void:
	if not _running:
		return

	if _node == null or not is_instance_valid(_node):
		_running = false
		return

	_settling = true
	_settle_single_loop = _has_infinite_repeat(_root.get("stmts", []))

	var guard := 0
	while _step(_root, 0.0):
		guard += 1
		if guard > SETTLE_GUARD:
			push_warning("ATL 结算时语句没有收敛，停在当前状态")
			break

	_settling = false
	_settle_single_loop = false
	_running = false
	_apply_state()

###########################################################
#  状态读写
###########################################################

## 从节点当前的实际状态读一份初值。
##
## 锚点初值给 0：这是"内容左上角对齐 pos"的约定。之后 xycenter 之类的
## 属性会覆盖它，而没写位置属性的动画不会凭空把内容挪走。
##
## 读位置时要把缩放旋转算进去，与 _apply_state() 用同一条反解：
## 节点原点不是内容左上角，缩放之后两者就分家了。少了这一步，
## 从一个 zoom 2 的最终态接着播新动画时，位置会跳一下
func _read_state(node: Node) -> Dictionary:
	var pos := Vector2.ZERO
	var scale_v := Vector2.ONE
	var angle := 0.0
	var alpha := 1.0

	if node is Node2D:
		var n2 := node as Node2D
		pos = n2.position
		scale_v = n2.scale
		angle = rad_to_deg(n2.rotation)
	elif node is Control:
		var c := node as Control
		pos = c.position
		scale_v = c.scale
		angle = rad_to_deg(c.rotation)

	if node is CanvasItem:
		alpha = (node as CanvasItem).modulate.a

	var origin := _origin_offset(node)
	# 节点上的 scale 是"实际纹理缩放"，换回逻辑缩放才是状态要存的值
	var logical_scale := scale_v * _render_scale
	var placed := (origin * logical_scale).rotated(deg_to_rad(angle))

	return {
		"xpos": pos.x + placed.x,
		"ypos": pos.y + placed.y,
		"xanchor": 0.0,
		"yanchor": 0.0,
		"xoffset": 0.0,
		"yoffset": 0.0,
		"xzoom": logical_scale.x,
		"yzoom": logical_scale.y,
		"rotate": angle,
		"alpha": alpha,
		"xflip": false,
		"yflip": false,
	}

## 内容左上角相对节点原点的偏移（逻辑尺寸）。
##
## Sprite2D 用局部矩形：centered 时它是 (-w/2, -h/2)；
## Control 的 position 就是左上角，所以偏移为零。
## 矩形是纹理坐标，超采样时比逻辑尺寸大，所以要除回去
func _origin_offset(node: Node) -> Vector2:
	if node is Sprite2D:
		return (node as Sprite2D).get_rect().position / _render_scale
	return Vector2.ZERO

## 内容尺寸（逻辑尺寸）。每次应用都重取 —— L2D 的纹理要加载完才有尺寸，
## 缓存在状态里会一直是个零矩形。
##
## 烘焙层的纹理比逻辑尺寸大，这里除回去 —— 锚点与比例换算都按逻辑尺寸算，
## 混进纹理尺寸的话 xycenter 会偏出半个放大倍数
func _content_size() -> Vector2:
	if _node == null or not is_instance_valid(_node):
		return Vector2.ZERO

	if _node is Sprite2D:
		return (_node as Sprite2D).get_rect().size / _render_scale
	if _node is Control:
		return (_node as Control).size / _render_scale
	return Vector2.ZERO

## 把逻辑状态写到节点上
func _apply_state() -> void:
	if _node == null or not is_instance_valid(_node):
		return

	var origin := _origin_offset(_node)

	var flip_x := -1.0 if bool(_state["xflip"]) else 1.0
	var flip_y := -1.0 if bool(_state["yflip"]) else 1.0
	var scale_v := Vector2(float(_state["xzoom"]) * flip_x,
		float(_state["yzoom"]) * flip_y)
	var angle := deg_to_rad(float(_state["rotate"]))

	# 锚点在节点局部坐标里的位置。
	#
	# 锚点本身已经是**像素**：_resolve_props() 把比例换算过了，这里不能
	# 再乘一次 —— 早期版本那样做，位置会整整偏出一个内容宽度。
	# origin 是内容左上角相对节点原点的偏移，两者相加才是"内容上的那个点"
	var local_anchor := Vector2(
		origin.x + float(_state["xanchor"]),
		origin.y + float(_state["yanchor"]))

	# 节点原点必须退到"锚点经过缩放旋转之后仍落在 (xpos, ypos)"的地方。
	#
	# Godot 的变换是 position + R * S * local —— 缩放和旋转都绕节点原点
	# 进行，所以锚点会被一起推走。反解就是下面这一行：把锚点先按缩放
	# 拉伸、再按角度旋转，然后从目标位置里减掉。
	#
	# 少了这个缩放因子，zoom 2 + xycenter 就会整体偏右下一个半宽半高：
	# 锚点在缩放前摆对了，缩放却把它推到了别处
	var placed := (local_anchor * scale_v).rotated(angle)

	# offset 是"最终位置上的平移"，不参与缩放旋转，所以加在最外面
	var pos := Vector2(
		float(_state["xpos"]) + float(_state["xoffset"]),
		float(_state["ypos"]) + float(_state["yoffset"])) - placed

	# 烘焙层的纹理是放大过的，实际缩放要除回去才能显示成逻辑尺寸。
	# 位置不用额外处理：上面 placed 用的是逻辑缩放，和这里正好抵消
	var actual_scale := scale_v / _render_scale

	if _node is Node2D:
		var n2 := _node as Node2D
		n2.position = pos
		n2.scale = actual_scale
		n2.rotation = angle
	elif _node is Control:
		var c := _node as Control
		c.position = pos
		c.scale = actual_scale
		c.rotation = angle

	if _node is CanvasItem:
		var ci := _node as CanvasItem
		var m := ci.modulate
		m.a = float(_state["alpha"])
		ci.modulate = m

###########################################################
#  执行
###########################################################

## 造一个执行帧。
##
## duration 用 -1 表示"当前没有在计时的语句" —— 用 0 当哨兵不行，
## 因为 linear 0 是合法的瞬时插值
func _make_frame(stmts: Array) -> Dictionary:
	return {
		"stmts": stmts,
		"cursor": 0,
		"elapsed": 0.0,
		"duration": -1.0,
		"easing": "linear",
		"from": {},
		"to": {},
		"children": [],
		"keys": [],
		"repeat_left": 0,
		"repeat_set": false,
		"sub": null,
	}

## 推进一帧。返回是否还在运行
func _step(frame: Dictionary, delta: float) -> bool:
	# ── 串行子块（内联块里引用的 transform）──
	# 子块跑完才轮到父块的下一条。它必须是自己一帧，不能把语句并进来：
	# 被引用的块可能带 repeat，并进来之后 repeat 会回到父块的开头
	if frame.get("sub") != null:
		if _step(frame["sub"], delta):
			return true
		frame["sub"] = null
		frame["cursor"] = int(frame["cursor"]) + 1

	# ── 并行分支 ──
	elif not frame["children"].is_empty():
		var alive: Array = []
		for child in frame["children"]:
			if _step(child, delta):
				alive.append(child)
		frame["children"] = alive
		if not alive.is_empty():
			return true
		frame["cursor"] = int(frame["cursor"]) + 1

	# ── 正在插值 / 停顿 ──
	elif float(frame["duration"]) >= 0.0:
		var duration := float(frame["duration"])
		if _settling:
			# 结算：不看 delta，插值一步到位
			frame["elapsed"] = duration
		else:
			frame["elapsed"] = float(frame["elapsed"]) + delta
		var t := 1.0 if duration <= 0.0 else clampf(float(frame["elapsed"]) / duration, 0.0, 1.0)

		# 只写回这条语句声明过的键。并行分支各管几个属性，
		# 整体覆盖的话后跑的分支会把先跑的结果抹掉
		var lerped := _lerp_state(frame["from"], frame["to"],
			_ease(t, String(frame["easing"])))
		for key in frame["keys"]:
			_state[key] = lerped[key]
		_apply_state()

		if t < 1.0:
			return true

		frame["duration"] = -1.0
		frame["cursor"] = int(frame["cursor"]) + 1

	return _run_next(frame)

## 从当前游标开始执行语句，直到需要等待（插值 / 停顿 / 并行）或整块结束。
##
## 外层 while 是为 repeat 准备的：回到块头之后**不能递归** ——
## 一个只有 repeat 的空块会让递归栈直接爆掉。所以块尾用 continue 回到
## 外层循环，并加一个上限兜底：一帧里跑过一千条还没遇到等待点，
## 说明这个块永远不会停下来，直接判定为结束
func _run_next(frame: Dictionary) -> bool:
	var stmts: Array = frame["stmts"]
	var guard := 0

	while true:
		guard += 1
		if guard > 1000:
			return false

		while int(frame["cursor"]) < stmts.size():
			var stmt = stmts[int(frame["cursor"])]
			if not (stmt is Dictionary):
				frame["cursor"] = int(frame["cursor"]) + 1
				continue

			var kind := String(stmt.get("op", ""))

			if kind == "interp":
				var to := _resolve_props(stmt.get("props", {}))
				frame["from"] = _state.duplicate()
				frame["to"] = to
				frame["keys"] = _changed_keys.duplicate()
				frame["duration"] = float(String(stmt.get("duration", "0")))
				frame["easing"] = String(stmt.get("easing", "linear"))
				frame["elapsed"] = 0.0

				# 瞬时插值（linear 0）没有等待的必要，直接落到目标值，
				# 否则要白白多跑一帧
				if float(frame["duration"]) <= 0.0:
					for key in frame["keys"]:
						_state[key] = to[key]
					_apply_state()
					frame["duration"] = -1.0
					frame["cursor"] = int(frame["cursor"]) + 1
					continue
				return true

			if kind == "pause":
				frame["from"] = _state.duplicate()
				frame["to"] = _state.duplicate()
				frame["keys"] = []
				frame["duration"] = float(String(stmt.get("duration", "0")))
				frame["easing"] = "linear"
				frame["elapsed"] = 0.0
				if float(frame["duration"]) <= 0.0:
					frame["duration"] = -1.0
					frame["cursor"] = int(frame["cursor"]) + 1
					continue
				return true

			if kind == "parallel":
				# 连续的 parallel 语句属于同一组：它们的块同时跑，
				# 全部结束之后才轮到后面的语句
				var children: Array = []
				while int(frame["cursor"]) < stmts.size():
					var next = stmts[int(frame["cursor"])]
					if not (next is Dictionary) or String(next.get("op", "")) != "parallel":
						break
					children.append(_make_frame(next.get("block", [])))
					frame["cursor"] = int(frame["cursor"]) + 1

				if children.is_empty():
					continue
				frame["children"] = children
				return true

			if kind == "use":
				# 内联块里引用的 transform：单独开一帧串行跑。
				# 语句已经由编译器展开进 block 里，这里没有名字可查
				var sub_block = stmt.get("block", [])
				frame["sub"] = _make_frame(sub_block if sub_block is Array else [])
				return true

			if kind == "repeat":
				# 只在第一次走到时读次数。repeat 之后 cursor 会回到 0，
				# 每次回来都重设一遍的话就永远停不下来了
				if not bool(frame["repeat_set"]):
					frame["repeat_set"] = true
					var count := String(stmt.get("count", ""))
					frame["repeat_left"] = -1 if count.is_empty() else maxi(1, int(float(count)))
				frame["cursor"] = int(frame["cursor"]) + 1
				continue

			# wait 是声明式的：它不占时间轴，只是给编译器/播放器读的时长。
			# 推进到这里直接跳过。其余几种（理论上 compiler 已经挡住）
			# 也走这条兜底，免得将来加新节点时它们静默卡住整块
			frame["cursor"] = int(frame["cursor"]) + 1

		# ── 块尾：处理 repeat ──
		# repeat N 的语义是"整块最多执行 N 次"，所以首次执行也算一次：
		# 每回到块尾就把剩余次数减一，减到零就结束
		var left := int(frame["repeat_left"])
		if left != 0:
			# 结算无限循环时只跑一轮。跑回到块尾，当前位置就是"循环的起点"，
			# 再转下去永远停不下来
			if _settle_single_loop and left < 0:
				return false
			if left > 0:
				left -= 1
				frame["repeat_left"] = left
				if left <= 0:
					return false
			frame["cursor"] = 0
			continue

		return false

	# while true 之后不可达。写在这里只为满足"所有路径都有返回值"
	# 这条编译要求 —— 少了它，整个脚本都加载不了
	return false

## 块里有没有无参 repeat（含 parallel 分支与 use 子块）。
##
## 有的话这块永远跑不完，结算只能停在"跑完一轮"的位置；
## 编译器也是用同一个判断拒绝"无限 repeat + wait"的组合
func _has_infinite_repeat(block: Variant) -> bool:
	if not (block is Array):
		return false

	for stmt in block:
		if not (stmt is Dictionary):
			continue

		var kind := String(stmt.get("op", ""))
		if kind == "repeat" and String(stmt.get("count", "")).is_empty():
			return true
		if kind == "parallel" and _has_infinite_repeat(stmt.get("block", [])):
			return true
		if kind == "use" and _has_infinite_repeat(stmt.get("block", [])):
			return true

	return false

###########################################################
#  属性求值
###########################################################

## 把一个 interp 语句的属性表解析成"目标状态"。
##
## 以当前状态为底再覆盖提到的属性 —— 没写到的属性保持不动，
## 这正是 ATL 的累积语义（Ren'Py 的 Transform 也是这么工作的）
func _resolve_props(props: Dictionary) -> Dictionary:
	var target := _state.duplicate()
	var size := _content_size()

	for key in props:
		var values: Array = props[key]
		if values.is_empty():
			continue

		match String(key):
			"xpos":
				target["xpos"] = _resolve_num(values[0], _container.x)
			"ypos":
				target["ypos"] = _resolve_num(values[0], _container.y)
			"xanchor":
				target["xanchor"] = _resolve_num(values[0], size.x)
			"yanchor":
				target["yanchor"] = _resolve_num(values[0], size.y)
			"xoffset":
				target["xoffset"] = float(String(values[0]))
			"yoffset":
				target["yoffset"] = float(String(values[0]))
			"pos":
				target["xpos"] = _resolve_num(values[0], _container.x)
				target["ypos"] = _resolve_num(values[1], _container.y)
			"anchor":
				target["xanchor"] = _resolve_num(values[0], size.x)
				target["yanchor"] = _resolve_num(values[1], size.y)
			"offset":
				target["xoffset"] = float(String(values[0]))
				target["yoffset"] = float(String(values[1]))
			"xycenter":
				target["xpos"] = _resolve_num(values[0], _container.x)
				target["ypos"] = _resolve_num(values[1], _container.y)
				target["xanchor"] = size.x * 0.5
				target["yanchor"] = size.y * 0.5
			"xcenter":
				target["xpos"] = _resolve_num(values[0], _container.x)
				target["xanchor"] = size.x * 0.5
			"ycenter":
				target["ypos"] = _resolve_num(values[0], _container.y)
				target["yanchor"] = size.y * 0.5
			"align":
				target["xpos"] = float(String(values[0])) * _container.x
				target["xanchor"] = float(String(values[0])) * size.x
				target["ypos"] = float(String(values[1])) * _container.y
				target["yanchor"] = float(String(values[1])) * size.y
			"xalign":
				target["xpos"] = float(String(values[0])) * _container.x
				target["xanchor"] = float(String(values[0])) * size.x
			"yalign":
				target["ypos"] = float(String(values[0])) * _container.y
				target["yanchor"] = float(String(values[0])) * size.y
			"zoom":
				var z := float(String(values[0]))
				target["xzoom"] = z
				target["yzoom"] = z
			"xzoom":
				target["xzoom"] = float(String(values[0]))
			"yzoom":
				target["yzoom"] = float(String(values[0]))
			"rotate":
				target["rotate"] = float(String(values[0]))
			"alpha":
				target["alpha"] = clampf(float(String(values[0])), 0.0, 1.0)
			"xflip":
				target["xflip"] = float(String(values[0])) != 0.0
			"yflip":
				target["yflip"] = float(String(values[0])) != 0.0

	# 记录这次真正改动到的键。并行分支靠它只写回自己管的那几个属性，
	# 否则每条分支都用完整快照覆盖，会互相抹掉
	_changed_keys = []
	for key in target:
		if target[key] != _state.get(key):
			_changed_keys.append(key)

	return target

## 解析一个数值：带小数点的是比例，不带的是像素。
##
## 这是 Ren'Py 的 position 类型：`xpos 0.5` 是容器的一半，`xpos 500` 是 500 像素。
## 注意 `xanchor 1` 因此是 1 像素而不是 100% —— 要比例就写 `1.0`
static func _resolve_num(value: Variant, span: float) -> float:
	var text := String(value)
	var number := float(text)
	if text.contains("."):
		return number * span
	return number

## 在两份状态之间插值
func _lerp_state(from: Dictionary, to: Dictionary, t: float) -> Dictionary:
	var out := {}
	for key in to:
		var b: Variant = to[key]
		var a: Variant = from.get(key, b)

		if b is bool:
			out[key] = b if t >= 1.0 else a
		elif b is float or b is int:
			out[key] = lerpf(float(a), float(b), t)
		else:
			out[key] = b
	return out

## 缓动。四条曲线与 Ren'Py 的 warpers 对齐：
##   linear  t
##   ease    0.5 - 0.5*cos(pi t)      （两头慢，中间快）
##   easein  1 - cos(t*pi/2)           （起步慢）
##   easeout sin(t*pi/2)               （收尾慢）
static func _ease(t: float, kind: String) -> float:
	match kind:
		"ease":
			return 0.5 - 0.5 * cos(PI * t)
		"easein":
			return 1.0 - cos(t * PI * 0.5)
		"easeout":
			return sin(t * PI * 0.5)
	return t

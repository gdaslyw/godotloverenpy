class_name VNTransition
extends Node

# ═══════════════════════════════════════════════════════════
#  界面转场。对应 Ren'Py 的 Dissolve / Fade 与 enter / exit / intra_transition。
#
#  淡入淡出只改 modulate.a：新画面从透明补到不透明，旧画面保持不透明直到
#  转场结束 —— 合成结果等同交叉溶解，不需要抓帧回读。黑场走 CanvasLayer(400)
#  上的全屏遮罩。
#
#  子节点各自独立绘制的内容（几百个网格的 L2D）到不了这里：VNStage 会先把它
#  烘焙进一张纹理再交过来（见 stage.gd 的 needs_alpha_group），到这一步屏幕上
#  的可调对象已经是一个整体。写入集中在 set_alpha()，全项目只此一处
#
#  一个会话可以有多个通道（内容页 + 侧边栏同时淡入），共用一个输入守卫；
#  转场中一次抬起跳过全部，其余输入由守卫吞掉。
# ═══════════════════════════════════════════════════════════

## 遮罩与守卫所在的层，压在 OverlayLayer(300) 之上
const LAYER := 400

var _layer: CanvasLayer
var _fade: ColorRect
var _guard: Control

## 当前会话编号。并发会话里旧协程靠它判断自己是否已经过时
var _session := 0
## 进行中的通道：{ "tween": Tween }
var _channels: Array[Dictionary] = []
var _active := false
var _skip := false
var _skippable := true

###########################################################
#  生命周期
###########################################################

func _ready() -> void:
	_layer = CanvasLayer.new()
	_layer.name = "TransitionLayer"
	_layer.layer = LAYER
	add_child(_layer)

	_fade = ColorRect.new()
	_fade.name = "Fade"
	_fade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_fade.color = Color(0.0, 0.0, 0.0, 1.0)
	_fade.modulate.a = 0.0
	_fade.visible = false
	_layer.add_child(_fade)
	_fade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	_guard = Control.new()
	_guard.name = "Guard"
	_guard.mouse_filter = Control.MOUSE_FILTER_STOP
	_guard.visible = false
	_layer.add_child(_guard)
	_guard.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	set_process_input(false)

###########################################################
#  对外
###########################################################

## 淡入一组节点（从透明到不透明）。nodes 可传单个节点或数组。
func dissolve_in(nodes: Variant, duration: float) -> void:
	await crossfade(nodes, [], duration)

## 淡出一组节点（到透明）。
func dissolve_out(nodes: Variant, duration: float) -> void:
	await crossfade([], nodes, duration)

## 同一会话里一批淡入、另一批淡出，共用守卫与跳过。
func crossfade(to_show: Variant, to_hide: Variant, duration: float) -> void:
	var token := _begin()
	var entries: Array = []
	entries.append_array(_entries(to_show, 1.0))
	entries.append_array(_entries(to_hide, 0.0))
	await _alpha_entries(entries, duration)
	_end(token)

## 黑场：淡到 color → 停留 hold → change() → 淡回。
## change 必须是同步的，它执行完才会开始淡入。
func fade_through(change: Callable, out_time: float, hold_time: float,
		in_time: float, color: Color = Color.BLACK) -> void:
	var token := _begin()
	_fade.color = Color(color.r, color.g, color.b, 1.0)
	_fade.modulate.a = 0.0
	_fade.visible = true

	await _alpha(_fade, 1.0, out_time)
	await _wait(hold_time)
	if change.is_valid():
		change.call()
	await _alpha(_fade, 0.0, in_time)

	_fade.visible = false
	_end(token)

## 从黑场淡入。启动进主菜单时用：先把遮罩拉满，等一帧再执行 change、淡出。
func fade_in(duration: float, change: Callable = Callable(),
		color: Color = Color.BLACK) -> void:
	var token := _begin()
	_fade.color = Color(color.r, color.g, color.b, 1.0)
	_fade.modulate.a = 1.0
	_fade.visible = true

	await get_tree().process_frame
	if change.is_valid():
		change.call()
	await _alpha(_fade, 0.0, duration)

	_fade.visible = false
	_end(token)

## 当前是否有转场在跑。
func is_running() -> bool:
	return _active

## 立即完成当前转场。所有通道直接到终值，等待中的协程在下一帧继续。
func finish() -> void:
	_skip = true
	for channel in _channels:
		var tween: Tween = channel["tween"]
		if tween != null and tween.is_valid():
			tween.kill()
	_channels.clear()

###########################################################
#  内部
###########################################################

## 开启一个会话，返回会话编号。
func _begin() -> int:
	if _active:
		finish()
		_active = false
	_session += 1
	_active = true
	_skip = false
	_skippable = VNSettings.get_current().transition_skippable
	_guard.visible = true
	set_process_input(true)
	return _session

## 结束会话。编号不匹配说明已经有新会话接管，不能再动守卫。
func _end(token: int) -> void:
	if token != _session:
		return
	_active = false
	_skip = false
	_guard.visible = false
	set_process_input(false)

## 把一组节点的透明度补到 target。
func _alpha(nodes: Variant, target: float, duration: float) -> void:
	await _alpha_entries(_entries(nodes, target), duration)

## 补一组通道：每个 entry 是 { "node": CanvasItem, "target": float }。
func _alpha_entries(entries: Array, duration: float) -> void:
	var time := _duration(duration)
	if time <= 0.0 or _skip:
		for entry in entries:
			set_alpha(entry["node"], entry["target"])
		return

	var tween := create_tween()
	tween.set_parallel(true)
	for entry in entries:
		var item := entry["node"] as CanvasItem
		if item == null or not is_instance_valid(item):
			continue
		set_alpha(item, 1.0 - entry["target"])
		tween.tween_property(item, "modulate:a", entry["target"], time)

	var channel := {"tween": tween}
	_channels.append(channel)

	# is_running() 在刚创建时不可靠，用 finished 信号判断真正结束
	var done := {"value": false}
	tween.finished.connect(func() -> void: done["value"] = true)

	while not done["value"]:
		if _skip or not tween.is_valid():
			break
		await get_tree().process_frame

	if channel["tween"] == tween:
		_channels.erase(channel)

	# 跳过或被外部 kill：补上终值，调用方的后续动作不受影响
	if _skip or not tween.is_valid():
		for entry in entries:
			set_alpha(entry["node"], entry["target"])

## 可跳过的等待。黑场的 hold 阶段用。
func _wait(seconds: float) -> void:
	if seconds <= 0.0 or _skip:
		return

	var elapsed := 0.0
	while elapsed < seconds:
		if _skip:
			return
		await get_tree().process_frame
		elapsed += get_process_delta_time()

## 把 duration 解析成实际秒数。总开关关闭时为 0。
func _duration(value: float) -> float:
	if not VNSettings.get_current().transition_enabled:
		return 0.0
	return maxf(0.0, value)

## 统一成数组，调用方可以只传一个节点。
func _node_list(nodes: Variant) -> Array:
	if nodes is Array:
		return nodes
	return [nodes]

## 把节点（单个或数组）展开成通道表。
func _entries(nodes: Variant, target: float) -> Array:
	var out := []
	for node in _node_list(nodes):
		out.append({"node": node, "target": target})
	return out

## 设置一个节点的透明度。节点已释放时静默跳过。
static func set_alpha(node: Variant, value: float) -> void:
	if node is CanvasItem and is_instance_valid(node):
		(node as CanvasItem).modulate.a = value

###########################################################
#  输入
###########################################################

## 转场期间的输入闸门。跳过转场的那一下吞掉；Ctrl 的按下/松开放行，
## 其余一律吞掉 —— 转场中不该打开菜单、存档，也不该推进台词
func _input(event: InputEvent) -> void:
	if not _active:
		return

	# 按住式快进的状态必须让界面收到：转场期间松开 Ctrl 时，
	# 界面要能清掉 _ctrl_held，否则转场结束后它会接着快进。
	# 只留这一路 —— A / Tab 等快捷键的可用性归"界面可见"管，
	# 不在转场层开洞
	if event.is_action(&"vn_skip_ctrl"):
		return

	if _skippable and _is_skip_event(event):
		finish()
	get_viewport().set_input_as_handled()

## 是不是"跳过转场"的输入：左键抬起、推进键抬起；滚轮没有抬起，按一格算。
func _is_skip_event(event: InputEvent) -> bool:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
			return true
		if event.is_action_pressed(&"vn_advance_wheel"):
			return true
	return event.is_action_released(&"vn_advance")

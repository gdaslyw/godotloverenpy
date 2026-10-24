class_name VNPortraitLayered
extends Node2D

# ═══════════════════════════════════════════════════════════
#  层叠式立绘后端。一个角色由若干张 Sprite2D 叠出来，
#  剧本里的属性决定每一组里哪一张可见。
#
#  ── 它和另外两个后端的分工 ──
#    static   一张贴图，文件名就是形态
#    cubism   一个模型，属性查表情表与动作表
#    layered  一个场景，属性查"哪个 Sprite2D 的节点名叫这个词"
#  三者都只实现 VNStage 的那几个可选方法，舞台对它们一视同仁。
#
#  ── 内容约定：content/role/<角色 ID>/portrait.tscn ──
#    Agustina       (Node2D)      场景根。它自己的变换叠加到所有层上，
#                                 可以用来整体微调角色在画布里的位置
#    ├─ base        (Sprite2D)    常驻层：永远按场景里的 visible 显示
#    ├─ outfit      (Node2D)      互斥组：组内同一时刻只显示一张
#    │   ├─ dress   (Sprite2D)    属性名 = 节点名
#    │   └─ uniform (Sprite2D)
#    └─ front       (Sprite2D)    常驻层
#
#    绘制顺序就是场景树顺序（以及各自的 z_index）—— Godot 原生规则，
#    作者在编辑器里怎么摆就是怎么排，本类不做任何重排。
#
#    position / scale / rotation / offset / centered 全部照常生效，
#    组节点的变换也会叠加到子层上。所以"每层图尺寸不同、需要各自偏移"
#    这件事不需要额外的定义表：在场景里把图摆到该在的位置就行。
#
#  ── 默认形态 = 场景里的初始 visible（不用任何元数据）──
#    作者在编辑器里把 dress 留着可见、uniform 关掉，dress 就是默认层：
#      show agustina happy    只改 face 组，outfit 保持 dress
#      show agustina -happy   face 组没有选中项，回落到 neutral
#    这就是 Ren'Py 的 default，只是"默认值"由编辑器里的眼睛决定，
#    而不是脚本里的一个关键字。好处有两条：
#      · 不用记 "_default 后缀" 或 meta 标记这类约定，摆完就能看到效果
#      · 一组里可以有多个同时默认可见的层（发型 + 刘海），
#        比 Ren'Py 的"每组一个 default"更宽松
#
#  ── 属性名 = 节点名，全局唯一 ──
#    剧本写 show agustina happy，不写组名 —— 属性集本来就是扁平的词表，
#    组只用来表达"同组互斥"。同一个词出现在两个组里会让一次 show 改动
#    多个组，那种语义（Ren'Py 是支持的）首版不做，遇到就直接报错。
#
#  ── 为什么必须走 alpha 烘焙（needs_alpha_group）──
#    两个理由，缺一不可：
#      1) 多个 Sprite2D 各自响应 modulate.a 时，重叠区会各混合一次，
#         半透明时会浮出部件轮廓 —— 与 L2D 多网格是同一个问题
#         （见 stage.gd 文件头）。烘焙成一张纹理之后 alpha 才作用于整体
#      2) ATL 的 _content_size() 只认 Sprite2D 与 Control。裸的 Node2D
#         多层节点拿不到尺寸，"没写 at 就居中"会按零尺寸算
#    套上烘焙层之后包装节点正好是 Sprite2D，两个问题一起解决。
#    代价是每个层叠立绘每帧多一张离屏 RT（尺寸见 alpha_group_rect）
#
#  ── 换层默认瞬时，with dissolve 会淡 ──
#    没有 with 时只改 visible，不做任何计时，和 Ren'Py 的默认行为一致。
#    剧本写 `show lia mouth_5 with dissolve(1.0)` 时，本类把这一轮
#    "由隐变显 / 由显变隐"的层报告给舞台（transition_layers），
#    舞台在同一个时长里把它们交叉淡化 —— 没变的层不参与，整张立绘
#    也不会跟着闪一下。黑场转场（with fade）给不出旧画面，仍然瞬时。
# ═══════════════════════════════════════════════════════════

## 角色资源目录。每个角色一个同名子目录
const ROLE_DIR := "res://content/role/"

## 层叠立绘的场景文件名。**固定名字**，不扫描别的 .tscn ——
## "这个角色用哪份场景"必须是一个确定的答案，靠文件名猜迟早猜错
const SCENE_FILE := "portrait.tscn"

## 角色 ID。等于 content/role/ 下的目录名
var character_id := ""

## 场景实例的根。它是本节点的**唯一**子节点：外层本节点负责接口与包围盒，
## 场景根负责"作者摆的位置"，两层各管一件事
var _scene: Node2D = null

## 全部图层，按扫描顺序：{ "node": Sprite2D, "attr": String,
## "group": String, "initial_visible": bool }。
## attr 为空表示常驻层（根下直接挂的 Sprite2D），不属于任何组
var _layers: Array[Dictionary] = []

## 组名 → 该组的层数组。数组顺序就是场景里的子节点顺序
var _groups: Dictionary = {}

## 属性名 → 组名。属性名在这一层必须全局唯一，见文件头
var _attr_group: Dictionary = {}

## 当前每组的选中项：组名 → 属性名。空字典表示没有任何组被属性选中，
## 这时每组都按初始 visible 显示
var _selection: Dictionary = {}

## setup() 里存下、_ready() 里应用。节点入树之前读不到全局变换，
## 而可见性其实不依赖它 —— 仍然推迟到入树，是为了和 cubism 的时序一致：
## 所有后端都是在"场景里第一次真正出现"那一刻才呈现属性
var _pending_attrs: PackedStringArray = PackedStringArray()

## 是否已经就"未知属性"警告过一次。
## 属性变化很频繁，不加这个标志会在整场剧情里反复刷同一条
var _unknown_warned := false

## 本轮属性变化里"由隐变显"与"由显变隐"的层。
## VNStage 在紧跟的 with dissolve 到来时取走它们（transition_layers），
## 交给 VNTransition 做交叉淡化。没有 with 跟随时会被下一轮重排覆盖
var _fade_show: Array[Node] = []
var _fade_hide: Array[Node] = []

###########################################################
#  对外接口（由 VNStage 调用）
###########################################################

## 一个角色的场景路径。预取与实例化共用这一份拼法
static func scene_path(id: String) -> String:
	return ROLE_DIR.path_join(id).path_join(SCENE_FILE)

## 设置角色并加载它的场景。**在节点入树之前**调用。
##
## 返回 false 表示这个角色没有可用的场景，调用方应当丢弃本节点。
## 让 resolve() 返回 null 比返回一个空白节点好：后者会安静地跑到帧末，
## 屏幕上什么都没有，查起来要绕很久（对应 stage.gd 里那条
## "舞台上没有可显示的东西"的警告）
func setup(id: String, attrs: PackedStringArray) -> bool:
	character_id = id
	_pending_attrs = attrs

	var path := scene_path(id)
	if not ResourceLoader.exists(path):
		push_warning("角色 \"%s\" 声明为 layered，但找不到 %s" % [id, path])
		return false

	var packed := load(path) as PackedScene
	if packed == null:
		push_warning("不是可用的场景文件：%s" % path)
		return false

	var instance := packed.instantiate()
	if not (instance is Node2D):
		push_warning("层叠立绘的场景根必须是 Node2D 系：%s（现在是 %s）"
			% [path, instance.get_class()])
		instance.free()
		return false

	_scene = instance as Node2D
	add_child(_scene)
	_disable_input(_scene)
	_scan()

	if _layers.is_empty():
		push_warning("角色 \"%s\" 的 %s 里没有任何 Sprite2D 层，舞台上会是一片空白"
			% [id, SCENE_FILE])

	return true

## 按新的属性集改各层的可见性。**原地更新，不重建节点**。
##
## 永远返回 true：换表情只是改 visible，纹理不用重读、节点不用重造。
## 返回 false 会让 stage 销毁节点重建（那是给"换模型"这种伤筋动骨的
## 变化留的口子，层叠式用不上）
func apply_attrs(attrs: PackedStringArray) -> bool:
	if _scene == null:
		_pending_attrs = attrs
		return true

	_pending_attrs = PackedStringArray()
	_apply(attrs)
	return true

## 需要整体透明度。理由见文件头，两条都不能省
func needs_alpha_group() -> bool:
	return true

## 烘焙纹理要覆盖的本地矩形：**所有层**的包围盒并集，含当前隐藏的层。
##
## 为什么把隐藏层也算进去：换层会改变可见集合，而烘焙纹理在节点入树时
## 一次性分配好、之后不再重算（stage 的 _fit_alpha_texture 只在 _add_entry
## 里调一次）。只算当前可见层的话，换成一张更大的表情图就会被裁掉边缘，
## 而且是在玩家注意不到的地方悄悄坏掉。多出来的空白只是让 RT 大一圈，
## 换来"任何属性组合都不会被裁"。
##
## 逐层把 sprite 的本地矩形四角变换到本节点坐标再取 AABB：旋转与缩放
## 都在这一步吃掉，不需要额外分支
func alpha_group_rect() -> Rect2:
	if _scene == null:
		return Rect2()

	var inv := get_global_transform().affine_inverse()
	var out := Rect2()
	var first := true

	for layer in _layers:
		var sprite: Sprite2D = layer["node"]
		if not is_instance_valid(sprite):
			continue

		var xf := inv * sprite.get_global_transform()
		for corner in _rect_corners(sprite.get_rect()):
			var point: Vector2 = xf * corner
			if first:
				out = Rect2(point, Vector2.ZERO)
				first = false
			else:
				out = out.expand(point)

	return out

## 取走本轮属性变化产生的层变化：{ "show": [...], "hide": [...] }。
##
## 这是 VNStage 的另一个可选契约：原地换外观的后端报告"哪些层要淡入、
## 哪些要淡出"，舞台把它们并进同一条 with 的 crossfade。没实现这个方法
## 的后端（静态图、L2D）换外观时保持原样 —— 前者重建节点走老路，
## 后者本来就是瞬时。
##
## 取走即清空：一次 with 只消费一轮变化，免得下一轮 show 把同一批层
## 再淡一遍
func transition_layers() -> Dictionary:
	var out := {
		"show": _fade_show.duplicate(),
		"hide": _fade_hide.duplicate(),
	}
	_fade_show.clear()
	_fade_hide.clear()
	return out

###########################################################
#  生命周期
###########################################################

## 入树后把 setup 存下的属性应用一次。
##
## 此刻子节点（场景根及其层）的 _ready() 已经跑过 —— Godot 的 _ready 是
## 后序遍历，子先父后。所以这里读到的是场景跑完自己初始化之后的状态，
## 而不是场景脚本还没准备好时的样子
func _ready() -> void:
	if _scene == null:
		# setup() 没被调用，或失败了但调用方没检查返回值。
		# 报错而不是静默空白：屏幕上什么都没有是最难查的故障
		push_error("VNPortraitLayered 没有可显示的场景（角色 \"%s\"）。"
			% character_id + "它应当由 VNStage.resolve() 经 setup() 构造")
		return

	if not _pending_attrs.is_empty():
		_apply(_pending_attrs)
		_pending_attrs = PackedStringArray()

###########################################################
#  扫描
###########################################################

## 把场景树翻译成层表。根下 Sprite2D 是常驻层，根下 Node2D 是互斥组。
##
## 只认一层嵌套：组里再放 Node2D 会报警告并跳过。理由不是省事，而是
## "嵌套组"的语义没有定义 —— 里层组的属性该不该顶掉外层组的选中项？
## 想清楚之前先不做，比做出一个说不清的语义要好
func _scan() -> void:
	for child in _scene.get_children():
		if child is Sprite2D:
			_add_layer(child as Sprite2D, "")
			continue

		if child is Node2D:
			var group_name := String(child.name)
			var count := 0
			for sub in child.get_children():
				if sub is Sprite2D:
					_add_layer(sub as Sprite2D, group_name)
					count += 1
				else:
					push_warning("角色 \"%s\" 的组 \"%s\" 里有不认识的节点 \"%s\"（%s），已忽略"
						% [character_id, group_name, sub.name, sub.get_class()])
			if count == 0:
				push_warning("角色 \"%s\" 的组 \"%s\" 里没有任何 Sprite2D 层"
					% [character_id, group_name]
					+ "（如果它本意是单独一层，那个节点必须是 Sprite2D）")
			continue

		push_warning("角色 \"%s\" 的场景里有不认识的根节点 \"%s\"（%s）："
			% [character_id, child.name, child.get_class()]
			+ "根下只认 Sprite2D（常驻层）与 Node2D（互斥组）")

## 登记一层。group 为空表示常驻层
func _add_layer(sprite: Sprite2D, group: String) -> void:
	var attr := String(sprite.name)

	if sprite.texture == null:
		push_warning("角色 \"%s\" 的层 \"%s\" 没有设置 texture，显示出来是空的"
			% [character_id, attr])

	var entry := {
		"node": sprite,
		"attr": "" if group.is_empty() else attr,
		"group": group,
		"initial_visible": sprite.visible,
	}

	if group.is_empty():
		_layers.append(entry)
		return

	# 属性名全局唯一：show 角色 <词> 只能有一个明确答案。同一个词落在两个
	# 组里，意味着一次 show 会同时改动多个组 —— 那种语义要么是内容写错，
	# 要么需要 Ren'Py 的"一属性多组"支持，两者都不该靠猜
	if _attr_group.has(attr):
		push_error("角色 \"%s\" 的属性名 \"%s\" 重复：组 \"%s\" 与组 \"%s\"。"
			% [character_id, attr, String(_attr_group[attr]), group]
			+ "属性名必须全局唯一，先扫描到的那个生效")
		# 仍然记进层表：这张图照样会被画出来（保持初始 visible），
		# 包围盒必须把它算进去，否则它超出别的层时会被烘焙纹理裁掉
		_layers.append(entry)
		return

	_attr_group[attr] = group
	_layers.append(entry)
	if not _groups.has(group):
		_groups[group] = []
	var row: Array = _groups[group]
	row.append(entry)

###########################################################
#  属性 → 可见性
###########################################################

## 把属性集翻译成"每组选谁"，然后刷新可见性。
##
## 属性集由 VNSession._merge_attrs() 维护：累加、去重、重写移到末尾、
## 减号移除。所以走到这里时只剩"当前形态的全部词"，顺序就是写入顺序。
## 同一组里后写的胜出 —— 和 cubism 的"取最后一个同类属性"是同一条规则，
## 剧本作者不必为不同后端记两套直觉
func _apply(attrs: PackedStringArray) -> void:
	_selection.clear()

	for word in attrs:
		var attr_name := String(word)

		# 负属性在 _merge_attrs() 里已经处理掉了，正常走不到这里。
		# 走到只可能是有人绕过 session 直接调本方法 —— 忽略，
		# 而不是把 "-happy" 当成一个层名去查
		if attr_name.begins_with("-"):
			continue

		if not _attr_group.has(attr_name):
			# 带括号的属性（dress(1.0)）也落进这一支：层名就是节点名，
			# 没有参数可言，如实当未知处理比宽松匹配更早暴露笔误
			_warn_unknown(attr_name)
			continue

		_selection[String(_attr_group[attr_name])] = attr_name

	_refresh_visibility()

## 按 _selection 重排各层可见性。常驻层不在任何组里，绝不会被这里碰到。
##
## 组节点自己的 visible 不归本类管：关掉组节点等于整组停用（本类只动子层
## 的 visible）。组节点的名字也不参与属性匹配，只有层名参与
func _refresh_visibility() -> void:
	# 每次重排都重新记：上一轮的变化没有 with 跟随就已经作废，
	# 留着会在后面某次转场里被重新淡一遍
	_fade_show.clear()
	_fade_hide.clear()

	for group_name in _groups:
		var chosen := String(_selection.get(group_name, ""))
		var row: Array = _groups[group_name]
		for layer in row:
			var sprite: Sprite2D = layer["node"]
			if not is_instance_valid(sprite):
				continue

			var want: bool
			if chosen.is_empty():
				# 这一组没有任何属性被选中：回到作者在场景里摆的形态。
				# 这就是 Ren'Py 的 default 回落，只是默认值是编辑器的 visible
				want = bool(layer["initial_visible"])
			else:
				want = String(layer["attr"]) == chosen

			if sprite.visible == want:
				continue

			if want:
				_fade_show.append(sprite)
				# 上一次淡化理论上已经由舞台复位；这里再补一次，
				# 免得任何一条路径漏掉之后，这一层以 alpha 0 "重新出现"
				sprite.modulate.a = 1.0
			else:
				_fade_hide.append(sprite)

			sprite.visible = want

## 不认识的属性警告一次，并列出全部可用属性。
##
## 只报一次：属性集里会保留同类属性的历史词（见 _merge_attrs 的说明），
## 每次变化都报会把控制台刷满。而"屏幕上少了一张脸"是最难查的故障，
## 不留线索就等于让人去翻场景文件对节点名
func _warn_unknown(attr_name: String) -> void:
	if _unknown_warned:
		return
	_unknown_warned = true

	var known := PackedStringArray()
	for attr in _attr_group:
		known.append("%s(%s)" % [attr, String(_attr_group[attr])])

	# 写成组名的情形单独点一句：从 Dialogic 的 `set 组/层` 过来的人很容易
	# 把组名当属性写。这里只说清"组不是可选项"，比笼统的"没有这一层"省事
	var hint := ""
	if _groups.has(attr_name):
		hint = "（\"%s\" 是组名，剧本里要写组里的属性名）" % attr_name

	var listing := ", ".join(known) if not known.is_empty() else "（没有任何组）"
	push_warning("角色 \"%s\" 没有名为 \"%s\" 的层。可用属性：%s%s"
		% [character_id, attr_name, listing, hint])

###########################################################
#  杂项
###########################################################

## 场景里的 Control 一律不吃输入。
##
## 层叠立绘不该有 Control（层只能是 Sprite2D），但美术资源里有时会顺手
## 塞一个 TextureRect 进来当参考。Control 的 mouse_filter 默认 STOP，
## 铺在舞台上会把点击整个吞掉 —— 和 stage.gd 的 _disable_mouse() 是同一个
## 坑，那个只处理根节点，这里必须覆盖整棵树
func _disable_input(node: Node) -> void:
	if node is Control:
		(node as Control).mouse_filter = Control.MOUSE_FILTER_IGNORE
	for child in node.get_children():
		_disable_input(child)

## 一个矩形的四个角。取 AABB 时逐角变换，旋转才不会漏掉
static func _rect_corners(rect: Rect2) -> Array[Vector2]:
	var x0 := rect.position.x
	var y0 := rect.position.y
	var x1 := rect.position.x + rect.size.x
	var y1 := rect.position.y + rect.size.y
	var out: Array[Vector2] = [
		Vector2(x0, y0),
		Vector2(x1, y0),
		Vector2(x1, y1),
		Vector2(x0, y1),
	]
	return out

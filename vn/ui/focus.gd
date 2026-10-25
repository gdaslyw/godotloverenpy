class_name VNFocus
extends RefCounted

# ═══════════════════════════════════════════════════════════
#  键盘焦点。统一走作用域自动图：
#
#  ── 作用域 ──
#  push_scope() 把一个界面根压栈。方向键/Tab 在该子树里现算可聚焦控件，
#  按矩形几何找最近/边缘。页面不再手写 focus_neighbor_*，布局怎么变
#  都不会失效。
#
#  组合作用域用 push_scope_roots()：选项界面和剧情界面是兄弟节点，
#  可以传 [choice, say] 两个根。tab_only 里的子树（quick menu）只允许
#  Tab 进入；wrap_around 控制方向键到边界是否绕回。
#
#  ── 默认焦点 ──
#  default_first() 只登记首项，不 grab。第一次方向键由 VNFocus.move()
#  把它叫出来。需要"打开即亮"的特殊场合仍可用 focus_first()。
#
#  ── 谁负责打开 focus_mode ──
#  本工具不动 focus_mode。按钮由 VNButton.keyboard_focus 控制，滑块由
#  VNSlider.keyboard_focus 控制。自动图用
#  get_focus_mode_with_override() 只收 FOCUS_ALL；FOCUS_CLICK、
#  FOCUS_ACCESSIBILITY 和递归禁焦的子树都不会进候选。
#
#  ── 关于可见性 ──
#  自动图每次现算，只收 is_visible_in_tree() 且与作用域/裁剪矩形相交
#  的控件。
# ═══════════════════════════════════════════════════════════

## 当前界面的默认焦点。由 default_first() 登记，不立即 grab。
##
## 玩家第一次按方向键时，VNInputMode 才把它叫出来。这样界面打开时
## 不会凭空出现一个键盘高亮，也不会和鼠标悬停同时亮。
static var default_focus: Control = null


## 登记默认首项，但不抢焦点。
##
## 与 focus_first() 的区别：这个只记下“按方向键时该从谁开始”，
## 真正 grab 发生在第一次方向键按下时（VNFocus.move）。
static func default_first(buttons: Array) -> bool:
	default_focus = first(buttons)
	if default_focus != null:
		var scope := current_scope()
		if scope != null:
			_scope_default[scope] = default_focus
	return default_focus != null


###########################################################
#  作用域与自动几何焦点
###########################################################

## 焦点作用域栈。栈顶是当前活动界面根，只有它的子树参与焦点搜索。
##
## 约定：直接挂在 CanvasLayer 下的界面根自己 push_scope；像 Extra 内容页
## 这种挂在 Control 容器里的子页面不 push，直接复用外壳的作用域。
static var _scopes: Array[Control] = []

## 当前逻辑焦点是不是由“鼠标悬停”产生的隐藏焦点。
##
## 和“鼠标点击后留下的隐藏焦点”分开：悬停时按回车应该操作悬停的按钮，
## 点击留下的隐藏焦点则不该被回车再次触发。
static var _mouse_hover_focus := false

## 当前逻辑焦点。和 Viewport 的原生焦点分开：原生焦点只负责把键盘事件
## 送进控件，视觉和导航都以这里为准。
static var _current: Control = null

## 每个 scope 上次的当前焦点，pop 时恢复
static var _saved: Dictionary = {}

## 每个 scope 的根。普通界面只有一根；选项 + 剧情这种组合作用域有两根。
## 键是 _scopes 里的主根，值是实际参与搜索的根数组。
static var _roots_by_scope: Dictionary = {}

## 每个 scope 里只允许 Tab 进入的子树根（quick menu）。
## 方向键从普通区域不会走进这些子树；进入之后方向键只在子树内移动。
static var _tab_only_by_scope: Dictionary = {}

## 每个 scope 登记的初始首项。Tab 从 quick menu 退出、或鼠标移出当前项时，
## 回到这里，而不是留在最后停留的 QM 按钮上。
static var _scope_default: Dictionary = {}

## 这个 scope 的方向键到边界后是否绕回另一端（选项 + QM 用）
static var _wrap_by_scope: Dictionary = {}

## 只有直接挂在 CanvasLayer 下的界面根才需要 push 作用域。
##
## Extra 内容页挂在 ContentSlot（Control）里，复用外壳的作用域；顶部菜单、
## 弹窗、主菜单、剧情各自是 CanvasLayer 的直接子节点，各自一个作用域。
static func push_scope_if_top_level(root: Control) -> void:
	if root == null:
		return
	if root.get_parent() is CanvasLayer:
		push_scope(root)


## 把单个界面根压入作用域栈。只保存/切换作用域，不抢焦点。
static func push_scope(root: Control) -> void:
	push_scope_roots([root], [], false)


## 把一组根压入作用域栈。
##
## 选项界面和剧情界面是兄弟节点，一个 Control 装不下两者；roots 允许传
## [say, choice]。tab_only 里的子树只允许 Tab 进入（quick menu）。
## wrap_around 为真时方向键到边界绕回另一端（选项/QM 保留原来的循环手感）。
static func push_scope_roots(roots: Array, tab_only: Array = [],
		wrap_around := false) -> void:
	var valid_roots := _sanitize_controls(roots)
	if valid_roots.is_empty():
		return

	var primary: Control = valid_roots[0]
	if _scopes.has(primary):
		return

	var top := current_scope()
	if top != null:
		_saved[top] = _current

	# 清掉底层原生焦点：弹层打开时回车不该落到下面那个按钮上。
	# 即使下面那层没有作用域（比如剧情界面的 quick menu），也要清。
	if primary.is_inside_tree():
		var viewport := primary.get_viewport()
		if viewport.gui_get_focus_owner() != null:
			viewport.gui_release_focus()

	_scopes.append(primary)
	_roots_by_scope[primary] = valid_roots
	_tab_only_by_scope[primary] = _sanitize_controls(tab_only)
	_wrap_by_scope[primary] = wrap_around
	_current = null
	_mouse_hover_focus = false
	default_focus = _saved.get(primary, _scope_default.get(primary, null)) as Control
	# 先让底层那些旧的高亮灭掉：作用域已经切到新根
	_notify(primary)


## 弹出作用域并恢复父作用域的当前焦点。
##
## 只移除指定的那一层：如果它上面还压着确认框/菜单，那些层和它们的当前
## 焦点保持不动。只有弹掉栈顶时才恢复父作用域。
static func pop_scope(root: Control) -> void:
	if root == null:
		return
	var index := _scopes.find(root)
	if index < 0:
		return

	var is_top := index == _scopes.size() - 1
	_scopes.remove_at(index)
	if is_instance_valid(root):
		_saved.erase(root)
	_roots_by_scope.erase(root)
	_tab_only_by_scope.erase(root)
	_scope_default.erase(root)
	_wrap_by_scope.erase(root)

	if not is_top:
		return

	_current = null
	_mouse_hover_focus = false
	var parent := current_scope()
	if parent != null:
		_current = _saved.get(parent, null) as Control
		if _current != null:
			default_focus = _current
		else:
			default_focus = _scope_default.get(parent, null) as Control
		if _current != null and is_instance_valid(_current) \
				and _focusable(_current, parent, _scope_rect(parent)):
			# 恢复原生焦点，回车才能直接继续操作刚才那个控件
			_current.grab_focus(false)
		_notify(parent)
	else:
		default_focus = null
		# 没有父作用域时也要让刚刚那层的按钮灭掉
		_notify(root)


## 清洗一组 Control，去掉 null/失效/重复项
static func _sanitize_controls(controls: Array) -> Array[Control]:
	var out: Array[Control] = []
	for node in controls:
		var control := node as Control
		if control == null or not is_instance_valid(control):
			continue
		if not out.has(control):
			out.append(control)
	return out


## 现在有没有活动作用域。顶部宿主失效时会自动向下回退。
static func current_scope() -> Control:
	while not _scopes.is_empty():
		var top: Control = _scopes.back()
		if is_instance_valid(top) and top.is_inside_tree():
			return top
		_scopes.pop_back()
		if is_instance_valid(top):
			_saved.erase(top)
		_roots_by_scope.erase(top)
		_tab_only_by_scope.erase(top)
		_scope_default.erase(top)
		_wrap_by_scope.erase(top)
		_current = null
		_mouse_hover_focus = false
		if not _scopes.is_empty():
			var parent: Control = _scopes.back()
			if is_instance_valid(parent):
				_current = _saved.get(parent, null) as Control
				default_focus = _current if _current != null \
					else _scope_default.get(parent, null) as Control
	return null


## 取作用域实际有效的根。组合作用域里某个根被释放后自动跳过。
static func _roots(scope: Control) -> Array[Control]:
	var out: Array[Control] = []
	var stored: Array = _roots_by_scope.get(scope, [])
	for node in stored:
		var root := node as Control
		if root != null and is_instance_valid(root) and root.is_inside_tree():
			out.append(root)
	if out.is_empty() and scope != null and is_instance_valid(scope) \
			and scope.is_inside_tree():
		out.append(scope)
	return out


## 这个控件在不在当前作用域里（多根作用域任意一根命中即可）
static func is_in_scope(control: Control) -> bool:
	var scope := current_scope()
	if scope == null or control == null:
		return false
	return _in_scope(control, scope)


## 当前有没有作用域
static func has_scope() -> bool:
	return current_scope() != null


## 取当前逻辑焦点；失效/不可见时清空
static func current_focus() -> Control:
	var scope := current_scope()
	if scope == null:
		return null
	if _current != null and not is_instance_valid(_current):
		_current = null
	if _current != null and not _current.is_visible_in_tree():
		_current = null
	if _current != null and not _in_scope(_current, scope):
		_current = null
	return _current


## 这个控件是不是当前焦点
static func is_current(control: Control) -> bool:
	var scope := current_scope()
	return control != null and _current == control and scope != null \
		and _in_scope(control, scope)


## 当前逻辑焦点是不是由鼠标悬停产生
static func is_mouse_hover_focus() -> bool:
	return _mouse_hover_focus and _current != null


## 由原生焦点反向同步逻辑焦点（Tab、鼠标点击等原生路径）。
static func adopt(control: Control) -> void:
	var scope := current_scope()
	if scope == null or control == null:
		return
	if not _in_scope(control, scope):
		return
	if _current == control:
		return
	_current = control
	default_focus = control
	_notify(scope)


## 把 Viewport 当前的原生焦点同步成逻辑焦点。Tab 之后方向键要先走这里。
static func sync_native() -> void:
	var scope := current_scope()
	if scope == null:
		return
	var owner := scope.get_viewport().gui_get_focus_owner()
	if owner == null or not owner.has_focus(true):
		return
	if not _in_scope(owner, scope):
		return
	if not _focusable(owner, scope, _scope_rect(scope)):
		return
	adopt(owner)


## 按方向移动一格。visible 为真时把原生焦点显示出来（键盘模式）。
##
## 当前没有逻辑焦点时只把默认焦点/边缘控件叫出来，不移动。这样第一次
## 按方向键是"出现焦点"，长按的 echo 才继续走。
static func move(side: int, visible: bool) -> bool:
	var scope := current_scope()
	if scope == null:
		return false

	var candidates := _collect(scope)
	if candidates.is_empty():
		return false

	var current := current_focus()
	if current == null or not candidates.has(current):
		# 没有焦点时只在普通区域里选首项：quick menu 是 Tab-only，
		# 方向键不能把它叫出来。
		var initial_allowed := _filter_tab_region(candidates, scope, false)
		if initial_allowed.is_empty():
			return false
		var target := default_focus
		if target == null or not initial_allowed.has(target):
			target = _extreme(initial_allowed, side)
		if target == null:
			return false
		_apply_current(target, scope, visible)
		return true

	var tab_only := _is_in_any(current, _tab_only_roots(scope))
	if tab_only and (side == SIDE_LEFT or side == SIDE_RIGHT):
		# quick menu 的左右保持原地；上下才在菜单内部移动
		return false

	var allowed := _filter_tab_region(candidates, scope, tab_only)
	var next := _nearest(allowed, current, side)
	if next == null and _wrap_by_scope.get(scope, false) \
			and (side == SIDE_TOP or side == SIDE_BOTTOM):
		next = _wrap_target(allowed, side)
	if next == null:
		return false
	_apply_current(next, scope, visible)
	return true


## 按 Tab 顺序移动一格（delta = ±1）。顺序取作用域内的树序。
static func move_ordered(delta: int, visible: bool) -> bool:
	var scope := current_scope()
	if scope == null:
		return false
	var candidates := _collect(scope)
	if candidates.is_empty():
		return false

	var index := -1
	var current := current_focus()
	if current != null:
		index = candidates.find(current)

	if index < 0:
		# 没有当前焦点时优先用页面登记的默认首项，而不是树序第一个。
		# 否则设置页里第一次按 Tab 会先跳到右上角返回键。
		var pending := default_focus
		if pending != null and candidates.has(pending):
			_apply_current(pending, scope, visible)
			return true
		index = 0 if delta > 0 else candidates.size() - 1
	else:
		index = posmod(index + delta, candidates.size())

	_apply_current(candidates[index], scope, visible)
	return true


## 鼠标位置决定逻辑焦点。没有可聚焦控件时清空当前焦点。
##
## hovering 为真表示这次是“移动悬停”，假表示鼠标点击。两者的隐藏焦点
## 在回车语义上不同：悬停焦点可以被回车激活，点击留下的隐藏焦点不行。
static func focus_from_mouse(hovering := true) -> void:
	var scope := current_scope()
	if scope == null:
		return

	var hovered := scope.get_viewport().gui_get_hovered_control()
	var target: Control = null
	var node: Node = hovered
	var scope_rect := _scope_rect(scope)

	while node != null:
		if node is Control:
			var control := node as Control
			if _focusable(control, scope, scope_rect):
				target = control
				break
		node = node.get_parent()

	if target == _current:
		_mouse_hover_focus = target != null and hovering
		return

	_current = target
	_mouse_hover_focus = target != null and hovering
	if target != null:
		default_focus = target
		target.grab_focus(true)
	else:
		_mouse_hover_focus = false
		# 鼠标停在空白：焦点回到页面登记的初始首项，而不是留在
		# 刚才那个 QM 按钮上
		default_focus = _scope_default.get(scope, null) as Control
		# 把原生焦点也放掉，格子那类自绘控件的 focus_exited 才会触发
		if scope.get_viewport().gui_get_focus_owner() != null:
			scope.get_viewport().gui_release_focus()
	_notify(scope)


## 如果当前焦点是这个控件，就清空。鼠标移出时用，视觉能立刻熄灭。
static func clear_if_current(control: Control) -> void:
	if _current != control:
		return
	var scope := current_scope()
	_current = null
	_mouse_hover_focus = false
	if scope != null:
		default_focus = _scope_default.get(scope, null) as Control
	_notify(scope)


## 清空当前焦点（内容页切换、Tab 退出 quick menu 时用）。
## 原生焦点也一并放掉，待用焦点回到该作用域登记的初始首项。
static func clear_current() -> void:
	var scope := current_scope()
	_current = null
	_mouse_hover_focus = false
	if scope != null:
		default_focus = _scope_default.get(scope, null) as Control
		if scope.is_inside_tree():
			if scope.get_viewport().gui_get_focus_owner() != null:
				scope.get_viewport().gui_release_focus()
	_notify(scope)


## 清空当前作用域的默认焦点（内容页切换时用）
static func clear_pending() -> void:
	var scope := current_scope()
	default_focus = null
	if scope != null:
		_scope_default.erase(scope)


###########################################################
#  作用域内部
###########################################################

## 把逻辑焦点设到某个控件。visible 决定原生焦点是否可见。
static func _apply_current(control: Control, scope: Control, visible: bool) -> void:
	_current = control
	if visible:
		_mouse_hover_focus = false
	default_focus = control
	if control != null and control.is_inside_tree():
		control.grab_focus(not visible)
	_notify(scope)


## 通知所有自绘焦点控件重画。按钮/滑块在 _ready() 里加入这个组。
static func _notify(scope: Control) -> void:
	if scope != null and scope.is_inside_tree():
		scope.get_tree().call_group(&"vn_focus_visuals", &"_refresh_focus_visuals")


## 收集作用域内所有可聚焦控件
static func _collect(scope: Control) -> Array[Control]:
	var out: Array[Control] = []
	var scope_rect := _scope_rect(scope)
	for root in _roots(scope):
		_collect_into(root, scope, scope_rect, out)
	return out


## 递归收集。隐藏/禁用/不可见区域的控件直接跳过。
static func _collect_into(node: Node, scope: Control, scope_rect: Rect2,
		out: Array[Control]) -> void:
	for child in node.get_children():
		if child is Control:
			var control := child as Control
			if _focusable(control, scope, scope_rect) and not out.has(control):
				out.append(control)
		_collect_into(child, scope, scope_rect, out)


## 控件是否在启用了 follow_focus 的滚动容器里。
##
## 这类容器里的控件滚出视口后仍然应该参与方向键导航：抓到它时
## ScrollContainer 会自己把它滚回视野。普通裁剪容器里的则要排除，
## 否则焦点会跑到看不见的地方。
static func _follows_scroll(control: Control, scope: Control) -> bool:
	var roots := _roots(scope)
	var node: Node = control.get_parent()
	while node != null:
		if node is ScrollContainer and (node as ScrollContainer).follow_focus:
			return true
		if roots.has(node):
			break
		node = node.get_parent()
	return false


## 这个控件现在能不能进焦点列表
static func _focusable(control: Control, scope: Control,
		scope_rect: Rect2) -> bool:
	if control == null or not is_instance_valid(control):
		return false
	if control.is_queued_for_deletion():
		return false
	if not _in_scope(control, scope):
		return false
	# 用 override 而不是裸 focus_mode：弹层期间 main.gd 会把底层子树的
	# focus_behavior_recursive 设成 DISABLED，这时 get_focus_mode_with_override()
	# 才是 NONE。只认 FOCUS_ALL —— FOCUS_CLICK 只能鼠标点，程序 grab 会报警。
	if control.get_focus_mode_with_override() != Control.FOCUS_ALL:
		return false
	# 滚动条是 Range，某些主题下会默认可聚焦；它们不该进方向键列表
	if control is ScrollBar:
		return false
	if not control.is_visible_in_tree():
		return false
	if control is BaseButton and (control as BaseButton).disabled:
		return false

	var rect := control.get_global_rect()
	if rect.size.x <= 0.0 or rect.size.y <= 0.0:
		return false

	# 滚动跟随容器里的项允许在视口外：抓到它时容器会自己滚过去
	var scroll_follow := _follows_scroll(control, scope)
	if not scroll_follow and not scope_rect.intersects(rect):
		return false
	if scroll_follow:
		return true

	# 普通裁剪容器里滚出可视区的按钮仍然 is_visible_in_tree()，但被
	# clip_contents 裁掉了；逐层检查裁剪矩形，别把屏幕外的项算进来。
	# 组合作用域有两个根，碰到任意一个根就停。
	var roots := _roots(scope)
	var clip: Node = control.get_parent()
	while clip != null and not roots.has(clip):
		if clip is Control and (clip as Control).clip_contents:
			var clip_rect := (clip as Control).get_global_rect()
			if clip_rect.size.x > 0.0 and clip_rect.size.y > 0.0 \
					and not clip_rect.intersects(rect):
				return false
		clip = clip.get_parent()
	return true


## 控件是否属于这个作用域（多根任意一根命中即可）
static func _in_scope(control: Control, scope: Control) -> bool:
	if control == null:
		return false
	for root in _roots(scope):
		if control == root or root.is_ancestor_of(control):
			return true
	return false


## 作用域的可见矩形。多根取并集；根节点尺寸没算出来时退回视口大小。
static func _scope_rect(scope: Control) -> Rect2:
	var rect := Rect2()
	var has_rect := false
	for root in _roots(scope):
		var root_rect := root.get_global_rect()
		if root_rect.size.x <= 0.0 or root_rect.size.y <= 0.0:
			continue
		if not has_rect:
			rect = root_rect
			has_rect = true
		else:
			rect = rect.merge(root_rect)
	if not has_rect and scope != null:
		rect = Rect2(Vector2.ZERO, scope.get_viewport_rect().size)
	return rect


## 当前作用域里只允许 Tab 进入的子树根（quick menu）
static func _tab_only_roots(scope: Control) -> Array[Control]:
	var out: Array[Control] = []
	var stored: Array = _tab_only_by_scope.get(scope, [])
	for node in stored:
		var control := node as Control
		if control != null and is_instance_valid(control):
			out.append(control)
	return out


## 控件是否落在这些根里任意一个下面
static func _is_in_any(control: Control, roots: Array[Control]) -> bool:
	if control == null:
		return false
	for root in roots:
		if root != null and is_instance_valid(root) \
				and (control == root or root.is_ancestor_of(control)):
			return true
	return false


## 按 tab-only 区域筛方向键候选。want_tab 为真只留 quick menu，
## 为假只留普通区域。
static func _filter_tab_region(candidates: Array[Control], scope: Control,
		want_tab: bool) -> Array[Control]:
	var roots := _tab_only_roots(scope)
	var out: Array[Control] = []
	for node in candidates:
		if _is_in_any(node, roots) == want_tab:
			out.append(node)
	return out


## 没有当前焦点时按方向选边缘控件
static func _extreme(candidates: Array[Control], side: int) -> Control:
	var best: Control = null
	var best_value := 0.0
	for node in candidates:
		var control := node as Control
		if control == null:
			continue
		var center := control.get_global_rect().get_center()
		var value := center.x
		match side:
			SIDE_LEFT:
				value = center.x
			SIDE_RIGHT:
				value = -center.x
			SIDE_TOP:
				value = center.y
			SIDE_BOTTOM:
				value = -center.y
		if best == null or value < best_value:
			best = control
			best_value = value
	return best


## 方向键到边界后的绕回目标：下 → 最上，上 → 最下，
## 右 → 最左，左 → 最右。
static func _wrap_target(candidates: Array[Control], side: int) -> Control:
	var best: Control = null
	var best_value := 0.0
	for node in candidates:
		var control := node as Control
		if control == null:
			continue
		var center := control.get_global_rect().get_center()
		var value := center.x
		match side:
			SIDE_LEFT:
				value = -center.x
			SIDE_RIGHT:
				value = center.x
			SIDE_TOP:
				value = -center.y
			SIDE_BOTTOM:
				value = center.y
			_:
				return null
		if best == null or value < best_value:
			best = control
			best_value = value
	return best


## 从当前焦点沿方向找最近的控件。主方向距离 + 2 倍副方向偏移，
## 让同一行/列的目标优先。
static func _nearest(candidates: Array[Control], current: Control,
		side: int) -> Control:
	var from := current.get_global_rect().get_center()
	var best: Control = null
	var best_score := INF

	for node in candidates:
		var control := node as Control
		if control == null or control == current:
			continue
		var center := control.get_global_rect().get_center()
		var dx := center.x - from.x
		var dy := center.y - from.y
		var primary := 0.0
		var secondary := 0.0

		match side:
			SIDE_LEFT:
				if dx >= -1.0:
					continue
				primary = absf(dx)
				secondary = absf(dy)
			SIDE_RIGHT:
				if dx <= 1.0:
					continue
				primary = absf(dx)
				secondary = absf(dy)
			SIDE_TOP:
				if dy >= -1.0:
					continue
				primary = absf(dy)
				secondary = absf(dx)
			SIDE_BOTTOM:
				if dy <= 1.0:
					continue
				primary = absf(dy)
				secondary = absf(dx)
			_:
				continue

		var score := primary + secondary * 2.0
		if score < best_score:
			best_score = score
			best = control

	return best


## 把焦点给数组里第一个可用的控件。
##
## 延到帧末执行：本函数常在 _ready() 或构建函数末尾调用，那一帧布局
## 还没跑完，grab_focus() 的可见性判定会失败（class_control 的文档
## 也建议配合 call_deferred 使用）。
##
## hide_focus 默认为 false：确实需要打开即亮的场合传默认值。界面打开
## 现在走 default_first()（只登记不抢），这里留给明确要立即 grab 的调用。
static func focus_first(buttons: Array, hide_focus := false) -> bool:
	var target := first(buttons)
	if target == null:
		return false
	target.grab_focus.call_deferred(hide_focus)
	return true


## 取第一个"现在就能被焦点选中"的控件。没有则返回 null。
##
## 预热中的页面整棵树不可见，不能作为 grab 目标；这里额外要求可见。
static func first(buttons: Array) -> Control:
	for node in buttons:
		if not is_instance_valid(node) or not (node is Control):
			continue
		var control: Control = node
		if not control.is_inside_tree() or not control.is_visible_in_tree():
			continue
		if control.focus_mode == Control.FOCUS_NONE:
			continue
		if control is BaseButton and (control as BaseButton).disabled:
			continue
		return control
	return null



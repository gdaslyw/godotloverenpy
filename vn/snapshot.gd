extends RefCounted

# ═══════════════════════════════════════════════════════════
#  快照里的纯逻辑：变量与角色属性的变更日志怎么撤销、路径怎么拆。
#
#  ── 为什么它不是一个 class_name ──
#  本文件被 VNPlayer 与 VNSession 在**类级别**引用（preload 常量），
#  内容是纯静态函数，没有实例、没有状态。走 preload 而不是 class_name
#  有两个好处：新文件不必等编辑器把全局类表扫过一遍才能用；也不会和
#  引用它的类形成循环声明。
#
#  ── 那快照本身的形状在哪 ──
#  在 VNSave 的 F_* 常量里 —— 那套键既是存档文件里的键，也是运行时快照
#  的键，只定义一份。本文件只负责"拿到那份数据之后怎么往回退"，不认识
#  具体的字段。
#
#  ── 为什么要 delta 而不是全量 ──
#  历史回跳要回到"那一句的数值"。全量快照 × 250 条会让存档胖几十倍，
#  所以每条历史记的是：**这一句显示之前，被改过的路径在改之前的值**。
#  回跳时从当前状态往回贴，不需要基准点，也不需要理解 += / -=。
#  函数不需要知道它怎么算的，也能撤销它。
#
#  这与 Ren'Py 的 Rollback.stores（rollback.py:281）同构：那边也是
#  (变量名, 旧值)，回滚时整份贴回去（rollback.py:424-434）。
# ═══════════════════════════════════════════════════════════

## 把一份变量变更日志反向应用到变量表上（就地修改 vars）。
##
## 日志的形状是 { 点路径: 旧值 }。值为 null 表示"改之前这个变量还不存在"
## —— 撤销时要把整个路径删掉，而不是写一个 null 进去（变量不存 null，
## 写进去会让 has_var() 与插值都认错）。
##
## 应用顺序由调用方保证：从最新一条往最旧一条。同一个路径被改过多次时，
## 靠后那条记的旧值才是"贴回去该得到的那个值"。
static func apply_vars_delta(vars: Dictionary, delta: Dictionary) -> void:
	for path in delta:
		var old: Variant = delta[path]
		if old == null:
			erase_path(vars, String(path))
		else:
			write_path(vars, String(path), old)

## 把一份角色属性变更日志反向应用（就地修改 roles）。
##
## 键是 "<角色ID>.<属性名>"，值是该属性改之前的字符串。角色属性不会被
## 删除，所以这里没有 erase 分支。
static func apply_roles_delta(roles: Dictionary, delta: Dictionary) -> void:
	for key in delta:
		var text := String(key)
		var dot := text.find(".")
		if dot <= 0 or dot >= text.length() - 1:
			continue

		var role_id := text.substr(0, dot)
		var prop := text.substr(dot + 1)
		var props: Dictionary = roles.get(role_id, {})
		if props.is_empty():
			props = {}
			roles[role_id] = props
		props[prop] = delta[key]

## 按点路径写一个值，中间层缺了就补字典。
##
## 与 VNSession.set_var() 的写入规则一致 —— 那边还兼着运算与通知，
## 这里只负责"把值放到该放的位置"。分开写是因为本文件不能依赖
## VNSession：那会绕回循环引用。
static func write_path(table: Dictionary, path: String, value: Variant) -> void:
	if path.is_empty():
		return

	var segments := path.split(".")
	var node := table
	for i in segments.size() - 1:
		var key := segments[i]
		var child: Variant = node.get(key)
		if not (child is Dictionary):
			child = {}
			node[key] = child
		node = child as Dictionary

	node[segments[segments.size() - 1]] = value

## 按点路径删掉一个值。路径不存在时安静返回 —— 撤销一个"本来就没有"的
## 变量是正常情况，不该报错。
static func erase_path(table: Dictionary, path: String) -> void:
	if path.is_empty():
		return

	var segments := path.split(".")
	var node := table
	for i in segments.size() - 1:
		var child: Variant = node.get(segments[i])
		if not (child is Dictionary):
			return
		node = child as Dictionary

	node.erase(segments[segments.size() - 1])

extends RefCounted

# ═══════════════════════════════════════════════════════════
#  条件表达式求值
#
#  ── 它是什么，不是什么 ──
#  这不是一个通用表达式引擎。它只回答剧本里 if / elif / menu 分支后面
#  那一行 `gold >= 10 and not flag` 是真是假。所以没有四则运算、没有函数
#  调用、没有属性访问 —— 那些真需要时再单独加，每加一样都要连带想清楚
#  优先级和类型提升，不是"顺手多支持一点"的事。
#
#  ── 表达式怎么存 ──
#  编译期由 VNParser 建成一棵小树，VNParser 再 JSON.stringify 成字符串
#  塞进指令参数（.vnbc 的 args 只有字符串）。运行时 JSON.parse_string()
#  还原，然后本文件递归求值。
#
#  存树而不是存后缀式：树在字节码里是能直接读懂的（调试时一眼看得出
#  这一条指令在判什么），而后缀式要拿纸笔算一遍才知道。
#
#  ── 节点形状 ──
#    {"kind": "lit", "type": "i"|"f"|"s"|"b", "value": "10"}
#    {"kind": "var", "path": "gold"}
#    {"kind": "cmp", "op": ">=", "lhs": 节点, "rhs": 节点}
#    {"kind": "and", "lhs": 节点, "rhs": 节点}
#    {"kind": "or",  "lhs": 节点, "rhs": 节点}
#    {"kind": "not", "expr": 节点}
#
#  ── 为什么没有 class_name ──
#  纯静态函数库，没有实例。和 vn/snapshot.gd 同一个理由：不为几个纯函数
#  去占一个全局类名，调用方 preload 即可。
# ═══════════════════════════════════════════════════════════

## 求值一个表达式节点，返回它的值。
##
## 返回类型是 Variant 而不是 bool：整个表达式可能只是一次比较（结果是
## bool），也可能只是一个变量的值。类型判断交给调用方 —— 条件场景用
## test()，它会把结果按真值规则收成 bool。
##
## achievements 只在路径里出现 steam.<id> 时才用到，persistent 只在
## persistent.xxx 时用到。都做成可选参数：expr.gd 也被开发端的自检单独
## 用过，那边没有这些对象。真遇到对应路径而没有对象时按"空值"处理，
## 见 _read_path()
##
## 节点形状不对时返回 null 并报错。这种情况只可能是 .vnbc 损坏或
## 编译器写坏了，运行时的剧本是编译产物，不该出现手工拼的节点。
static func eval(node: Variant, session: VNSession,
		achievements: VNAchievements = null,
		persistent: VNPersistent = null) -> Variant:
	if not (node is Dictionary):
		push_error("条件表达式：节点不是字典：%s" % str(node))
		return null

	var table: Dictionary = node

	match String(table.get("kind", "")):
		"lit":
			return _eval_literal(table)
		"var":
			return _read_path(String(table.get("path", "")), session,
				achievements, persistent)
		"cmp":
			return _eval_compare(String(table.get("op", "")),
				eval(table.get("lhs"), session, achievements, persistent),
				eval(table.get("rhs"), session, achievements, persistent))
		"and":
			# 短路。右侧不成立就不求值 —— 它可能有副作用吗？没有。
			# 但短路能省掉一次字典查找，而且和作者写顺序的直觉一致
			if not truthy(eval(table.get("lhs"), session, achievements, persistent)):
				return false
			return truthy(eval(table.get("rhs"), session, achievements, persistent))
		"or":
			if truthy(eval(table.get("lhs"), session, achievements, persistent)):
				return true
			return truthy(eval(table.get("rhs"), session, achievements, persistent))
		"not":
			return not truthy(eval(table.get("expr"), session, achievements, persistent))

	push_error("条件表达式：认不出的节点类型 \"%s\"" % String(table.get("kind", "")))
	return null

## 求值一个条件，按真值规则收成 bool。if / elif / menu 分支都用它。
static func test(node: Variant, session: VNSession,
		achievements: VNAchievements = null,
		persistent: VNPersistent = null) -> bool:
	return truthy(eval(node, session, achievements, persistent))

## 把任意值按真值规则收成 bool。
##
## 规则对齐 Python（Ren'Py 的条件就是 Python 表达式）：
##   bool    自身
##   int/float  非零为真
##   String  非空为真（"0" 和 "false" 都是**真**，这一点常被写错）
##   null    假
##   其余    假，并报错 —— 变量类型只有四种，出现别的说明数据坏了
static func truthy(value: Variant) -> bool:
	if value is bool:
		return value
	if value is int or value is float:
		return value != 0
	if value is String:
		return not (value as String).is_empty()
	if value == null:
		return false
	push_error("条件表达式：无法判断真值，值的类型是 %s" % type_string(typeof(value)))
	return false

###########################################################
#  内部
###########################################################

## 还原一个字面量节点。type 是 s / i / f / b，与 set / default 的字面量
## 编码完全一样 —— 那两处的值也是"字符串 + 类型标签"，三处共用一套约定
static func _eval_literal(node: Dictionary) -> Variant:
	return VNSession.decode_value(String(node.get("type", "s")),
		String(node.get("value", "")))

## 读一个路径。四种形态，按首段区分：
##   steam.<成就 id>      成就状态，走成就表
##   persistent.<名字>    跨周目变量，走持久化表
##   role.<角色>.<属性>   角色属性，走角色表
##   <名字>(.<名字>)*     普通变量，走变量表
##
## steam 与 persistent **都不经过 session**：它们是玩家级、跨存档的数据，
## 不属于这一局的演出状态。读档回滚舞台和变量，不回滚这两样
##
## 查不到返回 null。编译期已经保证了每个路径都有 default 声明，走到这里
## 还查不到只可能是"旧存档 + 新剧本"（新加的变量不在旧档里）。那种情况下
## 安静地当空值，让分支走 else —— 比在玩家面前报错好
static func _read_path(path: String, session: VNSession,
		achievements: VNAchievements, persistent: VNPersistent) -> Variant:
	if session == null or path.is_empty():
		return null

	var head := VNAchievements.PATH_ROOT + "."
	if path.begins_with(head):
		var id := path.substr(head.length())
		if achievements == null:
			return false
		return achievements.has(id)

	if VNPersistent.is_persistent_path(path):
		if persistent == null:
			return null
		return persistent.get_var(path)

	var segments := path.split(".")
	if segments.size() == 3 and segments[0] == VNSession.ROLE_PATH_ROOT:
		var text := session.character_property(segments[1], segments[2])
		# 角色属性只存字符串，而"没有这个属性"和"属性是空串"在
		# character_property() 的返回值里分不开。空串当 false 处理，
		# 于是 `if role.lili.name` 在没有显示名时是假 —— 这是唯一合理的解释
		return text

	return session.var_value(path)

## 比较两个值。类型不匹配时返回 false 并报错 —— 静默返回 false 会让
## `if gold == "10"` 这种笔误变成"永远不成立"，作者要盯着屏幕猜半天。
##
## 例外是 == / !=：它们对任意类型都有定义（不相等就是不相等），
## 所以类型不同时不报错，直接判 false / true。这与 Python 一致
static func _eval_compare(op: String, lhs: Variant, rhs: Variant) -> bool:
	var equal := _values_equal(lhs, rhs)

	if op == "==":
		return equal
	if op == "!=":
		return not equal

	# 剩下四个只对"有序"的类型有意义
	var both_number := _is_number(lhs) and _is_number(rhs)
	var both_string := lhs is String and rhs is String

	if not both_number and not both_string:
		push_error("条件表达式：\"%s\" 两侧必须是两个数值或两个字符串（%s 与 %s）"
			% [op, type_string(typeof(lhs)), type_string(typeof(rhs))])
		return false

	return _compare_ordered(op, lhs, rhs)

## 按运算符比较两个同类型的有序值。
## 单独拆出来是为了让上面那段"能不能比"的判断和"怎么比"分开 ——
## 混在一起时，读者要同时确认两件事
static func _compare_ordered(op: String, lhs: Variant, rhs: Variant) -> bool:
	match op:
		">":
			return lhs > rhs
		">=":
			return lhs >= rhs
		"<":
			return lhs < rhs
		"<=":
			return lhs <= rhs

	push_error("条件表达式：认不出的比较运算符 \"%s\"" % op)
	return false

## 判断两个值是否相等。
##
## 数值之间跨类型比较（3 == 3.0 为真）—— GDScript 的 == 本身就按值比，
## 这里只需要把"不能比"的情况挡掉
static func _values_equal(lhs: Variant, rhs: Variant) -> bool:
	if _is_number(lhs) and _is_number(rhs):
		return lhs == rhs
	if lhs is String and rhs is String:
		return lhs == rhs
	if lhs is bool and rhs is bool:
		return lhs == rhs
	# 一边是 null：只有两边都是 null 才算相等。null 是"没有这个变量"，
	# 让它等于 0 或空串会把"漏声明"伪装成一个合法值
	if lhs == null or rhs == null:
		return lhs == null and rhs == null
	return false

## 是不是数值类型。int 与 float 可以互相比较，规则同 VNSession._is_number
static func _is_number(value: Variant) -> bool:
	var t := typeof(value)
	return t == TYPE_INT or t == TYPE_FLOAT

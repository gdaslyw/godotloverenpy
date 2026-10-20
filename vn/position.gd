class_name VNPosition
extends RefCounted

# ═══════════════════════════════════════════════════════════
#  位置迁移：把"旧指令流上的一个位置"搬到"新指令流上"。
#
#  ── 谁在用 ──
#    读档     存档里的 cursor 是**存档那个版本**的指令下标，而当前的
#             .vnbc 可能已经重编译过好几次。两边对不上是常态，不是异常
#    热重载   开发期改剧本、重编译之后，把玩家留在原处
#  两个场景的处境完全相同，所以算法只该有一份。
#
#  ── 为什么它在框架层，而不是 vn/dev/ ──
#  读档是玩家端功能，而 vn/dev/ 按约定不进玩家端。这段逻辑留在那边的话，
#  发布版里读档就只能"从 label 开头重放"，而且同一套启发式会以两个速度
#  腐烂成两份。这里不依赖 VNPlayer 也不依赖 VNStory —— 只吃
#  "指令流 + 快照"，谁都能调。
#
#  ── 三级策略 ──
#  指令流会变，但 sid 是跨次编译继承的持久标识（见 VNCompiler._assign_sids：
#  它按内容配对把旧 sid 传给新指令，只有新增或改写的才发新随机值）。
#  所以只要那一句还在，就能把它找回来：
#
#    一级  当前句的 sid 直接命中
#          剧本改了别处，这一句没动 —— 最理想的情况
#    二级  往前找一条"新旧都还在"的锚点，按回溯步数推进
#          这一句被改写或删掉了，用它的上下文把落点估出来
#    三级  退回 label 开头
#          整段都找不到了，退回这一章的起点
#
#  调用栈是独立于这三级的一条线，理由见 resolve()。
#
#  ── 为什么不能直接照搬 cursor ──
#  指令下标在新旧指令流之间没有任何对应关系：剧本开头插一句台词，后面
#  所有下标整体平移一位。照搬的后果不是报错，而是**静默跳到另一句台词**
#  —— 屏幕上看起来一切正常，只是剧情从别处接了下去。这类错最难查，
#  所以宁可退回 label 开头，也不做没有依据的映射。
# ═══════════════════════════════════════════════════════════

## 定位结果的判据：当前句原样命中
const HOW_SID := "sid"
## 定位结果的判据：按锚点回溯
const HOW_ANCHOR := "anchor"
## 定位结果的判据：退回 label 开头
const HOW_LABEL := "label"
## 定位结果的判据：调用栈失效，退回 label 开头
const HOW_STACK := "stack"

## 锚点默认跨度。
##
## 32 是权衡：存档里每个锚点占 8 字节，32 个是 256 字节，可以忽略；
## 而往回 32 条以内几乎一定能碰到一句没被改过的台词 —— 一次改动通常
## 只涉及相邻几句
const ANCHOR_SPAN := 32

###########################################################
#  查找
###########################################################

## 建立"sid → 指令下标"的索引表。
##
## resolve() 内部会建一次并全程复用：调用栈有几帧就要查几次，加上锚点
## 回溯，逐个线性扫描几万条指令会很痛。一次性建表的代价是几十毫秒量级
static func build_sid_index(ops: Array[Dictionary]) -> Dictionary:
	var table := {}
	for i in ops.size():
		var sid := int(ops[i].get("sid", 0))
		if sid != 0:
			table[sid] = i
	return table

## 在一份指令流里按 sid 找**台词**指令的下标，找不到返回 -1。
##
## 只认 say 与 say_literal：两种都是玩家能停在上面的一句。漏掉任何一种，
## 停在那种句子上时一级定位都会失败，而且失败本身不报错，只表现为
## "位置跳了"，很难联想到是这里
static func seek_say(ops: Array[Dictionary], sid: int) -> int:
	if sid == 0:
		return -1
	for i in ops.size():
		if int(ops[i].get("sid", 0)) == sid and is_say(ops[i]):
			return i
	return -1

## 在一份指令流里按 sid 找任意指令的下标，找不到返回 -1。
## 和 seek_say 的区别：这个认所有 op —— 恢复调用栈要找回的是 call
static func find_by_sid(ops: Array[Dictionary], sid: int) -> int:
	if sid == 0:
		return -1
	for i in ops.size():
		if int(ops[i].get("sid", 0)) == sid:
			return i
	return -1

## 这条指令是不是"玩家能停在上面的一句"
static func is_say(op: Dictionary) -> bool:
	var kind := String(op.get("op", ""))
	return kind == "say" or kind == "say_literal"

## 从指令流里切一段锚点。
##
## cursor 是"旧位置"，切出来的是它**往前** span 条的 sid，**不含它自己**
## —— 它自己由调用方单独传（一级定位用它）。
##
## 顺序是由近及远：anchors[0] 是往前第 1 条。回溯时从近处试起，
## 步数少，估出来的落点误差也小
static func anchors_from(ops: Array[Dictionary], cursor: int,
		span: int = ANCHOR_SPAN) -> PackedInt64Array:
	var out := PackedInt64Array()
	var i := cursor - 1
	while i >= 0 and out.size() < span:
		out.append(int(ops[i].get("sid", 0)))
		i -= 1
	return out

###########################################################
#  迁移
###########################################################

## 把一份位置快照搬到新的指令流上。
##
## snapshot 是 capture_position() 的形状：{ cursor, label_name, call_stack, path }。
## sid 是旧位置上那一句的 sid，anchors 是它往前的一段（见 anchors_from）。
## label_start 是"label 名 → 指令下标"的查询函数，缺省时三级退化到 0。
##
## 返回 { cursor, label_name, call_stack, how }，输入里若有 path 会原样带过去。
## how 说明走的是哪一级 —— 调用方据此决定要不要 warning，验收时也靠它判断
static func resolve(snapshot: Dictionary, sid: int, anchors: PackedInt64Array,
		ops: Array[Dictionary], label_start: Callable = Callable()) -> Dictionary:
	var label_name := String(snapshot.get("label_name", ""))

	# 建一次表，调用栈、一级、二级全用它
	var index := build_sid_index(ops)

	# ── 调用栈：逐帧按 sid 找回 call 指令，重算 return_index ──
	#
	# 这一条独立于下面的三级。任何一帧找不到就整条栈作废 ——
	# 半截调用栈比空栈危险得多：它会让 return 回到一个语义上完全不相干的
	# 位置，而且屏幕上看起来一切正常
	var old_stack: Array = snapshot.get("call_stack", [])
	var new_stack: Array = []
	for frame in old_stack:
		if not (frame is Dictionary):
			new_stack.clear()
			break

		var call_index := int(index.get(int((frame as Dictionary).get("sid", 0)), -1))
		if call_index < 0 or String(ops[call_index].get("op", "")) != "call":
			new_stack.clear()
			break

		var moved: Dictionary = (frame as Dictionary).duplicate(true)
		moved["return_index"] = call_index + 1
		new_stack.append(moved)

	if new_stack.size() != old_stack.size():
		# 退回**最外层**那个 label。用内层的话，玩家会落进一个还没有被
		# call 进来的子过程里，后面的 return 直接踩空
		var outer := label_name
		if not old_stack.is_empty() and old_stack[0] is Dictionary:
			outer = String((old_stack[0] as Dictionary).get("label_name", ""))
		return _result(_label_index(label_start, outer), outer, [], HOW_STACK,
			snapshot)

	# ── 一级：当前句原样还在 ──
	if sid != 0 and index.has(sid):
		var at := int(index[sid])
		if is_say(ops[at]):
			return _result(at, label_name, new_stack, HOW_SID, snapshot)

	# ── 二级：往前找锚点，按回溯步数推进 ──
	#
	# 步数的算法：锚点是"旧位置往前第 k 条"，在新流里落在下标 j 上，
	# 那么新位置就是 j + k。前提是这一段里没有增删 —— 有的话落点会偏，
	# 但偏的幅度受锚点距离约束，比退回 label 开头准得多
	for i in anchors.size():
		var anchor_sid := int(anchors[i])
		if anchor_sid == 0 or not index.has(anchor_sid):
			continue
		var cursor := int(index[anchor_sid]) + (i + 1)
		if cursor >= 0 and cursor < ops.size():
			return _result(cursor, label_name, new_stack, HOW_ANCHOR, snapshot)

	# ── 三级：退回 label 开头 ──
	return _result(_label_index(label_start, label_name), label_name, new_stack,
		HOW_LABEL, snapshot)

###########################################################
#  内部
###########################################################

## 拼一份迁移结果。path 从输入快照里带过来 —— 它是"这是哪个剧本包的快照"
## 的身份信息，本函数不判断它对不对，那是调用方的事
static func _result(cursor: int, label_name: String, call_stack: Array,
		how: String, snapshot: Dictionary) -> Dictionary:
	var out := {
		"cursor": cursor,
		"label_name": label_name,
		"call_stack": call_stack,
		"how": how,
	}
	if snapshot.has("path"):
		out["path"] = snapshot["path"]
	return out

## 查一个 label 的起始下标。查不到或没有查询函数时返回 0（即从头开始）
static func _label_index(label_start: Callable, label_name: String) -> int:
	if label_name.is_empty() or not label_start.is_valid():
		return 0
	var found := int(label_start.call(label_name))
	return found if found >= 0 else 0

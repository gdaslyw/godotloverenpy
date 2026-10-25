class_name VNHistory
extends RefCounted

# ═══════════════════════════════════════════════════════════
#  对话历史。框架持有，界面只读 —— 对应 Ren'Py 的 _history_list。
#
#  ── 为什么记在框架层 ──
#    唯一的事件源是 VNPlayer._show_current()，那里同时握着说话人、原文、
#    语音路径、位置快照、舞台结构、姿态、当前音乐，以及这一句之前累积的
#    变量变更 —— 全是历史要的。而 line_shown 信号只发 (who, text)，
#    其余什么都带不出来，界面层从信号里根本凑不出完整的一条。
#
#  ── 条目的字段 ──
#    sid          去重用，见 add()
#    who          说话人显示名。旁白为空串
#    text         台词**原文**，带 BBCode。剥成纯文本是显示层的事
#    voice        语音路径。空串表示这条没有语音
#    position     capture_position() 的快照，回跳用
#    stage        这一句显示时的舞台结构快照，回跳用
#    pose         这一句开始时舞台的姿态快照，回跳用
#    bgm          这一句显示时正在播的背景音乐路径，空串表示没有音乐
#    vars_delta   这一句显示**之前**那段时间里被改过的变量 → 改之前的旧值
#    roles_delta  同上，角色属性
#
#  ── 为什么舞台与数值要跟着每一条走 ──
#  回跳要回到"那句的画面与数值"。画面只有那一刻有：从 ep1 跳回 ep0 时，
#  当前画面属于 ep1，抓不到第五句该有的样子。数值同理 —— 只恢复位置的话，
#  玩家会回到过去而好感度还是未来的值。
#
#  这与 Ren'Py 每个 checkpoint 存一份 SceneList 拷贝、以及 store 的 delta
#  （rollback.py:273 / :281）是同一件事。区别只在规模：那边是每条语句都存，
#  这边只存能停下来的台词，且舞台只存结构不存纹理。
#
#  ── delta 为什么记旧值而不是运算 ──
#  回跳时不需要理解 += / -=，把旧值整份贴回去就行。这样剧本里将来加别的
#  运算符，撤销逻辑一行都不用改。函数的逆运算不需要知道函数怎么算的。
#
#  ── 为什么存原文而不是存剥好的纯文本 ──
#    历史界面现在要纯文本，但那是**显示层的选择**。数据保持原样，
#    将来想让历史保留富文本效果时，不用动数据和序列化格式。
#
#  ── 可序列化 ──
#    to_data() / from_data() 是给存档系统留的口子。格式是一个 Array，
#    每项是一条记录的字典。Dictionary 本身就能被 var_to_bytes 处理，
#    不需要额外编码。
#
#    条目形状变了（多了 stage / delta）时，存档格式版本跟着 +1，旧档在
#    VNSave 那一层就被挡住 —— 本项目还在开发期，不做条目级迁移。读取方
#    因此可以假定字段齐全，不必到处判 has()
# ═══════════════════════════════════════════════════════════

## 条目列表。索引 0 是最旧的一条
var _entries: Array[Dictionary] = []

###########################################################
#  写入
###########################################################

## 追加一条。返回是否真的追加了（去重命中时返回 false）。
##
## who / text 存的是**原文**，不是译文。显示端（history.gd 那个页面）
## 才做 tr() —— 这样切语言之后整份历史可以跟着重译，
## 而不是永远停在记录当时那门语言上。
##
## moment 是"这一刻"的五样东西，由 VNPlayer._show_current() 当场抓好：
##   pose         各 tag 的显示姿态（位置 / 缩放 / 旋转 / 透明度）
##   stage        舞台结构（谁在台上、什么形态、哪一层）
##   bgm          正在播的曲子，空串表示当时确实没有音乐
##   vars_delta   这一句之前被改过的变量 → 旧值
##   roles_delta  同上，角色属性
##
## 为什么不让 add() 自己去取：这些东西只有播放器与显示层握得住，
## 而"取的那一刻"必须正好是这句台词落地的这一帧。晚一帧就抓到下一句的
## 画面了，早一帧舞台还没跟上这条 show。
##
## 去重的判据是 sid 与 text 都跟**最后一条**相同。为什么需要它：
## restore_position() 会重新显示当前句，而回跳正是走它 —— 不去重的话，
## 每次回跳都会在末尾多堆一条重复的。
##
## 为什么还要比 text：menu 的提示语与玩家选中的那一项共用**菜单指令**的
## sid（它们都不是独立指令），只比 sid 的话第二条会被当成重复丢掉，
## 历史里就只剩提示语、看不到选了什么
##
## 只比最后一条、不做全表去重：loop 回到之前的 label 是合法写法，
## 那时同一句确实该再记一次，全表去重会把这类正常情况一起吃掉
func add(sid: int, who: String, text: String, voice: String,
		position: Dictionary, moment: Dictionary) -> bool:
	if not _entries.is_empty():
		var tail: Dictionary = _entries[-1]
		if int(tail.get("sid", 0)) == sid and String(tail.get("text", "")) == text:
			return false

	# 逐项深拷。moment 里的两张 delta 表是 VNSession 刚交出来的活引用，
	# 不拷的话之后那次 take_journal() 之前的写入会改到已经归档的条目
	var stage: Dictionary = moment.get("stage", {})
	var pose: Dictionary = moment.get("pose", {})
	var vars_delta: Dictionary = moment.get("vars_delta", {})
	var roles_delta: Dictionary = moment.get("roles_delta", {})

	_entries.append({
		"sid": sid,
		"who": who,
		"text": text,
		"voice": voice,
		"position": position.duplicate(true),
		"stage": stage.duplicate(true),
		"pose": pose.duplicate(true),
		"bgm": String(moment.get("bgm", "")),
		"vars_delta": vars_delta.duplicate(true),
		"roles_delta": roles_delta.duplicate(true),
	})

	var limit := VNSettings.get_current().history_length
	while _entries.size() > limit:
		_entries.pop_front()

	return true

## 截断到前 count 条（保留 0 .. count-1）。
##
## 回跳后调用它：跳到第 N 条意味着"后面那些没发生过"。而且如果之后
## 剧情走了别的分支，留在表里的旧记录会指向一条与当前剧情线对不上的
## 位置，玩家点它只会跳到不相干的地方
func truncate(count: int) -> void:
	var keep := count
	if keep < 0:
		keep = 0
	while _entries.size() > keep:
		_entries.pop_back()

## 清空。开新游戏时用
func clear() -> void:
	_entries.clear()

###########################################################
#  读取
###########################################################

## 全部条目。发的是深拷，理由和 stage() 一样：
## 显示层和存档都不该有能力改到框架的内部状态
func entries() -> Array[Dictionary]:
	return _entries.duplicate(true)

## 条目数
func size() -> int:
	return _entries.size()

## 取一条。越界返回空字典
func at(index: int) -> Dictionary:
	if index < 0 or index >= _entries.size():
		return {}
	return _entries[index].duplicate(true)

## 取 [from, 末尾] 的条目（深拷），按原顺序。
##
## 回跳要用它撤销 from 之后那些条目记录的变量/角色属性变更。从末尾往前
## 遍历由调用方控制 —— 这里只按时间顺序交出去。
##
## from 越界时返回空数组而不是报错：回跳最后一条时 from 就等于 size，
## 那种情况下"没有要撤销的东西"正是正确答案
func from_index(from: int) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for i in range(maxi(from, 0), _entries.size()):
		out.append(_entries[i].duplicate(true))
	return out

###########################################################
#  序列化
###########################################################

## 导出成可存档的形式
func to_data() -> Array:
	return _entries.duplicate(true)

## 从存档恢复。数据不合法时保持为空，不抛错 ——
## 存档损坏时玩家该看到"没有历史"，而不是崩在打开历史界面上
func from_data(data: Variant) -> void:
	_entries.clear()
	if not (data is Array):
		return

	for item in (data as Array):
		if item is Dictionary:
			_entries.append((item as Dictionary).duplicate(true))

	var limit := VNSettings.get_current().history_length
	while _entries.size() > limit:
		_entries.pop_front()

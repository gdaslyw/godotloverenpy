class_name VNHistory
extends RefCounted

# ═══════════════════════════════════════════════════════════
#  对话历史。框架持有，界面只读 —— 对应 Ren'Py 的 _history_list。
#
#  ── 为什么记在框架层 ──
#    唯一的事件源是 VNPlayer._show_current()，那里同时握着说话人、原文、
#    语音路径和位置快照，四样都是历史要的。而 line_shown 信号只发
#    (who, text)，少了语音 —— 界面层从信号里根本凑不出完整的一条。
#
#  ── 条目的五个字段 ──
#    sid       去重用，见 add()
#    who       说话人显示名。旁白为空串
#    text      台词**原文**，带 BBCode。剥成纯文本是显示层的事
#    voice     语音路径。空串表示这条没有语音
#    position  capture_position() 的快照，回跳用
#
#  ── 为什么存原文而不是存剥好的纯文本 ──
#    历史界面现在要纯文本，但那是**显示层的选择**。数据保持原样，
#    将来想让历史保留富文本效果时，不用动数据和序列化格式。
#
#  ── 可序列化 ──
#    to_data() / from_data() 是给存档系统留的口子。存档还没做，格式先定
#    下来：一个 Array，每项是五个字段的字典。Dictionary 本身就能被
#    var_to_bytes 处理，不需要额外编码
# ═══════════════════════════════════════════════════════════

## 条目列表。索引 0 是最旧的一条
var _entries: Array[Dictionary] = []

###########################################################
#  写入
###########################################################

## 追加一条。返回是否真的追加了（去重命中时返回 false）。
##
## 去重的判据是 sid 与本列表**最后一条**相同。为什么需要它：
## restore_position() 会重新显示当前句，而回跳正是走它 —— 不去重的话，
## 每次回跳都会在末尾多堆一条重复的。
##
## 只比最后一条、不做全表去重：loop 回到之前的 label 是合法写法，
## 那时同一句确实该再记一次，全表去重会把这类正常情况一起吃掉
func add(sid: int, who: String, text: String, voice: String,
		position: Dictionary, pose: Dictionary = {}) -> bool:
	if not _entries.is_empty() and int(_entries[-1].get("sid", 0)) == sid:
		return false

	_entries.append({
		"sid": sid,
		"who": who,
		"text": text,
		"voice": voice,
		"position": position.duplicate(true),
		# 这一句开始时舞台的样子。历史跳转回到的正是这一刻 ——
		# 不能等到跳转时再去抓，那时画面可能已经是后面章节的了
		"pose": pose.duplicate(true),
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

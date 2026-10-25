class_name VNPersistent
extends RefCounted

# ═══════════════════════════════════════════════════════════
#  跨周目持久化变量。
#
#  ── 对应 Ren'Py 的什么 ──
#  `default persistent.xxx` / `persistent.xxx = 值`。那边挂在
#  renpy.persistent 上，和存档完全分离：读档不回滚、重开一局还在、
#  换存档也在。典型用途是"已经看过真结局""二周目才解锁的那条线"。
#
#  ── 与本项目普通变量的分界 ──
#    default foo = 0          进 VNSession，随存档走，开新局灌初值
#    default persistent.foo = 0   进本类，不进存档，只补缺不覆盖
#  两者共用同一张 default 表和同一条 set 指令，只是路径前缀不同。
#  这样做的好处是 .vnbc 格式一个字都不用改 —— 见下。
#
#  ── 为什么不给 .vnbc 加一张表 ──
#  .vnbc 的文件头是**定长**的（MAGIC | version | 各表计数）。再加一个
#  persistent_count 就必须升 FORMAT_VERSION，旧包会被拒绝。而复用
#  default 表（path 带 persistent. 前缀）零成本：读写两端都只多一个
#  "这个路径归谁"的判断。
#
#  ── 存档关系 ──
#  不进存档。读档、历史回跳、开新局都不碰它 —— 它记的是"玩家做过什么"，
#  不是"这一局走到哪"。
# ═══════════════════════════════════════════════════════════

## 路径前缀。和 role / steam 一样是"只在特定位置有意义"的保留根，
## 不进 lexer 关键字表 —— 进了以后作者再也不能拿它当角色名
const PATH_ROOT := "persistent"

## 完整前缀，带点。判"这条路径归不归本类管"一律用它
const PREFIX := PATH_ROOT + "."

## 本地记录的文件名。与 settings.cfg / seen.dat / achievements.dat 同目录
const FILE_NAME := "persistent.dat"

## 记录格式版本。将来要改结构时靠它分支，现在只有一个版本
const RECORD_VERSION := 1

## 路径 → 值。键是**完整路径**（"persistent.foo"），不拆成嵌套字典 ——
## 它和普通变量只差在"跨周目"，形状上没必要跟着点路径走
var _values: Dictionary = {}

###########################################################
#  生命周期
###########################################################

## 读本地记录。由 VNFrame._ready() 调一次。
##
## 文件不存在就当一条都没有 —— 首次运行就是这样，不是错误
func setup() -> void:
	load_records()

## 按 default 表补齐**文件里还没有**的路径，然后写盘。
##
## 对应 Ren'Py 的 execute_default_statement(False)：只补缺，不覆盖。
## 这是它与"开新局灌初值"的分界 —— 玩家攒下的 persistent 值不该因为
## 剧本里加了一行 default 就被打回初值。
##
## 由 VNPlayer.start() 在剧本加载完之后调：初值来自 default 表，
## 而表是刚读进来的。每次 start 都补一遍（不限 NEW_GAME），因为这是
## 玩家级数据，与开不开新局无关
func apply_defaults(defaults: Array) -> void:
	var changed := false

	for d in defaults:
		if not (d is Dictionary):
			continue

		var path := String(d.get("path", ""))
		if not is_persistent_path(path):
			continue
		if _values.has(path):
			continue

		_values[path] = VNSession.decode_value(
			String(d.get("kind", "s")), String(d.get("value", "")))
		changed = true

	if changed:
		save_records()

###########################################################
#  读写
###########################################################

## 这条路径是不是 persistent 命名空间下的。
##
## 静态：VNSession.reset_vars() 与 VNPlayer._apply_missing_defaults() 都要在
## 灌初值时把这一类挑出去，那两处手里没有本类实例
static func is_persistent_path(path: String) -> bool:
	return path == PATH_ROOT or path.begins_with(PREFIX)

## 这个路径有没有值。脚本变量不存 null，所以 null 一定表示"没有"
func has_var(path: String) -> bool:
	return _values.has(path)

## 读一个值。不存在返回 null
func get_var(path: String) -> Variant:
	return _values.get(path, null)

## 写一个值。how 是 "="、"+="、"-=" 之一，与 set 指令的运算符一致。
##
## 路径必须以 persistent. 开头 —— 调用方是 VNPlayer._apply_set()，
## 它已经按前缀分流过了，这里的检查只是防止误用
func set_var(path: String, value: Variant, how: String) -> void:
	if not is_persistent_path(path):
		push_error("persistent：路径必须以 \"%s\" 开头，写的是 \"%s\""
			% [PATH_ROOT + ".", path])
		return

	var old: Variant = _values.get(path, null)
	var next: Variant = VNSession.combine(old, value, how)
	if next == old:
		return

	_values[path] = next
	save_records()

###########################################################
#  本地记录
###########################################################

## 本地记录的完整路径。与 settings.cfg / achievements.dat 同一个目录
static func records_path() -> String:
	return VNConfig.data_dir().path_join(FILE_NAME)

## 备用路径。主目录不可写时（例如游戏装在 Program Files）退回这里，
## 与 VNConfig 里那几套记录同一个策略
static func fallback_path() -> String:
	return "user://" + FILE_NAME

## 读本地记录
func load_records() -> void:
	_values.clear()

	var path := records_path()
	if not FileAccess.file_exists(path):
		path = fallback_path()
		if not FileAccess.file_exists(path):
			return

	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_warning("持久化变量读取失败：%s" % path)
		return

	var data: Variant = file.get_var()
	file.close()

	if not (data is Dictionary):
		return

	var table: Dictionary = data
	var values: Variant = table.get("values", {})
	if not (values is Dictionary):
		return

	for key in values:
		_values[String(key)] = values[key]

## 把本地记录写盘。persistent 的写入本来就是低频的（看过结局、通关一次），
## 所以不学已读记录那套节流，改了就写
func save_records() -> bool:
	var payload := {
		"version": RECORD_VERSION,
		"values": _values.duplicate(),
	}

	if _write_records(records_path(), payload) != OK:
		if _write_records(fallback_path(), payload) != OK:
			push_error("持久化变量写入失败：%s" % records_path())
			return false
		push_warning("玩家数据目录不可写，持久化变量已改存 %s" % fallback_path())

	return true

## 写一份记录到指定路径，返回 Godot 的错误码
func _write_records(path: String, payload: Dictionary) -> int:
	VNConfig.ensure_data_dir()
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_var(payload)
	file.close()
	return OK

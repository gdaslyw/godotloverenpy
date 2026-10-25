class_name VNAchievements
extends RefCounted

# ═══════════════════════════════════════════════════════════
#  成就解锁。
#
#  ── 对应 Ren'Py 的什么 ──
#  renpy/common/00achievement.rpy:23 那个 achievement 门面。那边是
#  「一个门面 + 若干后端」：PersistentBackend 存 persistent._achievements，
#  SteamBackend（00steam.rpy:887）往 Steam 推。两个后端同时生效 ——
#  本地的永远在，Steam 的能用就用。
#
#  本文件是同一套结构，只是后端只有两个且固定：本地永远有，Steam 可选。
#  所以没有 backends 数组，代价是加第三个后端要改代码，收益是少一层
#  "谁都可能没实现"的间接。
#
#  ── 权威在哪 ──
#  **本地永远权威，Steam 是镜像。** 本地记着玩家解锁过什么，Steam 只是
#  把这件事报上去。所以 Steam 没开、离线、安卓包，都不影响成就判定；
#  等 Steam 能用了，由 sync() 把本地已有的补推上去 —— 这正是 Ren'Py
#  的 achievement.sync() 干的事（00achievement.rpy:293）。
#
#  ── 为什么全是 Object.call() ──
#  见 VNSteam 的说明。一句话：本文件不能出现 GodotSteam 的编译期符号，
#  否则把 vn/ 复制到没装插件的项目里，这个脚本连解析都过不去。
#
#  ── Steam 的初始化不在这里 ──
#  "能不能连上"由 VNSteam 回答，本类只是一份它的消费者。所以成就和
#  正版校验看到的是同一份状态，不会一个说可用、一个说不可用。
#
#  ── 存档关系 ──
#  成就不进存档。它是**玩家**做过什么，不是**这一局**走到哪 —— 和
#  VNConfig 里的已读记录、已选记录同一个层次。读档不会回滚成就。
# ═══════════════════════════════════════════════════════════

## 一个成就解锁了。参数是成就 id。
##
## 只在**首次**解锁时发一次。读档重放、历史回跳重复走到同一条指令时
## 不会再发 —— 应用层拿它做解锁提示，重复发会让提示刷屏
signal unlocked(id: String)

## 一个进度型成就的进度变了。max_value 来自 .vns 里 `steam "id" max N`
## 的声明，编译期已经内联进指令参数，所以这里拿到的一定是作者写的那个数
signal progress_changed(id: String, value: int, max_value: int)

## 成就命名空间的根。
##
## 剧本里 `if steam.<id>` 读它，顶层 `steam "id"` 声明它。parser 与
## expr 都引用这一个常量 —— 抄成两个字面量的后果是改了一处、另一处
## 静默失效（编译期放行、运行期永远读不到）
const PATH_ROOT := "steam"

## 本地记录的文件名。与 settings.cfg / seen.dat 放在同一个目录
const FILE_NAME := "achievements.dat"

## 进度提示的最小间隔（毫秒）。
##
## Steam 的进度提示是一块浮层，连发会糊成一片。同一局里玩家可能连着
## 推进好几个进度点（"看完第 3 个结局"接"看完第 4 个"），所以按时间
## 挡一道就够，不必按数值挡
const INDICATE_INTERVAL_MS := 3000

## 已解锁的 id 集合。Dictionary 当 set 用，键恒为 true
var _unlocked: Dictionary = {}
## 进度表：id → 已到达的数值。只增不减
var _progress: Dictionary = {}
## Steam 单例。null 表示"这一路不可用"，不是错误
var _steam: Object = null
## 上一次发进度提示的时刻，节流用
var _last_indicate_ms := 0

###########################################################
#  生命周期
###########################################################

## 建立成就状态：读本地记录，接上 Steam（如果它可用），然后把本地已有的
## 补推一遍。
##
## 由 VNFrame._ready() 调一次。Steam 的连接与所有权判定不在这里 ——
## 那是 VNSteam 的活，本类只从它手里拿单例。这样"能不能连上 Steam"
## 只有一个答案，成就和正版校验读到的是同一份状态。
##
## 读盘可能失败，失败时安静降级；VN.achievements 始终是个可用的对象
func setup(steam: VNSteam) -> void:
	load_records()
	_steam = steam.singleton() if steam != null else null
	sync()

## 这个成就解锁了没有。剧本里的 `if steam.<id>` 最终走到这里
func has(id: String) -> bool:
	return _unlocked.has(id)

## 某个成就的进度值。没记录过返回 0
func get_progress(id: String) -> int:
	return int(_progress.get(id, 0))

## Steam 这一路是不是真的可用。只给开发期排查用 —— 正常逻辑不该依赖它，
## 成就的判定与上报在两边都该是"能做就做"
func is_steam_active() -> bool:
	return _steam != null

###########################################################
#  解锁与进度
###########################################################

## 解锁一个成就。返回**是不是这次才解锁的**。
##
## 幂等是硬要求，不是优化：读档重放、历史回跳、快进都会让剧本重走同一条
## 指令，而"已经解锁"这件事必须没有副作用 —— 否则每次读档都会重新
## storeStats 一次，Steam 那边会重复弹浮层
func unlock(id: String) -> bool:
	if id.is_empty() or _unlocked.has(id):
		return false

	_unlocked[id] = true
	save_records()
	_steam_set_achievement(id)
	unlocked.emit(id)
	return true

## 上报一次进度，返回**这一下有没有顺带解锁**。
##
## 到 max_value 就地解锁，对应 Ren'Py 的 PersistentBackend.progress()
## （00achievement.rpy:109）：那边也是"数值够了自己 grant"，不需要作者
## 再写一条 unlock。所以剧本里进度型成就只写 progress，不写 unlock
func progress(id: String, value: int, max_value: int) -> bool:
	if id.is_empty() or _unlocked.has(id):
		return false

	# 只增不减。读档回到进度更早的位置时，记录要留在已经到过的地方 ——
	# 玩家真到过那里，回退不算退货
	if value <= int(_progress.get(id, 0)):
		return false

	_progress[id] = value

	# 满了就直接解锁，写盘交给 unlock() —— 它写的 payload 本来就包含
	# 进度表，这里再写一次是同一个文件写两遍
	if max_value > 0 and value >= max_value:
		return unlock(id)

	save_records()
	_steam_indicate(id, value, max_value)
	progress_changed.emit(id, value, max_value)
	return false

## 清空全部成就记录：本地两张表 + Steam 侧。
##
## 对应 Ren'Py 的 achievement.clear_all()（00achievement.rpy:223）。那边
## 也是逐个后端清，理由一样 —— **只清一路等于没清**：本地的幂等会挡住
## 二次解锁，Steam 的浮层也就永远不会再出现。
##
## 用途只有测试解锁浮层。**不可恢复**，账号上的进度会真的丢掉。
func clear_all() -> void:
	_unlocked.clear()
	_progress.clear()
	save_records()
	_steam_clear_all()

###########################################################
#  本地记录
###########################################################

## 本地记录的完整路径。与 settings.cfg / seen.dat 同一个目录
static func records_path() -> String:
	return VNConfig.data_dir().path_join(FILE_NAME)

## 备用路径。主目录不可写时（例如游戏装在 Program Files）退回这里，
## 与 VNConfig 里那三套记录同一个策略
static func fallback_path() -> String:
	return "user://" + FILE_NAME

## 读本地记录。文件不存在就当一条都没有 —— 首次运行就是这样，不是错误
func load_records() -> void:
	_unlocked.clear()
	_progress.clear()

	var path := records_path()
	if not FileAccess.file_exists(path):
		path = fallback_path()
		if not FileAccess.file_exists(path):
			return

	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_warning("成就记录读取失败：%s" % path)
		return

	var data: Variant = file.get_var()
	file.close()

	if not (data is Dictionary):
		return

	var table: Dictionary = data

	# 存的是 { unlocked: PackedStringArray, progress: Dictionary }。
	# 两张表分开而不是挤在一个字典里，因为值类型不同：解锁是集合，
	# 进度是数值 —— 混在一起读的时候要逐项判类型，写的时候也一样
	var ids: Variant = table.get("unlocked", PackedStringArray())
	if ids is PackedStringArray:
		for id in ids:
			_unlocked[String(id)] = true

	var values: Variant = table.get("progress", {})
	if values is Dictionary:
		for id in values:
			_progress[String(id)] = int(values[id])

## 把本地记录写盘。解锁和进度都是稀有事件，所以每次变化直接写，
## 不学已读记录那套节流 —— 那边一秒能标几十条，这边一局也就几条
func save_records() -> bool:
	var ids := PackedStringArray()
	ids.resize(_unlocked.size())
	var i := 0
	for id in _unlocked:
		ids[i] = String(id)
		i += 1

	var payload := {
		"unlocked": ids,
		"progress": _progress.duplicate(),
	}

	if _write_records(records_path(), payload) != OK:
		if _write_records(fallback_path(), payload) != OK:
			push_error("成就记录写入失败：%s" % records_path())
			return false
		push_warning("玩家数据目录不可写，成就记录已改存 %s" % fallback_path())

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

###########################################################
#  Steam
#
#  这一段里的每一次调用都是 _steam.call("方法名", 参数…)，没有一个
#  GodotSteam 的符号出现在源码里。单例由 VNSteam 传来，本类不碰初始化。
#
#  _steam 为 null 就表示"这一路不可用" —— 没装插件、安卓、客户端没开。
#  那不是错误，是常态：成就该记的照记，只是少了一份镜像
###########################################################

## 把本地已经解锁的成就补推给 Steam。
##
## 对应 Ren'Py 的 achievement.sync()（00achievement.rpy:293）。场景是
## 玩家离线解锁过、或者上一次 storeStats 失败，此时 Steam 那边缺记录。
##
## 先 getAchievement 问一遍再推，而不是无脑 set：Steam 侧已经有的
## 不该再触发一次浮层。只在一个都没补的时候才跳过 storeStats ——
## storeStats 本身有速率限制，能少发就少发
func sync() -> void:
	if _steam == null or _unlocked.is_empty():
		return

	var pushed := false
	for id in _unlocked:
		var info: Variant = _steam.call("getAchievement", String(id))
		if not (info is Dictionary):
			continue

		var entry: Dictionary = info
		# ret 为假说明这个 id 在 Steam 后台不存在（或改动没发布）。
		# 那不是玩家的问题，跳过就好，别一路推一堆无效 id
		if not bool(entry.get("ret", false)):
			continue
		if bool(entry.get("achieved", false)):
			continue

		_steam.call("setAchievement", String(id))
		pushed = true

	if pushed:
		_steam.call("storeStats")

## 通知 Steam 一个成就解锁了。
##
## setAchievement 只改内存，storeStats 才提交并触发浮层 —— 少任何一步
## 玩家都看不到提示。Ren'Py 的 SteamBackend.grant() 也是连着两行
## （00steam.rpy:907）。解锁是稀有事件，不必节流
func _steam_set_achievement(id: String) -> void:
	if _steam == null:
		return

	if not bool(_steam.call("setAchievement", id)):
		push_warning(("成就 \"%s\" 在 Steam 后台不存在或改动未发布；"
			% id) + "本地已记录，Steam 侧没有")
		return

	if not bool(_steam.call("storeStats")):
		push_warning("成就 \"%s\" 已提交，但 storeStats 失败；下次启动会补推" % id)

## 上报一次进度提示。
##
## 与解锁分开：indicateAchievementProgress 只弹浮层、不提交数据，对应
## Ren'Py 的 indicate_achievement_progress（00steam.rpy:125）。所以它
## 不需要跟 storeStats，也就不受那边的速率限制 —— 自己按时间挡一道
func _steam_indicate(id: String, value: int, max_value: int) -> void:
	if _steam == null or max_value <= 0:
		return

	var now := Time.get_ticks_msec()
	if now - _last_indicate_ms < INDICATE_INTERVAL_MS:
		return
	_last_indicate_ms = now

	_steam.call("indicateAchievementProgress", id, value, max_value)

## 把 Steam 侧的成就全部清掉。
##
## 名单向 Steam 要，而不是查本地记录：本地只知道"我这边解锁过哪些"，
## 后台可能还有别的（换过机器、本地文件丢过、用彩蛋清过一半）。
## 按后台的完整名单清才清得干净
func _steam_clear_all() -> void:
	if _steam == null:
		return

	var count := int(_steam.call("getNumAchievements"))
	for i in count:
		var raw: Variant = _steam.call("getAchievementName", i)
		if not (raw is String):
			continue
		var id := String(raw)
		if id.is_empty():
			continue
		_steam.call("clearAchievement", id)

	# clearAchievement 只改内存，storeStats 才提交 —— 与 setAchievement
	# 同一个道理。少这一步，重启游戏后成就又都回来了
	_steam.call("storeStats")

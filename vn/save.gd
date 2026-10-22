class_name VNSave
extends RefCounted

# ═══════════════════════════════════════════════════════════
#  存档数据层。槽位命名、落盘、读取都在这里 —— 界面层与调度器
#  只跟"槽名"打交道，不碰文件、不碰字节。
#
#  ── 位置 ──
#  和 settings.cfg / seen.dat 同处 VNConfig.data_dir()（开发期是项目根
#  下的 saves/，桌面发布版是可执行文件同级的 saves/，移动端与 Web 是
#  user://saves）。文件名取 slot_<槽名>.sav —— .sav 不是 Godot 认得的
#  资源扩展名，不会被导入器接手，这条规矩与 VNConfig 一致，理由见那边
#  的文件头。
#
#  ── 槽名 ──
#  照搬 Ren'Py 的"页-槽"命名，因为界面上要显示的 "NO.07" 正是从槽名
#  算出来的（见 slot_display_number）：
#    手动槽   "1-1" … "1-50"   对应原项目 page "1" 的 50 个槽
#    自动档   "auto"           对应 Ren'Py 的 auto 页
#    固定槽   任意名字          由内容层自己写，框架不预置也不自动填
#
#  固定槽不是框架概念：槽名只是内容层写死的一个字符串，框架只保证
#  "任意槽名都能读写" —— 名字里带连字符、下划线、中文都没有关系。
#  什么时候往它里面写由内容层自己决定，框架没有"经过某个 label 就自动
#  存一份"的功能
#
#  界面上还有一条"最近存档"，它**不是一个槽**，而是"手动槽里最新的
#  那一个"的查询结果，所以没有对应的文件名。
#
#  自动档只留一个槽：原项目的 auto 页在 Ren'Py 里可以有多个（每 N 次
#  交互存一个），但界面上只用 newest_slot("auto") 显示最新那个，
#  多存几个除了占地方没有别的作用。所以这里每次自动存档覆盖同一个文件。
#
#  ── 文件布局：分块 ──
#    [magic "VNSV" 4 字节][格式版本 u32]
#    块0 meta    [长度 u32][SHA-256 32 字节][数据]
#    块1 thumb   [长度 u32][SHA-256 32 字节][数据]
#    块2 body    [长度 u32][SHA-256 32 字节][数据]
#
#  分块的唯一理由是**打开存档界面不该读它不显示的东西**。
#  单槽的数据量大致是：大缩略图几百 KB，250 条历史几十 KB，
#  其余不到 1 KB。整份读的话，50 个槽就是几十 MB 的 I/O 加 50 次
#  924x520 的 PNG 解码，那个开销全花在了界面上根本不显示的历史和
#  用不到的大图上。
#
#  所以界面按用途分三次读：
#    列表（打开界面）  meta        50 个槽的编号/时间/章节名/附言
#    缩略图（可见的）  thumb       一次一个槽，界面侧缩到 453x255 显示
#    读档（点了某一槽）meta + body 缩略图不需要
#
#  缩略图**只存一份 924x520**，不为槽网格另存一张小图。
#  小图是"缩放后的缓存"，那属于内存的事：解码大图、缩到 453x255 建纹理、
#  把原图丢掉。往磁盘上再存一份等于把缓存写进硬盘 —— 占地方，而且
#  Ren'Py 也不是这么做的（它靠 im.py 的图片缓存 + 空闲时的 predict）。
#  每一个入口都只读它真正要用的块，其余的靠 seek 跳过。
#
#  每块**独立自校验**：跳过 body 就不校验 body。这是刻意的 ——
#  打开界面不需要 body 的完整性，真正读档时才需要，那时才验。
#
#  ── 为什么没有索引文件 ──
#  分块之后，每个 .sav 的 meta 块只有几百字节，扫 50 个 meta 块比维护
#  一份"槽名 → 时间/章节名"的缓存文件更简单，而且**永远不会与文件
#  不同步**。缓存被手删、被改坏、和文件对不上的那些麻烦事一并消失。
#  代价只是每次查询多读几十 KB，可以忽略。
#
#  ── 为什么摘要是 SHA-256 而不是内置 hash() ──
#  内置的 hash() 没有跨版本保证，引擎升级时一变，玩家所有旧存档都会
#  被误判成"已损坏"。SHA-256 是标准算法，由 HashingContext 在 C++ 侧
#  计算 —— 后半句也是性能要求不是偏好：GDScript 逐字节循环算几百 KB
#  的摘要要上百毫秒，而打开界面要读 50 个槽。
#
#  它的作用范围要写清楚：防的是**意外损坏**（写盘中断、位翻转、手工
#  改坏），不承担防篡改职责 —— 算法公开摆在这里，改完数据重算一遍
#  就绕过了。真要防篡改得用 HMAC 或签名，那是另一件事。
#
#  ── 校验顺序：先验后解 ──
#  每块都是字节流验完摘要才交给 bytes_to_var()。反过来做的话，一个被
#  截断的文件会让它解出半个字典，然后读档表现为"剧情乱跳、立绘错位"
#  —— 那是全项目最难查的一类故障，宁可在这里多写三行。
#
#  ── 写盘用临时文件 ──
#  先写 slot_x.sav.tmp 再改名过去。这一条比摘要更根本：它保证任何时刻
#  磁盘上要么是完整的旧档、要么是完整的新档，不会出现半个文件。
#  残留下来的 .tmp 不会被 list_slots() 认成存档（后缀对不上）。
# ═══════════════════════════════════════════════════════════

## 手动槽的页名。对应 Ren'Py 的 page "1"，槽名形如 "1-7"
const MANUAL_PAGE := "1"

## 自动存档的槽名
const SLOT_AUTO := "auto"

## 存档格式版本。布局或数据结构改动时 +1，读档时会挡住旧档并给出
## 明确提示，而不是让缺字段的字典悄悄跑下去
const SAVE_VERSION := 1

## 存档文件名前缀与后缀
const FILE_PREFIX := "slot_"
const FILE_SUFFIX := ".sav"

## 写盘中间态的后缀。放在存档目录里是为了让改名留在同一个文件系统内
## —— 跨盘改名不是原子操作，那就白做了
const TEMP_SUFFIX := ".tmp"

## 文件魔数
const MAGIC := "VNSV"

## 文件头长度：魔数 4 + 格式版本 u32
const HEADER_SIZE := 8

## 块头长度：长度 u32 + SHA-256 32 字节
const BLOCK_HEADER_SIZE := 36

## 摘要长度
const DIGEST_SIZE := 32

## 块序号。顺序即文件里的排列顺序，不许随意调整 ——
## 调整它等于改变文件布局，必须同时提升 SAVE_VERSION
const BLOCK_META := 0
const BLOCK_THUMB := 1
const BLOCK_BODY := 2
const BLOCK_COUNT := 3

## 缩略图尺寸与槽位显示尺寸不在这里 —— 它们是作品取舍，已移到
## content/vn_settings.gd 的 THUMB_SIZE / SLOT_THUMB_SIZE。
## Ren'Py 那边对应 config.thumbnail_width/height，原项目显式改过它

###########################################################
#  存档结构
###########################################################
#
#  写读两端必须用同一套键名，所以在这里集中定义，谁都不许写字面量。
#  read() 返回的 data 是一个**合并后**的字典，界面与调度器按这些键取值：
#
#    meta 块（列表与定位用，几百字节）
#      version     int              格式版本
#      time_unix   float            写入时刻的 Unix 时间戳，只用于排序
#      time_text   String           写入时刻的本地时间文本
#      chapter     String           章节名，对应原项目的 save_name
#      what        String           附言，对应原项目存档里的 "what"
#      label       String           当前 label 名
#      sid         int              当前语句的 sid，读档定位的主依据
#      anchor_sids PackedInt64Array 当前语句往前若干条的 sid，退回时的锚点
#      position    Dictionary       VNPlayer.capture_position() 的快照
#
#    body 块（只有真正读档时才读）
#      roles       Dictionary      角色属性
#      history     Array           对话历史，上限 250 条
#      bgm         String          正在播的 BGM 路径，空串表示没有
#
#    缩略图块
#      thumb      924x520 的 PNG 字节，由 VNScreenshot 生成
#
#  ── 为什么位置与 sid 放 meta、历史放 body ──
#  分块的依据是"谁在什么时候需要它"，不是"谁大谁小"。
#  定位信息（label / sid / 锚点 / 位置快照）加起来不到 1 KB，而读档时
#  必须和 meta 一起拿到，分到两块反而要读两次。
#
#  ── 为什么时间要存两份 ──
#  time_text 在**写入时**就定下来，而不是存完时间戳、显示时再转本地。
#  时间戳转本地要处理时区与夏令时，而存档上该显示的是"当时那一刻"：
#  玩家跨时区旅行之后回头看旧存档，看到的仍该是当时的时间。
#  time_unix 只负责排序（"最近存档"是谁）。

## 存档字段名：格式版本
const F_VERSION := "version"
## 存档字段名：写入时刻的 Unix 时间戳（排序用）
const F_TIME := "time_unix"
## 存档字段名：写入时刻的本地时间文本（显示用）
const F_TIME_TEXT := "time_text"
## 存档字段名：章节名
const F_CHAPTER := "chapter"
## 存档字段名：附言
const F_WHAT := "what"
## 存档字段名：当前 label 名
const F_LABEL := "label"
## 存档字段名：当前语句的 sid
const F_SID := "sid"
## 存档字段名：锚点 sid 序列
const F_ANCHORS := "anchor_sids"
## 存档字段名：位置快照
const F_POSITION := "position"
## 存档字段名：角色属性
const F_ROLES := "roles"
## 存档字段名：对话历史
const F_HISTORY := "history"
## 存档字段名：正在播的 BGM 路径
const F_BGM := "bgm"
## 存档字段名：各 tag 的显示姿态（位置 / 缩放 / 旋转 / 透明度）。
##
## ATL 是运行时状态，指令流里只有"用哪个 transform"，没有"播到哪了"。
## 不存这一份的话，读档重建只能从第 0 帧重播 —— 立绘会跳回居中。
## 旧存档没有这个字段，读出来是空字典，行为退回"重建 + 重播"
const F_POSE := "pose"
## 存档字段名：舞台结构快照（谁在台上、什么形态、哪一层）。
##
## 与 F_POSE 分工：【这里是"有哪些 tag"，F_POSE 是"它们现在在哪"】。
## 读档拿它直接还原舞台，不再从会话入口重放指令流 —— 重放要求控制流
## 完全可复现，而 {call=} 这类由玩家点击产生的位置变更重放看不见，
## 存档在它内部时重放会跑飞。
##
## 旧存档没有这个字段，读出来是空字典，行为退回"重放重建"
const F_STAGE := "stage"
## 存档字段名：剧本变量表。
##
## 它是 body 而不是 meta：变量可能很多，存档列表用不上。
## 旧存档没有这个字段，读出来是空字典 —— 之后剧本里再执行 "+=" 就从零值起算
const F_VARS := "vars"
## 存档字段名：缩略图（924x520 的 PNG 字节）
const F_THUMB := "thumb"

## meta 块收录哪些字段。这张表就是"什么算轻量信息、什么该跟列表一起读"
## 的唯一答案，加字段时只改这里
const META_FIELDS := [
	F_VERSION, F_TIME, F_TIME_TEXT, F_CHAPTER, F_WHAT,
	F_LABEL, F_SID, F_ANCHORS, F_POSITION,
]

## body 块收录哪些字段
const BODY_FIELDS := [F_ROLES, F_HISTORY, F_BGM, F_POSE, F_STAGE, F_VARS]

###########################################################
#  槽名与路径
###########################################################

## 第 index 个手动槽的槽名。index 从 1 开始，和界面上的编号一致
static func manual_slot(index: int) -> String:
	return "%s-%d" % [MANUAL_PAGE, index]

## 全部手动槽的槽名，顺序即编号顺序
static func manual_slots() -> PackedStringArray:
	var out := PackedStringArray()
	for i in range(1, VNSettings.get_current().slot_count + 1):
		out.append(manual_slot(i))
	return out

## 槽名对应的界面编号文本。"1-7" → "07"。
##
## 原项目是 str(slot).replace("1-", "").zfill(2)，这里照抄意图但换了实现：
## replace 会把槽名里任何位置的 "1-" 都换掉，而槽名只有开头那一段是页名。
## 取不到编号的槽名（"auto" 之类）返回空串，由界面决定显示什么
##
## ── 为什么没有了针对序章槽的 "00" 特判 ──
## 那条特判把两件事捆在一起：槽叫什么（内容层的）和显示成几号（界面约定）。
## 而原项目根本没有它 —— 序章那一格是**整块手写**的
## （game/screen/save_load.rpy:112-141：槽名、页名、编号全是字面量），
## 压根不走编号解析。
##
## 编号现在由内容层的存档界面自己给，见 save_load.gd 的 _slot_number()。
## 内容层那个固定槽叫 "fc-ep0_1"，走下面这段会 int("ep0_1") 失败返回 0，
## 凑出 "00" —— 那是巧合，界面不能依赖它
static func slot_display_number(slot: String) -> String:
	var dash := slot.find("-")
	if dash < 0:
		return ""
	return "%02d" % int(slot.substr(dash + 1))

## 槽名对应的文件绝对路径。不检查存在性 —— 判断存在用 exists()
static func slot_path(slot: String) -> String:
	return VNConfig.data_dir().path_join(FILE_PREFIX + slot + FILE_SUFFIX)

## 槽的存档文件在不在
static func exists(slot: String) -> bool:
	return FileAccess.file_exists(slot_path(slot))

## 扫描存档目录，返回**实际有文件**的槽名。
##
## 以目录为准：玩家手删过存档文件时，目录才是事实。
## 写盘中间态（.tmp）会因为后缀对不上而被自动滤掉
static func list_slots() -> PackedStringArray:
	var out := PackedStringArray()
	var dir := VNConfig.data_dir()
	if not DirAccess.dir_exists_absolute(dir):
		return out

	var name_len := FILE_PREFIX.length()
	var tail_len := FILE_SUFFIX.length()
	for file_name in DirAccess.get_files_at(dir):
		if not file_name.begins_with(FILE_PREFIX) \
				or not file_name.ends_with(FILE_SUFFIX):
			continue
		if file_name.length() <= name_len + tail_len:
			continue
		out.append(file_name.substr(name_len,
			file_name.length() - name_len - tail_len))
	return out

###########################################################
#  写入
###########################################################

## 写一个存档。data 里的字段见文件头的存档结构，这里只负责补上版本与
## 时间、按块切分、落盘。
##
## 两张缩略图的**字节**由调用方准备好（见 VNScreenshot），本函数不碰图像。
##
## 成功返回 true。任何一步失败都返回 false 并留下 push_error ——
## 存档失败必须让调用方知道，界面要据此决定是提示玩家还是保持原样
static func write(slot: String, data: Dictionary) -> bool:
	if slot.is_empty():
		push_error("VNSave：槽名为空，存档未写入")
		return false

	if not VNConfig.ensure_data_dir():
		return false

	# 深拷一份再加字段：调用方（VNPlayer.capture_state）给的字典可能
	# 还要接着用，往里塞 version / time 会污染它
	var payload := data.duplicate(true)
	payload[F_VERSION] = SAVE_VERSION
	payload[F_TIME] = Time.get_unix_time_from_system()
	payload[F_TIME_TEXT] = _now_text()

	var blob := MAGIC.to_ascii_buffer()
	var head := PackedByteArray()
	head.resize(4)
	head.encode_u32(0, SAVE_VERSION)
	blob.append_array(head)

	blob.append_array(_pack_block(var_to_bytes(_pick(payload, META_FIELDS))))
	blob.append_array(_pack_block(_bytes_of(payload, F_THUMB)))
	blob.append_array(_pack_block(var_to_bytes(_pick(payload, BODY_FIELDS))))

	var path := slot_path(slot)
	var temp := path + TEMP_SUFFIX

	var file := FileAccess.open(temp, FileAccess.WRITE)
	if file == null:
		push_error("VNSave：无法写入 %s（错误码 %d）"
			% [temp, FileAccess.get_open_error()])
		return false
	file.store_buffer(blob)
	file.close()

	return _commit(temp, path)

## 把临时文件改名成正式存档。
##
## 目标已存在时先删掉再改名：Windows 的 MoveFile 不覆盖已存在文件，
## 直接改名会让"覆盖存档"整个失败。代价是那一瞬间失去了原子性 ——
## 但崩在"删完旧的、还没改名"这个窗口里的概率，远小于"写盘中断留下
## 半个文件"的概率，而且前者最多丢一个槽，后者会让整个槽变成坏数据
static func _commit(temp: String, path: String) -> bool:
	var err := DirAccess.rename_absolute(temp, path)
	if err == OK:
		return true

	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
		err = DirAccess.rename_absolute(temp, path)
		if err == OK:
			return true

	push_error("VNSave：存档改名失败 %s → %s（错误码 %d）" % [temp, path, err])
	DirAccess.remove_absolute(temp)
	return false

## 删掉一个槽的存档文件。
##
## 界面上还没有删除入口（原项目把 save_delete 清空了，压根不做删除），
## 这个函数是给它将来补上时留的
static func erase(slot: String) -> bool:
	var path := slot_path(slot)
	if not FileAccess.file_exists(path):
		return true

	var err := DirAccess.remove_absolute(path)
	if err != OK:
		push_error("VNSave：删除存档失败 %s（错误码 %d）" % [path, err])
		return false
	return true

###########################################################
#  读取
###########################################################

## 读缩略图（924x520）。槽网格加载小图、悬停大预览，都走它。
##
## 读不出来返回空字节数组，界面退回占位图 —— 缩略图缺失不该拦住任何操作。
##
## 调用方要自己控制节奏：槽网格是"可见优先 + 分帧"，悬停预览要加防抖，
## 否则鼠标划过一排槽会连环读盘
static func load_thumbnail(slot: String) -> PackedByteArray:
	var read_ := _read_blocks(slot, [BLOCK_THUMB])
	if not read_["ok"]:
		return PackedByteArray()
	var blocks: Dictionary = read_["blocks"]
	var thumb: Variant = blocks.get(BLOCK_THUMB)
	if thumb is PackedByteArray:
		return thumb as PackedByteArray
	return PackedByteArray()

## 读一份完整存档。点了某个槽、真的要读档时调它。
##
## 它读 meta 与 body，**不读缩略图** —— 读档不需要画面，
## 那几百 KB 的解码开销没有理由付
##
## 返回 { ok: bool, error: String, data: Dictionary }，
## data 是 meta 与 body 合并后的完整字典，键见文件头的存档结构
static func read(slot: String) -> Dictionary:
	var read_ := _read_blocks(slot, [BLOCK_META, BLOCK_BODY])
	if not read_["ok"]:
		return {"ok": false, "error": String(read_["error"]), "data": {}}

	var blocks: Dictionary = read_["blocks"]
	var meta: Variant = bytes_to_var(blocks[BLOCK_META])
	var body: Variant = bytes_to_var(blocks[BLOCK_BODY])
	if not (meta is Dictionary) or not (body is Dictionary):
		return {"ok": false, "error": "存档内容无法解析", "data": {}}

	var data := (meta as Dictionary).duplicate(true)
	for key in (body as Dictionary):
		data[key] = (body as Dictionary)[key]
	return {"ok": true, "error": "", "data": data}

## 扫描全部槽的元数据。不读缩略图、不读历史。
##
## 返回 { 槽名: meta 字典 }。读不出来的槽不会出现在结果里 ——
## 界面上它会显示成空槽。
##
## 这是"最近存档是谁""有没有存档"这类查询的唯一数据源。它扫的是 .sav
## 本身而不是某个缓存文件，所以永远不会与文件不同步
static func scan() -> Dictionary:
	var out := {}
	for slot in list_slots():
		var read_ := _read_blocks(slot, [BLOCK_META])
		if not read_["ok"]:
			push_warning("VNSave：槽 %s 的元数据读不出来（%s）"
				% [slot, read_["error"]])
			continue
		var meta: Variant = bytes_to_var(read_["blocks"][BLOCK_META])
		if meta is Dictionary:
			out[slot] = meta
	return out

## 一组槽里最新的那个，按 meta 里的时间戳比较。全都没有则返回空串。
##
## 时间戳缺失的条目按 0 处理 —— 那种槽排到最后，
## 而不是让整个查询失败
static func newest_slot(metas: Dictionary, slots: PackedStringArray) -> String:
	var best := ""
	var best_time := -1.0
	for slot in slots:
		var meta: Variant = metas.get(slot)
		if not (meta is Dictionary):
			continue
		var t := float((meta as Dictionary).get(F_TIME, 0.0))
		if best.is_empty() or t > best_time:
			best_time = t
			best = slot
	return best

## 手动槽里最新的那个。界面左下角"最近存档"条显示的就是它
static func newest_manual_slot(metas: Dictionary) -> String:
	return newest_slot(metas, manual_slots())

## 一组槽里有没有至少一个能读的
static func has_slot(metas: Dictionary, slots: PackedStringArray) -> bool:
	for slot in slots:
		if metas.has(slot):
			return true
	return false

## 有没有手动槽存档。
##
## 主菜单用它决定"点击是开始新游戏还是打开读档界面"——原项目的判据是
## renpy.newest_slot()，那个默认只看当前页（也就是手动槽），
## 所以这里同样**不看自动档**：只有一个自动档时，主菜单照样该开始新游戏
static func has_manual_slot(metas: Dictionary) -> bool:
	return has_slot(metas, manual_slots())

###########################################################
#  内部
###########################################################

## 按需读取若干个块。
##
## 返回 { ok: bool, error: String, blocks: {块号: PackedByteArray} }。
## 只要的块会真正读进内存，其余的靠 seek 跳过 ——
## "打开存档界面不必读历史和大图"就是这一句 seek 实现的
static func _read_blocks(slot: String, wanted: Array) -> Dictionary:
	var path := slot_path(slot)
	if not FileAccess.file_exists(path):
		return _blocks_failure("存档不存在")

	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return _blocks_failure("存档打不开（错误码 %d）" % FileAccess.get_open_error())

	var total := file.get_length()
	if total < HEADER_SIZE:
		file.close()
		return _blocks_failure("存档文件不完整")

	# 魔数只占头 4 字节，而 HEADER_SIZE 是 8（4 魔数 + 4 版本号）。
	# 拿整块去比会永远不相等 —— 这正是"所有存档都读不出来"的根源，
	# 而且它的失败信息长得像"文件坏了"，很容易反过来去查写的那一侧
	var header := file.get_buffer(HEADER_SIZE)
	if header.slice(0, MAGIC.length()).get_string_from_ascii() != MAGIC:
		file.close()
		return _blocks_failure("文件头不认识，不是存档文件")

	var format := header.decode_u32(4)
	if format != SAVE_VERSION:
		file.close()
		return _blocks_failure("存档格式版本不符：文件 %d，本版支持 %d，请重新存档"
			% [format, SAVE_VERSION])

	var blocks := {}
	for index in BLOCK_COUNT:
		if file.get_position() + BLOCK_HEADER_SIZE > total:
			file.close()
			return _blocks_failure("存档在第 %d 块处被截断" % index)

		var chunk_header := file.get_buffer(BLOCK_HEADER_SIZE)
		var length := chunk_header.decode_u32(0)
		if length < 0 or file.get_position() + length > total:
			file.close()
			return _blocks_failure("存档第 %d 块的长度越界（文件被截断）" % index)

		if wanted.has(index):
			var data := file.get_buffer(length)
			if _digest(data) != chunk_header.slice(4, BLOCK_HEADER_SIZE):
				file.close()
				return _blocks_failure("存档第 %d 块已损坏（校验和不符）" % index)
			blocks[index] = data
		else:
			file.seek(file.get_position() + length)

	file.close()
	return {"ok": true, "error": "", "blocks": blocks}

## 把一块数据打包成"块头 + 数据"。
## 摘要写进块头，读的时候读哪块验哪块
static func _pack_block(data: PackedByteArray) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(BLOCK_HEADER_SIZE)
	out.encode_u32(0, data.size())

	var digest := _digest(data)
	for i in DIGEST_SIZE:
		out[4 + i] = digest[i]

	out.append_array(data)
	return out

## 从一份完整存档字典里挑出某一块要收的字段。
##
## 用"挑"而不是"删"：删的话，将来往存档里加字段时，忘了从哪一块里
## 排除它，它会同时出现在两块里，读回来谁覆盖谁全看遍历顺序
static func _pick(source: Dictionary, fields: Array) -> Dictionary:
	var out := {}
	for field in fields:
		if source.has(field):
			out[field] = source[field]
	return out

## 取字典里某个字节数组字段。类型不对或没有都返回空数组
static func _bytes_of(data: Dictionary, key: String) -> PackedByteArray:
	var value: Variant = data.get(key)
	if value is PackedByteArray:
		return value as PackedByteArray
	return PackedByteArray()

## 算字节流的 SHA-256。
##
## 走 HashingContext 而不是自己写循环：它在 C++ 侧算，几百 KB 是瞬时的，
## 而 GDScript 逐字节循环同样一份数据要上百毫秒 —— 打开存档界面要读
## 50 个槽，那个差距就是"秒开"和"卡几秒"
static func _digest(payload: PackedByteArray) -> PackedByteArray:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(payload)
	return ctx.finish()

## 当前本地时间的显示文本，格式 "2024/05/01 14:30"，
## 对应原项目 FileTime 的 format="%Y/%m/%d %H:%M"
static func _now_text() -> String:
	var d := Time.get_datetime_dict_from_system()
	return "%04d/%02d/%02d %02d:%02d" % [
		int(d["year"]), int(d["month"]), int(d["day"]),
		int(d["hour"]), int(d["minute"])]

## 分块读取的失败结果
static func _blocks_failure(message: String) -> Dictionary:
	return {"ok": false, "error": message, "blocks": {}}

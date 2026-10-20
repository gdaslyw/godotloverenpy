class_name VNBCFormat
extends RefCounted

# ═══════════════════════════════════════════════════════════
#  .vnbc 格式契约 —— 编译器与运行时共享
#  改这里必须同步检查 dev/compiler.gd 与 reader.gd
# ═══════════════════════════════════════════════════════════
#
#  [文件头]
#    MAGIC(4) | version(u32) | op_count(u32) | label_count(u32) | image_count(u32)
#             | transform_count(u32)                       ← v4 起
#  [label 表] × label_count
#    name(str) | index(u32)
#  [image 表] × image_count          ← v3 起
#    id(str) | path(str)
#  [transform 表] × transform_count  ← v4 起
#    name(str) | atl(str)            ← atl 是 ATL 语句树的 JSON
#  [指令记录] × op_count
#    sid(u64) | op(str) | argc(u8) | arg(str) × argc
#  [结尾]
#    checksum(u64)
#
#  字符串编码 = u32 长度 + UTF-8 字节，与 StreamPeer.put_utf8_string() 同格式
#  MAGIC 是例外：定长 4 字节，用 put_data() 直接写，不带长度前缀
#
#  落盘前两步变换：GZIP 压缩 → 整体异或 XOR_KEY
#  异或不是加密，只防手改；顺序必须与读取端严格对称
#
#  关于 sid：它是一条指令的持久身份，由编译器分配并跨次编译继承。
#  运行时靠它定位"剧情播到哪了"，所以它必须在剧本被编辑之后
#  依然指向同一句台词 —— 这正是它不能用行号代替的原因。
#
#  ── 关于 image 表（v3 新增）──
#  图像 ID → res:// 路径，由编译器在**编辑器环境**扫描 content/images/ 得出。
#  运行时不再扫目录：导出后的 pck 里 png 只剩一个 .png.import，源图被搬到
#  .godot/imported/ 下还带哈希，按扩展名过滤会一个都扫不到 —— 发布版所有
#  背景消失，而编辑器里永远撞不上。把表定死在编译期，这个差异就不存在了。
#
#  读取端允许旧版本：v2 的包没有这张表，照读不误（images 为空）。
#  这样做是为了让编译器第一次升到 v3 时仍能读到旧包、继承 sid ——
#  否则一次格式升级会让所有存档的位置全部失效

const MAGIC := "VNBC"
## 格式版本。任何字段顺序/宽度的改动都必须 +1，旧产物会因此被拒绝并要求重编。
##
## v5 没有改字段布局，升版本是因为**指令的语义变了**：ATL 语句树里出现了
## wait 与 use 两种节点，show 的 at 后面多了保留目标 end。旧引擎读到它们
## 只会静默跳过 —— 动画一声不响地不动，比拒绝加载难查得多
const FORMAT_VERSION := 5
## 读取端能接受的最低版本。v2 没有 image 表、v3 没有 transform 表，
## v5 之前的 transform 树里没有 wait / use，其余结构相同
const MIN_VERSION := 2
const XOR_KEY := 0x49
## 压缩模式。用 FileAccess.CompressionMode 枚举
const COMPRESSION_MODE := FileAccess.COMPRESSION_GZIP
## 解压输出上限，防止损坏数据导致内存暴涨（64 MB）
const MAX_RAW_SIZE := 64 * 1024 * 1024
## 间隔符。用于 checksum 与内容键的拼接，避免字段粘连产生歧义
const FIELD_SEP := "\u001F"
## 文件最小长度：文件头 16 字节 + 尾部 checksum 8 字节
const MIN_SIZE := 24

###########################################################
#  字节变换
###########################################################

## 异或变换。自反：xor_bytes(xor_bytes(d, k), k) == d，所以加密解密共用它
static func xor_bytes(data: PackedByteArray, key: int) -> PackedByteArray:
	# 必须复制。PackedByteArray 是引用类型，就地改会污染调用方的数据
	var out := data.duplicate()
	for i in out.size():
		out[i] = out[i] ^ key
	return out

## 压缩后异或，得到可落盘的字节流
static func seal(raw: PackedByteArray) -> PackedByteArray:
	return xor_bytes(raw.compress(COMPRESSION_MODE), XOR_KEY)

## 异或后解压。失败返回空数组（文件损坏或密钥不符）
static func unseal(sealed: PackedByteArray) -> PackedByteArray:
	return xor_bytes(sealed, XOR_KEY).decompress_dynamic(MAX_RAW_SIZE, COMPRESSION_MODE)

###########################################################
#  内容指纹
###########################################################

## 算内容校验和。编译器和运行时都调用它，保证算法唯一。
## 覆盖 label 表、image 表、transform 表与全部指令（含 sid），
## 任何字段被改动都会被发现。
##
## images / transforms 为空时结果与旧版本完全一致 —— 空表不产生任何 parts，
## 所以拿它校验旧包仍然对得上
static func compute_checksum(ops: Array[Dictionary], labels: Array[Dictionary],
		images: Dictionary = {}, transforms: Dictionary = {}) -> int:
	var parts := PackedStringArray()
	for label in labels:
		parts.append(str(label.get("name", "")))
		parts.append(str(label.get("index", 0)))
	for id in images:
		parts.append(String(id))
		parts.append(String(images[id]))
	for name in transforms:
		parts.append(String(name))
		parts.append(String(transforms[name]))
	for op in ops:
		parts.append(str(op.get("sid", 0)))
		parts.append(str(op.get("op", "")))
		for a in op.get("args", []):
			parts.append(String(a))
	return hash(FIELD_SEP.join(parts))

## 算一条指令的"内容键"，供编译器跨次编译配对继承 sid。
## 刻意不含 sid —— 它正是要被继承的东西。
## 这里用完整内容而不是 hash()：hash() 的位数没有文档保证，
## 一旦两条不同指令算出同一个键，就会静默继承到错误的 sid。
static func content_key(op: Dictionary) -> String:
	var parts := PackedStringArray()
	parts.append(str(op.get("op", "")))
	for a in op.get("args", []):
		parts.append(String(a))
	return FIELD_SEP.join(parts)

###########################################################
#  编解码
###########################################################

## 把指令、label 表、image 表与 transform 表编码成未压缩字节流（尾部含 checksum）
static func encode(ops: Array[Dictionary], labels: Array[Dictionary],
		images: Dictionary = {},
		transforms: Dictionary = {}) -> PackedByteArray:
	var sp := StreamPeerBuffer.new()

	sp.put_data(MAGIC.to_ascii_buffer())
	sp.put_32(FORMAT_VERSION)
	sp.put_32(ops.size())
	sp.put_32(labels.size())
	sp.put_32(images.size())
	sp.put_32(transforms.size())

	for label in labels:
		sp.put_utf8_string(str(label.get("name", "")))
		sp.put_32(int(label.get("index", 0)))

	for id in images:
		sp.put_utf8_string(String(id))
		sp.put_utf8_string(String(images[id]))

	for name in transforms:
		sp.put_utf8_string(String(name))
		sp.put_utf8_string(String(transforms[name]))

	for op in ops:
		sp.put_64(int(op.get("sid", 0)))
		sp.put_utf8_string(str(op.get("op", "")))
		var args: Array = op.get("args", [])
		# argc 是 u8。VN 语句的参数数量远达不到这个上限
		sp.put_8(args.size())
		for a in args:
			sp.put_utf8_string(String(a))

	sp.put_64(compute_checksum(ops, labels, images, transforms))
	return sp.data_array

## 解码未压缩字节流。
## 返回 { ok: bool, error: String, version: int, ops: Array, labels: Array, images: Dictionary }
## 失败时 ops/labels 可能只填了一部分，调用方应只依据 ok 判断
static func decode(raw: PackedByteArray) -> Dictionary:
	var ops: Array[Dictionary] = []
	var labels: Array[Dictionary] = []
	var images: Dictionary = {}
	var transforms: Dictionary = {}
	var version := 0

	if raw.size() < MIN_SIZE:
		return _failure("数据长度不足 %d 字节，文件可能被截断" % MIN_SIZE)

	var sp := StreamPeerBuffer.new()
	sp.data_array = raw

	# ── 魔数：定长 4 字节 ──
	var magic := sp.get_data(4)
	if magic[0] != OK:
		return _failure("读取魔数失败")
	if (magic[1] as PackedByteArray).get_string_from_ascii() != MAGIC:
		return _failure("魔数不符，不是有效的剧本文件")

	version = sp.get_32()
	if version < MIN_VERSION or version > FORMAT_VERSION:
		return _failure("剧本格式版本不符：文件=%d，引擎支持=%d~%d，请重新编译剧本"
			% [version, MIN_VERSION, FORMAT_VERSION])

	var op_count := sp.get_32()
	var label_count := sp.get_32()
	if op_count < 0 or label_count < 0:
		return _failure("记录数非法")

	# image_count 在**文件头里**，位于 label 表之前 —— 顺序必须和 encode() 一致
	var image_count := 0
	if version >= 3:
		image_count = sp.get_32()
		if image_count < 0:
			return _failure("图像表记录数非法")

	# transform_count 同理，v4 起
	var transform_count := 0
	if version >= 4:
		transform_count = sp.get_32()
		if transform_count < 0:
			return _failure("transform 表记录数非法")

	# ── label 表 ──
	for _i in label_count:
		if sp.get_available_bytes() < 4:
			return _failure("label 表被截断")
		var label_name := _read_string(sp)
		if sp.get_available_bytes() < 4:
			return _failure("label 表被截断")
		labels.append({"name": label_name, "index": sp.get_32()})

	# ── image 表（v3 起）──
	for _i in image_count:
		if sp.get_available_bytes() < 4:
			return _failure("图像表被截断")
		var id := _read_string(sp)
		var path := _read_string(sp)
		if not id.is_empty():
			images[id] = path

	# ── transform 表（v4 起）──
	for _i in transform_count:
		if sp.get_available_bytes() < 4:
			return _failure("transform 表被截断")
		var atl_name := _read_string(sp)
		var atl_source := _read_string(sp)
		if not atl_name.is_empty():
			transforms[atl_name] = atl_source

	# ── 指令记录 ──
	for _i in op_count:
		if sp.get_available_bytes() < 8:
			return _failure("指令表被截断")
		var sid := sp.get_64()
		var kind := _read_string(sp)
		if sp.get_available_bytes() < 1:
			return _failure("指令表被截断")
		var argc := sp.get_8()
		var args: Array[String] = []
		for _j in argc:
			args.append(_read_string(sp))
		ops.append({"sid": sid, "op": kind, "args": args})

	# ── 尾部 checksum ──
	if sp.get_available_bytes() < 8:
		return _failure("缺少结尾校验和，文件可能被截断")
	if sp.get_64() != compute_checksum(ops, labels, images, transforms):
		return _failure("校验和不符，文件已损坏或被修改")

	return {
		"ok": true, "error": "", "version": version,
		"ops": ops, "labels": labels, "images": images,
		"transforms": transforms,
	}

## 读一个带 u32 长度前缀的 UTF-8 字符串。
## 长度前缀先与剩余字节数比对，避免损坏数据触发巨额内存分配
static func _read_string(sp: StreamPeerBuffer) -> String:
	if sp.get_available_bytes() < 4:
		return ""
	var size := sp.get_32()
	if size < 0 or size > sp.get_available_bytes():
		return ""
	return sp.get_utf8_string(size)

## 构造一个失败结果
static func _failure(message: String) -> Dictionary:
	var ops: Array[Dictionary] = []
	var labels: Array[Dictionary] = []
	var images: Dictionary = {}
	var transforms: Dictionary = {}
	return {
		"ok": false, "error": message, "version": 0,
		"ops": ops, "labels": labels, "images": images,
		"transforms": transforms,
	}

###########################################################
#  文件读写
###########################################################

## 写一个 .vnbc 文件。返回是否成功
static func write_file(path: String, ops: Array[Dictionary],
		labels: Array[Dictionary], images: Dictionary = {},
		transforms: Dictionary = {}) -> bool:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_error("无法写入剧本文件 %s（错误码 %d）" % [path, FileAccess.get_open_error()])
		return false
	f.store_buffer(seal(encode(ops, labels, images, transforms)))
	f.close()
	return true

## 读一个 .vnbc 文件。返回结构同 decode()，读不到时 ok 为 false
static func read_file(path: String) -> Dictionary:
	var sealed := FileAccess.get_file_as_bytes(path)
	if sealed.is_empty():
		return _failure("剧本文件为空或不存在：%s" % path)

	var raw := unseal(sealed)
	if raw.is_empty():
		return _failure("解压失败（文件损坏或密钥不符）：%s" % path)

	return decode(raw)

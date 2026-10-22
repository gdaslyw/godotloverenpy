class_name VNReader
extends RefCounted

# ═══════════════════════════════════════════════════════════
#  .vnbc 读取入口。字节层的事全在 VNBCFormat 里，这里只做
#  文件级封装：把 label 表转成可查询的下标映射。
# ═══════════════════════════════════════════════════════════

## 指令序列，每项 { sid, op, args }
var ops: Array[Dictionary] = []
## label 表，每项 { name, index }
var labels: Array[Dictionary] = []
## label 名 → 指令下标。运行时跳转直接查它
var label_index: Dictionary = {}
## 图像 ID → res:// 路径。编译器在编译期扫好，运行时只查表
var images: Dictionary = {}
## transform 名 → ATL 语句树。.vnbc 里存的是 JSON，这里解析成数组，
## 运行时不再反复 parse —— ATL 每帧都要推进，不该在热路径上碰字符串
var transforms: Dictionary = {}
## 变量声明表，每项 { path, kind, value }。
## 编译器从各文件的顶层 default 汇总，运行时开新局时按它灌初值
var defaults: Array[Dictionary] = []
## 文件里记录的格式版本
var format_version: int = 0

###########################################################
#  对外接口
###########################################################

## 从 .vnbc 读入剧本。失败返回 false，且不改动已有数据
func load_from(path: String) -> bool:
	var result := VNBCFormat.read_file(path)
	if not result["ok"]:
		push_error(result["error"])
		return false

	var loaded_ops: Array[Dictionary] = result["ops"]
	var loaded_labels: Array[Dictionary] = result["labels"]

	var table := {}
	for label in loaded_labels:
		table[label["name"]] = label["index"]

	# transform 表在包里是 JSON 字符串，这里一次解析成结构。
	# 解析失败的条目直接丢掉 —— 校验和在读文件时已经验过，
	# 走到这里还坏说明是编译器写坏了，运行时没有补救的余地
	var parsed_transforms := {}
	var raw_transforms: Dictionary = result.get("transforms", {})
	for transform_name in raw_transforms:
		var blocks = JSON.parse_string(String(raw_transforms[transform_name]))
		if blocks is Array:
			parsed_transforms[transform_name] = blocks

	ops = loaded_ops
	labels = loaded_labels
	label_index = table
	images = result["images"]
	transforms = parsed_transforms
	defaults = result.get("defaults", [])
	format_version = result["version"]
	return true

## 取某个 label 的起始指令下标。不存在返回 -1
func find_label(name: String) -> int:
	return int(label_index.get(name, -1))

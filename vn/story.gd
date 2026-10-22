class_name VNStory
extends RefCounted

# ═══════════════════════════════════════════════════════════
#  剧本数据容器。只负责"加载并持有"，播放逻辑在 VN 里
# ═══════════════════════════════════════════════════════════

## 指令序列，每项 { sid, op, args }
var ops: Array[Dictionary] = []
## label 表，每项 { name, index }
var labels: Array[Dictionary] = []
## 图像 ID → res:// 路径。编译器扫 content/images/ 得到，运行时不再碰目录
var images: Dictionary = {}
## transform 名 → ATL 语句树
var transforms: Dictionary = {}
## 变量声明表，每项 { path, kind, value }。开新局时由 VNPlayer 灌进 session
var defaults: Array[Dictionary] = []
## 剧本格式版本
var format_version: int = 0

var _path := ""
var _reader: VNReader = null

###########################################################

## 加载剧本。失败返回 false 且不改动已有数据
func load_story(p_path: String) -> bool:
	var fresh := VNReader.new()
	if not fresh.load_from(p_path):
		return false

	_reader = fresh
	_path = p_path
	ops = fresh.ops
	labels = fresh.labels
	images = fresh.images
	transforms = fresh.transforms
	defaults = fresh.defaults
	format_version = fresh.format_version
	return true

## 用上次的路径重新加载。供热重载调用
func reload() -> bool:
	if _path.is_empty():
		return false
	return load_story(_path)

## 当前剧本路径
func path() -> String:
	return _path

## 取某个 label 的起始指令下标。不存在返回 -1
func label_start(label_name: String) -> int:
	if _reader == null:
		return -1
	return _reader.find_label(label_name)

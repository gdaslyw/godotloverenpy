class_name VNAlphaMask
extends RefCounted

# ═══════════════════════════════════════════════════════════
#  alpha 掩码命中判定。
#
#  用一张图的非透明像素当命中区，而不是它所在控件的矩形 ——
#  对应 Ren'Py 的 focus_mask。异形背景、PNG 立绘的可点部位、
#  只该在露出的地方响应鼠标的装饰框，都要它。
#
#  用法是建一次、存起来、反复查：
#
#      var _mask := VNAlphaMask.from_texture(tex)   # 建一次
#      ...
#      if _mask == null or _mask.contains(get_local_mouse_position()):
#          ...
#
#  建掩码要读整张图的像素，很贵 —— 千万别放进 _process 里反复调。
#  掩码自己只留一份位图（一位一像素），338x531 的图约 22KB，
#  不持有原纹理。
#
#  不做成 Resource：掩码是运行时从图算出来的，存成 .tres 没有意义，
#  要持久化就直接存源纹理。也不做成 Control 的子类：用它的东西不一定
#  是 Control，L2D 立绘是 Node2D，一样有 get_local_mouse_position()
# ═══════════════════════════════════════════════════════════

## 掩码尺寸，等于源图的像素尺寸。缓存一份，
## 免得每次查询都去问 BitMap 要一遍
var _size := Vector2i.ZERO

## 位图本体。为 null 表示掩码没建起来，contains() 会一律返回 false
var _bits: BitMap = null

###########################################################

## 从纹理的 alpha 通道建掩码。
##
## 拿不到像素数据（纹理为空或已释放）时返回 null，让调用方自己决定怎么
## 退化 —— 这里不悄悄返回一个"永远命中"的掩码，那种兜底会把"图配错了"
## 变成"判定莫名其妙不准"，反而更难查
static func from_texture(tex: Texture2D, threshold := 0.0) -> VNAlphaMask:
	if tex == null:
		return null
	return from_image(tex.get_image(), threshold)

## 从 Image 建掩码。调用方手里已经有 Image 时用它，省一次取图
static func from_image(img: Image, threshold := 0.0) -> VNAlphaMask:
	if img == null or img.is_empty():
		return null

	# 压缩过的图不能直接读像素。这里换成复制品再解压 ——
	# 传进来的 Image 可能是纹理内部的缓存，就地解压会把它污染掉
	var src := img
	if src.is_compressed():
		src = src.duplicate()
		src.decompress()

	var mask := VNAlphaMask.new()
	mask._bits = BitMap.new()

	# 阈值 0.0 的含义是"只要 alpha 不是全透明就算命中"，和 Ren'Py 一致：
	# 那边 alpha 为 0 的像素不属于按钮，半透明的抗锯齿边缘算在内
	mask._bits.create_from_image_alpha(src, threshold)
	mask._size = mask._bits.get_size()
	return mask

###########################################################

## 点是否落在掩码的不透明区内。
##
## pos 是相对掩码左上角的局部坐标 —— Control 的
## get_local_mouse_position() 和 _gui_input 里事件自带的 position 都符合
## 这个约定。源图和控件没对齐时（比如图绘制在控件内部的某个偏移处），
## 由调用方先减掉那个偏移
func contains(pos: Vector2) -> bool:
	if _bits == null:
		return false

	# 先用 float 挡边界再转 int：BitMap.get_bitv() 对越界坐标会 ERR_FAIL
	# 报错，而不是安静返回 false。这四行收在这里，调用方就不必每次重写
	if pos.x < 0.0 or pos.y < 0.0 \
			or pos.x >= float(_size.x) or pos.y >= float(_size.y):
		return false

	return _bits.get_bitv(Vector2i(pos))

## 掩码尺寸，等于源图的像素尺寸
func get_size() -> Vector2i:
	return _size

class_name VNScreenshot
extends RefCounted

# ═══════════════════════════════════════════════════════════
#  画面截图。存档缩略图的数据来源。
#
#  ── 它只管三件事 ──
#    抓帧   从 Viewport 回读当前画面
#    缩放   缩到调用方要的尺寸
#    编解码 PNG 字节 ↔ Image / ImageTexture
#
#  ── 裁形不在这里 ──
#  "把缩略图裁成 sl_emtpy 那个异形轮廓"是显示层的事，走
#  VNUIEffects.apply_alpha_mask()。本类属于框架，不该知道某部作品
#  用哪张图当遮罩。
#
#  ── 抓帧必须在"打开叠加界面之前" ──
#  存档界面是压在剧情之上的叠加层，压上去那一步会把剧情层整个隐藏
# （_main_layer.visible = false）。之后再抓只会抓到存档界面自己。
#  所以调用顺序是：先 await capture()，再 push_overlay()。
#
#  ── Compatibility 渲染器下的注意事项 ──
#  回读发生在 GPU 侧，必须等一帧画完（frame_post_draw）才能读 ——
#  绘制中途读会拿到上一帧的内容或者空白。这是本类唯一与环境有关的
#  地方：窗口最小化、被遮挡、或后端不支持回读时，get_image() 会返回
#  空图。那种情况本类返回 null 而不抛错 —— 缺一张缩略图不该拦住存档，
#  调用方显示占位图即可。
# ═══════════════════════════════════════════════════════════

## 抓一帧并缩放到指定尺寸。
##
## **这是协程**，调用方必须 await：
##     var image := await VNScreenshot.capture(get_viewport(),
##         VNSettings.get_current().thumb_size)
##
## 返回 Image；抓不到时返回 null（窗口最小化、后端不支持回读）。
## size 传 Vector2i.ZERO 表示不缩放，按原尺寸返回
static func capture(viewport: Viewport, size: Vector2i = Vector2i.ZERO) -> Image:
	if viewport == null:
		push_error("VNScreenshot：viewport 为空，抓帧失败")
		return null

	# 等这一帧画完再回读。这不是保险起见，是必须的：GPU 回读拿的是
	# "已经绘制完成的帧"，在绘制中途读会拿到上一帧的内容，或者干脆是空的
	await RenderingServer.frame_post_draw

	var texture := viewport.get_texture()
	if texture == null:
		push_error("VNScreenshot：拿不到 viewport 纹理")
		return null

	var image := texture.get_image()
	if image == null or image.is_empty():
		push_warning("VNScreenshot：viewport 回读失败（窗口最小化时会这样），"
			+ "这一张缩略图将缺失，槽位显示占位图")
		return null

	# 统一成 RGBA8：PNG 编码要求 8 位格式，而回读出来的格式由渲染器决定。
	# 少了这一步，某些后端会编码失败，或者编出一张颜色不对的图
	if image.get_format() != Image.FORMAT_RGBA8:
		image.convert(Image.FORMAT_RGBA8)

	if size.x > 0 and size.y > 0 and image.get_size() != size:
		# 缩小用 Lanczos：924x520 缩到 453x255 是两倍下采样，双线性会丢细节
		image.resize(size.x, size.y, Image.INTERPOLATE_LANCZOS)

	return image

###########################################################
#  编解码
###########################################################

## 把一张图编码成 PNG 字节。空图返回空数组
static func encode_png(image: Image) -> PackedByteArray:
	if image == null or image.is_empty():
		return PackedByteArray()
	return image.save_png_to_buffer()

## 从 PNG 字节解码。字节为空或解不出来时返回 null。
##
## 不抛错：存档里的缩略图坏了只该让那一个槽显示占位图，
## 不该阻断整个存档界面的构建
static func decode_png(bytes: PackedByteArray) -> Image:
	if bytes.is_empty():
		return null

	var image := Image.new()
	if image.load_png_from_buffer(bytes) != OK:
		push_warning("VNScreenshot：缩略图解码失败（%d 字节）" % bytes.size())
		return null
	return image

###########################################################
#  纹理
###########################################################

## 从 Image 建纹理。
##
## create_from_image() 会把像素上传到 GPU，之后 CPU 侧那份 Image 就可以
## 丢掉了 —— 纹理是独立的。这一点正是"槽网格只留小图"能成立的原因：
## 解码 924x520、缩到 453x255、建纹理、丢掉原图，显存里只留小图
static func texture_from_image(image: Image) -> ImageTexture:
	if image == null or image.is_empty():
		return null
	return ImageTexture.create_from_image(image)

## 从 PNG 字节直接建纹理，可顺带缩放到指定尺寸。
## 这是界面最常用的组合，一行顶三步。
##
## 返回 null 表示这张图没有（槽是空的，或者缩略图坏了），
## 由调用方决定显示哪张占位图
static func texture_from_png(bytes: PackedByteArray,
		size: Vector2i = Vector2i.ZERO) -> ImageTexture:
	var image := decode_png(bytes)
	if image == null:
		return null

	if size.x > 0 and size.y > 0 and image.get_size() != size:
		image.resize(size.x, size.y, Image.INTERPOLATE_LANCZOS)

	return texture_from_image(image)

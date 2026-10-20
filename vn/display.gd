class_name VNDisplay
extends RefCounted

# ═══════════════════════════════════════════════════════════
#  窗口尺寸的换算与应用。
#
#  ── 两套尺寸，各管一件事，别混 ──
#    screen_size()      屏幕的物理像素。判"这一档在这块屏上开不开得出来"
#    usable_size()      屏幕去掉任务栏之后的可视区。算实际尺寸用它
#
#  混用会出现"1920x1080 的屏上，1920x1080 那一档被判成开不出来" ——
#  因为任务栏一扣，可用区只剩 1040 了
#
#  ── 为什么缩放要按比例，而不是直接减像素 ──
#  项目的 viewport 是 2560x1440，stretch 用 canvas_items，而 aspect 是
#  默认的 keep。窗口宽高比和 viewport 差一点点，多出来的那截就是黑边。
#  所以缩出来的宽高必须**同时**是整数且保持原比例：单独把宽度砍掉 16
#  像素，比例就从 16:9 变成 1.92 了，左右立刻各出一条黑边
#
#  ── 全屏怎么表示 ──
#  配置表里用 Vector2i.ZERO 当哨兵。它不是合法的窗口尺寸，
#  正好不会和任何真实分辨率撞上
# ═══════════════════════════════════════════════════════════

## 配置表里表示"全屏"的取值
const FULLSCREEN := Vector2i.ZERO

## 档位装不下屏幕可用区时，先按这个比例缩一次。
##
## ── 为什么是比例，不是"精确扣掉标题栏" ──
## Godot 没有 API 能问出标题栏到底多高，扣像素就只能靠猜：猜小了窗口正好
## 压住任务栏，猜大了白白浪费一截可用高度 —— 而这两件事都和系统版本、
## 缩放设置有关，换台机器就得重新猜。
##
## 打一个固定折扣则天然留出余量，且和机器无关。代价是已知屏幕够大时
## 也会多缩一点，换来的是"任何机器上都不会盖住任务栏"
const OVERSIZE_SCALE := 0.9

###########################################################
#  平台
###########################################################

## 是不是"窗口由自己管、数据放可执行文件旁边"的桌面平台。
##
## 两个使用者：本类的全部窗口操作，以及 VNConfig.data_dir() 决定玩家数据
## 放哪儿。
##
## 刻意用白名单，而不是 OS.has_feature("pc") —— 认不出的平台必须当作
## 非桌面（数据落 user://，那是唯一保证可写的一侧；窗口尺寸则由系统说了算，
## 设了也没用）。白名单漏一个桌面系统的代价是数据去了 user://（能玩、能存），
## 黑名单漏一个移动平台的代价是存档功能整个失效，两边不对等
static func is_desktop() -> bool:
	return OS.has_feature("windows") or OS.has_feature("macos") \
		or OS.has_feature("linux") or OS.has_feature("bsd")

###########################################################
#  尺寸查询
###########################################################

## 窗口所在的那块屏幕
static func _screen() -> int:
	return DisplayServer.window_get_current_screen()

## 屏幕的物理尺寸。**判"能不能选"用它**，不是 usable_size()
static func screen_size() -> Vector2i:
	if not is_desktop():
		return DisplayServer.window_get_size()
	return DisplayServer.screen_get_size(_screen())

## 屏幕去掉任务栏之后的可视区
static func usable_size() -> Vector2i:
	if not is_desktop():
		return DisplayServer.window_get_size()
	return DisplayServer.screen_get_usable_rect(_screen()).size

###########################################################
#  档位换算
###########################################################

## 某一档在**当前这块屏**上实际能开的窗口尺寸。
##
## 三步：
##   1. 装得下可用区 —— 原样返回，不放大
##   2. 装不下 —— 先按 OVERSIZE_SCALE 缩一次；仍装不下（很小的屏幕）
##      再由 fit_into() 等比压进可用区
##   3. 量化 —— 压成"和标称尺寸同比例、宽高都是整数"的最大尺寸
##
## 第三步不能省。前两步出来的都是任意尺寸，比例很可能已经被浮点舍入
## 破坏，那种窗口在 stretch 的 aspect=keep 下会在一侧补出黑边
static func actual_size(nominal: Vector2i) -> Vector2i:
	if nominal == FULLSCREEN:
		return Vector2i.ZERO

	var limit := usable_size()
	var target := nominal

	if target.x > limit.x or target.y > limit.y:
		target = Vector2i(int(float(nominal.x) * OVERSIZE_SCALE),
			int(float(nominal.y) * OVERSIZE_SCALE))

	return _quantize(fit_into(target, limit), nominal)

## 把 size 压成"和 nominal 同比例、且宽高都精确"的最大尺寸。
##
## 把 nominal 用最大公约数化成最简比（2560x1440 → 16:9），再求 size 里
## 装得下几个这样的单位。这样出来的尺寸一定还是精确的同一个比例
static func _quantize(size: Vector2i, nominal: Vector2i) -> Vector2i:
	var unit := _gcd(nominal.x, nominal.y)
	if unit <= 0:
		return size

	# 整除是有意的：k 就是"最多能放几个单位"，余数本来就该丢掉
	@warning_ignore("integer_division")
	var ratio := Vector2i(nominal.x / unit, nominal.y / unit)
	@warning_ignore("integer_division")
	var k := mini(size.x / ratio.x, size.y / ratio.y)
	return ratio * k

## 这一档在这块屏上开不开得出来。
##
## 判据是**屏幕物理尺寸**，不是可用区：1920x1080 的屏上，"1920x1080"
## 那一档应当可选（只是实际会缩成 1728x972），而不是被任务栏挤成不可选
##
## 第二条判据是平台：安卓这类没有"窗口"的平台，除了全屏什么都不给选 ——
## 那边窗口尺寸由系统决定，设置项写什么都改不了实际显示
static func is_available(nominal: Vector2i) -> bool:
	if nominal == FULLSCREEN:
		return true
	if not is_desktop():
		return false
	var screen := screen_size()
	return nominal.x <= screen.x and nominal.y <= screen.y

## 按钮上该写的字。
##
## 可选的档写**实际尺寸**（它才是点下去真能得到的数）；不可选的档写**标称
## 尺寸** —— 它本来就点不了，标一个缩出来的数只会让人以为那档还能用
static func label_for(nominal: Vector2i) -> String:
	if nominal == FULLSCREEN:
		return "全屏"
	var size := nominal if not is_available(nominal) else actual_size(nominal)
	return "%d×%d" % [size.x, size.y]

## 把任意尺寸等比缩到 limit 之内。已经装得下就原样返回。
##
## 给"玩家自己拖出来的尺寸"用 —— 那个尺寸不保证是 16:9，所以不追求
## 精确比例，只保证不会有一条边撑出屏幕
static func fit_into(size: Vector2i, limit: Vector2i) -> Vector2i:
	if size.x <= limit.x and size.y <= limit.y:
		return size
	var factor := minf(float(limit.x) / float(size.x),
		float(limit.y) / float(size.y))
	return Vector2i(int(size.x * factor), int(size.y * factor))

## 两个数的最大公约数。actual_size() 化简比例用
static func _gcd(a: int, b: int) -> int:
	while b != 0:
		var t := b
		b = a % b
		a = t
	return absi(a)

###########################################################
#  当前状态
###########################################################

## 现在是独占式全屏还是普通全屏。两者都算"全屏"
static func is_fullscreen() -> bool:
	var mode := DisplayServer.window_get_mode()
	return mode == DisplayServer.WINDOW_MODE_FULLSCREEN \
		or mode == DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN

## 现在是不是普通窗口模式。最大化、最小化都不算
static func is_windowed() -> bool:
	return DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_WINDOWED

## 当前窗口对应配置表里的哪一档。**返回 -1 表示四个按钮都该是灭的**。
##
## 这是"选中态"的唯一判据：不看配置里存了什么，只看窗口此刻长什么样。
## 所以最大化、玩家手动拖过、换了显示器尺寸对不上，三种情况都会落到 -1 ——
## 那正是"这不是任何一档"的准确表达
static func current_index(modes: Array[Vector2i]) -> int:
	# 没有窗口概念的平台：永远算全屏档。
	#
	# 这一条不能省。安卓上 window_get_mode() 返回什么并不确定，万一它报的是
	# WINDOWED，下面那段尺寸比对会拿手机屏幕去和各档挨个比、一个都对不上，
	# 最后返回 -1 —— 表现就是"连全屏按钮都不亮"
	if not is_desktop():
		return modes.find(FULLSCREEN)

	if is_fullscreen():
		return modes.find(FULLSCREEN)

	if not is_windowed():
		return -1

	var size := DisplayServer.window_get_size()
	for i in modes.size():
		if modes[i] == FULLSCREEN:
			continue
		if actual_size(modes[i]) == size:
			return i
	return -1

###########################################################
#  应用
###########################################################

## 切到全屏
static func set_fullscreen() -> void:
	if not is_desktop():
		return
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)

## 切到窗口模式并设成 size，然后居中
static func set_window(size: Vector2i) -> void:
	if not is_desktop():
		return

	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	DisplayServer.window_set_size(size)
	_center(size)

## 把窗口挪到屏幕可用区的中间。
##
## 相对**可用区**而不是整块屏幕：有任务栏时按整屏居中会整体偏上，
## 看起来像没居中。
##
## usable_rect 的 position 已经是全局坐标（含多显示器偏移），
## 所以这里不再叠加 screen_get_position()
static func _center(size: Vector2i) -> void:
	var area := DisplayServer.screen_get_usable_rect(_screen())
	@warning_ignore("integer_division")
	DisplayServer.window_set_position(area.position + (area.size - size) / 2)

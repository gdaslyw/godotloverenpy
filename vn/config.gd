class_name VNConfig
extends RefCounted

# ═══════════════════════════════════════════════════════════
#  玩家数据（配置、已读记录、将来的存档）的落盘位置与读写。
#
#  位置规则（判定顺序见 data_dir()）
#    开发期     —— 项目根目录下的 saves/，跟 content 同级
#    桌面发布版 —— 可执行文件同级目录下的 saves/
#    移动端/Web —— user://saves
#
#  数据目录刻意让编辑器扫描（不放 .gdignore）：
#  开发时能在 FileSystem 面板里直接看到、双击查看、随手删掉存档，
#  比藏起来方便得多。两条前提保证这么做是安全的：
#    1. 存档文件不使用 Godot 认识的资源扩展名（.tres / .res / .tscn / .png …），
#       否则会被导入器接手，平白多出 .import 文件
#    2. Godot 导出默认只包含资源文件，非资源文件要在导出预设的
#       "Filters to export non-resource files/folders" 里显式列出才会进包，
#       所以 saves/ 不会被打进发布版 —— 保持那个过滤器为空即可
#
#  本类是"玩家数据目录"的唯一权威定义点。
# ═══════════════════════════════════════════════════════════

## 配置文件名。刻意用 .cfg —— 它不是 Godot 的资源类型，不会被导入
const FILE_NAME := "settings.cfg"
const SECTION := "preferences"

## 音量偏好的键名前缀。拼上 mixer 名就是键名：music → volume_music。
## 刻意带前缀：settings.cfg 是留给人手改的，一眼能分出哪几行是音量
const VOLUME_KEY_PREFIX := "volume_"

## 已读记录文件名。和 settings.cfg 分开存 ——
## 前者是十几个键的小配置（适合直接打开手改），后者是几千条记录，
## 混在一起以后想改个设置都得在几千行里翻
const SEEN_FILE_NAME := "seen.dat"

## 看过的图像记录文件名。和 seen.dat 同理，也是会增长的清单。
##
## 单独一份而不是塞进 seen.dat：那份存的是语句 sid（快进用），这份存的是
## 图像 id（CG 鉴赏用），两者的增长节奏、用途、将来的清空方式都不一样
const IMAGES_FILE_NAME := "images.dat"

## 写盘节流间隔（毫秒）。
##
## 快进时每秒会标记几十条已读，逐条写盘就是每秒几十次文件写入。
## 攒一会儿再写，代价是异常退出会丢掉最后这几秒的记录 ——
## 那些句子下次被当成没读过，不算大事
const SEEN_SAVE_INTERVAL_MS := 5000

## 语音在台词推进后是否继续播放（Ren'Py 的 voice sustain）。
## 默认 false，与 Ren'Py 的 preferences.voice_sustain 一致
var voice_sustain := false

## 自动播放间隔的出厂值，单位秒。对应 Ren'Py 的 preferences.afm_time 默认 15。
##
## 提成常量是因为它有三个使用点：成员变量的初值、load_config() 读不到这一项
## 时的兜底、reset_playback() 的重置。三处必须同一个数，而它们分居文件两头
const DEFAULT_AUTO_FORWARD_TIME := 15

## 自动播放的等待间隔。对应 Ren'Py 的 preferences.afm_time：
## 数值越大等得越久，实际秒数由它和台词长度共同决定，
## 见 say.gd 的 _auto_delay_ms()。范围见作品配置表的 setting_ranges
var auto_forward_time := DEFAULT_AUTO_FORWARD_TIME

## 自动播放时是否等语音播完再推进。
## 对应 Ren'Py 的 preferences.wait_voice，默认 true 也是那边的默认值
var wait_voice := true

## 快进时是否跳过未读文本。对应 Ren'Py 的 preferences.skip_unseen：
## true 全部跳过，false 只跳读过的。
##
## 默认 false —— 也就是默认只跳已读。玩家想要"一路冲到底"时，
## 按住 Ctrl 那一路不受它约束（见 ctrl_force_skip）
var skip_unseen := false

## 按住 Ctrl 快进时是否无视 skip_unseen，即"Ctrl 强制快进"。
## 默认开：这一路是玩家临时想加速，按下时就知道自己在跳过什么
var ctrl_force_skip := true

###########################################################
#  对话框
###########################################################

## 对话框底图透明度的出厂值。对应原项目 say.rpy 的
## `default persistent.window_alpha = 1.0`
const DEFAULT_WINDOW_ALPHA := 1.0

## 对话框底图的透明度。范围见作品配置表的 setting_ranges。
##
## 只作用于对话框和名字框的**底图**（say_bg / say_namebox）——
## 正文、角色名、继续箭头、快捷菜单都不跟着变淡。原项目那边是
## `background Transform("say_bg", alpha=persistent.window_alpha)`，
## 调的也只是背景那一张图
var window_alpha := DEFAULT_WINDOW_ALPHA

## 正文用的字体文件路径。**空串表示用作品配置表里的第一项**。
##
## 存路径而不是表里第几项：settings.cfg 是留给人手改的，写一行路径比写
## 一个位置数字清楚得多，而且将来字体表调整顺序时不会把玩家的选择错位
var dialog_font := ""

###########################################################
#  光标
###########################################################

## 自动隐藏光标的出厂间隔，单位秒。对应 Ren'Py 的 config.mouse_hide_time 默认 30
const DEFAULT_MOUSE_HIDE_TIME := 30.0

## 鼠标静止多久之后隐藏光标，单位秒。**0 表示不隐藏**。
##
## 对应 Ren'Py 的 config.mouse_hide_time。那边用 None 表示不隐藏，
## 这里用 0 —— 数值字段存不了 None，而"静止 0 秒就隐藏"在语义上不成立，
## 正好可以拿它当哨兵
var mouse_hide_time := DEFAULT_MOUSE_HIDE_TIME

###########################################################
#  功能栏（QM）
###########################################################

## 功能栏自动隐藏的出厂值。对应原项目 quick_menu.rpy 的
## `default persistent.qm_auto_hide = True`
const DEFAULT_QM_AUTO_HIDE := true

## 快捷菜单是否自动隐藏。
##
## 关掉时对应原项目最外层那个 `if persistent.qm_auto_hide is True:` ——
## 延时、透明度动画、悬停区三样**全都不存在**，QM 就那么一直亮着。
## 不是"不淡出但还响应悬停"，那三件事是绑在一起的
var qm_auto_hide := DEFAULT_QM_AUTO_HIDE

###########################################################
#  窗口
###########################################################

## 出厂是不是全屏。首次运行与"重置本页"都落在这里
const DEFAULT_FULLSCREEN := true

## 现在是不是全屏
var fullscreen := DEFAULT_FULLSCREEN

## 窗口模式下的客户区尺寸。
##
## 存**实际尺寸**而不是档位下标：玩家可以把窗口拖到一个不属于任何档位的
## 大小，那个大小同样是他的选择，同样要记住。Vector2i.ZERO 表示还没进过
## 窗口模式 —— 这时 VNConfig 不知道屏幕多大，没法给默认值，
## 留到 apply_display() 里现取
var window_size := Vector2i.ZERO

## 各路音量，0.0–1.0 的线性值。键是 mixer 名，有哪几路见配置表的
## VOLUME_BUSES（值必须与 default_bus_layout.tres 里的总线名对得上）。
##
## 用字典而不是四个成员：有哪几路是作品决定，写成成员等于把"四路"钉死在
## 框架里，加一路要同时改声明、范围表、读写、应用四处
var volumes: Dictionary = {}

## 打字机速度，字符/秒。0 表示整句立刻显示。
##
## 对应 Ren'Py 的 preferences.text_cps。**初值**由 _init() 从配置表的
## DEFAULT_TEXT_CPS 取 —— 与 Ren'Py 的 config.default_text_cps 同一条规则：
## 作品给的是首次运行时的初值，玩家改过之后以玩家存的为准
var text_cps := 0

## 已读语句：sid → true。
##
## 用字典而不是数组：快进时每句都要查一次，线性扫描几千条会很痛。
## 值恒为 true，只用来占位 —— 存盘时会把它拍扁成纯 sid 数组
var _seen: Dictionary = {}

## 已读记录有没有还没落盘的改动
var _seen_dirty := false

## 上次写盘的时刻（毫秒）
var _seen_saved_ms := 0

## 看过的图像：id → true。
##
## 由舞台在真正显示某张图时标记（见 VNStage._add_entry），CG 鉴赏靠它
## 决定显示缩略图还是锁定图。值同样恒为 true，存盘时拍平成字符串数组
var _seen_images: Dictionary = {}

## 图像记录有没有还没落盘的改动
var _seen_images_dirty := false

## 图像记录上次写盘的时刻（毫秒）
var _seen_images_saved_ms := 0

###########################################################
#  初值
###########################################################

## 铺一遍初值。玩家改过的值由 load_config() 覆盖。
##
## 放在这里而不是写成成员变量的初始化式：这样"初值全部来自作品配置"
## 是一句看得见的话，而不是散在五行声明里各自引用一次。
##
## 时序上有个要知道的点：VNConfig 的实例是 VNFrame._ready() 里造的，
## 而且是在第 1 步 load_project_settings() **之后**。所以这里读到的是
## **作品覆盖过的值**，不是框架默认值。
##
## 这条顺序是重构时特意收紧的：实例若在成员初始化式里造（那样早于
## load_project_settings()），这里就会读到框架默认值，而首次运行时
## 谁也没去盖它 —— 表现为"作品在 vn_settings.gd 里改了
## default_text_cps，第一次进游戏却是框架默认速度"，且只在首次运行出现
func _init() -> void:
	# 出厂值走 reset_playback() / _fill_volumes()，与设置界面那个
	# 「重置本页」是同一段逻辑。两处各写一份的话，哪天默认值改了必有一边
	# 被漏掉，而漏掉的那边不会有任何报错，只表现为"重置之后和新装不一样"
	reset_playback()
	_fill_volumes()

	# 显示档位同理，但它只铺内存值、不碰窗口 —— 这一刻窗口还没准备好，
	# 真正的应用在 load_config() 之后由 VNFrame 调 apply_display()
	_fill_display()

###########################################################
#  重置
###########################################################

## 把"剧情呈现与播放节奏"这一组偏好恢复成出厂值。
##
## 七个值各有各的权威定义点，这里一个都不重复写死：
##   auto_forward_time —— DEFAULT_AUTO_FORWARD_TIME（Ren'Py 的 afm_time 默认）
##   text_cps          —— 作品配置的 default_text_cps
##   skip_unseen       —— Ren'Py 的 preferences.skip_unseen 默认 False
##   window_alpha      —— DEFAULT_WINDOW_ALPHA（原项目的 persistent.window_alpha）
##   mouse_hide_time   —— DEFAULT_MOUSE_HIDE_TIME（Ren'Py 的 mouse_hide_time 默认）
##   qm_auto_hide      —— DEFAULT_QM_AUTO_HIDE（原项目的 persistent.qm_auto_hide）
##   dialog_font       —— 空串，表示用作品配置表里的第一项
##
## 只重置内存值，不写盘 —— 落盘由调用方（设置页的重置按钮）统一做
func reset_playback() -> void:
	var settings := VNSettings.get_current()
	skip_unseen = false
	auto_forward_time = int(clamp_value("auto_forward_time",
		float(DEFAULT_AUTO_FORWARD_TIME)))
	text_cps = int(clamp_value("text_cps", float(settings.default_text_cps)))
	window_alpha = clamp_value("window_alpha", DEFAULT_WINDOW_ALPHA)
	mouse_hide_time = DEFAULT_MOUSE_HIDE_TIME
	qm_auto_hide = DEFAULT_QM_AUTO_HIDE
	dialog_font = ""

## 把所有音量恢复成满，并立刻应用到总线。
##
## 比 reset_playback() 多一步 apply_audio()：音量是"改了就该听见"的东西，
## 留在内存里等下次启动才生效等于没重置
func reset_volumes() -> void:
	_fill_volumes()
	apply_audio()

## 按配置表把所有音量铺成满值。只碰内存，不碰总线 ——
## _init() 要用它，那个时刻还没有"应用"的必要
func _fill_volumes() -> void:
	var settings := VNSettings.get_current()
	var full := settings.volume_range.y

	volumes.clear()
	for mixer in settings.volume_buses:
		volumes[mixer] = full

## 把显示档位恢复成出厂值并立刻应用。
##
## 和 reset_volumes() 一样多一步应用：窗口大小是"改了就该看见"的东西，
## 只留在内存里等下次启动生效等于没重置
func reset_display() -> void:
	_fill_display()
	apply_display()

## 只铺显示档位的内存值，不碰窗口。_init() 用它
func _fill_display() -> void:
	fullscreen = DEFAULT_FULLSCREEN
	window_size = Vector2i.ZERO

###########################################################
#  窗口应用
###########################################################

## 按当前设置把窗口摆好。启动时调一次，玩家改显示档位时也走它。
##
## 非桌面平台直接跳过：移动端与 Web 没有"窗口尺寸"这回事，
## 对它们调 DisplayServer 只会得到一句警告
func apply_display() -> void:
	if not VNDisplay.is_desktop():
		return

	if fullscreen:
		VNDisplay.set_fullscreen()
		return

	var size := window_size
	if size == Vector2i.ZERO:
		size = _first_window_size()

	# 换过显示器的话，上次的尺寸可能已经装不下了。等比缩，不直接砍 ——
	# 只有一条边超出时砍那一条会改掉窗口的形状
	size = VNDisplay.fit_into(size, VNDisplay.usable_size())
	window_size = size
	VNDisplay.set_window(size)

## 切到配置表里的第 index 档，并立刻应用
func set_display(index: int) -> void:
	var modes: Array[Vector2i] = VNSettings.get_current().display_modes
	if index < 0 or index >= modes.size():
		push_error("VNConfig：显示档位下标越界 %d" % index)
		return

	var nominal: Vector2i = modes[index]
	if nominal == VNDisplay.FULLSCREEN:
		fullscreen = true
	else:
		fullscreen = false
		window_size = VNDisplay.actual_size(nominal)
	apply_display()

## 记下玩家自己拖出来的窗口尺寸。
##
## 只在普通窗口模式下记 —— 全屏、最大化、最小化时那个尺寸是引擎给的，
## 不是玩家的选择。记下来下次启动照它恢复
func capture_window_size() -> void:
	# 没有窗口概念的平台不记。安卓上屏幕旋转同样会发 size_changed，
	# 不挡的话旋转后的屏幕尺寸会被当成"玩家拖出来的窗口大小"写进配置
	if not VNDisplay.is_desktop():
		return

	if not VNDisplay.is_windowed():
		return

	var size := DisplayServer.window_get_size()
	if size == Vector2i.ZERO or size == window_size:
		return
	window_size = size

## 第一次进窗口模式时的兜底尺寸：配置表里第一个窗口档，缩到装得下
func _first_window_size() -> Vector2i:
	for nominal: Vector2i in VNSettings.get_current().display_modes:
		if nominal != VNDisplay.FULLSCREEN:
			return VNDisplay.actual_size(nominal)
	return Vector2i(1280, 720)

###########################################################
#  对话框应用
###########################################################

## 实际生效的正文字体路径。
##
## 配置里存空串时取作品配置表里的第一项 —— 那等于"出厂字体"。
## 表为空则返回空串，调用方据此跳过应用，而不是去 load 一个空路径
func dialog_font_path() -> String:
	if not dialog_font.is_empty():
		return dialog_font

	var fonts: Array = VNSettings.get_current().dialog_fonts
	if fonts.is_empty():
		return ""
	return String(fonts[0].get("path", ""))

###########################################################
#  位置与创建
###########################################################

## 玩家数据目录的路径。分三档，判定顺序就是下面代码的顺序：
##   编辑器       —— 项目根下的 saves/
##   桌面发布版   —— 可执行文件同级的 saves/
##   其余平台     —— user://saves
##
## 前两档刻意返回绝对路径而不是 res://：
##   · res:// 下的一切会被资源系统扫描并尝试导入
##   · 导出后 res:// 是 pck 内部，根本不可写
##
## 最后一档为什么不沿用"可执行文件同级"：安卓上可执行体就是 APK 本身，
## get_base_dir() 落在系统应用安装目录（/data/app/~~xxxx/<包名>-yyyy/），
## 那棵树对应用只读，而且重装时整个被替换 —— 不是缺权限，是位置本身不对。
## user:// 在那边映射到应用沙盒内的私有目录，不需要任何权限
static func data_dir() -> String:
	var dir_name := VNSettings.get_current().data_dir
	if OS.has_feature("editor"):
		# 编辑器里 res:// 就是项目根；globalize_path 只在编辑器下对 res:// 有效
		return ProjectSettings.globalize_path("res://").path_join(dir_name)
	if not VNDisplay.is_desktop():
		return "user://" + dir_name
	return OS.get_executable_path().get_base_dir().path_join(dir_name)

## 配置文件的完整路径
static func config_path() -> String:
	return data_dir().path_join(FILE_NAME)

## 已读记录的完整路径
static func seen_path() -> String:
	return data_dir().path_join(SEEN_FILE_NAME)

## 看过的图像记录的完整路径
static func images_path() -> String:
	return data_dir().path_join(IMAGES_FILE_NAME)

## 备用路径。主目录不可写时（例如游戏装在 Program Files）退回这里
static func fallback_path() -> String:
	return "user://" + FILE_NAME

## 确保玩家数据目录存在，返回是否可用。
## 只建目录 —— 数据目录要让编辑器扫描到，所以不做任何忽略处理
static func ensure_data_dir() -> bool:
	var dir := data_dir()
	if DirAccess.dir_exists_absolute(dir):
		return true

	var err := DirAccess.make_dir_recursive_absolute(dir)
	if err != OK:
		push_error("无法创建玩家数据目录 %s（错误码 %d）" % [dir, err])
		return false
	return true

###########################################################
#  取值范围
###########################################################

## 把某个数值设置夹到它的合法范围内。
##
## 手改过 settings.cfg、或将来设置界面传进越界值时靠它兜底。
## 查不到的键原样返回 —— 那说明它不是数值型设置，或者调用方写错了名字，
## 两种都不该在这里被悄悄改值
static func clamp_value(setting_name: String, value: float) -> float:
	var ranges := _ranges()
	if not ranges.has(setting_name):
		return value
	var limit: Vector2 = ranges[setting_name]
	return clampf(value, limit.x, limit.y)

## 现拼一张完整的范围表：作品配置里的 setting_ranges，加上各路音量。
##
## 音量不逐条列在作品配置里是有意的 —— 那样加一路音量就得记得回来补一行，
## 而漏掉的那行不会有任何报错，只会让那一路的音量滑块没有范围约束
static func _ranges() -> Dictionary:
	var settings := VNSettings.get_current()
	var out: Dictionary = settings.setting_ranges.duplicate()
	for mixer in settings.volume_buses:
		out[VOLUME_KEY_PREFIX + mixer] = settings.volume_range
	return out

###########################################################
#  配置读写
###########################################################

## 读配置。
## 两处都读不到说明是首次运行：沿用默认值，并立刻写出一份。
## 这样开发时能直接在编辑器里打开它改值，不必等设置界面做好；
## 手删掉文件也能当"恢复默认设置"用。
##
## 数值项都过一遍 clamp_value()：这个文件是留给人手改的，
## 越界值（比如把间隔写成 999）在这里就挡掉，
## 不必让每个用它的地方自己防一遍
func load_config() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(config_path()) != OK and cfg.load(fallback_path()) != OK:
		save_config()
		return

	voice_sustain = bool(cfg.get_value(SECTION, "voice_sustain", false))
	auto_forward_time = int(clamp_value("auto_forward_time",
		float(cfg.get_value(SECTION, "auto_forward_time",
			DEFAULT_AUTO_FORWARD_TIME))))
	wait_voice = bool(cfg.get_value(SECTION, "wait_voice", true))
	skip_unseen = bool(cfg.get_value(SECTION, "skip_unseen", false))
	ctrl_force_skip = bool(cfg.get_value(SECTION, "ctrl_force_skip", true))
	var settings := VNSettings.get_current()

	# 打字速度。**初值**是作品配置里的 default_text_cps，不是 0 ——
	# cfg.get_value 的默认参数只在键缺失时生效，正好是"首次运行"那一刻
	text_cps = int(clamp_value("text_cps",
		float(cfg.get_value(SECTION, "text_cps", settings.default_text_cps))))
	window_alpha = clamp_value("window_alpha",
		float(cfg.get_value(SECTION, "window_alpha", DEFAULT_WINDOW_ALPHA)))
	mouse_hide_time = maxf(
		float(cfg.get_value(SECTION, "mouse_hide_time", DEFAULT_MOUSE_HIDE_TIME)),
		0.0)
	qm_auto_hide = bool(cfg.get_value(SECTION, "qm_auto_hide", DEFAULT_QM_AUTO_HIDE))
	dialog_font = String(cfg.get_value(SECTION, "dialog_font", ""))

	# 窗口。宽高分开存两个 int 而不是一个 Vector2i —— 这个文件是留给人
	# 手改的，两行数字比 Vector2i(1920, 1080) 好认得多
	fullscreen = bool(cfg.get_value(SECTION, "fullscreen", DEFAULT_FULLSCREEN))
	window_size = Vector2i(
		int(cfg.get_value(SECTION, "window_width", 0)),
		int(cfg.get_value(SECTION, "window_height", 0)))

	# 先清空再铺：作品配置有可能删掉一路音量，残留的键虽然没人会查，
	# 但 save_config() 会按 volumes 全量写回，等于把它又写进文件里
	volumes.clear()
	for mixer in settings.volume_buses:
		var key := VOLUME_KEY_PREFIX + String(mixer)
		volumes[mixer] = clamp_value(key, float(cfg.get_value(SECTION, key, 1.0)))

## 写配置。主路径写不进去时退回备用路径
func save_config() -> bool:
	var cfg := ConfigFile.new()
	cfg.set_value(SECTION, "voice_sustain", voice_sustain)
	cfg.set_value(SECTION, "auto_forward_time", auto_forward_time)
	cfg.set_value(SECTION, "wait_voice", wait_voice)
	cfg.set_value(SECTION, "skip_unseen", skip_unseen)
	cfg.set_value(SECTION, "ctrl_force_skip", ctrl_force_skip)
	cfg.set_value(SECTION, "text_cps", text_cps)
	cfg.set_value(SECTION, "window_alpha", window_alpha)
	cfg.set_value(SECTION, "mouse_hide_time", mouse_hide_time)
	cfg.set_value(SECTION, "qm_auto_hide", qm_auto_hide)
	cfg.set_value(SECTION, "dialog_font", dialog_font)
	cfg.set_value(SECTION, "fullscreen", fullscreen)
	cfg.set_value(SECTION, "window_width", window_size.x)
	cfg.set_value(SECTION, "window_height", window_size.y)
	for mixer in VNSettings.get_current().volume_buses:
		cfg.set_value(SECTION, VOLUME_KEY_PREFIX + mixer, volume_of(mixer))

	if ensure_data_dir() and cfg.save(config_path()) == OK:
		return true

	var err := cfg.save(fallback_path())
	if err != OK:
		push_error("配置写入失败：%s（错误码 %d）" % [config_path(), err])
		return false
	push_warning("玩家数据目录不可写，配置已改存 %s" % fallback_path())
	return true

###########################################################
#  已读记录
###########################################################

## 这条语句读过没有
func is_seen(sid: int) -> bool:
	return _seen.has(sid)

## 标记一条语句已读。写盘由节流控制，见 _flush_seen()
func mark_seen(sid: int) -> void:
	if _seen.has(sid):
		return
	_seen[sid] = true
	_seen_dirty = true
	_flush_seen()

## 读已读记录。文件不存在就当全都没读过 —— 首次运行就是这样，不是错误
func load_seen() -> void:
	_seen.clear()
	_seen_dirty = false

	var path := seen_path()
	if not FileAccess.file_exists(path):
		# 主目录里没有时也看一眼备用位置
		path = "user://" + SEEN_FILE_NAME
		if not FileAccess.file_exists(path):
			return

	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_warning("已读记录读取失败：%s" % path)
		return

	var data: Variant = file.get_var()
	file.close()

	# 存的是 sid 数组，不是字典 —— 键在这个场景里恒为 true，没有信息量，
	# 拍扁成数组能让文件小一大截
	if data is PackedInt64Array:
		for sid in data:
			_seen[int(sid)] = true

## 把已读记录写盘。
##
## 剧情结束、回主菜单这类节点该直接调它，别等节流 ——
## 节流是给快进时的高频标记准备的，不是给收尾用的
func save_seen() -> bool:
	_seen_saved_ms = Time.get_ticks_msec()
	if not _seen_dirty:
		return true

	var sids := PackedInt64Array()
	sids.resize(_seen.size())
	var i := 0
	for sid in _seen:
		sids[i] = int(sid)
		i += 1

	if _write_seen(seen_path(), sids) != OK:
		# 主目录不可写时退回备用位置，和 settings.cfg 一个策略
		if _write_seen("user://" + SEEN_FILE_NAME, sids) != OK:
			push_error("已读记录写入失败：%s" % seen_path())
			return false
		push_warning("玩家数据目录不可写，已读记录已改存 %s"
			% ("user://" + SEEN_FILE_NAME))

	_seen_dirty = false
	return true

## 写一份已读记录到指定路径，返回 Godot 的错误码
func _write_seen(path: String, sids: PackedInt64Array) -> int:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_var(sids)
	file.close()
	return OK

## 按间隔把已读记录落盘。mark_seen() 每次都叫它，
## 但只有距上次写盘够久才真的写
func _flush_seen() -> void:
	if Time.get_ticks_msec() - _seen_saved_ms < SEEN_SAVE_INTERVAL_MS:
		return
	save_seen()

###########################################################
#  看过的图像
###########################################################

## 这张图看过没有。CG 鉴赏靠它决定显示缩略图还是锁定图。
##
## 判据是"它作为舞台上的图像显示过至少一次" —— 对应 Ren'Py 的
## renpy.seen_image()。不看剧情进度，也不看存档：跨存档全局有效
func is_image_seen(id: String) -> bool:
	return _seen_images.has(id)

## 标记一张图已经显示过。写盘同样走节流 —— 快进时一秒会闪过好几张图，
## 逐张写盘和逐句写盘是同一个问题
func mark_image_seen(id: String) -> void:
	if id.is_empty() or _seen_images.has(id):
		return
	_seen_images[id] = true
	_seen_images_dirty = true
	_flush_seen_images()

## 读看过的图像。文件不存在就当一张都没看过 —— 首次运行就是这样，不是错误
func load_seen_images() -> void:
	_seen_images.clear()
	_seen_images_dirty = false

	var path := images_path()
	if not FileAccess.file_exists(path):
		path = "user://" + IMAGES_FILE_NAME
		if not FileAccess.file_exists(path):
			return

	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_warning("图像记录读取失败：%s" % path)
		return

	var data: Variant = file.get_var()
	file.close()

	# 存的是 id 数组，不是字典 —— 键恒为 true，没有信息量
	if data is PackedStringArray:
		for id in data:
			_seen_images[String(id)] = true

## 把看过的图像写盘。
##
## 剧情结束、回主菜单这类收尾节点该直接调它，理由同 save_seen()
func save_seen_images() -> bool:
	_seen_images_saved_ms = Time.get_ticks_msec()
	if not _seen_images_dirty:
		return true

	var ids := PackedStringArray()
	ids.resize(_seen_images.size())
	var i := 0
	for id in _seen_images:
		ids[i] = String(id)
		i += 1

	if _write_seen_images(images_path(), ids) != OK:
		if _write_seen_images("user://" + IMAGES_FILE_NAME, ids) != OK:
			push_error("图像记录写入失败：%s" % images_path())
			return false
		push_warning("玩家数据目录不可写，图像记录已改存 %s"
			% ("user://" + IMAGES_FILE_NAME))

	_seen_images_dirty = false
	return true

## 写一份图像记录到指定路径，返回 Godot 的错误码
func _write_seen_images(path: String, ids: PackedStringArray) -> int:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_var(ids)
	file.close()
	return OK

## 按间隔把图像记录落盘
func _flush_seen_images() -> void:
	if Time.get_ticks_msec() - _seen_images_saved_ms < SEEN_SAVE_INTERVAL_MS:
		return
	save_seen_images()

###########################################################
#  音量应用
###########################################################

## 取一路音量。mixer 不在配置表里时返回满音量并警告 ——
## 静默返回 1.0 会让"名字写错"表现为"这一路音量调不动"
func volume_of(mixer: String) -> float:
	if volumes.has(mixer):
		return float(volumes[mixer])
	push_warning("音量：没有这一路 mixer，按满音量处理：%s" % mixer)
	return 1.0

## 设置一路音量，越界值会被夹到范围内
func set_volume(mixer: String, value: float) -> void:
	volumes[mixer] = clamp_value(VOLUME_KEY_PREFIX + mixer, value)

## 把配置里的音量全部应用到音频总线。
## 有哪几路查作品配置；总线名对不上只警告不中断 ——
## 少一条总线不该让游戏起不来
func apply_audio() -> void:
	var settings := VNSettings.get_current()
	for mixer in settings.volume_buses:
		_apply_bus(settings.volume_buses[mixer], VOLUME_KEY_PREFIX + mixer,
			volume_of(mixer))

## 把一路音量写到指定总线上。
##
## 范围不写死成 0–1，而是查 RANGES —— 那样换项目要放宽音量跨度时
## 只改表里的数，这里一个字都不用动
func _apply_bus(bus_name: StringName, setting_name: String, value: float) -> void:
	var idx := AudioServer.get_bus_index(bus_name)
	if idx < 0:
		push_warning("音频总线不存在，音量设置被忽略：%s" % bus_name)
		return
	AudioServer.set_bus_volume_linear(idx, clamp_value(setting_name, value))

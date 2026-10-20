class_name VNSettings
extends RefCounted

# ═══════════════════════════════════════════════════════════
#  作品配置的框架默认值。
#
#  ── 这是什么 ──
#  "换一部作品就该变"的那些值的**默认值**：存档缩略图多大、历史留几条、
#  音量分几路……项目层继承本类、在自己的 _init() 里给要改的项重新赋值
#  即可覆盖，其余全部沿用这里。
#
#  这套分层与 Ren'Py 一致：引擎的 config.py 给出 config.thumbnail_width
#  = 256、config.movie_mixer = "music" 这些默认值，作品用 define 覆盖它们。
#  区别只是 GDScript 用继承 + 赋值，Ren'Py 用 define。
#
#  ── 和 VNConfig 的分工 ──
#    VNSettings（本文件） 设计时的作品取舍。作者改，玩家看不到
#    VNConfig             运行时的玩家偏好。玩家改，存在 settings.cfg
#  两者会碰头：VNConfig 里某个偏好的**初值**取本文件的对应项，例如
#  text_cps 的初值就是 default_text_cps。玩家一旦改过就以玩家存的为准
#  —— 与 Ren'Py 的 config.default_text_cps 是同一条规则。
#
#  ── 项目层怎么覆盖 ──
#  在 content/vn_settings.gd 里 extends 本类，然后在 _init() 里赋值：
#      func _init() -> void:
#          thumb_size = Vector2i(1920, 1080)
#  那份文件**可以不建** —— 不建就是完全沿用这里，新项目复制 vn/ 过去
#  零配置就能跑。
#
#  注意：GDScript 不允许子类重新声明父类的成员变量（会报 already exists
#  in parent class），所以覆盖只能发生在 _init() 里赋值，不能写
#  `var thumb_size := ...`。
#
#  ── 为什么是 var 不是 const ──
#  const 是编译期常量，子类改不了，也就没有"框架给默认值、作品覆盖"这回
#  事。代价是这些值不能再用在常量上下文（例如拿去初始化另一个 const）。
#
#  ── 每个值都标了它在 Ren'Py 里的出处 ──
#  标出来不是为了考据，是为了下次想改时能立刻查到 Ren'Py 那边的语义
#  （比如 history_length 的 None 到底是什么意思），不必反推
# ═══════════════════════════════════════════════════════════

## 项目层覆盖文件的约定路径。
##
## 用**运行期** load 而不是 preload 是有意的：preload 要求文件必须存在，
## 而"项目层不建这份文件"是合法状态（完全沿用框架默认值）。代价是路径
## 写错不会在编译期被拦下来，所以 load_project_settings() 对加载失败和
## 类型不对都留了 push_error
const PROJECT_SCRIPT := "res://content/vn_settings.gd"

## 当前生效的作品配置。null 表示还没人设过 —— 读的地方一律走 get_current()。
##
## 不写成 `= VNSettings.new()` 的初始化式：static var 的初始化式里
## 构造自身实例是个容易踩坑的写法（求值时机在类注册过程中），
## 惰性初始化没有这个风险，代价只是一次判空
static var _current: VNSettings = null

###########################################################
#  窗口与显示
###########################################################

## 设置界面"窗口大小"那四个按钮对应的档位，**顺序即界面顺序**。
##
## Vector2i.ZERO 表示全屏，其余是窗口模式下的**标称**客户区尺寸。
## 标称不等于实际：屏幕装不下时，VNDisplay.actual_size() 会按这个尺寸
## 自己的比例等比缩到能装下，按钮上写的也是那个实际值。
##
## 窗口档必须和 viewport 同宽高比（2560x1440 = 16:9）—— 比例一旦对不上，
## stretch 的 aspect=keep 就会补黑边。加档位时注意这一点
var display_modes: Array[Vector2i] = [
	Vector2i.ZERO,
	Vector2i(2560, 1440),
	Vector2i(1920, 1080),
	Vector2i(1600, 900),
]

###########################################################
#  存档
###########################################################

## 存档缩略图的尺寸，**盘上只存这一份**。
##
## 对应原项目 gui.rpy 的 config.thumbnail_width = 924 / thumbnail_height = 520
## （Ren'Py 自己的默认值是 256x144，原项目显式改了它）。
## 换句话说：**这个值带着作品印记**，换项目时优先考虑移回覆盖文件。
##
## 数值不是随手定的：要能被显示端按 0.49 缩到 453x255 正好铺满槽网格，
## 同时悬停大预览直接用它本身。改这里的话 slot_thumb_size 也得跟着改
var thumb_size := Vector2i(924, 520)

## 槽网格里缩略图的显示尺寸。原项目给截图挂的是 zoom 0.49
## （924 * 0.49 ≈ 453，520 * 0.49 ≈ 255）。同样带着作品印记。
##
## 这个值同时是界面侧缩放的目标尺寸：往磁盘上不存小图，但要在一开始
## 就把它缩到这个尺寸再建纹理 —— 50 张 924x520 全留在显存里要近百 MB
var slot_thumb_size := Vector2i(453, 255)

## 手动存档槽的数量，即界面上的 NO.01 到 NO.50。
##
## 对应原项目 save_load.rpy 里的 for i in range(50)。Ren'Py 引擎侧并不
## 限制这个数 —— FileSlotName(slot, slots_per_page) 的 slots_per_page
## 是个**参数**，多少由作品定。这里同理
var slot_count := 50

###########################################################
#  历史与玩家数据
###########################################################

## 对话历史最多留多少条。超了从**最旧**的一端丢 —— 玩家关心的是刚说过的话。
##
## 对应原项目 gui.rpy 的 config.history_length = 250。
##
## 顺带记一笔 Ren'Py 那边的语义：它的默认值是 None，而 None 的含义是
## **根本不记录历史**。也就是说这个值必须由作品显式给出，
## 没有"引擎替你兜底"这回事
var history_length := 250

## 玩家数据目录名（settings.cfg / seen.dat / 存档都放它下面）。
## 对应 Ren'Py 的 config.savedir，原项目 options.rpy 里那个是 None
##
## 它只是**目录名**，不是路径 —— 挂在哪儿由 VNConfig.data_dir() 决定：
## 开发期是项目根下的一级目录，桌面发布版是可执行文件同级的一级目录，
## 移动端与 Web 是 user:// 下的一级目录
var data_dir := "saves"

## 剧本包的路径。
##
## 放进这一层而不是写死在框架里：它是"框架使用者按自己的文件组织
## 方式摆放的东西"，和上面的 data_dir 同类。想挪到 res://story/ 或
## res://data/ 下都行，只要和编译时的输出位置一致 ——
## vn/dev/compiler.gd 读的是同一个值
var package_path := "res://content/story.vnbc"

###########################################################
#  音频
###########################################################

## 音量分几路：偏好键名 → 音频总线名。
##
## 键名拼上 "volume_" 前缀就是设置的键名（music → volume_music）。
## 值必须和 default_bus_layout.tres 里的总线名逐字一致，对不上会在应用
## 音量时警告而不是崩 —— 少一条总线不该让游戏起不来。
##
## Ren'Py 那边这一层是**运行时注册**的（register_channel("sys",
## mixer="system_sound")），有哪几路 mixer 由作品决定，原项目就自己注册了
## 第四路 system_sound。这里用一张表达到同样效果：加一路只加一行，
## VNConfig 的读写、范围、应用全按表走，不必记得改三处。
##
## 第一项 "main" 和其余四项不是一回事：它对应 Ren'Py 的
## Preference("main volume")，也就是 **master mixer**，是其余几路的总闸。
## 原项目的声音设定页第一条就是它，摆在最前面
var volume_buses := {
	"main": &"Master",
	"music": &"Music",
	"sound": &"Sound",
	"system": &"System",
	"voice": &"Voice",
}

## 各路音量的取值范围。所有路共用 —— 单独放宽某一路的需求目前没有
var volume_range := Vector2(0.0, 1.0)

## 音频淡出与换曲的默认时长，单位秒。对应 Ren'Py 的 config.fadeout_audio。
##
## play music 不写 fadeout 时，旧曲按这个时长淡出、新曲同时淡入；
## stop music 同理。音频语句里显式写了 fadeout 就按写的来，0 是合法的瞬切。
##
## play sound 不用它 —— 音效都很短，等一秒淡出只会和下一声叠在一起，
## 那边默认 0（新声直接顶掉旧的）。要淡出得显式写 fadeout。
##
## 原项目把它设成了 1.0（subsidiary/config.rpy 的 config.fadeout_audio），
## 这里对齐；Ren'Py 自己的出厂值是 0.016（约一帧，等于瞬切）
var audio_fadeout_time := 1.0

## 视频音所在的总线。视频是"演出一部分"，跟着音乐走 ——
## 它不该混进 sound（演出音效），也不该挂在 system（界面音）上
var video_bus := &"Music"

## 界面音所在的总线。按钮的按下音、悬停音走它。
## 单列一条，玩家才能单独调界面音的音量
var ui_bus := &"System"

## 按钮的默认音效路径。**框架层默认为空** ——
## 框架不知道该给按钮配什么声音，那是作品的选型。
## 作品层在 content/vn_settings.gd 里填，和 thumb_size 那批同一条路。
##
## 空串 = 不播。单个按钮可以覆盖，见 VNButton.activate_sound 的说明
var button_activate_sound := ""
var button_hover_sound := ""

###########################################################
#  文本
###########################################################

## 打字机速度，单位是字符/秒。**0 表示不打字机、整句立刻显示。**
##
## 对应 Ren'Py 的 config.default_text_cps：它只是**首次运行时的初值**，
## 玩家在设置里调过之后就以玩家存的为准（那边叫 preferences.text_cps）。
##
## Ren'Py 的 preferences.text_cps 默认是 0，也就是默认瞬间显示全文。
## 这里的 25 是本项目的选择，想要和 Ren'Py 一致就改成 0。
## 这个值同样带着作品印记，换项目时优先考虑移回覆盖文件
var default_text_cps := 25

## 文案字体表。每项是 { name, path, offset_y, line_spacing }：
##   name          设置页按钮上的字
##   path          字体文件
##   offset_y      正文块顶部相对对话框底图（Textbox）顶部的偏移
##   line_spacing  额外行距，对应 RichTextLabel 的 line_separation
##
## ── 为什么三个排版参数要跟字体绑在一起 ──
## 不同字体的字形高度和基线不一样，同一个 y 偏移套上去有的偏上、有的压底，
## 行距同理（楷体的字形更"散"，行距小了会挤成一团）。原项目
## say.rpy:51-64 就是每种字体单独写一份 ypos 和 line_spacing。
##
## 拆成两张表只会让它们慢慢漂移：加了字体忘了补排版参数，表现是
## "选中某个字体之后正文位置错了"，而那种错不会报任何警
##
## offset_y 的来历：原项目用的是 1440 高屏幕上的绝对 ypos
## （圆体 1155 / 楷体 1165 / 宋黑 1150），而对话框底图顶部在 1039，
## 相减即得
##
## 这个值带着作品印记，换项目时优先考虑移回覆盖文件
var dialog_fonts: Array[Dictionary] = [
	{
		"name": "圆体",
		"path": "res://content/ui/fonts/AlibabaHealthFont20CN_45R.ttf",
		"offset_y": 116.0,
		"line_spacing": 20,
	},
	{
		"name": "楷体",
		"path": "res://content/ui/fonts/FounderKaitiSimplifiedChinese.ttf",
		"offset_y": 126.0,
		"line_spacing": 30,
	},
	{
		"name": "宋体",
		"path": "res://content/ui/fonts/SourceHanSerif_SemiBold.otf",
		"offset_y": 111.0,
		"line_spacing": 10,
	},
	{
		"name": "黑体",
		"path": "res://content/ui/fonts/SourceHanSansCNRegular.otf",
		"offset_y": 111.0,
		"line_spacing": 10,
	},
]

## 按路径查字体表项。查不到返回空字典 ——
## 调用方据此判断"这个路径不在表里"，而不是拿一份默认排版继续跑
func dialog_font_spec(path: String) -> Dictionary:
	for entry in dialog_fonts:
		if String(entry.get("path", "")) == path:
			return entry
	return {}

###########################################################
#  界面转场
###########################################################

## 总开关。关掉后所有转场瞬时完成，调用方逻辑不变
var transition_enabled := true

## 剧情 → 游戏菜单。对应原项目 config.enter_transition = dissolve（0.5s）
var menu_enter_time := 0.25

## 游戏菜单 → 剧情。对应原项目 config.exit_transition = dissolve（0.5s）
var menu_exit_time := 0.25

## 菜单内部切页。对应原项目 config.intra_transition = Dissolve(0.25)
var menu_intra_time := 0.25

## 主菜单黑场。对应原项目 black_t = Fade(1.0, 0.0, 1.0)
var fade_out_time := 1.0
var fade_hold_time := 0.0
var fade_in_time := 1.0

## 启动时从黑场淡入主菜单的时长
var boot_fade_time := 1.0

## 转场中一次抬起是否立即跳到终态。对应 Ren'Py 的 dismiss_blocking_transitions
var transition_skippable := true

## 对话窗口的自动显隐。对应原项目的 config.window = "auto"：
## say 显示窗口、scene 隐藏窗口，window show / window hide 可手动接管
var window_auto := true

## 窗口显示 / 隐藏的时长。对应原项目
## config.window_show_transition = Dissolve(.2) 与 window_hide_transition
var window_show_time := 0.2
var window_hide_time := 0.2

###########################################################
#  剧本转场（with）
#
#  剧本里 with dissolve / with fade 不带参数时用这里的值。
#  参数写在剧本里时覆盖它们，两边不冲突
###########################################################

## with dissolve 的默认时长。对应 Ren'Py 的 define dissolve = Dissolve(0.5)
var stage_dissolve_time := 0.5

## with fade 的三个时间：淡到中间画面、停留、从中间画面淡出。
## 对应 Ren'Py 的 define fade = Fade(.5, 0, .5)
var stage_fade_out_time := 0.5
var stage_fade_hold_time := 0.0
var stage_fade_in_time := 0.5

## with fade 的中间画面颜色。Ren'Py 的 Fade 也只接受纯色，默认黑场
var stage_fade_color := Color.BLACK

###########################################################
#  数值型偏好的范围
###########################################################

## 数值型玩家偏好的取值范围：偏好键名 → Vector2(下限, 上限)。
##
## 对应 Ren'Py 里"设置界面滑块的范围由作品定"这件事。范围是项目级的取舍
## —— 节奏要多快、音量跨多大，不同作品答案不同，所以集中放这一处。
##
## 设置界面做滑块时按名字来查，不自己写死数字；写入端也一律过
## VNConfig.clamp_value()，让范围只有这一个定义点。
##
## 各路音量的范围**不列在这里** —— 它们由 volume_buses + volume_range
## 拼出来，这样加一路音量不必记得回来补一行
##
## text_cps 的上限 200 来自 Ren'Py：它给 "text speed" 那条 bar 的默认范围
## 就是 0–200 cps（00preferences.rpy 里 bar_range 的默认值）。0 是合法的，
## 含义是"不打字机、整句立刻显示"
##
## window_alpha 的 0.7–1.0 来自原项目 preferences.rpy 那条 bar 的 min/max。
## 再低底图就和背景糊成一片了，对话框会看不出边界
var setting_ranges := {
	"auto_forward_time": Vector2(0.0, 30.0),
	"text_cps": Vector2(0.0, 200.0),
	"window_alpha": Vector2(0.7, 1.0),
}

###########################################################
#  加载
###########################################################

## 取当前生效的作品配置。
##
## 没人调过 load_project_settings() 时（测试脚本直接用 VNSave、工具脚本
## 单独跑），这里现造一份框架默认值并记住 —— 所以读它的地方不必关心
## "加载过没有"，也不必自己判空
static func get_current() -> VNSettings:
	if _current == null:
		_current = VNSettings.new()
	return _current

## 读项目层的覆盖文件，替换当前配置。
##
## 在 VNFrame._ready() 的**最前面**调用 —— 它必须早于任何读配置的人，
## 尤其是 VNConfig.ensure_data_dir()：数据目录名就来自这里。
##
## 文件不存在**不是错误**：那表示这个项目完全沿用框架默认值，是合法状态
## （新项目复制 vn/ 过去就是这样）。真正要报警的是"文件在但内容不对"
static func load_project_settings() -> void:
	if not ResourceLoader.exists(PROJECT_SCRIPT):
		return

	var script: Variant = load(PROJECT_SCRIPT)
	if not (script is GDScript):
		push_error("作品配置加载失败（不是脚本）：%s" % PROJECT_SCRIPT)
		return

	var instance: Variant = (script as GDScript).new()
	if not (instance is VNSettings):
		push_error("作品配置必须继承 VNSettings，已忽略：%s" % PROJECT_SCRIPT)
		return

	_current = instance

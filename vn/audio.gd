class_name VNAudio
extends Node

# ═══════════════════════════════════════════════════════════
#  音频。语音、背景音乐、剧情音效、界面音四条路。
#
#  ── 为什么值得单独一个类 ──
#  这四样和剧情执行**没有任何关系**：播放器只管"把这条流推给音频服务器"，
#  不知道 segment 走到哪、不知道当前 label 是什么。原来它们长在 VNPlayer 里，
#  于是循环修补、总线路由、单声道界面音这些纯音频知识
#  和执行控制流混在一个文件里。
#
#  ── 和 Ren'Py 的关系（说清楚，免得以为是照搬）──
#  Ren'Py **没有**这个类：它的音频通道是引擎初始化的产物，renpy.music /
#  renpy.sound 是模块级函数，同样扁平。所以这一层是我们自己的选择，不是移植。
#  选它的理由是它足够独立，而且踩过的坑（见 _configure_loop）值得有自己的落点。
#
#  ── 为什么不做成"音频通道表"这种通用结构 ──
#  四条路的语义差别是硬的：BGM 要判重、语音有属主、音效是打断式的、
#  界面音要活得比按钮久。抽成一张表之后，每加一路就得在表里塞一个 if，
#  反而比现在难读。
#
#  ── 两种"播放背景音乐" ──
#    play_bgm()    定位语义：同一首正在播就不动。读档恢复、回主菜单用它
#    play_music()  演出语义：play music 语句的落点，默认**重播**
#  分成两个方法而不是加一个参数：它们的调用方完全不同（一个是应用层的
#  状态恢复，一个是剧本指令），混在一起最容易出的错是"读档时音乐从头开始"
#
#  ── 语音属主不在这里 ──
#  谁在说话（_voice_owner）归 VNPlayer —— 本类只知道"有一条语音在播"，
#  不认识"角色"这个领域概念。语音自然播完时发 voice_finished 由它接手。
#
#  ── 创建方式 ──
#  由 VNFrame 在 _ready() 里 new 并 add_child。除了 VNSettings（只用来查
#  界面音总线名与淡出时长）之外不依赖任何东西，所以没有 setup()。
# ═══════════════════════════════════════════════════════════

## 语音与背景音乐所在的总线。
##
## 刻意写死而不是从 VNSettings 取：那边有 video_bus / ui_bus，没有
## voice_bus / music_bus —— 那两路是框架固定使用的，不构成作品层的选择。
## 总线的**条数**是作品层的（见 volume_buses），名字则要和
## default_bus_layout.tres 逐字一致。
##
## 注意别和 VNSettings.video_bus 共用：那个值也是 &"Music"，但语义是
## "视频音跟着音乐走"，是作品层的取舍。两者只是碰巧同值，不构成依赖
const VOICE_BUS := &"Voice"
const BGM_BUS := &"Music"

## 剧情音效总线。与界面音的总线刻意分开：一边是演出（门响、脚步），
## 一边是操作反馈（按钮音），玩家想单独关掉界面音时不该连剧情音效一起关
const SOUND_BUS := &"Sound"

###########################################################
#  交叉淡化
###########################################################

## 一对轮流使用的播放器，外加两条淡入淡出 tween。
##
## ── 为什么必须成对 ──
## Godot 的 AudioStreamPlayer 没法把"正在播的流"交给另一个播放器
## （那样会从头开始），所以交叉淡化只能在播放时就交替使用两个播放器：
## 上一次的主播放器天然就是这一次的旧曲播放器，它带着原来的播放位置
## 继续把淡出跑完。
##
## ── 为什么是内部类 ──
## 音乐与音效的淡化行为完全一样，差别只在"哪条总线、要不要记路径"，
## 那些留在 VNAudio 里。写两份的话，以后修淡化相关的 bug 得记得改两处。
class Crossfade:
	## 静音下限。tween 的目标值不能是 -INF ——
	## linear_to_db(0) 返回 -inf，那个值会把属性永久钉死，
	## 之后既没法插值也没法比较
	const SILENT_DB := -80.0

	## 宿主节点。create_tween() 挂在它身上 —— tween 随宿主释放自动作废
	var host: Node = null
	## 下一次播放用的播放器
	var current: AudioStreamPlayer = null
	## 上一次的播放器，只在淡出期间有意义
	var previous: AudioStreamPlayer = null
	## current 的淡入。只可能有一条
	var fade_in: Tween = null
	## previous 的淡出，或者 current 的停止淡出。两者互斥，因为都发生在
	## "正在结束一段声音"的时候
	var fade_out: Tween = null

	## 建一对播放器。两个都必须已经挂在场景树上
	func _init(p_host: Node, p_current: AudioStreamPlayer,
			p_previous: AudioStreamPlayer) -> void:
		host = p_host
		current = p_current
		previous = p_previous

	## 线性音量倍率 → 分贝。0 走静音下限而不是 -INF，理由见 SILENT_DB
	static func db_for(volume: float) -> float:
		if volume <= 0.0:
			return SILENT_DB
		return linear_to_db(volume)

	## 把正在播的那一首挪到淡出位，把 current 让给下一首。
	##
	## 调用方紧接着调 start() —— 中间不要插别的东西：挪完而没起新的那一段时间里，
	## current 是空的、previous 在淡出，状态是"过渡中"而不是任何稳定态
	func retire(fadeout: float) -> void:
		kill()
		# 上一轮的旧曲可能还挂着淡出。它已经没有继续的必要
		if previous.playing:
			previous.stop()
		previous.volume_db = 0.0

		if not current.playing:
			return

		var retired := current
		current = previous
		previous = retired

		if fadeout <= 0.0:
			previous.stop()
			previous.volume_db = 0.0
			return

		fade_out = host.create_tween()
		fade_out.tween_property(previous, "volume_db", SILENT_DB, fadeout)
		fade_out.tween_callback(_on_retired)

	## 在 current 上起一条新流。fadein > 0 时从静音升到 volume。
	##
	## **只杀淡入，不杀淡出** —— 淡出跑的是 previous，那是退休的那一首，
	## 它正该继续响到淡完。这里若把两条都杀掉，交叉淡化就退化成瞬切
	func start(stream: AudioStream, volume: float, fadein: float) -> void:
		if fade_in != null:
			fade_in.kill()
			fade_in = null

		var db := db_for(volume)
		current.stop()
		current.stream = stream
		current.volume_db = SILENT_DB if fadein > 0.0 else db
		current.play()

		if fadein <= 0.0:
			return
		fade_in = host.create_tween()
		fade_in.tween_property(current, "volume_db", db, fadein)

	## 让 current 淡出到停止。stop music / stop sound 用它
	func fade_out_and_stop(fadeout: float) -> void:
		kill()
		if previous.playing:
			previous.stop()
		previous.volume_db = 0.0

		if not current.playing:
			current.volume_db = 0.0
			return

		if fadeout <= 0.0:
			current.stop()
			current.volume_db = 0.0
			return

		fade_out = host.create_tween()
		fade_out.tween_property(current, "volume_db", SILENT_DB, fadeout)
		fade_out.tween_callback(_on_stopped)

	## 立刻全停，不留淡出。定位式操作（读档、回主菜单、结束一局）用它 ——
	## 那些时刻画面已经换过了，再让上一段音乐淡一秒是明显的破绽
	func stop_now() -> void:
		kill()
		current.stop()
		current.volume_db = 0.0
		previous.stop()
		previous.volume_db = 0.0

	## current 是否在播。注意不含 previous：退休中的那一首不算"在播"
	func is_playing() -> bool:
		return current.playing

	## 杀掉两条 tween。任何一次状态切换前都必须先做，
	## 否则旧 tween 会在新状态上继续写 volume_db
	func kill() -> void:
		if fade_in != null:
			fade_in.kill()
			fade_in = null
		if fade_out != null:
			fade_out.kill()
			fade_out = null

	## 退休的那一首淡完了：停掉它并复位，让它在下一轮交换时直接可用
	func _on_retired() -> void:
		fade_out = null
		previous.stop()
		previous.volume_db = 0.0

	## stop 的淡出走完了：停掉主播放器
	func _on_stopped() -> void:
		fade_out = null
		current.stop()
		current.volume_db = 0.0

###########################################################
#  成员
###########################################################

## 背景音乐的交叉淡化对。必须在 _ready() 里建好，不做惰性创建 ——
## 主菜单一开场就要有音乐，而"还没播过任何音乐"才是启动时的常态，
## 惰性那一套在 BGM 上省不下任何东西
var _bgm: Crossfade = null
## 剧情音效的交叉淡化对。惰性创建 —— 有的作品一条音效都没有
var _sound: Crossfade = null
## 语音播放器。语音不需要淡化，也不需要同时播两条
var _voice: AudioStreamPlayer = null
## 界面音播放器。**惰性创建** —— 界面音可能整部作品都不用
var _ui_sound: AudioStreamPlayer = null

## 当前 BGM 的路径，用来判断"是不是同一首"。空串表示没有音乐在播
var _bgm_path := ""

## 界面音所在的总线名。在 _init() 里就地取作品配置。
##
## 不能写成 const：总线名来自 VNSettings 的实例字段，实例字段进不了
## 常量上下文。也不能等 _ready() —— 那时 VNFrame 可能已经要播音了
var _ui_bus := &"Master"

###########################################################
#  信号
###########################################################

## 语音**自然播完**。
##
## 主动 stop() **不会**发这条 —— 与 AudioStreamPlayer.finished 的行为一致
## （文档原话："This signal is not emitted when calling stop()"）。
## 所以 VNPlayer 那侧要维护的语音属主有两条清理路径：接这条信号，
## 以及自己调 stop_voice() 时随手清掉
signal voice_finished()

###########################################################
#  生命周期
###########################################################

## 铺界面音总线名，然后建两个常驻播放器
func _init() -> void:
	_ui_bus = VNSettings.get_current().ui_bus

## 建语音播放器与 BGM 的播放器对。
##
## 此刻才建而不是在 _init() 里：add_child 要求本节点先有树内身份，
## 而 _init() 阶段它还不属于任何场景
func _ready() -> void:
	_voice = _make_player(VOICE_BUS)
	# 语音自然播完这条路在这里转发出去，见 voice_finished 的说明
	_voice.finished.connect(func() -> void: voice_finished.emit())

	_bgm = Crossfade.new(self, _make_player(BGM_BUS), _make_player(BGM_BUS))

## 建一个挂在指定总线上的播放器并纳入本节点
func _make_player(bus: StringName) -> AudioStreamPlayer:
	var player := AudioStreamPlayer.new()
	player.bus = bus
	add_child(player)
	return player

## 确保音效的一对播放器在。第一条 play sound 进来时才建
func _ensure_sound() -> void:
	if _sound != null:
		return
	_sound = Crossfade.new(self, _make_player(SOUND_BUS), _make_player(SOUND_BUS))

###########################################################
#  背景音乐
###########################################################

## 暂停 / 恢复背景音乐。
##
## 用于"临时把声音让出去"的场合：CG 鉴赏播视频时，视频音轨和 BGM 同在
## Music 总线上，没法只静音其中一者。这里从播放器这一层停 —— 用
## stream_paused 而不是 stop，恢复时接着原处放，不会从头开始。
##
## previous 也要一起处理：交叉淡化期间两个播放器都在响，只暂停 current
## 会让正在淡出的那一首继续露出来
func pause_bgm(paused: bool) -> void:
	if _bgm == null:
		return
	_bgm.current.stream_paused = paused
	_bgm.previous.stream_paused = paused

## 播放背景音乐，**同一首正在播就不动**。
##
## 这是"定位"语义而不是"演出"语义：读档恢复、回主菜单、章节往返都希望
## 音乐连续，不该因为重新进入同一个场景就从头放。剧本里的 play music
## 走 play_music()，那边默认重播 —— 两边的差别正是 Ren'Py 用 if_changed
## 显式区分的那件事，只是各给了它一个默认值。
##
## 返回是否**真的换了一首**：已经播着同一首时返回 false。调用方一般不需要
## 这个返回值，它是留给"想在音乐真的变了的时候做点什么"的场合
func play_bgm(path: String) -> bool:
	if _bgm == null:
		return false
	if _bgm.is_playing() and _bgm_path == path:
		return false

	if not ResourceLoader.exists(path):
		push_warning("背景音乐缺失：%s" % path)
		return false

	var stream := load(path)
	if not (stream is AudioStream):
		return false

	_configure_loop(stream, true)

	# 瞬切。定位式操作不该有淡出 —— 读档时先静一秒是明显的破绽。
	# 音量复位成 1.0：上一次 play music 可能带着 volume 0.5，
	# 存档恢复不该继承那个相对音量
	_bgm.stop_now()
	_bgm.start(stream, 1.0, 0.0)
	_bgm_path = path
	return true

## 播放背景音乐（剧本语句 play music 的落点）。
##
## opts 由 VNPlayer 从指令参数解析而来，键与默认值：
##   fadein: float      0     淡入秒数
##   fadeout: float     -1    旧曲淡出秒数；负值 = 用作品配置的 audio_fadeout_time
##   volume: float      1.0   相对音量倍率
##   loop: int          -1    1 循环 / 0 不循环 / -1 用通道默认（音乐循环）
##   if_changed: bool   false 同一首正在播就不动它
##
## 为什么要收一个字典而不是五个参数：调用方是 VNPlayer，它手里就是
## 从 .vnbc 摊开的一堆字符串。让本类认识"args[3] 是音量"会把字节码的
## 布局渗进音频层，而音频层不该知道剧本包长什么样
func play_music(path: String, opts: Dictionary) -> void:
	if _bgm == null or path.is_empty():
		return

	if bool(opts.get("if_changed", false)) and _bgm.is_playing() and _bgm_path == path:
		return

	if not ResourceLoader.exists(path):
		push_warning("背景音乐缺失：%s" % path)
		return

	var stream := load(path)
	if not (stream is AudioStream):
		return

	var loop := int(opts.get("loop", -1))
	if loop < 0:
		loop = 1
	_configure_loop(stream, loop != 0)

	var fadeout := float(opts.get("fadeout", -1.0))
	if fadeout < 0.0:
		fadeout = VNSettings.get_current().audio_fadeout_time

	_bgm.retire(maxf(0.0, fadeout))
	_bgm.start(stream, maxf(0.0, float(opts.get("volume", 1.0))),
		maxf(0.0, float(opts.get("fadein", 0.0))))
	_bgm_path = path

## 停掉背景音乐（剧本语句 stop music 的落点）。
## fadeout 为负时用作品配置的 audio_fadeout_time
func stop_music(fadeout: float = -1.0) -> void:
	if _bgm == null:
		return
	if fadeout < 0.0:
		fadeout = VNSettings.get_current().audio_fadeout_time
	_bgm.fade_out_and_stop(maxf(0.0, fadeout))
	_bgm_path = ""

## 立刻停掉背景音乐，不留淡出。
##
## 与 stop_music() 的分工和 play_bgm / play_music 相同：这个是定位式的
## （回主菜单、结束一局），那个是剧本语句
func stop_bgm() -> void:
	if _bgm != null:
		_bgm.stop_now()
	_bgm_path = ""

## 当前正在播的 BGM 路径。空串表示没有音乐在播
func current_bgm() -> String:
	return _bgm_path

## BGM 是否正在播。
##
## 两种情况都**不算**在播：
##   · 正在淡出的那一首 —— 它已经不是"当前这一首"，只是还没淡完；
##   · 被 pause_bgm() 暂停的那一首 —— 播放器挂着 stream_paused 时
##     playing 仍然是 true，但这一刻没有声音出来。界面上任何"跟着音乐动"
##     的东西都该停住，否则会出现"音乐停了、画面还在跳"。
##
## 对应 Ren'Py 的 renpy.music.is_playing()
func is_bgm_playing() -> bool:
	if _bgm == null or not _bgm.is_playing():
		return false
	return not _bgm.current.stream_paused

## 当前 BGM 的播放位置（秒）。没有音乐在播时返回 0。
##
## 对应 Ren'Py 的 renpy.music.get_pos()。
##
## 这个值是**按音频回调的块长递增**的，不是逐采样的连续值：同一个值被
## 连续读到几十毫秒是正常现象。界面按帧刷新时不需要再补
## AudioServer.get_time_since_last_mix() —— 那是给"跟着音乐做精确演出"
## 用的，进度条差半个块（几毫秒）看不出来
func bgm_position() -> float:
	if not is_bgm_playing():
		return 0.0
	return _bgm.current.get_playback_position()

## 把当前 BGM 跳到某个位置（秒）。没有音乐在播时什么都不做。
##
## 对应 Ren'Py 播放串里的 "<from x>"。
##
## 跳之前先把淡出中的前一首先停掉：留着它的话，旧曲会从原来的位置继续
## 响，和新位置的声音叠在一起，听起来像"跳转没生效"
func seek_bgm(seconds: float) -> void:
	if not is_bgm_playing():
		return

	if _bgm.previous.playing:
		_bgm.previous.stop()
		_bgm.previous.volume_db = 0.0

	_bgm.current.seek(maxf(0.0, seconds))

## 从指定位置开始播一首 BGM（定位语义）。
##
## 与 play_bgm() 的差别只有"从哪儿起播"：那边永远从头。音乐鉴赏那类
## 界面要的是"停止之后接着上次的位置继续"，只能走这条。
##
## **不做判重** —— 调用方要的就是"立刻到这个位置"，而同一首正在播时
## play_bgm() 会直接返回。所以这里先停再起，然后 seek。
##
## 返回是否成功。路径缺失、资源不是音频时返回 false
func play_bgm_from(path: String, from_seconds: float) -> bool:
	if _bgm == null:
		return false

	if not ResourceLoader.exists(path):
		push_warning("背景音乐缺失：%s" % path)
		return false

	var stream := load(path)
	if not (stream is AudioStream):
		return false

	# 鉴赏界面放的是整首循环的背景音乐，循环设置和 play_bgm() 一样
	_configure_loop(stream, true)

	_bgm.stop_now()
	_bgm.start(stream, 1.0, 0.0)
	_bgm_path = path
	# 起播之后才 seek：stop_now() + start() 换了一轮播放器状态，
	# seek 必须落在新的那次 play() 之后
	_bgm.current.seek(maxf(0.0, from_seconds))
	return true

###########################################################
#  剧情音效
###########################################################

## 播放剧情音效（剧本语句 play sound 的落点）。
##
## opts 的键与 play_music 相同，但默认值不同：
##   fadeout: float   0    旧的那一声本来就该被顶掉
##   loop: int        -1   用通道默认（音效不循环）
##
## 单通道语义：新的顶掉旧的（旧的那一声按 fadeout 淡出，两条会短暂并存）。
## 与 Ren'Py 的 sound 通道一致 —— 它也是一个通道一个播放器，要叠加得
## 自己注册 sound_2 / sound_3
func play_sound(path: String, opts: Dictionary) -> void:
	if path.is_empty():
		return

	if not ResourceLoader.exists(path):
		push_warning("音效缺失：%s" % path)
		return

	var stream := load(path)
	if not (stream is AudioStream):
		return

	_ensure_sound()

	var loop := int(opts.get("loop", -1))
	if loop < 0:
		loop = 0
	_configure_loop(stream, loop != 0)

	_sound.retire(maxf(0.0, float(opts.get("fadeout", 0.0))))
	_sound.start(stream, maxf(0.0, float(opts.get("volume", 1.0))),
		maxf(0.0, float(opts.get("fadein", 0.0))))

## 停掉剧情音效（剧本语句 stop sound 的落点）。默认瞬停
func stop_sound(fadeout: float = 0.0) -> void:
	if _sound == null:
		return
	_sound.fade_out_and_stop(maxf(0.0, fadeout))

###########################################################
#  语音
###########################################################

## 播放一条语音。成功返回 true。
##
## 文件缺失只警告、返回 false，不中断剧情 —— 缺一条配音不该让游戏走不下去。
## 失败时**不设属主**（属主在 VNPlayer 那边）：没声音就不该有嘴在动
func play_voice(path: String) -> bool:
	if _voice == null:
		return false
	if not ResourceLoader.exists(path):
		push_warning("语音文件缺失：%s" % path)
		return false

	var stream := load(path)
	if not (stream is AudioStream):
		return false

	# 语音永远不循环。素材的 .import 现在是不循环，但那是素材侧的设置 ——
	# 哪天有人把 wav 的导入改成循环，症状会是"一句台词反复念"
	_configure_loop(stream, false)

	_voice.stop()
	_voice.stream = stream
	_voice.play()
	return true

## 停掉当前正在播的语音。
##
## 历史界面要用它：进历史就是回看，让剧情那句继续播着、再叠上一条
## 重播的语音，两条会打架
func stop_voice() -> void:
	if _voice != null:
		_voice.stop()

## 语音是否还在播。自动播放开启"等待语音"时要问它 ——
## 语音长度和台词长度没有关系，没法一次性算出该等多久，只能每帧查
func is_voice_playing() -> bool:
	return _voice != null and _voice.playing

###########################################################
#  界面音
###########################################################

## 播一个界面音效。path 为空时什么都不做。
##
## 只判空，不认 VNButton 的 SOUND_NONE 哨兵 —— "故意不发声"在
## VNButton 那一侧就已经解析成空串了，走到这里的要么是有效路径、
## 要么是空。两边各管一段，也免得本类反过来依赖 VNButton
##
## ── 为什么不挂在按钮自己身上 ──
## 点击「关闭 / 返回」这类按钮时，按钮所在的整棵子树会在帧末被销毁
## （关菜单、关弹窗、侧边栏整体重建），挂在它身上的播放器跟着一起走，
## 音效刚推给音频服务器就被掐掉 —— 表现成"关闭类按钮没声音"。
##
## Ren'Py 也是这么分的：按钮音走 config.play_channel（默认 "audio"），
## 由模块级的 renpy.play() 播出去，和任何显示对象都没有关系。
##
## ── 为什么只有一个播放器 ──
## 单声道语义：新的音效打断旧的。界面音都很短，连点两下时第二声盖掉
## 第一声正合期望，没必要为此养一个池
func play_ui_sound(path: String) -> void:
	if path.is_empty():
		return

	var stream := load(path) as AudioStream
	if stream == null:
		push_error("界面音效不是可用的音频：%s" % path)
		return

	_configure_loop(stream, false)

	if _ui_sound == null:
		# 走界面音总线。不设的话默认是 Master，
		# 玩家在设置里调界面音量就管不到按钮音
		_ui_sound = _make_player(_ui_bus)

	_ui_sound.stream = stream
	_ui_sound.play()

###########################################################
#  预加载
###########################################################

## 预读一批音频。只把文件读进资源缓存，不碰任何播放器。
##
## 由 VNFrame 接在 audio_prefetch_requested 上。真正播放时的 load() 会命中
## 同一份缓存，所以这一步省下的是那次同步 I/O。
##
## 三条路（语音 / 音乐 / 音效）走同一个入口：它们都是"按路径预读一个
## 导入资源"，没有哪一路需要不同的处理。
##
## 不存在或空路径直接跳过：预读是尽力而为，缺文件该由真正播放时报出来，
## 在这里再报一遍只会让同一条缺失刷两次警告
func prefetch(paths: Array) -> void:
	for path in paths:
		var p := String(path)
		if p.is_empty() or not ResourceLoader.exists(p):
			continue
		ResourceLoader.load_threaded_request(p)

###########################################################
#  循环
###########################################################

## 按剧本的 loop 意愿配置一份导入音频的循环区间。
##
## ── loop=false ──
## 显式设 LOOP_DISABLED。素材的 .import 现在都是不循环，但那是素材侧的
## 设置，不该由它替剧本决定"这一条循环不循环"。语音、音效、以及写了
## noloop 的音乐都必须走这里关掉。
##
## ── loop=true ──
## 不能只设 loop_mode —— 导入器给 loop_end 留的是 -1，循环区间就成了
## [0, -1) 这种零长度，play() 一起步就结束。表现极具迷惑性：stream 加载
## 成功、bus 正确、总线音量正常、没有静音，但 playing 始终是 false，
## 而且全程没有任何警告。
##
## 所以 loop_end 必须按总时长补上：get_length() 返回秒，乘采样率得到
## 采样帧数，正是 loop_end 的单位。
##
## ── 改的是共享资源 ──
## load() 返回的是同一份 AudioStreamWAV。同一个文件既当 BGM 又当音效的
## 场合，后一次播放会把前一次的循环设置改掉。现实中没有人这么用，
## 所以不做 duplicate()（那会让同一份音频在内存里存两遍）
static func _configure_loop(stream: AudioStream, loop: bool) -> void:
	if stream is AudioStreamWAV:
		var wav := stream as AudioStreamWAV
		if not loop:
			wav.loop_mode = AudioStreamWAV.LOOP_DISABLED
			return
		wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
		if wav.loop_end <= wav.loop_begin:
			wav.loop_end = int(wav.get_length() * wav.mix_rate)
	elif stream is AudioStreamOggVorbis:
		# Ogg 把循环做在流内部，没有 loop_end 那个单位换算的坑
		(stream as AudioStreamOggVorbis).loop = loop
	elif stream is AudioStreamMP3:
		(stream as AudioStreamMP3).loop = loop

class_name VNFrame
extends Node

# ═══════════════════════════════════════════════════════════
#  框架统筹类。**vn/ 在 autoload 里的唯一一个类**，全局名 VN。
#
#  外部写 VN.start(...)、VN.config.text_cps、VN.stage_changed.connect(...)，
#  全部从这里进。它自己不实现任何一样能力，只做三件事：
#
#    1. 装配     按确定的顺序把子系统建出来（见 _ready 的启动表）
#    2. 转发     把公共 API 转给对应的子系统，并桥接它们的信号
#    3. 持有     层号表、玩家配置、以及"框架在哪儿"这件事本身
#
#  ── 对应 Ren'Py 的哪一层 ──
#  renpy.exports 那一整套（show / scene / jump / say …）：模块级的扁平函数，
#  内部拿到引擎对象再往下转发。displayexports.py:457 就是一例：
#      sls = scene_lists()          # 转到当前 Context 的 scene_lists
#  也就是说"公共 API 层"和"状态持有者"在 Ren'Py 里本来就分着两个地方，
#  本类就是前者。
#
#  ── 子系统 ──
#    Session    VNSession    一局的演出状态：角色属性、舞台、历史
#    Audio      VNAudio      语音 / 背景音乐 / 界面音
#    Player     VNPlayer     剧情执行：游标、调用栈、指令分派、位置快照
#    Transition VNTransition 界面转场：淡入淡出、黑场、跳过
#    Warmup     VNWarmup     界面预热池：空闲帧提前建好界面，切换时直接取用
#    config     VNConfig     玩家偏好（不是节点，是普通对象）
#
#  ── 为什么 player 和 config 不叫子系统的"拥有者" ──
#  本类只做装配与转发，**不参与**任何一方的运转：剧情推进不经过这里的方法体，
#  舞台变化不经过这里的状态。转发函数全是单行，它一旦长出一段真正的逻辑，
#  就说明有东西放错了地方。
# ═══════════════════════════════════════════════════════════

###########################################################
#  层号表
#
#  **全项目只有这一处定义。**
#
#  main.tscn 里不写这几个数字：.tscn 存的是字面量，引用不了 GDScript
#  常量，两处各写一遍就迟早会漂移 —— 而且是静默漂移。改由调度器在
#  _ready() 里逐层赋上去，代价是检查器里看到的和运行时不一致。
#
#  空档按 100 一段留，往中间插新层不用重排。
#
#  放在统筹类而不是 Player 里：这些值是"界面怎么分层"，与应用层的
#  调度器直接对话，和剧情执行没有关系。原来摆在播放器里只是因为
#  autoload 在那儿。
###########################################################

const LAYER_STAGE := 0
const LAYER_MAIN := 100
const LAYER_MENU := 200
const LAYER_OVERLAY := 300
## 数值定义在 VNTransition 里 —— 那一层由它自己创建
const LAYER_TRANSITION := VNTransition.LAYER
## 数值定义在 VNFPSMeter 里 —— 同上。压在转场之上，黑幕期间也要看得见
const LAYER_FPS := VNFPSMeter.LAYER

## 舞台内容层可用的最大 layer。舞台内容必须整体落在主层之下，
## 所以贴着 LAYER_MAIN 往下取一格。VNStage.MAX_LAYER 是本值的别名，
## 舞台层用它来限制内容层的 order，两个名字指的是同一件事
const MAX_CONTENT_LAYER := LAYER_MAIN - 1

## start() 的进入方式。用常量别名指向 VNPlayer 的枚举，**不重新声明**。
##
## 这样外部继续写 VN.StartMode.NEW_GAME，而值的唯一来源仍是 VNPlayer。
## 重新声明一份的话，两边各加一个成员时不会有任何提示，
## 表现是"传进去的模式被当成了另一个"
##
## 这个别名不是过渡垫片，别随手删 —— 内容的调用点写的是
## VN.StartMode.NEW_GAME（content/ui/screens/main.gd:216），
## 删掉它那行就会在解析期报错
const StartMode := VNPlayer.StartMode

###########################################################
#  子系统
###########################################################

## 剧情执行器
var player: VNPlayer = null
## 一局的演出状态
var session: VNSession = null
## 音频
var audio: VNAudio = null

## 界面转场。界面切换与黑场都走它
var transition: VNTransition = null

## 左上角帧率显示。纯显示，不参与任何逻辑，也没有任何东西依赖它
var fps_meter: VNFPSMeter = null

## 界面预热池。项目登记过的界面会在空闲帧提前建好，切换时直接取用。
##
## 纯优化：池空着、甚至整个项目没有一处 request()，界面照样正常打开。
## 所以它没有任何下游依赖，也没有谁需要"等它准备好"
var warmup: VNWarmup = null

## 鼠标静止自动隐藏光标。纯功能节点，不参与任何逻辑
var mouse_hide: VNMouseHide = null

## 触摸适配：长按视为鼠标右键。
##
## 纯功能节点：只收事件、发事件，没有任何下游依赖。桌面上的 Windows
## 只会收到鼠标事件，它的 _input 一次都不会命中
var touch: VNTouch = null

## 玩家配置。
##
## 与上面三个的区别：它不是节点，也不由本类转发 —— 外部一直写
## VN.config.xxx，而 VNConfig 是一堆普通字段 + 方法，转发一层只会
## 多出几百行没有信息量的代码。**所有权**在这里：创建、加载、落盘
## 都由本类负责，其它子系统只是读它的一个引用
var config: VNConfig = null

## 剧本包路径。取自作品配置，启动时定一次。
##
## 在 _ready() 里赋值而不是成员初始化式：后者早于
## load_project_settings()，读到的是框架默认值，拿不到作品的覆盖
var package_path := ""

## 开发期钩子的可选挂载点。发布版整个 vn/dev/ 被导出排除，
## ResourceLoader.exists 直接为假，这里不会加载任何东西。
##
## 留成字符串路径而不是静态引用：静态引用一个被排除的类会让发布版解析失败
const DEV_HOOK := "res://vn/dev/hot_reload.gd"

###########################################################
#  公共 API 的信号出口
#
#  真信号在子系统上（它们在事件发生的地方），这里只做出口 ——
#  连接点（VNStage、say.gd、调度器）全部写 VN.xxx，一行都不用改。
#
#  方向是单向的：子系统 -> 本类。子系统不认识 VNFrame，
#  所以桥接不会形成环
###########################################################

## 准备好显示一句台词
signal line_shown(who: String, text: String)
## 剧本结束。ending 是 finish 带的结局名；finish 没带参数时为空串
signal story_ended(ending: String)
## 舞台内容变化。带的是深拷后的完整舞台状态 { tag: { attrs, order } }
signal stage_changed(stage: Dictionary)
## 舞台被整体重建（热重载、存档恢复）。显示层收到后应当**丢弃所有节点**
## 并重新构造
signal stage_rebuilt()
## 进入了一个新的章节（新 label 的第一句台词已经就位）
signal chapter_started(label_name: String)
## 执行流经过了某个 label 的入口，且它的第一句台词已经就位
signal label_entered(label_name: String)
## 剧本请求舞台转场。转发给显示层（VNStage），由它保存旧画面并执行。
## serial 是本次请求的序号，恢复时要原样带回来
signal stage_transition_requested(transition_name: String, params: Array, serial: int)
## 请求显示层显示/隐藏对话框。转发给 say 界面，由它做淡入/淡出
signal window_action_requested(target_visible: bool, transition_name: String, params: Array, serial: int)
## 对话框底图的透明度变了。参数是新的值（范围见作品配置的 setting_ranges）。
## say 界面收到后立刻重绘底图 —— 玩家在设置页拖滑块时就是实时生效的
signal window_alpha_changed(alpha: float)
## 快捷菜单的自动隐藏开关变了。参数是新的状态。
## say 界面里的 QM 收到后重新安排延时与悬停响应 —— 关掉时那两样都不存在
signal qm_auto_hide_changed(on: bool)
## 正文字体变了。参数是新的字体路径。
## say 界面收到后立刻换字体、并跟着调正文的纵向偏移与行距
signal dialog_font_changed(path: String)
## 进入了一条 pause 指令。参数表示它是否在等点击（而不是等秒数）
signal pause_started(waits_for_click: bool)
## 播放器报来一批"接下来大概会用到"的内容。显示层自行决定要不要预载
signal stage_prefetch_requested(requests: Array)
## 播放器报来一批即将播出的声音路径（语音 / 音乐 / 音效）。音频层自行决定要不要预读
signal audio_prefetch_requested(paths: Array)

## 玩家请求退出：点了窗口关闭按钮（或 Alt+F4），或者在安卓上按了返回键。
##
## **上面那一段的例外** —— 它没有上游子系统。源头是引擎送到本节点上的
## NOTIFICATION_WM_CLOSE_REQUEST / NOTIFICATION_WM_GO_BACK_REQUEST，
## 而那两个通知默认会直接退掉进程（见 _ready() 第 0 步）。
##
## 框架只负责"拦下来、说一声"，退不退、要不要先问一句，全归应用层决定。
## **没有监听者时直接退出**：复制 vn/ 到一个新项目、没人接这个信号时，
## 窗口不能变成关不掉
signal quit_requested

###########################################################
#  生命周期
###########################################################

## 装配整个框架。**这个顺序就是启动契约**，每一步都有它必须在那个位置的理由。
##
## 子节点的 _ready() 不会被用来做初始化：VNSession 那边留了个占位函数说明
## 原因。这里全部显式调用，顺序写在明面上
func _ready() -> void:
	# 0. 关窗与安卓返回键改成"先问一句"。这两个开关默认都是 true ——
	#    意味着玩家点一下 X 进程就没了，任何确认框都来不及弹。
	#    它们和任何子系统都没有关系，排在最前面只为一件事：从装配的第一步
	#    起就归这里的规则管，中间不留"还没装上"的缝隙
	get_tree().auto_accept_quit = false
	get_tree().quit_on_go_back = false

	# 1. 作品配置必须最先就位：数据目录名、音量分几路都从它取。
	#    晚一行，下面就会按框架默认值去建目录、读配置
	VNSettings.load_project_settings()
	package_path = VNSettings.get_current().package_path

	# 2. 玩家数据目录先落地，配置与存档都放它下面
	VNConfig.ensure_data_dir()

	# 3. 玩家偏好。先建再给 player —— 它读 voice_sustain 等几个偏好
	config = VNConfig.new()
	config.load_config()
	config.load_seen()
	config.load_seen_images()
	config.apply_audio()

	# 窗口尺寸。必须排在 load_config() 之后 —— 玩家上次选的全屏/窗口、
	# 以及他自己拖出来的那个大小，都刚从 settings.cfg 里读出来
	config.apply_display()

	# 4. 界面转场。自带 CanvasLayer(400)，必须早于任何界面出现
	transition = VNTransition.new()
	transition.name = "Transition"
	add_child(transition)

	# 5-7. 三个子系统。**顺序是契约**：player 的 setup() 要拿到另外两个，
	#      所以它们必须先 add_child 完毕（add_child 时会立刻跑各自的 _ready）
	session = VNSession.new()
	session.name = "Session"
	add_child(session)

	audio = VNAudio.new()
	audio.name = "Audio"
	add_child(audio)

	player = VNPlayer.new()
	player.name = "Player"
	# 剧本包路径是"静态配置"，在装配时一次写好。
	# 必须在 add_child 之前 —— 后面的安装开发钩子会立刻编译一次剧本包，
	# 而它读的就是这个路径
	player.package_path = package_path
	player.setup(session, audio, config)
	add_child(player)

	# 8. 信号出口。必须在 player 开始播之前接好
	_bridge_signals()

	# 音频预取没有别的消费者：直接接在音频层上，不绕到界面。
	# 它也不依赖任何界面存在 —— 主菜单阶段照样能预读。
	# 语音、音乐、音效共用这一条：它们的落地方式完全一样
	audio_prefetch_requested.connect(audio.prefetch)

	# 9. 开发期钩子。放在最后：它一挂上就会立刻编译一次剧本包
	_install_dev_hook()

	# 10. 帧率显示。纯显示，和任何子系统都没有依赖，所以排在装配链末尾 ——
	#     它晚几毫秒出现不影响任何人，而排在装配链前面只会让"装配顺序
	#     就是启动契约"那张表多出一个不相干的条目
	fps_meter = VNFPSMeter.new()
	fps_meter.name = "FPSMeter"
	add_child(fps_meter)

	# 11. 界面预热池。必须排在 transition 之后 —— 它每帧都要问"现在能不能
	#     占用一帧"，而那个判断就是 transition.is_running()。
	#     排在末尾是因为它纯属优化：晚几毫秒装配好，不影响任何人的启动
	warmup = VNWarmup.new()
	warmup.name = "Warmup"
	add_child(warmup)

	# 12. 窗口尺寸记录。玩家拖窗口、最大化、切全屏都会走到这里。
	#     排在最后是为了让第 3 步的 apply_display() 先跑完 ——
	#     启动时那一次尺寸设定不是"玩家的选择"，不该被记一遍
	get_window().size_changed.connect(_on_window_resized)

	# 13. 自动隐藏光标。纯功能节点，和帧率显示同级 ——
	#     晚几毫秒装配好不影响任何人。间隔直接从玩家配置灌进去，
	#     它自己不认识 VNConfig
	mouse_hide = VNMouseHide.new()
	mouse_hide.name = "MouseHide"
	mouse_hide.hide_time = config.mouse_hide_time
	add_child(mouse_hide)

	# 14. 触摸适配（长按 → 鼠标右键）。和鼠标隐藏同为纯功能节点：
	#     只收事件、发事件，没有任何人依赖它"准备好"。排在末尾同样无害 ——
	#     它等到玩家第一次按住屏幕才会真正干活
	touch = VNTouch.new()
	touch.name = "Touch"
	add_child(touch)

## 退出时把还没落盘的东西补上：已读记录（节流窗口内的标记）与玩家拖出来的
## 窗口尺寸（拖动时只在内存里更新，每帧写盘太浪费）。
##
## 用 _exit_tree 而不是 NOTIFICATION_WM_CLOSE_REQUEST：后者只在点窗口
## 关闭按钮时来，get_tree().quit() 那条路不会触发
func _exit_tree() -> void:
	if config != null:
		config.save_seen()
		config.save_seen_images()
		# 玩家拖出来的窗口尺寸只留在内存里（拖动时每帧写盘太浪费），
		# 退出时补上
		config.save_config()

## 引擎送来的"玩家想退出"。
##
## 两种通知并成一条路：桌面点 X / Alt+F4 是 CLOSE_REQUEST，安卓返回键是
## GO_BACK_REQUEST —— 对应用层来说它们是同一个动作（原项目那边也是同一个
## config.quit_action）。两个开关已经在 _ready() 第 0 步关掉了，所以通知
## 一定会送到这里，而不是被引擎直接处理掉。
##
## 没有监听者就退出。这条兜底不是防御性代码，是让 vn/ 能直接复制到新项目
## 用的前提 —— 见 quit_requested 的说明
func _notification(what: int) -> void:
	if what != NOTIFICATION_WM_CLOSE_REQUEST \
			and what != NOTIFICATION_WM_GO_BACK_REQUEST:
		return

	if quit_requested.get_connections().is_empty():
		get_tree().quit()
		return

	quit_requested.emit()

## 窗口尺寸变了。
##
## 只在普通窗口模式下记 —— 全屏、最大化、最小化时那个尺寸由引擎决定，
## 不是玩家的选择。真正该不该记由 VNConfig.capture_window_size() 判断，
## 这里只是转一道
func _on_window_resized() -> void:
	if config != null:
		config.capture_window_size()

## 把子系统的信号接到本类的同名信号上。
##
## 只写这一处：加一条出口信号就是加一行，不会有"信号声明了但忘了接"的状态
func _bridge_signals() -> void:
	player.line_shown.connect(
		func(who: String, text: String) -> void: line_shown.emit(who, text))
	player.story_ended.connect(
		func(ending: String) -> void: story_ended.emit(ending))
	player.chapter_started.connect(
		func(label_name: String) -> void: chapter_started.emit(label_name))
	player.label_entered.connect(
		func(label_name: String) -> void: label_entered.emit(label_name))
	player.stage_transition_requested.connect(
		func(transition_name: String, params: Array, serial: int) -> void:
			stage_transition_requested.emit(transition_name, params, serial))
	player.window_action_requested.connect(
		func(target_visible: bool, transition_name: String, params: Array, serial: int) -> void:
			window_action_requested.emit(target_visible, transition_name, params, serial))
	player.pause_started.connect(
		func(waits_for_click: bool) -> void: pause_started.emit(waits_for_click))
	player.stage_prefetch_requested.connect(
		func(requests: Array) -> void: stage_prefetch_requested.emit(requests))
	player.audio_prefetch_requested.connect(
		func(paths: Array) -> void: audio_prefetch_requested.emit(paths))

	# lambda 的参数**不要**叫 stage：本类自己有 stage() 方法（转发给
	# session），同名参数会触发 SHADOWED_VARIABLE。同理，将来往这里加
	# 信号桥接时，参数名一律避开发过转发的方法名 —— history、audio、
	# session、player 都是这一类
	session.stage_changed.connect(
		func(state: Dictionary) -> void: stage_changed.emit(state))
	session.stage_rebuilt.connect(
		func() -> void: stage_rebuilt.emit())

## 装开发期钩子。发布版导出排除了 vn/dev/，ResourceLoader.exists 直接为假，
## 这里一次函数调用就返回，不会加载任何东西。
##
## 挂在 player 下而不是本类下：钩子要的是"播放位置"（capture_position /
## reload_story / story.ops），那些能力全在 player 上。让本类持有它的话，
## 每次它要读位置都得穿过一层转发
func _install_dev_hook() -> void:
	if not ResourceLoader.exists(DEV_HOOK):
		return

	var script := load(DEV_HOOK)
	if script == null:
		push_warning("开发期钩子加载失败：%s" % DEV_HOOK)
		return

	var hook: Node = script.new()
	player.add_child(hook)
	hook.call("attach", player)

###########################################################
#  剧情
#
#  下面这一段全是单行转发，按子系统分组。**没有逻辑**是常态，
#  多出一行判断就说明那段逻辑该挪回子系统里
###########################################################

## 从剧本包里的指定 label 进入剧情。label_name 为空则从第一条指令开始
func start(label_name: String = "", mode: int = StartMode.CONTINUE) -> bool:
	return player.start(label_name, mode)

## 推进到下一句台词
func advance() -> void:
	player.advance()

## 舞台转场结束。显示层执行完转场后调它，让播放器继续。
## serial 对不上时播放器会丢弃这次回调
func resume_transition(serial: int) -> void:
	player.resume_transition(serial)

## 对话框动画做完。显示层调它让播放器继续
func resume_window(serial: int) -> void:
	player.resume_window(serial)

## 对话框当前是否显示。界面初始挂载时用它同步显隐
func window_visible() -> bool:
	return player.window_visible()

## 当前对话框底图透明度。say 界面挂载时用它取初值
func window_alpha() -> float:
	return config.window_alpha

## 设置对话框底图透明度并广播出去。
##
## 夹范围放在这里而不是各调用方：设置页拖滑块、将来读档恢复、控制台调试
## 三条路都该走它，范围只需要在一个地方生效 —— 和音量、打字速度同一个道理
func set_window_alpha(alpha: float) -> void:
	config.window_alpha = VNConfig.clamp_value("window_alpha", alpha)
	window_alpha_changed.emit(config.window_alpha)

## 当前光标自动隐藏间隔，单位秒。0 表示不隐藏
func mouse_hide_time() -> float:
	return config.mouse_hide_time

## 设置光标自动隐藏间隔，0 表示不隐藏。
##
## 同步给 VNMouseHide 而不是只改配置：那边有自己的空闲计时，
## 改完要立刻按新间隔重算，否则旧计时会继续按老阈值走
func set_mouse_hide_time(seconds: float) -> void:
	config.mouse_hide_time = maxf(seconds, 0.0)
	if mouse_hide != null:
		mouse_hide.set_hide_time(config.mouse_hide_time)

## 快捷菜单是否自动隐藏
func qm_auto_hide() -> bool:
	return config.qm_auto_hide

## 设置快捷菜单是否自动隐藏，并广播出去。
##
## 和 window_alpha 一样，光改配置没用 —— QM 那边有自己的延时 Tween
## 和悬停判定，要收到通知才知道该停还是该重开
func set_qm_auto_hide(on: bool) -> void:
	config.qm_auto_hide = on
	qm_auto_hide_changed.emit(on)

## 当前正文字体路径。空串表示作品配置表里没有可用的字体
func dialog_font() -> String:
	return config.dialog_font_path()

## 设置正文字体并广播出去。
##
## 传空串等于"回到出厂字体"。字体一换，正文的纵向偏移和行距也得跟着换 ——
## 那两个值绑在字体上，由 say 界面自己去作品配置表里查，这里只负责通知
func set_dialog_font(path: String) -> void:
	config.dialog_font = path
	dialog_font_changed.emit(config.dialog_font_path())

## 同步快进状态。say 界面在开关快进时调用，快进时框架跳过转场与窗口动画
func set_skipping(on: bool) -> void:
	player.set_skipping(on)

## 是否停在 pause 上。say 界面用它判断点击要不要绕过冷却
func is_waiting_pause() -> bool:
	return player.is_waiting_pause()

## 当前 pause 是否在等点击（而不是等秒数）。自动播放靠它决定要不要推进
func pause_waits_for_click() -> bool:
	return player.pause_waits_for_click()

## 冻结 / 解冻 pause 的倒计时。叠加界面与观赏模式打开时调它
func set_pause_frozen(on: bool) -> void:
	player.set_pause_frozen(on)

## 是否还在播放
func is_playing() -> bool:
	return player.is_playing()

## 结束当前这一局：清空舞台、停掉语音、退出"正在播放"状态。回主菜单时调用
func end_session() -> void:
	player.end_session()

## 当前台词的 sid。没停在台词上时返回 0
func current_sid() -> int:
	return player.current_sid()

## 当前所在的 label 名
func current_label() -> String:
	return player.current_label()

## 取一份完整状态，直接就是 VNSave 认的存档结构
func capture_state() -> Dictionary:
	return player.capture_state()

## 从一份存档数据恢复整局状态，并立刻播出存档处那一句
func restore_state(data: Dictionary) -> bool:
	return player.restore_state(data)

## 回跳到历史里的第 index 条
func jump_to_history(index: int) -> bool:
	return player.jump_to_history(index)

## 从磁盘重新读一遍剧本包
func reload_story() -> bool:
	return player.reload_story()

###########################################################
#  角色与舞台（转发到 Session）
###########################################################

## 注册角色定义。表是 { 角色 ID: { 属性名: 值 } }
func register_roles(table: Dictionary) -> void:
	session.register_roles(table)

## 定义一个角色。由应用层的定义脚本在启动时调用。
##
## canvas 是烘焙纹理的目标分辨率（像素），零表示不声明 —— 见 VNSession
func define_role(id: String, display_name: String,
		portrait_kind: String = "static",
		canvas: Vector2 = Vector2.ZERO) -> void:
	session.define_role(id, display_name, portrait_kind, canvas)

## 取某个角色某个属性的当前值
func character_property(character_id: String, prop: String) -> String:
	return session.character_property(character_id, prop)

## 取某个角色某个向量属性的当前值
func character_vector_property(character_id: String, prop: String) -> Vector2:
	return session.character_vector_property(character_id, prop)

## 当前舞台状态的深拷
func stage() -> Dictionary:
	return session.stage()

## 舞台是否为空
func stage_is_empty() -> bool:
	return session.stage_is_empty()

## 图像 ID → res:// 路径。编译器在编译期扫好写进剧本包，运行时只查表。
##
## 显示层每次解析都要问一次，**不能缓存**：本类可能在剧情开始之前就被
## 界面访问（那时 story 还没加载，表是空的），而热重载换包之后表也会变
func images() -> Dictionary:
	if player == null:
		return {}
	return player.story.images

## 这张图看过没有。对应 Ren'Py 的 renpy.seen_image()。
##
## CG 鉴赏靠它决定显示缩略图还是锁定图。记录由 VNStage 在真正显示
## 某张图时写入（见 VNStage._add_entry），跨存档全局有效
func is_image_seen(id: String) -> bool:
	if config == null:
		return false
	return config.is_image_seen(id)

## 对话历史。返回实例本身，界面只读
func history() -> VNHistory:
	return session.history()

###########################################################
#  音频（转发到 Audio）
###########################################################

## 播放背景音乐。已经在播同一首就不重播，返回是否真的换了
func play_bgm(path: String) -> bool:
	return audio.play_bgm(path)

## 停止背景音乐
func stop_bgm() -> void:
	audio.stop_bgm()

## 播一个界面音效
func play_ui_sound(path: String) -> void:
	audio.play_ui_sound(path)

## 停掉当前正在播的语音
func stop_voice() -> void:
	player.stop_voice()

## 语音是否还在播
func is_voice_playing() -> bool:
	return audio.is_voice_playing()

## 当前正在播的语音属于哪个角色。空串表示没有语音在播
func voice_owner() -> String:
	return player.voice_owner()

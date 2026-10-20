class_name VNPlayer
extends Node

# ═══════════════════════════════════════════════════════════
#  剧情执行器。只管"播到哪、下一步做什么"，不碰任何 UI。
#
#  ── 它对应 Ren'Py 的什么 ──
#  renpy.execution.Context（execution.py:138）。那边的 Context 同时握着
#  self.current（走到哪条语句）、self.call_stack、self.scene_lists（舞台）。
#  本项目把那三样里的**舞台与角色状态**分给了 VNSession，理由见下。
#
#  ── 与 VNSession 的分工 ──
#    VNPlayer（本文件）  执行：游标、调用栈、指令怎么分派、控制流怎么重放
#    VNSession           状态：有什么角色、屏幕上摆着什么、说过什么
#  这条界线是"动词与名词"的界线：本类决定下一步做什么，Session 记住现在
#  是什么样。改状态时是本类单向调 session.show_tag() 这样进去，
#  Session 不知道剧本存在。
#
#  ── 和 VNAudio 的分工 ──
#  播放能力全在 VNAudio。**语音属主 `_voice_owner` 留在这里**：它是"这条
#  声音属于哪个角色"，而"角色"是本类才认识的领域概念 —— VNAudio 只知道
#  有一条语音在播。所以语音自然播完时它发 voice_finished，由本类清属主。
#
#  ── 被谁创建 ──
#  VNFrame 在 _ready() 里 new 出来，**先 setup() 再 add_child**。
#  本类不读 VNSettings、不建数据目录、不创建音频节点 —— 那些都是
#  VNFrame 的活。这样做的代价是构造顺序成了一个必须遵守的契约，
#  收益是它可测（喂三个替身就能跑指令流）。
#
#  ── 播放位置以"位置快照"的形式对外开放（capture_position /
#  restore_position）。那对接口是通用的：存档要用它记录玩家停在哪，
#  开发期的工具要用它做别的。框架本身不关心谁在用、用来做什么 ──
#
#  控制流由这些指令构成：
#    label    进入块，记录当前 label
#    jump     无条件跳转，不动调用栈
#    call     压栈后跳转，目标 label 里的 return 会回到这里
#    return   弹栈，回到 call 的下一条
#    finish   清空调用栈并结束整场会话
#    set      静默改一个角色属性，不产出台词
#    show / show_front / hide / scene   舞台内容的变化
#    with_run 请求一次舞台转场，转场结束前暂停执行
#    pause    等点击或等秒数，不产生台词
#    play_music / play_sound / stop_music / stop_sound
#             音频。**不停顿** —— 它们改的是播放状态，不是"等这一刻过去"
#    say      唯一会被显示出来的指令
#
#  语法层已强制每个 label 以 jump / finish / return 收尾，所以
#  "指令流自然跑完"在合法剧本里不可能发生 —— 真发生了就是引擎侧的问题。
# ═══════════════════════════════════════════════════════════

## 准备好显示一句台词
signal line_shown(who: String, text: String)
## 剧本结束。ending 是 finish 带的结局名；finish 没带参数时为空串
signal story_ended(ending: String)
## 进入了一个新的章节（新 label 的第一句台词已经就位）。
##
## 应用层用它做自动存档。Ren'Py 的 auto 页是引擎按交互次数写的，而"多少次
## 交互算一个节点"在框架里没有依据 —— 章节边界才是作者和玩家都认得的节点。
##
## 发送时机在 line_shown **之后**：这一刻台词已经交给界面，但画面要等下一帧
## 才重绘完。应用层要抓缩略图的话得再等一帧，见那边的自动存档流程。
signal chapter_started(label_name: String)

## 执行流经过了某个 label 的入口，且它的第一句台词已经就位。
##
## 与上面那条的区别就一句话：**chapter_started 判的是"label 名变了"，
## 这条判的是"label 指令真的被执行到了"**。所以要分成两条信号。
##
## 为什么非要分开：读档是把游标直接放到某句台词上（见 restore_position），
## 途中根本不经过 label 指令。章节固定存档点若按"label 名变了"来判，玩家在
## 第一章里读一份序章中段的档，就会被误判成"进了序章"，把这个固定档覆盖成
## 中段的内容。Ren'Py 没有这个问题 —— $ renpy.save(...) 是一行会被执行到的
## 语句，jump 进 label 中间压根不经过它。
##
## 反过来说，这条信号**不去重**：jump 回同一个 label 算重新进入，与"那行
## 语句又执行了一次"一致。而那正是 chapter_started 要挡掉的情况，两条信号
## 的判据在这里正好相反
signal label_entered(label_name: String)

## 剧本请求一次舞台转场。参数是转场名、它的参数（不含名字）与本次请求的序号。
##
## 发出后播放器会停在 with_run 上，直到有人调用 resume_transition()。
## 旧画面由显示层保存与消费 —— 播放器不碰任何 UI，也不认识"舞台节点"。
##
## 序号是为了让迟到的完成回调失效：热重载可能在转场途中换掉位置，
## 旧转场结束时不该把新位置上的等待一并清掉
signal stage_transition_requested(transition_name: String, params: Array, serial: int)

## 请求显示层显示或隐藏对话框。参数是目标可见性、转场描述与本请求的序号。
## 发出后播放器会暂停，直到界面做完转场并调 resume_window()
signal window_action_requested(target_visible: bool, transition_name: String, params: Array, serial: int)

## 进入了一条 pause 指令。参数表示这条 pause 是否在等点击（而不是等秒数）。
##
## 自动播放靠它挂上"替玩家点一下"的计时。光在 advance() 的调用点判断不够：
## advance() 可能先停在窗口动画或转场里，等它们做完才真正走到 pause
signal pause_started(waits_for_click: bool)

## 请求显示层预加载即将出现的内容。参数是一批 { "tag": String, "attrs": String }。
##
## 只是"接下来大概会用到"的建议 —— 显示层可以忽略、可以去重、可以延后。
## 播放器不判断谁会用到、也不判断值不值得预载（那是显示层的事，它认识
## 各个后端），这里只负责把往后 PREFETCH_DEPTH 条指令里会 show 的东西报出来
signal stage_prefetch_requested(requests: Array)

## 请求音频层预加载即将播出的声音。参数是已经展开好的资源路径。
##
## 语音、背景音乐、剧情音效走同一个入口：它们的落地方式完全一样
## （ResourceLoader 预读一个导入资源），拆成三条信号只会让接收方多写两遍。
##
## 和上面的舞台预取分开，是因为接收方不同：舞台管图像与模型，音频管声音。
## 播放器两边都只报路径，不替它们判断该不该加载
signal audio_prefetch_requested(paths: Array)

## call 的最大嵌套深度。递归 call 写成死循环时，压栈会一路吃到内存耗尽；
## 有个上限才能给出可查的错误，而不是崩在分配失败上
const MAX_CALL_DEPTH := 256

## 预取往后看多少条指令。数值与 Ren'Py 的 config.predict_statements 一致
const PREFETCH_DEPTH := 32

## ATL 运行时。只借它的静态方法读 wait 时长 —— 播放器不推进任何动画，
## 那是显示层的事。preload 而不是 class_name：新脚本第一次被引用时，
## 全局类表可能还没登记它
const ATL_SCRIPT := preload("res://vn/ui/atl.gd")

## start() 的进入方式
enum StartMode {
	NEW_GAME,   ## 新游戏：每局状态（角色属性等）重置回注册时的初始定义
	CONTINUE,   ## 续播：只换入口 label，状态原样保留。章节切换、从玩法返回都走它
}

###########################################################
#  注入的依赖
###########################################################

## 一局的演出状态。角色属性、舞台、历史都在它里面
var session: VNSession = null
## 音频。语音、背景音乐、界面音
var audio: VNAudio = null
## 玩家偏好。**读**它 —— 创建与落盘归 VNFrame
var config: VNConfig = null

## setup() 跑过没有。没跑就进剧情执行时给一条能查的报错，
## 而不是让空引用崩在某个深处
var _initialized := false

###########################################################
#  剧本与位置
###########################################################

## 剧本数据，由 VNFrame 写在 player 上的 package_path 加载
var story := VNStory.new()

## 剧本包路径。由 VNFrame 在 start() 之前写入一次
var package_path := ""

## 当前指令下标。-1 表示还没开始
var _cursor := -1
## 预取扫描是否已经排进帧末队列。同一帧里连点几次只扫一次
var _prefetch_queued := false
## 是否正在播放
var _playing := false
## 当前所在的 label 名。位置快照会带上它，供恢复方在找回位置时兜底
var _label_name := ""
## 当前 label 指令的下标
var _label_begin := 0
## 本次会话的入口 label 名。start() 时记下，rebuild_stage() 用它定位
## 重放的起点。用名字而不是下标：下标在重编译后会失效，label 名不会
var _session_label := ""
## call 的返回栈，每帧 { sid, return_index, label_name, label_begin }。
## sid 是 call 指令自己的 sid —— 位置快照要靠它在新指令流里重算 return_index，
## 因为指令下标在新旧指令流之间没有任何对应关系
var _call_stack: Array[Dictionary] = []

## 正在播的那条语音属于哪个角色。空串表示没有语音在播，或者播的那条
## 不属于任何注册角色（旁白、字面说话人）
##
## 唇跟随靠它判断"该不该我动嘴"。用「语音属主」而不是「当前说话者」：
## voice_sustain 打开时，推进到下一句并不会切断仍在播的旧语音 ——
## 那时声音还是上一个人的，嘴也就该继续由他来动
var _voice_owner := ""

## 上一次报过 chapter_started 的 label 名。
## 用它把"每个 label 只报一次"做成幂等：回跳历史、jump 回同一个 label
## 都会重新经过 label 指令，但那些都不是"进入了新章节"
var _last_announced_label := ""

## "刚经过 label 入口，还没报出去"。见 label_entered 信号。
##
## 由 advance() 的 label 分支置位、由 _show_current() 消费，中间隔着若干条
## 非显示指令（set / show / scene …）。之所以用一个标量带过去而不是就地发信号：
## 经过入口的那一刻画面还停在上一句，应用层要抓缩略图得等台词出来才有的抓
var _label_fresh := false

## 是否停在 with_run 上等舞台转场。
##
## 等待期间 advance() 直接返回：自动播放、快进、玩家点击都会走到 advance()，
## 只在这一处挡住，界面那边就不必知道转场的存在 —— 否则每个调用点都要
## 自己判一次"现在能不能推"
var _waiting_transition := false

## 转场请求序号。每请求一次自增；恢复时带回来核对，旧请求的迟到回调整无效
var _transition_serial := 0

## 是否在恢复位置。读档与热重载只是把游标搬过去，不是播放，
## 途中遇到的 with_run 直接跳过 —— 不该为了定位而播一次转场
var _restoring := false

## 对话框是否显示着。与 Ren'Py 的 store._window 同义
var _window_visible := false
## 界面是否在快进。由 say 界面在开关快进时同步进来 ——
## 快进时 with 转场与窗口动画都直接跳过，
## 对应 Ren'Py 在 skipping 时把 with 的转场置为 None
var _skipping := false
## 是否按 say / scene 自动显隐。对应 Ren'Py 的 _window_auto
var _window_auto := true
## 窗口请求序号。与转场那套分开，两边互不干扰
var _window_serial := 0
## 是否停在窗口显隐上。期间 advance() 直接返回
var _waiting_window := false
## 被窗口隐藏挡住、等动画做完再执行的 scene 指令
var _pending_scene: Dictionary = {}
## 被窗口显示挡住、等动画做完再播的台词（当前指令就是 say）
var _pending_say := false

## 是否停在 pause 上。期间 advance() 只用来结束等待，不往下走
var _waiting_pause := false
## pause 的结束时刻，Time.get_ticks_msec 基准。-1 表示无参 pause，等点击
var _pause_deadline_ms := -1
## pause 计时是否被冻结。叠加界面与观赏模式打开时置位
var _pause_frozen := false
## 冻结时记下的剩余毫秒，解冻后换算成新的截止时刻
var _pause_remaining_ms := 0
## 这条 pause 是不是 ATL 的 wait 引起的。非空时，结束等待（点击 / 快进 /
## 到点）都要顺手把那个 tag 的动画结算到最终态 —— 玩家跳过的是"等动画演完"
## 这件事，动画本身该被補到终点，而不是停在半路
var _pause_wait_tag := ""

## 待生效的 ATL wait，单位秒。0 表示没有。
##
## 由 _apply_show / _apply_scene 写，advance() 的指令循环顶部消费。
## 不就地暂停是因为 scene 可能被对话框淡出挡到 resume_window() 才执行，
## 那时已经离开了那条分支 —— 检查点必须放在循环顶上
var _pending_wait := 0.0
## 上面那次等待对应哪个 tag。跳过时用它找到动画去结算
var _pending_wait_tag := ""

###########################################################
#  装配
###########################################################

## 注入依赖。**由 VNFrame 在 add_child 之前调用一次**。
##
## 收参数而不是自己去摸 autoload：本类因此不需要知道 VNFrame 存在，
## 也不会在单元测试里被迫拉起整个框架。
##
## 语音自然播完的信号在这里接 —— 只有本类关心它（要清属主），
## 所以不放在 VNAudio 里直接回调谁
func setup(p_session: VNSession, p_audio: VNAudio, p_config: VNConfig) -> void:
	session = p_session
	audio = p_audio
	config = p_config

	if audio != null:
		audio.voice_finished.connect(_on_voice_finished)

	# pause 的倒计时只在真的停在定时 pause 上时才需要每帧跑。
	# 装配时先关掉，_start_pause() 到点再开
	set_process(false)

	_initialized = true

###########################################################
#  剧情
###########################################################

## 从剧本包里的指定 label 进入剧情。label_name 为空则从第一条指令开始。
## 成功后立刻发出第一句 line_shown。
##
## 不需要文件路径：label 名全局唯一，而且整包编译成一个产物
func start(label_name: String = "", mode: int = StartMode.CONTINUE) -> bool:
	if not _check_ready():
		return false

	# 空路径直接挡住，不去 load_story()：那样只会得到一条
	# "剧本文件为空或不存在：" 后面什么都没有的报错，
	# 而真正的原因在装配侧（VNFrame 没把 package_path 传下来）
	# 或者作品配置里 package_path 写空了，两者都不是"文件丢了"
	if package_path.is_empty():
		push_error("剧本包路径为空：检查 VNSettings.package_path 与 VNFrame 的装配")
		return false

	# 前置检查全部通过之后才动状态 —— 一次失败的 start 不该留下任何副作用。
	# 重置是破坏性的：玩家玩到一半时若因 label 写错而加载失败，
	# 已经清空的角色属性是收不回来的
	if not story.load_story(package_path):
		return false

	var begin := 0
	if not label_name.is_empty():
		begin = story.label_start(label_name)
		if begin < 0:
			push_error("%s 里没有 label \"%s\"" % [package_path, label_name])
			return false

	if mode == StartMode.NEW_GAME:
		session.reset_roles()
		# 舞台也归零。CONTINUE 时不清 —— 从玩法返回剧情、章节切换，
		# 玩家还在同一个场景里，屏幕上的东西不该凭空消失
		session.clear_stage()
		# 历史同样归零。它和舞台的理由一致：CONTINUE 是"还在同一局里"，
		# 章节切换不该把读过的东西抹掉；而 NEW_GAME 是重开一局，
		# 上一局的历史留到这一局里就是串台
		session.clear_history()

	_label_name = label_name
	_label_begin = begin
	# 重放的起点。jump 走再远，重建时也要从会话入口重新走一遍
	# 才能得到正确的路径 —— 见 rebuild_stage()
	_session_label = label_name
	_call_stack.clear()
	# 章节报告重新计数：新的一局从入口 label 重新开始，
	# 即便入口和上一局的最后一章同名，也该再报一次
	_last_announced_label = ""
	# 入口标记同理。下一轮 advance() 一定会经过 label 指令重新置位，
	# 这里清掉是为了让上一局遗留的 true 不可能漏进这一局
	_label_fresh = false
	# 上一局若停在转场里，新的一局不该继承这个等待状态
	_waiting_transition = false
	# 窗口状态每局重来：auto 恢复成作品配置，界面还没画面时窗口是藏着的
	_window_auto = VNSettings.get_current().window_auto
	_window_visible = false
	_waiting_window = false
	_pending_scene = {}
	_pending_say = false
	_skipping = false
	# 上一局若停在 pause 里，新的一局不该继承这个等待
	_clear_pause()
	_clear_pending_wait()
	_cursor = begin - 1
	_playing = true
	advance()
	return true

## 推进到下一句台词。
## label / jump / call / return / finish / set 都是非显示指令，
## 在这里就地执行并继续循环，只有 say 才会跳出循环交给 UI
func advance() -> void:
	if not _playing:
		return
	# 预取排在帧末。这里只管登记，不占当前帧 —— 加载一张 L2D 要几百毫秒，
	# 放在推进的调用链里会把这一下点击的响应一起拖慢
	_queue_prefetch()
	# pause 期间这一下就是"结束等待"。点击、滚轮、自动播放与快进
	# 都从 advance() 进来，所以只需要在这里接一次；清完之后不 return，
	# 让本轮继续执行 pause 的下一条
	if _waiting_pause:
		_finish_pause()
	# 转场期间不接推进。自动播放、快进和玩家点击都走这一条路，
	# 只挡在播放器里就够了 —— 界面那边不需要知道转场的存在
	if _waiting_transition:
		return
	# 窗口显隐同理：动画没做完之前剧情不该往下走
	if _waiting_window:
		return
	if not _check_ready():
		return

	while true:
		# ATL 的 wait：上一条 show / scene 带来的动画要等播完才继续。
		#
		# 消费点放在循环顶而不是各自的分支里，是因为 scene 可能被对话框
		# 淡出挡到 resume_window() 才执行 —— 那时早就离开了 scene 分支，
		# 只有回到这里才收得到。恢复位置与快进不走等待，与 pause 一致
		if _pending_wait > 0.0:
			var wait_seconds := _pending_wait
			var wait_tag := _pending_wait_tag
			_pending_wait = 0.0
			_pending_wait_tag = ""
			if not _restoring and not _skipping:
				_start_pause({"args": [str(wait_seconds)]}, wait_tag)
				return

		_cursor += 1
		if _cursor >= story.ops.size():
			# 语法层已保证每个 label 都以 jump / finish / return 收尾，
			# 合法剧本走不到这里。走到这里说明字节码损坏或有编译器 bug
			push_error("剧本指令流意外结束：label 缺少出口指令，或 .vnbc 已损坏")
			_end("")
			return

		var op: Dictionary = story.ops[_cursor]
		var kind: String = op["op"]

		if kind == "say" or kind == "say_literal":
			# 对话期间窗口强制显示（Ren'Py 的语义）：window hide 管的是
			# 两句之间的空档，不是把台词一起藏掉。
			# 快进时窗口瞬时切换，不等动画
			if not _window_visible and not _restoring:
				_window_visible = true
				if _skipping:
					_request_window_now(true)
					break
				_pending_say = true
				_request_window(true, "dissolve", [])
				return
			break

		if kind == "label":
			var label_args: Array = op["args"]
			if label_args.size() > 0:
				_label_name = String(label_args[0])
			_label_begin = _cursor
			# 标记"这次是从章节入口进来的"。**只在这里置位**，别处一律不置 ——
			# 读档与热重载都是先改 _cursor 再调 advance()，走不到这一支，
			# 于是"从中间恢复"天然不会被误报成入口
			_label_fresh = true
			continue

		if kind == "set":
			_apply_set(op)
			continue

		if kind == "show":
			_apply_show(op, false)
			continue

		if kind == "show_front":
			_apply_show(op, true)
			continue

		# show <tag> at end：把这个 tag 正在播的动画结算到最终态。
		# 它不是显示指令 —— 不碰舞台数据，只把请求转给显示层
		if kind == "atl_end":
			_apply_atl_end(op)
			continue

		if kind == "hide":
			_apply_hide(op)
			continue

		# 音频。四条都不停顿、不碰窗口与舞台 —— 与 Ren'Py 的 play / stop
		# 一致：它们改的是播放状态，不是"等这一刻过去"。
		# 恢复位置时也照常执行：音乐是状态，"读档后该响什么"由 restore_state
		# 单独覆盖，这里执行与否都不会让画面错位
		if kind == "play_music":
			_apply_play_music(op)
			continue

		if kind == "play_sound":
			_apply_play_sound(op)
			continue

		if kind == "stop_music":
			_apply_stop_music(op)
			continue

		if kind == "stop_sound":
			_apply_stop_sound(op)
			continue

		if kind == "scene":
			# 先让对话框淡出，再动舞台 —— 与 Ren'Py 的顺序一致。
			# 快进时窗口瞬时切换，不暂停；恢复位置时也跳过窗口动画
			if _window_auto and _window_visible and not _restoring:
				_window_visible = false
				if _skipping:
					_request_window_now(false)
					_apply_scene(op)
					continue
				_pending_scene = op
				_request_window(false, "dissolve", [])
				return
			_apply_scene(op)
			continue

		# window auto / show / hide。手动显隐会关掉 auto，
		# 与 Ren'Py 的 execute_window_show 一致
		if kind == "window_auto":
			_window_auto = true
			continue

		if kind == "window_show":
			_window_auto = false
			if _window_visible:
				continue
			_window_visible = true
			if _skipping:
				_request_window_now(true)
				continue
			var show_trans := _window_transition(op)
			_request_window(true, String(show_trans[0]), show_trans[1])
			return

		if kind == "window_hide":
			_window_auto = false
			if not _window_visible:
				continue
			_window_visible = false
			if _skipping:
				_request_window_now(false)
				continue
			var hide_trans := _window_transition(op)
			_request_window(false, String(hide_trans[0]), hide_trans[1])
			return

		# with 不是显示指令，但必须停在这里：转场结束前不能往下执行，
		# 否则后面紧跟着的 show 会在转场中途改变目标画面。
		# 快进时直接跳过 —— 画面靠显示层下一帧丢弃旧节点完成瞬时切换；
		# 恢复位置同理，那是定位，不是播放
		if kind == "with_run":
			if _restoring or _skipping:
				continue
			if _request_transition(op):
				return
			continue

		# pause 不是显示指令，但它会停在这里等。快进和恢复位置都直接跳过 ——
		# 快进对应 Ren'Py 在 skipping 时让 pause 立即结束，
		# 恢复位置是定位，不是播放
		if kind == "pause":
			if _restoring or _skipping:
				continue
			_start_pause(op)
			return

		if kind == "jump":
			var jump_to := _target_index(op)
			if jump_to < 0:
				push_error("jump 的目标不存在：%s" % _target_name(op))
				_end("")
				return
			_cursor = jump_to - 1
			continue

		if kind == "call":
			if not _enter_call(op):
				_end("")
				return
			continue

		if kind == "return":
			if not _leave_call():
				push_error(
					"return 时调用栈为空：label \"%s\" 是 jump 进来的，需要一个 finish 或 jump 收尾"
					% _label_name)
				_end("")
				return
			continue

		if kind == "finish":
			var finish_args: Array = op["args"]
			_end(String(finish_args[0]) if finish_args.size() > 0 else "")
			return

	_show_current()

## 是否还在播放
func is_playing() -> bool:
	return _playing

## 当前正在播的语音属于哪个角色。空串表示没有语音在播。
## 唇跟随每帧问它，判断该不该由自己驱动口型
func voice_owner() -> String:
	return _voice_owner

## 请求一次预取扫描。延迟到帧末执行：advance() 的循环会把 _cursor 推到
## 当前这句上，同步扫的话扫到的是"刚刚执行过的那几条"
func _queue_prefetch() -> void:
	if _prefetch_queued:
		return
	_prefetch_queued = true
	_prefetch.call_deferred()

## 线性往后看 PREFETCH_DEPTH 条指令，把会 show 出来的内容、会播的声音
## 报给显示层与音频层。
##
## 声音这一路有三种来源：say 的语音、play_music、play_sound。都只报路径，
## 去重在这里做 —— 同一句语音在同一段里出现两次很常见。
##
## 遇到跳转类指令就停：后面的指令在线性视角下不可达，而按控制流预测
## 等于在这里再实现一遍跳转与调用栈。Ren'Py 的预测同样不承诺覆盖分支
func _prefetch() -> void:
	_prefetch_queued = false
	if not _playing or story.ops.is_empty():
		return

	var requests: Array = []
	var audios: Array = []
	var i := _cursor + 1
	var stop := mini(story.ops.size(), i + PREFETCH_DEPTH)
	while i < stop:
		var op: Dictionary = story.ops[i]
		var kind: String = op["op"]

		if kind == "jump" or kind == "call" or kind == "return" or kind == "finish":
			break

		if kind == "show" or kind == "show_front" or kind == "scene":
			var args: Array = op["args"]
			if not args.is_empty():
				requests.append({
					"tag": String(args[0]),
					"attrs": String(args[1]) if args.size() > 1 else "",
				})
		elif kind == "say" or kind == "say_literal":
			# args[2] 是编译期展开好的语音路径；这句没有语音时这一格不存在
			_collect_audio(op, 2, audios)
		elif kind == "play_music" or kind == "play_sound":
			# args[0] 是编译期展开好的音频路径
			_collect_audio(op, 0, audios)

		i += 1

	if not requests.is_empty():
		stage_prefetch_requested.emit(requests)
	if not audios.is_empty():
		audio_prefetch_requested.emit(audios)

## 把某个参数位上的音频路径收进 audios，去重。
##
## 三种指令的路径只是位置不同（语音在 args[2]，play 在 args[0]），
## 取法与去重规则一样，所以两处共用这一段
func _collect_audio(op: Dictionary, slot: int, audios: Array) -> void:
	var args: Array = op["args"]
	if slot >= args.size():
		return
	var path := String(args[slot])
	if path.is_empty() or audios.has(path):
		return
	audios.append(path)

## 当前台词的 sid。没停在台词上时返回 0
func current_sid() -> int:
	if _cursor < 0 or _cursor >= story.ops.size():
		return 0
	return int(story.ops[_cursor].get("sid", 0))

## 当前所在的 label 名
func current_label() -> String:
	return _label_name

###########################################################
#  位置快照
###########################################################

## 取当前位置快照。存档用它记录玩家停在哪；开发期工具用它在指令流
## 被替换之后把位置搬过去。框架不关心谁在用。
##
## 返回 { cursor, label_name, call_stack, session_label, path }。
## cursor 指向"当前这条指令"，不是 _cursor 的内部语义（那个指向上一条），
## 这样调用方不需要知道 advance() 是先加一后取
##
## session_label 必须带上：它是 rebuild_stage() 的重放起点，缺了它，
## 从存档恢复时舞台会从指令 0 开始扫，把沿途所有 show / hide 都当成
## "已经发生过"，立绘会整片错位
func capture_position() -> Dictionary:
	return {
		"cursor": _cursor,
		"label_name": _label_name,
		"call_stack": _call_stack.duplicate(true),
		"session_label": _session_label,
		"path": package_path,
	}

## 恢复到某个位置快照，并立刻播出该处（或它之后的第一句台词）。
##
## 调用方负责保证快照里的 cursor 对**当前**指令流有意义 ——
## 这份接口不做校验，也没法做：它不知道指令流换过没有。
##
## poses 是存档里那份各 tag 的显示姿态。读档时传进来，重建出来的节点
## 才能停在存档那一刻的位置上；热重载不传，走显示层自己的"销毁前抓一份"那条路
func restore_position(snapshot: Dictionary, poses: Dictionary = {}) -> void:
	if not _check_ready():
		return

	# 这是一次"跳到中间"，不是"从入口进来"。清标记的理由见 label_entered 信号。
	# 放在最前面而不是交给 advance()：中途若正好停在 label 指令上，
	# advance() 反而会把它置起来，先清才能保证语义是"这次不算"
	_label_fresh = false
	# 读档是彻底换一个位置，上一处若停在转场里，这个等待必须作废
	_waiting_transition = false
	# pause 同理：上一处若停在等待里，新位置不该继承它
	_clear_pause()
	_clear_pending_wait()

	# 读档停在台词上，窗口必须是显示状态。界面可能还藏着对话框，
	# 发一个零时长的显示请求让它立刻露出来（不等待：这是一次定位）
	_window_auto = VNSettings.get_current().window_auto
	_window_visible = true
	_waiting_window = false
	_pending_scene = {}
	_pending_say = false
	_skipping = false
	_window_serial += 1
	window_action_requested.emit(true, "none", [], _window_serial)

	_cursor = int(snapshot.get("cursor", 0)) - 1
	_label_name = String(snapshot.get("label_name", ""))

	# 会话入口一并恢复，理由见 capture_position()。
	# 用 has() 判断而不是取默认值：热重载传来的快照里这一项本来就没变，
	# 而空串会把重建起点抹掉，那比不恢复更糟
	if snapshot.has("session_label"):
		_session_label = String(snapshot["session_label"])

	_call_stack.clear()
	var frames: Array = snapshot.get("call_stack", [])
	for frame in frames:
		if frame is Dictionary:
			_call_stack.append((frame as Dictionary).duplicate(true))

	_playing = true
	# 恢复途中遇到 with_run 直接跳过。读档是定位，不是播放
	_restoring = true
	advance()
	_restoring = false

	# advance() 只在途中遇到 label 指令时才更新 _label_begin。
	# 从一句台词直接恢复时它不会经过 label，所以这里补一次同步
	_sync_label_at_cursor()

	# 舞台按**新**指令流重建。位置对了不等于画面对了 ——
	# 剧本里改过的 show / hide 只有重放一遍才会反映到屏幕上；
	# 而"重放到一半的动画"只有 pose 能还原
	rebuild_stage(poses)

## 从磁盘重新读一遍剧本包。
## 调用方负责在此之前取好位置快照，之后用 restore_position() 放回去
func reload_story() -> bool:
	if story.path().is_empty():
		return false
	return story.reload()

###########################################################
#  存档状态
###########################################################

## 取一份完整状态，直接就是 VNSave 认的存档结构（除了缩略图与展示信息）。
##
## 与 capture_position() 的分工：那个只回答"停在哪"，这个回答"这一局是什么样"。
## 存档要的是后者，热重载要的是前者，所以两个接口都留着。
##
## 键名全部取自 VNSave.F_* —— 存与读共用一套常量，不会出现
## "写的时候叫 A、读的时候叫 B"这种只在读档时才暴露的错
##
## ── 为什么没有舞台 ──
## 舞台不存。restore_position() 会调 rebuild_stage()，从会话入口重放到
## 当前游标，结果等价于存档时的舞台 —— 而且**必然与当前剧本一致**。
## 存一份下来的话，剧本改过之后就会出现"存档里的舞台"与"重建出来的
## 舞台"两个版本，还得决定听谁的
func capture_state() -> Dictionary:
	return {
		VNSave.F_POSITION: capture_position(),
		VNSave.F_SID: current_sid(),
		VNSave.F_ANCHORS: VNPosition.anchors_from(story.ops, _cursor),
		VNSave.F_ROLES: session.roles_data(),
		VNSave.F_HISTORY: session.history_data(),
		VNSave.F_BGM: audio.current_bgm(),
		VNSave.F_WHAT: session.last_say_text(),
		VNSave.F_POSE: session.stage_poses(),
	}

## 从一份存档数据恢复整局状态，并立刻播出存档处那一句。
##
## data 是 VNSave.read() 返回的那个字典。成功返回 true。
## 恢复顺序有三处讲究，每一处都不能调换，见段内注释
func restore_state(data: Dictionary) -> bool:
	if not _check_ready():
		return false

	if data.is_empty():
		push_error("读档：存档数据为空")
		return false

	# 指令流不在就先加载。从主菜单读档时 VN 还没开播、story 是空的；
	# 从剧情里读档时它已经在，重读一次纯属浪费
	if story.ops.is_empty() and not story.load_story(package_path):
		push_error("读档：剧本加载失败 %s" % package_path)
		return false

	var snapshot: Dictionary = data.get(VNSave.F_POSITION, {})
	var sid := int(data.get(VNSave.F_SID, 0))
	var anchors: PackedInt64Array = data.get(VNSave.F_ANCHORS, PackedInt64Array())

	# ── 定位：把存档时的下标搬到当前指令流上 ──
	#
	# 存档可能是上一个剧本版本存的，cursor 不能直接用。三级策略与热重载
	# 共用同一份实现，见 vn/position.gd
	var moved := VNPosition.resolve(snapshot, sid, anchors, story.ops,
		Callable(story, "label_start"))
	match String(moved.get("how", "")):
		VNPosition.HOW_ANCHOR:
			push_warning("读档：这一句在当前剧本里已被改写，按上下文就近恢复")
		VNPosition.HOW_LABEL, VNPosition.HOW_STACK:
			push_warning("读档：这一句在当前剧本里找不到了，已退回章节开头")

	# ── 数据先就位，再放回位置 ──
	#
	# restore_position() 内部会 advance()，那会立刻播出目标那一句并把它
	# 追加进历史。历史必须先就位，VNHistory.add() 的"只比最后一条"去重
	# 才挡得住这次重复追加。反过来的话，读档后历史末尾会多出一条一模一样的
	session.restore_roles(data.get(VNSave.F_ROLES, {}))
	session.restore_history(data.get(VNSave.F_HISTORY, []))

	# 舞台姿态。旧存档里没有这一项，空字典会让重建退回"居中 + 重播"
	var poses: Dictionary = data.get(VNSave.F_POSE, {})
	restore_position(moved, poses)

	# ── 音乐 ──
	#
	# 空串走 stop_bgm() 而不是 play_bgm("")：后者会去检查一个不存在的资源
	# 路径，然后打一条"背景音乐缺失"的警告 —— 那是误报，
	# "存档时本来就没有音乐"是完全正常的状态
	var bgm := String(data.get(VNSave.F_BGM, ""))
	if bgm.is_empty():
		audio.stop_bgm()
	else:
		audio.play_bgm(bgm)

	return true

## 回跳到历史里的第 index 条。成功返回 true。
##
## 这就是"点击回跳"的落点。restore_position() 会把剧情位置搬回去并重放
## 舞台，而它内部走 advance() → _show_current() 会重新显示那一句 ——
## 那一次追加会被 add() 的 sid 去重挡掉，所以历史不会因此多出一条。
##
## **顺序不能反：先截断、再恢复。** 反过来的话，_show_current() 追加的
## 那一条会先落进表里，紧接着的截断就连它一起砍掉了
func jump_to_history(index: int) -> bool:
	var entry := session.history().at(index)
	if entry.is_empty():
		return false

	# 剧本拆包之后，旧快照里的 cursor 在新指令流里没有意义。
	# 当前全项目只有一个包，这一条永远不会命中 —— 留着是给将来拆包的护栏
	var snapshot: Dictionary = entry.get("position", {})
	if String(snapshot.get("path", "")) != package_path:
		push_warning("历史回跳：这一句属于另一个剧本包（%s），跳不回去"
			% snapshot.get("path", ""))
		return false

	# 姿态取**目标历史条目**记录的那一刻，不是当前画面。
	#
	# 这条区别在跨章节跳转时是决定性的：已经推进到 ep1 再跳回 ep0 第五句，
	# 当前画面属于 ep1，从它身上抓不到第五句该有的样子。条目里那份是
	# 当年播到第五句时存下的，和 Ren'Py 每个 checkpoint 存一份 SceneList
	# 拷贝是同一件事
	var poses: Dictionary = entry.get("pose", {})

	session.truncate_history(index + 1)
	restore_position(snapshot, poses)
	return true

###########################################################
#  会话收尾
###########################################################

## 停掉当前正在播的语音。
##
## 历史界面要用它：进历史就是回看，让剧情那句继续播着、再叠上一条
## 重播的语音，两条会打架
func stop_voice() -> void:
	if audio != null:
		audio.stop_voice()
	_voice_owner = ""

## 结束当前这一局：清空舞台、停掉语音、退出"正在播放"状态。
##
## 回到主菜单时调用。语义是"这一局不在了"，不是"把画面藏起来"——
## 舞台清掉之后，主菜单背后不会再残留上一局的立绘和背景。
##
## ── 对应 Ren'Py 的哪一件事 ──
## Ren'Py 的主菜单跑在一个**新 context** 里（00start.rpy:301 的
## renpy.call_in_new_context("_main_menu")），那个 context 的 scene_lists
## 是空的，所以主菜单天然没有舞台。本项目没有 context 这一层机制，
## 只能在回主菜单时显式清一次。不是在模仿它，是在补它缺的那一手。
##
## ── 为什么 _playing 也要置回 false ──
## is_playing() 问的是"现在有没有进行中的一局"，主菜单里答案必须是否。
## 它还兼着 save_auto_now() 与 _request_save() 的闸门：不置回的话，
## 玩家在主菜单点「退出游戏」会凭空写出一份自动存档。
##
## 历史不清、_session_label 也不抹：前者下一局 start(NEW_GAME) 会清、
## 读档时 restore_state() 会整个覆盖；后者被 start() 与 restore_position()
## 各覆盖一次。这里少动一处状态，就少一处会漏的地方
func end_session() -> void:
	if session != null:
		session.clear_stage()
	stop_voice()
	_playing = false
	# 这一局已经结束，迟到的转场结束回调不该再把游标推走
	_waiting_transition = false
	# 窗口同理：迟到的显隐回调也不再算数
	_waiting_window = false
	_pending_scene = {}
	_pending_say = false
	_window_visible = false
	_window_auto = VNSettings.get_current().window_auto
	_skipping = false
	# 这一局已经结束，pause 的倒计时没有继续的理由
	_clear_pause()

###########################################################
#  舞台重建
###########################################################

## 按**当前指令流**重建舞台状态：从本次会话的入口 label 开始模拟执行，
## 一路走到当前游标，只应用舞台指令。
##
## 为什么不能线性扫 0.._cursor（我第一版就是那么写的，是错的）：
##   call 会把控制流送到物理位置更靠后的子过程，而子过程之后还压着
##   call 后面那些**尚未执行**的 show。线性扫会把它们提前应用 ——
##   表现就是"停在子过程里，立绘却已经按 call 之后的指令摆好了"。
##   jump 同理：label 的物理顺序和控制流顺序可以完全无关。
##
## 所以必须真跟踪控制流。走到 pc == _cursor 就停：那就是"实际走过的
## 路径"，一步不多一步不少。
##
## 起点用 label 名而不是下标：指令下标在重编译后会失效，label 名不会。
##
## set 一并重放，但**不**调 session.reset_roles()：set 是赋值、幂等的，
## 重放一遍结果相同；而 reset_roles() 会把属性打回 define_role() 的初始值，
## 那会毁掉 StartMode.CONTINUE 带过来的跨章节状态
##
## 舞台状态写进 session，重放的循环控制留在本类 —— 两边各管一段：
## session 不知道剧本存在，本类不直接碰 _stage 那份字典
func rebuild_stage(poses: Dictionary = {}) -> void:
	if _cursor < 0 or story.ops.is_empty():
		return
	if not _check_ready():
		return

	session.begin_replay()

	# 起点：会话入口 label。入口为空（start() 没给 label）就从 0 开始
	var pc := 0
	if not _session_label.is_empty():
		var entry := story.label_start(_session_label)
		if entry >= 0:
			pc = entry

	var returns: Array[int] = []
	# 步数上限。剧本里写得出跳转环，没有上限时重建会卡死在这里 ——
	# 而它是在热重载路径上跑的，卡死等于游戏没反应。取指令总数两倍：
	# 正常路径每条最多经过两遍（进去、回来）
	var budget := story.ops.size() * 2
	var reached := false

	while pc >= 0 and pc < story.ops.size() and budget > 0:
		if pc == _cursor and _stack_matches(returns):
			reached = true
			break
		budget -= 1

		var op: Dictionary = story.ops[pc]
		match String(op["op"]):
			"set":
				_apply_set(op)
			"show":
				_apply_show(op, false)
			"show_front":
				_apply_show(op, true)
			"hide":
				_apply_hide(op)
			"scene":
				_apply_scene(op)
			"jump":
				var jump_to := _target_index(op)
				pc = jump_to if jump_to >= 0 else story.ops.size()
				continue
			"call":
				var call_to := _target_index(op)
				if call_to < 0:
					pc = story.ops.size()
					continue
				returns.append(pc + 1)
				pc = call_to
				continue
			"return":
				if returns.is_empty():
					pc = story.ops.size()
					continue
				pc = returns.pop_back()
				continue
			"finish":
				pc = story.ops.size()
				continue
		pc += 1

	# 收尾由 session 做：先让显示层把节点全丢掉（stage_rebuilt），
	# 再推新状态。顺序见 VNSession.end_replay() 的说明
	#
	# 姿态必须在这之前并进去：end_replay() 一返回，显示层就开始照
	# _stage 建节点了，晚一步贴上去的 pose 这一轮用不上
	session.apply_poses(poses)
	session.end_replay()

	if not reached:
		# 走到这里说明入口 label + 控制流推不出当前游标。位置恢复那一层
		# 已经尽力了，舞台这边如实说一声，别让屏幕上摆着一份来路不明的状态
		push_warning("舞台重建没能走到当前位置（label \"%s\"，游标 %d），"
			% [_session_label, _cursor] + "屏幕上的内容可能不完整")

## 重放途中维护的返回地址栈，是否就是当前位置的调用栈。
##
## 光看 pc == _cursor 是不够的：同一个 label 可以被 call 第二次，
## 它的指令下标和第一次完全相同。重放会在**第一次**到达时就停下，
## 得到的是那一次的舞台状态（往往是空的），而不是现在这一次的。
## 实测过的症状：ep0_sub 的台词被 call 两回，停在第二回里时，
## 重放退回了一个空舞台，而屏幕上其实是 {mao_pro: exp_05 special_02}。
##
## 调用栈正是"第几次进来"的区分信息。两边存的还是同一样东西：
## _call_stack 每帧的 return_index 就是 call 的下一条指令，
## 而重放压栈压的也是 pc + 1
func _stack_matches(returns: Array[int]) -> bool:
	if returns.size() != _call_stack.size():
		return false
	for i in returns.size():
		if returns[i] != int(_call_stack[i].get("return_index", 0)):
			return false
	return true

###########################################################
#  控制流
###########################################################

## 取 jump / call 的目标指令下标。目标 label 不存在时返回 -1。
##
## 返回值必须挡住 -1：GDScript 里 story.ops[-1] 是"最后一条"而不是越界，
## 不挡住的话，一个坏掉的跳转目标会让剧情静默跳到文件末尾
func _target_index(op: Dictionary) -> int:
	var args: Array = op["args"]
	if args.is_empty():
		return -1
	return story.label_start(String(args[0]))

## 取 jump / call 的目标名，只用于报错
func _target_name(op: Dictionary) -> String:
	var args: Array = op["args"]
	return String(args[0]) if args.size() > 0 else "<空>"

## 压一层调用栈并跳到目标 label。栈太深或目标不存在时返回 false，由调用方收尾。
##
## 栈帧存的是 call 指令自己的 sid，不是目标 label 的名字：位置快照要在
## 新的指令流里找到同一条 call，再重算 return_index。直接存 return_index
## 是没用的 —— 下标在新旧指令流之间没有对应关系
func _enter_call(op: Dictionary) -> bool:
	if _call_stack.size() >= MAX_CALL_DEPTH:
		push_error("call 嵌套超过 %d 层，疑似递归死循环（label \"%s\"）"
			% [MAX_CALL_DEPTH, _label_name])
		return false

	var target := _target_index(op)
	if target < 0:
		push_error("call 的目标不存在：%s" % _target_name(op))
		return false

	_call_stack.append({
		"sid": int(op.get("sid", 0)),
		"return_index": _cursor + 1,
		"label_name": _label_name,
		"label_begin": _label_begin,
	})
	_cursor = target - 1
	return true

## 弹一层调用栈并回到 call 的下一条。栈空时返回 false。
##
## label 名和 label 起始下标一并恢复：return 落回的位置通常不是 label 指令，
## 靠往回搜是搜不准的 —— call 的下一条可能紧挨着另一个 label 的边界
func _leave_call() -> bool:
	if _call_stack.is_empty():
		return false

	var frame: Dictionary = _call_stack.pop_back()
	_cursor = int(frame["return_index"]) - 1
	_label_name = String(frame["label_name"])
	_label_begin = int(frame["label_begin"])
	return true

###########################################################
#  指令落点
#
#  这一小段的形状值得说一句：**把 op 拆成参数，再交给 session**。
#  原来这几个函数直接吃 op 字典、直接改 _stage，于是 VNPlayer 必须知道
#  ".vnbc 的 args 长什么样"和"舞台数据怎么摆"两件事。
#  现在它只管前者，后者归 VNSession
###########################################################

## 执行一条 set 指令。
## 路径形状已经由 parser 校验过，这里是运行时的落点。
## set 是静默指令，不产出台词，执行完继续往下走
func _apply_set(op: Dictionary) -> void:
	var args: Array = op["args"]
	if args.size() < 2:
		return

	var path := String(args[0])
	var value := String(args[1])

	# parser 保证路径是 role.<角色>.<属性> 三段
	var segments := path.split(".")
	if segments.size() != 3 or segments[0] != "role":
		push_error("set 的路径形状不对：%s" % path)
		return

	session.set_character_property(segments[1], segments[2], value)

## 执行 show / show_front。属性如何累加由 VNSession 决定
##
## args 布局：[0] tag  [1] 属性串  [2] at 的 transform 名  [3] 内联 ATL 块（JSON）
## 后两格都是"没有就是空串"，由显示层决定默认值
##
## 这里顺手记下 wait 的时长：动画从这一句开始播，等待也就从这一刻起算。
## 真正的暂停在 advance() 的循环顶上做，见 _pending_wait
func _apply_show(op: Dictionary, front: bool) -> void:
	var args: Array = op["args"]
	if args.is_empty():
		return

	var at_name := String(args[2]) if args.size() > 2 else ""
	var atl := String(args[3]) if args.size() > 3 else ""

	session.show_tag(String(args[0]),
		String(args[1]) if args.size() > 1 else "", front, at_name, atl)

	_pending_wait = _atl_wait(at_name, atl)
	_pending_wait_tag = String(args[0])

## 执行 hide
func _apply_hide(op: Dictionary) -> void:
	var args: Array = op["args"]
	if args.is_empty():
		return
	session.hide_tag(String(args[0]))

## 执行 scene
func _apply_scene(op: Dictionary) -> void:
	var args: Array = op["args"]
	if args.is_empty():
		return

	var at_name := String(args[2]) if args.size() > 2 else ""
	var atl := String(args[3]) if args.size() > 3 else ""

	session.scene_with(String(args[0]),
		String(args[1]) if args.size() > 1 else "", at_name, atl)

	_pending_wait = _atl_wait(at_name, atl)
	_pending_wait_tag = String(args[0])

## 执行 `show <tag> at end`：让这个 tag 的动画立刻结算到最终态。
##
## 结算本身归显示层，播放器只转达。tag 不在场上、或动画早就播完了，
## 都是正常情况，由显示层安静地忽略
func _apply_atl_end(op: Dictionary) -> void:
	var args: Array = op["args"]
	if args.is_empty():
		return
	session.finish_tag(String(args[0]))

## 一条 show / scene 带来的动画需要等多久。返回 0 表示不等。
##
## wait 只认顶层块，所以这里只看最外层的那一条语句。时长由编译器在
## 展开完 transform 引用之后算好 —— 运行时重复算一遍只会和它对不上
func _atl_wait(at_name: String, atl: String) -> float:
	if not atl.is_empty():
		var parsed = JSON.parse_string(atl)
		if parsed is Array:
			return ATL_SCRIPT.wait_time(parsed)
		return 0.0

	if at_name.is_empty() or story == null or not story.transforms.has(at_name):
		return 0.0

	var blocks = story.transforms[at_name]
	if not (blocks is Array):
		return 0.0
	return ATL_SCRIPT.wait_time(blocks)

###########################################################
#  音频落点
#
#  与舞台那几个同一个形状：把 op 的 args 摊成具名参数，再交给 VNAudio。
#  本类因此不需要知道 VNAudio 的 opts 字典怎么实现，VNAudio 也不需要
#  知道 .vnbc 的 args 布局 —— 摊开这一步就在这一段里，两边各管一段。
#
#  为什么要摊开而不是把 args 整个递过去：args 是**字符串数组**，
#  而且顺序是字节码的约定。音频层若去读 args[3]，改一次参数顺序就得
#  同时改两处，且编译器不会报错
###########################################################

## 执行 play music。args 布局：
##   [0] 路径（编译期已展开）  [1] fadein  [2] fadeout
##   [3] volume  [4] loop（""/"0"/"1"）  [5] if_changed（""/"1"）
##
## 空串一律表示"未指定"，由 VNAudio 按通道默认值填。注意它和 "0" 的区别：
## fadeout 0 是合法的瞬切，未指定则是"用作品配置的 1.0 秒"
func _apply_play_music(op: Dictionary) -> void:
	var args: Array = op["args"]
	if args.is_empty():
		return
	audio.play_music(String(args[0]), {
		"fadein": _arg_float(args, 1, 0.0),
		"fadeout": _arg_float(args, 2, -1.0),
		"volume": _arg_float(args, 3, 1.0),
		"loop": _arg_flag(args, 4),
		"if_changed": _arg_flag(args, 5) > 0,
	})

## 执行 play sound。args 布局同 play music，但没有 if_changed 那一格
func _apply_play_sound(op: Dictionary) -> void:
	var args: Array = op["args"]
	if args.is_empty():
		return
	audio.play_sound(String(args[0]), {
		"fadein": _arg_float(args, 1, 0.0),
		"fadeout": _arg_float(args, 2, 0.0),
		"volume": _arg_float(args, 3, 1.0),
		"loop": _arg_flag(args, 4),
	})

## 执行 stop music。args[0] 是淡出秒数，空串表示用作品配置的默认值
func _apply_stop_music(op: Dictionary) -> void:
	audio.stop_music(_arg_float(op["args"], 0, -1.0))

## 执行 stop sound。args[0] 是淡出秒数，空串表示瞬停
func _apply_stop_sound(op: Dictionary) -> void:
	audio.stop_sound(_arg_float(op["args"], 0, 0.0))

## 取一个浮点参数。越界或空串时返回 fallback
func _arg_float(args: Array, index: int, fallback: float) -> float:
	if index >= args.size():
		return fallback
	var text := String(args[index])
	if text.is_empty():
		return fallback
	return float(text)

## 取一个三态开关参数：""（未指定）、"0"、"1"。
##
## 返回 -1 / 0 / 1。"未指定"与"显式关掉"必须是两回事 —— 循环的默认值
## （音乐开、音效关）全靠这个区别，塌成布尔值的话 play sound 就再也
## 说不清"我要它循环"到底是不是有意为之
func _arg_flag(args: Array, index: int) -> int:
	if index >= args.size():
		return -1
	var text := String(args[index])
	if text.is_empty():
		return -1
	return 1 if text == "1" else 0

###########################################################
#  舞台转场
###########################################################

## 请求显示层执行一次舞台转场，并暂停执行。返回是否真的进入了等待。
##
## 暂停是必须的：with 在 Ren'Py 里是一次交互，转场结束之前后面的 show
## 不能提前执行；否则转场的目标画面就不是作者写的那一张。
##
## 参数拼成数组而不是把 op 整个送出去：显示层只该知道"转场名 + 参数"，
## 不该认识 .vnbc 的指令结构
func _request_transition(op: Dictionary) -> bool:
	var args: Array = op["args"]
	if args.is_empty():
		# 字节码损坏。跳过它，别把整条指令流卡在这里
		push_error("with_run 缺少转场名")
		return false

	var params: Array[String] = []
	for i in range(1, args.size()):
		params.append(String(args[i]))

	_waiting_transition = true
	_transition_serial += 1
	stage_transition_requested.emit(String(args[0]), params, _transition_serial)
	return true

## 舞台转场结束，继续执行后面的指令。
## serial 对不上说明这是上一次转场的迟到回调，直接丢弃
func resume_transition(serial: int) -> void:
	if not _waiting_transition:
		return
	if serial != _transition_serial:
		return
	_waiting_transition = false
	advance()

###########################################################
#  对话窗口
###########################################################

## 请求界面显示或隐藏对话框，并暂停执行。
## 参数是目标可见性与时长；序号用于丢弃迟到的完成回调
func _request_window(target_visible: bool, transition_name: String, params: Array) -> void:
	_waiting_window = true
	_window_serial += 1
	window_action_requested.emit(target_visible, transition_name, params, _window_serial)

## 快进时用：只改状态、发一个瞬时请求，不暂停执行。
## 界面收到后会立即同步显隐；它的 resume_window 回调因为不在等待中而幂等返回
func _request_window_now(target_visible: bool) -> void:
	_window_serial += 1
	window_action_requested.emit(target_visible, "none", [], _window_serial)

## 取 window show / window hide 后面的转场描述。没写 with 时默认 dissolve
func _window_transition(op: Dictionary) -> Array:
	var args: Array = op["args"]
	if args.is_empty():
		return ["dissolve", []]

	var params: Array = []
	for i in range(1, args.size()):
		params.append(String(args[i]))
	return [String(args[0]), params]

## 界面做完了窗口动画，继续执行。
## serial 对不上说明这是上一次请求的迟到回调
func resume_window(serial: int) -> void:
	if not _waiting_window:
		return
	if serial != _window_serial:
		return
	_waiting_window = false

	# 被窗口挡住的 scene：现在补执行，再从它的下一条继续
	if not _pending_scene.is_empty():
		var op := _pending_scene
		_pending_scene = {}
		_apply_scene(op)
		advance()
		return

	# 被窗口挡住的台词：现在播出去。_cursor 正指着它，不能再 advance
	if _pending_say:
		_pending_say = false
		_show_current()
		return

	advance()

## 对话框当前是否显示。界面初始挂载时要用它同步自己的显隐
func window_visible() -> bool:
	return _window_visible

## 同步快进状态。say 界面在开关快进时调用
func set_skipping(on: bool) -> void:
	_skipping = on

## 是否停在 pause 上。say 界面用它判断点击要不要绕过冷却
func is_waiting_pause() -> bool:
	return _waiting_pause

## 当前 pause 是否在等点击（而不是等秒数）。
## 自动播放靠它区分"要不要替玩家点这一下"
func pause_waits_for_click() -> bool:
	return _waiting_pause and _pause_deadline_ms < 0

## 冻结 / 解冻 pause 的倒计时。叠加界面与观赏模式打开时冻结，
## 关闭后按剩余时间继续 —— 对应 Ren'Py 打开菜单时剧情暂停
func set_pause_frozen(on: bool) -> void:
	if not _waiting_pause:
		return
	if _pause_frozen == on:
		return

	# 无参 pause 没有计时可冻结。记下状态，结束等待时一并清掉
	if _pause_deadline_ms < 0:
		_pause_frozen = on
		return

	if on:
		_pause_remaining_ms = maxi(0, _pause_deadline_ms - Time.get_ticks_msec())
		_pause_frozen = true
		set_process(false)
		return

	_pause_frozen = false
	_pause_deadline_ms = Time.get_ticks_msec() + _pause_remaining_ms
	_pause_remaining_ms = 0
	set_process(true)

###########################################################
#  pause
###########################################################

## 进入一条 pause 指令。无参等点击，带秒数按时间倒计时。
## 定时等待用 _process 推进：它要的是"时间到了继续执行"，
## 而不是一次转场，所以不借 VNTransition
##
## wait_tag 非空表示这条 pause 是 ATL 的 wait 造出来的，结束等待时要把
## 那个 tag 的动画结算到最终态。普通 pause 传空串
func _start_pause(op: Dictionary, wait_tag: String = "") -> void:
	var args: Array = op["args"]
	_waiting_pause = true
	_pause_frozen = false
	_pause_remaining_ms = 0
	_pause_deadline_ms = -1
	_pause_wait_tag = wait_tag

	if args.is_empty():
		set_process(false)
	else:
		var seconds := maxf(0.0, float(args[0]))
		_pause_deadline_ms = Time.get_ticks_msec() + int(seconds * 1000.0)
		set_process(true)

	# 通知界面。自动播放要靠它挂等待 —— advance() 可能先停在窗口动画
	# 或转场里，等它们做完才走到这里，光看 advance() 的返回点不够
	pause_started.emit(_pause_deadline_ms < 0)

## 结束 pause 等待。点击、倒计时到点、快进三条路都走这里；
## 调用方负责继续执行（advance 的循环会往下走）
##
## ATL 的 wait 在这里补最后一步：等待结束了，动画却可能还差一点没到终点
## （玩家点得比动画快）。玩家跳过的是"等动画演完"这件事，不是那段演出本身，
## 所以把动画撥到最终态再走。已经播完的 finish() 是空操作
func _finish_pause() -> void:
	var wait_tag := _pause_wait_tag
	_clear_pause()
	if not wait_tag.is_empty():
		session.finish_tag(wait_tag)

## 清掉 pause 的等待状态并关掉每帧计时。
## 换位置的入口（start / restore_position / end_session / _end）走它
##
## 注意它不清 _pending_wait：那个是"还没开始等"的动画，与当前这条 pause
## 无关，换位置的入口自己会清
func _clear_pause() -> void:
	_waiting_pause = false
	_pause_deadline_ms = -1
	_pause_frozen = false
	_pause_remaining_ms = 0
	_pause_wait_tag = ""
	set_process(false)

## 丢掉还没生效的 ATL wait。
##
## 换位置的入口调用它：那条 show 已经在上一处执行过了，它的等待属于
## "从那条指令往下走"的流程，新位置不该继承。和 _clear_pause 分开，
## 是因为两者的生命周期不同 —— pause 是"正在等"，pending 是"马上要等"
func _clear_pending_wait() -> void:
	_pending_wait = 0.0
	_pending_wait_tag = ""

## pause 的倒计时。只在定时等待时开着 —— 无参 pause 与冻结期间不需要每帧跑
func _process(_delta: float) -> void:
	if not _waiting_pause or _pause_frozen or _pause_deadline_ms < 0:
		set_process(false)
		return
	if Time.get_ticks_msec() < _pause_deadline_ms:
		return

	_finish_pause()
	advance()

###########################################################
#  台词
###########################################################

## 播出台词指令。只在 op 为 say / say_literal 时调用。
##
## 两种 op 的区别只有说话人怎么来：
##   say           args[0] 是角色 ID，要查角色表拿当前显示名
##   say_literal   args[0] 就是显示文本本身（旁白是空串），不查表
##
## 显示名和台词都过一层 tr() —— 翻译是运行时的事，
## 所以 .vnbc 里存的永远是原文
func _show_current() -> void:
	var op: Dictionary = story.ops[_cursor]
	var kind: String = op["op"]
	var args: Array = op["args"]

	var who_raw := ""
	var text := ""
	var voice := ""
	if args.size() > 0:
		who_raw = String(args[0])
	if args.size() > 1:
		text = String(args[1])
	if args.size() > 2:
		voice = String(args[2])

	var who := who_raw if kind == "say_literal" else _resolve_role_name(who_raw)

	# 字面说话人（旁白、直接写名字的那种）不对应任何角色，语音也就没有
	# 属主 —— 旁白带配音时，场上任何一个立绘都不该动嘴
	var role_id := "" if kind == "say_literal" else who_raw
	_update_voice(voice, role_id)

	# 记历史。
	#
	# 存的是 tr() 之后的两段文字：历史记的是"玩家当时读到的内容"，
	# 而 tr() 是单向的 —— 存了原文反而拿不回 msgid，切语言时也没法重译。
	#
	# 位置用 capture_position()：advance() 是先加一后取，走到这里时
	# _cursor 正指着这条 say 指令，快照拿到的就是它。快进时同样会走到
	# 这里，所以快进过的句子照记，和 Ren'Py 一致
	# tr() 只算一次。原来这里把它调了两遍（历史一次、信号一次），
	# 加上下面要记的附言就是三遍 —— 纯函数，结果相同，但没必要
	var shown_who := tr(who)
	var shown_text := tr(text)
	session.set_last_say_text(shown_text)

	# 姿态也在这一刻抓：这条历史指向的就是"现在这个画面"。
	# 等玩家以后从别的章节跳回来时，抓不到这一刻 —— 那时屏幕上早换人了
	session.add_history(current_sid(), shown_who, shown_text, voice,
		capture_position(), session.stage_poses())

	line_shown.emit(shown_who, shown_text)

	# 两个报告都放在 line_shown 之后：这一刻界面已经拿到台词了，
	# 应用层收到就能接着做"抓图 + 存档"这件事。
	# 入口报告在前 —— 它对应用层的含义更基础（我到了这一章的开头），
	# 章节点在后。两者在同一帧发出，应用层会把它们合并成一次抓图
	_announce_entry()
	_announce_chapter()

## 从章节入口进来就报一次。
##
## 消费点必须在**这一句台词**上，而不能在置位那一刻就地发：label 入口和第一句
## 台词之间可能夹着 scene / show / set，标量要一直留到画面真的换了内容，
## 应用层才有东西可抓
func _announce_entry() -> void:
	if not _label_fresh:
		return
	_label_fresh = false
	label_entered.emit(_label_name)

## 进了新章节就报一次。
##
## 判据是"label 名和上次报过的不一样"，而不是"经过了一条 label 指令"：
## 回跳历史、jump 回同一个 label，都会重新经过 label 指令，
## 但那些都不是进入了新章节
func _announce_chapter() -> void:
	if _label_name == _last_announced_label:
		return
	_last_announced_label = _label_name
	chapter_started.emit(_label_name)

## 把角色 ID 解析成当前的显示名。
##
## 只处理"标识符说话人"这一种 —— 字面名和旁白走的是 say_literal 指令，
## 根本不进这里。所以走到这个函数还查不到，就是真的没注册过，值得警告。
##
## 角色定义在应用层的 GDScript 里，框架编译期看不到，没法提前拦住。
## 屏幕上出现 me 这种标识符本身就是最直观的线索，比什么都不显示强
func _resolve_role_name(character_id: String) -> String:
	if character_id.is_empty():
		return ""

	var display := session.character_property(character_id, "name")
	if display.is_empty():
		push_warning("角色 \"%s\" 没有注册过显示名" % character_id)
		return character_id

	return display

###########################################################
#  语音
###########################################################

## 语音是否还在播。转发给 VNAudio。
##
## 留这一条转发而不是让调用方写 VN.player.audio.is_voice_playing()：
## 唇跟随每帧都要问它（cubism_lipsync.gd:214 的 _should_drive），
## 而握有本对象的那些地方（立绘、界面）并不需要知道音频节点的存在。
##
## 两个调用场景的频率差得很远：自动播放那道"等语音"每句问一次，
## 唇跟随是每帧一次 —— 所以这里只是一行转发，不要往里加任何判断
func is_voice_playing() -> bool:
	return audio != null and audio.is_voice_playing()

## 按 voice 与 voice_sustain 决定语音的去留。
## 下一句自带 voice 就替换；没有 voice 时由设置决定旧语音是停是续 ——
## 这正是 Ren'Py 的 voice sustain 语义：推进时要不要切断仍在播的那条
##
## role_id 是这条语音的归属角色，只服务于唇跟随。voice_sustain 保住了
## 旧语音时**不动属主**：声音还是上一个人的，就还是他的嘴在动
func _update_voice(voice_path: String, role_id: String) -> void:
	if not voice_path.is_empty():
		# 属主跟着"播放成功"走。缺文件时不设属主 —— 没声音就不该有嘴在动，
		# 那条警告由 VNAudio 自己打
		if audio.play_voice(voice_path):
			_voice_owner = role_id
		return

	if not config.voice_sustain and audio != null and audio.is_voice_playing():
		stop_voice()

## 语音自然播完。属主在这条路上清。
##
## 主动 stop() 不会触发这里（AudioStreamPlayer 的文档明说 stop() 不发
## finished），所以那一路由 stop_voice() 自己清 —— 三条主动路径都走它，
## 漏掉任何一处都会留下"声音已经没了、嘴还在动"
func _on_voice_finished() -> void:
	_voice_owner = ""

###########################################################
#  收尾
###########################################################

## 结束本次剧情会话。ending 为空串表示 finish 没带结局名。
##
## 调用栈在这里清空 —— finish 与 return 的本质区别就在这一句：
## return 只弹一层，finish 无论嵌在多深的 call 里都一路结束整场会话。
##
## 语音也在这里停：剧情已经结束，让一条台词音跨到主菜单里播完是很怪的，
## 而主菜单不归剧情管。背景音乐**不**主动停 —— 接下来该放什么由接手的那
## 一方通过 play_bgm 决定，它已经处理了"同一首不重播"
func _end(ending: String) -> void:
	# 收尾时把已读记录落盘，不等节流 —— 节流是给快进时的高频标记用的。
	# 看过的图像记录同理
	if config != null:
		config.save_seen()
		config.save_seen_images()
	_playing = false
	_call_stack.clear()
	stop_voice()
	# finish 也可能跟在一条 with 后面；结束时的等待状态一并作废
	_waiting_transition = false
	_waiting_window = false
	_pending_scene = {}
	_pending_say = false
	_skipping = false
	# pause 的倒计时也停掉；结束之后没有人会来消费它
	_clear_pause()
	_clear_pending_wait()
	story_ended.emit(ending)

## 从当前游标往回找最近的 label，同步 _label_name 与 _label_begin。
## 位置快照跳转之后必须调它，否则快照里的 label 归属就是错的
func _sync_label_at_cursor() -> void:
	for i in range(_cursor, -1, -1):
		var op: Dictionary = story.ops[i]
		if op["op"] == "label":
			var args: Array = op["args"]
			if args.size() > 0:
				_label_name = String(args[0])
			_label_begin = i
			return

###########################################################
#  内部
###########################################################

## 装配检查。没 setup() 就进剧情执行，说明有人绕过了 VNFrame ——
## 与其让空引用崩在某个深处，这里给一条能直接定位的报错
func _check_ready() -> bool:
	if _initialized:
		return true
	push_error("VNPlayer 没有装配：必须先调用 setup(session, audio, config)，"
		+ "正常路径下由 VNFrame 在启动时完成")
	return false

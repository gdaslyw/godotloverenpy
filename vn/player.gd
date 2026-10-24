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

## 剧本里的 save 指令。参数是槽名与**指令执行那一刻**的进度快照。
##
## 快照在这里取而不是让应用层到帧末自己抓：save 后面常常紧跟 jump / call，
## 它们会立刻改 _cursor —— 等到帧末再取，存下来的位置已经是好几条之后了。
## 这也正是 Ren'Py 的语义：renpy.save() 存的是它执行到的位置。
##
## 应用层收到后负责抓缩略图与落盘，播放器不等它 —— 存档是异步的，
## 指令本身不产生台词、不停顿、不碰舞台
signal save_requested(slot: String, state: Dictionary)

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

## 恢复位置时舞台的来源。
##
##   STAGE_AUTO      有快照就用，没有就重放。留给不传来源的调用方
##   STAGE_SNAPSHOT  一定用快照 —— 即使快照里舞台是空的，"那一刻台上
##                   什么都没有"也是一个合法且必须尊重的事实
##   STAGE_REPLAY    一定重放指令流。只在"要按新剧本重算画面"时才有意义
##
## 为什么要三种而不是"空字典就当没有快照"：那种写法把"台上本来就没东西"
## 和"没有快照"混成一种情况，于是空舞台会被误判成需要重放，而重放按新
## 指令流可能建出东西来 —— 读档后凭空多出一个立绘
const STAGE_AUTO := ""
const STAGE_SNAPSHOT := "snapshot"
const STAGE_REPLAY := "replay"

## 预取往后看多少条指令。数值与 Ren'Py 的 config.predict_statements 一致
const PREFETCH_DEPTH := 32

## ATL 运行时。只借它的静态方法读 wait 时长 —— 播放器不推进任何动画，
## 那是显示层的事。preload 而不是 class_name：新脚本第一次被引用时，
## 全局类表可能还没登记它
const ATL_SCRIPT := preload("res://vn/ui/atl.gd")

## 快照里 delta 的撤销逻辑。纯静态函数库、没有实例，所以同样走 preload ——
## 理由与 ATL_SCRIPT 一样，而且它不该为了几个纯函数去占一个全局类名
const SNAPSHOT := preload("res://vn/snapshot.gd")

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

## 待生效的内联跳转，存目标 label 名。空串表示没有。
##
## 由台词里的 {jump=} / {call=} 点击写进来，消费点与 _pending_wait 在同一个
## 循环顶。不就地改 _cursor 是因为玩家点链接发生在 GUI 事件里，那时播放器
## 正等着下一次推进 —— 把跳转排进"下一条指令"，语义就和剧本里的一条
## jump 完全等价，不用为它单独维护一条执行路径
var _pending_jump := ""
## 上面那次内联跳转是不是 call。true 表示读完目标 label 还要回到触发它的那句。
##
## 两个标签共用 _pending_jump 存目标名，只用这个开关区分 —— 目标名、校验、
## "目标不存在就报错并照常推进"那几段完全一样，没有第二个字段的必要
var _pending_call := false

## 玩家点过 {jump=} 的位置，每项 { sid, target }。
##
## 重放要靠它复现"那一次偏离主线"。{call=} 不用记在这里 —— 它压的栈帧
## 里有 target，重放从调用栈取；{jump=} 不压栈，跳完什么都不剩，
## 不自己记一份就永远还原不出来。
##
## **只增不减**：一条记录产生后一直有效，重放按 sid 查找。同一条台词
## 点两次只是重复同一个跳转，不必区分先后。换位置（start / 读档）时
## 跟着位置快照一起清空或覆盖
var _inline_jumps: Array[Dictionary] = []

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
		# 变量同理，但要走 default 表：先清空，再按声明灌初值。
		# 上一局没被声明过的量不该带着数跑进新局
		session.reset_vars(story.defaults)

	_label_name = label_name
	_label_begin = begin
	# 重放的起点。jump 走再远，重建时也要从会话入口重新走一遍
	# 才能得到正确的路径 —— 见 rebuild_stage()
	_session_label = label_name
	_call_stack.clear()
	# 上一局点过的内联跳转不能带到新的一局：重放按 sid 匹配，
	# 而 sid 在同一份剧本里是固定的，留着会让新的一局凭空偏离主线
	_inline_jumps.clear()
	# 章节报告重新计数：新的一局从入口 label 重新开始，
	# 即便入口和上一局的最后一章同名，也该再报一次
	_last_announced_label = ""
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
	# 补齐剧本里声明过、但变量表里还没有的量。NEW_GAME 上面那条 reset_vars
	# 已经把整张表灌好了，这里对它是空操作；CONTINUE（章节切换）才是它
	# 真正起作用的地方 —— 新章节新增的 default 不该等到第一次 += 才从零起算。
	# 对应 Ren'Py 在开局与读档后各调一次的 execute_default_statement
	_apply_missing_defaults()
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

		# 内联跳转：玩家点了台词里的 {jump=} / {call=} 链接。
		# 放在 _cursor += 1 之前，等价于"在当前句后面插了一条 jump / call"；
		# 目标不存在时只报错并继续往下走，不让玩家端结束 ——
		# 因为这一下是玩家点出来的，卡在原地比走错更难受
		if not _pending_jump.is_empty():
			var jump_name := _pending_jump
			var is_call := _pending_call
			_pending_jump = ""
			_pending_call = false
			var jump_target := story.label_start(jump_name)
			if jump_target < 0:
				push_error("内联跳转的目标不存在：%s" % jump_name)
			elif is_call and not _push_text_call(jump_name):
				# 栈太深。当作普通推进：这一次点击被吃掉，不跳
				push_error("内联 call 的嵌套层数已达上限，已改为普通推进")
			else:
				if not is_call:
					# 只有 {jump=} 要记：call 的目标在栈帧里，而 jump 跳完
					# 什么都不剩，重放没有别的来源
					_inline_jumps.append({
						"sid": current_sid(),
						"target": jump_name,
					})
				_cursor = jump_target - 1
				continue

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
			continue

		# 变量赋值。读档恢复时跳过 —— 变量随存档整份还原了，再从
		# 入口重放一遍 "+=" 就会把值算多。与 save 指令同一个理由
		if kind == "set":
			if _restoring:
				continue
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

		# 存档。和音频那几条同一类：不产生台词、不停顿、不碰舞台。
		# 只挡重放 —— 读档恢复会把剧本从头走一遍，那不是玩家在存档，
		# 不挡的话一次读档就可能把存档点覆盖掉。
		# 快进照常执行：快进只是玩家跳着读，路是走过了的，
		# 作者用 save 标出的节点（流程图档靠它）一个都不能少
		if kind == "save":
			if _restoring:
				continue
			_apply_save(op)
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

## 请求一次内联跳转。由界面在玩家点中台词里的 {jump=} 链接时调用。
##
## 真正的跳转发生在 advance() 的循环顶：这里只登记目标，然后当成一次
## 普通推进 —— 玩家点链接本来就是"往下走"这个动作，不该和点击分两套路径
func request_jump(label_name: String) -> void:
	if not _playing:
		return
	_pending_jump = label_name
	_pending_call = false
	advance()

## 请求一次内联调用。由界面在玩家点中台词里的 {call=} 链接时调用。
##
## 与 request_jump 共用一条登记通道，差别只在消费时压不压调用栈：
## call 的目标走到 return 会回到**触发它的那一句**，也就是玩家点的那句台词
func request_call(label_name: String) -> void:
	if not _playing:
		return
	_pending_jump = label_name
	_pending_call = true
	advance()

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
		"inline_jumps": _inline_jumps.duplicate(true),
		"session_label": _session_label,
		"path": package_path,
	}

## 恢复到某个位置快照，并立刻播出该处（或它之后的第一句台词）。
##
## 调用方负责保证快照里的 cursor 对**当前**指令流有意义 ——
## 这份接口不做校验，也没法做：它不知道指令流换过没有。
##
## poses 是快照里那份各 tag 的显示姿态。给了解析出来的节点才能停在该停的
## 位置上；不给就走显示层自己的"销毁前抓一份"那条路
##
## stage_snapshot 是舞台结构。stage_source 决定信不信它：
##   STAGE_SNAPSHOT  一定按它还原（读档、历史回跳、热重载）
##   STAGE_REPLAY    一定重放指令流（将来的"按新剧本重算画面"）
##   STAGE_AUTO      空字典才重放，留给不传来源的老调用方
##
## 三条路现在都传 STAGE_SNAPSHOT。历史条目带结构之后，"回跳只能重放"
## 那个限制消失了 —— 重放要求控制流完全可复现，而 {call=} 这类由玩家
## 点出来的分支只在调用栈里，重放要额外维护一堆匹配逻辑（见 rebuild_stage）
func restore_position(snapshot: Dictionary, poses: Dictionary = {},
		stage_snapshot: Dictionary = {},
		stage_source: String = STAGE_AUTO) -> void:
	if not _check_ready():
		return

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

	# 内联跳转记录。旧快照没有这一项，空数组等价于"这一路没点过链接"——
	# 那种情况下重放本来就走主线，与旧版本行为一致
	_inline_jumps.clear()
	var hops: Array = snapshot.get("inline_jumps", [])
	for hop in hops:
		if hop is Dictionary:
			_inline_jumps.append((hop as Dictionary).duplicate(true))

	# 舞台来源先定下来，下面的顺序要按它分叉
	var use_snapshot := not stage_snapshot.is_empty()
	if stage_source == STAGE_SNAPSHOT:
		use_snapshot = true
	elif stage_source == STAGE_REPLAY:
		use_snapshot = false

	_playing = true
	# 恢复途中遇到 with_run 直接跳过。读档是定位，不是播放
	_restoring = true

	# ── 顺序：舞台先就位，再往后执行 ──
	#
	# 反过来的话（先 advance 再贴快照），advance 执行的那些 scene / show
	# 会被"存档那一刻"的旧快照整个盖掉。存档点落在 scene 之前时那份快照
	# 正是空的 —— 表现就是"读档后剧情已经走到第一句，画面却全空"。
	# ep0.vns 的 fc-ep0_1 就是这种存档点：save 在 scene bg1 的两行之前。
	#
	# 重放路径只能倒过来：它要靠 advance() 先把 _cursor 推到目标句，
	# 才能从会话入口重放到那里。两条路的差异只在这一处
	if use_snapshot:
		session.restore_stage(stage_snapshot, poses)
		advance()
		_restoring = false
	else:
		advance()
		_restoring = false
		rebuild_stage(poses)

	# advance() 只在途中遇到 label 指令时才更新 _label_begin。
	# 从一句台词直接恢复时它不会经过 label，所以这里补一次同步
	_sync_label_at_cursor()

## 从磁盘重新读一遍剧本包。
## 调用方负责在此之前取好位置快照，之后用 restore_position() 放回去
func reload_story() -> bool:
	if story.path().is_empty():
		return false
	return story.reload()

###########################################################
#  存档状态
###########################################################

## 取一份完整快照：位置、舞台、变量、角色属性、历史、音乐、姿态。
##
## 三条路共用这一份 —— 存档（VNSave 把它切成两块字节）、历史回跳（条目里
## 存的是它的迷你版）、热重载（重载前后各取一次）。
##
## 与 capture_position() 的分工：那个只回答"停在哪"，这个回答"这一局是什么
## 样"。存档要后者，热重载要后者，两个接口都留着是因为 rebuild 那一侧只要
## 位置。
##
## 键名全部取自 VNSave.F_* —— 形状只有一份定义，存与读不会走散
##
## ── 舞台为什么要存 ──
## 早先不存，靠 restore_position() 从会话入口重放指令流重建。那个办法要求
## 控制流完全由指令决定，而 {call=} 是玩家点出来的：它不是一条 call 指令，
## 重放走到那里看不见，存档停在它内部时重放会一路跑到剧本末尾，
## 把整份剧本的 show / scene 全应用一遍 —— 舞台变成结局态，比不重建更糟。
##
## 代价是存档记的是"那一刻的画面"：之后删掉某个角色再读旧档，那个立绘
## 还会出现。它与 Ren'Py 存 scene_lists 是同一个取舍 —— 存档是一份快照，
## 不是一份可以按新剧本重新演算的剧本。
##
## F_STAGE 存结构（谁在台上），F_POSE 存姿态（他们在哪）：
## 前者指令里没有，后者只有那一帧才有，两样都得留下来
func capture_snapshot() -> Dictionary:
	return {
		VNSave.F_POSITION: capture_position(),
		VNSave.F_SID: current_sid(),
		VNSave.F_ANCHORS: VNPosition.anchors_from(story.ops, _cursor),
		VNSave.F_ROLES: session.roles_data(),
		VNSave.F_STAGE: session.stage(),
		VNSave.F_HISTORY: session.history_data(),
		VNSave.F_VARS: session.vars_data(),
		VNSave.F_BGM: audio.current_bgm() if audio != null else "",
		VNSave.F_WHAT: session.interpolate(tr(session.last_say_text())),
		VNSave.F_POSE: session.stage_poses(),
	}

## 存档用的旧名字。内容层（save_entry.gd / main.gd）还在叫它，
## 行为与 capture_snapshot() 完全一样
func capture_state() -> Dictionary:
	return capture_snapshot()

## 从一份快照恢复整局状态，并立刻播出目标那一句。
##
## 这是**唯一**的恢复路径：读档、历史回跳、热重载都走它。顺序在下面逐条
## 注明，每一处的先后都不能换 —— 换过的症状都写在各自那段注释里。
##
## opts 目前只认一个键 "resolved"：true 表示 F_POSITION 已经过
## VNPosition.resolve()，不要重复迁移（热重载就是这种）。默认 false。
func restore_snapshot(snap: Dictionary, opts: Dictionary = {}) -> bool:
	if not _check_ready():
		return false

	if snap.is_empty():
		push_error("恢复快照：数据为空")
		return false

	# 指令流不在就先加载。从主菜单读档时 VN 还没开播、story 是空的；
	# 从剧情里读档时它已经在，重读一次纯属浪费
	if story.ops.is_empty() and not story.load_story(package_path):
		push_error("恢复快照：剧本加载失败 %s" % package_path)
		return false

	# 上一段剧情留下的变更日志到此作废。不清的话，回跳之后下一句的
	# vars_delta 里会混进读档之前那些改动 —— 那些改动属于被丢掉的时间线
	session.discard_journal()

	# ── 定位：把快照里的下标搬到当前指令流上 ──
	#
	# 快照可能是上一个剧本版本存的，cursor 不能直接用。三级策略与热重载
	# 共用同一份实现，见 vn/position.gd
	var snapshot: Dictionary = snap.get(VNSave.F_POSITION, {})
	var moved := snapshot
	if not bool(opts.get("resolved", false)):
		moved = VNPosition.resolve(snapshot,
			int(snap.get(VNSave.F_SID, 0)),
			snap.get(VNSave.F_ANCHORS, PackedInt64Array()),
			story.ops, Callable(story, "label_start"))
		_report_resolution(moved)

	# ── 数据先就位，再放回位置 ──
	#
	# restore_position() 内部会 advance()，那会立刻播出目标那一句并把它
	# 追加进历史。历史必须先就位，VNHistory.add() 的"只比最后一条"去重
	# 才挡得住这次重复追加。反过来的话，读档后历史末尾会多出一条
	# 一模一样的
	session.restore_roles(snap.get(VNSave.F_ROLES, {}))
	session.restore_vars(snap.get(VNSave.F_VARS, {}))
	# 变量就位之后立刻补 default：advance() 里的插值要读它们，缺了的
	# 变量会以 "[gold]" 的形式原样印在台词上
	_apply_missing_defaults()
	session.restore_history(snap.get(VNSave.F_HISTORY, []))

	# 交回给下一句的变更记录。热重载截掉历史最后一条时，那条里的 delta
	# 不能丢 —— 并回日志，_show_current() 重写这一句时会把它们带走。
	# 读档不走这条：存档里的历史是完整的，没有任何条目被临时拿掉
	var carry: Dictionary = opts.get("carry_delta", {})
	if not carry.is_empty():
		session.merge_journal(carry.get("vars", {}), carry.get("roles", {}))

	# ── 音乐 ──
	#
	# 必须在 restore_position() **之前**：它会 advance() 到目标那一句并
	# 走 _show_current()，那里拿 audio.current_bgm() 写进新历史条目。
	# 晚一步切的话，历史记下的还是切换前那首旧曲子。
	#
	# 一律从头重播（play_bgm_from 不判重），与历史回跳同一个语义。
	# play_bgm() 会在"同一首正在播"时直接返回，读档就变成了"接着放" ——
	# 那是回主菜单、章节往返要的连播，不是回到过去该有的行为。
	#
	# 空串走 stop_bgm() 而不是 play_bgm("")：后者会去检查一个不存在的
	# 资源路径然后打一条"背景音乐缺失"的警告 —— 那是误报，
	# "存档时本来就没有音乐"是完全正常的状态
	var bgm := String(snap.get(VNSave.F_BGM, ""))
	if audio != null:
		if bgm.is_empty():
			audio.stop_bgm()
		else:
			audio.play_bgm_from(bgm, 0.0)

	# ── 位置与舞台 ──
	#
	# 舞台来源写死 STAGE_SNAPSHOT：快照里就是那一刻的画面，重放只会因为
	# 剧本改动而算歪。热重载也用快照 —— 角色被删掉的 tag 由显示层跳过，
	# 那比"清空舞台"更接近玩家重载前看到的东西
	restore_position(moved,
		snap.get(VNSave.F_POSE, {}),
		snap.get(VNSave.F_STAGE, {}),
		STAGE_SNAPSHOT)

	return true

## 按剧本的 default 表补齐**当前不存在**的变量。
##
## 对应 Ren'Py 的 execute_default_statement(False)：读档与回滚之后都会调用
## （rollback.py:1045）。补的是"旧存档里还没有这个变量"的情况 —— 剧本后来
## 加了 default，玩家读旧档时那个量必须有初值，否则第一次 "+=" 会从零值
## 起算，插值则直接把 [变量名] 露在台词里。
##
## start=False 的语义：已经存在的变量**不覆盖**。这正是它与 reset_vars()
## 的分界 —— 后者是开新局，前者是"把缺的补上"
func _apply_missing_defaults() -> void:
	for d in story.defaults:
		if not (d is Dictionary):
			continue
		var path := String(d.get("path", ""))
		if path.is_empty() or session.has_var(path):
			continue
		session.set_var(path,
			VNSession.decode_value(String(d.get("kind", "s")),
				String(d.get("value", ""))),
			"=", false)

## 把位置迁移走了哪一级报出来。读档时这是玩家唯一能感知到"落点不是原来
## 那一句"的线索，不该静默发生。
##
## 热重载有自己更细的报告（见 vn/dev/hot_reload.gd），那边传 resolved=true
## 跳过这一步，免得同一个判断被报两次
func _report_resolution(moved: Dictionary) -> void:
	match String(moved.get("how", "")):
		VNPosition.HOW_ANCHOR:
			# sid 还在、只是那条指令不是台词 —— 剧本里写的流程存档点
			# （ep0.vns 的 save "fc-ep0_1" 那种）就属于这一类：存档时游标
			# 停在 save 上，锚点算出来的位置与存档时完全一致，落点是精确的。
			# 只有 sid 真的不在了才是"这句被改写"，那时落点是估出来的
			if not bool(moved.get("sid_found", false)):
				push_warning("读档：这一句在当前剧本里已被改写，按上下文就近恢复")
		VNPosition.HOW_LABEL, VNPosition.HOW_STACK:
			push_warning("读档：这一句在当前剧本里找不到了，已退回章节开头")

## 存档用的旧名字。行为与 restore_snapshot() 完全一样
func restore_state(data: Dictionary) -> bool:
	return restore_snapshot(data)

## 回跳到历史里的第 index 条。成功返回 true。
##
## 历史条目带的是那一刻的迷你快照：位置、舞台结构、姿态、音乐，以及变量与
## 角色属性的变更日志。所以回跳只是"恢复一份快照" —— 与读档同一条路，
## 不再靠重放指令流去猜画面。
##
## ── 这是读档，不是 rollback ──
## 回跳之后"未来"就不存在了：历史截断、变量贴回、音乐重播。Ren'Py 的
## rollback 会保留一个 forward 栈让玩家再走回去，但那条路上回滚是步进式的
## （滚轮一格退一句，容易退过头）。这里是列表点选，精确到某一条，不存在
## 退过头 —— 所以不需要 forward，回跳就是重开一条分支。
##
## ── 顺序：先算数值、再截断、最后恢复位置 ──
##   数值    要从**当前**状态往回贴，所以必须先取 index 之后那些条目
##   截断    在 restore_snapshot() 之前：它内部 advance() 会显示目标那一句
##           并追加历史，那一次追加会被 add() 的 sid 去重挡掉，但前提是
##           历史已经是截断后的样子
##   位置    最后，它把画面与台词一起换过来
## position 是可选的**已迁移位置**。不传时用条目里记的那份 —— 同一次会话
## 内的历史跳转，指令流没换过，它直接可用。传了就在恢复时跳过 resolve：
## 热重载刚换过指令流，它手里那份是按新流算过的，比这里重新猜一次准
func jump_to_history(index: int, position: Dictionary = {}) -> bool:
	var entry := session.history().at(index)
	if entry.is_empty():
		return false

	# 剧本拆包之后，旧快照里的 cursor 在新指令流里没有意义。
	# 当前全项目只有一个包，这一条永远不会命中 —— 留着是给将来拆包的护栏
	var snapshot: Dictionary = entry.get("position", {})
	if not position.is_empty():
		snapshot = position

	if String(snapshot.get("path", "")) != package_path:
		push_warning("历史回跳：这一句属于另一个剧本包（%s），跳不回去"
			% snapshot.get("path", ""))
		return false

	# ── 撤销 index 之后那些条目记录的数值变更 ──
	#
	# 从最后一条往前贴。同一条路径被改过多次时，靠后那条记的旧值才是
	# "贴回该得到的那个值" —— 顺序反了会把更早的值写回去。
	# 不需要基准点：贴的是绝对值，不是差值
	var vars := session.vars_data()
	var roles := session.roles_data()

	# 还压在 journal 里的那些改动比任何历史条目都晚，所以先撤它们。
	#
	# 什么时候会有：玩家停在 save / pause 这类非台词指令上时，那之前的
	# set 已经执行、但上一条历史条目早就 take_journal() 过了，于是它们
	# 没有归属。不回卷这一段，回跳后的数值会多算
	var pending := session.take_journal()
	SNAPSHOT.apply_vars_delta(vars, pending["vars"])
	SNAPSHOT.apply_roles_delta(roles, pending["roles"])

	var tail := session.history().from_index(index + 1)
	for i in range(tail.size() - 1, -1, -1):
		SNAPSHOT.apply_vars_delta(vars, tail[i].get("vars_delta", {}))
		SNAPSHOT.apply_roles_delta(roles, tail[i].get("roles_delta", {}))

	# ── 截断并拼一份迷你快照 ──
	#
	# 这就是这个条目的全部内容。恢复完它，屏幕上、数值上、声音上都是
	# "当年播到这一句时"的样子
	session.truncate_history(index + 1)

	var snap := {
		VNSave.F_POSITION: snapshot,
		VNSave.F_SID: int(entry.get("sid", 0)),
		# 历史条目不带锚点。不传 position（也就是玩家在界面里点历史）时
		# 靠 sid 命中就够了 —— 同一次会话内指令流没换过，那一句必然还在。
		# 真命不中（热重载之后又点了历史）就退回 label 开头，那种粗落点
		# 是可以接受的：热重载那条路自己会传 position，用不上这里
		VNSave.F_ANCHORS: PackedInt64Array(),
		VNSave.F_ROLES: roles,
		VNSave.F_STAGE: entry.get("stage", {}),
		VNSave.F_HISTORY: session.history_data(),
		VNSave.F_VARS: vars,
		VNSave.F_BGM: String(entry.get("bgm", "")),
		VNSave.F_POSE: entry.get("pose", {}),
	}
	# 传了位置就说明调用方已经迁移过，别再 resolve 一遍 —— 那会把一份
	# 精确的落点重新交给启发式去估
	return restore_snapshot(snap, {"resolved": not position.is_empty()})

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
		# 这一局不在了，压在 journal 里还没归属的改动也一并作废
		session.discard_journal()
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
## set **不**重放：变量是随存档整份还原的（VNPlayer.restore_state 里先于
## 定位就位），重放一遍 "+="/"-=" 就会把值算多。同理也不调
## session.reset_roles() —— 那会把属性打回 define_role() 的初始值，
## 毁掉 StartMode.CONTINUE 带过来的跨章节状态
##
## 舞台状态写进 session，重放的循环控制留在本类 —— 两边各管一段：
## session 不知道剧本存在，本类不直接碰 _stage 那份字典
##
## ── {call=} 也要重放 ──
## 它的目标只存在于调用栈里（玩家点出来的，指令流里没有）。而历史跳转
## 不带舞台结构快照 —— 历史条目一条存一份舞台会让存档胖几百 KB ——
## 所以回跳到子剧情里的某一句，只能靠重放把那次调用复现出来。
## 复现的信息全部来自栈帧：sid 认出触发句，target 指出跳去哪
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
	# 台词里的 {call=} 压的帧，按栈序排列。
	#
	# 这类调用没有对应的 call 指令 —— 目标是玩家点出来的，只存在于栈帧里。
	# 重放要复现它，只能从这里取目标。按顺序消费而不是"按 sid 查找"：
	# 同一条台词被点两次就压两帧，查找到的永远是第一帧，重放会一直在
	# 第一次调用的子剧情里打转
	var text_calls: Array[Dictionary] = []
	for frame in _call_stack:
		if frame.has("target"):
			text_calls.append(frame)
	var next_text_call := 0
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
		var op_kind := String(op["op"])

		# 这台词是不是某次内联跳转的触发句。命中就照真实执行那样偏离主线，
		# 否则重放会沿着主线一路走下去，永远到不了点过链接才去的地方。
		#
		# jump 与 call 分开查：前者跳过目标就不回来了，不压栈；
		# 后者要压一层返回地址，落点由调用栈帧给出
		if op_kind == "say" or op_kind == "say_literal":
			var op_sid := int(op.get("sid", 0))

			var hop := _find_inline_jump(op_sid)
			if not hop.is_empty():
				var hop_to := story.label_start(String(hop.get("target", "")))
				if hop_to >= 0:
					pc = hop_to
					continue

			if next_text_call < text_calls.size():
				var text_frame: Dictionary = text_calls[next_text_call]
				if int(text_frame.get("sid", 0)) == op_sid:
					next_text_call += 1
					var text_to := story.label_start(
						String(text_frame.get("target", "")))
					if text_to >= 0:
						# 落点用帧里记的那个数（就是这条 say 的下标），
						# 不用 pc —— 两者必须相等，而拿帧里的值才能保证
						# _stack_matches() 比的是同一样东西
						returns.append(int(text_frame.get("return_index", 0)))
						pc = text_to
						continue

		match op_kind:
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
		# 已经尽力了，舞台这边如实说一声。
		#
		# 清空而不是留着：循环跑到预算耗尽时，_stage 里装的是"整份剧本
		# 一路 show 到末尾"的结果，那是错的画面。空舞台至少一眼看得出
		# "重建失败了"，错乱的立绘反而会被当成剧本问题去查
		push_warning("舞台重建没能走到当前位置（label \"%s\"，游标 %d），"
			% [_session_label, _cursor] + "已清空舞台")
		session.clear_stage()

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
##
## ── text call 的帧也在这张表里 ──
## {call=} 压的帧同样带 return_index（记的是触发它的那条 say 的下标），
## 重放用帧里的值往 returns 里压，所以两边比的仍然是同一样东西。
## 读档不走重放（存档有 F_STAGE 舞台快照），这条比对留给热重载与历史跳转
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

## 从内联跳转记录里找出这条台词点过一次的那一条。没有则返回空字典。
##
## 同一条台词点两次 {jump=} 只是重复同一个跳转 —— 第一次跳走之后就不会
## 再回到那条台词，所以取第一条即可，不必区分先后。
## sid 为 0 直接当作"没有"：那是没分配 sid 的指令，匹配它只会误伤
func _find_inline_jump(sid: int) -> Dictionary:
	if sid == 0:
		return {}
	for hop in _inline_jumps:
		if int(hop.get("sid", 0)) == sid:
			return hop
	return {}

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

## 压一层"台词里的 call"栈帧。目标 label 由调用方负责跳过去。
##
## 与 _enter_call 的两点差别：
##   · return_index 记的是**当前这一句**，不是它的下一条 —— 这是 Ren'Py
##     from_current 的语义：读完目标 label 回来，玩家还停在这句台词上，
##     于是这句会重新显示一次（打字机重打、语音重播、历史可能多一条）。
##     Ren'Py 文档对这个开关的说明就是 "the current statement being run twice"
##   · sid 记的是这句台词的 sid：调用栈靠它在新旧指令流里认出"是同一句"
##
## 目标 label 若不以 return 收尾，这一帧会一直留在栈上 —— 编译期查不出
## （要跨 label 做控制流分析），与 Ren'Py 一样把这条当作者责任
func _push_text_call(label_name: String) -> bool:
	if _call_stack.size() >= MAX_CALL_DEPTH:
		return false

	_call_stack.append({
		"sid": current_sid(),
		"return_index": _cursor,
		"label_name": _label_name,
		"label_begin": _label_begin,
		"target": label_name,
	})
	return true

## 弹一层调用栈并回到帧里记的落点。栈空时返回 false。
##
## 落点由压栈方决定：call 指令记的是"它的下一条"，台词里的 {call=} 记的是
## "触发它的那一句"（Ren'Py 的 from_current）。这里只负责照做，不区分来源。
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
##
## args 布局（编译期钉死）：[0] 路径  [1] 类型  [2] 值的字面形式  [3] 运算符
## 类型是 s / i / f / b 之一 —— .vnbc 的参数只有字符串，不带着它
## 3 和 "3" 就分不开
##
## 路径首段是 role 时是角色属性，值是字符串、只接受 "="；
## 其余一律是普通变量，走 VNSession 的变量表
func _apply_set(op: Dictionary) -> void:
	var args: Array = op["args"]
	if args.size() < 4:
		push_error("set 指令的参数不完整：%s" % str(args))
		return

	var path := String(args[0])
	var value: Variant = VNSession.decode_value(String(args[1]), String(args[2]))
	var how := String(args[3])

	if path.begins_with(VNSession.ROLE_PATH_ROOT + "."):
		var segments := path.split(".")
		if segments.size() != 3:
			push_error("set 的 role 路径形状不对：%s" % path)
			return
		session.set_character_property(segments[1], segments[2], String(value))
		return

	session.set_var(path, value, how)

## 玩法侧写变量。路径必须是剧本里 default 声明过的，否则拒绝。
##
## 走和剧本 set 完全一样的那条路（VNSession.set_var），所以玩法侧不需要
## 自己判类型，也不会写出一个剧本里不存在的变量
func set_var(path: String, value: Variant) -> bool:
	if not is_var_declared(path):
		push_error("VN.set_var：\"%s\" 没有 default 声明，不能凭空创建变量" % path)
		return false
	session.set_var(path, value, "=")
	return true

## 这个路径是不是剧本里声明过的变量（含点路径）
func is_var_declared(path: String) -> bool:
	for d in story.defaults:
		if d is Dictionary and String(d.get("path", "")) == path:
			return true
	return false

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

## 执行 save。把槽名和此刻的进度快照一起交给应用层。
##
## 快照必须在这里取：save 后面常常紧跟 jump / call，它们会立刻改 _cursor。
## 让应用层到帧末再 capture_state()，存下来的位置已经是好几条之后了。
##
## 不等待落盘 —— 播放器不认识文件，抓缩略图和写盘都是应用层的事
func _apply_save(op: Dictionary) -> void:
	var args: Array = op["args"]
	if args.is_empty():
		return
	save_requested.emit(String(args[0]), capture_state())

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

## 丢掉还没生效的 ATL wait 与内联跳转。
##
## 换位置的入口调用它：那条 show 已经在上一处执行过了，它的等待属于
## "从那条指令往下走"的流程，新位置不该继承。内联跳转同理 —— 玩家的
## 那一下点击是针对旧位置的，搬走之后就作废了。
## 和 _clear_pause 分开，是因为两者的生命周期不同 ——
## pause 是"正在等"，pending 是"马上要执行"
func _clear_pending_wait() -> void:
	_pending_wait = 0.0
	_pending_wait_tag = ""
	_pending_jump = ""

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
	# 历史和附言存的是**原文**，只有发给界面的那两段是译文。
	#
	# 曾经存的是译文，理由是"历史记的是玩家当时读到的内容"。但那样切语言
	# 之后旧记录永远停在上一门语言 —— 而且 tr() 是单向的，存了译文就再也
	# 拿不回 msgid。现在改为存原文、显示时翻译（见 history.gd 与
	# save_load.gd 的附言渲染），旧存档里的译文会被 tr() 原样返回，
	# 两种格式可以共存。
	#
	# 位置用 capture_position()：advance() 是先加一后取，走到这里时
	# _cursor 正指着这条 say 指令，快照拿到的就是它。快进时同样会走到
	# 这里，所以快进过的句子照记，和 Ren'Py 一致
	var shown_who := tr(who)
	# 插值放在 tr 之后：译文里同样可以写 [变量]。历史存的是原文，
	# 那边显示时再各自插值一次
	var shown_text := session.interpolate(tr(text))
	session.set_last_say_text(text)

	# "这一刻"的五样东西一起抓：位置、舞台结构、姿态、音乐、数值变更。
	#
	# 每一样都只在当下存在：从 ep1 跳回 ep0 时，屏幕上没有第五句该有的
	# 画面，变量表里也只有最新的值。所以不能等回跳时再取。
	#
	# take_journal() 取走的是"这一句之前累积的那些 set"。取走即清空，
	# 下一句的 delta 从零开始 —— 这正是 delta 链能逐条撤销的前提
	var journal := session.take_journal()
	session.add_history(current_sid(), who, text, voice,
		capture_position(), {
			"pose": session.stage_poses(),
			"stage": session.stage(),
			"bgm": audio.current_bgm() if audio != null else "",
			"vars_delta": journal["vars"],
			"roles_delta": journal["roles"],
		})

	line_shown.emit(shown_who, shown_text)

	# 章节报告放在 line_shown 之后：这一刻界面已经拿到台词了，
	# 应用层收到就能接着做"抓图 + 存档"这件事
	_announce_chapter()

## 切语言之后重译**当前停在的这一句**。
##
## ── 只重发 line_shown ──
## 语音、章节报告都不动：语音已经在播了，重译不该让它从头再来；
## 章节报告只在真正进入新章节时发一次。
##
## 历史**不用动**：它存的是原文，切语言后由 history.gd 在显示时翻译。
##
## ── 附言也存原文 ──
## 存档的附言取"最近一句台词的原文"（session 的 last_say_text），
## 显示时才翻译。所以这里更新它是为了"切完语言马上存档"那一刻附言正确，
## 而不是为了把译文写进存档
##
## 停在非台词指令（pause、scene 之类）上时什么都不做 —— 那种时刻屏幕上
## 没有可翻的文字
func retranslate_current() -> void:
	if not _playing or _cursor < 0 or _cursor >= story.ops.size():
		return

	var op: Dictionary = story.ops[_cursor]
	var kind: String = op["op"]
	if kind != "say" and kind != "say_literal":
		return

	var args: Array = op["args"]
	var who_raw := String(args[0]) if args.size() > 0 else ""
	var text := String(args[1]) if args.size() > 1 else ""
	var who := who_raw if kind == "say_literal" else _resolve_role_name(who_raw)

	# 和 _exec 里那条路保持一致：先 tr 再插值。只 tr 不插值的话，
	# 切完语言停在带变量的句子上，占位符会原样露出来
	var shown_text := session.interpolate(tr(text))
	session.set_last_say_text(text)
	line_shown.emit(tr(who), shown_text)

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

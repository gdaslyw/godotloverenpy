class_name VNSteam
extends RefCounted

# ═══════════════════════════════════════════════════════════
#  Steam 接入与正版校验。
#
#  ── 它负责什么 ──
#  初始化 Steamworks、持有那个单例、回答"当前账号有没有本作"。
#  成就系统从它这里拿单例；正版校验读它的三态判定。
#
#  ── 它不负责什么 ──
#  **不决定"没通过时怎么办"**。要不要拦、拦下来显示什么、拦完退不退出，
#  全是内容层的事。本类只回答"该不该拦"。
#
#  这条界线是框架/内容的界线：vn/ 里不该出现任何一句写给玩家的文案。
#  换一个项目就该换一套完全不同的提示界面，而判定逻辑不必重写。
#
#  ── 为什么全是 Object.call() ──
#  vn/ 是要复制到别的项目里的框架，那边可能根本没装 GodotSteam。
#  源码里只要出现一个 Steam.xxx，整份文件在解析期就会报
#  "Identifier Steam not declared" —— 连"没有 Steam 的那条路"都跑不起来。
#  Engine.has_singleton() + Object.call() 把依赖推迟到运行时。
#
#  ── 三态而不是两态 ──
#  "Steam 用不了"和"Steam 能用但没买"必须分开。合成一种的话，
#  正版玩家只要换个启动方式（从文件夹双击 exe）就会被当成盗版踢出去。
# ═══════════════════════════════════════════════════════════

## Steam 这一路的可用性与所有权。
enum State {
	## 用不了：没装插件、安卓 / Web、客户端没开、初始化失败。
	## 这不是错误，是常态 —— 编辑器里跑、自检、安卓包都落在这一态
	UNAVAILABLE,
	## 能用，且当前账号拥有本作。家庭共享与免费周末也算拥有
	OWNED,
	## 能用，但当前账号不拥有本作
	NOT_OWNED,
}

## Steam 单例。null 表示这一路不可用
var _steam: Object = null
## 缓存的判定结果。setup() 算一次，之后不再变 —— 玩家不会在游戏运行中途
## 买下本作，而每帧查一次 isSubscribed() 是白花一次原生调用
var _state: int = State.UNAVAILABLE

###########################################################
#  生命周期
###########################################################

## 尝试初始化 Steam 并判定所有权。不成功不报错，只是 state() 落在 UNAVAILABLE。
##
## 由 VNFrame._ready() 在创建成就之前调一次 —— 成就要用这里的单例。
func setup() -> void:
	_state = State.UNAVAILABLE
	_steam = null

	# 安卓与 Web 没有 Steam 客户端。用户明确要求安卓不要尝试启动后端 ——
	# 那边 init 只会失败并刷一条没人看的警告
	if OS.has_feature("android") or OS.has_feature("web"):
		return

	# 没装 GodotSteam（或它没能加载）时这里就是假，一行都不往下跑
	if not Engine.has_singleton("Steam"):
		return

	var steam := Engine.get_singleton("Steam")
	if steam == null:
		return

	if not _initialize(steam):
		return

	_steam = steam
	_state = State.OWNED if _query_owned(steam) else State.NOT_OWNED

###########################################################
#  查询
###########################################################

## 当前的三态判定。State 之一
func state() -> int:
	return _state

## Steam 这一路到底能不能用。UNAVAILABLE 之外都为真
func is_active() -> bool:
	return _steam != null

## 当前账号是否拥有本作。Steam 不可用时为假 —— 所以判断"正版"要用
## should_block()，不能只看这个：没装 Steam 的正版玩家在这里同样是假
func is_owned() -> bool:
	return _state == State.OWNED

## Steam 单例，给成就之类的 Steam 功能用。不可用时为 null
func singleton() -> Object:
	return _steam

## 当前环境该不该把玩家拦在门外。
##
## 三条放行：编辑器（没有 Steam 客户端，也没人会从 Steam 启动开发中的游戏）、
## 非 Windows（安卓的包不在 Steam 上卖），以及真的拥有本作。
##
## 其余一律拦，包括"Steam 客户端没开"—— 那种情况玩家双击的是文件夹里的
## exe，而不是从库里启动，成就、云存档、浮层都不会工作
func should_block() -> bool:
	if OS.has_feature("editor"):
		return false
	if not OS.has_feature("windows"):
		return false
	return _state != State.OWNED

###########################################################
#  内部
###########################################################

## 调 steamInitEx 并检查返回码。成功返回 true。
##
## AppID 从 GodotSteam 自己的项目设置分组里读，框架不写死任何号 ——
## vn/ 是公开的框架，带上某部作品的应用号既没意义也不合适。
## 正式 id 优先，没有就退到 demo id（App Data 那组设置正是这个用途）
func _initialize(steam: Object) -> bool:
	var app_id := int(ProjectSettings.get_setting(
		"steam/initialization/app_data/app_id", 0))
	if app_id <= 0:
		app_id = int(ProjectSettings.get_setting(
			"steam/initialization/app_data/demo_id", 0))

	var result: Variant = steam.call("steamInitEx", app_id, false)
	if not (result is Dictionary):
		push_warning("Steam 初始化没有返回结果，这一路按不可用处理")
		return false

	var info: Dictionary = result
	var status := int(info.get("status", 1))
	if status != 0:
		# 2 = 连不上客户端，开发期最常见。降级为"只记本地"是正常路径，
		# 不是需要修的错误
		push_warning("Steam 初始化失败（状态 %d，%s）"
			% [status, String(info.get("verbal", ""))])
		return false

	return true

## 问 Steam 当前账号有没有本作。
##
## isSubscribed() 覆盖三种"有权运行"：自己买的、家庭共享来的、免费周末。
## 所以不必再单独查 isSubscribedFromFamilySharing()
func _query_owned(steam: Object) -> bool:
	return bool(steam.call("isSubscribed"))

class_name VNCubismLipSync
extends GDCubismEffectCustom

# ═══════════════════════════════════════════════════════════
#  Live2D 唇跟随。把 Voice 总线上的语音能量驱动成模型的口型参数。
#
#  ── 挂在哪、谁给它东西 ──
#    必须是 GDCubismUserModel 的**直接子节点**：基类的 _enter_tree() 会
#    cast 自己的 parent，挂到孙辈不会报错，只是永远不生效。
#    portrait_cubism.gd 在 _install_effects() 里按需挂它，并填三样：
#      parameter_ids  要驱动的参数名（从 .model3.json 的 LipSync 组来）
#      role_id        我是谁，用来判断当前这条语音是不是我的
#      player         查"语音还在不在播""属主是谁"
#
#    参数名不由本类解析：.model3.json 已经由 portrait_cubism.gd 在读
#    （表情表、动作表），Groups 段顺手一起解析，本类只管驱动。
#
#  ── 为什么每帧都得写 ──
#    GDCubismUserModel 默认的 parameter_mode 是 FULL_PARAMETER，这个模式
#    每帧开头会 CubismModel::LoadParameters() 把参数值整片覆盖回快照：
#        _parameterValues[i] = _savedParameters[i];
#    所以写进去的值只活一帧，下一帧不重写就没了。
#
#    反过来说，这也正是"松手"能成立的原因 —— **停写就等于把参数交还给
#    motion 和 expression**，不需要任何归还动作。
#
#  ── 写入时机只能是 cubism_process ──
#    模型每帧的更新序列是：
#        pro_update     motion / expression 写参数
#        efx_update     ★ cubism_process 在这里
#        参数写回循环    把 GDScript 侧的值落进模型
#        epi_update     物理 → pose → 烘焙
#        update_node    渲染
#    写在这里既能压过 motion（它在前面），又能参与物理与渲染（在后面）。
#
#  ── 松手时机看"语音在不在播"，不看能量 ──
#    语音里出现剧情需要的停顿是常态。若拿"能量归零"当松手条件，停顿那
#    几秒会交还控制权、语音恢复又抢回来，中间的 motion 会自己动一下嘴。
#    所以三者分开：
#      要不要驱动    ← 语音在不在播（player.is_voice_playing）
#      驱动成什么值  ← 音频能量（停顿期间自然是 0，嘴闭合，但仍在写）
#      什么时候松手  ← 语音真的播完了，且已衰减到 0
# ═══════════════════════════════════════════════════════════

## 读哪条总线。语音固定走 Voice（见 main.gd 的 _voice.bus），不做成可配
## 项 —— 每个角色一条总线在角色数上不可行，既然永远共用一条，
## 留一个没人会改的参数只是噪音
const BUS_NAME := &"Voice"
## 频谱效果在总线效果链里的下标。Voice 上目前只有这一个效果
const BUS_EFFECT_INDEX := 0

## 人声频率范围。下限取 0 而不是基频：爆破音和元音的低频能量对"嘴张多大"
## 有贡献，而 Voice 总线上只有语音、没有 BGM 与音效，不必靠抬下限来避噪
const FREQ_LOW := 0.0
const FREQ_HIGH := 3200.0
## 动态范围门限，单位 dB。低于 -60dB 视为完全无声。
## 它和 _read_target() 里那条公式一起把能量映射到 0..1
const MIN_DB := 60.0
## 死区。映射结果低于它一律当闭嘴，压掉底噪与呼吸声
const DEAD_ZONE := 0.05
## 张开速度，单位是每秒变化量。要快，否则口型跟不上起音
const ATTACK_RATE := 12.0
## 闭合速度。要慢，否则每个音节之间都会闪一下
const RELEASE_RATE := 4.0
## 音量补偿上限，单位 dB。理由见 input_gain_db
const MAX_INPUT_GAIN_DB := 12.0

## 总灵敏度。乘在映射结果上，是本类唯一暴露的旋钮
@export var sensitivity: float = 1.0

## 要驱动的参数名。由 portrait_cubism.gd 从 LipSync 组读出后填入
var parameter_ids: PackedStringArray = PackedStringArray()
## 本立绘的角色 ID。空串表示不检查属主，任何语音都驱动
var role_id := ""
## 查语音状态用。为空时退回"只看能量"的通用行为
var player: VNPlayer = null
## 音量补偿，单位 dB。
##
## 频谱分析器读到的信号位于**播放器音量之后、总线音量之前**，所以把
## 播放器音量补掉，就能让"玩家调小语音音量"不影响口型幅度。框架层按
##     input_gain_db = min(-播放器音量dB, MAX_INPUT_GAIN_DB)
## 算好填进来。
##
## 为什么要封顶：补偿会**同倍放大录音底噪**。数字静音（精确 0）不要紧，
## 但真实配音文件里"没说话"的地方并不是精确的 0，底噪典型在 -60dB 上下，
## 放大 20dB 后就跑到 -40dB，换算成口型值是 0.33 —— 嘴会半张着。
## 封顶在 +12dB 意味着音量 ≥ 25% 时完全补偿、幅度完全不变，
## 再往下才让口型随音量变小。
##
## 目前恒为 0（不补偿）：per-character 音量还没做。等做的时候顺带实测
## 一次"把语音音量调到 50%，看嘴是否变小"，确认频谱确实取在播放器音量
## 之后；若实测发现不受影响，这里保持 0 即可
var input_gain_db := 0.0

## 匹配到的参数对象。cubism_init 时填，cubism_term 时清。
## 不用类型化数组：GDCubismParameter 是扩展注册的类型，
## 普通 Array 少一层类型系统上的不确定性
var _params: Array = []
## 总线上的频谱分析器实例
var _spectrum: AudioEffectSpectrumAnalyzerInstance = null
## 口型当前值，0..1
var _level := 0.0
## 是否可用（参数和频谱都拿到了）
var _operable := false

###########################################################
#  生命周期
###########################################################

## 连接 C++ 侧发来的三个信号。
##
## 用字符串形式而不是 node.cubism_init.connect()：这几个信号由扩展的
## ADD_SIGNAL 注册，字符串写法不依赖 GDScript 对扩展类信号的静态解析，
## gd_cubism 自己的示例也是这么连的
##
## 父类没有 C++ 侧的 _ready() 覆写（GDCubismEffect 只覆写了 _enter_tree
## 与 _exit_tree），所以这里可以放心覆写，不需要 super
func _ready() -> void:
	connect("cubism_init", _on_cubism_init)
	connect("cubism_term", _on_cubism_term)
	connect("cubism_process", _on_cubism_process)

## 模型就绪。把要驱动的参数抓出来，并拿到总线的频谱实例。
##
## 模型重新加载时这个信号会再发一次（基类文档写明），所以每次都从零重建，
## 不做增量
func _on_cubism_init(model: GDCubismUserModel) -> void:
	_params.clear()
	_spectrum = null
	_operable = false
	_level = 0.0

	# 参数对象归模型所有，按 id 匹配。id 就是 .model3.json 里写的那个名字
	for item in model.get_parameters():
		var param := item as GDCubismParameter
		if param != null and parameter_ids.has(param.id):
			_params.append(param)

	if _params.is_empty():
		# LipSync 组为空的模型会走到这里（kei_vowels_pro 就是）。那是模型
		# 作者的明确表态，按约定静默跳过，不打日志
		return

	var bus_index := AudioServer.get_bus_index(BUS_NAME)
	if bus_index < 0:
		push_warning("唇跟随：找不到音频总线 \"%s\"" % BUS_NAME)
		return

	var instance := AudioServer.get_bus_effect_instance(bus_index, BUS_EFFECT_INDEX)
	if not (instance is AudioEffectSpectrumAnalyzerInstance):
		# 总线在，但那个位置不是频谱分析器 —— 这是配置漏了，不是模型的锅
		push_warning("唇跟随：\"%s\" 总线的第 %d 个效果不是 SpectrumAnalyzer"
			% [BUS_NAME, BUS_EFFECT_INDEX])
		return

	_spectrum = instance
	_operable = true

## 模型卸载。清掉所有引用 —— 参数对象属于旧模型，留着会悬空。
##
## 模型参数用不上：要清的四样都是本类自己的字段，和传进来那个模型无关。
## 前缀下划线是 GDScript 表示"有意不用"的写法 ——
## 信号的签名要求这个位置必须有个参数，不能删
func _on_cubism_term(_model: GDCubismUserModel) -> void:
	_operable = false
	_params.clear()
	_spectrum = null
	_level = 0.0

###########################################################
#  驱动
###########################################################

## 每帧驱动。时机与松手语义见文件头。
##
## 模型参数同样用不上：要驱动的参数对象在 cubism_init 时就抓好存进
## _params 了，每帧不必再问模型一次
func _on_cubism_process(_model: GDCubismUserModel, delta: float) -> void:
	if not _operable:
		return

	var driving := _should_drive()
	var target := 0.0
	if driving:
		target = _read_target()

	# 不对称逼近：张开快、闭合慢。
	# 手写而不是用 move_toward —— 后者的文档在这份离线文档里查不到
	# （float 的实例方法页是空的），按"API 必须可查"的规矩不用它
	var step := (ATTACK_RATE if target > _level else RELEASE_RATE) * delta
	if target > _level:
		_level = minf(_level + step, target)
	else:
		_level = maxf(_level - step, target)

	# 松手：语音已经播完，且嘴已经闭到位。
	# 从这里 return 就是"不再写"，参数下一帧被 LoadParameters() 收回去，
	# 控制权回到 motion 与 expression
	if not driving and _level <= 0.0:
		return

	for param in _params:
		param.value = _level

## 这一帧该不该由本立绘驱动口型。
##
## 两个条件都满足才行：语音在播，且那条语音是我的。
## 拿能量当条件是不行的 —— 语音里的戏剧性停顿会让控制权来回切换
func _should_drive() -> bool:
	if player == null:
		# 没接框架时退回通用行为：一直跟随音频，沉默时闭嘴。
		# 代价是参数被长期占用，但独立使用本类时那正是想要的
		return true
	if not player.is_voice_playing():
		return false
	if role_id.is_empty():
		return true
	return player.voice_owner() == role_id

## 读一次频谱，映射成 0..1 的口型目标值。
##
## 公式来自 gd_cubism 官方的 demo_effect_custom_03，只去掉了它最后那步
## 二值化（demo 是"超过阈值就满开"，这里要连续值）：
##     linear_to_db 把能量转成 dB，加 MIN_DB 再除以 MIN_DB，
##     得到的就是"离 -60dB 有多远"，天然落在 0..1
func _read_target() -> float:
	if _spectrum == null:
		return 0.0

	# MAGNITUDE_MAX 取频段峰值。文档里默认值就是它（= 1），
	# 但默认值不像参数名那样能自解释，显式写出来
	var magnitude: Vector2 = _spectrum.get_magnitude_for_frequency_range(
		FREQ_LOW, FREQ_HIGH, AudioEffectSpectrumAnalyzerInstance.MAGNITUDE_MAX)

	# 取左右声道中较大的那个，不取 .length()：语音通常是左右相同的内容，
	# 求模长等于给了一个恒定的 +3dB 虚假增益
	var peak := maxf(magnitude.x, magnitude.y)
	if peak <= 0.0:
		return 0.0

	var level := clampf((MIN_DB + linear_to_db(peak) + input_gain_db) / MIN_DB, 0.0, 1.0)

	# 死区重映射：把 [DEAD_ZONE, 1] 重新铺满 [0, 1]，低于死区的直接归零
	level = clampf((level - DEAD_ZONE) / (1.0 - DEAD_ZONE), 0.0, 1.0)
	return clampf(level * sensitivity, 0.0, 1.0)

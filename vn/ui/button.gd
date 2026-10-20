class_name VNButton
extends BaseButton

# ═══════════════════════════════════════════════════════════
#  通用按钮。对标 Ren'Py 的 button。
#
#  ── 和 Godot 原生按钮的不同，只剩一处 ──
#
#  状态图由调用方**显式指定**，一档一个路径，不做文件名推断。
#  对应 Ren'Py 的 idle_background / hover_background / ... 那一组槽位。
#  某一档留空就是不画那一档 —— 目录行常态没有底图，靠的就是这条。
#
#  （另有一个属性叫 insensitive 而不是 disabled：disabled 是 BaseButton
#  的原生成员，GDScript 不允许重定义同名成员。两者语义相同，内部同步。）
#
#  ── 输入：一律交给引擎，本类不碰 _input ──
#
#  action_mode 保持 ACTION_MODE_BUTTON_RELEASE，"抬起才执行"就是它：
#  按住不算，松手那一刻才判，且按下与松开都要落在本按钮内。
#
#  曾经用 _input 全局监听实现过 Ren'Py 的"只看松开在哪、不看按下在哪"。
#  那套语义更保真，代价却是绕开整个 GUI 分发体系 —— 层级遮挡、
#  mouse_filter、set_input_as_handled()，以及上层界面靠 suspend() 关输入
#  那一套，全部对它失效。表现就是"叠加界面开着，底下的按钮照样能点到"，
#  每遇到一个新的遮挡场景都得回来补一次丁。而它换来的只是两个误触格子
#  （A 按 B 松、空白按 A 松）的表现差异，不划算，所以改回原生。
#
#  改回之后，focus_mask 的接入点也回到它本该在的地方：_has_point()。
#  GUI 命中测试由引擎自己发起，本类不需要轮询鼠标位置。
#
#  ── 它不管什么 ──
#
#  不内建排版。图标贴哪、文字几行、装饰线叠哪一层，都由子节点决定 ——
#  本类只负责在状态变化时把新状态广播下去（visual_state_changed）。
# ═══════════════════════════════════════════════════════════

###########################################################
#  信号
###########################################################

## 点击。由原生 pressed 信号驱动，判定条件就是 BaseButton 那套
## "按下与松开都落在本按钮内"，见文件头的说明。
##
## 为什么不直接把原生 pressed 交给调用方：
## 它是引擎对本类自己的通知，本类已经拿它当输入源接进来了。
## 调用方要是也接上，同一次点击就会收到两条通知、执行两遍
## （表现为开关翻两次又回到原状）。
##
## 所以约定是：pressed 归本类内部使用，对外只有这一个信号
signal vn_pressed

## 视觉状态变化。状态名见 STATE_* 常量。
##
## 调用方接它来刷新那些本类管不着的部件 —— 装饰线、独立的图标层、
## 额外叠的装饰等等。本类只负责算状态和广播，怎么画由外面决定。
##
## 只在状态**真的变了**时发一次：悬停和焦点的抖动会让 _apply_visuals()
## 被频繁调用，每次都通知一遍外面纯属浪费
signal visual_state_changed(state: String)

###########################################################
#  状态名
###########################################################

## "不出声"的哨兵值。用字符串而不是 null，是因为要区分三种状态：
##   ""          没设置 —— 走作品层的默认音效
##   "none"      故意不发声 —— 覆盖作品层的默认
##   一个路径    用这个音效
## Godot 的 null 只能表达其中一种，另外两种必须是不同的值
const SOUND_NONE := "none"

const STATE_IDLE := "idle"
## 悬停
const STATE_HOVER := "hover"
## 按下
const STATE_PRESSED := "pressed"
## 禁用
const STATE_DISABLED := "disabled"
## 选中（未悬停）
const STATE_SELECTED := "selected"
## 选中且悬停
const STATE_SELECTED_HOVER := "selected_hover"
## 选中且禁用。对应 Ren'Py 的 selected_insensitive
const STATE_SELECTED_DISABLED := "selected_disabled"
## 选中且按下。对应 Ren'Py 的 selected_activate
const STATE_SELECTED_PRESSED := "selected_pressed"

## 禁用态。对应 Ren'Py 的 sensitive 取反。
##
## 为什么不叫 disabled：那是 BaseButton 的原生属性，GDScript 不允许
## 重定义原生类的成员，声明成同名会直接编译不过。
##
## 内部仍然同步到 BaseButton.disabled —— 它管着原生那套输入拦截，
## 而本类只借它表达"不可点"，外观和点击判定都走自己这条路
@export var insensitive := false:
	set(value):
		if insensitive == value:
			return
		insensitive = value
		# 同步给原生属性，让 BaseButton 自己那套也停下来
		disabled = value
		if is_inside_tree():
			_apply_visuals()

## 禁用时底图的整体透明度。
##
## 对应 Ren'Py 的 insensitive_background —— 那边一般写成
## Transform("xx_idle", alpha=0.5)，也就是"同一张图，调淡一半"。
## 这里不另做一份图，改在 _draw() 里乘上去，少一份资源也少一处要维护的路径。
##
## 默认 1.0 即不调淡，保持"没配禁用图就沿用常态图"的老行为 ——
## 本类不知道调用方想不想要那个淡化效果
@export_range(0.0, 1.0, 0.05) var insensitive_alpha := 1.0:
	set(value):
		insensitive_alpha = value
		if is_inside_tree():
			queue_redraw()

## 状态到回退顺序的表。当前状态没配图时，按这个顺序往后找。
##
## 这张表逐条照搬 Ren'Py 的 ImageButton —— 那边的兜底写在构造函数里
## （behavior.py 的 ImageButton.__init__），七行赋值，展开就是：
##
##     hover                → idle
##     insensitive          → idle
##     activate             → hover → idle
##     selected_idle        → idle
##     selected_hover       → hover → idle
##     selected_insensitive → insensitive → idle
##     selected_activate    → activate → hover → idle
##
## 关键在"退到哪一档"上，别想当然：
##   · selected_idle 退到 idle，不是退到 hover
##   · selected_hover 退到 hover，不是退到 selected_idle
##   · 每条链都到 idle 为止，再没有更上一层的"无前缀"档可退
##
## 本类比 Ren'Py 多出来的只有 pressed 这一维（那边叫 activate），
## 链的位置和它保持一致
const STATE_FALLBACK := {
	STATE_IDLE: [STATE_IDLE],
	STATE_HOVER: [STATE_HOVER, STATE_IDLE],
	STATE_PRESSED: [STATE_PRESSED, STATE_HOVER, STATE_IDLE],
	STATE_SELECTED: [STATE_SELECTED, STATE_IDLE],
	STATE_SELECTED_HOVER: [STATE_SELECTED_HOVER, STATE_HOVER, STATE_IDLE],
	STATE_DISABLED: [STATE_DISABLED, STATE_IDLE],
	STATE_SELECTED_DISABLED: [
		STATE_SELECTED_DISABLED, STATE_DISABLED, STATE_IDLE],
	STATE_SELECTED_PRESSED: [
		STATE_SELECTED_PRESSED, STATE_PRESSED, STATE_HOVER, STATE_IDLE],
}

###########################################################
#  状态图
###########################################################

## ── 关于 *_background 这一组 ──
##
## 配上去的图会被**拉伸铺满整个按钮**（draw_texture_rect 的语义），
## 所以它们必须是和按钮同尺寸的"底图"，不能拿图标来配 ——
## 43x46 的图标配进 150x46 的按钮会被横向拉变形。
##
## 图标、装饰线这类不铺满的层，用子节点 + visual_state_changed 自己做。

## 常态底图。留空表示常态不画
@export_file("*.png") var idle_background := ""

## 悬停底图
@export_file("*.png") var hover_background := ""

## 按下底图
@export_file("*.png") var pressed_background := ""

## 禁用底图
@export_file("*.png") var insensitive_background := ""

## 选中（未悬停）底图
@export_file("*.png") var selected_idle_background := ""

## 选中且悬停底图
@export_file("*.png") var selected_hover_background := ""

## 选中且禁用底图
@export_file("*.png") var selected_insensitive_background := ""

## 选中且按下底图。
##
## 和 pressed_background 的关系照搬 Ren'Py 的 selected_activate → activate：
## 这一档没配时，选中态的按下会沿回退链落到 pressed_background 上，
## 不必两份都填
@export_file("*.png") var selected_pressed_background := ""

###########################################################
#  文字
###########################################################

## 按钮文字。留空则不生成文字节点
@export var text := "":
	set(value):
		text = value
		if is_inside_tree():
			_sync_text()
			_apply_visuals()

## 文字字体
@export var text_font: Font = null:
	set(value):
		text_font = value
		if is_inside_tree():
			_sync_text()

## 文字字号
@export var text_size := 36:
	set(value):
		text_size = value
		if is_inside_tree():
			_sync_text()

## 文字常态颜色
@export var text_idle_color := Color.WHITE:
	set(value):
		text_idle_color = value
		if is_inside_tree():
			_apply_visuals()

## 文字悬停颜色
@export var text_hover_color := Color.WHITE:
	set(value):
		text_hover_color = value
		if is_inside_tree():
			_apply_visuals()

## 文字选中（未悬停）颜色
##
## 选中且悬停时用的是 text_hover_color，不是这一档 —— 分档方式照搬
## Ren'Py：那边"选中"与"悬停"是两个正交维度，组合出的四个槽位靠样式
## 回退链兜底。所以这里等价于给每个状态配上它"降级之后"的归宿：
##   selected        → text_selected_idle_color
##   selected_hover  → text_hover_color
@export var text_selected_idle_color := Color.WHITE:
	set(value):
		text_selected_idle_color = value
		if is_inside_tree():
			_apply_visuals()

## 文字禁用颜色
@export var text_insensitive_color := Color.WHITE:
	set(value):
		text_insensitive_color = value
		if is_inside_tree():
			_apply_visuals()

## 文字水平对齐。
##
## 右对齐时铺满整个按钮宽度，文字贴右边缘；
## 其余对齐方式从 text_offset 起排，右边界到按钮末尾
@export var text_align := HORIZONTAL_ALIGNMENT_CENTER:
	set(value):
		text_align = value
		if is_inside_tree():
			_sync_text()

## 文字框在按钮内的起点。text_align 为右对齐时忽略
@export var text_offset := Vector2.ZERO:
	set(value):
		text_offset = value
		if is_inside_tree():
			_sync_text()

###########################################################
#  选中与音效
###########################################################

## 选中态。对应 Ren'Py 的 selected_* 那一组槽。
##
## 它不影响会不会触发点击，只影响外观 —— 单选那种互斥关系
## 由调用方接 vn_pressed 之后自己设，本类不发明第二套
@export var selected := false:
	set(value):
		if selected == value:
			return
		selected = value
		if is_inside_tree():
			_apply_visuals()

## 悬停音效。为空则不播
##
## 值有三个含义：空串 = 用作品层的默认音效；"none" = 故意不发声；
## 否则是 res:// 路径。类型从 AudioStream 改成 String 就是为了分开这三种，
## 详见 SOUND_NONE 的说明
@export var hover_sound := ""

## 点击音效。为空则不播
##
## 值有三个含义：空串 = 用作品层的默认音效；"none" = 故意不发声；
## 否则是 res:// 路径。类型从 AudioStream 改成 String 就是为了分开这三种，
## 详见 SOUND_NONE 的说明
@export var activate_sound := ""

###########################################################
#  命中
###########################################################

## 是否按 alpha 通道判定可点区，对应 Ren'Py 的 focus_mask。
##
## 开着的时候，鼠标必须落在 focus_mask_state 那张图的不透明像素上
## 才算命中，用来做异形按钮 —— 比如只有露出部分才该响应鼠标的装饰框。
##
## 默认关：绝大多数按钮就是一块矩形，按矩形判定既准确又便宜。
## 关着时不会去读任何图的像素，零开销
@export var focus_mask := false:
	set(value):
		focus_mask = value
		_mask_built = false
		_mask = null

## 掩码判定用哪一档的状态图。默认取常态那张
@export var focus_mask_state := STATE_IDLE:
	set(value):
		focus_mask_state = value
		_mask_built = false
		_mask = null

###########################################################
#  运行时
###########################################################

## 纹理缓存：路径 → Texture2D。省掉每次的重复 load
var _texture_cache: Dictionary = {}

## 路径 → 这个文件在不在。见 _path_usable()
var _path_ok: Dictionary = {}

## 受本按钮管理的文字节点。自动生成的与外部搭好的都在这里
var _labels: Array[Label] = []

## 自动装配出来的文字节点
var _own_label: Label = null

## 按钮音效的解析结果。键是 "activate" / "hover"，值是 AudioStream
## 或 null（表示不播）。路径不会在运行期变，算一次就够
var _sound_cache: Dictionary = {}

## 命中掩码。为 null 表示不做 alpha 判定，退回整块矩形
var _mask: VNAlphaMask = null

## 掩码是否已经建过。建失败也会置 true，
## 免得每次点击都重试一遍注定失败的加载
var _mask_built := false

## 上一次真正应用过的状态名。用来判断状态有没有变，
## 避免同一状态反复发 visual_state_changed
var _applied_state := ""

## 现在是不是按住不放。
##
## 由 button_down / button_up 驱动，不看 BaseButton 那套 —— 那套管的是
## "这次点击算不算数"，和"现在该画哪一档"是两件事：按住之后把鼠标拖出
## 按钮，点击已经注定不生效了，但视觉上该立刻恢复常态
var _held := false

###########################################################

func _ready() -> void:
	# 外部搭好的 Label 要纳管 —— 本类只管广播状态，
	# 排版由调用方决定，那就得知道有哪些节点在听
	adopt_children()

	# 自己按 text 生成的那个 Label
	if not text.is_empty():
		_sync_text()

	# 显式写出来，不依赖 BaseButton 的默认值 —— 这行就是"抬起才执行"
	# 的定义，本类整个输入契约都压在它上面。要改成按下触发的话，
	# 文件头那份说明会一起失效，所以别在检查器里改它
	action_mode = BaseButton.ACTION_MODE_BUTTON_RELEASE

	# 触发时机与落点判定全部交回引擎 —— 见文件头的说明。
	#
	# 接 pressed 而不是 button_down：前者要等到松开、且按下与松开都落在
	# 本按钮内才发，后者按下就发。本类不再自己监听 _input 之后，
	# 这一行就是"按下不算、松手那一下才判"唯一的落点
	pressed.connect(_fire)
	
	# 按下态的两个信号。它们和 pressed 是两回事：pressed 管"这次点击
	# 成不成立"（要等到松开才发），这两个只管"手指现在有没有按着"，
	# 用来驱动 STATE_PRESSED 那一档外观
	button_down.connect(_on_button_down)
	button_up.connect(_on_button_up)

	mouse_entered.connect(_on_mouse_entered)
	mouse_exited.connect(_on_mouse_exited)

	# 不接键盘与手柄焦点。
	#
	# 本项目全是鼠标操作，没有键盘导航；而焦点一旦拿到就不会自己松手，
	# 任何"焦点也当悬停"的判断都会被它拖住。
	# 真要给某个界面加键盘导航时，在那一处单独改成 FOCUS_ALL 即可
	focus_mode = Control.FOCUS_NONE

	_apply_visuals()

## 重写命中测试。Godot 问"这个坐标算不算落在本按钮上"时走这里。
##
## 这是掩码的唯一正确接入点 —— mouse_filter 的目标选择、悬停判定、
## BaseButton 内部那套"按下与松开都在按钮内"的状态机，全部经过它。
## 自己写一个并行的判定函数是没用的：C++ 那套收不到通知。
##
## 本类不再监听 _input，所以这里也是"鼠标能不能点到本按钮"的唯一入口：
## 返回 false 时事件会直接穿透到下层去 —— 台词界面的推进判定就靠这条
## 才能收到落在按钮透明区上的点击
func _has_point(point: Vector2) -> bool:
	if not Rect2(Vector2.ZERO, size).has_point(point):
		return false

	if not focus_mask:
		return true

	if not _mask_built:
		_build_mask()
	if _mask == null:
		return true

	return _mask.contains(point)

## 绘制底图。当前状态没配图就什么都不画
##
## 禁用态会额外乘一个透明度（insensitive_alpha）。Ren'Py 那边是用
## Transform("idle", alpha=0.5) 造一张专用的 insensitive_background，
## 这里不另做图，改在绘制时把同一张图调淡 —— 效果一样，少一份资源
func _draw() -> void:
	var tex := _load_state_texture(_current_state())
	if tex == null:
		return

	var tint := Color.WHITE
	if insensitive:
		tint.a = insensitive_alpha
	draw_texture_rect(tex, Rect2(Vector2.ZERO, size), false, tint)

###########################################################
#  触发
###########################################################

## 执行一次点击。由原生 pressed 信号驱动。
##
## 不需要自己判"现在能不能被点"：BaseButton 在 disabled 时压根不发
## pressed，不可见时也收不到 GUI 事件，两条都由引擎兜住了。
##
## 只发 vn_pressed，不转发原生 pressed —— 后者是引擎发给本类的那个，
## 调用方一旦也接上，同一次点击就会执行两遍。详见 vn_pressed 的说明
func _fire() -> void:
	_play_sound("activate")
	vn_pressed.emit()

## 播一个按钮音效。which 取 "activate" 或 "hover"。
##
## 传的是字段名而不是流本身：判断该不该响需要同时看按钮自己的设置
## 和作品层的默认值，那是 _cached_sound() 的事
func _play_sound(which: String) -> void:
	var path := _cached_sound_path(which)
	if path.is_empty():
		return

	# 交给 VN 播，不用本节点自己的播放器。
	# 理由见 VNAudio._ui_sound 的说明：关闭类按钮点完就把自己连同
	# 子树一起销毁，挂在这儿的播放器撑不到音效播完
	VN.play_ui_sound(path)

## 取某个按钮音效该用的路径，返回空串表示不播，算一次后缓存。
##
## 优先级：按钮自己设的 > 作品层的默认 > 不播。
## 按钮设成 SOUND_NONE 时直接不播，**不再往下问默认值** ——
## 那正是"故意不发声"的意思，问下去就把它盖掉了
func _cached_sound_path(which: String) -> String:
	if _sound_cache.has(which):
		return _sound_cache[which]

	var own := activate_sound if which == "activate" else hover_sound
	var path := ""

	if own != SOUND_NONE:
		var settings := VNSettings.get_current()
		var fallback := settings.button_activate_sound if which == "activate" \
			else settings.button_hover_sound
		path = own if not own.is_empty() else fallback
		if path == SOUND_NONE:
			path = ""

	_sound_cache[which] = path
	return path

###########################################################
#  子节点装配
###########################################################

## 把外部搭好的直接子节点纳入管理。
##
## 只收 Label：底图由本类自己画，而调用方摆的 TextureRect
## （装饰线、独立图标层）各有各的状态逻辑，纳管只会互相打架
func adopt_children() -> void:
	for child in get_children():
		if child is Label and not _labels.has(child):
			_labels.append(child)

## 把一个 Label 纳入或移出管理。运行时动态增删部件的场合用它
func manage(child: Node, enable := true) -> void:
	if not (child is Label):
		return
	if enable:
		if not _labels.has(child):
			_labels.append(child)
	elif _labels.has(child):
		_labels.erase(child)
	_apply_visuals()

## 生成或更新自动装配的文字节点
func _sync_text() -> void:
	if text.is_empty():
		return

	if _own_label == null:
		_own_label = Label.new()
		_own_label.name = "VNButtonText"
		_own_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(_own_label)
		_labels.append(_own_label)

	_own_label.text = text
	if text_font != null:
		_own_label.add_theme_font_override("font", text_font)
	_own_label.add_theme_font_size_override("font_size", text_size)
	_own_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_own_label.horizontal_alignment = text_align

	# 右对齐时铺满整个按钮宽度，文字才贴得住右边缘；
	# 其余对齐方式从 text_offset 起排，右边界到按钮末尾
	if text_align == HORIZONTAL_ALIGNMENT_RIGHT:
		_own_label.position = Vector2.ZERO
		_own_label.size = size
	else:
		_own_label.position = text_offset
		_own_label.size = size - text_offset

###########################################################
#  状态
###########################################################

## 当前该显示哪一档状态。
##
## 优先级从高到低：禁用 → 按下 → 选中（且悬停 / 未悬停）→ 悬停 → 常态。
##
## 禁用排最前是有意的：一个不可点的按钮，无论鼠标在哪都该长得一样，
## 否则玩家会以为"它亮着说明能点"。
##
## 按下排在选中之前也是同理：按下是"此刻正在发生"的动作，反馈该压过
## 持久态。选中与否只决定走 selected_ 那一列还是普通那一列，两者正交
func _current_state() -> String:
	if insensitive:
		return STATE_SELECTED_DISABLED if selected else STATE_DISABLED

	if _held and _has_pressed_art():
		return STATE_SELECTED_PRESSED if selected else STATE_PRESSED

	if selected:
		return STATE_SELECTED_HOVER if _wants_hover() else STATE_SELECTED
	return STATE_HOVER if _wants_hover() else STATE_IDLE

## 按下这一档有没有配图。
##
## 没配就根本不进按下档（见 _current_state()），而不是让回退链换成
## hover 或 idle 那张 —— 状态图是"配了才生效"，没配就该原样不动。
## 换一张别的顶上去，玩家看到的是按住时按钮莫名其妙变了样
##
## 选中态要看两个槽：它自己那档没配时，回退链会落到 pressed 上
## （见 STATE_FALLBACK），所以两者都空才算真的没配
func _has_pressed_art() -> bool:
	if selected:
		return not selected_pressed_background.is_empty() \
			or not pressed_background.is_empty()
	return not pressed_background.is_empty()

## 现在算不算"悬停"。
##
## 只看鼠标，不看 has_focus() —— 键盘焦点是另一回事，而且 Godot 里
## 点击按钮本身就会给它焦点。两者混在一起会导致点过一次之后
## 悬停态永远为真：鼠标移开了，焦点还在，按钮就一直亮着
func _wants_hover() -> bool:
	return is_hovered()

## 把当前状态广播给底图和受管的文字节点。
##
## 状态真的变了才发 visual_state_changed
func _apply_visuals() -> void:
	var state := _current_state()
	var changed := state != _applied_state
	_applied_state = state

	queue_redraw()

	if changed:
		visual_state_changed.emit(state)

	var color := _text_color_for_state(state)
	for label in _labels:
		label.add_theme_color_override("font_color", color)

## 按当前状态取文字该用的颜色。
##
## 分档方式照搬 Ren'Py —— 那边"选中"与"悬停"是两个正交维度，组合出的
## 六个槽位靠样式回退链兜底。回退时**先剥"悬停"这一维，再剥"选中"**：
##
##   selected_hover  → selected_idle   选中项悬停时保持原色，不变
##   hover           → idle            未选中项悬停时才变色
##
## 顺序不是随手排的，两个方向正好相反：设置页的未选中悬停底图是白底，
## 文字退回 idle_color（深紫）才看得清；选中底图是淡紫底，文字若同样
## 退回深紫，压在那个底色上几乎看不见 —— 它必须停在 selected 的白
func _text_color_for_state(state: String) -> Color:
	match state:
		STATE_DISABLED, STATE_SELECTED_DISABLED:
			return text_insensitive_color
		STATE_SELECTED, STATE_SELECTED_HOVER, STATE_SELECTED_PRESSED:
			return text_selected_idle_color
	return text_hover_color if _wants_hover() else text_idle_color

## 把八档底图全部读进缓存。
##
## 底图平时是懒在 _draw() 里加载的 —— 画到哪一档才读哪一档，没显示过的
## 按钮永远不会读盘。这本是笔正当的节省，直到界面预热出现：预热容器
## 不可见，_draw() 不执行，不主动请一次的话，那批图仍然要等到第一次
## 真正显示时才加载，预热就只热了节点树那一半。
##
## 没配图的档由 _load_state_texture 返回 null，不必先检查有没有配
func preload_textures() -> void:
	for state: String in [
		STATE_IDLE, STATE_HOVER, STATE_PRESSED, STATE_DISABLED,
		STATE_SELECTED, STATE_SELECTED_HOVER,
		STATE_SELECTED_DISABLED, STATE_SELECTED_PRESSED]:
		_load_state_texture(state)

## 取某状态的底图。沿回退链找到第一张配了图的；全都没配就返回 null，
## 调用方按"这一层不画"处理
func _load_state_texture(state: String) -> Texture2D:
	var path := _resolve_state_path(state)
	if path.is_empty():
		return null

	if not _texture_cache.has(path):
		_texture_cache[path] = load(path)
	return _texture_cache[path] as Texture2D

## 沿回退链找第一个**真有图**的路径。全都没有则返回空串。
##
## 判据是"路径非空且文件在"，不只是"路径非空"：状态图由调用方显式指定，
## 谁也没法保证每一档都配了图。少配一档该落到下一档去，而不是让这一档
## 画出一片空白 —— "这档没配"和"这档配了个不存在的文件"看起来是同一个
## 结果，但前者会沿链退到有图的那档，后者不该把整条链堵死
func _resolve_state_path(state: String) -> String:
	var chain: Array = STATE_FALLBACK.get(state, [state])
	for candidate in chain:
		var path := _background_for(candidate)
		if not path.is_empty() and _path_usable(path):
			return path
	return ""

## 这个路径现在能不能拿来画。
##
## 结果缓存起来：回退链一次要挨档问好几遍，同一批路径会被反复问到。
## 缓存只增不减 —— 路径来自 @export，运行时不会变
func _path_usable(path: String) -> bool:
	if not _path_ok.has(path):
		_path_ok[path] = ResourceLoader.exists(path)
	return _path_ok[path]

## 某一档配的底图路径。没配则返回空串
func _background_for(state: String) -> String:
	match state:
		STATE_IDLE: return idle_background
		STATE_HOVER: return hover_background
		STATE_PRESSED: return pressed_background
		STATE_DISABLED: return insensitive_background
		STATE_SELECTED: return selected_idle_background
		STATE_SELECTED_HOVER: return selected_hover_background
		STATE_SELECTED_DISABLED: return selected_insensitive_background
		STATE_SELECTED_PRESSED: return selected_pressed_background
	return ""

###########################################################
#  掩码
###########################################################

## 按 focus_mask_state 指定的那张图建掩码。只建一次
func _build_mask() -> void:
	_mask_built = true

	var tex := _load_state_texture(focus_mask_state)
	if tex == null:
		# 图找不到就退回矩形判定。不报错 ——
		# 一个按钮不配状态图是合法用法，用矩形判它照样能用
		return

	_mask = VNAlphaMask.from_texture(tex)
	if _mask == null:
		push_warning("VNButton（%s）：%s 图读不出像素，命中区退回矩形"
			% [name, focus_mask_state])

###########################################################
#  悬停
###########################################################

## 鼠标进入
func _on_mouse_entered() -> void:
	# 禁用态的按钮不该有悬停反馈 —— 那会让它看起来还能点
	if not insensitive:
		_play_sound("hover")
	_apply_visuals()

## 鼠标离开。
##
## 一并把按下态放掉：Godot 在鼠标移出时就已经把这次点击判成不生效了
## （松开不会再发 pressed），视觉上该跟它一致 —— 不然按住拖出按钮，
## 按钮会一直亮着按下态，看着像"还按着、还作数"
func _on_mouse_exited() -> void:
	_held = false
	_apply_visuals()

## 手指按下了。
##
## 只管视觉，不代表这次点击一定成立 —— 成立与否由 pressed 说了算
func _on_button_down() -> void:
	_held = true
	_apply_visuals()

## 手指松开了。
##
## 不必判"松开落在哪"：移出按钮时 mouse_exited 已经放掉过一次，
## 这里收尾剩下那些情况 —— 也包括按住期间按钮被禁用，
## 那种场合引擎会补发 button_up
func _on_button_up() -> void:
	_held = false
	_apply_visuals()

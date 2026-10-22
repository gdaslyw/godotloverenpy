class_name VNI18n
extends RefCounted

# ═══════════════════════════════════════════════════════════
#  多语言的唯一入口：语言列表、locale 归一、字体组、字体缓存。
#
#  ── 翻译放在哪、怎么生效 ──
#  译文是 Godot 原生支持的 gettext PO 资源，放在 tl/<locale>/ui.po，
#  与 content/ 同级。它们不是"导入资源"，改完由引擎直接加载，不需要
#  重新导入。项目的 project.godot 里 internationalization/locale/translations
#  逐个登记，internationalization/locale/fallback 指向 zh_Hans。
#
#  ── 为什么 msgid 是简中原文 ──
#  tr("窗口大小") 里的"窗口大小"既是代码里的字面量，也是 PO 的 msgid。
#  查不到译文时 Godot 原样返回 msgid，也就是简中原文 —— "缺译文就回退简中"
#  这条规则因此不需要任何额外代码。
#
#  ── fallback 为什么必须是 zh_Hans ──
#  TranslationServer 的查找顺序是：当前 locale 的翻译表 → fallback locale
#  的翻译表 → msgid。默认 fallback 是 "en"，如果英文表是全量的，那么日文
#  表里缺一条就会被英文表接住，回退的是英文而不是简中。把 fallback 指向
#  zh_Hans（而我们**不提供** zh_Hans 表）之后，第二级必然落空，最终落到
#  msgid。这条设置写在 project.godot 里，不在代码里，改动时注意别被
#  编辑器面板的默认值盖回去。
#
#  ── 字体为什么按语言分组 ──
#  原项目在切语言时同时改 font / bole_font / dialog_font 三档字体
#  （screen/preferences.rpy:240-281）。不是审美偏好：简中字体不含假名，
#  日文界面会缺字；简体字库也不含繁中专用字形。所以字体必须跟着语言走，
#  具体路径由作品配置表的 language_fonts 决定。
# ═══════════════════════════════════════════════════════════

## 四种语言的 locale 标识。
##
## 用 BCP 47 的 script 形式（zh_Hans / zh_Hant）而不是 zh_CN / zh_TW：
## 简繁的区别是文字系统，不是地区 —— 新加坡也用简体。
const ZH_HANS := "zh_Hans"
const ZH_HANT := "zh_Hant"
const JA := "ja"
const EN := "en"

## 字体组的四个槽位名。作品配置表的 language_fonts 按这四个键组织
const FONT_UI := "ui"
const FONT_BOLD := "bold"
const FONT_ARTISTIC := "artistic"
const FONT_DIALOG := "dialog"

## 模拟粗体的强度。0 是原样，1.2 已经很重（Godot 文档里的示例值）。
## 0.6 大约相当于一档自带的粗体，再往上笔画就开始糊
const SIMULATED_BOLD := 0.6

## 模拟斜体的水平剪切量。0.2 约 11°，正数向右倾
const SIMULATED_SLANT := 0.2

## locale 别名表。键是归一化后的小写形式（连字符已换成下划线），
## 值是四种语言之一。
##
## 这张表存在的理由：settings.cfg 是留给人手改的，玩家或开发者可能写成
## "zh-CN"、"ja_JP"、"en-US"；而系统语言（如果将来接到选项里）也是这种
## 形式。归一化在这里做一次，别处不必各写一套判断
const _ALIASES := {
	"zh": ZH_HANS,
	"zh_hans": ZH_HANS,
	"zh_cn": ZH_HANS,
	"zh_sg": ZH_HANS,
	"zh_hant": ZH_HANT,
	"zh_tw": ZH_HANT,
	"zh_hk": ZH_HANT,
	"zh_mo": ZH_HANT,
	"ja": JA,
	"ja_jp": JA,
	"jp": JA,
	"en": EN,
	"en_us": EN,
	"en_gb": EN,
	"en_au": EN,
}

## 已加载的字体，键是 "locale:槽位"，值是 Font。
##
## 为什么要缓存：一个语言要两三档字体，繁中那两个字体文件各 20 MB 上下。
## 每建一个界面就 load() 一次，等于每次切页都重新读盘 + 解析字形表。
## 缓存的代价是切语言时要主动清（见 clear_font_cache）—— 否则旧语言的
## 字体会一直被这张表引用着，手机上就是几十 MB 用不掉的常驻内存
static var _fonts: Dictionary = {}

###########################################################
#  语言表
###########################################################

## 作品配置里的语言列表，顺序即设置界面上的按钮顺序。
##
## 返回的每项是 { "locale": String, "name": String }。name 是该语言
## **用它自己写**的名字（"简体中文" / "繁體中文" / "日本語" / "English"），
## 刻意不翻译 —— 玩家在选之前就该认出自己那一行，翻成当前语言反而难找
static func languages() -> Array:
	return VNSettings.get_current().languages

## 作品配置里的默认语言（首次运行、重置之后回到它）。
##
## 原项目用 Language(None) 表示简体中文，不跟随系统 —— 这里同样是"默认
## 简中"，而不是 OS.get_locale_language()。跟随系统会让同一份存档在不同
## 机器上显示成不同语言，对视觉小说不合适
static func default_language() -> String:
	return VNSettings.get_current().default_language

## 翻译文件所在目录（res:// 路径，结尾带斜杠）。
##
## 只用来给开发端的核对脚本查文件；运行期的加载由 project.godot 的
## translations 列表负责，那边是逐文件登记的
static func translation_dir() -> String:
	return VNSettings.get_current().translation_dir

## 源语言的 locale。它的"译文"就是 msgid 本身，不需要翻译表
static func source_language() -> String:
	return VNSettings.get_current().default_language

## 某个 locale 是不是源语言（简中）。
##
## 判断这个的用处：源语言下要按玩家选的 dialog_font 走，其它语言下要
## 强制用该语言的正文默认字体 —— 原项目切语言时就是直接覆盖 dialog_font
static func is_source(locale: String) -> bool:
	return normalize(locale) == source_language()

## 语言在设置界面上的显示名。查不到时返回 locale 本身 ——
## 显示 "xyz" 比显示空白更容易看出配错了
static func display_name(locale: String) -> String:
	var target := normalize(locale)
	for entry: Dictionary in languages():
		if String(entry.get("locale", "")) == target:
			return String(entry.get("name", target))
	return target

## 把任意写法的 locale 归一到四种语言之一。认不出来就落到默认语言。
##
## 认不出来时**不报错**：settings.cfg 里写了一个过期语言（比如曾经做过
## 法语、后来删了）是正常的历史遗留，回退到默认语言比让游戏起不来合理
static func normalize(locale: String) -> String:
	var key := locale.strip_edges().replace("-", "_").to_lower()

	if _ALIASES.has(key):
		return String(_ALIASES[key])

	# 前缀匹配：处理 "zh_hant_tw"、"ja_jp_utf8" 这类带后缀的写法。
	# 必须在别名表之后做，否则 "zh" 会把 "zh_hant" 抢先吃掉
	for entry: Dictionary in languages():
		var candidate := String(entry.get("locale", "")).to_lower()
		if not candidate.is_empty() and key.begins_with(candidate):
			return String(entry.get("locale", ""))

	return default_language()

## locale 在语言列表里的下标。查不到返回 -1
static func index_of(locale: String) -> int:
	var target := normalize(locale)
	var list: Array = languages()
	for i in list.size():
		if String((list[i] as Dictionary).get("locale", "")) == target:
			return i
	return -1

## 语言列表里第 index 个语言的 locale。越界返回默认语言
static func locale_at(index: int) -> String:
	var list: Array = languages()
	if index < 0 or index >= list.size():
		return default_language()
	return String((list[index] as Dictionary).get("locale", default_language()))

###########################################################
#  应用到引擎
###########################################################

## 把引擎当前 locale 切到给定语言，返回归一化后的 locale。
##
## TranslationServer.set_locale() 内部会做它自己的标准化（"en-US" →
## "en_US"），所以这里先归一成我们的四种语言再传进去，避免 "en_US" 和
## "en" 两套标识在同一个项目里并存。
##
## ── 切简中时要把繁中表摘掉 ──
## Godot 的 locale 匹配会把 zh_Hans 拆到语言层 `zh`，于是简中查询会命中
## zh_Hant 表 —— 表里有的条目在简中界面下会显示成繁体。实测：只登记
## en/ja/zh_Hant 三张表时，简中下 tr("窗口大小") 返回"視窗大小"。
##
## 摘掉之后，简中查询无处可去，一路回退到 msgid，也就是简中原文本身。
## 好处是**简中不需要维护任何翻译表**：新加一句台词、一条界面文案，
## 不写进任何 PO 文件也照样显示正确，不会被繁中表串味
static func apply(locale: String) -> String:
	var target := normalize(locale)
	_attach_hant(target != ZH_HANS)
	TranslationServer.set_locale(target)
	return target

## 繁中表的路径。运行时要用它把表加回来，所以不能只靠 project.godot
const ZH_HANT_PATH := "res://tl/zh_Hant/ui.po"

## 繁中表的缓存。add / remove 要求是同一个 Translation 实例
static var _hant: Translation = null

## 繁中表现在挂在 TranslationServer 上吗。
## 初值 true —— 启动时 project.godot 的 translations 列表已经把它加载了
static var _hant_attached := true

## 把繁中表挂上 / 摘下。已经是目标状态时直接返回
static func _attach_hant(on: bool) -> void:
	if on == _hant_attached:
		return

	if _hant == null:
		if not ResourceLoader.exists(ZH_HANT_PATH):
			return
		_hant = load(ZH_HANT_PATH) as Translation
	if _hant == null:
		return

	if on:
		TranslationServer.add_translation(_hant)
	else:
		TranslationServer.remove_translation(_hant)
	_hant_attached = on

## 引擎当前 locale。**不一定是四种语言之一** —— 启动早期还没调用
## apply() 时，它是系统 locale。要"项目认为现在是哪种语言"请用
## VNFrame.language()，那个值来自玩家配置
static func engine_locale() -> String:
	return TranslationServer.get_locale()

## 引擎已加载的 locale 列表（PackedStringArray）。
##
## 启动自检用它回答"PO 到底被 load 进来没有"。只在编辑器里能改
## project.godot 的 translations 列表，手改路径写错时这里会少一项
static func loaded_locales() -> PackedStringArray:
	return TranslationServer.get_loaded_locales()

## 某个 locale 的翻译表是否已经挂在引擎上。
##
## 注意两个"false 也正常"的情况：
##   · 源语言（简中）本来就没有表 —— 它的译文就是 msgid，见 is_source()
##   · 简中界面下繁中表会被主动摘掉，见 apply()
##
## 想判断"这个语言有没有准备译文"应该看文件在不在，别用这个函数 ——
## VNFrame 的启动自检就是这么做的
static func has_translation(locale: String) -> bool:
	return loaded_locales().has(normalize(locale))

###########################################################
#  图片
###########################################################

## content 根。图片本地化按"content 之后的路径原样镜像到 tl/<locale>/"来查，
## 与原项目 game/tl/<lang>/images/... 镜像 game/images/... 是同一个思路
const CONTENT_PREFIX := "res://content/"

## 某个资源的本地化版本路径。没有本地化版本时返回空串。
##
## 规则：
##   res://content/ui/images/x.png
##     → res://tl/<locale>/ui/images/x.png
##   res://content/images/cg/x.png
##     → res://tl/<locale>/images/cg/x.png
##
## 也就是说 content/ 这一段被换成 tl/<locale>/，后面的目录结构原样保留。
## 这样一来"某张图有没有外语版本"只看 tl 下有没有同名文件，
## 不必给每张图单独写一条配置
static func localized_path(path: String, locale := "") -> String:
	if not path.begins_with(CONTENT_PREFIX):
		return ""

	var target := normalize(locale if not locale.is_empty() else engine_locale())
	var rest := path.substr(CONTENT_PREFIX.length())
	var candidate := translation_dir().path_join(target).path_join(rest)
	return candidate if ResourceLoader.exists(candidate) else ""

## 取一张图的本地化版本；没有就回退原图。
##
## 返回 null 表示连原图都不存在，调用方按"缺图"处理。
##
## 用 load 而不是 preload：本地化路径是运行期算出来的，preload 只吃
## 编译期常量。代价是第一次切到某语言时会读一次盘 —— 这类图都是整屏
## 素材，本来就要在页面构建时读，多这一次不影响
static func localized_texture(path: String, locale := "") -> Texture2D:
	var candidate := localized_path(path, locale)
	var target := candidate if not candidate.is_empty() else path
	if not ResourceLoader.exists(target):
		return null
	return load(target) as Texture2D

###########################################################
#  字体
###########################################################

## 某个语言某个槽位的字体路径。locale 传空表示"当前引擎 locale"。
##
## 查不到时回退到默认语言的对应槽位 —— 作品配置漏配一种语言不该让界面
## 变成默认字体（默认字体只有 Latin-1，中文会整片空白）
static func font_path(kind: String, locale := "") -> String:
	var target := normalize(locale if not locale.is_empty() else engine_locale())
	var table: Dictionary = VNSettings.get_current().language_fonts

	var spec: Dictionary = table.get(target, {})
	if spec.is_empty():
		spec = table.get(default_language(), {})
	return String(spec.get(kind, ""))

## 取某个语言某个槽位的 Font 对象，带缓存。
##
## 路径为空或文件不存在时返回 null 并报错 —— 界面拿到 null 会退回引擎
## 默认字体，那在中文下就是满屏空白，报错至少能把问题指到配置表上
static func font(kind: String, locale := "") -> Font:
	var target := normalize(locale if not locale.is_empty() else engine_locale())
	var path := font_path(kind, target)
	if path.is_empty():
		push_error("VNI18n：语言 %s 的字体槽位 %s 没有配置" % [target, kind])
		return null

	var key := target + ":" + kind
	if _fonts.has(key):
		return _fonts[key] as Font

	if not ResourceLoader.exists(path):
		push_error("VNI18n：字体文件不存在：%s" % path)
		return null

	var loaded: Variant = load(path)
	if not (loaded is Font):
		push_error("VNI18n：不是字体文件：%s" % path)
		return null

	_fonts[key] = loaded
	return loaded as Font

## {font=文件名} 对应的字体路径；找不到返回空串。
##
## 名字**带后缀**（.ttf / .otf），直接拼到作品配置的 inline_font_dir 后面。
## 早先试过"不带后缀、依次试两种"，但那样编辑器侧（能列目录）与运行时
## （只能挨个拼）的判定不完全一致，所以统一成写全名。
##
## 用 ResourceLoader.exists() 而不是 FileAccess.file_exists()：导出之后
## 源文件不进包，只有 .godot/imported 下的 fontdata，而 ResourceLoader
## 认得导入资源。目录由作品配置的 inline_font_dir 给，换项目只改那一行
static func inline_font_path(name: String) -> String:
	if name.is_empty():
		return ""

	var dir := String(VNSettings.get_current().inline_font_dir)
	if dir.is_empty():
		return ""
	if not dir.ends_with("/"):
		dir += "/"

	var path := dir + name
	if ResourceLoader.exists(path):
		return path
	return ""

## 给一个 RichTextLabel 配齐四套字形：正文、粗体、斜体、粗斜体。
##
## ── 为什么四套必须一起配 ──
## RichTextLabel 的字形是分槽的：[b] 走 bold_font + bold_font_size，
## [i] 走 italics_font + italics_font_size，[b][i] 走 bold_italics_*。
## [u] [s] 只是绘制修饰、不换字体，所以只有粗斜体会出事。只 override
## normal_font 而不配另外三套时，它们会落到引擎的 default_font_size（16）
## 和引擎默认字体上 —— 正文 50 号，一加粗就变 16 号，中文字形还得靠
## fallback。
##
## ── 粗体为什么是模拟的 ──
## 玩家能挑圆/楷/宋/黑四种正文字体，设置表里只有 path、没有各自的粗体
## 配对。language_fonts 里虽然有真粗体，但只为"出厂字体"那几个开一条
## 分支的话，玩家一换字体粗体就换成另一副字形，前后不一致。统一用
## variation_embolden 模拟，任何字体都只是"同一套字加粗"。
##
## ── 斜体为什么是模拟的 ──
## 项目里没有任何 italic 字体文件，只能靠 variation_transform 剪切。
## 汉字伪斜体是常规做法，Ren'Py 对没有 italic 变体的中文字体同样走
## fake italic。
##
## base 传 null 时只统一字号、不动字体 —— 字体路径意外为空时，也不该
## 让三个字号槽继续停在默认值上
static func apply_rich_fonts(label: RichTextLabel, base: Font, size: int) -> void:
	# 每项是 [字体槽, 字号槽, 模拟粗体量, 模拟斜体量]
	var slots := [
		["normal_font", "normal_font_size", 0.0, 0.0],
		["bold_font", "bold_font_size", SIMULATED_BOLD, 0.0],
		["italics_font", "italics_font_size", 0.0, SIMULATED_SLANT],
		["bold_italics_font", "bold_italics_font_size",
			SIMULATED_BOLD, SIMULATED_SLANT],
	]
	for slot in slots:
		label.add_theme_font_size_override(String(slot[1]), size)
		if base == null:
			continue
		var embolden := float(slot[2])
		var slant := float(slot[3])
		if embolden == 0.0 and slant == 0.0:
			label.add_theme_font_override(String(slot[0]), base)
		else:
			label.add_theme_font_override(String(slot[0]),
				_simulated(base, embolden, slant))

## 从一个基础字体造出模拟加粗 / 倾斜的变体。
##
## Transform2D 的两列是 x 轴和 y 轴上单位向量变换后的方向，这里当剪切
## 矩阵用：y 轴带上横向分量之后，y 为负（字形顶部）的点被推向 +x、
## y 为正（底部）的点被推向 -x，合起来就是向右倾
static func _simulated(base: Font, embolden: float, slant: float) -> FontVariation:
	var fv := FontVariation.new()
	fv.base_font = base
	fv.variation_embolden = embolden
	if slant != 0.0:
		fv.variation_transform = Transform2D(
			Vector2(1.0, 0.0), Vector2(-slant, 1.0), Vector2.ZERO)
	return fv

## 丢弃所有已缓存的字体。
##
## 切语言时调一次：不清的话旧语言的字体仍被这张静态表引用着，永远不释放。
## 真正的回收发生在调用之后 —— 界面重建完、旧节点释放、引用归零，
## ResourceLoader 那边才会把字体从内存里放掉
static func clear_font_cache() -> void:
	_fonts.clear()

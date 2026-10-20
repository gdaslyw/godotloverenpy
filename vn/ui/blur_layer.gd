class_name VNBlurLayer extends ColorRect

# ═══════════════════════════════════════════════════════════
#  模糊层。往场景树里插一层，糊掉它下方已经画完的一切。
#
#  它只是 shader 的载体：真正干活的 gaussian_blur.gdshader 采的是屏幕
#  纹理，这一层负责三件事 —— 铺满父节点、别挡输入、把强度转成 uniform。
#  之所以继承 ColorRect，是因为挂 shader 需要一个会绘制的节点，
#  而 ColorRect 是其中最轻的一个（不必带贴图）。
#
#  放 vn/ 是因为它跟具体作品无关：主菜单要糊背景视频、剧情里要糊舞台
#  背景、菜单弹出时要糊整个舞台，用的都是同一个东西，差别只在插进
#  场景树的哪个位置。
# ═══════════════════════════════════════════════════════════

## 模糊 shader。同目录，随本脚本一起进框架
const BLUR_SHADER := preload("res://vn/shader/gaussian_blur.gdshader")

## 模糊半径，单位像素。语义与 Ren'Py 的 blur 变换属性一致：
## blur 4 就是糊 4 像素。0 表示不糊，整层会自动隐藏
@export var blur: float = 4.0:
	set(value):
		# 负半径没有意义。Ren'Py 那边也是直接夹住的
		blur = maxf(value, 0.0)
		_push()

## 本层建的材质。留引用是为了改 uniform 时不必反复 cast
var _material: ShaderMaterial = null

###########################################################

## 铺满父节点、放行输入、建好材质。
##
## 铺满与鼠标穿透这两条刻意写在代码里，而不是留给你在检查器里调：
## 它们错了都是功能性故障（糊错范围 / 底下按钮点不动），不是审美问题，
## 不该有被改错的余地
func _ready() -> void:
	# 全透明底色。shader 正常时它会被整个覆盖，看不出区别；
	# 万一 shader 编译失败，Godot 退回默认材质，这一层就是透明的，
	# 而不是一块白板糊死整个屏幕
	color = Color(0.0, 0.0, 0.0, 0.0)

	# 输入一律放行。这一层盖住整个画面，要是吃掉鼠标事件，
	# 底下那些按钮就全点不动了
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	_ensure_material()
	_push()

###########################################################

## 在 parent 里插一层模糊，位置紧随 after 之后。
##
## 用"after 的下标 + 1"而不是写死数字：以后在编辑器里调整背景和
## 前景的先后顺序，调用方这一行不会跟着错位。
##
## 返回建好的节点，方便调用方留着以后改强度 —— 将来做模糊淡入
## 就是 Tween 这个节点的 blur
static func attach(parent: Node, after: Node, blur_radius: float) -> VNBlurLayer:
	if parent == null or after == null:
		push_error("VNBlurLayer：parent 或 after 为空，模糊层没有插入")
		return null

	var layer := VNBlurLayer.new()
	layer.blur = blur_radius
	parent.add_child(layer)
	parent.move_child(layer, after.get_index() + 1)
	return layer

###########################################################
#  内部
###########################################################

## 保证 _material 指向一个用本 shader 的材质。
##
## 判定方式是"材质的 shader 就是本 shader"，而不是"材质不为空" ——
## 和 VNUIEffects 的做法一致：节点上可能已经挂了别的效果，
## 那种情况下宁可不动它，也不要覆盖掉
func _ensure_material() -> void:
	var existing := material as ShaderMaterial
	if existing != null and existing.shader == BLUR_SHADER:
		_material = existing
		return

	if material != null:
		push_warning("VNBlurLayer：%s 上已有别的材质，模糊不会生效" % name)
		return

	_material = ShaderMaterial.new()
	_material.shader = BLUR_SHADER
	material = _material

## 把 blur 推给 shader，并决定这一层要不要显示。
##
## 半径为 0 时整层撤掉：屏幕拷贝不是免费的，而这一层此时什么都看不见。
## 顺带这也是将来做淡入的前提 —— Tween 把 blur 从 0 抬起来的那一刻
## 它会自己出现，调用方不必另外管显隐
func _push() -> void:
	if _material != null:
		_material.set_shader_parameter("u_blur", blur)
	visible = blur > 0.0

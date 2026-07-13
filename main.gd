extends Control
# ═══════════════════════════════════════════════════════════════════════════════
# TurnTV メインスクリプト
# デスクトップの矩形領域をキャプチャし、NTSC/CRTシェーダー（Gemidiusから移植）を
# 通して表示するツールです。仕様書: SPEC_TurnTV.md
#
# パイプライン:
#   画面キャプチャImage → NTSCキャンバスSubViewport(320x240) →
#   Stage1 SubViewport(crt_signal.gdshader) → Stage2 ColorRect(crt_display.gdshader)
# ═══════════════════════════════════════════════════════════════════════════════

enum Mode { SELECT, TV }

const SETTINGS_PATH: String = "user://turntv_settings.json"  # 設定保存先です。
const RECT_WINDOW_RATIO: float = 0.9      # 選択矩形がウィンドウに占める割合です。
const EDGE_MARGIN: float = 10.0           # ウィンドウリサイズ判定の外周幅[px]です。
const MIN_SELECT_SIZE: int = 8            # 選択矩形の最小サイズ[px]です。
const ZOOM_MIN: float = 0.1               # ホイールズームの下限です。
const ZOOM_MAX: float = 8.0               # ホイールズームの上限です。
const ZOOM_STEP: float = 1.1              # ホイール1ノッチのズーム倍率です。
const CLICK_MOVE_THRESHOLD: float = 6.0   # クリックとドラッグを区別する移動量[px]です。
const MIN_WINDOW_SIZE: Vector2i = Vector2i(240, 180)  # TVウィンドウの最小サイズです。
const SELECT_CAPTURE_WAIT: float = 0.35   # 最小化からスクリーンショットまでの待ち時間[秒]です。
const TOP_BAR_HEIGHT: float = 28.0        # TVモード上部の移動用グラブバーの高さ[px]です。

const TARGET_SIGNAL: int = 0   # パラメータ適用先: Stage1（NTSC信号）です。
const TARGET_DISPLAY: int = 1  # パラメータ適用先: Stage2（CRT表示）です。
const TARGET_APP: int = 2      # パラメータ適用先: アプリ設定です。

# パラメータ定義表。既定値はGemidiusのコンポジットTVプリセット（Crt_composite_*/Crt_shared_*）です。
const PARAM_DEFS: Array = [
    {"section": "Stage1: NTSC信号"},
    {"name": "signal_amount", "label": "信号劣化 全体量", "min": 0.0, "max": 1.0, "step": 0.001, "def": 1.0, "target": TARGET_SIGNAL},
    {"name": "composite_artifact", "label": "クロスカラー(偽色)", "min": 0.0, "max": 2.0, "step": 0.001, "def": 0.85, "target": TARGET_SIGNAL},
    {"name": "composite_fringing", "label": "クロスルミナンス(にじみ)", "min": 0.0, "max": 2.0, "step": 0.001, "def": 0.65, "target": TARGET_SIGNAL},
    {"name": "subcarrier_phase_px", "label": "サブキャリア位相/px", "min": 0.1, "max": 3.14, "step": 0.001, "def": 1.047, "target": TARGET_SIGNAL},
    {"name": "line_phase_amount", "label": "ライン位相差", "min": 0.0, "max": 6.283, "step": 0.001, "def": 2.094, "target": TARGET_SIGNAL},
    {"name": "phase_jitter", "label": "位相ジッター", "min": 0.0, "max": 0.25, "step": 0.001, "def": 0.025, "target": TARGET_SIGNAL},
    {"name": "chroma_delay_px", "label": "色ずれ[px]", "min": -8.0, "max": 8.0, "step": 0.001, "def": 1.25, "target": TARGET_SIGNAL},
    {"name": "y_band_px", "label": "Y帯域(輝度ぼけ)", "min": 0.5, "max": 5.0, "step": 0.001, "def": 1.25, "target": TARGET_SIGNAL},
    {"name": "i_band_px", "label": "I帯域(色ぼけ1)", "min": 1.0, "max": 9.0, "step": 0.001, "def": 2.75, "target": TARGET_SIGNAL},
    {"name": "q_band_px", "label": "Q帯域(色ぼけ2)", "min": 1.0, "max": 12.0, "step": 0.001, "def": 4.25, "target": TARGET_SIGNAL},
    {"name": "ghost_strength", "label": "ゴースト強度", "min": 0.0, "max": 0.5, "step": 0.001, "def": 0.08, "target": TARGET_SIGNAL},
    {"name": "ghost_offset_px", "label": "ゴースト距離[px]", "min": 0.0, "max": 32.0, "step": 0.001, "def": 6.0, "target": TARGET_SIGNAL},
    {"name": "noise_luma", "label": "輝度ノイズ", "min": 0.0, "max": 0.1, "step": 0.0005, "def": 0.012, "target": TARGET_SIGNAL},
    {"name": "noise_chroma", "label": "色ノイズ", "min": 0.0, "max": 0.1, "step": 0.0005, "def": 0.018, "target": TARGET_SIGNAL},
    {"name": "rgb_bypass_mix", "label": "RGBバイパス率", "min": 0.0, "max": 1.0, "step": 0.001, "def": 0.0, "target": TARGET_SIGNAL},
    {"section": "Stage2: CRT表示"},
    {"name": "display_amount", "label": "CRT表示 全体量", "min": 0.0, "max": 1.0, "step": 0.001, "def": 1.0, "target": TARGET_DISPLAY},
    {"name": "scanline_strength", "label": "走査線強度", "min": 0.0, "max": 1.0, "step": 0.001, "def": 0.42, "target": TARGET_DISPLAY},
    {"name": "scanline_width_dark", "label": "ビーム幅(暗部)", "min": 0.05, "max": 1.0, "step": 0.001, "def": 0.18, "target": TARGET_DISPLAY},
    {"name": "scanline_width_bright", "label": "ビーム幅(明部)", "min": 0.05, "max": 1.0, "step": 0.001, "def": 0.42, "target": TARGET_DISPLAY},
    {"name": "mask_type", "label": "マスク方式", "def": 1, "target": TARGET_DISPLAY, "type": "enum", "items": ["OFF", "スロットマスク", "アパーチャーグリル", "シャドウマスク"]},
    {"name": "mask_strength", "label": "マスク強度", "min": 0.0, "max": 1.0, "step": 0.001, "def": 0.45, "target": TARGET_DISPLAY},
    {"name": "mask_pitch_px", "label": "蛍光体ピッチ[px]", "min": 2.0, "max": 8.0, "step": 0.001, "def": 3.6, "target": TARGET_DISPLAY},
    {"name": "mask_dark", "label": "マスク暗部", "min": 0.0, "max": 1.0, "step": 0.001, "def": 0.45, "target": TARGET_DISPLAY},
    {"name": "mask_softness", "label": "マスクぼかし", "min": 0.0, "max": 2.0, "step": 0.001, "def": 0.35, "target": TARGET_DISPLAY},
    {"name": "brightness_compensation", "label": "明度補償", "min": 0.5, "max": 2.0, "step": 0.001, "def": 1.22, "target": TARGET_DISPLAY},
    {"name": "gamma_in", "label": "入力ガンマ", "min": 1.0, "max": 3.0, "step": 0.001, "def": 2.4, "target": TARGET_DISPLAY},
    {"name": "gamma_out", "label": "出力ガンマ", "min": 1.0, "max": 3.0, "step": 0.001, "def": 2.2, "target": TARGET_DISPLAY},
    {"name": "curve_amount", "label": "画面カーブ", "min": 0.0, "max": 0.2, "step": 0.001, "def": 0.040, "target": TARGET_DISPLAY},
    {"name": "corner_radius", "label": "角丸半径", "min": 0.0, "max": 0.15, "step": 0.001, "def": 0.045, "target": TARGET_DISPLAY},
    {"name": "vignette_strength", "label": "外周減光", "min": 0.0, "max": 1.0, "step": 0.001, "def": 0.18, "target": TARGET_DISPLAY},
    {"name": "bezel_strength", "label": "ベゼル暗部", "min": 0.0, "max": 1.0, "step": 0.001, "def": 0.35, "target": TARGET_DISPLAY},
    {"name": "interlace_enabled", "label": "480i風表示", "def": false, "target": TARGET_DISPLAY, "type": "bool"},
    {"name": "interlace_dim", "label": "480i減光", "min": 0.0, "max": 1.0, "step": 0.001, "def": 0.72, "target": TARGET_DISPLAY},
    {"name": "interlace_bob_px", "label": "480i上下揺れ[px]", "min": 0.0, "max": 1.0, "step": 0.001, "def": 0.5, "target": TARGET_DISPLAY},
    {"section": "アプリ設定"},
    {"name": "always_on_top", "label": "常に最前面", "def": true, "target": TARGET_APP, "type": "bool"},
    {"name": "capture_interval", "label": "キャプチャ間隔[フレーム]", "min": 1, "max": 30, "step": 1, "def": 3, "target": TARGET_APP, "type": "int"},
    {"name": "canvas_width", "label": "NTSCキャンバス幅", "min": 160, "max": 720, "step": 2, "def": 320, "target": TARGET_APP, "type": "int"},
    {"name": "canvas_height", "label": "NTSCキャンバス高さ", "min": 120, "max": 540, "step": 2, "def": 240, "target": TARGET_APP, "type": "int"},
]

# ── 状態 ──────────────────────────────────────────────────────────────────────
var mode: int = Mode.TV                     # 現在のモードです。
var select_ready: bool = false              # 選択モードの静止画取得が完了したかです。
var selecting: bool = false                 # 矩形ドラッグ中かです。
var select_start: Vector2 = Vector2.ZERO    # 選択ドラッグ開始位置（ウィンドウ座標）です。
var select_end: Vector2 = Vector2.ZERO      # 選択ドラッグ現在位置（ウィンドウ座標）です。
var capture_rect: Rect2i = Rect2i()         # 確定した選択矩形（デスクトップ絶対座標）です。
var capture_screen: int = 0                 # キャプチャ対象スクリーン番号です。
var zoom: float = 1.0                       # ホイールによる表示ズーム倍率です。
var frame_count: float = 0.0                # 60fps換算のフレームカウンタ（シェーダーへ渡す）です。
var capture_interval: int = 3               # ライブキャプチャの実行間隔[フレーム]です。
var capture_frame_accum: int = 0            # キャプチャ間隔の経過カウンタです。
var canvas_size: Vector2i = Vector2i(320, 240)  # NTSCキャンバス解像度です。
var param_values: Dictionary = {}           # パラメータ名→現在値です。
var tv_window_pos: Vector2i = Vector2i(120, 120)  # TVモードのウィンドウ位置（復元用）です。
var tv_window_size: Vector2i = Vector2i(640, 480) # TVモードのウィンドウサイズ（復元用）です。
var has_tv_window_state: bool = false       # TVウィンドウ位置の保存値があるかです。
var pressed_center: bool = false            # TVモードで中央部を左押下中かです。
var press_pos: Vector2 = Vector2.ZERO       # 左押下位置です。
var dragging_rect: bool = false             # 左ドラッグで選択矩形（映す場所）を移動中かです。
var window_dragging: bool = false           # 上部帯/中ボタンでウィンドウを移動中かです。
var window_drag_offset: Vector2i = Vector2i.ZERO  # ウィンドウ移動開始時の（マウス−ウィンドウ位置）差です。
var drag_start_mouse: Vector2 = Vector2.ZERO      # 矩形移動ドラッグ開始時のマウス位置です。
var drag_start_rect_pos: Vector2i = Vector2i.ZERO # 矩形移動ドラッグ開始時の矩形位置です。
var window_to_capture_scale: float = 1.0    # ウィンドウ1pxあたりのキャプチャ元px数です（レイアウト時に更新）。
var debug_shot_done: bool = false           # デバッグ用スクリーンショットを保存済みかです。
var debug_dump_done: bool = false           # デバッグ用キャプチャ生画像を保存済みかです。
var frozen_size: Vector2i = Vector2i.ZERO   # 静止スクリーンショットの実ピクセルサイズです。
var select_screen_origin: Vector2i = Vector2i.ZERO  # 選択対象スクリーン左上のデスクトップ絶対座標です。

# ── ノード・リソース参照 ──────────────────────────────────────────────────────
var frozen_texture: ImageTexture = null     # 選択モード用の静止スクリーンショットです。
var capture_texture: ImageTexture = null    # ライブキャプチャ用テクスチャです。
var canvas_viewport: SubViewport = null     # NTSCキャンバス（黒背景＋キャプチャ中央配置）です。
var canvas_bg: ColorRect = null             # キャンバスの黒背景です。
var capture_view: TextureRect = null        # キャンバス内のキャプチャ表示ノードです。
var signal_viewport: SubViewport = null     # Stage1レンダリング先です。
var signal_rect: ColorRect = null           # Stage1シェーダーを持つ矩形です。
var signal_material: ShaderMaterial = null  # Stage1マテリアルです。
var tv_display: ColorRect = null            # Stage2シェーダーを持つ最終表示矩形です。
var display_material: ShaderMaterial = null # Stage2マテリアルです。
var close_button: Button = null             # 右上の✕終了ボタンです。
var param_panel: PanelContainer = null      # パラメータ調節パネルです。
var param_controls: Dictionary = {}         # パラメータ名→UIコントロールです。


func _ready() -> void:
    # 【重要】コンテンツスケールを必ず無効化します。このアプリはマウス座標＝物理ピクセルの
    # 前提で矩形選択・キャプチャ座標を計算するため、プロジェクト設定で stretch/mode が
    # viewport 等に変更されていると選択矩形とキャプチャ領域が大きくずれます
    # （2026-07-13に実際に発生。NTSCの低解像度表現は内部のSubViewportパイプラインが担います）。
    get_window().content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
    get_window().content_scale_aspect = Window.CONTENT_SCALE_ASPECT_IGNORE
    # 診断用グラデーション表示モード（TURNTV_GRADIENT=スクリーン番号 で起動時のみ）。
    if OS.get_environment("TURNTV_GRADIENT") != "":
        _setup_gradient_test()
        return
    var win: Window = get_window()
    win.title = "TurnTV"
    win.borderless = true
    win.always_on_top = true
    win.min_size = MIN_WINDOW_SIZE
    mouse_filter = Control.MOUSE_FILTER_IGNORE
    _init_param_values()
    _build_pipeline()
    _build_close_button()
    _build_param_panel()
    _load_settings()
    _apply_all_params()
    win.size_changed.connect(_on_window_size_changed)
    # 保存済み矩形があればTVモード、無ければ矩形選択モードから開始します。
    if capture_rect.size.x >= MIN_SELECT_SIZE and capture_rect.size.y >= MIN_SELECT_SIZE:
        call_deferred("_start_from_saved_rect")
    else:
        call_deferred("enter_select_mode")


# キャプチャ位置ずれ診断用: 各ピクセルへ自身の座標を色でエンコードしたグラデーションを
# 指定スクリーンへ全画面表示します（TURNTV_GRADIENT=スクリーン番号 で起動。通常運用では未使用）。
# エンコード: R=x%256, G=y%256, B=floor(x/256)*16+floor(y/256)（ウィンドウ左上原点）。
# キャプチャ画像の色をデコードすると「実際に取り込まれたスクリーン内座標」が判ります。
func _setup_gradient_test() -> void:
    set_process(false)
    set_process_unhandled_input(false)
    var env_value: String = OS.get_environment("TURNTV_GRADIENT")
    var test_screen: int = int(env_value) if env_value.is_valid_int() else 0
    var win: Window = get_window()
    win.title = "TurnTV Gradient Test"
    win.borderless = true
    win.always_on_top = true  # 他ウィンドウに隠れると診断できないため最前面にします。
    win.position = DisplayServer.screen_get_position(test_screen)
    win.size = DisplayServer.screen_get_size(test_screen)
    var rect_node: ColorRect = ColorRect.new()
    add_child(rect_node)
    rect_node.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    var grad_shader: Shader = Shader.new()
    grad_shader.code = "shader_type canvas_item;\nvoid fragment() {\n\tfloat x = floor(FRAGCOORD.x);\n\tfloat y = floor(FRAGCOORD.y);\n\tCOLOR = vec4(mod(x, 256.0) / 255.0, mod(y, 256.0) / 255.0, (floor(x / 256.0) * 16.0 + floor(y / 256.0)) / 255.0, 1.0);\n}\n"
    var grad_material: ShaderMaterial = ShaderMaterial.new()
    grad_material.shader = grad_shader
    rect_node.material = grad_material
    await get_tree().process_frame
    print("TurnTV GRADIENT: screen=", test_screen, " win_pos=", win.position, " win_size=", win.size)


# 保存済み矩形でTVモードを復元開始します。
func _start_from_saved_rect() -> void:
    var win: Window = get_window()
    win.position = tv_window_pos
    win.size = tv_window_size
    has_tv_window_state = true
    enter_tv_mode(false)


# ═══ パラメータ管理 ═══════════════════════════════════════════════════════════

# 全パラメータを既定値で初期化します。
func _init_param_values() -> void:
    for def in PARAM_DEFS:
        if def.has("name"):
            param_values[def["name"]] = def["def"]


# 1パラメータを実際の適用先（シェーダーuniform / アプリ設定）へ反映します。
func _apply_param(param_name: String, value) -> void:
    param_values[param_name] = value
    var target: int = TARGET_APP
    for def in PARAM_DEFS:
        if def.has("name") and def["name"] == param_name:
            target = def["target"]
            break
    if target == TARGET_SIGNAL:
        signal_material.set_shader_parameter(param_name, value)
    elif target == TARGET_DISPLAY:
        display_material.set_shader_parameter(param_name, value)
    else:
        if param_name == "capture_interval":
            capture_interval = int(value)
        elif param_name == "always_on_top":
            get_window().always_on_top = bool(value)
        elif param_name == "canvas_width":
            _set_canvas_size(Vector2i(int(value), canvas_size.y))
        elif param_name == "canvas_height":
            _set_canvas_size(Vector2i(canvas_size.x, int(value)))


# 全パラメータをまとめて適用します（起動時・設定読込後・リセット時）。
func _apply_all_params() -> void:
    for def in PARAM_DEFS:
        if def.has("name"):
            _apply_param(def["name"], param_values[def["name"]])


# 全パラメータを既定値（コンポジットTVプリセット）へ戻し、UIも同期します。
func _reset_params_to_default() -> void:
    _init_param_values()
    _apply_all_params()
    _sync_param_controls()


# UIコントロールの表示値を param_values に合わせます。
func _sync_param_controls() -> void:
    for param_name in param_controls:
        var ctrl = param_controls[param_name]
        var value = param_values[param_name]
        if ctrl is HSlider:
            ctrl.set_value_no_signal(float(value))
            ctrl.value_changed.emit(float(value))
        elif ctrl is CheckBox:
            ctrl.set_pressed_no_signal(bool(value))
        elif ctrl is OptionButton:
            ctrl.select(int(value))


# NTSCキャンバス解像度を変更し、関連ノードとuniformを更新します。
func _set_canvas_size(new_size: Vector2i) -> void:
    canvas_size = new_size
    canvas_viewport.size = canvas_size
    signal_viewport.size = canvas_size
    canvas_bg.size = Vector2(canvas_size)
    signal_rect.size = Vector2(canvas_size)
    signal_material.set_shader_parameter("source_size", Vector2(canvas_size))
    display_material.set_shader_parameter("source_size", Vector2(canvas_size))
    _update_tv_layout()


# ═══ レンダリングパイプライン構築 ═══════════════════════════════════════════════

func _build_pipeline() -> void:
    # NTSCキャンバス: 黒背景の中央にキャプチャ画像を置く低解像度ビューポートです。
    canvas_viewport = SubViewport.new()
    canvas_viewport.disable_3d = true
    canvas_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
    canvas_viewport.size = canvas_size
    add_child(canvas_viewport)
    canvas_bg = ColorRect.new()
    canvas_bg.color = Color.BLACK
    canvas_bg.position = Vector2.ZERO
    canvas_bg.size = Vector2(canvas_size)
    canvas_viewport.add_child(canvas_bg)
    capture_view = TextureRect.new()
    capture_view.stretch_mode = TextureRect.STRETCH_SCALE
    capture_view.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
    canvas_viewport.add_child(capture_view)

    # Stage1: NTSC信号劣化をキャンバスと同解像度で焼き込みます。
    signal_viewport = SubViewport.new()
    signal_viewport.disable_3d = true
    signal_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
    signal_viewport.size = canvas_size
    add_child(signal_viewport)
    signal_rect = ColorRect.new()
    signal_rect.position = Vector2.ZERO
    signal_rect.size = Vector2(canvas_size)
    signal_material = ShaderMaterial.new()
    signal_material.shader = load("res://crt_signal.gdshader")
    signal_rect.material = signal_material
    signal_viewport.add_child(signal_rect)
    signal_material.set_shader_parameter("source_texture", canvas_viewport.get_texture())
    signal_material.set_shader_parameter("source_size", Vector2(canvas_size))

    # Stage2: CRT表示。メインウィンドウ上の最終表示ノードです。
    tv_display = ColorRect.new()
    tv_display.mouse_filter = Control.MOUSE_FILTER_IGNORE
    display_material = ShaderMaterial.new()
    display_material.shader = load("res://crt_display.gdshader")
    tv_display.material = display_material
    add_child(tv_display)
    display_material.set_shader_parameter("source_texture", signal_viewport.get_texture())
    display_material.set_shader_parameter("source_size", Vector2(canvas_size))
    display_material.set_shader_parameter("output_size", Vector2(640, 480))


# ═══ UI構築 ═══════════════════════════════════════════════════════════════════

# 右上の✕終了ボタンを作ります。
func _build_close_button() -> void:
    close_button = Button.new()
    close_button.text = "✕"
    close_button.tooltip_text = "終了"
    close_button.custom_minimum_size = Vector2(32, 32)
    close_button.anchor_left = 1.0
    close_button.anchor_right = 1.0
    close_button.anchor_top = 0.0
    close_button.anchor_bottom = 0.0
    close_button.offset_left = -36
    close_button.offset_right = -4
    close_button.offset_top = 4
    close_button.offset_bottom = 36
    close_button.pressed.connect(_quit_app)
    add_child(close_button)


# 右クリックで開くパラメータ調節パネルを作ります。
func _build_param_panel() -> void:
    param_panel = PanelContainer.new()
    param_panel.visible = false
    param_panel.anchor_left = 1.0
    param_panel.anchor_right = 1.0
    param_panel.anchor_top = 0.0
    param_panel.anchor_bottom = 1.0
    param_panel.offset_left = -400
    param_panel.offset_right = 0
    param_panel.offset_top = 44
    param_panel.offset_bottom = 0
    add_child(param_panel)

    var scroll: ScrollContainer = ScrollContainer.new()
    scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
    param_panel.add_child(scroll)
    var vbox: VBoxContainer = VBoxContainer.new()
    vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    scroll.add_child(vbox)

    var title: Label = Label.new()
    title.text = "TVパラメータ調節（右クリックで閉じる）"
    vbox.add_child(title)

    var button_row: HBoxContainer = HBoxContainer.new()
    vbox.add_child(button_row)
    var reselect_button: Button = Button.new()
    reselect_button.text = "矩形を再選択"
    reselect_button.pressed.connect(func() -> void: enter_select_mode())
    button_row.add_child(reselect_button)
    var reset_button: Button = Button.new()
    reset_button.text = "既定値に戻す"
    reset_button.pressed.connect(_reset_params_to_default)
    button_row.add_child(reset_button)

    for def in PARAM_DEFS:
        if def.has("section"):
            var section_label: Label = Label.new()
            section_label.text = "── " + def["section"] + " ──"
            section_label.modulate = Color(1.0, 0.85, 0.4)
            vbox.add_child(section_label)
            continue
        _build_param_row(vbox, def)


# 1パラメータぶんのUI行（ラベル＋スライダー等）を作ります。
func _build_param_row(vbox: VBoxContainer, def: Dictionary) -> void:
    var row: HBoxContainer = HBoxContainer.new()
    vbox.add_child(row)
    var label: Label = Label.new()
    label.text = def["label"]
    label.custom_minimum_size = Vector2(168, 0)
    label.clip_text = true
    row.add_child(label)

    var param_name: String = def["name"]
    var param_type: String = def.get("type", "float")
    if param_type == "bool":
        var check: CheckBox = CheckBox.new()
        check.button_pressed = bool(param_values[param_name])
        check.toggled.connect(func(on: bool) -> void: _apply_param(param_name, on))
        row.add_child(check)
        param_controls[param_name] = check
    elif param_type == "enum":
        var option: OptionButton = OptionButton.new()
        for item_text in def["items"]:
            option.add_item(item_text)
        option.select(int(param_values[param_name]))
        option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
        option.item_selected.connect(func(index: int) -> void: _apply_param(param_name, index))
        row.add_child(option)
        param_controls[param_name] = option
    else:
        var slider: HSlider = HSlider.new()
        slider.min_value = float(def["min"])
        slider.max_value = float(def["max"])
        slider.step = float(def["step"])
        slider.value = float(param_values[param_name])
        slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
        slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
        row.add_child(slider)
        var value_label: Label = Label.new()
        value_label.custom_minimum_size = Vector2(56, 0)
        value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
        row.add_child(value_label)
        var is_int: bool = (param_type == "int")
        var update_func: Callable = func(value: float) -> void:
            if is_int:
                value_label.text = str(int(value))
                _apply_param(param_name, int(value))
            else:
                value_label.text = "%.3f" % value
                _apply_param(param_name, value)
        slider.value_changed.connect(update_func)
        update_func.call(float(param_values[param_name]))
        param_controls[param_name] = slider


# ═══ モード遷移 ═══════════════════════════════════════════════════════════════

# 矩形選択モードへ入ります。自ウィンドウを最小化してデスクトップ静止画を取得し、
# 画面全体に広げたウィンドウ上でドラッグ選択させます。
func enter_select_mode() -> void:
    var win: Window = get_window()
    if mode == Mode.TV and has_tv_window_state:
        tv_window_pos = win.position
        tv_window_size = win.size
    mode = Mode.SELECT
    select_ready = false
    selecting = false
    param_panel.visible = false
    close_button.visible = false
    tv_display.visible = false
    capture_screen = _screen_under_mouse()
    # 最小化して自ウィンドウをスクリーンショットから外します。
    win.mode = Window.MODE_MINIMIZED
    await get_tree().create_timer(SELECT_CAPTURE_WAIT).timeout
    var img: Image = DisplayServer.screen_get_image(capture_screen)
    frozen_texture = ImageTexture.create_from_image(img)
    frozen_size = img.get_size()
    select_screen_origin = DisplayServer.screen_get_position(capture_screen)
    # 【重要】ボーダーレスウィンドウをスクリーンサイズぴったりへ手動リサイズすると、
    # Windows側で排他フルスクリーン（MODE_EXCLUSIVE_FULLSCREEN）へ自動昇格してしまい、
    # 以後のウィンドウ化・縮小が無視されて全画面のまま残ります（2026-07-13に実測）。
    # そのため明示的に MODE_FULLSCREEN を使い、正規の手順で行き来させます。
    win.mode = Window.MODE_WINDOWED
    win.current_screen = capture_screen
    win.mode = Window.MODE_FULLSCREEN
    select_ready = true
    queue_redraw()
    # 診断ログ: ウィンドウが要求どおりの位置・サイズになったかを1フレーム後に出力します。
    # （タスクバー等でウィンドウがクランプされると静止画が伸縮表示され、座標補正が必要になります）
    await get_tree().process_frame
    print("TurnTV SELECT geom: screen=", capture_screen, " origin=", select_screen_origin,
            " screen_size=", DisplayServer.screen_get_size(capture_screen),
            " win_pos=", win.position, " win_size=", win.size, " frozen=", frozen_size)
    # デバッグ用: TURNTV_AUTOSELECT="x,y,w,h"（ウィンドウ座標）で起動すると、その矩形を
    # 自動確定して選択→TV遷移を無人テストできます（通常起動では何もしません）。
    var auto_sel: String = OS.get_environment("TURNTV_AUTOSELECT")
    if auto_sel != "":
        var parts: PackedStringArray = auto_sel.split(",")
        if parts.size() == 4:
            var auto_rect: Rect2 = Rect2(float(parts[0]), float(parts[1]), float(parts[2]), float(parts[3]))
            capture_rect = _selection_to_screen_rect(auto_rect)
            print("TurnTV AUTOSELECT -> capture_rect=", capture_rect)
            enter_tv_mode(true)
            await get_tree().create_timer(1.0).timeout
            print("TurnTV after TV transition: win_mode=", win.mode,
                    " win_pos=", win.position, " win_size=", win.size)


# TV表示モードへ入ります。from_selection=trueなら選択直後で、ウィンドウサイズを
# 「選択矩形が約90%を占める」サイズへ合わせ、ズームをリセットします。
func enter_tv_mode(from_selection: bool) -> void:
    mode = Mode.TV
    var win: Window = get_window()
    # 選択用の静止画は解放します（巨大テクスチャの保持と描き残りの防止）。
    frozen_texture = null
    tv_display.visible = true
    close_button.visible = true
    capture_frame_accum = capture_interval  # 次フレームで即キャプチャさせます。
    if from_selection:
        zoom = 1.0
    queue_redraw()
    # 【重要】画面全体に広げた選択ウィンドウは、Windows側で最大化/フルスクリーン扱いに
    # なることがあり、その状態でのサイズ変更は無視されて全画面のまま残ります。
    # 先にウィンドウ化へ戻し、1フレーム待って反映させてからサイズ・位置を適用します。
    win.mode = Window.MODE_WINDOWED
    await get_tree().process_frame
    if from_selection:
        var desired: Vector2i = Vector2i((Vector2(capture_rect.size) / RECT_WINDOW_RATIO).ceil()) + Vector2i(2, 2)
        var screen_limit: Vector2i = Vector2i(Vector2(DisplayServer.screen_get_size(capture_screen)) * 0.9)
        desired = desired.clamp(MIN_WINDOW_SIZE, screen_limit)
        win.size = desired
        if has_tv_window_state:
            win.position = tv_window_pos
        else:
            var screen_pos: Vector2i = DisplayServer.screen_get_position(capture_screen)
            var screen_size: Vector2i = DisplayServer.screen_get_size(capture_screen)
            win.position = screen_pos + (screen_size - desired) / 2
        tv_window_pos = win.position
        tv_window_size = win.size
        has_tv_window_state = true
    elif has_tv_window_state:
        # 選択キャンセル（ESC）等での復帰時も、全画面状態を確実に解除して元の位置へ戻します。
        win.size = tv_window_size
        win.position = tv_window_pos
    _update_tv_layout()
    queue_redraw()


# アプリを終了します（設定保存つき）。
func _quit_app() -> void:
    _save_settings()
    get_tree().quit()


# Alt+F4等のOS経由の終了要求でも設定を保存します（保存漏れ対策）。
func _notification(what: int) -> void:
    if what == NOTIFICATION_WM_CLOSE_REQUEST and mode == Mode.TV:
        _save_settings()


# ═══ 毎フレーム処理 ═══════════════════════════════════════════════════════════

func _process(delta: float) -> void:
    # シェーダーへ渡す60fps換算フレーム番号を進めます（ドットクロール・ノイズ・480i用）。
    frame_count += delta * 60.0
    if frame_count > 100000.0:
        frame_count = 0.0
    var frame_floor: float = floor(frame_count)
    signal_material.set_shader_parameter("frame_count", frame_floor)
    display_material.set_shader_parameter("frame_count", frame_floor)
    # TVモード中は指定間隔でライブキャプチャを更新します。
    if mode == Mode.TV and capture_rect.size.x >= MIN_SELECT_SIZE:
        capture_frame_accum += 1
        if capture_frame_accum >= capture_interval:
            capture_frame_accum = 0
            _update_capture()
    # デバッグ用: 環境変数 TURNTV_SHOT にパスを入れて起動すると、約3秒後に
    # ウィンドウ内容をPNG保存します（自動テスト用。通常起動では何もしません）。
    if not debug_shot_done and frame_count > 180.0:
        debug_shot_done = true
        var shot_path: String = OS.get_environment("TURNTV_SHOT")
        if shot_path != "":
            var shot: Image = get_viewport().get_texture().get_image()
            shot.save_png(shot_path)


# 選択矩形のライブキャプチャを1回実行し、キャンバスへ反映します。
func _update_capture() -> void:
    var img: Image = null
    if DisplayServer.has_method("screen_get_image_rect"):
        img = DisplayServer.screen_get_image_rect(capture_rect)
    else:
        # 旧API環境向けフォールバック: スクリーン全体を撮って切り出します。
        var full: Image = DisplayServer.screen_get_image(capture_screen)
        if full != null:
            var origin: Vector2i = DisplayServer.screen_get_position(capture_screen)
            img = full.get_region(Rect2i(capture_rect.position - origin, capture_rect.size))
    if img == null:
        return
    # デバッグ用: 環境変数 TURNTV_DUMP にパスを入れて起動すると、最初のキャプチャ生画像を
    # PNG保存します（座標ずれ調査用。通常起動では何もしません）。比較用に
    # 「全画面取得＋切り出し」方式の画像も <パス>.crop.png へ保存します。
    if not debug_dump_done:
        debug_dump_done = true
        var dump_path: String = OS.get_environment("TURNTV_DUMP")
        if dump_path != "":
            img.save_png(dump_path)
            print("TurnTV CAPTURE dump: rect=", capture_rect, " img_size=", img.get_size())
            var full_img: Image = DisplayServer.screen_get_image(capture_screen)
            if full_img != null:
                var origin2: Vector2i = DisplayServer.screen_get_position(capture_screen)
                var local2: Rect2i = Rect2i(capture_rect.position - origin2, capture_rect.size)
                local2 = local2.intersection(Rect2i(Vector2i.ZERO, full_img.get_size()))
                if local2.size.x > 0 and local2.size.y > 0:
                    full_img.get_region(local2).save_png(dump_path + ".crop.png")
                    print("TurnTV CAPTURE crop dump: local=", local2)
    # サイズ・フォーマットが同じならテクスチャを再利用して転送のみ行います。
    if capture_texture != null and Vector2i(capture_texture.get_size()) == img.get_size() and capture_texture.get_format() == img.get_format():
        capture_texture.update(img)
    else:
        capture_texture = ImageTexture.create_from_image(img)
        capture_view.texture = capture_texture


# TV表示のレイアウトを再計算します。
# 選択矩形がウィンドウの約90%（×ズーム）を占めるようにStage2出力を拡大配置します。
func _update_tv_layout() -> void:
    if capture_rect.size.x < 1 or capture_rect.size.y < 1:
        return
    var win_size: Vector2 = Vector2(get_window().size)
    var rect_size: Vector2 = Vector2(capture_rect.size)
    # キャンバスに収まる縮小率（大きい矩形はキャンバス内へ縮小、小さい矩形は等倍）です。
    var fit: float = minf(1.0, minf(float(canvas_size.x) / rect_size.x, float(canvas_size.y) / rect_size.y))
    var disp: Vector2 = rect_size * fit
    capture_view.size = disp
    capture_view.position = (Vector2(canvas_size) - disp) * 0.5
    # 矩形部分がウィンドウの RECT_WINDOW_RATIO を占める拡大率にズームを乗算します。
    var k: float = RECT_WINDOW_RATIO * minf(win_size.x / disp.x, win_size.y / disp.y) * zoom
    # 矩形移動ドラッグ用: ウィンドウ上の1pxがキャプチャ元の何pxに当たるかを覚えておきます。
    window_to_capture_scale = 1.0 / maxf(fit * k, 0.0001)
    var tv_size: Vector2 = Vector2(canvas_size) * k
    tv_display.size = tv_size
    tv_display.position = (win_size - tv_size) * 0.5
    display_material.set_shader_parameter("output_size", tv_size)


func _on_window_size_changed() -> void:
    if mode == Mode.TV:
        _update_tv_layout()
    queue_redraw()


# ═══ 入力処理 ═══════════════════════════════════════════════════════════════

func _unhandled_input(event: InputEvent) -> void:
    if mode == Mode.SELECT:
        _handle_select_input(event)
    else:
        _handle_tv_input(event)


# 矩形選択モードの入力処理です。
func _handle_select_input(event: InputEvent) -> void:
    if not select_ready:
        return
    if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
        if event.pressed:
            selecting = true
            select_start = event.position
            select_end = event.position
            queue_redraw()
        elif selecting:
            selecting = false
            select_end = event.position
            var local_rect: Rect2 = _selection_rect()
            if local_rect.size.x >= MIN_SELECT_SIZE and local_rect.size.y >= MIN_SELECT_SIZE:
                var new_rect: Rect2i = _selection_to_screen_rect(local_rect)
                print("TurnTV SELECT rect: local=", local_rect, " view=", size,
                        " -> capture_rect=", new_rect)
                if new_rect.size.x >= MIN_SELECT_SIZE and new_rect.size.y >= MIN_SELECT_SIZE:
                    capture_rect = new_rect
                    enter_tv_mode(true)
                else:
                    queue_redraw()
            else:
                queue_redraw()
    elif event is InputEventMouseMotion and selecting:
        select_end = event.position
        queue_redraw()
    elif event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
        if capture_rect.size.x >= MIN_SELECT_SIZE and capture_rect.size.y >= MIN_SELECT_SIZE:
            enter_tv_mode(false)  # ウィンドウ位置・サイズの復元は enter_tv_mode 内で行います。
        else:
            _quit_app()


# TV表示モードの入力処理です。
func _handle_tv_input(event: InputEvent) -> void:
    if event is InputEventMouseButton:
        if event.button_index == MOUSE_BUTTON_LEFT:
            if event.pressed:
                var edge: int = _edge_at(event.position)
                if edge >= 0:
                    # 外周ドラッグ: OSのウィンドウリサイズへ委譲します。
                    DisplayServer.window_start_resize(edge, get_window().get_window_id())
                elif event.position.y <= TOP_BAR_HEIGHT:
                    # 上部帯ドラッグ: ウィンドウ移動を開始します（自前実装。exeでも確実に動きます）。
                    _begin_window_drag()
                else:
                    pressed_center = true
                    press_pos = event.position
            else:
                if window_dragging:
                    window_dragging = false
                elif dragging_rect:
                    # 矩形移動ドラッグの終了です（クリック扱いにはしません）。
                    dragging_rect = false
                    Input.set_default_cursor_shape(Input.CURSOR_ARROW)
                elif pressed_center:
                    # 動かさず離した＝クリック → 矩形選択モードへ移行します。
                    pressed_center = false
                    enter_select_mode()
        elif event.button_index == MOUSE_BUTTON_MIDDLE:
            if event.pressed:
                # 中ボタンドラッグ: どこを掴んでもウィンドウ移動します（自前実装）。
                _begin_window_drag()
            else:
                window_dragging = false
        elif event.button_index == MOUSE_BUTTON_RIGHT:
            if not event.pressed:
                param_panel.visible = not param_panel.visible
        elif event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
            zoom = minf(zoom * ZOOM_STEP, ZOOM_MAX)
            _update_tv_layout()
        elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
            zoom = maxf(zoom / ZOOM_STEP, ZOOM_MIN)
            _update_tv_layout()
    elif event is InputEventMouseMotion:
        if window_dragging:
            # グローバルマウス基準で追従させ、座標フィードバックによるガタつきを避けます。
            get_window().position = DisplayServer.mouse_get_position() - window_drag_offset
        elif dragging_rect:
            _drag_capture_rect(event.position)
        elif pressed_center:
            if event.position.distance_to(press_pos) > CLICK_MOVE_THRESHOLD:
                # 一定量動いた＝ドラッグ → 選択矩形（映す場所）の移動を開始します。
                pressed_center = false
                dragging_rect = true
                drag_start_mouse = press_pos
                drag_start_rect_pos = capture_rect.position
                Input.set_default_cursor_shape(Input.CURSOR_MOVE)
                _drag_capture_rect(event.position)
        else:
            _update_edge_cursor(event.position)
    elif event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
        _quit_app()


# ウィンドウ移動ドラッグを開始します（上部帯の左ドラッグ／任意位置の中ボタンドラッグ）。
func _begin_window_drag() -> void:
    window_dragging = true
    window_drag_offset = DisplayServer.mouse_get_position() - get_window().position


# マウスカーソルがあるスクリーン番号を返します（該当なしならウィンドウの現在スクリーン）。
# マルチモニタ環境で「マウスがあるモニタ」に矩形選択画面を出すために使います。
func _screen_under_mouse() -> int:
    var mouse_global: Vector2i = DisplayServer.mouse_get_position()
    for s in DisplayServer.get_screen_count():
        var screen_rect: Rect2i = Rect2i(DisplayServer.screen_get_position(s), DisplayServer.screen_get_size(s))
        if screen_rect.has_point(mouse_global):
            return s
    return get_window().current_screen


# 左ドラッグ中の選択矩形（映す場所）の移動処理です。
# 「TV画像を掴んで動かす」操作感にするため、マウス移動と逆方向へ矩形を動かします
# （画像がマウスに付いてくる＝キャプチャ元は逆へずれる）。スクリーン範囲内へクランプします。
func _drag_capture_rect(mouse_pos: Vector2) -> void:
    var delta: Vector2 = mouse_pos - drag_start_mouse
    var new_pos: Vector2i = drag_start_rect_pos - Vector2i((delta * window_to_capture_scale).round())
    var s_origin: Vector2i = DisplayServer.screen_get_position(capture_screen)
    var s_size: Vector2i = DisplayServer.screen_get_size(capture_screen)
    new_pos = new_pos.clamp(s_origin, s_origin + s_size - capture_rect.size)
    capture_rect.position = new_pos


# 指定位置がウィンドウ外周のどのリサイズ縁かを返します（-1=縁ではない）。
func _edge_at(pos: Vector2) -> int:
    var win_size: Vector2 = Vector2(get_window().size)
    var on_left: bool = pos.x <= EDGE_MARGIN
    var on_right: bool = pos.x >= win_size.x - EDGE_MARGIN
    var on_top: bool = pos.y <= EDGE_MARGIN
    var on_bottom: bool = pos.y >= win_size.y - EDGE_MARGIN
    if on_top and on_left:
        return DisplayServer.WINDOW_EDGE_TOP_LEFT
    if on_top and on_right:
        return DisplayServer.WINDOW_EDGE_TOP_RIGHT
    if on_bottom and on_left:
        return DisplayServer.WINDOW_EDGE_BOTTOM_LEFT
    if on_bottom and on_right:
        return DisplayServer.WINDOW_EDGE_BOTTOM_RIGHT
    if on_left:
        return DisplayServer.WINDOW_EDGE_LEFT
    if on_right:
        return DisplayServer.WINDOW_EDGE_RIGHT
    if on_top:
        return DisplayServer.WINDOW_EDGE_TOP
    if on_bottom:
        return DisplayServer.WINDOW_EDGE_BOTTOM
    return -1


# 外周ホバー時にリサイズ用カーソル形状へ切り替えます。
func _update_edge_cursor(pos: Vector2) -> void:
    var edge: int = _edge_at(pos)
    var shape: int = Input.CURSOR_ARROW
    if edge < 0 and pos.y <= TOP_BAR_HEIGHT:
        shape = Input.CURSOR_MOVE
    elif edge == DisplayServer.WINDOW_EDGE_LEFT or edge == DisplayServer.WINDOW_EDGE_RIGHT:
        shape = Input.CURSOR_HSIZE
    elif edge == DisplayServer.WINDOW_EDGE_TOP or edge == DisplayServer.WINDOW_EDGE_BOTTOM:
        shape = Input.CURSOR_VSIZE
    elif edge == DisplayServer.WINDOW_EDGE_TOP_LEFT or edge == DisplayServer.WINDOW_EDGE_BOTTOM_RIGHT:
        shape = Input.CURSOR_FDIAGSIZE
    elif edge == DisplayServer.WINDOW_EDGE_TOP_RIGHT or edge == DisplayServer.WINDOW_EDGE_BOTTOM_LEFT:
        shape = Input.CURSOR_BDIAGSIZE
    Input.set_default_cursor_shape(shape)


# ドラッグ中の選択矩形（ウィンドウ座標）を返します。
func _selection_rect() -> Rect2:
    var top_left: Vector2 = Vector2(minf(select_start.x, select_end.x), minf(select_start.y, select_end.y))
    var rect_size: Vector2 = (select_end - select_start).abs()
    return Rect2(top_left, rect_size)


# 選択矩形（ウィンドウ座標）をデスクトップ絶対座標へ変換します。
# 静止スクリーンショットはウィンドウ全面へ伸縮表示されるため、「ウィンドウサイズ⇔静止画実サイズ」
# の比率で補正してから、スクリーン左上の絶対座標を加算します。タスクバー・DPIスケーリング等で
# ウィンドウがスクリーンサイズちょうどにならない環境でも、見えている静止画上の位置と一致します。
func _selection_to_screen_rect(local_rect: Rect2) -> Rect2i:
    var view_size: Vector2 = size
    if view_size.x < 1.0 or view_size.y < 1.0 or frozen_size.x < 1 or frozen_size.y < 1:
        # 静止画情報が無い異常時のフォールバック: 補正なしでウィンドウ座標をそのまま使います。
        return Rect2i(select_screen_origin + Vector2i(local_rect.position), Vector2i(local_rect.size))
    var img_scale: Vector2 = Vector2(frozen_size) / view_size
    var img_pos: Vector2 = (local_rect.position * img_scale).round()
    var img_size: Vector2 = (local_rect.size * img_scale).round()
    # 静止画（＝スクリーン）の範囲内へクランプしてから絶対座標にします。
    var image_rect: Rect2i = Rect2i(Vector2i(img_pos), Vector2i(img_size)).intersection(Rect2i(Vector2i.ZERO, frozen_size))
    return Rect2i(select_screen_origin + image_rect.position, image_rect.size)


# ═══ 描画 ═══════════════════════════════════════════════════════════════════

func _draw() -> void:
    if mode == Mode.SELECT:
        _draw_select_overlay()
    else:
        # TVモードの背景（Stage2ノードの外側）は黒で塗ります。
        draw_rect(Rect2(Vector2.ZERO, size), Color.BLACK)
        # 上部の移動用グラブバー（疑似タイトルバー）です。ここを左ドラッグでウィンドウ移動できます。
        draw_rect(Rect2(0, 0, size.x, TOP_BAR_HEIGHT), Color(0.12, 0.12, 0.15, 0.85))
        var font: Font = get_theme_default_font()
        draw_string(font, Vector2(10, TOP_BAR_HEIGHT - 8), "≡ TurnTV ─ この帯をドラッグでウィンドウ移動",
                HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color(0.75, 0.75, 0.8))


# 選択モードのオーバーレイ（静止画＋暗幕＋選択矩形＋案内文）を描きます。
func _draw_select_overlay() -> void:
    var dim: Color = Color(0.0, 0.0, 0.0, 0.45)
    if frozen_texture != null:
        draw_texture_rect(frozen_texture, Rect2(Vector2.ZERO, size), false)
    var font: Font = get_theme_default_font()
    var font_size: int = 18
    if selecting:
        var r: Rect2 = _selection_rect()
        # 選択矩形の外側4領域だけ暗幕をかけ、内側は素通しで見せます。
        draw_rect(Rect2(0, 0, size.x, r.position.y), dim)
        draw_rect(Rect2(0, r.end.y, size.x, size.y - r.end.y), dim)
        draw_rect(Rect2(0, r.position.y, r.position.x, r.size.y), dim)
        draw_rect(Rect2(r.end.x, r.position.y, size.x - r.end.x, r.size.y), dim)
        draw_rect(r, Color(1.0, 1.0, 1.0, 0.9), false, 2.0)
        # 表示サイズではなく、実際にキャプチャされるピクセル数（静止画スケール補正後）を表示します。
        var img_scale: Vector2 = Vector2(frozen_size) / size if (size.x >= 1.0 and size.y >= 1.0) else Vector2.ONE
        var size_text: String = "%d x %d" % [int(round(r.size.x * img_scale.x)), int(round(r.size.y * img_scale.y))]
        draw_string(font, r.position + Vector2(4, -8), size_text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, Color(1.0, 1.0, 0.4))
    else:
        draw_rect(Rect2(Vector2.ZERO, size), dim)
        var message: String = "ドラッグでTV表示する矩形を選択してください（ESC=キャンセル）"
        var text_width: float = font.get_string_size(message, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
        var text_pos: Vector2 = Vector2((size.x - text_width) * 0.5, size.y * 0.5)
        draw_string(font, text_pos + Vector2(1, 1), message, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, Color(0, 0, 0, 0.8))
        draw_string(font, text_pos, message, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, Color(1, 1, 1, 0.95))


# ═══ 設定の保存・読込 ═══════════════════════════════════════════════════════

func _save_settings() -> void:
    var win: Window = get_window()
    if mode == Mode.TV:
        tv_window_pos = win.position
        tv_window_size = win.size
    var data: Dictionary = {
        "version": 1,
        "params": param_values,
        "rect": [capture_rect.position.x, capture_rect.position.y, capture_rect.size.x, capture_rect.size.y],
        "screen": capture_screen,
        "window": [tv_window_pos.x, tv_window_pos.y, tv_window_size.x, tv_window_size.y],
        "zoom": zoom,
    }
    var file: FileAccess = FileAccess.open(SETTINGS_PATH, FileAccess.WRITE)
    if file != null:
        file.store_string(JSON.stringify(data, "  "))
        file.close()


func _load_settings() -> void:
    if not FileAccess.file_exists(SETTINGS_PATH):
        return
    var file: FileAccess = FileAccess.open(SETTINGS_PATH, FileAccess.READ)
    if file == null:
        return
    var parsed = JSON.parse_string(file.get_as_text())
    file.close()
    if not (parsed is Dictionary):
        return
    var saved_params = parsed.get("params", {})
    if saved_params is Dictionary:
        for def in PARAM_DEFS:
            if def.has("name") and saved_params.has(def["name"]):
                var value = saved_params[def["name"]]
                var param_type: String = def.get("type", "float")
                if param_type == "int" or param_type == "enum":
                    param_values[def["name"]] = int(value)
                elif param_type == "bool":
                    param_values[def["name"]] = bool(value)
                else:
                    param_values[def["name"]] = float(value)
    var rect_array = parsed.get("rect", [])
    if rect_array is Array and rect_array.size() == 4:
        capture_rect = Rect2i(int(rect_array[0]), int(rect_array[1]), int(rect_array[2]), int(rect_array[3]))
    capture_screen = int(parsed.get("screen", 0))
    if capture_screen < 0 or capture_screen >= DisplayServer.get_screen_count():
        capture_screen = 0
    var window_array = parsed.get("window", [])
    if window_array is Array and window_array.size() == 4:
        tv_window_pos = Vector2i(int(window_array[0]), int(window_array[1]))
        tv_window_size = Vector2i(int(window_array[2]), int(window_array[3]))
    zoom = clampf(float(parsed.get("zoom", 1.0)), ZOOM_MIN, ZOOM_MAX)
    _sync_param_controls()

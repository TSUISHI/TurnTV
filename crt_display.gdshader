// CRT表現 Stage2（CRT表示・蛍光体表示側）用シェーダーです。
// Gemidius BaseState.gd の CRT_DISPLAY_SHADER_CODE からの移植です。
// 設計書: CRT_SHADER_DESIGN_20260711.md §4（Stage2設計）・§7（プリセット）
// 入力: Stage1のSubViewport出力（NTSC信号経路を通った低解像度画像）
// 出力: 最終表示解像度でのCRT表示。走査線、輝度依存ビーム幅、マスク3方式、画面カーブ、
//       角丸、外周減光、ベゼル暗部、480i風フィールド表示をまとめて処理します。
shader_type canvas_item;

// ─── 入力uniform（設計書§4.8） ───────────────────────────────────────────────
// Stage1出力。Stage1 SubViewport の get_texture() をGDScript側から接続します。
uniform sampler2D source_texture : filter_nearest, repeat_disable;
// Stage1の低解像度ソースサイズ。走査線位置と低解像度サンプルの基準です。
uniform vec2 source_size = vec2(320.0, 240.0);
// Stage2の実レンダーターゲットサイズ。マスクはこのピクセル座標基準で計算します。
uniform vec2 output_size = vec2(1280.0, 720.0);
// 60fpsフレーム番号。480i風フィールド切替に使います。
uniform float frame_count = 0.0;
// Stage2全体量。0でStage1出力そのまま、1でCRT表示効果を全量適用します。
uniform float display_amount : hint_range(0.0, 1.0) = 1.0;
// 走査線の減光量。ソースライン中心から離れるほど暗くします。
uniform float scanline_strength : hint_range(0.0, 1.0) = 0.42;
// 暗部ビーム幅。暗いピクセルほど細いビームにして黒線を強めます。
uniform float scanline_width_dark : hint_range(0.05, 1.0) = 0.14;
// 明部ビーム幅。明るいピクセルほど太いビームにしてCRTのにじむ明部を作ります。
uniform float scanline_width_bright : hint_range(0.05, 1.0) = 0.46;
// マスク方式。0=OFF、1=スロットマスクTV、2=アパーチャーグリル、3=シャドウマスク。
uniform int mask_type : hint_range(0, 3) = 1;
// マスク全体の適用量。0でマスクなし、1で蛍光体パターンを全量適用します。
uniform float mask_strength : hint_range(0.0, 1.0) = 0.45;
// 蛍光体ピッチ[最終表示px]。非整数拡大時も出力ピクセル基準で安定させます。
uniform float mask_pitch_px : hint_range(2.0, 8.0) = 3.5;
// 非該当サブピクセルの暗さ。小さいほどRGBマスクの色分離が強く見えます。
uniform float mask_dark : hint_range(0.0, 1.0) = 0.45;
// マスク境界のぼかし量。0ならfwidthを使わず、くっきりした境界にします。
uniform float mask_softness : hint_range(0.0, 2.0) = 0.35;
// 走査線とマスクで落ちた明るさの補償です。リニア空間で乗算します。
uniform float brightness_compensation : hint_range(0.5, 2.0) = 1.22;
// 入力ガンマ。Stage1出力をリニア空間へ持ち上げる指数です。
uniform float gamma_in : hint_range(1.0, 3.0) = 2.2;
// 出力ガンマ。最終的な表示RGBへ戻す指数です。
uniform float gamma_out : hint_range(1.0, 3.0) = 2.2;
// 軽量バレル歪み量。0で平面、値を上げるほど画面端がCRT管面らしく曲がります。
uniform float curve_amount : hint_range(0.0, 0.2) = 0.017;
// 画面角丸半径。UV単位で、0なら角丸なしです。
uniform float corner_radius : hint_range(0.0, 0.15) = 0.035;
// 外周減光。画面端へ向かって暗くする量です。
uniform float vignette_strength : hint_range(0.0, 1.0) = 0.18;
// ベゼル暗部。表示領域外や角丸外側を黒へ寄せる量です。
uniform float bezel_strength : hint_range(0.0, 1.0) = 0.35;
// 480i風表示のON/OFF。プリセット既定はすべてfalseです。
uniform bool interlace_enabled = false;
// 480i風で非該当フィールドをどれだけ暗くするか。
uniform float interlace_dim : hint_range(0.0, 1.0) = 0.77;
// 480i風フィールドの上下揺れ量[ソースpx]。
uniform float interlace_bob_px : hint_range(0.0, 1.0) = 0.4;

// ─── 定数・補助関数 ─────────────────────────────────────────────────────────
const vec3 CRT_STAGE2_LUMA = vec3(0.299, 0.587, 0.114);

// sRGB相当の入力をリニア空間へ変換します。ゼロ付近の負値を避けるため先にclampします。
vec3 crt_to_linear(vec3 color) {
    return pow(clamp(color, vec3(0.0), vec3(1.0)), vec3(gamma_in));
}

// リニア空間から表示RGBへ戻します。
vec3 crt_from_linear(vec3 color) {
    return pow(clamp(color, vec3(0.0), vec3(1.0)), vec3(1.0 / max(gamma_out, 0.0001)));
}

// マスク境界のソフト化。mask_softness=0ではfwidthを通らない軽いstepにします。
float crt_soft_step(float edge, float value) {
    if (mask_softness <= 0.0001) {
        return step(edge, value);
    }
    float width = max(fwidth(value) * mask_softness, 0.0001);
    return smoothstep(edge - width, edge + width, value);
}

// スロットマスクTV。RGBサブピクセルを2行ごとに半ピッチずらし、縦スロットの暗部を重ねます。
vec3 crt_slot_mask(vec2 screen_px) {
    float pitch = max(mask_pitch_px, 0.0001);
    vec2 cell = floor(screen_px / pitch);
    float row_shift = mod(cell.y, 2.0) * 1.5;
    float channel = mod(floor(screen_px.x / pitch + row_shift), 3.0);
    vec3 phosphor = vec3(mask_dark);
    if (channel < 1.0) {
        phosphor.r = 1.0;
    } else if (channel < 2.0) {
        phosphor.g = 1.0;
    } else {
        phosphor.b = 1.0;
    }
    float slot_phase = fract(screen_px.y / pitch);
    float slot_gate = mix(1.0, mask_dark, crt_soft_step(0.55, slot_phase));
    return mix(vec3(1.0), phosphor * slot_gate, mask_strength);
}

// アパーチャーグリル/トリニトロン。縦RGBストライプだけで、横方向に色を切り替えます。
vec3 crt_aperture_mask(vec2 screen_px) {
    float pitch = max(mask_pitch_px, 0.0001);
    float stripe = mod(floor(screen_px.x / pitch), 3.0);
    vec3 phosphor = vec3(mask_dark);
    if (stripe < 1.0) {
        phosphor.r = 1.0;
    } else if (stripe < 2.0) {
        phosphor.g = 1.0;
    } else {
        phosphor.b = 1.0;
    }
    return mix(vec3(1.0), phosphor, mask_strength);
}

// シャドウマスク/デルタトライアド。2行周期でRGBの並びをずらし、粒状感を作ります。
vec3 crt_shadow_mask(vec2 screen_px) {
    float pitch = max(mask_pitch_px, 0.0001);
    vec2 cell = floor(screen_px / pitch);
    float row = mod(cell.y, 2.0);
    float channel = mod(cell.x + row * 1.5, 3.0);
    vec3 triad_a = vec3(mask_dark);
    vec3 triad_b = vec3(mask_dark);
    if (channel < 1.0) {
        triad_a.r = 1.0;
        triad_b.g = 1.0;
    } else if (channel < 2.0) {
        triad_a.g = 1.0;
        triad_b.b = 1.0;
    } else {
        triad_a.b = 1.0;
        triad_b.r = 1.0;
    }
    return mix(vec3(1.0), mix(triad_a, triad_b, row), mask_strength);
}

// 選択中の蛍光体マスクを返します。mask_type=0なら白を返し、Stage2の他処理だけを残します。
vec3 crt_mask(vec2 screen_px) {
    if (mask_type == 1) {
        return crt_slot_mask(screen_px);
    }
    if (mask_type == 2) {
        return crt_aperture_mask(screen_px);
    }
    if (mask_type == 3) {
        return crt_shadow_mask(screen_px);
    }
    return vec3(1.0);
}

// 軽量角丸マスク。表示領域内は1、角丸外側は0へ滑らかに落とします。
float crt_corner_alpha(vec2 uv) {
    if (corner_radius <= 0.0001) {
        return 1.0;
    }
    vec2 corner_uv = min(uv, 1.0 - uv);
    float min_corner = min(corner_uv.x, corner_uv.y);
    float edge = corner_radius * 0.35;
    return smoothstep(0.0, max(edge, 0.0001), min_corner);
}

void fragment() {
    // ── 画面カーブ: 出力UVからCRT管面の歪んだソースUVへ逆写像します ───────────────
    vec2 centered = UV * 2.0 - 1.0;
    vec2 warped = centered * (1.0 + curve_amount * centered.yx * centered.yx);
    vec2 source_uv = warped * 0.5 + 0.5;
    vec3 plain_rgb = texture(source_texture, clamp(UV, vec2(0.0), vec2(1.0))).rgb;

    // 歪みで画面外を参照するピクセルはベゼル暗部として扱います。
    float inside = step(0.0, source_uv.x) * step(source_uv.x, 1.0) * step(0.0, source_uv.y) * step(source_uv.y, 1.0);
    vec2 sample_uv = clamp(source_uv, vec2(0.0), vec2(1.0));

    // 480i風表示ではフィールドに応じてサンプル位置を半ピクセル上下へ揺らします。
    float field = mod(frame_count, 2.0);
    if (interlace_enabled) {
        sample_uv.y += (field - 0.5) * interlace_bob_px / max(source_size.y, 1.0);
        sample_uv = clamp(sample_uv, vec2(0.0), vec2(1.0));
    }

    // ── 低解像度ソースサンプリング ────────────────────────────────────────────
    vec3 source_rgb = texture(source_texture, sample_uv).rgb;
    vec3 linear_rgb = crt_to_linear(source_rgb);

    // ── 走査線: ソースライン中心からの距離と輝度依存ビーム幅で減光量を作ります ─────
    float src_y = sample_uv.y * source_size.y;
    float line_dist = abs(fract(src_y) - 0.5);
    float luma = dot(source_rgb, CRT_STAGE2_LUMA);
    float beam_width = mix(scanline_width_dark, scanline_width_bright, luma);
    float scan = exp(-(line_dist * line_dist) / max(beam_width, 0.0001));
    float scan_gain = mix(1.0 - scanline_strength, 1.0, scan);
    linear_rgb *= scan_gain;

    // 480i風では、現在フィールドと一致しないソースラインを暗くします。
    if (interlace_enabled) {
        float src_line = floor(sample_uv.y * source_size.y);
        float field_match = 1.0 - abs(mod(src_line, 2.0) - field);
        linear_rgb *= mix(interlace_dim, 1.0, field_match);
    }

    // ── 蛍光体マスク: 最終出力ピクセル基準のscreen_pxで計算します ───────────────
    vec2 screen_px = UV * output_size;
    linear_rgb *= crt_mask(screen_px);

    // ── 明度補償・外周減光・角丸・ベゼル ───────────────────────────────────────
    linear_rgb *= brightness_compensation;
    float edge_dist = min(min(source_uv.x, 1.0 - source_uv.x), min(source_uv.y, 1.0 - source_uv.y));
    float vignette = mix(1.0, smoothstep(0.0, 0.35, edge_dist), vignette_strength);
    float corner = crt_corner_alpha(source_uv);
    float screen_alpha = inside * corner;
    linear_rgb *= vignette * screen_alpha;

    vec3 crt_rgb = crt_from_linear(linear_rgb);
    vec3 bezel_rgb = vec3(0.0);
    crt_rgb = mix(bezel_rgb, crt_rgb, mix(screen_alpha, 1.0, 1.0 - bezel_strength));

    // display_amount=0ではStage1出力をそのまま見せ、1ではStage2効果を全量適用します。
    COLOR = vec4(mix(plain_rgb, crt_rgb, clamp(display_amount, 0.0, 1.0)), 1.0);
}

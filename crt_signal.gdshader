// CRT表現 Stage1（NTSCコンポジット信号経路）用シェーダーです。
// Gemidius BaseState.gd の CRT_SIGNAL_SHADER_CODE からの移植です。
// 設計書: CRT_SHADER_DESIGN_20260711.md §3（Stage1設計）・§7（プリセット）
// 入力: NTSCキャンバスSubViewportの低解像度画像（ViewportTexture）
// 出力: NTSCコンポジット接続の信号劣化（色にじみ・偽色・ドットクロール・ゴースト・ノイズ）を
//       施したRGB画像。走査線・マスク等の「表示側」の劣化はStage2が担当します。
// 処理の流れ（設計書§3.2）
//   1. RGB→YIQ変換（NTSC系色空間。Y=輝度、I/Q=色差）
//   2. サブキャリア位相計算（様式化値 π/3 rad/px、3相ライン位相＋2フレーム周期＋位相ジッター）
//   3. I/Q変調（クロマをサブキャリアへ乗せ、コンポジット信号の「色の縞」を作る）
//   4. 不完全なY/C分離（ノッチフィルタ機近似。ルーマ⇔クロマの相互漏れ＝偽色とにじみ縞）
//   5. Y/I/Q別の水平FIRローパス（帯域制限。クロマ遅延はI/Qのタップ中心をずらして表現）
//   6. 復調（サブキャリア乗算×2でI/Qを取り出す。分離残差が偽色・ドットクロールになる）
//   7. ゴースト（多重反射）・アナログノイズ付加
//   8. YIQ→RGB復元、クランプ、原画とのミックス（signal_amount / rgb_bypass_mix）
shader_type canvas_item;

// ─── 入力uniform（設計書§3.7の一覧に対応。既定値はOFFではなくコンポジットTVプリセット寄り） ───
// 入力テクスチャ。NTSCキャンバスの ViewportTexture を GDScript 側から接続します。
uniform sampler2D source_texture : filter_nearest, repeat_disable;
// 入力解像度（NTSCキャンバスサイズ）。ピクセル座標とUVの相互変換に使います。
uniform vec2 source_size = vec2(320.0, 240.0);
// 60fpsフレーム番号。位相のフレーム項（ドットクロール）とノイズの時間変化に使います。
uniform float frame_count = 0.0;
// Stage1全体の適用量。0で原画そのまま、1で信号劣化を全量適用します。
uniform float signal_amount : hint_range(0.0, 1.0) = 1.0;
// クロスカラー量。ルーマ（輝度の細かい模様）が変調クロマへ漏れて虹色の偽色になる量です。
uniform float composite_artifact : hint_range(0.0, 2.0) = 0.85;
// クロスルミナンス量。変調クロマがルーマへ漏れて色境界にドット状の縞・にじみが出る量です。
uniform float composite_fringing : hint_range(0.0, 2.0) = 0.65;
// 1ソースピクセルあたりのサブキャリア位相角[rad]。様式化値 π/3（にじみ帯が3〜6px幅）です。
uniform float subcarrier_phase_px : hint_range(0.1, 3.14) = 1.047;
// ライン間の位相差[rad]。3相近似では 2π/3（ライン周期3）を使います。
uniform float line_phase_amount : hint_range(0.0, 6.283) = 2.094;
// 位相ジッター強度。ラインごと・フレームごとに位相を微小揺らし、アナログの不安定さを出します。
uniform float phase_jitter : hint_range(0.0, 0.25) = 0.025;
// クロマ（I/Q）の水平遅れ[px]。色が輪郭より右へずれる「色ずれ」を作ります。
uniform float chroma_delay_px : hint_range(-8.0, 8.0) = 1.25;
// Y（輝度）ローパスFIRの半径[px]。NTSCのY約4.2MHz相当の水平ぼけ近似です。
uniform float y_band_px : hint_range(0.5, 5.0) = 1.25;
// I（橙-シアン色差）ローパスFIRの半径[px]。NTSCのI約1.3MHz相当です。
uniform float i_band_px : hint_range(1.0, 9.0) = 2.75;
// Q（紫-黄緑色差）ローパスFIRの半径[px]。NTSCのQ約0.4-0.6MHz相当で最もぼけます。
uniform float q_band_px : hint_range(1.0, 12.0) = 4.25;
// ゴースト（多重反射）の強さ。アンテナ線の反射で映像が右へ薄く二重写りする現象の近似です。
uniform float ghost_strength : hint_range(0.0, 0.5) = 0.09;
// ゴーストの反射距離[px]。1次ゴーストの水平オフセットです（2次はこの2倍の距離）。
uniform float ghost_offset_px : hint_range(0.0, 32.0) = 6.0;
// 輝度ノイズ量。画面全体の細かい明滅（スノーノイズの弱いもの）です。
uniform float noise_luma : hint_range(0.0, 0.1) = 0.012;
// 色ノイズ量。I/Qへ乗る色のちらつきです。
uniform float noise_chroma : hint_range(0.0, 0.1) = 0.018;
// RGB接続モード用の信号バイパス率。1に近いほどStage1を素通しに近づけます（コンポジットTVでは0）。
uniform float rgb_bypass_mix : hint_range(0.0, 1.0) = 0.0;
// RF追加効果の全体量。0なら従来のコンポジット表現だけを残します。
uniform float rf_amount : hint_range(0.0, 1.0) = 0.20;
// 水平同期PLLの追従残差を模したライン単位の横揺れ[ソースpx]です。
uniform float sync_jitter_px : hint_range(0.0, 4.0) = 0.18;
// RF離調量。サブキャリア位相へ画面内傾斜と時間ドリフトを加えます。
uniform float rf_tuning_error : hint_range(-1.0, 1.0) = 0.08;
// カラーバースト位相ロックの残差。ライン単位の色相揺れになります。
uniform float burst_phase_noise : hint_range(0.0, 0.5) = 0.03;
// RF受信由来の細粒ノイズと白いインパルスノイズの量です。
uniform float rf_snow : hint_range(0.0, 0.25) = 0.015;
// AGC追従残差を模した低周波の信号振幅揺れです。
uniform float rf_gain_wobble : hint_range(0.0, 0.25) = 0.015;
// 復調後の色相補正[degree]。実機RFデコーダのhue trimに対応します。
uniform float hue_deg : hint_range(-45.0, 45.0) = 0.0;
// 復調後の彩度補正。0でモノクロ、1で等倍です。
uniform float saturation : hint_range(0.0, 2.0) = 1.0;

// ─── 定数 ───────────────────────────────────────────────────────────────────
// 円周率2π。Godotシェーダー言語に組み込み定数PIは無いため自前で定義します。
const float CRT_TAU = 6.2831853071795865;
// 水平FIRの固定半径[タップ]。半径8で17タップ（設計書§8.1の標準設定相当）。
// 動的配列は使わず、ループ回数はコンパイル時固定にします。
const int CRT_FIR_RADIUS = 8;
// RGB→YIQ変換行列（設計書§2.1の近似行列。mat3は列優先なので行列の「列」を並べています）。
// Y =  0.2989R + 0.5870G + 0.1140B / I = 0.5959R - 0.2744G - 0.3216B / Q = 0.2115R - 0.5229G + 0.3114B
const mat3 CRT_RGB_TO_YIQ = mat3(
    vec3(0.2989, 0.5959, 0.2115),
    vec3(0.5870, -0.2744, -0.5229),
    vec3(0.1140, -0.3216, 0.3114));
// YIQ→RGB逆変換行列（同§2.1）。
// R = Y + 0.956I + 0.621Q / G = Y - 0.272I - 0.647Q / B = Y - 1.106I + 1.705Q
const mat3 CRT_YIQ_TO_RGB = mat3(
    vec3(1.0, 1.0, 1.0),
    vec3(0.956, -0.272, -1.106),
    vec3(0.621, -0.647, 1.705));
// 輝度計算用のBT.601係数。エッジ検出とノイズの基準輝度に使います。
const vec3 CRT_LUMA_WEIGHT = vec3(0.2989, 0.5870, 0.1140);

// ─── 補助関数 ────────────────────────────────────────────────────────────────
// 3次元入力の擬似乱数ハッシュ（0.0〜1.0）。ノイズと位相ジッターの乱数源です。
// テクスチャ参照を増やさない算術ハッシュ（よく使われるfract-dot方式）を採用します。
float crt_hash(vec3 p) {
    p = fract(p * vec3(0.1031, 0.1030, 0.0973));
    p += dot(p, p.yzx + 33.33);
    return fract((p.x + p.y) * p.z);
}

// ガウス窓の重み。distance_px=タップ中心からの距離[px]、radius_px=帯域半径[px]（σとして使用）。
// 帯域半径が大きいほど広くぼける＝帯域が狭い（低周波しか通らない）ことに対応します。
float crt_gaussian_weight(float distance_px, float radius_px) {
    float sigma = max(radius_px, 0.0001);
    return exp(-(distance_px * distance_px) / (2.0 * sigma * sigma));
}

// 指定ソースピクセル位置でのNTSCサブキャリア位相[rad]を返します（設計書§3.3）。
// ・X項: 1pxあたり subcarrier_phase_px（様式化値 π/3 = 6pxで1周期）
// ・ライン項: 3相近似。ライン番号 mod 3 に line_phase_amount(2π/3) を掛け、走査線ごとに位相を回す
// ・フレーム項: 2フレーム周期で位相を進め、静止画でも色縞が揺れる「ドットクロール」を作る
//   （ntsc-adaptive実装と同じく係数はライン項と共通の line_phase_amount を使用）
// ・ジッター項: ライン×フレーム単位の乱数で±(phase_jitter×2π)/2 の範囲を揺らす
float crt_subcarrier_phase(float pixel_x, float pixel_y, float frame_index) {
    float line_index = floor(pixel_y);
    float line_phase = line_phase_amount * mod(line_index, 3.0);
    float frame_phase = line_phase_amount * mod(frame_index, 2.0);
    float jitter = (crt_hash(vec3(line_index, frame_index, 17.0)) - 0.5) * phase_jitter * CRT_TAU;
    // 実RFデコーダのカラーバースト位相ロックと離調残差を、ライン位相の追加誤差として近似します。
    float burst_error = (crt_hash(vec3(line_index, floor(frame_index * 0.25), 71.0)) - 0.5) * burst_phase_noise * CRT_TAU;
    float tuning_drift = rf_tuning_error * ((pixel_x / max(source_size.x, 1.0)) + frame_index * 0.006) * CRT_TAU;
    return pixel_x * subcarrier_phase_px + line_phase + frame_phase + jitter + rf_amount * (burst_error + tuning_drift);
}

void fragment() {
    // 完全バイパス時は17タップFIRを含む信号処理を実行しません。
    if (signal_amount <= 0.0001 || rgb_bypass_mix >= 0.9999) {
        COLOR = texture(source_texture, UV);
    } else {
    // ── 前準備: ピクセル座標・原画・1texelのUV幅 ──────────────────────────────
    // 水平同期PLLの残差は、ラインごとの緩い揺れと更新の遅い乱数を合成して表現します。
    float source_line = floor(UV.y * source_size.y);
    float sync_slow = sin(source_line * 0.093 + frame_count * 0.018);
    float sync_noise = crt_hash(vec3(source_line, floor(frame_count * 0.25), 41.0)) - 0.5;
    float sync_offset = rf_amount * sync_jitter_px * (sync_slow * 0.65 + sync_noise * 0.70) / max(source_size.x, 1.0);
    vec2 signal_uv = clamp(UV + vec2(sync_offset, 0.0), vec2(0.0), vec2(1.0));
    // UV(0..1)をソースピクセル座標へ変換します。位相計算はピクセル単位で行います。
    vec2 src_px = signal_uv * source_size;
    // 原画RGB。最終段の signal_amount / rgb_bypass_mix ミックスの「劣化なし側」です。
    vec3 source_rgb = texture(source_texture, UV).rgb;
    // 1ソースピクセルぶんのUV幅。タップやゴーストのオフセット計算に使います。
    vec2 texel = vec2(1.0) / source_size;

    // ── エッジ係数（設計書§3.5）: 左右1pxの輝度差から作り、輝度境界だけ偽色を強めます ──
    // 平坦部でルーマがクロマへ漏れ続けると画面全体が色づくため、境界に限定するゲートです。
    float luma_left = dot(texture(source_texture, signal_uv - vec2(texel.x, 0.0)).rgb, CRT_LUMA_WEIGHT);
    float luma_right = dot(texture(source_texture, signal_uv + vec2(texel.x, 0.0)).rgb, CRT_LUMA_WEIGHT);
    float edge_factor = clamp(abs(luma_right - luma_left) * 4.0, 0.0, 1.0);
    // ルーマ→クロマ漏れ（クロスカラー/偽色）の実効ゲイン。
    float artifact_gain = composite_artifact * edge_factor;

    // ── 変調→混合→帯域制限FIR→復調（設計書§3.3〜§3.5、ntsc-adaptive pass1/2の一体化） ──
    // 各タップで「コンポジット信号の合成（変調＋Y/C相互漏れ）」と「復調（キャリア再乗算）」を行い、
    // Y/I/Q別のガウス重みで水平に積分します。I/Qの重み中心を chroma_delay_px ずらすことで
    // クロマ遅延（色ずれ）を同じループ内で表現します（追加フェッチなし）。
    vec3 accum_yiq = vec3(0.0);
    vec3 weight_sum = vec3(0.0);
    for (int tap = -CRT_FIR_RADIUS; tap <= CRT_FIR_RADIUS; tap++) {
        float tap_offset = float(tap);
        // タップ位置のUV。repeat_disableにより画面端はエッジクランプされます。
        vec2 tap_uv = signal_uv + vec2(tap_offset * texel.x, 0.0);
        // タップ位置のRGBをYIQへ変換します。
        vec3 tap_yiq = CRT_RGB_TO_YIQ * texture(source_texture, tap_uv).rgb;
        // タップ位置でのサブキャリア位相と、そのcos/sinキャリアです。
        float tap_phase = crt_subcarrier_phase(src_px.x + tap_offset, src_px.y, frame_count);
        float carrier_cos = cos(tap_phase);
        float carrier_sin = sin(tap_phase);
        // I/Q変調: クロマをキャリアに乗せた「コンポジット信号のクロマ成分」です。
        float chroma_mod = tap_yiq.y * carrier_cos + tap_yiq.z * carrier_sin;
        // 不完全なY/C分離（ノッチフィルタ機近似）:
        // ・ルーマ側には変調クロマが composite_fringing の割合で残留 → 色境界のドット縞・にじみ
        float composite_luma = tap_yiq.x + chroma_mod * composite_fringing;
        // ・クロマ復調入力にはルーマが artifact_gain の割合で混入 → 細かい模様が虹色の偽色に
        float composite_chroma = chroma_mod + tap_yiq.x * artifact_gain;
        // Y/I/Q別のガウス重み（I/Qは chroma_delay_px だけ重み中心を右へずらす）。
        vec3 tap_weight = vec3(
            crt_gaussian_weight(tap_offset, y_band_px),
            crt_gaussian_weight(tap_offset - chroma_delay_px, i_band_px),
            crt_gaussian_weight(tap_offset - chroma_delay_px, q_band_px));
        // 復調: キャリアcos/sinを再度掛けて2倍すると、I/Q成分が直流側へ戻ります
        // （2cos²=1+cos2φ の直流項）。残った2倍周波数のリップルと分離残差が
        //  FIRで取り切れずに残ることこそが、コンポジット特有の画質劣化の正体です。
        accum_yiq += vec3(
            composite_luma,
            composite_chroma * 2.0 * carrier_cos,
            composite_chroma * 2.0 * carrier_sin) * tap_weight;
        weight_sum += tap_weight;
    }
    // 重み合計で正規化し、帯域制限済みのYIQ信号を得ます（ゼロ除算はmaxで防止）。
    vec3 yiq_signal = accum_yiq / max(weight_sum, vec3(0.0001));

    // ── アナログノイズ（設計書§3.6）: ピクセル×フレームの乱数をY/I/Qへ加算します ──
    // 乱数入力の第3成分をずらして、Y/I/Qそれぞれ独立したノイズパターンにします。
    yiq_signal.x += (crt_hash(vec3(src_px, frame_count)) - 0.5) * noise_luma;
    yiq_signal.y += (crt_hash(vec3(src_px, frame_count + 61.0)) - 0.5) * noise_chroma;
    yiq_signal.z += (crt_hash(vec3(src_px, frame_count + 123.0)) - 0.5) * noise_chroma;

    // RFのAGC追従残差。フレームとラインにまたがる低周波成分だけを使い、激しい点滅を避けます。
    float gain_wave = sin(frame_count * 0.037 + source_line * 0.013) * 0.65
        + (crt_hash(vec3(floor(frame_count * 0.125), source_line * 0.031, 93.0)) - 0.5) * 0.35;
    yiq_signal *= 1.0 + rf_amount * rf_gain_wobble * gain_wave;

    // 実RFデコーダと同じく復調後の色相・彩度をI/Q平面で調整します。
    float hue_angle = hue_deg * CRT_TAU / 360.0;
    float hue_cos = cos(hue_angle);
    float hue_sin = sin(hue_angle);
    vec2 rotated_iq = vec2(
        yiq_signal.y * hue_cos - yiq_signal.z * hue_sin,
        yiq_signal.y * hue_sin + yiq_signal.z * hue_cos) * saturation;
    yiq_signal.y = rotated_iq.x;
    yiq_signal.z = rotated_iq.y;

    // RFスノーは細粒ノイズに、低頻度の白いインパルスを重ねます。
    float snow_hash = crt_hash(vec3(src_px * vec2(1.7, 2.3), frame_count + 211.0));
    float snow_impulse = max((snow_hash - 0.985) / 0.015, 0.0);
    yiq_signal.x += rf_amount * rf_snow * ((snow_hash - 0.5) * 0.35 + snow_impulse * 1.2);
    yiq_signal.y += rf_amount * rf_snow * snow_impulse * 0.20;
    yiq_signal.z -= rf_amount * rf_snow * snow_impulse * 0.15;

    // ── YIQ→RGB復元 ─────────────────────────────────────────────────────────
    vec3 ntsc_rgb = CRT_YIQ_TO_RGB * yiq_signal;

    // ── ゴースト（設計書§3.6）: 原画を右へずらした薄い像を2段重ね、輝度正規化します ──
    // ghost_strength=0 のときはフェッチ自体を分岐で省きます（設計書§8.2の負荷逃げ道5）。
    if (ghost_strength > 0.0001) {
        vec2 ghost_uv_offset = vec2(ghost_offset_px * texel.x, 0.0);
        ntsc_rgb += texture(source_texture, signal_uv - ghost_uv_offset).rgb * ghost_strength;
        ntsc_rgb += texture(source_texture, signal_uv - ghost_uv_offset * 2.0).rgb * ghost_strength * 0.35;
        ntsc_rgb /= 1.0 + ghost_strength * 1.35;
    }

    // ── クランプと最終ミックス（設計書§3.2の clamp/gamma return） ─────────────────
    // ガンマ処理はStage2で行うため、ここでは範囲クランプのみ行います。
    ntsc_rgb = clamp(ntsc_rgb, vec3(0.0), vec3(1.0));
    // signal_amount=全体量、rgb_bypass_mix=RGB接続プリセット用の素通し率。
    // どちらも「原画へ寄せる」方向で合成し、0/1の組で完全バイパス〜全量適用を表します。
    float ntsc_mix = clamp(signal_amount * (1.0 - rgb_bypass_mix), 0.0, 1.0);
    COLOR = vec4(mix(source_rgb, ntsc_rgb, ntsc_mix), 1.0);
    }
}

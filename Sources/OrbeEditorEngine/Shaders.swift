/// シェーダのソース。描画スレッドが最初に要る前に、実行時にコンパイルする（ビルド手順と同梱物を増やさない）。
///
/// 色は sRGB の値のまま、乗算済みアルファで合成する（線形にしない）。Core Text の字の縁の濃さと揃える。
enum Shaders {
  static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct Glyph { float2 position; float2 size; float2 uv; uint color; uint pad; };
    struct GlyphOut { float4 position [[position]]; float2 uv; float4 color; };

    vertex GlyphOut glyph_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                                 const device Glyph* glyphs [[buffer(0)]],
                                 constant float2& viewport [[buffer(1)]]) {
      Glyph g = glyphs[iid];
      float2 corner = float2(vid & 1, vid >> 1);
      float2 px = g.position + corner * g.size;
      GlyphOut out;
      out.position = float4(px.x / viewport.x * 2 - 1, 1 - px.y / viewport.y * 2, 0, 1);
      out.uv = g.uv + corner * g.size;
      out.color = unpack_unorm4x8_to_float(g.color);
      return out;
    }

    fragment float4 mono_fragment(GlyphOut in [[stage_in]], texture2d<float> atlas [[texture(0)]]) {
      constexpr sampler s(coord::pixel, filter::nearest);
      float a = atlas.sample(s, in.uv).r * in.color.a;
      return float4(in.color.rgb * a, a);
    }

    fragment float4 color_fragment(GlyphOut in [[stage_in]], texture2d<float> atlas [[texture(0)]]) {
      constexpr sampler s(coord::pixel, filter::nearest);
      return atlas.sample(s, in.uv) * in.color.a;
    }

    // 画面外に描いた 1 枚を、組の不透明度で重ねる（不透明度は 8bit に丸めない）。
    fragment float4 layer_fragment(GlyphOut in [[stage_in]], texture2d<float> layer [[texture(0)]],
                                   constant float& opacity [[buffer(0)]]) {
      constexpr sampler s(coord::pixel, filter::nearest);
      return layer.sample(s, in.uv) * opacity;
    }

    struct Shape { float4 rect; uint color; float radius; uint kind; uint pad; };
    struct ShapeOut {
      float4 position [[position]];
      float2 local;
      float2 size;
      float radius;
      uint kind [[flat]];
      float4 color;
    };

    vertex ShapeOut shape_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                                 const device Shape* shapes [[buffer(0)]],
                                 constant float2& viewport [[buffer(1)]]) {
      Shape s = shapes[iid];
      float2 corner = float2(vid & 1, vid >> 1);
      float2 px = s.rect.xy + corner * s.rect.zw;
      ShapeOut out;
      out.position = float4(px.x / viewport.x * 2 - 1, 1 - px.y / viewport.y * 2, 0, 1);
      out.local = corner * s.rect.zw;
      out.size = s.rect.zw;
      out.radius = s.radius;
      out.kind = s.kind;
      out.color = unpack_unorm4x8_to_float(s.color);
      return out;
    }

    // kind 0: 角の丸い矩形。kind 1: 右向きの三角（左辺が底辺）。
    fragment float4 shape_fragment(ShapeOut in [[stage_in]]) {
      float d;
      if (in.kind == 0) {
        float2 q = abs(in.local - in.size * 0.5) - in.size * 0.5 + in.radius;
        d = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - in.radius;
      } else {
        float2 p = in.local;
        float half_h = in.size.y * 0.5;
        float slope = in.size.x / half_h;
        float edge = (abs(p.y - half_h) * slope + p.x - in.size.x) / sqrt(1.0 + slope * slope);
        d = max(edge, -p.x);
      }
      float a = clamp(0.5 - d, 0.0, 1.0) * in.color.a;
      return float4(in.color.rgb * a, a);
    }

    // ミニマップの字: 字形の表の明度 × 明るさの係数（切り捨て）を α にした役割の色、全体に不透明度。
    struct MinimapCell { uint packed; uint role; };
    struct MinimapUniforms { float2 origin; float2 cell; float2 glyph; float ratio; float opacity; };
    struct MinimapOut { float4 position [[position]]; float2 uv; uint role [[flat]]; };

    vertex MinimapOut minimap_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                                     const device MinimapCell* cells [[buffer(0)]],
                                     constant float2& viewport [[buffer(1)]],
                                     constant MinimapUniforms& u [[buffer(2)]]) {
      MinimapCell c = cells[iid];
      float2 corner = float2(vid & 1, vid >> 1);
      float2 at = float2(float(c.packed & 0xFFFFu), float((c.packed >> 16) & 0xFFu));
      float2 px = u.origin + (at + corner) * u.cell;
      MinimapOut out;
      out.position = float4(px.x / viewport.x * 2 - 1, 1 - px.y / viewport.y * 2, 0, 1);
      out.uv = float2(float(c.packed >> 24) * u.glyph.x, 0) + corner * u.glyph;
      out.role = c.role;
      return out;
    }

    fragment float4 minimap_fragment(MinimapOut in [[stage_in]], texture2d<float> sheet [[texture(0)]],
                                     constant MinimapUniforms& u [[buffer(0)]],
                                     constant uint* colors [[buffer(1)]]) {
      constexpr sampler s(coord::pixel, filter::nearest);
      float value = round(sheet.sample(s, in.uv).r * 255.0);
      float a = floor(value * u.ratio + 0.001);
      float4 color = unpack_unorm4x8_to_float(colors[in.role]);
      // 字を 8bit の乗算済みの絵に合成してから（色 × α を切り捨て）不透明度を掛ける段で丸める。
      float4 premultiplied = float4(floor(color.rgb * a + 0.001), a);
      return round(premultiplied * u.opacity) / 255.0;
    }
    """
}

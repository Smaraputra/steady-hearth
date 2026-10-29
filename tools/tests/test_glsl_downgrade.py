import os
import sys
import unittest

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
if REPO_ROOT not in sys.path:
    sys.path.insert(0, REPO_ROOT)

from tools.make_mac_gl_compat import (
    convert_shader_text,
    convert_section,
    convert_glsl_text,
    check_unsupported_constructs,
)


class TestGLSLDowngrade(unittest.TestCase):
    def test_vertex_section(self):
        input_code = (
            "#version 410\n"
            "in vec3 vertPos;\n"
            "out vec4 color;\n"
            "void main() {\n"
            "    gl_Position = vec4(vertPos, 1.0);\n"
            "    color = vec4(1.0);\n"
            "}\n"
        )
        converted, _ = convert_section("[[VS]]", input_code)
        self.assertIn("#version 120", converted)
        self.assertNotIn("#version 410", converted)
        self.assertIn("attribute vec3 vertPos;", converted)
        self.assertNotIn("in vec3 vertPos;", converted)
        self.assertIn("varying vec4 color;", converted)
        self.assertNotIn("out vec4 color;", converted)

    def test_fragment_section_single_output(self):
        input_code = (
            "#version 410\n"
            "out vec4 fragColor;\n"
            "in vec4 color;\n"
            "void main() {\n"
            "    fragColor = color;\n"
            "}\n"
        )
        converted, _ = convert_section("[[FS]]", input_code)
        self.assertIn("#version 120", converted)
        self.assertNotIn("out vec4 fragColor;", converted)
        self.assertIn("varying vec4 color;", converted)
        self.assertNotIn("in vec4 color;", converted)
        self.assertIn("gl_FragColor = color;", converted)
        self.assertNotIn("fragColor = color;", converted)

    def test_fragment_section_multiple_outputs_with_location(self):
        input_code = (
            "#version 410\n"
            "layout(location = 0) out vec4 fragData_0;\n"
            "layout(location = 1) out vec4 fragData_1;\n"
            "void main() {\n"
            "    fragData_0 = vec4(1.0);\n"
            "    fragData_1 = vec4(0.0);\n"
            "}\n"
        )
        converted, _ = convert_section("[[FS]]", input_code)
        self.assertNotIn("fragData_0;", converted)
        self.assertNotIn("fragData_1;", converted)
        self.assertIn("gl_FragData[0] = vec4(1.0);", converted)
        self.assertIn("gl_FragData[1] = vec4(0.0);", converted)

    def test_texture_resolution_by_sampler_type(self):
        input_code = (
            "uniform sampler3D lut;\n"
            "uniform sampler2D albedo;\n"
            "vec4 sampleTex(sampler2D tex, vec2 uv) {\n"
            "    return texture(tex, uv);\n"
            "}\n"
            "void main() {\n"
            "    vec4 a = texture(lut, vec3(0.5));\n"
            "    vec4 b = texture(albedo, vec2(0.5));\n"
            "}\n"
        )
        converted, _ = convert_section("[[FS]]", input_code)
        self.assertIn("texture3D(lut,", converted)
        self.assertIn("texture2D(albedo,", converted)
        self.assertIn("texture2D(tex,", converted)

    def test_shadow_sampler_and_texture_proj(self):
        input_code = (
            "uniform sampler2DShadow shadowMap;\n"
            "uniform sampler2D albedo;\n"
            "uniform samplerCube cubeShadow;\n"
            "float f(vec4 projCoords, vec3 dir) {\n"
            "    float a = textureProj(shadowMap, projCoords);\n"
            "    float b = texture(shadowMap, projCoords.xyz);\n"
            "    vec4 c = textureProj(albedo, projCoords);\n"
            "    float d = texture(cubeShadow, dir).r;\n"
            "    return a + b + c.r + d;\n"
            "}\n"
        )
        converted, _, _ = convert_glsl_text(input_code, stage="fragment")
        self.assertIn("shadow2DProj(shadowMap, projCoords).r;", converted)
        self.assertIn("shadow2D(shadowMap, projCoords.xyz).r;", converted)
        self.assertIn("texture2DProj(albedo, projCoords);", converted)
        self.assertIn("textureCube(cubeShadow, dir).r;", converted)
        self.assertNotIn("textureProj(", converted)

    def test_fx_section_unchanged(self):
        fx_code = (
            "sampler2D buf0 = sampler_state\n"
            "{\n"
            "  Address = Clamp;\n"
            "  Filter = None;\n"
            "};\n"
        )
        converted, _ = convert_section("[[FX]]", fx_code)
        self.assertEqual(converted, fx_code)

    def test_whole_word_check(self):
        input_code = (
            "#version 410\n"
            "out vec4 fragColor;\n"
            "void main() {\n"
            "    float fragColorScale = 1.0;\n"
            "    fragColor = vec4(fragColorScale);\n"
            "}\n"
        )
        converted, _ = convert_section("[[FS]]", input_code)
        self.assertIn("float fragColorScale = 1.0;", converted)
        self.assertIn("gl_FragColor = vec4(fragColorScale);", converted)
        self.assertNotIn("gl_FragColorScale", converted)

    def test_unsupported_constructs_texel_fetch(self):
        input_code = (
            "void main() {\n"
            "    vec4 c = texelFetch(depthBuffer, ivec2(0, 0), 0);\n"
            "}\n"
        )
        issues = check_unsupported_constructs(input_code, filename="test.glsl")
        self.assertTrue(any(issue[2] == "texelFetch" for issue in issues))

    def test_texture_lod_stages(self):
        vs_code = (
            "uniform sampler2D tex;\n"
            "void main() {\n"
            "    vec4 c = textureLod(tex, vec2(0.0), 0.0);\n"
            "}\n"
        )
        converted_vs, _ = convert_section("[[VS]]", vs_code)
        self.assertIn("texture2DLod(tex, vec2(0.0), 0.0)", converted_vs)

        fs_code = (
            "uniform sampler2D areaTex;\n"
            "void main() {\n"
            "    vec2 c = textureLod(areaTex, texcoord, 0.0).rg;\n"
            "}\n"
        )
        converted_fs, _ = convert_section("[[FS]]", fs_code)
        self.assertIn("texture2D(areaTex, texcoord).rg", converted_fs)


    def test_generated_mod_verification(self):
        mod_dir = os.path.join(REPO_ROOT, "mods", "mac_gl_compat")
        manifest_path = os.path.join(mod_dir, "manifest.json")
        if not os.path.isfile(manifest_path):
            self.skipTest("Generated mod directory not present yet")

        import json
        with open(manifest_path, "r", encoding="utf-8") as fh:
            data = json.load(fh)
            self.assertEqual(data["info"]["namespace"], "mac_gl_compat")
            self.assertIn("overrides", data)
            self.assertGreaterEqual(len(data["overrides"]), 60)

        # Check that no file contains "#version 4"
        version_4_files = []
        for root, _, files in os.walk(mod_dir):
            for f in files:
                if f.endswith((".shader", ".glsl")):
                    p = os.path.join(root, f)
                    with open(p, "r", encoding="utf-8", errors="replace") as fh:
                        if "#version 4" in fh.read():
                            version_4_files.append(p)
        self.assertEqual(version_4_files, [])


if __name__ == "__main__":
    unittest.main()

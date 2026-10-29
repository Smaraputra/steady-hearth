#!/usr/bin/env python3
"""
tools/make_mac_gl_compat.py

GLSL 4.10 to 1.20 converter that generates a harness-only "mac_gl_compat" mod.
Converts shaders shipped with Stonehearth ACE to compile under macOS / Wine
legacy OpenGL 2.1 (GLSL 1.20).
"""

import argparse
import json
import os
import re
import sys
import zipfile
from collections import defaultdict


def mask_comments(code: str) -> tuple[str, list[str]]:
    """
    Mask single-line and multi-line comments with placeholders.
    Preserves newlines to maintain line number mapping.
    """
    comments = []

    def repl(m):
        c = m.group(0)
        idx = len(comments)
        comments.append(c)
        return f"__COMMENT_TOKEN_{idx}__" + ("\n" * c.count("\n"))

    masked = re.sub(r'//[^\n]*|/\*[\s\S]*?\*/', repl, code)
    return masked, comments


def unmask_comments(masked: str, comments: list[str]) -> str:
    """Restore comments from placeholders."""
    for idx, c in enumerate(comments):
        token_prefix = f"__COMMENT_TOKEN_{idx}__"
        padding = "\n" * c.count("\n")
        masked = masked.replace(token_prefix + padding, c)
        if token_prefix in masked:
            masked = masked.replace(token_prefix, c)
    return masked


def check_unsupported_constructs(code: str, filename: str = "") -> list[tuple[str, int, str, str]]:
    """
    Check for constructs with no GLSL 1.20 equivalent:
    texelFetch, textureSize, <<, >>, integer %, flat, uint.
    Returns list of (filename, line_number, construct_name, line_text).
    """
    masked, _ = mask_comments(code)
    lines_masked = masked.split("\n")
    lines_orig = code.split("\n")
    issues = []

    unsupported = [
        ("texelFetch", re.compile(r'\btexelFetch\b')),
        ("textureSize", re.compile(r'\btextureSize\b')),
        ("<<", re.compile(r'<<')),
        (">>", re.compile(r'>>')),
        ("integer %", re.compile(r'%')),
        ("flat", re.compile(r'\bflat\b')),
        ("uint", re.compile(r'\buint\b')),
    ]

    for line_idx, (m_line, orig_line) in enumerate(zip(lines_masked, lines_orig), start=1):
        clean_line = re.sub(r'__COMMENT_TOKEN_\d+__', '', m_line).strip()
        if not clean_line:
            continue
        for name, pat in unsupported:
            if pat.search(clean_line):
                issues.append((filename, line_idx, name, orig_line.strip()))
    return issues


def parse_call_args(text: str, open_paren_idx: int) -> tuple[list[str], int]:
    """
    Parse argument strings from balanced parentheses starting at open_paren_idx.
    Returns (args_list, end_idx) where end_idx is index immediately after ')'.
    """
    args = []
    depth = 0
    current_arg = []
    i = open_paren_idx
    while i < len(text):
        ch = text[i]
        if ch == '(':
            if depth > 0:
                current_arg.append(ch)
            depth += 1
        elif ch == ')':
            depth -= 1
            if depth == 0:
                args.append(''.join(current_arg))
                return args, i + 1
            else:
                current_arg.append(ch)
        elif ch == ',' and depth == 1:
            args.append(''.join(current_arg))
            current_arg = []
        else:
            current_arg.append(ch)
        i += 1
    return args, i


def collect_sampler_declarations(code: str) -> dict[str, str]:
    """
    Find sampler declarations in code:
    e.g. uniform samplerXX name; or samplerXX name = sampler_state or function param samplerXX name.
    """
    samplers = {}
    decl_pattern = re.compile(r'\b(sampler[A-Za-z0-9_]+)\s+([A-Za-z0-9_]+)\b')
    for m in decl_pattern.finditer(code):
        stype = m.group(1)
        sname = m.group(2)
        samplers[sname] = stype
    return samplers


def replace_texture_calls(code: str, sampler_types: dict[str, str], stage: str) -> tuple[str, int]:
    """
    Replace texture( and textureLod( calls according to stage and sampler types.
    """
    count = 0

    # 1. textureLod
    if stage == "vertex":
        def repl_vs_lod(m):
            nonlocal count
            count += 1
            return "texture2DLod("
        code = re.sub(r'\btextureLod\s*\(', repl_vs_lod, code)
    elif stage == "fragment":
        # In fragment stage, textureLod becomes texture2D with last argument dropped
        while True:
            m = re.search(r'\btextureLod\s*\(', code)
            if not m:
                break
            start_pos = m.start()
            paren_start = m.end() - 1
            args, end_pos = parse_call_args(code, paren_start)
            if not args:
                code = code[:start_pos] + "texture2D(" + code[paren_start + 1:]
                count += 1
                continue
            count += 1
            remaining_args = [a.strip() for a in args[:-1]]
            new_call = "texture2D(" + ", ".join(remaining_args) + ")"
            code = code[:start_pos] + new_call + code[end_pos:]

    # 2. texture( and textureProj(. GLSL 1.20 shadow lookups return vec4, so shadow-sampler
    # calls get a trailing .r to keep the float result of the GLSL 1.30+ overloads.
    while True:
        m = re.search(r'\btexture(Proj)?\s*\(', code)
        if not m:
            break
        is_proj = m.group(1) is not None
        start_pos = m.start()
        paren_start = m.end() - 1
        args, end_pos = parse_call_args(code, paren_start)
        first_arg = args[0].strip() if args else ""
        ident_m = re.search(r'[A-Za-z_][A-Za-z0-9_]*', first_arg)
        ident = ident_m.group(0) if ident_m else first_arg
        stype = sampler_types.get(ident, "sampler2D")
        suffix = ""
        if stype == "sampler2DShadow":
            func_name = "shadow2DProj" if is_proj else "shadow2D"
            suffix = ".r"
        elif stype == "sampler3D":
            func_name = "texture3DProj" if is_proj else "texture3D"
        elif stype == "samplerCube":
            func_name = "textureCube"
        else:
            func_name = "texture2DProj" if is_proj else "texture2D"
        count += 1
        if suffix and args:
            code = code[:start_pos] + func_name + code[paren_start:end_pos] + suffix + code[end_pos:]
        else:
            code = code[:start_pos] + func_name + code[paren_start:]

    return code, count


def convert_glsl_stage_content(
    code: str,
    stage: str,
    filename: str = "",
    sampler_types: dict[str, str] = None,
) -> tuple[str, dict[str, int], list[tuple[str, int, str, str]]]:
    """
    Convert GLSL code for a specific stage ('vertex', 'fragment', or 'both').
    """
    if sampler_types is None:
        sampler_types = {}

    local_samplers = dict(sampler_types)
    local_samplers.update(collect_sampler_declarations(code))

    rules_applied = {
        "rule_1_version": 0,
        "rule_2_layout": 0,
        "rule_3_vertex_qualifiers": 0,
        "rule_4_fragment_outputs": 0,
        "rule_5_textures": 0,
    }

    issues = check_unsupported_constructs(code, filename)

    masked_code, comments = mask_comments(code)

    # Rule 1: #version downgrade
    def repl_version(m):
        rules_applied["rule_1_version"] += 1
        return "#version 120"

    masked_code = re.sub(r'^[ \t]*#[ \t]*version[ \t]+[34]\d\d[^\n]*', repl_version, masked_code, flags=re.MULTILINE)

    # Stages:
    if stage == "vertex":
        # Rule 2: Strip layout(...)
        def repl_layout(m):
            rules_applied["rule_2_layout"] += 1
            return ""

        masked_code = re.sub(r'layout\s*\([^)]*\)\s*', repl_layout, masked_code)

        # Rule 3: in -> attribute, out -> varying
        def repl_in(m):
            rules_applied["rule_3_vertex_qualifiers"] += 1
            return m.group(1) + "attribute "

        masked_code = re.sub(r'(^[ \t]*)in\s+', repl_in, masked_code, flags=re.MULTILINE)

        def repl_out(m):
            rules_applied["rule_3_vertex_qualifiers"] += 1
            return m.group(1) + "varying "

        masked_code = re.sub(r'(^[ \t]*)out\s+', repl_out, masked_code, flags=re.MULTILINE)

    elif stage == "fragment":
        # Rule 4: Fragment outputs
        out_pattern = re.compile(
            r'^[ \t]*(?:layout\s*\(([^)]*)\)\s*)?out\s+([A-Za-z0-9_]+)\s+([A-Za-z0-9_]+)\s*;[^\n]*\n?',
            re.MULTILINE,
        )

        outputs = []
        for m in out_pattern.finditer(masked_code):
            layout_inner = m.group(1)
            loc = None
            if layout_inner:
                rules_applied["rule_2_layout"] += 1
                loc_m = re.search(r'location\s*=\s*(\d+)', layout_inner)
                if loc_m:
                    loc = int(loc_m.group(1))
            out_name = m.group(3)
            outputs.append({
                "name": out_name,
                "location": loc,
                "match_str": m.group(0),
            })

        # Remove declarations
        for out_info in outputs:
            rules_applied["rule_4_fragment_outputs"] += 1
            masked_code = masked_code.replace(out_info["match_str"], "")

        # Target replacements
        if len(outputs) == 1 and outputs[0]["location"] is None:
            name = outputs[0]["name"]
            masked_code, nsub = re.subn(r'\b' + re.escape(name) + r'\b', 'gl_FragColor', masked_code)
            rules_applied["rule_4_fragment_outputs"] += nsub
        elif len(outputs) > 0:
            for idx, out_info in enumerate(outputs):
                loc = out_info["location"] if out_info["location"] is not None else idx
                target = f"gl_FragData[{loc}]"
                masked_code, nsub = re.subn(r'\b' + re.escape(out_info["name"]) + r'\b', target, masked_code)
                rules_applied["rule_4_fragment_outputs"] += nsub

        # Strip remaining layout(...)
        def repl_frag_layout(m):
            rules_applied["rule_2_layout"] += 1
            return ""

        masked_code = re.sub(r'layout\s*\([^)]*\)\s*', repl_frag_layout, masked_code)

        # Rule 4: in -> varying
        def repl_frag_in(m):
            rules_applied["rule_4_fragment_outputs"] += 1
            return m.group(1) + "varying "

        masked_code = re.sub(r'(^[ \t]*)in\s+', repl_frag_in, masked_code, flags=re.MULTILINE)

    elif stage == "both":
        # Qualifier-free rules only
        def repl_both_layout(m):
            rules_applied["rule_2_layout"] += 1
            return ""

        masked_code = re.sub(r'layout\s*\([^)]*\)\s*', repl_both_layout, masked_code)

        # If it has in/out declarations, list under needs manual check
        in_out_m = re.search(r'^[ \t]*(?:in|out)\s+[A-Za-z0-9_]+', masked_code, re.MULTILINE)
        if in_out_m:
            issues.append((
                filename,
                0,
                "in/out declaration in stage 'both'",
                "Include file used in both VS and FS contains in/out declarations",
            ))

    # Rule 5: texture calls
    masked_code, tex_count = replace_texture_calls(masked_code, local_samplers, stage)
    rules_applied["rule_5_textures"] += tex_count

    converted = unmask_comments(masked_code, comments)
    return converted, rules_applied, issues


def split_shader_sections(text: str) -> list[tuple[str, str, str]]:
    """
    Split .shader file into sections.
    Returns list of (header_line, section_name, content).
    """
    pattern = re.compile(r'^[ \t]*\[\[([A-Za-z0-9_]+)\]\][^\n]*\n?', re.MULTILINE)
    matches = list(pattern.finditer(text))
    if not matches:
        return [("", "", text)]

    sections = []
    if matches[0].start() > 0:
        prelude = text[:matches[0].start()]
        sections.append(("", "", prelude))

    for i, m in enumerate(matches):
        sec_name = m.group(1)
        header_line = m.group(0)
        start_content = m.end()
        end_content = matches[i + 1].start() if i + 1 < len(matches) else len(text)
        content = text[start_content:end_content]
        sections.append((header_line, sec_name, content))

    return sections


def convert_section(
    header: str,
    content: str,
    sampler_types: dict[str, str] = None,
) -> tuple[str, list[tuple[str, int, str, str]]]:
    """
    Convert a single section by its header string.
    Useful for unit testing directly on strings.
    """
    h = header.strip()
    if h.startswith("[[FX") or h == "[[FX]]":
        return content, []

    stage = "vertex" if h.startswith("[[VS") else "fragment"
    converted, _, issues = convert_glsl_stage_content(content, stage, filename="", sampler_types=sampler_types)
    return converted, issues


def convert_shader_text(
    text: str,
    filename: str = "",
    external_samplers: dict[str, str] = None,
) -> tuple[str, dict[str, int], list[tuple[str, int, str, str]]]:
    """
    Convert a complete .shader file content.
    """
    sections = split_shader_sections(text)
    total_rules = defaultdict(int)
    total_issues = []

    # Collect all samplers declared across all sections (including FX)
    all_samplers = dict(external_samplers or {})
    for _, _, sec_content in sections:
        all_samplers.update(collect_sampler_declarations(sec_content))

    converted_parts = []
    for header, sec_name, content in sections:
        if not sec_name or sec_name.startswith("FX"):
            converted_parts.append(header + content)
            continue

        if sec_name.startswith("VS"):
            stage = "vertex"
        elif sec_name.startswith("FS"):
            stage = "fragment"
        else:
            converted_parts.append(header + content)
            continue

        converted_body, rules, issues = convert_glsl_stage_content(
            content,
            stage,
            filename=filename,
            sampler_types=all_samplers,
        )
        for k, v in rules.items():
            total_rules[k] += v
        total_issues.extend(issues)
        converted_parts.append(header + converted_body)

    return "".join(converted_parts), dict(total_rules), total_issues


def convert_glsl_text(
    text: str,
    stage: str,
    filename: str = "",
    external_samplers: dict[str, str] = None,
) -> tuple[str, dict[str, int], list[tuple[str, int, str, str]]]:
    """
    Convert a .glsl include file.
    """
    return convert_glsl_stage_content(text, stage, filename=filename, sampler_types=external_samplers)


def needs_conversion(content: str) -> bool:
    """
    Returns True if the file contains any GLSL 4.x/higher constructs requiring conversion.
    """
    if re.search(r'^[ \t]*#[ \t]*version[ \t]+4', content, re.MULTILINE):
        return True
    if re.search(r'^[ \t]*(?:in|out)\s+[A-Za-z0-9_]+', content, re.MULTILINE):
        return True
    if 'layout(' in content or 'layout (' in content:
        return True
    if re.search(r'\btexture(?:Lod|Proj)?\s*\(', content):
        return True
    return False


def scan_include_stages(ace_dir: str, base_smod_path: str | None) -> dict[str, str]:
    """
    Scan all .shader files in ACE and base smod for #include "shaders/<path>" in VS/FS sections.
    Returns mapping: rel_path (e.g. "shaders/utilityLib/vertCommon.glsl") -> "vertex" | "fragment" | "both" | "none".
    """
    vs_includes = set()
    fs_includes = set()

    include_pattern = re.compile(r'^[ \t]*#[ \t]*include\s+["<](shaders/[^">]+)[">]', re.MULTILINE)

    def scan_shader_content(text: str):
        for header, sec_name, content in split_shader_sections(text):
            if sec_name.startswith("VS"):
                for m in include_pattern.finditer(content):
                    vs_includes.add(m.group(1))
            elif sec_name.startswith("FS"):
                for m in include_pattern.finditer(content):
                    fs_includes.add(m.group(1))

    # 1. Scan ACE shaders
    ace_horde = os.path.join(ace_dir, "data", "horde")
    if os.path.isdir(ace_horde):
        for root, _, files in os.walk(ace_horde):
            for f in files:
                if f.endswith(".shader"):
                    full_path = os.path.join(root, f)
                    try:
                        with open(full_path, "r", encoding="utf-8", errors="replace") as fh:
                            scan_shader_content(fh.read())
                    except Exception as e:
                        print(f"Warning: could not read {full_path}: {e}", file=sys.stderr)

    # 2. Scan base smod shaders if available
    if base_smod_path and os.path.isfile(base_smod_path):
        try:
            with zipfile.ZipFile(base_smod_path, "r") as zf:
                for name in zf.namelist():
                    if name.endswith(".shader") and "data/horde/" in name:
                        try:
                            content = zf.read(name).decode("utf-8", errors="replace")
                            scan_shader_content(content)
                        except Exception as e:
                            print(f"Warning: could not read zip entry {name}: {e}", file=sys.stderr)
        except Exception as e:
            print(f"Warning: could not open base smod {base_smod_path}: {e}", file=sys.stderr)

    # 3. Transitive propagation through .glsl includes
    glsl_contents = {}
    if os.path.isdir(ace_horde):
        for root, _, files in os.walk(ace_horde):
            for f in files:
                if f.endswith(".glsl"):
                    full_path = os.path.join(root, f)
                    rel_to_horde = os.path.relpath(full_path, ace_horde).replace("\\", "/")
                    try:
                        with open(full_path, "r", encoding="utf-8", errors="replace") as fh:
                            glsl_contents[rel_to_horde] = fh.read()
                    except Exception:
                        pass

    # Propagate transitive includes until stable
    changed = True
    while changed:
        changed = False
        for inc_path, content in glsl_contents.items():
            if inc_path in vs_includes:
                for m in include_pattern.finditer(content):
                    nested = m.group(1)
                    if nested not in vs_includes:
                        vs_includes.add(nested)
                        changed = True
            if inc_path in fs_includes:
                for m in include_pattern.finditer(content):
                    nested = m.group(1)
                    if nested not in fs_includes:
                        fs_includes.add(nested)
                        changed = True

    decisions = {}
    for inc_path in glsl_contents.keys():
        in_vs = inc_path in vs_includes
        in_fs = inc_path in fs_includes
        if in_vs and in_fs:
            decisions[inc_path] = "both"
        elif in_vs:
            decisions[inc_path] = "vertex"
        elif in_fs:
            decisions[inc_path] = "fragment"
        else:
            decisions[inc_path] = "vertex"  # none -> treat as vertex

    return decisions


def collect_transitive_samplers(file_path: str, horde_dir: str, visited: set = None) -> dict[str, str]:
    """
    Recursively collect sampler declarations from a file and all its includes.
    """
    if visited is None:
        visited = set()
    norm_path = os.path.abspath(file_path)
    if norm_path in visited:
        return {}
    visited.add(norm_path)

    samplers = {}
    if not os.path.isfile(norm_path):
        return samplers

    try:
        with open(norm_path, "r", encoding="utf-8", errors="replace") as fh:
            content = fh.read()
    except Exception:
        return samplers

    samplers.update(collect_sampler_declarations(content))

    include_pattern = re.compile(r'^[ \t]*#[ \t]*include\s+["<](shaders/[^">]+)[">]', re.MULTILINE)
    for m in include_pattern.finditer(content):
        inc_rel = m.group(1)
        inc_full = os.path.join(horde_dir, inc_rel)
        samplers.update(collect_transitive_samplers(inc_full, horde_dir, visited))

    return samplers


def generate_manifest(
    ace_dir: str,
    out_dir: str,
    converted_rel_files: list[str],
) -> dict:
    """
    Generate manifest.json for mac_gl_compat mod.
    """
    ace_manifest_path = os.path.join(ace_dir, "manifest.json")
    ace_overrides = {}
    if os.path.isfile(ace_manifest_path):
        try:
            with open(ace_manifest_path, "r", encoding="utf-8") as fh:
                ace_data = json.load(fh)
                ace_overrides = ace_data.get("overrides", {})
        except Exception as e:
            print(f"Warning: could not read {ace_manifest_path}: {e}", file=sys.stderr)

    converted_set = set(f.replace("\\", "/") for f in converted_rel_files)
    referenced_converted = set()

    mod_overrides = {}

    # 1. Map existing ACE override keys pointing to converted files
    for k, v in ace_overrides.items():
        if isinstance(v, str) and v.startswith("file(") and v.endswith(")"):
            rel_target = v[5:-1].strip().replace("\\", "/").lstrip("/")
            if rel_target in converted_set:
                mod_overrides[k] = f"file({rel_target})"
                referenced_converted.add(rel_target)

    # 2. Add stonehearth_ace/<rel> for converted files not referenced by any ACE override
    for rel in sorted(converted_set):
        if rel not in referenced_converted:
            mod_overrides[f"stonehearth_ace/{rel}"] = f"file({rel})"

    manifest = {
        "info": {
            "name": "Mac GL Compat (harness only)",
            "namespace": "mac_gl_compat",
            "version": 3,
        },
        "dependencies": [
            "stonehearth_ace",
        ],
        "overrides": mod_overrides,
    }

    out_manifest_path = os.path.join(out_dir, "manifest.json")
    os.makedirs(out_dir, exist_ok=True)
    with open(out_manifest_path, "w", encoding="utf-8") as fh:
        json.dump(manifest, fh, indent=3)

    return manifest


def main():
    parser = argparse.ArgumentParser(description="Convert GLSL shaders to 1.20 for macOS compatibility")
    parser.add_argument("--ace", default="stonehearth_ace", help="Path to stonehearth_ace directory")
    parser.add_argument(
        "--base-smod",
        default="stonehearth_game/Stonehearth.v1.1.0.949/mods/stonehearth.smod",
        help="Path to base stonehearth.smod zip",
    )
    parser.add_argument("--out", default="mods/mac_gl_compat", help="Path to output mod directory")

    args = parser.parse_args()

    ace_dir = os.path.abspath(args.ace)
    out_dir = os.path.abspath(args.out)
    base_smod_path = os.path.abspath(args.base_smod) if args.base_smod else None

    if not os.path.isdir(ace_dir):
        print(f"Error: ACE directory not found: {ace_dir}", file=sys.stderr)
        sys.exit(1)

    ace_horde = os.path.join(ace_dir, "data", "horde")
    if not os.path.isdir(ace_horde):
        print(f"Error: Horde data directory not found: {ace_horde}", file=sys.stderr)
        sys.exit(1)

    print(f"Scanning include stages from {ace_dir}...")
    include_stages = scan_include_stages(ace_dir, base_smod_path)

    # Collect all *.shader and *.glsl files under <ace>/data/horde/
    candidate_files = []
    for root, _, files in os.walk(ace_horde):
        for f in sorted(files):
            if f.endswith(".shader") or f.endswith(".glsl"):
                candidate_files.append(os.path.join(root, f))

    converted_files = []
    file_rule_stats = {}
    all_issues = []

    for full_path in candidate_files:
        rel_to_ace = os.path.relpath(full_path, ace_dir).replace("\\", "/")
        rel_to_horde = os.path.relpath(full_path, ace_horde).replace("\\", "/")

        try:
            with open(full_path, "r", encoding="utf-8", errors="replace") as fh:
                orig_content = fh.read()
        except Exception as e:
            print(f"Warning: could not read {full_path}: {e}", file=sys.stderr)
            continue

        if not needs_conversion(orig_content):
            continue

        # Collect transitive samplers
        external_samplers = collect_transitive_samplers(full_path, ace_horde)

        has_sections = re.search(r'^\[\[[A-Za-z0-9_]+\]\]', orig_content, re.MULTILINE) is not None
        if full_path.endswith(".shader") and has_sections:
            converted_code, rules, issues = convert_shader_text(
                orig_content,
                filename=rel_to_ace,
                external_samplers=external_samplers,
            )
        else:
            stage = include_stages.get(rel_to_horde, "vertex")
            converted_code, rules, issues = convert_glsl_text(
                orig_content,
                stage=stage,
                filename=rel_to_ace,
                external_samplers=external_samplers,
            )

        # Write converted file to out_dir
        dest_path = os.path.join(out_dir, rel_to_ace)
        os.makedirs(os.path.dirname(dest_path), exist_ok=True)
        with open(dest_path, "w", encoding="utf-8") as fh:
            fh.write(converted_code)

        converted_files.append(rel_to_ace)
        file_rule_stats[rel_to_ace] = rules
        all_issues.extend(issues)

    # Generate manifest.json
    manifest = generate_manifest(ace_dir, out_dir, converted_files)

    # Generate CONVERSION_REPORT.md
    report_path = os.path.join(out_dir, "CONVERSION_REPORT.md")
    report_lines = [
        "# Mac GL Compat Mod Conversion Report",
        "",
        f"- Files converted: {len(converted_files)}",
        f"- Total needs manual check items: {len(all_issues)}",
        "",
        "## Converted Files and Applied Rules",
        "",
        "| File | Rule 1 (Version) | Rule 2 (Layout) | Rule 3 (Vertex Qualifiers) | Rule 4 (Fragment Outputs) | Rule 5 (Textures) |",
        "| --- | --- | --- | --- | --- | --- |",
    ]

    for rel_path in sorted(converted_files):
        stats = file_rule_stats[rel_path]
        report_lines.append(
            f"| `{rel_path}` | {stats.get('rule_1_version', 0)} | {stats.get('rule_2_layout', 0)} | "
            f"{stats.get('rule_3_vertex_qualifiers', 0)} | {stats.get('rule_4_fragment_outputs', 0)} | "
            f"{stats.get('rule_5_textures', 0)} |"
        )

    report_lines.extend([
        "",
        "## Include Stage Decisions",
        "",
        "| Include File | Decided Stage |",
        "| --- | --- |",
    ])

    for inc_path in sorted(include_stages.keys()):
        report_lines.append(f"| `{inc_path}` | {include_stages[inc_path]} |")

    report_lines.extend([
        "",
        "## Needs Manual Check Items",
        "",
    ])

    if all_issues:
        report_lines.extend([
            "| Location | Construct | Context |",
            "| --- | --- | --- |",
        ])
        for filename, line_num, construct, context in all_issues:
            loc = f"`{filename}:{line_num}`" if line_num > 0 else f"`{filename}`"
            clean_context = context.replace("|", "\\|")
            report_lines.append(f"| {loc} | `{construct}` | `{clean_context}` |")
    else:
        report_lines.append("No manual check items detected.")

    report_lines.append("")

    with open(report_path, "w", encoding="utf-8") as fh:
        fh.write("\n".join(report_lines))

    # Print summary to stdout
    print(f"Conversion complete. Converted {len(converted_files)} files.")
    print(f"Manifest created at: {os.path.join(out_dir, 'manifest.json')}")
    print(f"Report written to: {report_path}")
    print(f"Needs manual check items count: {len(all_issues)}")
    if all_issues:
        print("\nNeeds manual check items:")
        for filename, line_num, construct, context in all_issues:
            loc = f"{filename}:{line_num}" if line_num > 0 else filename
            print(f"  {loc}: [{construct}] {context}")


if __name__ == "__main__":
    main()

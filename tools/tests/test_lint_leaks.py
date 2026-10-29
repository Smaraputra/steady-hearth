import contextlib
import io
import json
import os
import sys
import tempfile
import unittest

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
if REPO_ROOT not in sys.path:
    sys.path.insert(0, REPO_ROOT)

from tools.lint_leaks import main, scan_roots, scan_text, scan_texts


def rule_findings(findings, rule):
    return [f for f in findings if f["rule"] == rule]


class TestIpairsIndexAsId(unittest.TestCase):
    def test_positive(self):
        text = "for id in ipairs(trace_ids) do\n   self:_remove(id)\nend\n"
        found = rule_findings(scan_text("a.lua", text), "ipairs-index-as-id")
        self.assertEqual([f["line"] for f in found], [1])
        self.assertEqual(found[0]["file"], "a.lua")
        self.assertEqual(found[0]["code"], "for id in ipairs(trace_ids) do")

    def test_negative_two_variables(self):
        text = "for _, id in ipairs(trace_ids) do\n   self:_remove(id)\nend\n"
        self.assertEqual(rule_findings(scan_text("a.lua", text), "ipairs-index-as-id"), [])

    def test_suffix_id_name_is_reported_without_usage(self):
        text = "for entity_id in ipairs(list) do\n   count = count + 1\nend\n"
        self.assertEqual(len(rule_findings(scan_text("a.lua", text), "ipairs-index-as-id")), 1)

    def test_index_passed_to_call_is_reported(self):
        text = "for i in ipairs(list) do\n   self:_remove(i)\nend\n"
        self.assertEqual(len(rule_findings(scan_text("a.lua", text), "ipairs-index-as-id")), 1)

    def test_index_into_the_iterated_table_is_not_reported(self):
        text = "for i in ipairs(list) do\n   total = total + list[i]\nend\n"
        self.assertEqual(rule_findings(scan_text("a.lua", text), "ipairs-index-as-id"), [])

    def test_index_into_another_table_is_reported(self):
        text = "for i in ipairs(list) do\n   total = total + other[i]\nend\n"
        self.assertEqual(len(rule_findings(scan_text("a.lua", text), "ipairs-index-as-id")), 1)

    def test_use_after_the_loop_end_is_not_reported(self):
        text = "for i in ipairs(list) do\n   count = count + 1\nend\nself:_remove(i)\n"
        self.assertEqual(rule_findings(scan_text("a.lua", text), "ipairs-index-as-id"), [])


class TestNotPrecedence(unittest.TestCase):
    def test_positive(self):
        text = "if not entity_data.target_type == target_type then\n   return false\nend\n"
        found = rule_findings(scan_text("a.lua", text), "not-precedence")
        self.assertEqual([f["line"] for f in found], [1])

    def test_positive_not_equal(self):
        text = "if not type(rule.key) ~= 'string' then\nend\n"
        self.assertEqual(len(rule_findings(scan_text("a.lua", text), "not-precedence")), 1)

    def test_negative_parenthesised(self):
        self.assertEqual(rule_findings(scan_text("a.lua", "if not (a == b) then\nend\n"),
                                       "not-precedence"), [])

    def test_negative_plain_comparison(self):
        self.assertEqual(rule_findings(scan_text("a.lua", "if a ~= b then\nend\n"),
                                       "not-precedence"), [])

    def test_negative_not_inside_parentheses_before_comparison(self):
        self.assertEqual(rule_findings(scan_text("a.lua", "if (not a) == b then\nend\n"),
                                       "not-precedence"), [])

    def test_negative_both_sides_negated(self):
        text = "if not a == not b.c(d) then\nend\n"
        self.assertEqual(rule_findings(scan_text("a.lua", text), "not-precedence"), [])

    def test_negative_inside_string(self):
        text = "local s = 'if not a == b then'\n"
        self.assertEqual(rule_findings(scan_text("a.lua", text), "not-precedence"), [])


class TestListenWithoutTrigger(unittest.TestCase):
    LISTEN = "radiant.events.listen(g, 'worker_remove', self, self._unfeed)\n"

    def test_positive(self):
        files = {
            "a.lua": self.LISTEN,
            "b.lua": "radiant.events.trigger(g, 'worker_removed', {})\n",
        }
        found = rule_findings(scan_texts(files), "listen-without-trigger")
        self.assertEqual(len(found), 1)
        self.assertEqual((found[0]["file"], found[0]["line"]), ("a.lua", 1))
        self.assertEqual(found[0]["detail"], "worker_remove")

    def test_negative_matching_names(self):
        files = {
            "a.lua": self.LISTEN,
            "b.lua": "radiant.events.trigger(g, 'worker_remove', {})\n",
        }
        self.assertEqual(rule_findings(scan_texts(files), "listen-without-trigger"), [])

    def test_engine_event_is_not_a_finding(self):
        files = {"a.lua": "radiant.events.listen(radiant, 'radiant:gameloop', self, self._tick)\n"}
        engine = []
        found = scan_texts(files, engine_events=engine)
        self.assertEqual(rule_findings(found, "listen-without-trigger"), [])
        self.assertEqual([(f["file"], f["detail"]) for f in engine],
                         [("a.lua", "radiant:gameloop")])

    def test_json_string_counts_as_trigger(self):
        files = {
            "a.lua": self.LISTEN,
            "data.json": '{"on_done": {"event": "worker_remove"}}',
        }
        self.assertEqual(rule_findings(scan_texts(files), "listen-without-trigger"), [])

    def test_string_in_unrelated_call_counts_as_trigger(self):
        files = {
            "a.lua": self.LISTEN,
            "b.lua": "local name = 'worker_remove'\nfire(name)\n",
        }
        self.assertEqual(rule_findings(scan_texts(files), "listen-without-trigger"), [])

    def test_colon_listen_and_listen_once_forms(self):
        files = {
            "a.lua": "autotest.util:listen(worker, 'ev_one', function() end)\n"
                     "radiant.events.listen_once(worker, 'ev_two', self, self._f)\n",
        }
        found = rule_findings(scan_texts(files), "listen-without-trigger")
        self.assertEqual([(f["line"], f["detail"]) for f in found], [(1, "ev_one"), (2, "ev_two")])

    def test_variable_event_name_is_ignored(self):
        files = {"a.lua": "radiant.events.listen(g, event_name, self, self._f)\n"}
        self.assertEqual(rule_findings(scan_texts(files), "listen-without-trigger"), [])

    def test_name_in_comment_does_not_count_as_trigger(self):
        files = {
            "a.lua": self.LISTEN + "-- radiant.events.trigger(g, 'worker_remove', {})\n",
        }
        self.assertEqual(len(rule_findings(scan_texts(files), "listen-without-trigger")), 1)

    def test_dynamic_prefix_is_skipped(self):
        files = {
            "a.lua": "radiant.events.listen(e, 'stonehearth:attribute_changed:speed', self, f)\n",
            "b.lua": "radiant.events.trigger(e, 'stonehearth:attribute_changed:' .. name, {})\n",
        }
        self.assertEqual(rule_findings(scan_texts(files), "listen-without-trigger"), [])

    def test_short_prefix_does_not_suppress(self):
        files = {
            "a.lua": "radiant.events.listen(e, 'stonehearth:speed', self, f)\n",
            "b.lua": "local ok = uri:starts_with('stonehearth:')\n",
        }
        self.assertEqual(len(rule_findings(scan_texts(files), "listen-without-trigger")), 1)

    def test_two_listeners_of_one_orphan_event_are_both_reported(self):
        files = {"a.lua": self.LISTEN, "b.lua": self.LISTEN}
        self.assertEqual(len(rule_findings(scan_texts(files), "listen-without-trigger")), 2)


class TestDuplicateCallInFunction(unittest.TestCase):
    def test_positive(self):
        text = (
            "function Foo:activate()\n"
            "   if self._a then\n"
            "      self:_create_listeners()\n"
            "   else\n"
            "      self:_create_listeners()\n"
            "   end\n"
            "end\n"
        )
        found = rule_findings(scan_text("a.lua", text), "duplicate-call-in-function")
        self.assertEqual([f["line"] for f in found], [5])
        self.assertIn("line 3", found[0]["detail"])

    def test_negative_once(self):
        text = (
            "function Foo:activate()\n"
            "   if self._a then\n"
            "      self:_create_listeners()\n"
            "   end\n"
            "end\n"
        )
        self.assertEqual(rule_findings(scan_text("a.lua", text), "duplicate-call-in-function"), [])

    def test_negative_same_line_in_two_functions(self):
        text = (
            "function Foo:activate()\n"
            "   self:_create_listeners()\n"
            "end\n"
            "function Foo:restore()\n"
            "   self:_create_listeners()\n"
            "end\n"
        )
        self.assertEqual(rule_findings(scan_text("a.lua", text), "duplicate-call-in-function"), [])

    def test_negative_same_line_in_two_closures(self):
        text = (
            "function Foo:activate()\n"
            "   self._a = radiant.events.listen(x, 'e1', function()\n"
            "         self:_start_timer()\n"
            "      end)\n"
            "   self._b = radiant.events.listen(x, 'e2', function()\n"
            "         self:_start_timer()\n"
            "      end)\n"
            "end\n"
        )
        self.assertEqual(rule_findings(scan_text("a.lua", text), "duplicate-call-in-function"), [])

    def test_positive_listen_and_trace_calls(self):
        text = (
            "local function setup(self)\n"
            "   self._l = radiant.events.listen(self._entity, 'e', self, self._on_e)\n"
            "   self._t = self._entity:trace_data('x')\n"
            "   self._l = radiant.events.listen(self._entity, 'e', self, self._on_e)\n"
            "   self._t = self._entity:trace_data('x')\n"
            "end\n"
        )
        found = rule_findings(scan_text("a.lua", text), "duplicate-call-in-function")
        self.assertEqual([f["line"] for f in found], [4, 5])

    def test_negative_other_calls_are_ignored(self):
        text = "function Foo:run()\n   self:_do_it()\n   self:_do_it()\nend\n"
        self.assertEqual(rule_findings(scan_text("a.lua", text), "duplicate-call-in-function"), [])


class TestDiscardedListenerHandle(unittest.TestCase):
    def test_positive(self):
        text = "   radiant.events.listen(entity, 'stonehearth:foo', self, self._on_foo)\n"
        found = rule_findings(scan_text("a.lua", text), "discarded-listener-handle")
        self.assertEqual([f["line"] for f in found], [1])

    def test_negative_assigned(self):
        text = "   self._l = radiant.events.listen(entity, 'stonehearth:foo', self, self._on_foo)\n"
        self.assertEqual(rule_findings(scan_text("a.lua", text), "discarded-listener-handle"), [])

    def test_positive_timers_and_game_loop(self):
        text = (
            "stonehearth.calendar:set_interval('x', '1h', fn)\n"
            "stonehearth.calendar:set_timer('x', '1h', fn)\n"
            "radiant.on_game_loop('x', fn)\n"
            "radiant.set_realtime_timer('x', 10, fn)\n"
            "radiant.events.listen_once(e, 'a', self, f)\n"
        )
        found = rule_findings(scan_text("a.lua", text), "discarded-listener-handle")
        self.assertEqual([f["line"] for f in found], [1, 2, 3, 4, 5])

    def test_negative_listen_once_with_destroy_on_the_same_line(self):
        text = "radiant.events.listen_once(e, 'a', self, f):destroy()\n"
        self.assertEqual(rule_findings(scan_text("a.lua", text), "discarded-listener-handle"), [])

    def test_negative_continuation_of_an_assignment(self):
        text = "self._l =\n   radiant.events.listen(e, 'a', self, f)\n"
        self.assertEqual(rule_findings(scan_text("a.lua", text), "discarded-listener-handle"), [])

    def test_negative_returned(self):
        text = "return radiant.events.listen(e, 'a', self, f)\n"
        self.assertEqual(rule_findings(scan_text("a.lua", text), "discarded-listener-handle"), [])


class TestHandleNeverDestroyed(unittest.TestCase):
    def test_positive(self):
        text = (
            "function Foo:start()\n"
            "   self._timer = stonehearth.calendar:set_interval('x', '1h', fn)\n"
            "end\n"
        )
        found = rule_findings(scan_text("a.lua", text), "handle-never-destroyed")
        self.assertEqual([(f["line"], f["detail"]) for f in found], [(2, "self._timer")])

    def test_negative_destroyed(self):
        text = (
            "function Foo:start()\n"
            "   self._timer = stonehearth.calendar:set_interval('x', '1h', fn)\n"
            "end\n"
            "function Foo:destroy()\n"
            "   self._timer:destroy()\n"
            "end\n"
        )
        self.assertEqual(rule_findings(scan_text("a.lua", text), "handle-never-destroyed"), [])

    def test_negative_destroy_through_a_local_alias_of_the_field_name(self):
        text = (
            "self._trace = self._entity:trace_data('x')\n"
            "local function stop(_trace)\n"
            "end\n"
            "_trace:destroy()\n"
        )
        self.assertEqual(rule_findings(scan_text("a.lua", text), "handle-never-destroyed"), [])

    def test_reported_once_per_field(self):
        text = (
            "self._l = radiant.events.listen(a, 'x', self, f)\n"
            "self._l = radiant.events.listen(b, 'x', self, f)\n"
        )
        self.assertEqual(len(rule_findings(scan_text("a.lua", text), "handle-never-destroyed")), 1)

    def test_negative_other_assignment(self):
        text = "self._value = compute(1)\nself._flag = a == b\n"
        self.assertEqual(rule_findings(scan_text("a.lua", text), "handle-never-destroyed"), [])

    def test_patch_and_base_file_are_searched_together(self):
        files = {
            "mod/monkey_patches/ace_foo.lua": "self._l = radiant.events.listen(a, 'x', self, f)\n",
            "base/foo.lua": "function Foo:destroy()\n   self._l:destroy()\nend\n",
        }
        self.assertEqual(rule_findings(scan_texts(files), "handle-never-destroyed"), [])

    def test_unrelated_files_with_the_same_name_are_not_paired(self):
        files = {
            "a/foo.lua": "self._l = radiant.events.listen(a, 'x', self, f)\n",
            "b/foo.lua": "function Foo:destroy()\n   self._l:destroy()\nend\n",
        }
        self.assertEqual(len(rule_findings(scan_texts(files), "handle-never-destroyed")), 1)


class TestRealtimeTimerInAi(unittest.TestCase):
    TEXT = "radiant.set_realtime_timer('t', 100, fn)\n"

    def test_positive(self):
        found = rule_findings(scan_text("stonehearth/ai/actions/foo.lua", self.TEXT),
                              "realtime-timer-in-ai")
        self.assertEqual([f["line"] for f in found], [1])

    def test_positive_observer_interval(self):
        text = "self._t = radiant.set_realtime_interval('t', 100, fn)\n"
        found = rule_findings(scan_text("stonehearth/ai/observers/foo.lua", text),
                              "realtime-timer-in-ai")
        self.assertEqual(len(found), 1)

    def test_negative_other_path(self):
        self.assertEqual(rule_findings(scan_text("stonehearth/services/foo.lua", self.TEXT),
                                       "realtime-timer-in-ai"), [])


class TestCommentStripping(unittest.TestCase):
    BUG = "if not entity_data.target_type == target_type then"

    def test_line_comment(self):
        text = "-- %s\nlocal x = 1 -- %s\n" % (self.BUG, self.BUG)
        self.assertEqual(rule_findings(scan_text("a.lua", text), "not-precedence"), [])

    def test_block_comment_and_line_numbers_after_it(self):
        text = "--[[\n%s\n%s\n]]\nlocal x = 1\n%s\nend\n" % (self.BUG, self.BUG, self.BUG)
        found = rule_findings(scan_text("a.lua", text), "not-precedence")
        self.assertEqual([f["line"] for f in found], [6])

    def test_leveled_block_comment(self):
        text = "--[==[\n%s\n]]\n%s\n]==]\n%s\n" % (self.BUG, self.BUG, self.BUG)
        found = rule_findings(scan_text("a.lua", text), "not-precedence")
        self.assertEqual([f["line"] for f in found], [6])

    def test_comment_marker_inside_string_is_not_a_comment(self):
        text = "local s = '--'; %s\n" % self.BUG
        found = rule_findings(scan_text("a.lua", text), "not-precedence")
        self.assertEqual([f["line"] for f in found], [1])

    def test_escaped_quote_in_string(self):
        text = "local s = 'it\\'s -- fine'\n%s\n" % self.BUG
        found = rule_findings(scan_text("a.lua", text), "not-precedence")
        self.assertEqual([f["line"] for f in found], [2])

    def test_long_bracket_string_hides_code_but_keeps_lines(self):
        text = "local s = [[\n%s\n]]\n%s\n" % (self.BUG, self.BUG)
        found = rule_findings(scan_text("a.lua", text), "not-precedence")
        self.assertEqual([f["line"] for f in found], [4])

    def test_commented_listen_is_not_a_listen_site(self):
        text = "-- radiant.events.listen(g, 'only_in_comment', self, f)\n"
        self.assertEqual(scan_text("a.lua", text), [])

    def test_crlf_line_endings(self):
        text = "local x = 1\r\n%s\r\nend\r\n" % self.BUG
        found = rule_findings(scan_text("a.lua", text), "not-precedence")
        self.assertEqual([(f["line"], f["code"]) for f in found], [(2, self.BUG)])


class TestRuleSelection(unittest.TestCase):
    def test_rules_argument_limits_the_run(self):
        text = ("if not a == b then\nend\n"
                "radiant.events.listen(e, 'x', self, f)\n")
        found = scan_text("a.lua", text, ["not-precedence"])
        self.assertEqual({f["rule"] for f in found}, {"not-precedence"})

    def test_finding_keys(self):
        found = scan_text("a.lua", "if not a == b then\nend\n")
        self.assertEqual(sorted(found[0]), ["code", "detail", "file", "line", "rule"])

    def test_long_code_is_truncated(self):
        text = "if not a == b then local " + "x" * 300 + " = 1 end\n"
        found = scan_text("a.lua", text)
        self.assertEqual(len(found[0]["code"]), 160)


class TestCommandLine(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        os.makedirs(os.path.join(self.tmp.name, "mod", "ai", "actions"))
        self.write("mod/ai/actions/act.lua",
                   "function Act:start()\n"
                   "   self._t = radiant.set_realtime_interval('x', 10, fn)\n"
                   "   if not self._a == self._b then\n"
                   "   end\n"
                   "end\n")
        self.write("mod/other.lua", "radiant.events.listen(g, 'orphan_event', self, f)\n")
        self.write("mod/data.json", '{"a": "something_else"}')
        self.write("mod/ignored.txt", "if not a == b then")

    def write(self, relative, text):
        with open(os.path.join(self.tmp.name, relative), "w", newline="") as handle:
            handle.write(text)

    def run_main(self, *args):
        out = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
            code = main(["lint_leaks.py"] + list(args))
        return code, out.getvalue()

    def test_scan_roots_finds_files_recursively(self):
        found = scan_roots([self.tmp.name])
        rules = sorted({f["rule"] for f in found})
        self.assertEqual(rules, ["discarded-listener-handle", "handle-never-destroyed",
                                 "listen-without-trigger", "not-precedence",
                                 "realtime-timer-in-ai"])

    def test_json_output(self):
        code, output = self.run_main(self.tmp.name, "--json")
        self.assertEqual(code, 0)
        data = json.loads(output)
        self.assertEqual({f["rule"] for f in data},
                         {"discarded-listener-handle", "handle-never-destroyed",
                          "listen-without-trigger", "not-precedence", "realtime-timer-in-ai"})
        for item in data:
            self.assertEqual(sorted(item), ["code", "detail", "file", "line", "rule"])

    def test_json_rule_filter(self):
        code, output = self.run_main(self.tmp.name, "--json", "--rule", "not-precedence")
        self.assertEqual(code, 0)
        data = json.loads(output)
        self.assertEqual([(f["rule"], f["line"]) for f in data], [("not-precedence", 3)])

    def test_markdown_output(self):
        code, output = self.run_main(self.tmp.name)
        self.assertEqual(code, 0)
        self.assertIn("## not-precedence: ", output)
        self.assertIn("| File | Line | Code |", output)
        self.assertIn("### engine events (informational)", output)
        self.assertIn("## Summary", output)
        self.assertIn("| not-precedence | 1 |", output)
        self.assertIn("| ipairs-index-as-id | 0 |", output)

    def test_markdown_escapes_pipes(self):
        self.write("mod/pipe.lua", "if not a == b then x = 'a|b' end\n")
        code, output = self.run_main(self.tmp.name, "--rule", "not-precedence")
        self.assertEqual(code, 0)
        self.assertIn("a\\|b", output)

    def test_usage_errors(self):
        self.assertEqual(self.run_main()[0], 64)
        self.assertEqual(self.run_main(self.tmp.name, "--rule", "no-such-rule")[0], 64)
        self.assertEqual(self.run_main(self.tmp.name, "--bogus")[0], 64)
        self.assertEqual(self.run_main(os.path.join(self.tmp.name, "missing"))[0], 66)


if __name__ == "__main__":
    unittest.main()

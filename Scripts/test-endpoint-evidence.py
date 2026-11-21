#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 David E. Weekly
"""Negative tests for the evidence checks in generate-endpoint-docs.py."""
import copy
import importlib
import json
import unittest

gen = importlib.import_module('generate-endpoint-docs')

MANUAL = "on:\n  workflow_call:\n  workflow_dispatch:\n    inputs: {}\n\njobs: {}\n"
SCHEDULED = "on:\n  workflow_dispatch:\n  schedule:\n    - cron: '0 13 * * *'\n\njobs: {}\n"


def problems(data, workflows=None):
    def read_text(rel):
        if workflows and rel in workflows:
            return workflows[rel]
        return (gen.ROOT / rel).read_text()
    return gen.evidence_problems(data, read_text=read_text)


def first_live(data):
    return next(e for e in data['endpoints'] if e['evidence'].get('live'))


class WorkflowTriggerTests(unittest.TestCase):
    def test_dispatch_and_call_only_is_manual(self):
        self.assertEqual(gen.workflow_trigger(MANUAL), 'manual')
        self.assertEqual(gen.workflow_trigger("on: [workflow_dispatch]\n"), 'manual')

    def test_push_or_schedule_is_automatic(self):
        self.assertEqual(gen.workflow_trigger(SCHEDULED), 'automatic')
        self.assertEqual(gen.workflow_trigger("on:\n  push:\n    branches: [ main ]\n"), 'automatic')
        self.assertEqual(gen.workflow_trigger("on: push\n"), 'automatic')

    def test_repository_workflows_match_manifest(self):
        lanes = gen.load()['evidence_lanes']
        for lane in lanes.values():
            text = (gen.ROOT / lane['workflow']).read_text()
            self.assertEqual(gen.workflow_trigger(text), lane['trigger'], lane['workflow'])


class EvidenceProblemTests(unittest.TestCase):
    def setUp(self):
        self.data = gen.load()

    def test_committed_manifest_is_clean(self):
        self.assertEqual(problems(self.data), [])

    def test_live_claim_must_name_daemon_lane_and_date(self):
        for field in ('daemon', 'lane', 'last_passed', 'run', 'tests'):
            data = copy.deepcopy(self.data)
            del first_live(data)['evidence']['live'][field]
            self.assertTrue(problems(data), f"live claim without {field} was accepted")

    def test_live_claim_must_match_the_lane_record(self):
        data = copy.deepcopy(self.data)
        first_live(data)['evidence']['live']['daemon'] = '1.98.0'
        self.assertTrue(any('not among' in p for p in problems(data)))
        data = copy.deepcopy(self.data)
        first_live(data)['evidence']['live']['last_passed'] = '2026-11-21'
        self.assertTrue(any('date of the run' in p for p in problems(data)))

    def test_matrix_trigger_must_match_workflow(self):
        workflow = self.data['evidence_lanes']['headscale-matrix']['workflow']
        found = problems(self.data, {workflow: SCHEDULED})
        self.assertTrue(any('headscale-matrix' in p and 'automatic' in p for p in found), found)
        data = copy.deepcopy(self.data)
        data['evidence_lanes']['headscale-matrix']['trigger'] = 'automatic'
        self.assertTrue(any('headscale-matrix' in p for p in problems(data)))

    def test_retired_free_text_fields_are_rejected(self):
        data = copy.deepcopy(self.data)
        data['tested_matrix'] = 'hermetic headscale lanes'
        data['endpoints'][0]['tested'] = 'matrix+live'
        found = problems(data)
        self.assertTrue(any('tested_matrix' in p for p in found))
        self.assertTrue(any("'tested'" in p for p in found))

    def test_tested_floor_language_is_rejected(self):
        data = copy.deepcopy(self.data)
        data['endpoints'][0]['min_tailscaled'] = 'old'
        self.assertTrue(any('tested floor' in p for p in problems(data)))

    def test_fixture_claim_needs_a_matching_file(self):
        data = copy.deepcopy(self.data)
        entry = next(e for e in data['endpoints'] if e['evidence']['unit'] == 'synthetic-fixture')
        entry['evidence']['fixtures'] = 'no-such-fixture-*.json'
        self.assertTrue(any('matches no file' in p for p in problems(data)))

    def test_historical_record_must_name_a_known_lane(self):
        data = copy.deepcopy(self.data)
        entry = next(e for e in data['endpoints'] if e['evidence'].get('historical'))
        entry['evidence']['historical']['lane'] = 'headscale-1.x'
        self.assertTrue(any('unknown lane' in p for p in problems(data)))

    def test_rendered_table_has_no_retired_line(self):
        table = gen.coverage_table(self.data)
        self.assertNotIn('Tested against:', table)
        self.assertIn('Live on 1.x', table)
        json.dumps(self.data)


if __name__ == '__main__':
    unittest.main()

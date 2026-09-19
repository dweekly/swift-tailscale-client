#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 David E. Weekly
import importlib
import unittest

api = importlib.import_module('verify-api-baseline')


class BaselineNormalizationTests(unittest.TestCase):
    def test_equivalent_compiler_spellings(self):
        for left, right in [
            ('init(from decoder: Decoder) throws', 'init(from decoder: any Decoder) throws'),
            ('case networkFailure(underlying: any Error & Sendable)', 'case networkFailure(underlying: any Error)'),
            ('func discover() -> Result', 'func discover() -> LocalAPIDiscovery.Result'),
        ]:
            self.assertEqual(api.normalize_declaration(left), api.normalize_declaration(right))

    def test_real_signature_changes_remain_visible(self):
        for left, right in [
            ('func read() -> Int', 'func read() -> String'),
            ('func read() async throws', 'func read() async'),
            ('func set(_ value: @Sendable () -> Void)', 'func set(_ value: () -> Void)'),
            ('func read() -> any Decoder', 'func read() -> some Decoder'),
        ]:
            self.assertNotEqual(api.normalize_declaration(left), api.normalize_declaration(right))

    def test_inherited_member_remangling_requires_same_recipient_and_signature(self):
        symbol = {'title': '!=(_:_:)', 'kind': 'swift.func.op', 'declaration': 'static func != (Self, Self) -> Bool'}
        old = 'old::SYNTHESIZED::MyType'
        new = 'new::SYNTHESIZED::MyType'
        self.assertEqual(api.synthesized_aliases({old: symbol}, {new: symbol}), {old: new})
        self.assertEqual(api.synthesized_aliases({old: symbol}, {'new::SYNTHESIZED::OtherType': symbol}), {})
        changed = dict(symbol, declaration='static func != (Self, Self) -> String')
        self.assertEqual(api.synthesized_aliases({old: symbol}, {new: changed}), {})
        self.assertEqual(api.synthesized_aliases({'authored-old': symbol}, {'authored-new': symbol}), {})

    def test_only_inherited_equatable_default_normalizes_borrowing(self):
        old = {'title': '!=(_:_:)', 'kind': 'swift.func.op',
               'declaration': 'static func != (lhs: Self, rhs: Self) -> Bool'}
        new = dict(old, declaration='static func != (lhs: borrowing Self, rhs: borrowing Self) -> Bool')
        self.assertEqual(api.synthesized_aliases({'new::SYNTHESIZED::Type': new},
                                               {'old::SYNTHESIZED::Type': old}),
                         {'new::SYNTHESIZED::Type': 'old::SYNTHESIZED::Type'})
        self.assertNotEqual(api.comparable_declaration('authored', old),
                            api.comparable_declaration('authored', new))

    def test_conformance_relationships_are_not_discarded(self):
        relationship = {'kind': 'conformsTo', 'source': 'MyType', 'target': 'Equatable'}
        self.assertEqual(api.relationship_key(relationship, {}), 'conformsTo::MyType::Equatable')
        self.assertNotEqual(api.relationship_key(relationship, {}), 'conformsTo::MyType::Sendable')
        member = {'kind': 'memberOf', 'source': 'old', 'target': 'MyType'}
        self.assertEqual(api.relationship_key(member, {'old': 'new'}), 'memberOf::new::MyType')


if __name__ == '__main__':
    unittest.main()

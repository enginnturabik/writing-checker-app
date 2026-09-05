import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:writing_checker/models/check_result.dart';

CheckResult _resultWith(List<Map<String, dynamic>> corrections) =>
    CheckResult.fromJson({
      'detected_language': 'French',
      'language_code': 'fr',
      'cefr_estimate': 'B1',
      'word_count': 12,
      'summary': 'Good effort.',
      'scores': {
        'grammar': 70,
        'vocabulary': 75,
        'spelling': 80,
        'coherence': 72,
        'style': 68,
        'overall': 73,
      },
      'corrected_text': '',
      'strengths': <String>[],
      'priorities': <String>[],
      'next_steps': <String>[],
      'corrections': corrections,
      'vocabulary_upgrades': <Map<String, dynamic>>[],
    });

Map<String, dynamic> _correction({
  required String id,
  required String original,
  required String correction,
  String contextBefore = '',
  String category = 'grammar',
}) =>
    {
      'id': id,
      'original': original,
      'correction': correction,
      'context_before': contextBefore,
      'category': category,
      'severity': 'moderate',
      'explanation': 'because',
      'rule': 'a rule',
    };

void main() {
  group('locateSpans', () {
    test('resolves a single span to its offsets', () {
      const source = 'Je suis alle au marche hier.';
      final result = _resultWith([
        _correction(id: 'c1', original: 'alle', correction: 'alle(e)'),
      ]);

      result.locateSpans(source);

      final c = result.corrections.single;
      expect(c.isLocated, isTrue);
      expect(source.substring(c.start!, c.end!), 'alle');
    });

    test('uses context_before to pick the right repeated span', () {
      const source = 'Je mange le pain. Tu mange le pain.';
      final result = _resultWith([
        _correction(
          id: 'c1',
          original: 'mange',
          correction: 'manges',
          contextBefore: 'Tu ',
        ),
      ]);

      result.locateSpans(source);

      // Without the context anchor this would match the first "mange" at 3.
      expect(result.corrections.single.start, source.indexOf('Tu ') + 3);
    });

    test('never lets two corrections claim the same characters', () {
      const source = 'the the the';
      final result = _resultWith([
        _correction(id: 'c1', original: 'the', correction: 'a'),
        _correction(id: 'c2', original: 'the', correction: 'an'),
      ]);

      result.locateSpans(source);

      final starts = result.corrections.map((c) => c.start).toList();
      expect(starts, [0, 4]);
    });

    test('marks a snippet that is not in the text as unlocated', () {
      const source = 'Hello world.';
      final result = _resultWith([
        _correction(id: 'c1', original: 'goodbye', correction: 'hello'),
      ]);

      result.locateSpans(source);

      expect(result.corrections.single.isLocated, isFalse);
    });
  });

  group('applyAccepted', () {
    test('returns the source untouched when nothing is applied', () {
      const source = 'Je suis alle au marche.';
      final result = _resultWith([
        _correction(id: 'c1', original: 'alle', correction: 'allee'),
      ])
        ..locateSpans(source);

      expect(result.applyAccepted(source), source);
    });

    test('substitutes every applied correction, left to right', () {
      const source = 'Je suis alle au marche hier.';
      final result = _resultWith([
        _correction(id: 'c1', original: 'alle', correction: 'allee'),
        _correction(id: 'c2', original: 'marche', correction: 'marche'),
      ])
        ..locateSpans(source);

      for (final c in result.corrections) {
        c.applied = true;
      }

      expect(result.applyAccepted(source), 'Je suis allee au marche hier.');
    });

    test('an empty correction deletes the span', () {
      const source = 'I did not went there.';
      final result = _resultWith([
        _correction(id: 'c1', original: ' went', correction: ''),
      ])
        ..locateSpans(source);
      result.corrections.single.applied = true;

      expect(result.applyAccepted(source), 'I did not there.');
    });
  });

  group('parsing', () {
    test('falls back to safe values for unknown category and severity', () {
      final result = _resultWith([
        {
          'id': 'c1',
          'original': 'x',
          'correction': 'y',
          'context_before': '',
          'category': 'nonsense',
          'severity': 'apocalyptic',
          'explanation': '',
          'rule': '',
        }
      ]);

      expect(result.corrections.single.category, 'other');
      expect(result.corrections.single.severity, 'minor');
    });

    test('clamps out-of-range scores', () {
      final result = CheckResult.fromJson({
        'scores': {'grammar': 140, 'overall': -20},
        'corrections': <Map<String, dynamic>>[],
      });

      expect(result.scores.grammar, 100);
      expect(result.scores.overall, 0);
    });

    test('survives a round trip through JSON', () {
      const source = 'Je suis alle.';
      final original = _resultWith([
        _correction(id: 'c1', original: 'alle', correction: 'allee'),
      ])
        ..locateSpans(source);
      original.corrections.single.applied = true;

      // toJson/decode is the pair history persistence uses.
      final restored = CheckResult.decode(jsonEncode(original.toJson()))
        ..locateSpans(source);

      expect(restored.corrections.single.applied, isTrue);
      expect(restored.corrections.single.start, source.indexOf('alle'));
      expect(restored.scores.overall, 73);
    });
  });

  test('countsByCategory ignores dismissed corrections', () {
    final result = _resultWith([
      _correction(id: 'c1', original: 'a', correction: 'b'),
      _correction(id: 'c2', original: 'c', correction: 'd', category: 'spelling'),
    ]);
    result.corrections[1].dismissed = true;

    expect(result.countsByCategory, {'grammar': 1});
    expect(result.active.length, 1);
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/components/custom_slider.dart';

void main() {
  testWidgets('CustomSlider supports horizontal drag', (tester) async {
    double? lastValue;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 200,
              child: CustomSlider(
                min: 1,
                max: 10,
                value: 1,
                divisions: 9,
                onChanged: (v) => lastValue = v,
              ),
            ),
          ),
        ),
      ),
    );

    await tester.drag(find.byType(CustomSlider), const Offset(120, 0));
    await tester.pump();

    expect(lastValue, isNotNull);
    expect(lastValue!, greaterThan(1));
  });

  testWidgets('CustomSlider handles invalid config safely', (tester) async {
    var callCount = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 200,
              child: CustomSlider(
                min: 1,
                max: 1,
                value: 1,
                divisions: 0,
                onChanged: (_) => callCount++,
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byType(CustomSlider));
    await tester.pump();

    expect(callCount, 0);
  });
}


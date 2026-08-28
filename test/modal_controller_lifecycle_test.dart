import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vently_app/presentation/widgets/modal_text_controller_scope.dart';

void main() {
  testWidgets('modal text controller survives the route exit animation',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: ElevatedButton(
              onPressed: () => showModalBottomSheet<void>(
                context: context,
                useRootNavigator: true,
                builder: (sheetContext) => ModalTextControllerScope(
                  initialValues: const [''],
                  builder: (sheetContext, controllers) => Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextField(controller: controllers.single),
                      TextButton(
                        onPressed: () => Navigator.pop(sheetContext),
                        child: const Text('Close'),
                      ),
                    ],
                  ),
                ),
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'still alive');
    await tester.tap(find.text('Close'));
    await tester.pump();

    expect(tester.takeException(), isNull);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}

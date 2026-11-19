// 冒烟测试：只验证 App 能构建出根组件和 5 个底部入口，不依赖任何原生通道
// （pty / filesDir / SSH 都要真设备，跑在单测里会直接卡住）。
//
// 之前这里留着 Flutter 模板的 MyApp + 计数器断言，那个类早就不存在了，
// 每次 analyze 都报一个 error，等于把真正的错误淹掉。

import 'package:flutter_test/flutter_test.dart';

import 'package:sparkshell/main.dart';

void main() {
  testWidgets('根组件可构建，底部 5 个入口齐全', (WidgetTester tester) async {
    await tester.pumpWidget(const SparkShellApp());
    expect(find.text('Linux'), findsOneWidget);
    expect(find.text('Chat'), findsOneWidget);
    expect(find.text('文件'), findsOneWidget);
    expect(find.text('SSH'), findsOneWidget);
    expect(find.text('远程'), findsOneWidget);
  });
}

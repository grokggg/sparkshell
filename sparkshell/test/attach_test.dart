// 附件链路的真跑测试：通道 mock 成原生，但走的是产品代码本身。
//
// 为什么不做 UI 截图式测试：这里要守住的是"选到的东西到底进没进消息"，
// 不是像素。真正的像素问题（弹层长得丑）在真机上看一眼比断言框位置靠谱。

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sparkshell/chat/attach.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final TestDefaultBinaryMessenger messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const MethodChannel io = MethodChannel('com.xinghuo.sparkshell/io');

  tearDown(() => messenger.setMockMethodCallHandler(io, null));

  group('composeWithAttachments', () {
    test('没有附件时原样返回，不产生空行', () {
      expect(composeWithAttachments('帮我看看', const []), '帮我看看');
      expect(composeWithAttachments('', const []), '');
    });

    test('一句话 + 一张图：正文在前，路径在后', () {
      final out = composeWithAttachments('这图里的报错什么意思', ['/root/inbox/a.jpg']);
      expect(out.startsWith('这图里的报错什么意思'), isTrue);
      expect(out, contains('/root/inbox/a.jpg'));
      expect(out, contains('附件已放进容器'));
    });

    test('只发附件不写字：不留下开头的空行', () {
      final out = composeWithAttachments('', ['/root/inbox/a.jpg', '/root/inbox/b.png']);
      expect(out.startsWith('\n'), isFalse);
      expect(out, contains('/root/inbox/a.jpg'));
      expect(out, contains('/root/inbox/b.png'));
    });

    test('多份附件逐行列出，模型能一次拿全', () {
      final out = composeWithAttachments('都打开', [
        '/root/inbox/1.pdf',
        '/root/inbox/2.zip',
        '/root/inbox/3.mp3',
      ]);
      expect(out.split('\n').where((l) => l.startsWith('- ')).length, 3);
    });
  });

  group('AttachmentPicker 走原生通道', () {
    test('images() 调 pickImages，返回容器路径', () async {
      var called = '';
      messenger.setMockMethodCallHandler(io, (call) async {
        called = call.method;
        return <String>['/root/inbox/IMG_001.jpg'];
      });

      final got = await AttachmentPicker.images();
      expect(called, 'pickImages');
      expect(got, ['/root/inbox/IMG_001.jpg']);
      expect(AttachmentPicker.inboxDir, '/root/inbox');
    });

    test('files() 调 pickFiles，用户取消返回空表而不是抛异常', () async {
      var called = '';
      messenger.setMockMethodCallHandler(io, (call) async {
        called = call.method;
        return null; // 原生取消时可能回 null
      });

      final got = await AttachmentPicker.files();
      expect(called, 'pickFiles');
      expect(got, isEmpty);
    });

    test('原生报错翻成人话，而不是把 code 怼到用户脸上', () async {
      messenger.setMockMethodCallHandler(io, (call) async {
        throw PlatformException(code: 'import_failed', message: '复制图片到容器失败：空间不足');
      });

      expect(
        () => AttachmentPicker.images(),
        throwsA(isA<AttachmentPickerException>().having(
          (e) => e.message,
          'message',
          contains('空间不足'),
        )),
      );
    });
  });
}

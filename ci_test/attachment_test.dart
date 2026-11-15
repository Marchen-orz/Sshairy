import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/features/ai/domain/attachment.dart';

void main() {
  test('text attachments keep their content and reject executable names', () {
    final attachment = AgentAttachment.text(id: 'a1', name: 'notes.txt', text: 'hello');
    expect(attachment.bytes, 5);
    expect(attachment.description, {'id': 'a1', 'name': 'notes.txt', 'mediaType': 'text/plain', 'bytes': 5});
    expect(() => AgentAttachment.text(id: 'a2', name: 'notes/evil.txt', text: 'x'), throwsFormatException);
    expect(() => AgentAttachment.text(id: 'a3', name: '', text: 'x'), throwsFormatException);
    expect(() => AgentAttachment.text(id: '../a4', name: 'ok.txt', text: 'x'), throwsFormatException);
  });

  test('known secrets and control bytes are refused', () {
    const secrets = [
      'password = hunter2',
      'API_TOKEN=abcdef',
      '-----BEGIN OPENSSH PRIVATE KEY-----',
      'Authorization: Bearer abc.def.ghi',
    ];
    for (final text in secrets) {
      expect(() => AgentAttachment.text(id: 's', name: 'a.txt', text: text), throwsFormatException, reason: text);
    }
    expect(() => AgentAttachment.text(id: 'c', name: 'a.txt', text: 'a\u0001b'), throwsFormatException);
  });

  test('the combined list refuses duplicate ids and oversized counts', () {
    final one = AgentAttachment.text(id: 'same', name: 'a.txt', text: 'a');
    expect(() => checkedAgentAttachments([one, one]), throwsFormatException);
    expect(
      () => checkedAgentAttachments([
        for (var i = 0; i <= AgentAttachmentLimits.count; i++)
          AgentAttachment.text(id: 'id$i', name: 'a.txt', text: 'a'),
      ]),
      throwsFormatException,
    );
  });
}

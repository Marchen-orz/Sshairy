import 'dart:convert';

class Snippet {
  Snippet({required this.id, required this.label, required this.text, List<String> tags = const []})
    : tags = List.unmodifiable(tags);

  final String id, label, text;
  final List<String> tags;

  void validate() {
    if (id.isEmpty || label.trim().isEmpty || text.isEmpty || utf8.encode(text).length > 65536) {
      throw ArgumentError('snippet');
    }
  }

  bool matches(String query) => query
      .toLowerCase()
      .split(RegExp(r'\s+'))
      .every((word) => '$label $text ${tags.join(' ')}'.toLowerCase().contains(word));

  Map<String, Object?> toJson() => {'id': id, 'label': label, 'text': text, 'tags': tags};

  factory Snippet.fromJson(Map<String, dynamic> json) {
    final snippet = Snippet(
      id: json['id'] as String,
      label: json['label'] as String,
      text: json['text'] as String,
      tags: (json['tags'] as List<dynamic>? ?? const []).cast<String>(),
    );
    snippet.validate();
    return snippet;
  }
}

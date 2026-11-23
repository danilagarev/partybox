import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class TruthSources extends StatelessWidget {
  const TruthSources({super.key, required this.sources});

  final List<({String title, String url})> sources;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      for (final source in sources)
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(source.title),
          subtitle: Text(Uri.parse(source.url).host),
          trailing: IconButton(
            tooltip: 'Скопировать ссылку на источник',
            icon: const Icon(Icons.content_copy),
            onPressed: () async {
              try {
                await Clipboard.setData(ClipboardData(text: source.url));
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Ссылка скопирована')),
                  );
                }
              } on PlatformException {
                if (context.mounted) {
                  await showDialog<void>(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: Text(source.title),
                      content: SelectableText(source.url),
                    ),
                  );
                }
              }
            },
          ),
        ),
    ],
  );
}

import 'package:flutter/material.dart';

/// The same neutral prompts for every pack and role; never reads session data.
class SpyQuestionHelp extends StatelessWidget {
  const SpyQuestionHelp({super.key});

  @override
  Widget build(BuildContext context) => TextButton.icon(
    icon: const Icon(Icons.chat_bubble_outline_rounded),
    label: const Text('О чём спросить?'),
    onPressed: () => showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: const Text('Начните с простого'),
        content: const Text(
          '• Что здесь обычно слышно?\n\n'
          '• Что ты взял бы с собой?\n\n'
          '• Здесь хочется задержаться или скорее уйти?\n\n'
          '• Что здесь было бы странно увидеть?\n\n'
          'Не называйте место и не задавайте слишком точные вопросы. '
          'После ответа передайте вопрос другому игроку.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Продолжить обсуждение'),
          ),
        ],
      ),
    ),
  );
}

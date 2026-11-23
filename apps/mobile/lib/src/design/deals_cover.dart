import 'package:flutter/material.dart';

class DealsCover extends StatelessWidget {
  const DealsCover({super.key});

  @override
  Widget build(BuildContext context) => Image.asset(
    'assets/images/deals-cover.webp',
    fit: BoxFit.cover,
    excludeFromSemantics: true,
  );
}

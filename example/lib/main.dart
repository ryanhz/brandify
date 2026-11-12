import 'package:flutter/foundation.dart';
// Flutter 3.47+ moves Material to package:material_ui, but brandify supports Flutter
// 3.35.3 and newer, so the example keeps the import that works on all of them.
// ignore: deprecated_member_use
import 'package:flutter/material.dart';

void main() => runApp(const BrandifyExampleApp());

/// Root widget, exposed so integration tests can pump it directly.
class BrandifyExampleApp extends StatelessWidget {
  const BrandifyExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Acme Tasks',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF2E5BFF)),
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  static const _tasks = [
    ('Plan sprint', 'Today · 09:30', true),
    ('Review designs', 'Today · 11:00', false),
    ('Ship release 2.4', 'Tomorrow', false),
    ('Write changelog', 'Fri', false),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Acme Tasks')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Good morning', style: Theme.of(context).textTheme.headlineMedium),
          const SizedBox(height: 16),
          const FocusChart(),
          const SizedBox(height: 16),
          for (final (title, due, done) in _tasks)
            Card(
              child: CheckboxListTile(
                value: done,
                onChanged: (_) {},
                title: Text(title),
                subtitle: Text(due),
              ),
            ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('add_task'),
        onPressed: () => Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => const AddTaskPage()),
        ),
        icon: const Icon(Icons.add),
        label: const Text('New task'),
      ),
    );
  }
}

/// Keep in sync with MainActivity.kt and AppDelegate.swift.
const focusChartViewType = 'brandify_example/focus_chart';

/// A weekly chart drawn by the platform (Android Canvas, UIKit Core
/// Graphics), embedded as a PlatformView. It's here to show what brandify
/// captures and widget-test renderers can't: they have no platform views,
/// so this card comes out blank there.
class FocusChart extends StatelessWidget {
  const FocusChart({super.key});

  @override
  Widget build(BuildContext context) {
    final Widget view = switch (defaultTargetPlatform) {
      TargetPlatform.android => const AndroidView(viewType: focusChartViewType),
      TargetPlatform.iOS => const UiKitView(viewType: focusChartViewType),
      _ => const Center(child: Text('Native chart: Android and iOS only')),
    };
    return SizedBox(height: 190, child: view);
  }
}

class AddTaskPage extends StatelessWidget {
  const AddTaskPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('New task')),
      body: const Padding(
        padding: EdgeInsets.all(16),
        child: TextField(
          decoration: InputDecoration(labelText: 'Title', border: OutlineInputBorder()),
        ),
      ),
    );
  }
}

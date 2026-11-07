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

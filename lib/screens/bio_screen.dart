// lib/screens/bio_screen.dart (new)
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

class BioScreen extends StatefulWidget {
  final String userId;
  const BioScreen({super.key, required this.userId});

  @override
  State<BioScreen> createState() => _BioScreenState();
}

class _BioScreenState extends State<BioScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _nationalityController = TextEditingController();
  final _passportController = TextEditingController();
  final _tripStartController = TextEditingController();
  final _tripEndController = TextEditingController();
  bool _isLoading = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Complete Profile')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Form(
          key: _formKey,
          child: Column(
            children: [
              TextFormField(
                controller: _nameController,
                decoration: const InputDecoration(labelText: 'Name'),
                validator: (value) =>
                    value?.isEmpty ?? true ? 'Required' : null,
              ),
              TextFormField(
                controller: _nationalityController,
                decoration: const InputDecoration(labelText: 'Nationality'),
                validator: (value) =>
                    value?.isEmpty ?? true ? 'Required' : null,
              ),
              TextFormField(
                controller: _passportController,
                decoration: const InputDecoration(labelText: 'Passport'),
                validator: (value) =>
                    value?.isEmpty ?? true ? 'Required' : null,
              ),
              TextFormField(
                controller: _tripStartController,
                decoration: const InputDecoration(
                  labelText: 'Trip Start (YYYY-MM-DD)',
                ),
                validator: (value) =>
                    value?.isEmpty ?? true ? 'Required' : null,
              ),
              TextFormField(
                controller: _tripEndController,
                decoration: const InputDecoration(
                  labelText: 'Trip End (YYYY-MM-DD)',
                ),
                validator: (value) =>
                    value?.isEmpty ?? true ? 'Required' : null,
              ),
              const SizedBox(height: 20),
              ElevatedButton(
                onPressed: _isLoading ? null : _save,
                child: _isLoading
                    ? const CircularProgressIndicator()
                    : const Text('Save'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _isLoading = true);
    final random = Random();
    final id =
        'SIH${DateTime.now().year}${random.nextInt(10000).toString().padLeft(4, '0')}';
    await FirebaseFirestore.instance
        .collection('users')
        .doc(widget.userId)
        .set({
          'name': _nameController.text,
          'nationality': _nationalityController.text,
          'passport': _passportController.text,
          'trip_start': _tripStartController.text,
          'trip_end': _tripEndController.text,
          'id': id,
        });
    setState(() => _isLoading = false);
    if (mounted) {
      Navigator.pushReplacementNamed(
        context,
        '/home',
      ); // Adjust route if needed
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _nationalityController.dispose();
    _passportController.dispose();
    _tripStartController.dispose();
    _tripEndController.dispose();
    super.dispose();
  }
}

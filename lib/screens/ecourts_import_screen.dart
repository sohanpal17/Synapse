import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart';
import '../main.dart';
import '../providers/providers.dart';
import '../services/ecourts_import_service.dart';

class EcourtsImportScreen extends ConsumerStatefulWidget {
  const EcourtsImportScreen({super.key});
  @override
  ConsumerState<EcourtsImportScreen> createState() => _EcourtsImportScreenState();
}

class _EcourtsImportScreenState extends ConsumerState<EcourtsImportScreen> {
  bool _importing = false;
  EcourtsImportResult? _result;
  String? _error;

  Future<void> _pickAndImport() async {
    final user = ref.read(currentUserProvider);
    if (user == null) return;

    try {
      final picked = await FilePicker.platform.pickFiles(
        type: FileType.any,
        withData: true, // Required for web — loads bytes into memory
      );
      if (picked == null || picked.files.isEmpty) return;

      final file = picked.files.first;
      if (file.bytes == null) {
        setState(() => _error = 'Could not read file data');
        return;
      }

      setState(() {
        _importing = true;
        _error = null;
        _result = null;
      });

      final cases = await EcourtsImportService.parseBytes(file.bytes!);
      debugPrint('eCourts parse: ${cases.length} cases found in file');

      if (cases.isEmpty) {
        setState(() {
          _importing = false;
          _error = 'No cases found in file.';
        });
        return;
      }

      final result = await EcourtsImportService.importCases(cases);
      debugPrint('eCourts import done: ${result.newCases} new, ${result.updated} updated, ${result.errors} errors');
      ref.read(casesProvider.notifier).refresh();

      setState(() {
        _importing = false;
        _result = result;
      });
    } catch (e) {
      debugPrint('eCourts import error: $e');
      setState(() {
        _importing = false;
        _error = 'Import failed: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(20, 60, 20, 20),
            color: AppColors.primary,
            child: Row(children: [
              GestureDetector(
                onTap: () => Navigator.pop(context),
                child: const Icon(Icons.arrow_back, color: AppColors.white),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Text('Import from eCourts',
                    style: TextStyle(
                        color: AppColors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.w600)),
              ),
            ]),
          ),
          Expanded(
            child: Center(
              child: _importing
                  ? const CircularProgressIndicator()
                  : Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        if (_result != null) ...[
                          const Icon(Icons.check_circle,
                              color: AppColors.success, size: 64),
                          const SizedBox(height: 16),
                          Text(
                              'Imported ${_result!.total} cases\n'
                              '${_result!.newCases} new · ${_result!.updated} updated'
                              '${_result!.errors > 0 ? ' · ${_result!.errors} errors' : ''}',
                              textAlign: TextAlign.center,
                              style: const TextStyle(fontSize: 18)),
                        ],
                        if (_error != null)
                          Text(_error!,
                              style: const TextStyle(color: AppColors.error)),
                        const SizedBox(height: 24),
                        ElevatedButton(
                          onPressed: _pickAndImport,
                          child: const Text('Select File'),
                        ),
                      ],
                    ),
            ),
          ),
        ],
      ),
    );
  }
}
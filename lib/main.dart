import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'dart:typed_data';
import 'services/comic_parser_service.dart';
import 'screens/comic_reader_screen.dart';

void main() {
  runApp(const PanelShiftApp());
}

class PanelShiftApp extends StatelessWidget {
  const PanelShiftApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PanelShift Core',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.deepPurple,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
        brightness: Brightness.dark,
      ),
      home: const ComicProcessorScreen(title: 'PanelShift Core Engine'),
    );
  }
}

/// ==========================================
/// 1. File Picker & Archive Loader Screen
/// ==========================================
class ComicProcessorScreen extends StatefulWidget {
  const ComicProcessorScreen({super.key, required this.title});

  final String title;

  @override
  State<ComicProcessorScreen> createState() => _ComicProcessorScreenState();
}

class _ComicProcessorScreenState extends State<ComicProcessorScreen> {
  String _statusMessage = 'Ready to process digital comic archives.';
  bool _isProcessing = false;
  int _extractedPageCount = 0;

  Future<void> _pickAndProcessComic() async {
    setState(() {
      _isProcessing = true;
      _statusMessage = 'Opening file manager...';
      _extractedPageCount = 0;
    });

    try {
      List<PlatformFile> files = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['cbz', 'zip'],
      );

      if (files.isEmpty || files.single.path == null) {
        setState(() {
          _statusMessage = 'File selection cancelled.';
        });
        return;
      }

      final filePath = files.single.path!;
      setState(() {
        _statusMessage = 'Extracting comic archive pages...';
      });

      final List<Uint8List> pages = await ComicParserService.extractCbzPages(filePath);

      if (pages.isEmpty) {
        setState(() {
          _statusMessage = 'No valid image pages found in archive.';
        });
        return;
      }

      setState(() {
        _extractedPageCount = pages.length;
        _statusMessage = 'Successfully extracted $_extractedPageCount pages!';
      });

      if (mounted) {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => ComicReaderScreen(pageBytes: pages),
          ),
        );
      }
    } catch (e) {
      setState(() {
        _statusMessage = 'Error unpacking archive: $e';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isProcessing = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: Text(widget.title),
      ),
      body: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Icon(Icons.menu_book, size: 80, color: Colors.deepPurple),
            const SizedBox(height: 24),
            Text(
              _statusMessage,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 16),
            ),
            if (_extractedPageCount > 0) ...[
              const SizedBox(height: 12),
              Text(
                'Total Pages Loaded: $_extractedPageCount',
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.green),
              ),
            ],
            const SizedBox(height: 32),
            ElevatedButton.icon(
              onPressed: _isProcessing ? null : _pickAndProcessComic,
              icon: const Icon(Icons.folder_open),
              label: const Text('Select & Process Comic Archive (.cbz)'),
            ),
          ],
        ),
      ),
    );
  }
}
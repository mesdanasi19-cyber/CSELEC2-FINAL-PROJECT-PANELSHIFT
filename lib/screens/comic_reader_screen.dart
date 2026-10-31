import 'dart:typed_data';
import 'package:flutter/material.dart';

class ComicReaderScreen extends StatelessWidget {
  final List<Uint8List> pageBytes;

  const ComicReaderScreen({super.key, required this.pageBytes});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black.withOpacity(0.7),
        title: const Text('PanelShift Reader', style: TextStyle(color: Colors.white)),
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: PageView.builder(
        itemCount: pageBytes.length,
        itemBuilder: (context, index) {
          return Center(
            child: InteractiveViewer(
              // Allows pinching and zooming on individual comic panels
              minScale: 1.0,
              maxScale: 4.0,
              child: Image.memory(
                pageBytes[index],
                fit: BoxFit.contain,
                errorBuilder: (context, error, stackTrace) {
                  return const Center(
                    child: Text(
                      'Error loading page',
                      style: TextStyle(color: Colors.red),
                    ),
                  );
                },
              ),
            ),
          );
        },
      ),
    );
  }
}
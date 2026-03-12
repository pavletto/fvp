// Copyright 2022-2026 Wang Bin. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// ignore_for_file: public_member_api_docs

/// Example: Playing video from raw bytes using Player.appendBuffer()
///
/// This demonstrates how to feed raw bytes directly to the FVP player
/// instead of a URL or file path. This is useful when:
/// - You receive video data from a custom source (e.g. a socket, pipe, etc.)
/// - You have video data already loaded in memory as a byte array
/// - You want to play video without writing it to disk first
///
/// How it works:
/// 1. Set player.media = 'mdkbuf://identifier' to enable buffer-based input.
///    The identifier after :// is an arbitrary label string.
/// 2. Set player state to playing and start feeding data via appendBuffer().
/// 3. When all data has been fed, signal end-of-stream with flags: 1.
///
/// For real-time / live H.264 streams (Annex-B byte-stream format) with the
/// lowest possible end-to-end latency, see realtime_h264_example.dart which
/// also documents the recommended player configuration for that use-case.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:fvp/fvp.dart' as fvp;
import 'package:fvp/mdk.dart' as mdk;

void main() {
  fvp.registerWith();
  runApp(const MaterialApp(
    title: 'FVP Bytes Example',
    home: BytesPlayerExample(),
  ));
}

/// A sample video URL used to download bytes into memory for demonstration.
/// Any playable media URL can be used here.
const String _sampleVideoUrl =
    'https://flutter.github.io/assets-for-api-docs/assets/videos/bee.mp4';

class BytesPlayerExample extends StatefulWidget {
  const BytesPlayerExample({super.key});

  @override
  State<BytesPlayerExample> createState() => _BytesPlayerExampleState();
}

class _BytesPlayerExampleState extends State<BytesPlayerExample> {
  late mdk.Player _player;
  String _status = 'Idle';
  bool _textureReady = false;

  @override
  void initState() {
    super.initState();
    _player = mdk.Player();
    _loadAndPlay();
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  /// Downloads video bytes from the network, then feeds them to the player
  /// via [mdk.Player.appendBuffer].
  Future<void> _loadAndPlay() async {
    setState(() => _status = 'Downloading video into memory...');
    try {
      final bytes = await _downloadToBytes(_sampleVideoUrl);
      setState(() => _status = 'Downloaded ${bytes.length} bytes. Preparing...');

      // Use the special mdkbuf:// URL scheme to tell the player to expect
      // data fed via appendBuffer() rather than reading from a file or URL.
      _player.media = 'mdkbuf://memory';
      _player.state = mdk.PlaybackState.playing;

      // Start feeding bytes to the player in the background while prepare()
      // waits for the first frame to be decoded.
      final feedFuture = _feedBytes(bytes);
      final pos = await _player.prepare();

      if (pos < 0) {
        setState(() => _status = 'Error: failed to prepare player (code: $pos)');
        return;
      }

      // Create the Flutter texture for rendering.
      await _player.updateTexture();

      setState(() {
        _textureReady = true;
        _status = 'Playing from ${bytes.length} bytes in memory';
      });

      // Ensure all bytes have been fully fed before completing.
      await feedFuture;
    } catch (e) {
      setState(() => _status = 'Error: $e');
    }
  }

  /// Feeds [bytes] to the player in chunks via [mdk.Player.appendBuffer].
  ///
  /// [appendBuffer] may return `false` when the internal buffer is full;
  /// in that case the same chunk is retried after a short delay.
  Future<void> _feedBytes(Uint8List bytes) async {
    const int chunkSize = 64 * 1024; // 64 KB per chunk
    int offset = 0;

    while (offset < bytes.length) {
      final end = (offset + chunkSize).clamp(0, bytes.length);
      final chunk = bytes.sublist(offset, end);

      // Retry if the player's internal buffer is temporarily full.
      while (!_player.appendBuffer(chunk)) {
        await Future.delayed(const Duration(milliseconds: 10));
      }

      offset = end;
    }

    // Signal end-of-stream so the player knows no more data is coming.
    _player.appendBuffer(Uint8List(0), flags: 1);
  }

  /// Downloads the content at [url] and returns it as a [Uint8List].
  Future<Uint8List> _downloadToBytes(String url) async {
    final client = HttpClient();
    try {
      final request = await client.getUrl(Uri.parse(url));
      final response = await request.close();
      final builder = BytesBuilder();
      await for (final chunk in response) {
        builder.add(chunk);
      }
      return builder.toBytes();
    } finally {
      client.close();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Play from Bytes')),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Text(
                _status,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
            const SizedBox(height: 16),
            if (_textureReady)
              AspectRatio(
                aspectRatio: 16 / 9,
                child: ValueListenableBuilder<int?>(
                  valueListenable: _player.textureId,
                  builder: (context, id, _) {
                    if (id == null) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    return Texture(textureId: id);
                  },
                ),
              )
            else
              const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  icon: const Icon(Icons.play_arrow),
                  tooltip: 'Play',
                  onPressed: () {
                    _player.state = mdk.PlaybackState.playing;
                  },
                ),
                IconButton(
                  icon: const Icon(Icons.pause),
                  tooltip: 'Pause',
                  onPressed: () {
                    _player.state = mdk.PlaybackState.paused;
                  },
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

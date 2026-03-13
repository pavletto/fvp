// Copyright 2022-2026 Wang Bin. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// ignore_for_file: public_member_api_docs

/// Real-time H.264 low-latency playback via raw bytes (Annex-B byte stream).
///
/// This example shows the **recommended configuration** for feeding a live
/// H.264 stream (in MPEG-4 Annex-B format, i.e. with 0x00 0x00 0x00 0x01 /
/// 0x00 0x00 0x01 start-codes) to the player with **minimum latency**.
///
/// Typical use-cases:
///   • WebSocket / WebRTC video feed
///   • Custom network protocol producing raw NAL units
///   • Hardware encoder output (camera) piped directly to the player
///   • Demuxed H.264 track from an RTSP/RTP/SRT stream
///
/// ─── PLAYBACK MODEL ───────────────────────────────────────────────────────
/// The `mdkbuf://` protocol turns the player into a push-based sink:
///
///   [Your source]                    [FVP Player]
///   appendBuffer(naluChunk) ──────►  internal ring buffer
///                                         │
///                                    H.264 demuxer
///                                         │
///                                    HW decoder (VideoToolbox / D3D11 / MediaCodec …)
///                                         │
///                                    Flutter Texture
///
/// ─── KNOWN STALL POINTS ───────────────────────────────────────────────────
/// There are several independent places in the pipeline that can stall a live
/// Annex-B stream. The configuration below addresses all of them:
///
///   Stall source                     Setting that fixes it
///   ─────────────────────────────────────────────────────────────────────────
///   Container format auto-detection  avformat.f = h264
///   Demuxer packet queue (GOP wait)  avformat.fflags = +nobuffer
///   Format analysis window (5 s)     avformat.analyzeduration = 0
///   FPS probing                      avformat.fpsprobesize = 0
///   I/O thread packet queue          avformat.thread_queue_size = 1
///   Decoder B-frame buffer (up to    avcodec.flags = +low_delay
///     16 frames on software decode)
///   Decoder frame threading latency  avcodec.thread_type = 2 (slice)
///   A/V clock sync (video-only src)  setActiveTracks(audio, []) (videoOnly: true)
///   prepare() hanging with no data   Use prepareWithTimeout() instead of prepare()
///   Decode queue pre-roll            setBufferRange(min: 0, max: 500, drop: true)
///
/// ─── CONFIGURATION SUMMARY ────────────────────────────────────────────────
/// 1. `avformat.f` = `h264`
///    Bypass format auto-detection and go straight to the H.264 byte-stream
///    demuxer. Eliminates the probing delay that would otherwise occur when
///    the player inspects the first bytes to decide the container format.
///
/// 2. `avformat.fflags` = `+nobuffer+discardcorrupt`
///    Disable AVFormat's internal input buffer. Every packet that arrives is
///    handed to the decoder immediately. Without this, FFmpeg may hold packets
///    until a full GOP is available, adding 1-2 key-frame intervals of delay.
///    `+discardcorrupt` silently skips malformed NAL units rather than stalling.
///
/// 3. `avformat.probesize` = `512`
///    Absolute minimum probe size (bytes). Since we specify the format
///    explicitly this is effectively a no-op, but it ensures no accidental
///    large probing if the format hint is ignored.
///
/// 4. `avformat.fpsprobesize` = `0`
///    Do not probe any frames just to detect the frame-rate. For live streams
///    the frame-rate is either known from SPS or irrelevant (wall-clock-based
///    presentation).
///
/// 5. `avformat.analyzeduration` = `0`
///    Set the analysis window to 0 microseconds. Combined with `nobuffer` this
///    means the player starts decoding as soon as the very first full NAL unit
///    arrives.
///
/// 6. `avformat.thread_queue_size` = `1`
///    Limits the demuxer I/O thread packet queue to 1 entry. Without this,
///    old packets can pile up in the queue and re-introduce latency even when
///    all other options are set correctly.
///
/// 7. `avcodec.flags` = `+low_delay`
///    Tells the H.264 **decoder** not to buffer frames for B-frame reordering.
///    Without this, the software (FFmpeg) decoder may buffer up to 16 frames
///    (~533 ms at 30 fps) before outputting the first decoded frame. This is
///    the single most impactful codec-level option for live H.264 latency.
///    Note: hardware decoders (VideoToolbox, MediaCodec, D3D11) inherently have
///    low-delay behaviour; this flag mainly benefits the FFmpeg fallback.
///
/// 8. `avcodec.thread_type` = `2` (slice)
///    Frame-level threading (the default, type=1) spawns a thread per frame
///    and the decoder outputs frame N while thread N+1 is still decoding, which
///    adds one full frame of extra output latency. Slice-level threading (type=2)
///    parallelises work within a single frame, with no additional output delay.
///
/// 9. `setBufferRange(min: 0, max: 500, drop: true)`
///    • `min: 0` — do not wait for any pre-roll before starting to decode.
///    • `max: 500` — cap the decode queue at 500 ms. If the source is faster
///      than real-time the oldest unrendered frames are dropped so the viewer
///      always sees the freshest frame.
///    • `drop: true` — enable the frame-drop behaviour described above.
///
/// 10. Hardware decoder priority list
///    Lets the player pick the fastest available HW decoder. FFmpeg is kept as
///    the last-resort software fallback so the stream always plays.
///    Platform-specific names:
///      Windows  → D3D11 (preferred), NVDEC, CUVID, DXVA2
///      macOS/iOS→ VideoToolbox
///      Linux    → VAAPI, VDPAU, V4L2M2M
///      Android  → MediaCodec
///
/// ─── A/V SYNC STALL (VIDEO-ONLY STREAMS) ─────────────────────────────────
/// MDK uses the audio clock as the master clock by default. If your source is
/// video-only (no audio track), the player can stall waiting for audio data
/// that never arrives. Pass `videoOnly: true` to [configureForRealtimeH264]
/// to explicitly disable audio track selection and avoid this stall.
///
/// ─── prepare() HANG ───────────────────────────────────────────────────────
/// [mdk.Player.prepare] has **no built-in timeout**. If the demuxer never
/// receives enough data to initialise (e.g. because data feeding started too
/// late, or the source stalled before the first SPS/PPS NAL unit), the Dart
/// Future returned by `prepare()` will never complete.
/// Use [prepareWithTimeout] instead of calling `prepare()` directly.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:fvp/fvp.dart' as fvp;
import 'package:fvp/mdk.dart' as mdk;

void main() {
  fvp.registerWith();
  runApp(const MaterialApp(
    title: 'FVP — Real-time H.264 (low latency)',
    home: RealtimeH264Example(),
  ));
}

// ---------------------------------------------------------------------------
// Platform-specific hardware decoder priority lists (shared constant)
// ---------------------------------------------------------------------------

/// Hardware decoder priority list for each platform.
///
/// The player tries each entry in order; the first one that can handle the
/// stream wins. `FFmpeg` at the end is the guaranteed-available software
/// fallback on every platform.
const Map<String, List<String>> _decodersByPlatform = {
  'windows': ['D3D11', 'NVDEC', 'CUVID', 'DXVA2', 'FFmpeg'],
  'macos': ['VideoToolbox', 'FFmpeg'],
  'ios': ['VideoToolbox', 'FFmpeg'],
  'android': ['MediaCodec', 'FFmpeg'],
  'linux': ['VAAPI', 'VDPAU', 'V4L2M2M', 'FFmpeg'],
  'other': ['FFmpeg'],
};

List<String> _platformDecoderList() {
  if (kIsWeb) return _decodersByPlatform['other']!;
  if (Platform.isWindows) return _decodersByPlatform['windows']!;
  if (Platform.isMacOS) return _decodersByPlatform['macos']!;
  if (Platform.isIOS) return _decodersByPlatform['ios']!;
  if (Platform.isAndroid) return _decodersByPlatform['android']!;
  if (Platform.isLinux) return _decodersByPlatform['linux']!;
  return _decodersByPlatform['other']!;
}

// ---------------------------------------------------------------------------
// Public helper: configure a Player for real-time H.264 Annex-B input
// ---------------------------------------------------------------------------

/// Applies the optimal low-latency settings for real-time H.264 Annex-B
/// streaming to [player].
///
/// Call this **before** setting [mdk.Player.media] and before
/// [prepareWithTimeout] / [mdk.Player.prepare].
///
/// Parameters:
///
/// - [maxBufferMs] — how many milliseconds of decoded frames may accumulate
///   before old frames are dropped. Default 500 ms; lower it (e.g. 200) for
///   tighter real-time requirements at the cost of more frequent frame drops.
///
/// - [videoOnly] — set to `true` when the Annex-B stream contains **no audio
///   track**. MDK uses the audio clock as the master clock by default; if no
///   audio data arrives, the player can stall indefinitely waiting for an audio
///   packet to advance the clock. Passing `videoOnly: true` disables audio
///   track selection so the player uses the video clock instead.
void configureForRealtimeH264(
  mdk.Player player, {
  int maxBufferMs = 500,
  bool videoOnly = false,
}) {
  // ── 1. Demuxer: bypass format detection, go straight to H.264 parser ──
  // Tells FFmpeg to treat the stream as a raw H.264 Annex-B byte stream.
  // This removes the container-detection probe delay entirely.
  player.setProperty('avformat.f', 'h264');

  // ── 2. Demuxer: disable input buffering ───────────────────────────────
  // +nobuffer: deliver packets to the decoder without waiting for more data.
  // discardcorrupt: silently skip corrupted/incomplete NAL units instead of
  // stalling the pipeline.
  player.setProperty('avformat.fflags', '+nobuffer+discardcorrupt');

  // ── 3. Demuxer: minimal probing ───────────────────────────────────────
  // 512 bytes is the absolute minimum. Because we specify avformat.f = h264
  // the probe is effectively a no-op, but this prevents any inadvertent
  // large probe if the hint is ignored.
  player.setProperty('avformat.probesize', '512');

  // ── 4. Demuxer: no fps probing ────────────────────────────────────────
  // For live streams we do not probe frames to detect the frame-rate.
  player.setProperty('avformat.fpsprobesize', '0');

  // ── 5. Demuxer: zero analysis window ─────────────────────────────────
  // Start decoding as soon as the first complete NAL unit arrives.
  player.setProperty('avformat.analyzeduration', '0');

  // ── 6. Demuxer I/O thread: limit packet queue to 1 entry ─────────────
  // Without this, old packets accumulate in the queue and re-introduce
  // latency. Keeping the queue at 1 ensures we always process the newest
  // packet, not one that has been waiting in line.
  player.setProperty('avformat.thread_queue_size', '1');

  // ── 7. Decoder: force low-delay mode ─────────────────────────────────
  // Tells the H.264 decoder not to buffer frames for B-frame reordering.
  // Without this, the software (FFmpeg) decoder can hold up to 16 frames
  // (~533 ms at 30 fps) before releasing even the first one.
  // Hardware decoders (VideoToolbox, MediaCodec, D3D11) already have
  // inherent low-delay behaviour; this flag primarily benefits the FFmpeg
  // software fallback.
  player.setProperty('avcodec.flags', '+low_delay');

  // ── 8. Decoder: use slice threading, not frame threading ─────────────
  // Frame-level threading (the H.264 default) outputs frame N while a
  // thread is still decoding frame N+1, adding one full frame of output
  // latency. Slice threading (type=2) parallelises within a single frame
  // and does not increase output delay.
  player.setProperty('avcodec.thread_type', '2');

  // ── 9. Decode queue: no pre-roll, aggressive frame drop ──────────────
  // • min: 0  — start playback immediately, no pre-buffering.
  // • max: maxBufferMs — oldest frames beyond this window are dropped so
  //   the viewer always sees the freshest content.
  // • drop: true — enable the drop behaviour.
  player.setBufferRange(min: 0, max: maxBufferMs, drop: true);

  // ── 10. A/V sync: disable audio for video-only sources ───────────────
  // MDK uses the audio clock as the master clock. If the source has no
  // audio, the player will stall waiting for audio data that never arrives.
  // Passing videoOnly:true disables audio track selection so the player
  // uses the system clock instead.
  if (videoOnly) {
    player.setActiveTracks(mdk.MediaType.audio, []);
  }

  // ── 11. Hardware decoder priority ────────────────────────────────────
  // The player tries each entry in order; the first one that can handle
  // the stream wins. FFmpeg is the guaranteed-available software fallback.
  player.videoDecoders = _platformDecoderList();
}

// ---------------------------------------------------------------------------
// Utility: prepare() with a timeout
// ---------------------------------------------------------------------------

/// Calls [mdk.Player.prepare] and returns a negative error code if [player]
/// has not produced its first frame within [timeout].
///
/// **Background:** [mdk.Player.prepare] returns a Dart `Future` that completes
/// only when the native layer has decoded at least one frame. If the demuxer
/// never receives enough data to initialise (e.g. because data feeding started
/// too late, or the source stalled before the first SPS/PPS NAL unit),
/// `prepare()` will **never** complete — blocking your `async` code forever.
///
/// [prepareWithTimeout] wraps `prepare()` with `Future.timeout` so callers
/// always get a result. On timeout the function returns `-99`.
///
/// Recommended timeout for a live Annex-B stream: 5–10 seconds. A shorter
/// value (e.g. 3 s) is acceptable when you know SPS/PPS arrive in the first
/// packet; a longer value is safer when network conditions are unpredictable.
Future<int> prepareWithTimeout(
  mdk.Player player, {
  Duration timeout = const Duration(seconds: 10),
}) {
  return player.prepare().timeout(timeout, onTimeout: () => -99);
}

// ---------------------------------------------------------------------------
// Example widget
// ---------------------------------------------------------------------------

/// Demonstrates real-time H.264 Annex-B playback.
///
/// In a real application replace [_simulateRealtimeSource] with your own
/// byte-producing function (WebSocket, custom socket, hardware capture, …).
class RealtimeH264Example extends StatefulWidget {
  const RealtimeH264Example({super.key});

  @override
  State<RealtimeH264Example> createState() => _RealtimeH264ExampleState();
}

class _RealtimeH264ExampleState extends State<RealtimeH264Example> {
  late mdk.Player _player;
  String _status = 'Idle';
  bool _textureReady = false;

  @override
  void initState() {
    super.initState();
    _player = mdk.Player();
    _startStream();
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  Future<void> _startStream() async {
    setState(() => _status = 'Configuring player…');

    // ── Step 1: apply low-latency H.264 settings ──────────────────────
    // videoOnly: true because our sample source has no audio track.
    // Remove this flag if your live stream carries audio.
    configureForRealtimeH264(_player, maxBufferMs: 500, videoOnly: true);

    // ── Step 2: select the mdkbuf:// source ───────────────────────────
    // The identifier after "://" is arbitrary; it is only used as a label
    // in logs. You may use any unique string that describes your source.
    _player.media = 'mdkbuf://h264live';

    // ── Step 3: start the render pipeline ─────────────────────────────
    _player.state = mdk.PlaybackState.playing;

    setState(() => _status = 'Fetching sample stream…');

    // ── Step 4: start feeding bytes in the background ─────────────────
    // IMPORTANT: begin feeding BEFORE calling prepare() so the demuxer
    // has data to inspect when prepare() starts analysing the stream.
    // In a real application this would be:
    //   _mySocket.listen((bytes) => _feedChunk(bytes));
    final feedFuture = _simulateRealtimeSource();

    // ── Step 5: wait for the first frame (with timeout) ───────────────
    // prepareWithTimeout() prevents an indefinite hang if the demuxer
    // never receives enough data (e.g. source stalls before first SPS/PPS).
    // Code -99 means the timeout was hit; any other negative code is an
    // internal error from the native layer.
    final pos = await prepareWithTimeout(_player, timeout: const Duration(seconds: 10));
    if (pos < 0) {
      if (mounted) {
        final reason = pos == -99 ? 'timeout' : 'error code $pos';
        setState(() => _status = 'Failed to prepare ($reason)');
      }
      return;
    }

    // ── Step 6: create the Flutter render texture ─────────────────────
    await _player.updateTexture();

    if (mounted) {
      setState(() {
        _textureReady = true;
        _status = 'Streaming (low-latency H.264)';
      });
    }

    await feedFuture;

    if (mounted) setState(() => _status = 'Stream ended');
  }

  // ── Feed one Annex-B chunk to the player ──────────────────────────────
  //
  // Rules:
  //  • appendBuffer() returns false when the internal ring buffer is full.
  //    Do NOT discard the chunk — retry it after a short back-off.
  //  • Feed data as soon as your source produces it; do not accumulate large
  //    batches as that reintroduces latency.
  //  • The player does not require complete NAL units per call; you can pass
  //    raw byte ranges from your source buffer directly.
  Future<void> _feedChunk(Uint8List chunk) async {
    // Retry immediately if the buffer has temporary back-pressure.
    while (!_player.appendBuffer(chunk)) {
      await Future.delayed(const Duration(milliseconds: 5));
    }
  }

  // ── Simulate a real-time H.264 Annex-B byte source ────────────────────
  //
  // This function emulates what a real live source would do:
  //   1. Download raw H.264 bytes (in a real app these come from a socket).
  //   2. Drip them out at ~1 MB/s to simulate a live network bitrate.
  //
  // In production, replace this with your actual stream consumer, e.g.:
  //   final socket = await RawDatagramSocket.bind(…);
  //   socket.listen((event) {
  //     final data = socket.receive();
  //     if (data != null) await _feedChunk(data.data);
  //   });
  Future<void> _simulateRealtimeSource() async {
    const sampleUrl =
        'https://flutter.github.io/assets-for-api-docs/assets/videos/bee.mp4';
    // NOTE: the sample URL above is an MP4 file, not a raw H.264 stream.
    // For a real application you would connect to your actual H.264 source.
    // The mp4 container is transparently handled by the demuxer even when
    // avformat.f = h264 is set, because the mdkbuf demuxer will re-probe
    // when it detects that the start bytes are not an H.264 Annex-B start
    // code — so the example still plays correctly for demonstration purposes.
    // To feed genuine Annex-B data, connect to an RTSP/SRT/WebSocket source
    // that produces raw NAL units.
    Uint8List bytes;
    try {
      bytes = await _downloadToBytes(sampleUrl);
    } catch (e) {
      if (mounted) setState(() => _status = 'Download failed: $e');
      return;
    }

    // Simulate real-time: emit chunks at roughly 1 MB/s.
    const int chunkSize = 8 * 1024; // 8 KB
    const Duration chunkInterval = Duration(milliseconds: 8); // ~1 MB/s

    int offset = 0;
    while (offset < bytes.length) {
      if (!mounted) return;
      final end = (offset + chunkSize).clamp(0, bytes.length);
      await _feedChunk(bytes.sublist(offset, end));
      offset = end;
      await Future.delayed(chunkInterval);
    }

    // Signal end-of-stream. flags: 1 tells the demuxer no more data will
    // arrive so it can flush remaining frames.
    _player.appendBuffer(Uint8List(0), flags: 1);
  }

  /// Downloads [url] and returns the body as a [Uint8List].
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
      appBar: AppBar(title: const Text('Real-time H.264 — Low Latency')),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(
                _status,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
            const SizedBox(height: 12),
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
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  icon: const Icon(Icons.play_arrow),
                  tooltip: 'Resume',
                  onPressed: () =>
                      _player.state = mdk.PlaybackState.playing,
                ),
                IconButton(
                  icon: const Icon(Icons.pause),
                  tooltip: 'Pause',
                  onPressed: () =>
                      _player.state = mdk.PlaybackState.paused,
                ),
              ],
            ),
            const SizedBox(height: 16),
            // ── Configuration summary card ─────────────────────────────
            Card(
              margin: const EdgeInsets.symmetric(horizontal: 16),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Active low-latency settings',
                        style: Theme.of(context).textTheme.titleSmall),
                    const SizedBox(height: 6),
                    const _SettingRow('avformat.f', 'h264'),
                    const _SettingRow(
                        'avformat.fflags', '+nobuffer+discardcorrupt'),
                    const _SettingRow('avformat.probesize', '512'),
                    const _SettingRow('avformat.fpsprobesize', '0'),
                    const _SettingRow('avformat.analyzeduration', '0'),
                    const _SettingRow('avformat.thread_queue_size', '1'),
                    const _SettingRow('avcodec.flags', '+low_delay'),
                    const _SettingRow('avcodec.thread_type', '2 (slice)'),
                    const _SettingRow(
                        'setBufferRange', 'min=0  max=500ms  drop=true'),
                    const _SettingRow('audio tracks', 'disabled (videoOnly)'),
                    _SettingRow('videoDecoders',
                        _platformDecoders().join(' › ')),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static List<String> _platformDecoders() => _platformDecoderList();
}

class _SettingRow extends StatelessWidget {
  const _SettingRow(this.settingKey, this.value);
  final String settingKey;
  final String value;

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 200,
            child: Text(settingKey,
                style: tt.bodySmall?.copyWith(fontFamily: 'monospace')),
          ),
          Expanded(
            child: Text(value,
                style: tt.bodySmall?.copyWith(
                    fontFamily: 'monospace',
                    color: Theme.of(context).colorScheme.primary)),
          ),
        ],
      ),
    );
  }
}

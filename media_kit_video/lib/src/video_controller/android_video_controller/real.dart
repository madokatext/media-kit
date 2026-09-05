/// This file is a part of media_kit (https://github.com/media-kit/media-kit).
///
/// Copyright © 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
/// All rights reserved.
/// Use of this source code is governed by MIT license that can be found in the LICENSE file.
import 'dart:io';
import 'dart:async';
import 'dart:collection';
import 'dart:convert' show jsonEncode;
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:synchronized/synchronized.dart';

import 'package:media_kit/media_kit.dart';

// ignore_for_file: implementation_imports
import 'package:media_kit/ffi/ffi.dart';

import 'package:media_kit_video/src/video_controller/platform_video_controller.dart';

/// {@template android_video_controller}
///
/// AndroidVideoController
/// ----------------------
///
/// The [PlatformVideoController] implementation based on native JNI & C/C++ used on Android.
///
/// {@endtemplate}
class AndroidVideoController extends PlatformVideoController {
  /// Whether [AndroidVideoController] is supported on the current platform or not.
  static bool get supported => Platform.isAndroid;

  /// Fixed width of the video output.
  int? width;

  /// Fixed height of the video output.
  int? height;

  int? _sourceWidth;
  int? _sourceHeight;
  int? _surfaceWidth;
  int? _surfaceHeight;
  bool _surfaceAttached = false;
  int _mediaEpoch = 0;
  bool _mediaActive = false;
  int _surfaceSizeGeneration = 0;
  int? _pendingMediaEpoch;
  int? _pendingSurfaceSizeGeneration;
  int? _pendingSurfaceWidth;
  int? _pendingSurfaceHeight;
  Completer<void> _currentMediaFirstFrameRendered = Completer<void>();
  int _diagnosticMediaGeneration = 0;
  final Stopwatch _diagnosticClock = Stopwatch()..start();
  int _layoutDiagnosticCount = 0;

  // Startup-only, release-enabled diagnostics. No stream URLs or headers.
  void _logStartup(String event, [Map<String, Object?> details = const {}]) {
    if (_diagnosticClock.elapsedMilliseconds > 20000) return;
    try {
      // Dragging layouts can call setSize every frame. Preserve all rejection
      // and cancellation events while bounding verbose layout diagnostics.
      if (event.startsWith('set_size.') || event == 'video_params') {
        if (_layoutDiagnosticCount++ >= 24) return;
      }
      debugPrintSynchronously('[PiliPlusStartup] ${jsonEncode({
        'layer': 'surface',
        'event': event,
        'time': DateTime.now().toIso8601String(),
        'handle': player.handle.toString(),
        'mediaGeneration': _diagnosticMediaGeneration,
        'mediaEpoch': _mediaEpoch,
        'mediaActive': _mediaActive,
        'pendingMediaEpoch': _pendingMediaEpoch,
        'elapsedMs': _diagnosticClock.elapsedMilliseconds,
        'vo': vo,
        'wid': _wid,
        'attached': _surfaceAttached,
        'generation': _surfaceSizeGeneration,
        'pendingGeneration': _pendingSurfaceSizeGeneration,
        'pendingWidth': _pendingSurfaceWidth,
        'pendingHeight': _pendingSurfaceHeight,
        'surfaceWidth': _surfaceWidth,
        'surfaceHeight': _surfaceHeight,
        'sourceWidth': _sourceWidth,
        'sourceHeight': _sourceHeight,
        'firstFrameCompleted': _currentMediaFirstFrameRendered.isCompleted,
        'firstFrameFutureId': identityHashCode(_currentMediaFirstFrameRendered.future),
        ...details,
      })}');
    } catch (_) {
      // Logging cannot interfere with surface setup or frame acknowledgements.
    }
  }

  // ----------------------------------------------

  bool get androidAttachSurfaceAfterVideoParameters =>
      configuration.androidAttachSurfaceAfterVideoParameters ?? vo == 'gpu';

  /// --vo
  String get vo => configuration.vo ?? 'gpu';

  /// --hwdec
  // Future<String> get hwdec async {
  //   if (_hwdec != null) {
  //     return _hwdec!;
  //   }
  //   bool enableHardwareAcceleration = configuration.enableHardwareAcceleration;
  //   // Enforce software rendering in emulators.
  //   final bool isEmulator = await _channel.invokeMethod('Utils.IsEmulator');
  //   if (isEmulator) {
  //     debugPrint('media_kit: AndroidVideoController: Emulator detected.');
  //     debugPrint('media_kit: AndroidVideoController: Enforcing S/W rendering.');
  //     enableHardwareAcceleration = false;
  //   }
  //   _hwdec =
  //       configuration.hwdec ??
  //       (enableHardwareAcceleration ? 'auto-safe' : 'no');
  //   return _hwdec!;
  // }

  // ----------------------------------------------

  String? _current;

  /// {@macro android_video_controller}
  AndroidVideoController._(super.player, super.configuration) {
    width = configuration.width;
    height = configuration.height;

    player.onLoadHooks.add(() {
      final mediaEpoch = _invalidateMediaOutput('load_hook');
      _diagnosticClock.reset();
      _layoutDiagnosticCount = 0;
      _logStartup('load_hook.queued');
      return _lock.synchronized(() async {
        if (mediaEpoch != _mediaEpoch) return;
        _logStartup('load_hook.enter');
        final mpv = NativePlayer.mpv;
        final ctx = player.ctx;

        // An unloaded Surface is never reused, even for the same URL.
        final name = 'path'.toNativeUtf8();
        final path = mpv.mpv_get_property_string(ctx, name);
        final current = path.toDartString();
        calloc.free(name.cast());
        mpv.mpv_free(path.cast());

        if (_current != current || _wid == null) {
          _logStartup('load_hook.new_resource');
          _current = current;
          _surfaceAttached = false;
          _surfaceWidth = null;
          _surfaceHeight = null;
          _invalidatePendingSurfaceSize('load_hook');
          // It is important to use a new android.view.Surface each time a new video-output is created because: https://stackoverflow.com/a/21564236
          // Not doing so will cause MediaCodec usage inside libavcodec to incorrectly fail with error (because this android.view.Surface would be used twice):
          // "native_window_api_connect returned an error: Invalid argument (-22)" & next less-efficient hwdec will be used redundantly.

          // Create a new android.view.Surface & obtain object reference to it.
          // NOTE: Previous android.view.Surface & object reference is internally released/destroyed by the method.
          final data = await _channel.invokeMethod(
            'VideoOutputManager.CreateSurface',
            {'handle': ctx.address.toString()},
          );
          if (mediaEpoch != _mediaEpoch) return;
          debugPrint(data.toString());
          // Save the android.view.Surface object reference for usage inside player.stream.videoParams.listen.
          _wid = data['wid'];
          _logStartup('load_hook.surface_created');
        }

        // By default, android.view.Surface has a size of 1x1. If we assign --wid here, libmpv will internally start rendering & the first frame will be drawn as a solid color: https://github.com/media-kit/media-kit/issues/339
        // The solution is to assign --wid after android.graphics.SurfaceTexture.setDefaultBufferSize has been called & --android-surface-size has been updated (see inside player.stream.videoParams.listen).

        // Assign --wid here if --vo is not "gpu" or "null" i.e. custom vo/hwdec was passed through [VideoControllerConfiguration].
        try {
          // ----------------------------------------------
          if (!androidAttachSurfaceAfterVideoParameters) {
            player.setOption('wid', _wid.toString());
            player.setOption('vo', vo);
            _surfaceAttached = vo == 'gpu';
          }
          // ----------------------------------------------
        } catch (exception, stacktrace) {
          debugPrint(exception.toString());
          debugPrint(stacktrace.toString());
        }
        // on_load runs before the new file's decoder starts. Until this hook
        // finishes, queued video parameters still belong to the old output.
        _sourceWidth = null;
        _sourceHeight = null;
        _mediaActive = true;
        _logStartup('load_hook.ready');
      });
    });
    player.onUnloadHooks.add(() {
      // Invalidate synchronously, BEFORE waiting for a layout/platform call
      // already holding _lock. Its continuation must not reattach the old VO.
      final mediaEpoch = _invalidateMediaOutput('unload_hook');
      return _lock.synchronizedSync(() {
        if (mediaEpoch != _mediaEpoch) return;
        _logStartup('unload_hook');
        _surfaceAttached = false;
        _surfaceWidth = null;
        _surfaceHeight = null;
        _invalidatePendingSurfaceSize('unload_hook');
        _wid = null;
        // Release any references to current android.view.Surface.
        //
        // It is important to set --vo=null here for 2 reasons:
        // 1. Allow the native code to drop any references to the android.view.Surface.
        // 2. Resize the android.graphics.SurfaceTexture to next video's resolution before setting --vo=gpu.
        try {
          // ----------------------------------------------
          player.setOption('vo', 'null');
          player.setOption('wid', '0');
          // ----------------------------------------------
        } catch (exception, stacktrace) {
          debugPrint(exception.toString());
          debugPrint(stacktrace.toString());
        }
      });
    });

    _subscription = player.stream.videoParams.listen(
      (event) async {
        final mediaEpoch = _mediaEpoch;
        if (!_mediaActive) {
          _logStartup('video_params.ignored', {'reason': 'media_inactive'});
          return;
        }
        await _lock.synchronized(() async {
          if (!_isCurrentMedia(mediaEpoch)) return;
          _logStartup('video_params', {
            'dw': event.dw, 'dh': event.dh, 'rotate': event.rotate,
          });
          if (const [0, null].contains(event.dw) ||
              const [0, null].contains(event.dh) ||
              _wid == null) {
            return;
          }

          final int width;
          final int height;
          if (event.rotate == 0 || event.rotate == 180) {
            _sourceWidth = event.dw ?? 0;
            _sourceHeight = event.dh ?? 0;
          } else {
            // width & height are swapped for 90 or 270 degrees rotation.
            _sourceWidth = event.dh ?? 0;
            _sourceHeight = event.dw ?? 0;
          }

          width = vo == 'gpu' ? _outputWidth! : _sourceWidth!;
          height = vo == 'gpu' ? _outputHeight! : _sourceHeight!;
          final surfaceWasAttached = _surfaceAttached;
          try {
            if (vo == 'gpu') {
              if (_surfaceWidth != width || _surfaceHeight != height) {
                await _channel.invokeMethod(
                  'VideoOutputManager.SetSurfaceTextureSize',
                  {
                    'handle': player.handle.toString(),
                    'width': width.toString(),
                    'height': height.toString(),
                  },
                );
                if (!_isCurrentMedia(mediaEpoch)) return;
                if (surfaceWasAttached) {
                  player.setProperty('android-surface-size', '${width}x$height');
                } else {
                  player.setOption('android-surface-size', '${width}x$height');
                }
                _surfaceWidth = width;
                _surfaceHeight = height;
              }

              if (!_surfaceAttached) {
                // Arm the notification before attaching the surface so the
                // first real video frame cannot arrive between attachment and
                // registration.
                final expected = await _expectSurfaceTextureFrame(
                  width,
                  height,
                  minimumFrameCount: 1,
                );
                if (!expected || !_isCurrentMedia(mediaEpoch)) return;
                player.setOption('wid', _wid.toString());
                player.setOption('vo', 'gpu');
                _surfaceAttached = true;
                _logStartup('surface.attached');
              } else if (!_rectMatches(width, height) &&
                  (_pendingSurfaceWidth != width ||
                      _pendingSurfaceHeight != height)) {
                // Media reconfiguration only needs the first frame produced
                // for the new video parameters.
                await _expectSurfaceTextureFrame(
                  width,
                  height,
                  minimumFrameCount: 1,
                );
              }
            }
          } catch (exception, stacktrace) {
            debugPrint(exception.toString());
            debugPrint(stacktrace.toString());
          }
          if (vo != 'gpu') {
            _publishSurfaceSize(width, height);
          }
        });
      },
    );
  }

  /// {@macro android_video_controller}
  static Future<PlatformVideoController> create(
    Player player,
    VideoControllerConfiguration configuration,
  ) async {
    // Retrieve the native handle of the [Player].
    final handle = player.handle;
    // Return the existing [VideoController] if it's already created.
    if (_controllers.containsKey(handle)) {
      return _controllers[handle]!;
    }

    // Creation:
    final controller = AndroidVideoController._(player, configuration);

    // Register [_dispose] for execution upon [Player.dispose].
    player.release.add(controller._dispose);

    // Store the [VideoController] in the [_controllers].
    _controllers[handle] = controller;

    final data = await _channel.invokeMethod('VideoOutputManager.Create', {
      'handle': handle.toString(),
    });
    debugPrint(data.toString());

    final int? id = data['id'];

    // ----------------------------------------------

    final values = {
      // It is necessary to set vo=null here to avoid SIGSEGV, --wid must be assigned before vo=gpu is set.
      'vo': 'null',
      'hwdec':
          configuration.hwdec ??
          (configuration.enableHardwareAcceleration ? 'auto-safe' : 'no'),
      'vid': 'auto',
      'opengl-es': 'yes',
      'force-window': 'yes',
      'gpu-context': 'android',
      'sub-use-margins': 'no',
      'sub-font-provider': 'none',
      'sub-scale-with-window': 'yes',
      'hwdec-codecs': 'h264,hevc,mpeg4,mpeg2video,vp8,vp9,av1',
    };

    for (final entry in values.entries) {
      final name = entry.key.toNativeUtf8();
      final value = entry.value.toNativeUtf8();
      NativePlayer.mpv.mpv_set_property_string(player.ctx, name, value);
      calloc.free(name);
      calloc.free(value);
    }
    // ----------------------------------------------

    controller.id.value = id;

    // Return the [PlatformVideoController].
    return controller;
  }

  /// Sets the required size of the video output.
  /// This may yield substantial performance improvements if a small [width] & [height] is specified.
  ///
  /// Remember:
  /// * “Premature optimization is the root of all evil”
  /// * “With great power comes great responsibility”
  @override
  Future<void> setSize({
    int? width,
    int? height,
    bool waitForFrame = false,
  }) async {
    if ((width != null && width <= 0) || (height != null && height <= 0)) {
      throw ArgumentError('width & height must be null or positive.');
    }

    _logStartup('set_size.queued', {
      'requestedWidth': width, 'requestedHeight': height,
      'waitForFrame': waitForFrame,
    });
    await _lock.synchronized(() async {
      _logStartup('set_size.enter', {
        'requestedWidth': width, 'requestedHeight': height,
        'waitForFrame': waitForFrame,
      });
      this.width = width;
      this.height = height;
      final mediaEpoch = _mediaEpoch;
      if (!_mediaActive) return;

      if (!waitForFrame &&
          _pendingSurfaceSizeGeneration != null) {
        // Ordinary layout changes must remain responsive. Invalidate the
        // Dart generation before crossing the platform channel so an
        // already queued acknowledgement cannot publish an obsolete size.
        _invalidatePendingSurfaceSize('set_size_without_frame_wait');
        await _channel.invokeMethod<void>(
          'VideoOutputManager.CancelSurfaceTextureFrameExpectation',
          {'handle': player.handle.toString()},
        );
        if (!_isCurrentMedia(mediaEpoch)) return;
        _logStartup('expectation.cancel_sent');
      }

      final outputWidth = _outputWidth;
      final outputHeight = _outputHeight;
      if (_wid == null ||
          vo != 'gpu' ||
          !_surfaceAttached ||
          outputWidth == null ||
          outputHeight == null) {
        return;
      }

      if (_surfaceWidth != outputWidth || _surfaceHeight != outputHeight) {
        await _channel.invokeMethod<void>(
          'VideoOutputManager.SetSurfaceTextureSize',
          {
            'handle': player.handle.toString(),
            'width': outputWidth.toString(),
            'height': outputHeight.toString(),
          },
        );
        if (!_isCurrentMedia(mediaEpoch)) return;
        player.setProperty(
          'android-surface-size',
          '${outputWidth}x$outputHeight',
        );
        _surfaceWidth = outputWidth;
        _surfaceHeight = outputHeight;
      }

      if (waitForFrame) {
        if (!_rectMatches(outputWidth, outputHeight) &&
            (_pendingSurfaceWidth != outputWidth ||
                _pendingSurfaceHeight != outputHeight)) {
          // A SurfaceTexture callback can still belong to one buffer queued
          // before the resize command. Fullscreen transitions therefore
          // require two callbacks before publishing the target size.
          await _expectSurfaceTextureFrame(
            outputWidth,
            outputHeight,
            minimumFrameCount: 2,
          );
        }
      } else {
        // Preserve the original immediate resize behavior for continuously
        // changing layouts such as comment-panel drags and pinch gestures.
        _publishSurfaceSize(outputWidth, outputHeight);
      }
    });
  }

  @override
  Future<void> get waitUntilFirstFrameRendered => vo == 'gpu'
      ? _currentMediaFirstFrameRendered.future
      : super.waitUntilFirstFrameRendered;

  @override
  Future<void> armWaitUntilFirstFrameRendered() {
    _diagnosticMediaGeneration++;
    _diagnosticClock.reset();
    _layoutDiagnosticCount = 0;
    _logStartup('first_frame.arm');
    if (vo != 'gpu') {
      return super.armWaitUntilFirstFrameRendered();
    }
    _invalidateMediaOutput('first_frame.arm');
    _currentMediaFirstFrameRendered = Completer<void>();
    _logStartup('first_frame.armed');
    return _currentMediaFirstFrameRendered.future;
  }

  Future<bool> _expectSurfaceTextureFrame(
    int width,
    int height, {
    required int minimumFrameCount,
  }) async {
    final mediaEpoch = _mediaEpoch;
    if (!_mediaActive) return false;
    final generation = ++_surfaceSizeGeneration;
    _pendingMediaEpoch = mediaEpoch;
    _pendingSurfaceSizeGeneration = generation;
    _pendingSurfaceWidth = width;
    _pendingSurfaceHeight = height;
    _logStartup('expectation.before', {'minimumFrameCount': minimumFrameCount});

    try {
      await _channel.invokeMethod<void>(
        'VideoOutputManager.ExpectSurfaceTextureFrame',
        {
          'handle': player.handle.toString(),
          'generation': generation.toString(),
          'width': width.toString(),
          'height': height.toString(),
          'minimumFrameCount': minimumFrameCount.toString(),
        },
      );
      if (!_isCurrentMedia(mediaEpoch)) return false;
      _logStartup('expectation.registered', {'requestedGeneration': generation});
      return true;
    } catch (error) {
      _logStartup('expectation.error', {
        'requestedGeneration': generation,
        'errorType': error.runtimeType.toString(),
      });
      if (_pendingSurfaceSizeGeneration == generation) {
        _pendingMediaEpoch = null;
        _pendingSurfaceSizeGeneration = null;
        _pendingSurfaceWidth = null;
        _pendingSurfaceHeight = null;
      }
      if (_isCurrentMedia(mediaEpoch) &&
          _surfaceWidth == width &&
          _surfaceHeight == height) {
        _publishSurfaceSize(width, height);
      }
      rethrow;
    }
  }

  void _notifySurfaceTextureFrame(
    int generation,
    int width,
    int height,
  ) {
    if (!_mediaActive ||
        _pendingMediaEpoch != _mediaEpoch ||
        _pendingSurfaceSizeGeneration != generation ||
        _pendingSurfaceWidth != width ||
        _pendingSurfaceHeight != height ||
        _surfaceWidth != width ||
        _surfaceHeight != height) {
      _logStartup('frame.rejected', {
        'receivedGeneration': generation,
        'receivedWidth': width,
        'receivedHeight': height,
        'blockers': [
          if (!_mediaActive) 'media_inactive',
          if (_pendingMediaEpoch != _mediaEpoch) 'media_epoch',
          if (_pendingSurfaceSizeGeneration != generation) 'generation',
          if (_pendingSurfaceWidth != width) 'pending_width',
          if (_pendingSurfaceHeight != height) 'pending_height',
          if (_surfaceWidth != width) 'surface_width',
          if (_surfaceHeight != height) 'surface_height',
        ],
      });
      return;
    }

    _logStartup('frame.accepted', {'receivedGeneration': generation});
    _pendingMediaEpoch = null;
    _pendingSurfaceSizeGeneration = null;
    _pendingSurfaceWidth = null;
    _pendingSurfaceHeight = null;
    if (!_currentMediaFirstFrameRendered.isCompleted) {
      _currentMediaFirstFrameRendered.complete();
      _logStartup('first_frame.completed');
    }
    _publishSurfaceSize(width, height);
  }

  void _notifyFirstFrameRendered() {
    _logStartup('legacy_first_frame.received');
    if (!waitUntilFirstFrameRenderedCompleter.isCompleted) {
      waitUntilFirstFrameRenderedCompleter.complete();
    }
  }

  void _invalidatePendingSurfaceSize(String reason) {
    _logStartup('expectation.invalidated', {'reason': reason});
    _surfaceSizeGeneration++;
    _pendingMediaEpoch = null;
    _pendingSurfaceSizeGeneration = null;
    _pendingSurfaceWidth = null;
    _pendingSurfaceHeight = null;
  }

  bool _isCurrentMedia(int epoch) => _mediaActive && epoch == _mediaEpoch;

  int _invalidateMediaOutput(String reason) {
    _mediaActive = false;
    _mediaEpoch++;
    _invalidatePendingSurfaceSize(reason);
    return _mediaEpoch;
  }

  bool _rectMatches(int width, int height) {
    final current = rect.value;
    return current != null &&
        current.width == width &&
        current.height == height;
  }

  void _publishSurfaceSize(int width, int height) {
    rect.value = Rect.fromLTRB(
      0.0,
      0.0,
      width.toDouble(),
      height.toDouble(),
    );
  }

  int? get _outputWidth {
    if (width != null) return width;
    if (height != null && _sourceWidth != null && _sourceHeight != null) {
      return (height! * _sourceWidth! / _sourceHeight!).round();
    }
    return _sourceWidth;
  }

  int? get _outputHeight {
    if (height != null) return height;
    if (width != null && _sourceWidth != null && _sourceHeight != null) {
      return (width! * _sourceHeight! / _sourceWidth!).round();
    }
    return _sourceHeight;
  }

  /// Disposes the instance. Releases allocated resources back to the system.
  Future<void> _dispose() async {
    _invalidateMediaOutput('dispose');
    // Dispose the [StreamSubscription]s.
    await _subscription?.cancel();
    // Release the native resources.
    final handle = player.handle;
    _controllers.remove(handle);
    await _channel.invokeMethod('VideoOutputManager.Dispose', {
      'handle': handle.toString(),
    });
  }

  /// Pointer address to the global object reference of `android.view.Surface` i.e. `(intptr_t)(*android.view.Surface)`.
  int? _wid;

  /// [Lock] used to synchronize the [_widthStreamSubscription] & [_heightStreamSubscription].
  final _lock = Lock();

  /// [StreamSubscription] for listening to video [Rect] from [_controller].
  StreamSubscription<VideoParams>? _subscription;

  /// Currently created [AndroidVideoController]s.
  static final _controllers = HashMap<int, AndroidVideoController>();

  /// [MethodChannel] for invoking platform specific native implementation.
  static final _channel =
      const MethodChannel(
        'com.alexmercerind/media_kit_video',
      )..setMethodCallHandler((MethodCall call) async {
        try {
          debugPrint(call.method.toString());
          debugPrint(call.arguments.toString());
          switch (call.method) {
            case 'VideoOutput.WaitUntilFirstFrameRenderedNotify':
              {
                // Notify about updated texture ID & [Rect].
                final int handle = call.arguments['handle'];
                debugPrint(handle.toString());
                // Notify about the first frame being rendered.
                _controllers[handle]?._notifyFirstFrameRendered();
                break;
              }
            case 'VideoOutput.SurfaceTextureFrameAvailable':
              {
                final int handle = call.arguments['handle'];
                final int generation = call.arguments['generation'];
                final int width = call.arguments['width'];
                final int height = call.arguments['height'];
                final controller = _controllers[handle];
                if (controller == null) {
                  debugPrintSynchronously(
                    '[PiliPlusStartup] layer=surface event=frame.missing_controller '
                    'handle=$handle generation=$generation width=$width height=$height',
                  );
                }
                controller?._notifySurfaceTextureFrame(
                  generation,
                  width,
                  height,
                );
                break;
              }
            default:
              {
                break;
              }
          }
        } catch (exception, stacktrace) {
          debugPrint(exception.toString());
          debugPrint(stacktrace.toString());
        }
      });
}

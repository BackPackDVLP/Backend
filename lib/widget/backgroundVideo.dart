import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

class BackgroundVideo extends StatefulWidget {
  final String? videoUrl;
  const BackgroundVideo({super.key, this.videoUrl});

  @override
  _BackgroundVideoState createState() => _BackgroundVideoState();
}

class _BackgroundVideoState extends State<BackgroundVideo> {
  late VideoPlayerController _controller;
  late Future<void> _initializeBackgroundVideoFuture;

  @override
  void initState() {
    super.initState();
    _initializeController();
  }

  void _initializeController() {
    if (widget.videoUrl != null && widget.videoUrl!.isNotEmpty) {
      _controller = VideoPlayerController.networkUrl(
        Uri.parse(widget.videoUrl!),
        videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
      );
    } else {
      _controller = VideoPlayerController.asset(
        'assets/images/backgroundVideo.mp4',
        videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
      );
    }
    _initializeBackgroundVideoFuture = _controller.initialize().then((_) {
      _controller.setVolume(0);
      _controller.setLooping(true);
      _controller.play();
      if (mounted) setState(() {});
    });
  }

  @override
  void didUpdateWidget(BackgroundVideo oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.videoUrl != widget.videoUrl) {
      _controller.dispose();
      _initializeController();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder(
      future: _initializeBackgroundVideoFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.done) {
          return SizedBox.expand(
            child: FittedBox(
              fit: BoxFit.cover,
              child: SizedBox(
                width: _controller.value.size.width,
                height: _controller.value.size.height,
                child: VideoPlayer(_controller),
              ),
            ),
          );
        } else {
          return Container(color: Colors.black);
        }
      },
    );
  }
}

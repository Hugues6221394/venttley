import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:screenshot/screenshot.dart';
import 'package:share_plus/share_plus.dart';
import 'package:path_provider/path_provider.dart';

import 'dart:io';

import '../../../core/providers.dart';
import '../../theme/colors.dart';
import '../../widgets/mood_chip.dart';
import '../../widgets/vently_logo.dart';

class ShareCardScreen extends ConsumerWidget {
  const ShareCardScreen({super.key, required this.postId});
  final String postId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final postAsync = ref.watch(postByIdProvider(postId));
    final post = postAsync.valueOrNull;
    if (postAsync.isLoading && post == null) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    if (post == null) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: Text('Post not found')),
      );
    }
    final screenshotController = ScreenshotController();
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => context.pop()),
        title: const Text('Share'),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: Center(
                  child: Screenshot(
                    controller: screenshotController,
                    child: Container(
                      width: 320,
                      padding: const EdgeInsets.all(22),
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [
                            VentlyColors.blushPink,
                            Color(0xFFFAD0DA),
                          ],
                        ),
                        borderRadius: BorderRadius.circular(28),
                        border: Border.all(color: VentlyColors.softMauve),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Row(
                            children: [
                              const VentlyLogo(size: 18),
                              const Spacer(),
                              MoodChip(mood: post.postMood, dense: true),
                            ],
                          ),
                          const SizedBox(height: 18),
                          Text(
                            '"${post.content}"',
                            style: const TextStyle(
                              fontSize: 16,
                              fontStyle: FontStyle.italic,
                              fontWeight: FontWeight.w600,
                              color: VentlyColors.deepBurgundy,
                              height: 1.4,
                            ),
                          ),
                          const SizedBox(height: 20),
                          Row(
                            children: [
                              Text(
                                'Shared by ${post.authorPseudonym}',
                                style: const TextStyle(
                                  color: VentlyColors.deepBurgundy,
                                  fontWeight: FontWeight.w800,
                                  fontSize: 11,
                                ),
                              ),
                              const Spacer(),
                              Container(
                                width: 36,
                                height: 36,
                                decoration: BoxDecoration(
                                  color: scheme.primary,
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: const Icon(
                                  Icons.qr_code,
                                  color: Colors.white,
                                  size: 22,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 18),
              Text('Share to',
                  style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 12),
              const Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _ShareIcon(label: 'IG Story',  icon: Icons.camera_alt_outlined, color: Color(0xFFE1306C)),
                  _ShareIcon(label: 'Snapchat',  icon: Icons.send_rounded,        color: Color(0xFFFFFC00)),
                  _ShareIcon(label: 'TikTok',    icon: Icons.music_note,          color: Colors.black87),
                  _ShareIcon(label: 'WhatsApp',  icon: Icons.chat,                color: Color(0xFF25D366)),
                ],
              ),
              const SizedBox(height: 20),
              ElevatedButton.icon(
                onPressed: () async {
                  final bytes = await screenshotController.capture();
                  if (bytes == null) return;
                  final dir = await getTemporaryDirectory();
                  final file = File('${dir.path}/vently-share.png');
                  await file.writeAsBytes(bytes);
                  await Share.shareXFiles(
                    [XFile(file.path)],
                    text: 'Vented on Vently — your safe space.',
                  );
                },
                icon: const Icon(Icons.download, size: 18),
                label: const Text('Download Image'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ShareIcon extends StatelessWidget {
  const _ShareIcon({required this.label, required this.icon, required this.color});
  final String label;
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          width: 52,
          height: 52,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Icon(icon, color: Colors.white),
        ),
        const SizedBox(height: 6),
        Text(label, style: const TextStyle(fontSize: 11)),
      ],
    );
  }
}

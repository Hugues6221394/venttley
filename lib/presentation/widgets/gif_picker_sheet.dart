import 'dart:convert';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../../core/constants.dart';
import '../theme/colors.dart';

/// A Tenor-backed GIF search sheet. Returns the chosen GIF's URL (a remote
/// hotlink — no upload needed) or null if dismissed. Needs
/// [VentlyConfig.tenorApiKey]; without it, shows a friendly setup message.
Future<String?> showGifPickerSheet(BuildContext context) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.white,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (_) => const _GifPickerSheet(),
  );
}

class _GifPickerSheet extends StatefulWidget {
  const _GifPickerSheet();

  @override
  State<_GifPickerSheet> createState() => _GifPickerSheetState();
}

class _GifPickerSheetState extends State<_GifPickerSheet> {
  final _search = TextEditingController();
  List<_Gif> _results = const [];
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (VentlyConfig.gifSearchEnabled) _load(''); // featured on open
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load(String query) async {
    if (!VentlyConfig.gifSearchEnabled) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final base = query.trim().isEmpty
          ? 'https://tenor.googleapis.com/v2/featured'
          : 'https://tenor.googleapis.com/v2/search';
      final uri = Uri.parse(base).replace(queryParameters: {
        'key': VentlyConfig.tenorApiKey,
        if (query.trim().isNotEmpty) 'q': query.trim(),
        'limit': '24',
        'media_filter': 'tinygif,gif',
        'contentfilter': 'high', // SFW only — this is a support space
        'client_key': 'venttly',
      });
      final res = await http.get(uri);
      if (res.statusCode != 200) {
        throw Exception('Tenor ${res.statusCode}');
      }
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final results = (data['results'] as List? ?? []).map((r) {
        final media = (r as Map)['media_formats'] as Map?;
        final full = (media?['gif'] as Map?)?['url'] as String?;
        final preview = (media?['tinygif'] as Map?)?['url'] as String? ?? full;
        return _Gif(preview: preview ?? '', full: full ?? preview ?? '');
      }).where((g) => g.full.isNotEmpty).toList();
      if (!mounted) return;
      setState(() {
        _results = results;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Couldn\'t load GIFs. Check your connection and try again.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final viewInsets = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: viewInsets),
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.7,
        child: Column(
          children: [
            const SizedBox(height: 10),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: VentlyColors.softMauve,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: TextField(
                controller: _search,
                textInputAction: TextInputAction.search,
                onSubmitted: _load,
                decoration: InputDecoration(
                  hintText: 'Search GIFs',
                  prefixIcon: const Icon(Icons.gif_box_outlined),
                  filled: true,
                  fillColor: const Color(0xFFFFF1F6),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
            Expanded(child: _body()),
          ],
        ),
      ),
    );
  }

  Widget _body() {
    if (!VentlyConfig.gifSearchEnabled) {
      return const _Centered(
        icon: Icons.gif_box_outlined,
        text: 'GIF search isn\'t configured yet.\n'
            'Add a Tenor API key (TENOR_API_KEY) to enable it.',
      );
    }
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return _Centered(icon: Icons.wifi_off_rounded, text: _error!);
    }
    if (_results.isEmpty) {
      return const _Centered(
          icon: Icons.search_off_rounded, text: 'No GIFs found.');
    }
    return GridView.builder(
      padding: const EdgeInsets.all(12),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
      ),
      itemCount: _results.length,
      itemBuilder: (_, i) {
        final g = _results[i];
        return GestureDetector(
          onTap: () => Navigator.pop(context, g.full),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: CachedNetworkImage(
              imageUrl: g.preview,
              fit: BoxFit.cover,
              placeholder: (_, __) => Container(color: const Color(0xFFFFE3EC)),
              errorWidget: (_, __, ___) =>
                  Container(color: const Color(0xFFFFE3EC)),
            ),
          ),
        );
      },
    );
  }
}

class _Centered extends StatelessWidget {
  const _Centered({required this.icon, required this.text});
  final IconData icon;
  final String text;
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 34, color: VentlyColors.softMauve),
            const SizedBox(height: 10),
            Text(
              text,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: context.ink.withOpacity(0.6),
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Gif {
  const _Gif({required this.preview, required this.full});
  final String preview;
  final String full;
}
